<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

<!-- markdownlint-disable MD013 -->

# Tox verify reusable workflow

`.github/workflows/tox-verify.yaml` runs a project's tox environments,
one job per environment, against a Gerrit change or a GitHub commit.
It replaces `gerrit-compose-required-tox-verify.yaml` in
`lfit/releng-reusable-workflows`.

It lives here rather than in `python-workflows` because tox serves
more than Python across the estate: documentation builds in Java
projects, JJB verification in `releng-global-jjb`, and pre-commit
environments.

## Job graph

```text
[gerrit] ──► plan ──► Tox: <env 1>   (matrix, one leg per env)
                 ├──► Tox: <env 2>
                 └──► Tox: <env n>
```

- `gerrit` runs in Gerrit mode alone (`gerrit_refspec` set). It checks
  the Gerrit inputs and resolves the ref to check out, with the same
  script as the `gerrit` job in `change-isolation.yaml`.
- `plan` validates the inputs and emits the matrix. It checks nothing
  out.
- `Tox: <env>` runs once per entry in `tox_envs`, with
  `fail-fast: false`, so every environment reports. Each leg hardens
  the runner, checks the change out, drops any persisted token and
  runs `lfreleng-actions/tox-run-action` for its one environment.

The workflow has no `concurrency` block: concurrency belongs to the
caller, which knows the change it runs for. The examples carry the
recommended group.

## Inputs

| Input                                  | Default                   | Purpose                                                                               |
| -------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------- |
| `tox_envs`                             | (required)                | JSON array of tox environment names; see below                                        |
| `path_prefix`                          | `.`                       | Directory holding `tox.ini`, relative to the repository root                          |
| `python_version`                       | `3.12`                    | Python version for tox; `python_version_file` overrides it                            |
| `python_version_file`                  | empty                     | File holding the Python version, relative to the repository root                      |
| `parallel`                             | `auto`                    | tox `--parallel` value: `auto`, `all` or a positive number; empty omits `--parallel`  |
| `pre_build_script`                     | empty                     | Repository-relative path of an executable `.sh` script to run before tox              |
| `repository`                           | caller                    | Repository to check out (`owner/name`)                                                |
| `ref`                                  | triggering commit         | Branch, tag or SHA to check out in GitHub mode                                        |
| `gerrit_refspec`                       | empty                     | Gerrit refspec of the change; setting it selects Gerrit mode                          |
| `gerrit_project`                       | empty                     | Gerrit project; required in Gerrit mode                                               |
| `gerrit_branch`                        | empty                     | Target branch, short (`master`) or full (`refs/meta/config`); required in Gerrit mode |
| `gerrit_url`                           | `vars.GERRIT_URL`         | Gerrit server URL; required in Gerrit mode                                            |
| `runs_on`                              | `ubuntu-latest`           | Runner label for every job                                                            |
| `timeout_minutes`                      | `30`                      | Timeout for each tox job                                                              |
| `harden_runner_egress`                 | `block`                   | `block` or `audit`                                                                    |
| `harden_runner_allowlist`              | organisation list, pinned | Allow-list for the tox jobs, in `harden-runner-block-action` coordinate grammar       |
| `harden_runner_supplemental_allowlist` | empty                     | Extra allow-list merged with the baseline, for project-specific hosts                 |

| Secret  | Purpose                                                                                               |
| ------- | ----------------------------------------------------------------------------------------------------- |
| `token` | Token to check out `repository`; defaults to `GITHUB_TOKEN`, which reads the calling repository alone |

The workflow publishes no outputs. Each leg's result is its own job
status.

### Python version

`tox-run-action` hands `python-version` and `python-version-file` to
`actions/setup-python`. Given both, `setup-python` uses
`python-version`, ignores the file and warns. So that a file can
override the `3.12` default, this workflow leaves `python-version`
empty whenever `python_version_file` names a file. Name the file
relative to the repository root, not to `path_prefix`: `setup-python`
reads it from the workspace.

### Runner

`runs_on` must name a Linux runner that harden-runner supports, and
that has `pipx` installed: `tox-run-action` runs tox through
`pipx run` and fails without it. GitHub-hosted Ubuntu runners have
`pipx`; a self-hosted runner must provide it.

## `tox_envs`

A JSON array of strings, one matrix leg each. Each value reaches
`tox-run-action`'s `tox-envs` input, which the action splits on
whitespace into `tox -e <value>`. The `plan` job rejects the run, and
names the problem without echoing the value, when `tox_envs`:

- is not valid JSON, or not an array;
- is empty, or holds more than 256 entries, GitHub's matrix limit;
- holds an entry that is not a string, is empty, duplicates an earlier
  entry, or is longer than 100 characters;
- holds an entry with whitespace, a control character (C0, DEL, or C1
  from U+0080 to U+009F), a comma, or a leading `-`;
- holds an entry with any character outside letters, digits, `.`, `_`,
  `+` and `-`.

A comma would make one leg run more than one environment, and a leading
`-` would read as a tox option. Generative factors such as
`py{311,312}` need a comma, so the plan rejects them: list each
environment instead.

The plan also rejects a `parallel` value other than `auto`, `all`, a
positive number or empty; a `path_prefix` that is absolute, holds a
`..` segment or a character outside letters, digits, `.`, `_` and `-`;
a `harden_runner_egress` other than `block` or `audit`; and a
supplemental allow-list without a baseline.

## Gerrit checkout

With `gerrit_refspec` set, each leg checks the change out with
`lfreleng-actions/checkout-gerrit-change-action`, with `repository`
set to `inputs.repository` or the caller. The action's own default
names the caller, not the project under review.

The action persists its checkout token in the git configuration and
has no input to stop it. The pre-build script and tox run the change's
own code, so a `Remove checkout credentials` step deletes the token
first, and fails the leg if git would still send one. The GitHub-mode
checkout never persists it.

`gerrit_branch` is the branch short name (`master`) or a full ref
(`refs/meta/config`). The `gerrit` job uses a value starting with
`refs/` as given and prefixes any other with `refs/heads/`. It rejects
whitespace, control characters, `..`, `//`, a leading `-`, and a
trailing `/` or `.lock`, as `change-isolation.yaml` does. The legacy
workflow prefixed every value, which broke changes against
`refs/meta/config`.

Without `gerrit_refspec`, each leg checks out `ref`, or the commit
that triggered the run, with `actions/checkout`.

## Network egress

Each tox leg runs the project's own environments, and `pip` and the
project's dependency tools download whatever the project lists. No
per-job host list can name those in advance, so the legs use the
shared organisation allow-list, as `docs-workflows`'
`docs-build.yaml` does:

- `harden-runner-block-action` loads `harden_runner_allowlist`,
  pinned to the organisation list in `lfreleng-actions/.github`,
  merged with `harden_runner_supplemental_allowlist` when set. A
  supplemental list the caller names but that does not exist fails the
  leg at once rather than at the first blocked connection.
- `step-security/harden-runner` then runs in `block` mode, or `audit`
  when `harden_runner_egress` says so, with that list.
- Matrix leg 0 alone writes the allow-list summary; the list is the
  same in every leg.

The organisation list carries PyPI and the LF project Gerrit servers.
A Gerrit server not on it, or a package index or download host the
project's environments need, belongs in a supplemental list.

The `gerrit` and `plan` jobs talk to GitHub alone. They run
harden-runner directly with `github.com:443` and nothing else, as
`change-isolation.yaml` does.

Every job pins harden-runner v2.22.3, which fixes a DNS bypass on
`westus2` hosted runners that makes block-mode jobs fail or hang.

## Pre-build scripts

`pre_build_script` names a `.sh` file in the repository. The workflow
passes it to `tox-run-action` through `with:` and nothing else;
the action refuses a path with `..`, a file outside the workspace
(symlinks resolved), a name without the `.sh` suffix, and a file
without the executable bit.

This workflow drops the legacy workflow's three pre-build inputs:

| Legacy input            | Why it went                                                                      |
| ----------------------- | -------------------------------------------------------------------------------- |
| `PRE_BUILD_SCRIPT`      | Interpolated caller input straight into a `run:` block                           |
| `PRE_BUILD_SCRIPT_URL`  | Downloaded a script from a mutable branch and executed it                        |
| `PRE_BUILD_SCRIPT_PATH` | Its step also interpolated the input into a `run:` block; now `pre_build_script` |

No input of this workflow reaches a `run:` block by expression
interpolation; variable data travels through `env:`.

Three repositories set `PRE_BUILD_SCRIPT_URL`: `o-ran-sc/ric-app-ad`,
`ric-app-lp` and `ric-app-qp`. All three point at
`jjb/shell/install-deb-rmr.sh` in `o-ran-sc/ci-management`, which reads
`rmr-version.yaml` from the repository and installs RMR packages from
`packagecloud.io`, a host on the organisation allow-list. To migrate,
each repository commits a copy of that script, for example as
`scripts/install-deb-rmr.sh` with the executable bit set, and passes
`pre_build_script: scripts/install-deb-rmr.sh`.

## Voting and private changes

