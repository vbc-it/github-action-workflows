#!/usr/bin/env bash
# Tests for the scenario lock of .github/workflows/ansible-collection.yml: the
# "Plan Molecule jobs" step of discover, the molecule-lock and molecule-unlock
# jobs and the "Check scenario lock" step of the Molecule jobs, run against an
# in-memory mock of the GitHub git refs and workflow run APIs (mock_github_api.py).
#
# Needs bash 4+, curl, jq and python3 with PyYAML, e.g.
#   PYTHON=tests/ansible_collections/legacy_collection/.venv/bin/python tests/lock/test_lock.sh
# shellcheck disable=SC2015  # fail() never fails
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo"
python=${PYTHON:-python3}

work=$(mktemp -d)
"$python" -I tests/lock/mock_github_api.py "$work/port" &
mock_pid=$!
trap 'kill "$mock_pid" 2> /dev/null || true; rm -rf "$work"' EXIT

"$python" -I - .github/workflows/ansible-collection.yml "$work" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    jobs = yaml.safe_load(f)["jobs"]
for job, key, value, out in (
    ("discover", "id", "molecule-plan", "plan.sh"),
    ("molecule-lock", "name", "Acquire scenario locks", "acquire.sh"),
    ("molecule-unlock", "name", "Release scenario locks", "release.sh"),
    ("molecule", "name", "Check scenario lock", "check.sh"),
    ("molecule-locked", "name", "Check scenario lock", "check-locked.sh"),
):
    with open(f"{sys.argv[2]}/{out}", "w", encoding="utf-8") as f:
        f.write(next(s for s in jobs[job]["steps"] if s.get(key) == value)["run"])
PY

for _ in $(seq 50); do [[ -s "$work/port" ]] && break; sleep 0.1; done
api="http://127.0.0.1:$(cat "$work/port")"
now() { "$python" -I -c 'import time; print(f"{time.time():.3f}")'; }

common=(GITHUB_API_URL="$api" GITHUB_REPOSITORY=o/r GITHUB_SERVER_URL=https://github.example
  GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 GH_TOKEN=token COLLECTION_PATH=. LOCK_POLL_SECONDS=1)
run_step() { # run_step <script> <log> [VAR=value ...]
  local script=$1 log=$2
  shift 2
  env "${common[@]}" RUNNER_TEMP="$work" "$@" bash --noprofile --norc -eo pipefail "$work/$script" > "$log" 2>&1
}
# locks <role>/<scenario> ...: the molecule_locked output for legacy scenarios.
locks() { printf '%s\n' "$@" | jq -R 'split("/") | {role: .[0], scenario: .[1], is_native: false, locked: true}' | jq -cs .; }

# hold <name> <seconds> <locks json> [VAR=value ...]: acquire, hold, release.
# Each holder is a separate call of the workflow (PLATFORM=<name>). Writes
# $work/<name>.times with "<acquired> <released>".
hold() {
  local name=$1 seconds=$2 locks=$3
  shift 3
  mkdir -p "$work/$name"
  run_step acquire.sh "$work/$name/acquire.log" RUNNER_TEMP="$work/$name" PLATFORM="$name" LOCKS="$locks" "$@"
  local acquired released
  acquired=$(now)
  sleep "$seconds"
  released=$(now)
  run_step release.sh "$work/$name/release.log" PLATFORM="$name" LOCKS="$locks"
  echo "$acquired $released" > "$work/$name.times"
}

failures=0
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
overlap() { # overlap <a> <b>: true when the held intervals overlap
  read -r a1 a2 < "$work/$1.times"
  read -r b1 b2 < "$work/$2.times"
  "$python" -I -c 'import sys; a1, a2, b1, b2 = map(float, sys.argv[1:]); sys.exit(0 if a1 < b2 and b1 < a2 else 1)' "$a1" "$a2" "$b1" "$b2"
}
ref_sha() { curl -s "$api/repos/o/r/git/ref/heads/$1" | jq -r '.object.sha // empty'; }

