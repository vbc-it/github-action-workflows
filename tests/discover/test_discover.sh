#!/usr/bin/env bash
# Unit tests for the "Discover scenarios for each role" step of
# .github/workflows/ansible-collection.yml. The step script is extracted from
# the workflow and run against the fixture collections, like the runner does.
#
# Needs bash 4+, jq, uv and synced fixture environments:
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

"$legacy/.venv/bin/python" -I - .github/workflows/ansible-collection.yml > "$work/discover.sh" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    workflow = yaml.safe_load(f)
steps = workflow["jobs"]["discover"]["steps"]
print(next(s for s in steps if s.get("id") == "discover-scenarios")["run"])
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
  env GITHUB_OUTPUT="$out" ALL_ROLES=false LISTED_ROLES= CHANGED_ROLES= \
    COLLECTION_PATH="$legacy" FAKE_MOLECULE="$work/fake-molecule" "$@" \
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
run_case "glob failed is skipped" "$work/discover-fake.sh" 0 "" \
  CHANGED_ROLES=single_scenario FAKE_OUTPUT="$work/glob-failed.txt" FAKE_RC=1

if [[ $failures -ne 0 ]]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "All cases passed"
