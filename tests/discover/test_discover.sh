#!/usr/bin/env bash
# Unit tests for the "Discover scenarios for each role", "Select roles from
# changeset" and "Remove checkout credentials" steps of the discover job in
# .github/workflows/ansible-collection.yml. The step scripts are extracted from
# the workflow and run against the fixture collections, like the runner does.
#
# Needs bash 4+ (first in PATH), jq, git, uv and synced fixture environments:
#   (cd tests/ansible_collections/legacy_collection && uv sync --locked --dev)
#   (cd tests/ansible_collections/native_collection && uv sync --locked --dev)
# Run from anywhere: tests/discover/test_discover.sh
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo"
legacy=tests/ansible_collections/legacy_collection
native=tests/ansible_collections/native_collection
unset VIRTUAL_ENV

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Writes discover.sh, changed-roles.sh and remove-credentials.sh to $work.
"$legacy/.venv/bin/python" -I - .github/workflows/ansible-collection.yml "$work" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    workflow = yaml.safe_load(f)
steps = workflow["jobs"]["discover"]["steps"]
for key, value, out in (
    ("id", "discover-scenarios", "discover.sh"),
    ("id", "changed-roles", "changed-roles.sh"),
    ("name", "Remove checkout credentials", "remove-credentials.sh"),
):
    with open(f"{sys.argv[2]}/{out}", "w", encoding="utf-8") as f:
        f.write(next(s for s in steps if s.get(key) == value)["run"])
PY

# Same script with "molecule list" replaced by a stub that prints $FAKE_OUTPUT
# and exits with $FAKE_RC, to test the output parser in isolation.
grep -q 'uv run molecule list -f yaml' "$work/discover.sh"
# shellcheck disable=SC2016  # $FAKE_MOLECULE expands when the copy runs
sed 's#uv run molecule list -f yaml#"$FAKE_MOLECULE"#' "$work/discover.sh" > "$work/discover-fake.sh"
cat > "$work/fake-molecule" <<'SH'
#!/bin/sh
cat "$FAKE_OUTPUT"
exit "${FAKE_RC:-0}"
SH
chmod +x "$work/fake-molecule"

# molecule list output as rich prints it with colours forced.
esc=$'\033'
{
  for s in default second; do
    printf '%s[38;2;248;248;242;48;2;39;40;34m  %s[0m%s[38;2;255;70;137;48;2;39;40;34mScenario Name%s[0m' "$esc" "$esc" "$esc" "$esc"
    printf '%s[38;2;248;248;242;48;2;39;40;34m:%s[0m %s[48;2;39;40;34m%s%s[0m      \r\n' "$esc" "$esc" "$esc" "$s" "$esc"
  done
} > "$work/colour.txt"
printf 'some unexpected output\n' > "$work/garbage.txt"
printf 'CRITICAL Failed to load scenario: glob failed\n' > "$work/glob-failed.txt"

failures=0

# run_case <name> <script> <expected rc: 0|fail> <expected ids> [VAR=value ...]
# ids are "role/scenario" for legacy and the Molecule scenario name for native
# entries, sorted and space-separated.
run_case() {
  local name=$1 script=$2 want_rc=$3 want_ids=$4
  shift 4
  local out="$work/output" log="$work/log" rc=0 ids=""
  : > "$out"
  : > "$work/summary"
  env GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$work/summary" ALL_ROLES=false LISTED_ROLES= CHANGED_ROLES= \
    CHANGED_ALL_ROLES= COLLECTION_PATH="$legacy" FAKE_MOLECULE="$work/fake-molecule" "$@" \
    bash --noprofile --norc -eo pipefail "$script" > "$log" 2>&1 || rc=$?
  if [[ "$want_rc" == fail ]]; then
    if [[ $rc -eq 0 ]]; then
      echo "FAIL $name: expected a failure, got rc=0"; cat "$log"; failures=$((failures + 1)); return
    fi
    echo "ok   $name (failed as expected: $(grep -m1 -E '::error::|Invalid|not' "$log" || tail -n1 "$log"))"
    return
  fi
  if [[ $rc -ne 0 ]]; then
    echo "FAIL $name: rc=$rc"; cat "$log"; failures=$((failures + 1)); return
  fi
  ids=$(sed -n 's/^role_scenarios=//p' "$out" \
    | jq -r '.[] | if .is_native then .scenario else .role + "/" + .scenario end' | sort | xargs)
  if [[ "$ids" != "$want_ids" ]]; then
    echo "FAIL $name: got [$ids], want [$want_ids]"; cat "$log"; failures=$((failures + 1)); return
  fi
  echo "ok   $name"
}