# Plan: split into locked and unlocked scenarios and mark the secret scenarios.
plan() { # plan <log> [VAR=value ...]
  local log=$1
  shift
  : > "$work/plan.out"
  env GITHUB_OUTPUT="$work/plan.out" GALAXY_TOKEN_SERVERS='published rh_certified community staging' \
    ROLE_SCENARIOS='[{"role":"r1","scenario":"default","is_native":false},{"role":"r1","scenario":"other","is_native":false},{"role":"r2","scenario":"r2/s1","is_native":true}]' \
    MOLECULE_LOCK_SCENARIOS='["r1/default","r2/s1"]' MOLECULE_SECRET_SCENARIOS='["*"]' "$@" \
    bash --noprofile --norc -eo pipefail "$work/plan.sh" > "$log" 2>&1
}
plan_ids() { # plan_ids <unlocked|locked>: "<id>:<secrets>" sorted
  sed -n "s/^$1=//p" "$work/plan.out" | jq -r '.[] | (if .is_native then .scenario else .role + "/" + .scenario end) + ":\(.secrets)"' | sort | xargs
}
if plan "$work/plan.log" && [[ "$(plan_ids unlocked)" == "r1/other:true" && "$(plan_ids locked)" == "r1/default:true r2/s1:true" ]]; then
  echo "ok   plan: locked scenarios split off, \"*\" gives all scenarios the secrets"
else
  fail "plan: unlocked [$(plan_ids unlocked)] locked [$(plan_ids locked)]"; cat "$work/plan.log"
fi
if plan "$work/plan.log" MOLECULE_SECRET_SCENARIOS='["r2/s1"]' MOLECULE_LOCK_SCENARIOS='[]' \
  && [[ "$(plan_ids unlocked)" == "r1/default:false r1/other:false r2/s1:true" && "$(plan_ids locked)" == "" ]]; then
  echo "ok   plan: only listed scenarios get the secrets"
else
  fail "plan: secret selection: unlocked [$(plan_ids unlocked)] locked [$(plan_ids locked)]"; cat "$work/plan.log"
fi
plan "$work/plan.log" MOLECULE_SECRET_SCENARIOS='[]' && [[ "$(plan_ids unlocked)" == "r1/other:false" ]] \
  && echo "ok   plan: [] gives no scenario the secrets" || fail "plan: []: [$(plan_ids unlocked)]"
for bad in 'MOLECULE_SECRET_SCENARIOS={"r1": "default"}' 'GALAXY_TOKEN_SERVERS=published,community' 'GALAXY_TOKEN_SERVERS=Published'; do
  if plan "$work/plan.log" "$bad"; then
    fail "plan: $bad: expected a failure"
  else
    echo "ok   plan: $bad fails: $(grep -m1 '::error::' "$work/plan.log")"
  fi
done

# Same scenario: the second job waits, and neither is cancelled.
hold q1 3 "$(locks role1/default)" & p1=$!
sleep 0.5
hold q2 1 "$(locks role1/default)" & p2=$!
hold q3 1 "$(locks role1/default)" & p3=$!
if wait "$p1" && wait "$p2" && wait "$p3"; then
  if overlap q1 q2 || overlap q1 q3 || overlap q2 q3; then
    fail "same scenario: holders overlapped"
  else
    echo "ok   same scenario: three jobs queued and each held the lock alone"
  fi
else
  fail "same scenario: a job failed"; cat "$work"/q*/acquire.log
fi
grep -q 'Waiting: Molecule lock held by https://github.example/o/r/actions/runs/1/attempts/1 role1/default (' "$work/q2/acquire.log" \
  && echo "ok   waiting job names the holder" || fail "waiting job did not name the holder"
[[ -z "$(ref_sha molecule-lock/role1/default)" ]] && echo "ok   lock branch deleted after release" || fail "lock branch left behind"

# Different scenarios of the same role don't wait for each other.
hold d1 2 "$(locks role1/default)" & p1=$!
hold d2 2 "$(locks role1/other)" & p2=$!
wait "$p1" && wait "$p2"
overlap d1 d2 && echo "ok   different scenarios run in parallel" || fail "different scenarios were serialised"

# Two runs that need the same two locks, listed in opposite order, do not
# deadlock (a deadlock would hang here; the self-test job has a timeout).
hold m1 2 "$(locks role1/a role1/b)" & p1=$!
hold m2 2 "$(locks role1/b role1/a)" & p2=$!
if wait "$p1" && wait "$p2"; then
  overlap m1 m2 && fail "several locks: holders overlapped" || echo "ok   several locks are taken in name order without deadlock"
else
  fail "several locks: a job failed"; cat "$work"/m*/acquire.log
fi
[[ -z "$(ref_sha molecule-lock/role1/a)$(ref_sha molecule-lock/role1/b)" ]] \
  && echo "ok   all locks of a job released" || fail "locks of a job left behind"

