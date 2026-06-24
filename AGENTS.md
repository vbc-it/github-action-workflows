# AGENTS.md

Guidance for coding agents working in this repository.

## Scope

- This repository provides reusable GitHub Actions workflows for Ansible collection CI.
- Primary workflow under development is [ansible-collection](.github/workflows/ansible-collection.yml).
- Self-test entrypoint is [test-self](.github/workflows/test-self.yml).

## First Files To Read

- [README](README.md) for workflow purpose and public inputs.
- [ansible-collection workflow](.github/workflows/ansible-collection.yml) for source-of-truth job behavior.
- [legacy test fixture README](tests/ansible_collections/legacy_collection/README.md) for fixture intent.

## Local Validation Commands

Run from repository root unless noted otherwise.

- Pre-commit checks:
  - `pre-commit run -a`
- Workflow fixture dependencies (legacy):
  - `cd tests/ansible_collections/legacy_collection && uv sync --dev`
- Workflow fixture dependencies (native):
  - `cd tests/ansible_collections/native_collection && uv sync --dev`
- Molecule scenario discovery (legacy role directory):
  - `cd tests/ansible_collections/legacy_collection/roles/<role> && uv run molecule list -f yaml`
- Molecule scenario discovery (native collection root):
  - `cd tests/ansible_collections/native_collection && uv run molecule list -f yaml`

## Repository Conventions

- Keep reusable workflow behavior centralized in [ansible-collection workflow](.github/workflows/ansible-collection.yml); avoid duplicating logic in callers.
- Preserve support for both fixture patterns:
  - Legacy layout: role-local `molecule/` folders.
  - Native layout: collection-level `extensions/molecule/` with role/scenario naming.
- Prefer minimal, targeted edits. Do not reformat unrelated YAML blocks.

## Important CI Behavior To Preserve

- Job order: `pre-commit` and `ansible-lint` before `sanity`; `discover` after `sanity`; `molecule` after `discover`.
- Sanity matrix currently includes `stable-2.16`, `stable-2.17`, `stable-2.18`.
- Discovery must continue to:
  - Respect `force_all_roles` and event-based full-run conditions.
  - Handle Molecule "glob failed" as a skip condition, not a hard failure.
  - Deduplicate discovered role/scenario pairs before matrix fan-out.
- Final `check` job is used for branch protection and must aggregate upstream status.

## Common Pitfalls

- In this repo, role-scenario naming differs by collection type:
  - Legacy scenarios are discovered per role path.
  - Native scenarios are discovered from collection root and may be `role/scenario`.
- Molecule execution assumes an activated virtual environment in CI jobs.
- Path handling must remain compatible with the `collection-path` workflow input.

## Change Checklist For Agents

- Update [README](README.md) if workflow inputs/behavior change.
- Keep [test-self workflow](.github/workflows/test-self.yml) aligned with reusable workflow expectations.
- If changing discovery logic, validate both fixture collections:
  - `tests/ansible_collections/legacy_collection`
  - `tests/ansible_collections/native_collection`
- Prefer adding comments only where logic is non-obvious.
