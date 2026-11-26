# github-action-workflows

Reusable GitHub Actions workflows for Ansible collection CI.

## Supported reusable workflows

### `.github/workflows/ansible-collection.yml`

Runs:

- `pre-commit` and `ansible-lint`
- Ansible `sanity` tests (default: stable `2.16`, `2.17`, `2.18`; set `sanity_ansible_versions`), run with `ansible-test sanity --docker default` against the newest PyPI release of each `ansible-core` branch
- Molecule tests for discovered role/scenario combinations

`pre-commit`, `ansible-lint`, `sanity` and Molecule discovery start in parallel once `validate-release` passes, so Molecule doesn't wait for lint and sanity. The `check` job aggregates all of them and gates publishing.

Molecule runs the scenarios of the roles touched by the changeset:

- Files under `roles/<role>/` or `extensions/molecule/<role>/` select that role.
- Other files under `extensions/molecule/` (shared `config.yml`, inventory, `default` scenario), the `molecule_env_file`, and files matching `molecule_all_roles_paths` select all roles.
- `schedule`, `workflow_dispatch` and tag runs, and `force_all_roles: true`, test all roles. Tag runs always test everything so a release is never published on an empty changeset.
- Role and scenario directory names must be plain names (`^[A-Za-z0-9_]+$` for roles); discovery fails on anything else.

Requirements for calling repositories:

- Grant `contents: read`, plus `pull-requests: read` for change detection on pull requests in private and internal repositories. All jobs except `discover` reduce the token to what they need; `discover` uses the token as the caller grants it.
- The collection must have a committed `uv.lock` that matches `pyproject.toml`: dependencies are installed with `uv sync --locked`, which fails instead of re-resolving.
- uv is pinned to `0.13.9` (the newest release whose checksum is built into the pinned `setup-uv`), which takes precedence over a `[tool.uv] required-version` in the caller's `pyproject.toml`.

Inputs:

- `platform` (string, default: `ubuntu-latest`): runner for Molecule jobs (`self-hosted` is supported for your self-hosted runners)
- `collection-path` (string, default: `.`): path to collection root
- `force_all_roles` (boolean, default: `false`): test all roles instead of changed roles only
- `molecule_env_file` (string, default: `''`): optional environment file sourced before Molecule runs
- `publish_to_automationhub` (boolean, default: `false`): when `true`, build and publish collection artifact on tag runs
- `automationhub_url` (string, default: `https://tower.vbc.ac.at/api/galaxy/`): private Automation Hub API endpoint passed to `ansible-galaxy collection publish --server`
- `publish_runner` (string, default: `self-hosted`): runner label for the publish job; Automation Hub is only reachable from internal runners, so use a label that only dedicated release runners carry
- `publish_environment` (string, default: `automationhub`): GitHub environment of the publish job in the calling repository
- `sanity_ansible_versions` (string, default: `'["stable-2.16", "stable-2.17", "stable-2.18"]'`): JSON list of ansible-core branches for the sanity matrix; match it to `requires_ansible` in `meta/runtime.yml`
- `molecule_all_roles_paths` (string, default: `plugins/*`, `requirements.yml`, `tests/requirements.yml`, `pyproject.toml`, `uv.lock`): newline-separated shell patterns, relative to `collection-path`, whose changes run the scenarios of all roles (`*` also matches `/`)
- `molecule_timeout_minutes` (number, default: `120`): timeout for each Molecule scenario job

Secrets:

- `automationhub_token` (optional): required only when `publish_to_automationhub=true` on a tag run

Publishing:

- On tag runs with `publish_to_automationhub: true`, after `check` passes, `build-collection` builds the tarball on the `platform` runner without any secrets. It refuses tags that do not point to a commit on the default branch or whose version differs from the built tarball.
- `publish-automationhub` runs on `publish_runner` in the `publish_environment` environment. It does not check out or install the repository: it downloads the tarball and uploads it with `ansible-galaxy` from a fixed `ansible-core` release. The token is passed through `ansible-galaxy`'s server configuration in the environment, never on the command line.
- Protect the environment in the calling repository: required reviewers, and a deployment tag rule (e.g. `v*`). The `automationhub_token` secret can be stored as an environment secret there.

Tag validation:

- When `publish_to_automationhub=true` and the workflow runs on a tag, CI validates that the tag version matches `galaxy.yml` `version` (supports tag names like `1.2.3` and `v1.2.3`).
- If the versions do not match, the workflow fails before test jobs continue.

Caching:

- `setup-uv` caches uv downloads in the GitHub Actions cache on GitHub-hosted runners. On self-hosted runners uv's cache in `~/.cache/uv` and Galaxy content in `~/.ansible` stay on the runner between jobs, so no GitHub Actions cache is used there.

## How to use

Call the reusable workflow from your repository workflow:

```yaml
name: collection-ci

on:
    pull_request:
    push:
        branches: [main]
        tags: ['*']
    schedule:
        - cron: '0 4 * * 1'
    workflow_dispatch:

# Cancel superseded runs of a pull request; let main, tag and scheduled runs finish.
concurrency:
    group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.run_id }}
    cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
    tests:
        permissions:
            contents: read
            pull-requests: read
        uses: your-org/github-action-workflows/.github/workflows/ansible-collection.yml@main
        secrets:
            automationhub_token: ${{ secrets.AUTOMATIONHUB_TOKEN }}
        with:
            platform: ubuntu-latest
            collection-path: tests/test_collection
            force_all_roles: false
            publish_to_automationhub: false
            automationhub_url: https://automationhub.example.com/api/automation-hub/
```

This workflow is tested in this repo with the `test_collection` sample using `.github/workflows/test-self.yml`.