colour_env=(PY_COLORS=1 FORCE_COLOR=1 CLICOLOR_FORCE=1 ANSIBLE_FORCE_COLOR=1 TERM=xterm-256color COLORTERM=truecolor)
legacy_all=(ALL_ROLES=true "LISTED_ROLES=multi_scenario single_scenario")
native_all=(ALL_ROLES=true "LISTED_ROLES=role1 role2" COLLECTION_PATH="$native")

# P12: colour regression and zero-scenario guard.
run_case "legacy, all roles" "$work/discover.sh" 0 \
  "multi_scenario/default multi_scenario/second single_scenario/default" "${legacy_all[@]}"
run_case "legacy, all roles, colour forced" "$work/discover.sh" 0 \
  "multi_scenario/default multi_scenario/second single_scenario/default" "${legacy_all[@]}" "${colour_env[@]}"
run_case "legacy, changed role only" "$work/discover.sh" 0 \
  "single_scenario/default" CHANGED_ROLES=single_scenario
run_case "nothing selected" "$work/discover.sh" 0 ""
run_case "native, all roles, colour forced" "$work/discover.sh" 0 \
  "role1 role2/scenario1 role2/scenario2" "${native_all[@]}" "${colour_env[@]}"
run_case "native, changed role only" "$work/discover.sh" 0 \
  "role2/scenario1 role2/scenario2" COLLECTION_PATH="$native" CHANGED_ROLES=role2
run_case "parser strips ANSI colour codes" "$work/discover-fake.sh" 0 \
  "single_scenario/default single_scenario/second" CHANGED_ROLES=single_scenario FAKE_OUTPUT="$work/colour.txt"
run_case "no parseable scenario fails" "$work/discover-fake.sh" fail "" \
  CHANGED_ROLES=single_scenario FAKE_OUTPUT="$work/garbage.txt"

# Issue #28: glob failed is a skip only without any molecule.yml; native
# scenarios whose top folder is no role run with all roles.
# Copies of the fixtures reuse the synced environments.
uv_env() { echo "UV_PROJECT_ENVIRONMENT=$repo/$1/.venv"; }
mkdir -p "$work/legacy" "$work/native" "$work/native-empty"
cp -R "$legacy/." "$work/legacy/" && rm -rf "$work/legacy/.venv"
mkdir -p "$work/legacy/roles/no_scenario/molecule/resources" "$work/legacy/roles/no_scenario/tasks"
echo '---' > "$work/legacy/roles/no_scenario/molecule/resources/prepare.yml"
echo '---' > "$work/legacy/roles/no_scenario/tasks/main.yml"
cp -R "$native/." "$work/native/" && rm -rf "$work/native/.venv"
mkdir -p "$work/native/extensions/molecule/shared_tests"
cp "$native/extensions/molecule/role1/"*.yml "$work/native/extensions/molecule/shared_tests/"
cp -R "$native/." "$work/native-empty/" && rm -rf "$work/native-empty/.venv"
find "$work/native-empty/extensions/molecule" -name molecule.yml -delete
legacy_copy=(COLLECTION_PATH="$work/legacy" "$(uv_env "$legacy")" UV_OFFLINE=1)
native_copy=(COLLECTION_PATH="$work/native" "$(uv_env "$native")" UV_OFFLINE=1)

run_case "glob failed without molecule.yml is skipped" "$work/discover.sh" 0 \
  "single_scenario/default" "${legacy_copy[@]}" "CHANGED_ROLES=no_scenario single_scenario"
grep -q '^::warning::roles/no_scenario/molecule contains no scenario' "$work/log" \
  || { echo "FAIL glob failed skip: no warning"; failures=$((failures + 1)); }
grep -q 'without a scenario (not tested): no_scenario' "$work/summary" \
  || { echo "FAIL glob failed skip: role missing from the step summary"; failures=$((failures + 1)); }
run_case "glob failed with molecule.yml present fails" "$work/discover-fake.sh" fail "" \
  CHANGED_ROLES=single_scenario FAKE_OUTPUT="$work/glob-failed.txt" FAKE_RC=1
run_case "other molecule list failure fails" "$work/discover-fake.sh" fail "" \
  CHANGED_ROLES=single_scenario FAKE_OUTPUT="$work/garbage.txt" FAKE_RC=1
run_case "native: glob failed without molecule.yml is skipped" "$work/discover.sh" 0 "" \
  ALL_ROLES=true "LISTED_ROLES=role1 role2" COLLECTION_PATH="$work/native-empty" "$(uv_env "$native")" UV_OFFLINE=1
run_case "native: glob failed with molecule.yml present fails" "$work/discover-fake.sh" fail "" \
  "${native_all[@]}" FAKE_OUTPUT="$work/glob-failed.txt" FAKE_RC=1