The reusable casts no vote and never receives a Gerrit SSH key. The
Gerrit example, `examples/tox-verify/gerrit-tox-verify.yaml`, clears
the vote before the call and sets it from the run's conclusion after.
It first asks `gerrit-change-visible-action` whether the voting
account can read the change, and skips every later job for a private
one, as the change isolation example does; see
[`change-isolation.md`](change-isolation.md#private-changes-and-the-visibility-gate).

## Migration

Seventeen repositories call the legacy workflow: ten in `o-ran-sc`,
five in `opendaylight`, `akraino-edge-stack/iec` and
`lfit/releng-global-jjb`.

| Legacy input                                                                                                                               | This workflow                                        |
| ------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------- |
| `TOX_ENVS`                                                                                                                                 | `tox_envs` (same JSON array, now validated)          |
| `TOX_DIR`                                                                                                                                  | `path_prefix`                                        |
| `PYTHON_VERSION`                                                                                                                           | `python_version` (same `3.12` default)               |
| (none)                                                                                                                                     | `python_version_file`                                |
| `PARALLEL`                                                                                                                                 | `parallel` (default `auto`; empty omits it)          |
| `PRE_BUILD_SCRIPT_PATH`                                                                                                                    | `pre_build_script`                                   |
| `PRE_BUILD_SCRIPT`, `PRE_BUILD_SCRIPT_URL`                                                                                                 | dropped; see [Pre-build scripts](#pre-build-scripts) |
| `GERRIT_REFSPEC`                                                                                                                           | `gerrit_refspec`                                     |
| `GERRIT_PROJECT`                                                                                                                           | `gerrit_project`                                     |
| `GERRIT_BRANCH`                                                                                                                            | `gerrit_branch`                                      |
| `TARGET_REPO`                                                                                                                              | `repository`                                         |
| `GERRIT_CHANGE_ID`, `GERRIT_CHANGE_NUMBER`, `GERRIT_CHANGE_URL`, `GERRIT_EVENT_TYPE`, `GERRIT_PATCHSET_NUMBER`, `GERRIT_PATCHSET_REVISION` | dropped: the legacy workflow never used them         |
| `vars.GERRIT_URL`                                                                                                                          | unchanged fallback, or pass `gerrit_url`             |

Behaviour that changes on migration:

- `parallel` defaults to `auto`, the `tox-run-action` default, where
  the legacy `PARALLEL` was empty unless set. With one environment per
  leg, `--parallel` has nothing to run alongside; pass `parallel: ''`
  to omit the flag.
- `tox-run-action` moves from v0.1.3 to v0.2.0, which takes the same
  inputs and requires the pre-build script to sit inside the
  workspace.
- The concurrency group moves from the reusable into the caller.
- Every job runs behind harden-runner in block mode; a project that
  reaches a host off the organisation list needs a supplemental list,
  or `harden_runner_egress: audit` while it finds out which.

While migrating, also:

- replace an `@main` reference, as all ten `o-ran-sc` callers use,
  or an older tag, as the `opendaylight` callers use, with a release
  **commit** SHA of this repository;
- replace `lfit/gerrit-review-action` with
  `lfreleng-actions/gerrit-review-action`;
- replace the archived `technote-space/workflow-conclusion-action`
  with `im-open/workflow-conclusion`.

[`examples/tox-verify/`](../examples/tox-verify/) holds two callers:
`gerrit-tox-verify.yaml` for Gerrit projects and
`github-tox-verify.yaml` for pull requests. Their basenames differ from
every other example's on purpose: `.github/zizmor.yml` scopes its
ignores by basename and line number.

## Testing

`tests/test-tox-verify-plan.sh` extracts the `gerrit`, `plan` and
credential-removal scripts from between their `BEGIN`/`END` markers
and runs them offline: the refs `master`, `release/1.2` and
`refs/meta/config`, the rejected `gerrit_branch` forms, accepted and
rejected `tox_envs`, `parallel`, `path_prefix` and hardening inputs,
and a checkout configured with a persisted token. It also fails when
the `gerrit` script drifts from `change-isolation.yaml`'s, when a
`run:` block interpolates an expression, and when a harden-runner pin
is not v2.22.3. The `tox-verify-fixtures` prek hook runs it whenever
either workflow or the script changes.

`.github/workflows/tox-verify-action.yaml` calls the workflow on this
repository's own pull requests, in block mode, against the fixture in
`tests/fixtures/tox/`. A pull request cannot run Gerrit mode, so no
run here covers a Gerrit checkout, the `refs/meta/config` case
included, or a real vote; the offline fixtures cover the ref
resolution.
