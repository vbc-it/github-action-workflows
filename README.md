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
- `schedule`, `workflow_dispatch` and tag runs, and `force_all_roles: true`, test all roles. Tag runs test everything so a release is never published on an empty changeset; set `test_all_roles_on_tag: false` to test only the changeset on tags.
- Role and scenario directory names must be plain names (`^[A-Za-z0-9_]+$` for roles); discovery fails on anything else.
- Discovery runs `molecule list` with colours off (`NO_COLOR=1`, `PY_COLORS=0`, `FORCE_COLOR`, `CLICOLOR_FORCE` and `ANSIBLE_FORCE_COLOR` unset) and strips ANSI codes before parsing. It fails when a selected role has a `molecule/` directory (or `extensions/molecule/` exists) and `molecule list` succeeds but no scenario can be parsed, instead of passing with no tests run. A role whose `molecule/` holds no scenario at all (`glob failed`) is still skipped, and a run that selects no role still skips Molecule.
- Each Molecule job exports `INSTANCE_ID`, the first 16 hex characters of the SHA-1 of `<run_id>-<run_attempt>-<role>-<scenario>`. Use it in `molecule.yml` (e.g. `name: instance-${INSTANCE_ID:-local}`) or for external names so parallel jobs on one host don't collide. It is set before `molecule_env_file` is sourced, so that file can override it.

Requirements for calling repositories:

- Grant the minimum token permissions listed below.
- The collection must have a committed `uv.lock` that matches `pyproject.toml`: dependencies are installed with `uv sync --locked`, which fails instead of re-resolving.
- uv is pinned to `0.13.9` (the newest release whose checksum is built into the pinned `setup-uv`), which takes precedence over a `[tool.uv] required-version` in the caller's `pyproject.toml`.

Minimum caller permissions:

| Caller repository | `permissions:` on the calling job |
|---|---|
| public | `contents: read` |
| internal or private | `contents: read` and `pull-requests: read` |

- `pull-requests: read` is needed because `discover` reads the changed files of a pull request through the GitHub API (`dorny/paths-filter`). Without it, `discover` fails on `pull_request` events with "Resource not accessible by integration".
- The reusable workflow requests no permissions of its own: a called workflow can never get more than its caller grants, and a job that asked for more would stop the whole run from starting. Every job except `discover` reduces the token further to what it needs (`contents: read` or nothing); `discover` uses the token as the caller grants it.
- If the caller sets no `permissions:`, the repository or organisation default for `GITHUB_TOKEN` applies. Declare them explicitly so the run does not depend on that setting.

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
- `molecule_scenarios` (string, default: `''`): JSON object that selects scenarios per role, like the `roleConfigs` of the Jenkins pipeline, e.g. `'{"ssh": ["default", "hostbased"], "certificate": []}'`. A listed role runs only the listed scenarios and `[]` excludes the role. Unlike Jenkins, a role that is not listed still runs all its scenarios. Discovery fails when the JSON is invalid, a key is not a role under `roles/`, or a listed scenario of a selected role was not discovered. For native layouts a scenario can be given as Molecule names it (`role2/scenario1`) or without the role prefix (`scenario1`). Empty (the default) runs every discovered scenario
- `molecule_max_parallel` (number, default: `0`): maximum number of Molecule scenario jobs that run at the same time (the matrix `max-parallel`); `0` means no limit
- `test_all_roles_on_tag` (boolean, default: `true`): tag runs test all roles, like `force_all_roles`. With `false`, tag runs select roles from the changeset like branch pushes, so a release can be published with no Molecule scenario run

Secrets:

- `automationhub_token` (optional): required only when `publish_to_automationhub=true` on a tag run

Publishing:

- On tag runs with `publish_to_automationhub: true`, after `check` passes, `build-collection` builds the tarball on a fresh GitHub-hosted runner without any secrets, using a fixed `ansible-core` release; no code from the repository runs. It refuses tags that do not point to a commit on the default branch or whose version differs from the built tarball.
- `publish-automationhub` runs on `publish_runner` in the `publish_environment` environment. It does not check out or install the repository: it downloads the tarball by artifact ID and uploads it with the same fixed `ansible-galaxy`, in a clean environment (temporary `HOME`, minimal `PATH`, empty Ansible config, freshly downloaded Python). The token is passed through `ansible-galaxy`'s server configuration in the environment, never on the command line.
- The environment is the real release gate. In the calling repository, give it required reviewers and a deployment tag rule (e.g. `v*`), and store the token there as an environment secret named `AUTOMATIONHUB_TOKEN`: inside the publish job it takes precedence over a repository or organisation secret passed by the caller, and other branches cannot read it.
- Point `publish_runner` at dedicated, ideally ephemeral, release runners: a runner that also executes test jobs can be tampered with by code from any branch.

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
            # Optional: mirror Jenkins roleConfigs (unlisted roles still run all scenarios)
            molecule_scenarios: '{"ssh": ["default", "hostbased"], "certificate": []}'
            molecule_max_parallel: 4
```

This workflow is tested in this repo with the `test_collection` sample using `.github/workflows/test-self.yml`.