run_case "native: scenario without role runs with all roles" "$work/discover.sh" 0 \
  "role1 role2/scenario1 role2/scenario2 shared_tests" "${native_copy[@]}" ALL_ROLES=true "LISTED_ROLES=role1 role2"
run_case "native: scenario without role runs when the changeset selects all roles" "$work/discover.sh" 0 \
  "role1 role2/scenario1 role2/scenario2 shared_tests" "${native_copy[@]}" CHANGED_ALL_ROLES=true "CHANGED_ROLES=role1 role2"
run_case "native: scenario without role is not run for a changed role" "$work/discover.sh" 0 \
  "role2/scenario1 role2/scenario2" "${native_copy[@]}" CHANGED_ROLES=role2

# P4: molecule_scenarios.
run_case "scenarios: listed role runs only listed, [] excludes" "$work/discover.sh" 0 \
  "multi_scenario/second" "${legacy_all[@]}" \
  'MOLECULE_SCENARIOS={"multi_scenario": ["second"], "single_scenario": []}'
run_case "scenarios: unlisted role still runs all" "$work/discover.sh" 0 \
  "multi_scenario/default single_scenario/default" "${legacy_all[@]}" \
  'MOLECULE_SCENARIOS={"multi_scenario": ["default"]}'
run_case "scenarios: everything excluded gives an empty matrix" "$work/discover.sh" 0 "" \
  "${legacy_all[@]}" 'MOLECULE_SCENARIOS={"multi_scenario": [], "single_scenario": []}'
run_case "scenarios: empty object changes nothing" "$work/discover.sh" 0 \
  "multi_scenario/default multi_scenario/second single_scenario/default" "${legacy_all[@]}" 'MOLECULE_SCENARIOS={}'
run_case "scenarios: whitespace only means auto-discovery" "$work/discover.sh" 0 \
  "single_scenario/default" CHANGED_ROLES=single_scenario $'MOLECULE_SCENARIOS= \n'
run_case "scenarios: listed scenario not discovered fails" "$work/discover.sh" fail "" \
  "${legacy_all[@]}" 'MOLECULE_SCENARIOS={"multi_scenario": ["default", "missing"]}'
run_case "scenarios: listed role that is not selected is not checked" "$work/discover.sh" 0 \
  "single_scenario/default" CHANGED_ROLES=single_scenario 'MOLECULE_SCENARIOS={"multi_scenario": ["missing"]}'
run_case "scenarios: unknown role fails" "$work/discover.sh" fail "" \
  'MOLECULE_SCENARIOS={"no_such_role": []}'
run_case "scenarios: invalid role name fails" "$work/discover.sh" fail "" \
  'MOLECULE_SCENARIOS={"../x": []}'
run_case "scenarios: not an object fails" "$work/discover.sh" fail "" \
  'MOLECULE_SCENARIOS=["single_scenario"]'
run_case "scenarios: scenario list of non-strings fails" "$work/discover.sh" fail "" \
  'MOLECULE_SCENARIOS={"single_scenario": [1]}'
run_case "scenarios: invalid JSON fails" "$work/discover.sh" fail "" \
  'MOLECULE_SCENARIOS={"single_scenario": [}'
run_case "scenarios: native short and full names" "$work/discover.sh" 0 \
  "role1 role2/scenario2" "${native_all[@]}" \
  'MOLECULE_SCENARIOS={"role1": ["role1"], "role2": ["scenario2"]}'
run_case "scenarios: native full name, other role unlisted" "$work/discover.sh" 0 \
  "role1 role2/scenario1" "${native_all[@]}" 'MOLECULE_SCENARIOS={"role2": ["role2/scenario1"]}'
run_case "scenarios: native [] excludes" "$work/discover.sh" 0 \
  "role2/scenario1 role2/scenario2" "${native_all[@]}" 'MOLECULE_SCENARIOS={"role1": []}'
run_case "scenarios: native missing scenario fails" "$work/discover.sh" fail "" \
  "${native_all[@]}" 'MOLECULE_SCENARIOS={"role2": ["scenario3"]}'

# P6(c): molecule_lock_scenarios is validated in discover.
run_case "lock: list of names accepted" "$work/discover.sh" 0 "single_scenario/default" \
  CHANGED_ROLES=single_scenario 'MOLECULE_LOCK_SCENARIOS=["single_scenario/default"]'
run_case "lock: not a list fails" "$work/discover.sh" fail "" \
  'MOLECULE_LOCK_SCENARIOS={"single_scenario": "default"}'
run_case "lock: invalid JSON fails" "$work/discover.sh" fail "" 'MOLECULE_LOCK_SCENARIOS=["x"'