# Native scenario names keep their role prefix; "/" becomes "__".
hold n1 0 '[{"role":"role2","scenario":"role2/scenario1","is_native":true,"locked":true}]'
grep -q 'Acquired molecule-lock/role2/role2__scenario1' "$work/n1/acquire.log" \
  && echo "ok   native scenario branch name" || fail "native scenario branch name: $(cat "$work/n1/acquire.log")"

# Check scenario lock: passes while this run holds the lock, fails after release.
check_env=(PLATFORM=c1 ROLE=role1 SCENARIO=check)
run_step acquire.sh "$work/c1-acquire.log" PLATFORM=c1 LOCKS="$(locks role1/check)"
run_step check-locked.sh "$work/c1-check.log" "${check_env[@]}" GITHUB_RUN_ATTEMPT=2 \
  && echo "ok   check passes while the run holds the lock (also in a later attempt)" || { fail "check failed while held"; cat "$work/c1-check.log"; }
run_step check-locked.sh "$work/c1-check-other.log" PLATFORM=other ROLE=role1 SCENARIO=check \
  && fail "check passed for another call of the workflow" || echo "ok   check fails for another call of the workflow"
run_step release.sh "$work/c1-release.log" PLATFORM=c1 LOCKS="$(locks role1/check)"
if run_step check-locked.sh "$work/c1-check-after.log" "${check_env[@]}"; then
  fail "check passed after release"
else
  echo "ok   check fails without the lock: $(grep -m1 '::error::' "$work/c1-check-after.log")"
fi
cmp -s "$work/check.sh" "$work/check-locked.sh" && echo "ok   both Molecule jobs share their steps" || fail "molecule and molecule-locked steps differ"

# A lock whose holder run has completed (or was deleted) is removed.
for status in completed gone; do
  run=$([[ $status == completed ]] && echo 999 || echo 997)
  curl -s -X POST "$api/_test/run/$run/$status" > /dev/null
  curl -s -X POST "$api/_test/held/$run/molecule-lock/role1/stale" > /dev/null
  if hold "s-$status" 0 "$(locks role1/stale)" && grep -q '::warning::Removing stale lock molecule-lock/role1/stale' "$work/s-$status/acquire.log"; then
    echo "ok   stale lock removed (holder run $status)"
  else
    fail "stale lock not removed (holder run $status)"; cat "$work/s-$status/acquire.log"
  fi
done

# A lock of a run that is still in progress is kept however old it is, until that run completes.
curl -s -X POST "$api/_test/held/998/molecule-lock/role1/busy" > /dev/null
run_step acquire.sh "$work/b1-acquire.log" PLATFORM=b1 LOCKS="$(locks role1/busy)" & p1=$!
sleep 3
if kill -0 "$p1" 2> /dev/null && grep -q 'Waiting: .*runs/998/' "$work/b1-acquire.log"; then
  echo "ok   old lock of a running holder is kept"
else
  fail "old lock of a running holder was not kept"; cat "$work/b1-acquire.log"
fi
curl -s -X POST "$api/_test/run/998/completed" > /dev/null
wait "$p1" && grep -q 'Acquired molecule-lock/role1/busy' "$work/b1-acquire.log" \
  && echo "ok   lock taken once the holder run completed" || fail "lock not taken after the holder completed"

# Release does not delete a lock that another run holds.
curl -s -X POST "$api/_test/held/996/molecule-lock/role1/foreign" > /dev/null
held=$(ref_sha molecule-lock/role1/foreign)
run_step release.sh "$work/foreign.log" PLATFORM=f LOCKS="$(locks role1/foreign)"
[[ "$(ref_sha molecule-lock/role1/foreign)" == "$held" ]] && echo "ok   release leaves another holder's lock" || fail "release deleted another holder's lock"

# Without contents: write or actions: read the job fails with a hint instead of waiting forever.
for token in readonly noactions; do
  if run_step acquire.sh "$work/$token.log" GH_TOKEN=$token PLATFORM=ro LOCKS="$(locks role1/ro)"; then
    fail "$token token: expected a failure"
  elif grep -q 'contents: write and actions: read' "$work/$token.log"; then
    echo "ok   $token token fails: $(grep -m1 '::error::' "$work/$token.log")"
  else
    fail "$token token: unexpected output"; cat "$work/$token.log"
  fi
done

if [[ $failures -ne 0 ]]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "All cases passed"
