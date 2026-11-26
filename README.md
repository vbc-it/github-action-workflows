# github-action-workflows

Reusable GitHub Actions workflows for Ansible collection CI and container image builds.

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
- uv is pinned to `0.13.6` (the newest release whose checksum is built into the pinned `setup-uv`), which takes precedence over a `[tool.uv] required-version` in the caller's `pyproject.toml`.

Inputs:

- `platform` (string, default: `ubuntu-latest`): runner for Molecule jobs (`self-hosted` is supported for your self-hosted runners)
- `collection-path` (string, default: `.`): path to collection root
- `force_all_roles` (boolean, default: `false`): test all roles instead of changed roles only
- `molecule_env_file` (string, default: `''`): optional environment file sourced before Molecule runs
- `publish_to_automationhub` (boolean, default: `false`): when `true`, build and publish collection artifact on tag runs
- `automationhub_url` (string, default: `https://tower.vbc.ac.at/api/galaxy/`): private Automation Hub API endpoint passed to `ansible-galaxy collection publish --server`
- `sanity_ansible_versions` (string, default: `'["stable-2.16", "stable-2.17", "stable-2.18"]'`): JSON list of ansible-core branches for the sanity matrix; match it to `requires_ansible` in `meta/runtime.yml`
- `molecule_all_roles_paths` (string, default: `plugins/*`, `requirements.yml`, `tests/requirements.yml`, `pyproject.toml`, `uv.lock`): newline-separated shell patterns, relative to `collection-path`, whose changes run the scenarios of all roles (`*` also matches `/`)
- `molecule_timeout_minutes` (number, default: `120`): timeout for each Molecule scenario job

Secrets:

- `automationhub_token` (optional): required only when `publish_to_automationhub=true` on a tag run

Tag validation:

- When `publish_to_automationhub=true` and the workflow runs on a tag, CI validates that the tag version matches `galaxy.yml` `version` (supports tag names like `1.2.3` and `v1.2.3`).
- If the versions do not match, the workflow fails before test jobs continue.

Caching:

- `setup-uv` caches uv downloads in the GitHub Actions cache on GitHub-hosted runners. On self-hosted runners uv's cache in `~/.cache/uv` and Galaxy content in `~/.ansible` stay on the runner between jobs, so no GitHub Actions cache is used there.

### `.github/workflows/container-image.yml`

Builds one container image from a Dockerfile with `docker build --pull`, pushes it with `skopeo` and can launch an AAP job template afterwards.

- The image is labelled with `org.opencontainers.image.source` (the calling repository) and `org.opencontainers.image.revision` (the commit).
- `push: false` (the default) only builds. The caller decides when to push, for example `push: ${{ github.event_name == 'push' }}`.
- The pushed reference is `<registry>/<namespace>/<image>:<tag>` for every tag in `tags`. Without `tags`, the branch or tag name of the run is the tag.
- The `deploy` job runs only after a push and only when `aap_job_template` is set. It launches the template with `aap_launch` as request body and fails unless the AAP job ends as `successful`.
- A repository with several images calls the workflow once per image, for example from a matrix.

Requirements:

- The runner needs `docker`, `skopeo`, `curl` and `jq`. `quay.vbc.ac.at` and `tower.vbc.ac.at` need a self-hosted runner.
- Grant `contents: read`.

Inputs:

- `image` (string, required): repository below the namespace, e.g. `netbox` or `galaxy/app`
- `namespace` (string, default: `it`): organization in the registry
- `registry` (string, default: `quay.vbc.ac.at`)
- `registry_username` (string, default: `''`): robot account with write access to the namespace; required when `push: true`
- `context` (string, default: `.`): build context, relative to the repository root
- `dockerfile` (string, default: `Dockerfile`): relative to the repository root
- `build_args` (string, default: `''`): newline-separated `KEY=VALUE` build arguments
- `tags` (string, default: branch or tag name): newline-separated tags to push
- `push` (boolean, default: `false`)
- `platform` (string, default: `self-hosted`): runner to build on
- `aap_job_template` (string, default: `''`): numeric ID of the AAP job template to launch after a push
- `aap_launch` (string, default: `{}`): JSON body of the launch request, e.g. `{"job_tags": "reload", "extra_vars": {"tag": "main"}}`
- `aap_url` (string, default: `https://tower.vbc.ac.at`)
- `aap_timeout_minutes` (number, default: `60`)

Secrets:

- `registry_password` (optional): required when `push: true`
- `aap_username`, `aap_password` (optional): required when `aap_job_template` is set

Example:

```yaml
name: image

on:
    pull_request:
    push:
        branches: [main]
        tags: ['*']

jobs:
    image:
        permissions:
            contents: read
        uses: your-org/github-action-workflows/.github/workflows/container-image.yml@main
        secrets:
            registry_password: ${{ secrets.QUAY_PASSWORD }}
            aap_username: ${{ secrets.AAP_USERNAME }}
            aap_password: ${{ secrets.AAP_PASSWORD }}
        with:
            image: netbox
            registry_username: it+github_pusher
            build_args: |
                NETBOX_VERSION=v4.6.10-5.0.2
            push: ${{ github.event_name == 'push' }}
            aap_job_template: ${{ github.ref_type == 'branch' && '123' || '' }}
            aap_launch: '{"job_tags": "reload", "extra_vars": {"app_generic_image_tag": "main"}}'
```

The self-test builds `tests/container_image` without pushing.

## How to use

Call the `ansible-collection` workflow from your repository workflow:

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
