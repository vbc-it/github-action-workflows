# github-action-workflows

Reusable GitHub Actions workflows for Ansible collection CI and container image builds.

## Supported reusable workflows

### `.github/workflows/ansible-collection.yml`

Runs:

- `pre-commit` and `ansible-lint`
- Ansible `sanity` tests (default: stable `2.16`, `2.17`, `2.18`; set `sanity_ansible_versions`), run with `ansible-test sanity --docker default` against the newest PyPI release of each `ansible-core` branch
- Molecule tests for discovered role/scenario combinations
- `build`: `ansible-galaxy collection build` on every run (`build_collection`), uploaded as the artifact `collection-<namespace>-<name>-<version>`

`pre-commit`, `ansible-lint`, `sanity` and `changes` start in parallel once `validate-release` passes; `discover` follows `changes`, so Molecule doesn't wait for lint and sanity. `changes` finds the changeset and selects the roles; `discover` runs `molecule list` for them and plans the Molecule jobs. The `check` job aggregates all of them and gates publishing.

Molecule runs the scenarios of the roles touched by the changeset:

- Files under `roles/<role>/` or `extensions/molecule/<role>/` select that role.
- Other files under `extensions/molecule/` (shared `config.yml`, inventory, `default` scenario), the `molecule_env_file`, and files matching `molecule_all_roles_paths` select all roles.
- A changeset of 3,000 files or more selects all roles: the GitHub API lists at most 3,000 files of a pull request, so the list may be incomplete.
- `schedule`, `workflow_dispatch`, `merge_group` and tag runs, and `force_all_roles: true`, test all roles. Tag runs test everything so a release is never published on an empty changeset; set `test_all_roles_on_tag: false` to test only the changeset on tags. Merge queue runs have no usable changeset (the base is the queue head itself).
- Native scenarios whose first path element is not a role under `roles/` (e.g. `extensions/molecule/integration/`) run whenever all roles are tested; a change to their files selects all roles.
- Role and scenario directory names must be plain names (`^[A-Za-z0-9_]+$` for roles); discovery fails on anything else.
- Discovery runs `molecule list` with colours off (`NO_COLOR=1`, `PY_COLORS=0`, `FORCE_COLOR`, `CLICOLOR_FORCE` and `ANSIBLE_FORCE_COLOR` unset) and strips ANSI codes before parsing. It fails when a selected role has a `molecule/` directory (or `extensions/molecule/` exists) and `molecule list` succeeds but no scenario can be parsed, instead of passing with no tests run. When `molecule list` fails, discovery fails too, except for Molecule's `glob failed` error when there really is no `molecule.yml` (`roles/<role>/molecule/*/molecule.yml`, or anywhere under `extensions/molecule/`): that role or the native scenarios are skipped with a warning. A run that selects no role still skips Molecule. Selected roles without any scenario and skipped directories are listed in a notice and in the job summary of `discover`.
- `changes` checks out with credentials, because `dorny/paths-filter` runs `git fetch` on push events, and runs no code of the calling repository: it only reads file names and lists `roles/`. `discover`, which runs `uv sync` and `molecule list` on the branch under test, gets `contents: read` only and checks out without credentials.
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
| any, with `molecule_lock_scenarios` | also `contents: write` instead of `contents: read`, and `actions: read` |

