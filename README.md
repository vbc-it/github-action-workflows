# github-action-workflows

Reusable GitHub Actions workflows for Ansible collection CI.

## Supported reusable workflows

### `.github/workflows/ansible-collection.yml`

Runs:

- `pre-commit`
- Ansible `sanity` tests (stable `2.16`, `2.17`, `2.18`)
- Molecule tests for discovered role/scenario combinations

Inputs:

- `platform` (string, default: `ubuntu-latest`): runner for Molecule jobs (`self-hosted` is supported for your self-hosted runners)
- `collection-path` (string, default: `.`): path to collection root
- `force_all_roles` (boolean, default: `false`): test all roles instead of changed roles only
- `molecule_env_file` (string, default: `''`): optional environment file sourced before Molecule runs
- `publish_to_automationhub` (boolean, default: `false`): when `true`, build and publish collection artifact on tag runs
- `automationhub_url` (string, default: `''`): private Automation Hub API endpoint passed to `ansible-galaxy collection publish --server`

Secrets:

- `automationhub_token` (optional): required only when `publish_to_automationhub=true` on a tag run

Tag validation:

- When `publish_to_automationhub=true` and the workflow runs on a tag, CI validates that the tag version matches `galaxy.yml` `version` (supports tag names like `1.2.3` and `v1.2.3`).
- If the versions do not match, the workflow fails before test jobs continue.

## How to use

Call the reusable workflow from your repository workflow:

```yaml
name: collection-ci

on:
    pull_request:
    push:
        branches: [main]

jobs:
    tests:
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
