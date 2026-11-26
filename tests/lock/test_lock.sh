#!/usr/bin/env bash
# Tests for the "Acquire scenario lock" and "Release scenario lock" steps of
# .github/workflows/ansible-collection.yml, run against an in-memory mock of
# the GitHub git refs API (mock_github_api.py).
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
    steps = yaml.safe_load(f)["jobs"]["molecule"]["steps"]
for name, out in (("Acquire scenario lock", "acquire.sh"), ("Release scenario lock", "release.sh")):
    with open(f"{sys.argv[2]}/{out}", "w", encoding="utf-8") as f:
        f.write(next(s for s in steps if s.get("name") == name)["run"])
PY

for _ in $(seq 50); do [[ -s "$work/port" ]] && break; sleep 0.1; done
api="http://127.0.0.1:$(cat "$work/port")"
now() { "$python" -I -c 'import time; print(f"{time.time():.3f}")'; }

common=(GITHUB_API_URL="$api" GITHUB_REPOSITORY=o/r GITHUB_SERVER_URL=https://github.example
  GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 GH_TOKEN=token STALE_MINUTES=120 LOCK_POLL_SECONDS=1)

# hold <name> <role> <scenario> <seconds> [VAR=value ...]: acquire, hold, release.
# Writes $work/<name>.times with "<acquired> <released>".
hold() {
  local name=$1 role=$2 scenario=$3 seconds=$4
  shift 4
  mkdir -p "$work/$name"
  : > "$work/$name/output"
  env "${common[@]}" RUNNER_TEMP="$work/$name" GITHUB_OUTPUT="$work/$name/output" \
    ROLE="$role" SCENARIO="$scenario" "$@" bash --noprofile --norc -eo pipefail "$work/acquire.sh" > "$work/$name/acquire.log" 2>&1
  local acquired released
  acquired=$(now)
  sleep "$seconds"
  released=$(now)
  env "${common[@]}" RUNNER_TEMP="$work/$name" \
    LOCK_BRANCH="$(sed -n 's/^branch=//p' "$work/$name/output")" \
    LOCK_COMMIT="$(sed -n 's/^commit=//p' "$work/$name/output")" \
    bash --noprofile --norc -eo pipefail "$work/release.sh" > "$work/$name/release.log" 2>&1
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

# Same scenario: the second job waits, and neither is cancelled.
hold q1 role1 default 3 & p1=$!
sleep 0.5
hold q2 role1 default 1 & p2=$!
hold q3 role1 default 1 & p3=$!
if wait "$p1" && wait "$p2" && wait "$p3"; then
  if overlap q1 q2 || overlap q1 q3 || overlap q2 q3; then
    fail "same scenario: holders overlapped"
  else
    echo "ok   same scenario: three jobs queued and each held the lock alone"
  fi
else
  fail "same scenario: a job failed"; cat "$work"/q*/acquire.log
fi
grep -q 'Waiting: Molecule lock held by https://github.example/o/r/actions/runs/1/attempts/1 role1/default' "$work/q2/acquire.log" \
  && echo "ok   waiting job names the holder" || fail "waiting job did not name the holder"
[[ -z "$(ref_sha molecule-lock/role1/default)" ]] && echo "ok   lock branch deleted after release" || fail "lock branch left behind"

# Different scenarios of the same role don't wait for each other.
hold d1 role1 default 2 & p1=$!
hold d2 role1 other 2 & p2=$!
wait "$p1" && wait "$p2"
overlap d1 d2 && echo "ok   different scenarios run in parallel" || fail "different scenarios were serialised"

# Native scenario names keep their role prefix; "/" becomes "__".
hold n1 role2 role2/scenario1 0
grep -qx 'branch=molecule-lock/role2/role2__scenario1' "$work/n1/output" \
  && echo "ok   native scenario branch name" || fail "native scenario branch name: $(cat "$work/n1/output")"

# A lock older than molecule_timeout_minutes + 5 is removed.
curl -s -X POST "$api/_test/stale/molecule-lock/role1/stale" > /dev/null
if hold s1 role1 stale 0 STALE_MINUTES=1 && grep -q '::warning::Removing stale lock molecule-lock/role1/stale' "$work/s1/acquire.log"; then
  echo "ok   stale lock removed"
else
  fail "stale lock not removed"; cat "$work/s1/acquire.log"
fi

# Release does not delete a lock that another job holds.
curl -s -X POST "$api/_test/stale/molecule-lock/role1/foreign" > /dev/null
held=$(ref_sha molecule-lock/role1/foreign)
env "${common[@]}" RUNNER_TEMP="$work" LOCK_BRANCH=molecule-lock/role1/foreign LOCK_COMMIT=0000 \
  bash --noprofile --norc -eo pipefail "$work/release.sh" > "$work/foreign.log" 2>&1
[[ "$(ref_sha molecule-lock/role1/foreign)" == "$held" ]] && echo "ok   release leaves another holder's lock" || fail "release deleted another holder's lock"

# Without contents: write the step fails with a hint instead of waiting forever.
mkdir -p "$work/ro"
if env "${common[@]}" GH_TOKEN=readonly RUNNER_TEMP="$work/ro" GITHUB_OUTPUT="$work/ro/output" ROLE=role1 SCENARIO=ro \
  bash --noprofile --norc -eo pipefail "$work/acquire.sh" > "$work/ro/acquire.log" 2>&1; then
  fail "read-only token: expected a failure"
elif grep -q 'HTTP 403' "$work/ro/acquire.log" || grep -q 'contents: write' "$work/ro/acquire.log"; then
  echo "ok   read-only token fails: $(grep -m1 -E 'error|403' "$work/ro/acquire.log")"
else
  fail "read-only token: unexpected output"; cat "$work/ro/acquire.log"
fi

if [[ $failures -ne 0 ]]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "All cases passed"