# Issue #28: a changeset of 3000 files (GitHub API limit) selects all roles.
# changed_roles_case <name> <number of files> <want all_roles> <want role_folders>
changed_roles_case() {
  local name=$1 n=$2 want_all=$3 want_roles=$4 out="$work/output" rc=0 got_all got_roles
  : > "$out"
  env GITHUB_OUTPUT="$out" COLLECTION_PATH="$legacy" MOLECULE_ENV_FILE= ALL_ROLES_PATHS=$'plugins/*\nuv.lock' \
    CHANGED_FILES="$(jq -cn --argjson n "$n" --arg p "$legacy" '["\($p)/roles/single_scenario/tasks/main.yml"] + [range(1; $n) | "docs/\(.).md"]')" \
    bash --noprofile --norc -eo pipefail "$work/changed-roles.sh" > "$work/log" 2>&1 || rc=$?
  got_all=$(sed -n 's/^all_roles=//p' "$out")
  got_roles=$(sed -n 's/^role_folders=//p' "$out" | xargs -n1 | sort | xargs)
  if [[ $rc -ne 0 || "$got_all" != "$want_all" || "$got_roles" != "$want_roles" ]]; then
    echo "FAIL $name: rc=$rc all_roles=[$got_all] role_folders=[$got_roles]"; cat "$work/log"; failures=$((failures + 1)); return
  fi
  echo "ok   $name"
}
changed_roles_case "changeset below the API limit maps files to roles" 2999 false "single_scenario"
changed_roles_case "changeset at the API limit selects all roles" 3000 true "multi_scenario single_scenario"

# Issue #27: credentials as actions/checkout v6+ stores them are removed.
# cred_case <name> <want: removed|fail> [extra setup command] [extra check command]
cred_case() {
  local name=$1 want=$2 setup=${3:-} check=${4:-true} repo_dir="$work/cred-repo" tmp="$work/runner-temp" rc=0 cred left
  rm -rf "$repo_dir" "$tmp"
  mkdir -p "$tmp"
  git init -q "$repo_dir"
  # includeIf.gitdir matches the resolved path (/var -> /private/var on macOS).
  repo_dir=$(cd "$repo_dir" && pwd -P)
  cred="$tmp/git-credentials-0123abcd-4567-89ef-0123-456789abcdef.config"
  git config -f "$cred" http.https://github.com/.extraheader 'AUTHORIZATION: basic c2VjcmV0'
  git -C "$repo_dir" config "includeIf.gitdir:$repo_dir/.git.path" "$cred"
  git -C "$repo_dir" config "includeIf.gitdir:$repo_dir/.git/worktrees/*.path" "$cred"
  git -C "$repo_dir" config includeIf.gitdir:/github/workspace/.git.path "/github/runner_temp/${cred##*/}"
  git -C "$repo_dir" config http.https://github.com/.extraheader 'AUTHORIZATION: basic b2xk'
  git -C "$repo_dir" config core.unrelated keep
  [[ -n "$setup" ]] && (cd "$repo_dir" && eval "$setup")
  if ! git -C "$repo_dir" config --get-regexp '^http\..*\.extraheader$' | grep -q c2VjcmV0; then
    echo "FAIL $name: test setup does not resolve the credentials"; failures=$((failures + 1)); return
  fi
  (cd "$repo_dir" && env RUNNER_TEMP="$tmp" GITHUB_SERVER_URL=https://github.com \
    bash --noprofile --norc -eo pipefail "$work/remove-credentials.sh") > "$work/log" 2>&1 || rc=$?
  if [[ "$want" == fail ]]; then
    if [[ $rc -eq 0 ]]; then
      echo "FAIL $name: expected a failure"; cat "$work/log"; failures=$((failures + 1)); return
    fi
    echo "ok   $name (failed as expected: $(grep -m1 '::error::' "$work/log"))"
    return
  fi
  left=$(git -C "$repo_dir" config --list --show-origin | grep -iE 'extraheader|git-credentials' || true)
  if [[ $rc -ne 0 || -n "$left" || -e "$cred" ]] || ! git -C "$repo_dir" config core.unrelated > /dev/null \
    || ! (cd "$repo_dir" && eval "$check"); then
    echo "FAIL $name: rc=$rc, left: [$left], file exists: $([[ -e "$cred" ]] && echo yes || echo no)"
    cat "$work/log"; failures=$((failures + 1)); return
  fi
  echo "ok   $name"
}
cred_case "credentials: includeIf entries, file and extraheader removed" removed
cred_case "credentials: unrelated includeIf kept" removed \
  "git config includeIf.gitdir:/elsewhere/.git.path /elsewhere/other.config" \
  "git config includeIf.gitdir:/elsewhere/.git.path > /dev/null"
cred_case "credentials: an extraheader from another file fails" fail \
  "git config -f other.config http.https://example.com/.extraheader x && git config include.path \"\$PWD/other.config\""

if [[ $failures -ne 0 ]]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "All cases passed"