- `pull-requests: read` is needed because `changes` reads the changed files of a pull request through the GitHub API (`dorny/paths-filter`). Without it, `changes` fails on `pull_request` events with "Resource not accessible by integration".
- The reusable workflow requests no permissions of its own: a called workflow can never get more than its caller grants, and a job that asked for more would stop the whole run from starting. GitHub checks this when the run starts, before any `if:`, so it also applies to jobs that would be skipped. Every job except `changes`, `molecule-lock` and `molecule-unlock` reduces the token further to what it needs (`contents: read` or nothing); in particular `discover` and both Molecule jobs, which run the code under test, always get `contents: read` only. `changes` uses the token as the caller grants it (see `pull-requests: read` above) and runs no code from the repository. `molecule-lock` and `molecule-unlock` also use it as granted, so that only callers that use `molecule_lock_scenarios` need to grant `contents: write` and `actions: read`; they run on a GitHub-hosted runner, check out nothing and run no code from the repository.
- Grant `contents: write` only on the calling job that sets `molecule_lock_scenarios`. Only `changes`, `molecule-lock` and `molecule-unlock` hold it, and none of them runs code from the repository.
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
- `molecule_max_parallel` (number, default: `0`): maximum number of Molecule scenario jobs that run at the same time (the matrix `max-parallel`); `0` means no limit. Scenarios in `molecule_lock_scenarios` run in a second matrix job (`molecule-locked`) with its own limit, so up to twice this many can run at once
- `molecule_lock_scenarios` (string, default: `'[]'`): JSON list of scenarios that must never run at the same time, across all runs of the repository, e.g. `'["certificate/create"]'`. Use `<role>/<scenario>` for legacy layouts and the Molecule scenario name (as printed by `discover`) for native layouts. Listed scenarios run in the `molecule-locked` matrix job instead of `molecule`, between two jobs that hold the write token and run no repository code:
  - `molecule-lock` takes a mutex for each listed scenario of the run: it creates the branch `molecule-lock/<role>/<scenario>` (`/` in native names becomes `__`) through the GitHub API, which fails while another run holds it. It takes the locks one by one in name order, so two runs never wait for each other's locks. Waiting runs poll every 15 to 30 seconds and are never cancelled; the order among several waiters is not guaranteed. Waiting counts towards `molecule_timeout_minutes` (the timeout of `molecule-lock`).
  - `molecule-locked` runs the listed scenarios with `contents: read`. Its first step checks that the run still holds the lock and fails otherwise: use "Re-run all jobs" for a run with locks, since "Re-run failed jobs" does not take the locks again.
  - `molecule-unlock` deletes the branches after `molecule-locked`, also when it fails or the run is cancelled. All locks of a run are held from `molecule-lock` until `molecule-unlock`, including while `molecule-locked` waits for a runner.
  - A lock whose holder run has completed without releasing it is removed by the next waiter (it reads the run's status, hence `actions: read`); a lock of a run that is still in progress is never removed. Delete the branch by hand to free a lock sooner. Branches not created by this workflow are never removed.
  - Needs `contents: write` and `actions: read` (see above), GitHub-hosted `ubuntu-latest` runners for the two lock jobs (they use runner minutes while waiting), and branch rules that let `GITHUB_TOKEN` create and delete `molecule-lock/*` branches. Branches created with `GITHUB_TOKEN` do not trigger workflows. Other scenarios, including other scenarios of the same role, take no lock and do not wait. Prefer deriving shared external names from `INSTANCE_ID` where possible
- `molecule_secret_scenarios` (string, default: `'["*"]'`): JSON list of scenarios (same names as `molecule_lock_scenarios`) whose Molecule step receives `op_service_account_token` and `galaxy_server_token`; `"*"` means every scenario. The jobs of other scenarios get neither secret (the op CLI is not installed either). The default keeps the behaviour of earlier versions; list only the scenarios that need the secrets (see "Secrets in Molecule jobs")
- `galaxy_token_servers` (string, default: `published rh_certified community staging`): space-separated Galaxy server names (as in `[galaxy] server_list`) whose `ANSIBLE_GALAXY_SERVER_<NAME>_TOKEN` is set to `galaxy_server_token`. List only servers that point to the server the token belongs to; the default keeps the behaviour of earlier versions
- `molecule_base_config` (string, default: `''`): repository-relative path of a Molecule base config, passed as `molecule --base-config` to `molecule dependency` and `molecule test`. It replaces Molecule's default base config (`.config/molecule/config.yml`, or `extensions/molecule/config.yml` in native layouts), so include that content if you need it
- `ansible_config` (string, default: `''`): repository-relative path of an `ansible.cfg`, exported as `ANSIBLE_CONFIG` before `molecule_env_file` is sourced. It applies to `molecule dependency` (`ansible-galaxy`, e.g. private Galaxy or Automation Hub servers) and to commands outside Molecule's provisioner; the playbooks Molecule runs use the `ansible.cfg` Molecule generates, so use `provisioner.config_options` in `molecule.yml` or the base config for those
- `build_collection` (boolean, default: `true`): build the collection tarball on every run with a fixed `ansible-core` release (no code from the repository runs) and upload it as an artifact; `check` needs this job, so a broken `galaxy.yml` or `build_ignore` fails CI. Set `false` to skip it
- `test_reports` (boolean, default: `true`): each Molecule job sets `PYTEST_ADDOPTS=--junit-xml=...` (appended after `molecule_env_file`, so the testinfra verifier writes a report; other verifiers ignore it), uploads the report as `junit-molecule-<role>-<scenario>-...` even when the job fails, and adds a short table to the job summary. Each sanity job uploads `tests/output/junit/` from `ansible-test sanity --junit` as `junit-sanity-<namespace>-<name>-<branch>-...`. Nothing is published as a check run, so no `checks: write` is needed. If a scenario's verifier sets its own `--junit-xml`, the flag that pytest reads last wins
- `test_all_roles_on_tag` (boolean, default: `true`): tag runs test all roles, like `force_all_roles`. With `false`, tag runs select roles from the changeset like branch pushes, so a release can be published with no Molecule scenario run. Because of that, a tag run with `publish_to_automationhub: true` and `test_all_roles_on_tag: false` (and `force_all_roles: false`, not `workflow_dispatch`) fails in `validate-release` unless `allow_untested_publish` is `true`
- `allow_untested_publish` (boolean, default: `false`): accept publishing on tag runs that do not test all roles (see `test_all_roles_on_tag`). `validate-release` then emits a warning and a job summary note instead of failing

Secrets:

- `automationhub_token` (optional): required only when `publish_to_automationhub=true` on a tag run
- `op_service_account_token` (optional): 1Password service account token, exported as `OP_SERVICE_ACCOUNT_TOKEN` in the Molecule step of the `molecule_secret_scenarios` only, and only when set (for the `community.general.onepassword` lookups). When it is set, the Molecule job installs the 1Password CLI `op` 2.35.0 with `1password/install-cli-action`, which downloads it into the runner's tool cache (no root needed), checks its GPG signature and puts it on `PATH`; the runner needs `gpg` and `unzip`
- `galaxy_server_token` (optional): exported as `ANSIBLE_GALAXY_SERVER_<NAME>_TOKEN` for each name in `galaxy_token_servers` (by default `PUBLISHED`, `RH_CERTIFIED`, `COMMUNITY` and `STAGING`) in the Molecule step of the `molecule_secret_scenarios` only, and only when set. The server list and URLs come from `ansible_config` or `molecule_env_file`
- Secrets are exported before `molecule_env_file` is sourced, so that file can override them. Pass them explicitly (or with `secrets: inherit`). GitHub does not pass secrets to `pull_request` runs from forks; do not work around that, since a fork's code would then receive them. Only pass them to runners you trust with them

Secrets in Molecule jobs:

- Molecule runs code from the branch under test: playbooks, `molecule.yml`, `molecule_env_file`, `ansible.cfg` and the build backends `uv sync` runs. Anyone who can push a branch to the calling repository can read every secret the Molecule step receives, and on persistent self-hosted runners code can outlive the job. Treat the secrets as readable by all of them.
- Use a 1Password service account with read access to a dedicated test-only vault, never one that can read production vaults.
- Use a read-only Galaxy or Automation Hub token for `galaxy_server_token`, never the token used for `automationhub_token` or any other token that can publish collections.
- The token is sent to every server named in `galaxy_token_servers` whose URL the Ansible config sets. If your config maps one of those names to a public server (e.g. `community` to `https://galaxy.ansible.com/`), the token goes there: set `galaxy_token_servers` to the internal servers only.
- Set `molecule_secret_scenarios` to the scenarios that need the secrets, and pass the secrets only on the events that need them (e.g. `${{ github.event_name != 'pull_request' && secrets.OP_SERVICE_ACCOUNT_TOKEN || '' }}`).
- Secrets are only in the environment of the Molecule step, never in `GITHUB_ENV` or on a command line.

Publishing:

- On tag runs with `publish_to_automationhub: true`, after `check` passes, `build-collection` builds the tarball on a fresh GitHub-hosted runner without any secrets, using a fixed `ansible-core` release; no code from the repository runs. It refuses tags that do not point to a commit on the default branch or whose version differs from the built tarball.
- `publish-automationhub` runs on `publish_runner` in the `publish_environment` environment. It does not check out or install the repository: it downloads the tarball by artifact ID and uploads it with the same fixed `ansible-galaxy`, in a clean environment (temporary `HOME`, minimal `PATH`, empty Ansible config, freshly downloaded Python). The token is passed through `ansible-galaxy`'s server configuration in the environment, never on the command line.
- The environment is the real release gate. In the calling repository, give it required reviewers and a deployment tag rule (e.g. `v*`), and store the token there as an environment secret named `AUTOMATIONHUB_TOKEN`: inside the publish job it takes precedence over a repository or organisation secret passed by the caller, and other branches cannot read it.
- Point `publish_runner` at dedicated, ideally ephemeral, release runners: a runner that also executes test jobs can be tampered with by code from any branch.

Tag validation:

- When `publish_to_automationhub=true` and the workflow runs on a tag, CI validates that the tag version matches `galaxy.yml` `version` (supports tag names like `1.2.3` and `v1.2.3`).
- If the versions do not match, the workflow fails before test jobs continue.
- It also fails when Molecule would not test all roles (`test_all_roles_on_tag: false` without `force_all_roles`), unless `allow_untested_publish: true`.

Caching:

- `setup-uv` caches uv downloads in the GitHub Actions cache on GitHub-hosted runners. On self-hosted runners uv's cache in `~/.cache/uv` and Galaxy content in `~/.ansible` stay on the runner between jobs, so no GitHub Actions cache is used there.

### `.github/workflows/container-image.yml`

Builds one container image from a Dockerfile with `docker build --pull`, pushes it with `skopeo` and can launch an AAP job template afterwards.

- The image is labelled with `org.opencontainers.image.source` (the calling repository) and `org.opencontainers.image.revision` (the commit).
- `push: false` (the default) only builds. The caller decides when to push, for example `push: ${{ github.event_name == 'push' }}`.
- The pushed reference is `<registry>/<namespace>/<image>:<tag>` for every tag in `tags`. Without `tags`, the branch or tag name of the run is the tag.
- A build that pushes uses `--no-cache`, so it cannot reuse layers that another job on a shared docker daemon put in the build cache. `push: false` builds keep the cache.
- The image is pushed by the image ID that `docker build --iidfile` wrote, not by its local tag, which another job on the same daemon could retag. The first tag is pushed from the daemon and every further tag is copied from that manifest digest in the registry; the job fails if a tag ends up with another digest. The digest is written to the job summary and returned as the `digest` and `image_ref` outputs.
- The `deploy` job runs only after a push and only when `aap_job_template` is set. It launches the template with `aap_launch` as request body and fails unless the AAP job ends as `successful`. curl reads the AAP credentials as a config from a pipe, so they never appear in process arguments on the runner host.
- A repository with several images calls the workflow once per image, for example from a matrix.

Requirements:

- The runner needs `docker`, `skopeo`, `curl` and `jq`. `quay.vbc.ac.at` and `tower.vbc.ac.at` need a self-hosted runner.
- Grant `contents: read`.

Inputs:

- `image` (string, required): repository below the namespace, e.g. `netbox` or `galaxy/app`
- `namespace` (string, default: `it`): organization in the registry
- `registry` (string, default: `quay.vbc.ac.at`)
- `registry_username` (string, default: `''`): robot account with write access to the namespace; required when `push: true`
- `ref` (string, default: ref of the run): branch, tag or commit of the calling repository to build, e.g. an existing git tag chosen in a `workflow_dispatch` run
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

Outputs:

- `digest`: manifest digest of the pushed image, e.g. `sha256:...`; empty when `push: false`
- `image_ref`: `<registry>/<namespace>/<image>@<digest>`; empty when `push: false`

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
            # write and actions: read only because molecule_lock_scenarios is used; otherwise contents: read
            contents: write
            actions: read
            pull-requests: read
        uses: your-org/github-action-workflows/.github/workflows/ansible-collection.yml@main
        secrets:
            automationhub_token: ${{ secrets.AUTOMATIONHUB_TOKEN }}
            # Optional: for onepassword lookups and private Galaxy servers in Molecule
            op_service_account_token: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
            galaxy_server_token: ${{ secrets.GALAXY_SERVER_TOKEN }}
        with:
            platform: ubuntu-latest
            collection-path: tests/test_collection
            force_all_roles: false
            publish_to_automationhub: false
            automationhub_url: https://automationhub.example.com/api/automation-hub/
            # Optional: mirror Jenkins roleConfigs (unlisted roles still run all scenarios)
            molecule_scenarios: '{"ssh": ["default", "hostbased"], "certificate": []}'
            molecule_max_parallel: 4
            molecule_lock_scenarios: '["certificate/create"]'
            # Only these scenarios get op_service_account_token and galaxy_server_token
            molecule_secret_scenarios: '["certificate/create", "ssh/default"]'
            galaxy_token_servers: published
            molecule_base_config: .config/molecule/ci.yml
            ansible_config: .config/ansible.cfg
            # Defaults: build the tarball and upload JUnit reports on every run
            build_collection: true
            test_reports: true
```

This workflow is tested in this repo with the `test_collection` sample using `.github/workflows/test-self.yml`.
