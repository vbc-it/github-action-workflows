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
        with:
            platform: ubuntu-latest
            collection-path: tests/test_collection
            force_all_roles: false
```

This workflow is tested in this repo with the `test_collection` sample using `.github/workflows/test-self.yml`.
