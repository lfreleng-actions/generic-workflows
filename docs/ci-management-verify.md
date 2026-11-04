<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

<!-- markdownlint-disable MD013 -->

# CI management verify reusable workflow

`.github/workflows/ci-management-verify.yaml` verifies a change to a
ci-management repository: it runs the change's pre-commit hooks, and
generates its Jenkins jobs with Jenkins Job Builder (JJB). It replaces
`gerrit-ci-management-verify.yaml`,
`gerrit-compose-ci-management-verify.yaml` and
`composed-ci-management-verify.yaml` in
`lfit/releng-reusable-workflows`.

The workflow follows [`tox-verify.yaml`](tox-verify.md) wherever this
page says nothing different: the same Gerrit inputs, ref resolution,
hardening inputs and checkout token handling.
Its merge counterpart, which pushes the jobs to Jenkins once a change
merges, is [`ci-management-merge.yaml`](ci-management-merge.md).

## Job graph

```text
[gerrit] ──► plan ──► Lint
                 └──► JJB
```

- `gerrit` runs in Gerrit mode alone (`gerrit_refspec` set). It checks
  the Gerrit inputs and resolves the ref to check out, with the same
  script as the `gerrit` job in `change-isolation.yaml`.
- `plan` validates the inputs. It checks nothing out.
- `Lint` hardens the runner, checks the change out, drops any
  persisted token, and runs every hook in
  `<path_prefix>/.pre-commit-config.yaml` through
  `lfreleng-actions/standalone-linting-action`, with
  `no_checkout: 'true'` and `run_all_hooks: 'true'`, and
  `cache_hooks: 'false'` in Gerrit mode.
- `JJB` hardens the runner, checks the change out with its
  submodules, drops any persisted token, and runs
  `lfreleng-actions/jjb-action` with `mode: test`, which generates the
  job XML for `<path_prefix>/<jjb_path>` and fails on a tree JJB
  cannot expand. The step summary reports the job count.

The two legs run in parallel, and each reports its own result. The
workflow has no `concurrency` block, casts no vote and holds no SSH
key: the caller owns all three. The example carries the recommended
concurrency group, one per change: the workflow, the Gerrit project,
branch and Change-Id (the run ID when that is empty), with
`cancel-in-progress: false`. A repeat dispatch for one change waits
for the run in flight rather than cancelling it: cancelling a run
cannot retract a vote it has already sent over SSH, and the
example's `vote` job runs under `always()`, so that vote could then
land after the new run's `prepare` clear. GitHub keeps one pending
run per group and replaces a pending one with a newer. A run
cancelled by hand or by the platform still votes its conclusion.

## Inputs

| Input                                  | Default                   | Purpose                                                                                      |
| -------------------------------------- | ------------------------- | -------------------------------------------------------------------------------------------- |
| `path_prefix`                          | `.`                       | Root of the ci-management tree: holds `.pre-commit-config.yaml`, and JJB runs from it        |
| `jjb_path`                             | `jjb`                     | JJB tree, relative to `path_prefix`, read recursively                                        |
| `repository`                           | caller                    | Repository to check out (`owner/name`)                                                       |
| `ref`                                  | triggering commit         | Branch, tag or SHA to check out in GitHub mode                                               |
| `gerrit_refspec`                       | empty                     | Gerrit refspec of the change; setting it selects Gerrit mode                                 |
| `gerrit_project`                       | empty                     | Gerrit project; required in Gerrit mode                                                      |
| `gerrit_branch`                        | empty                     | Target branch, short (`master`) or full (`refs/meta/config`); required in Gerrit mode        |
| `gerrit_url`                           | `vars.GERRIT_URL`         | Gerrit server URL; required in Gerrit mode                                                   |
| `runs_on`                              | `ubuntu-latest`           | Runner label for every job; a Linux runner harden-runner supports                            |
| `timeout_minutes`                      | `30`                      | Timeout for each of the `Lint` and `JJB` jobs                                                |
| `harden_runner_egress`                 | `block`                   | `block` or `audit`                                                                           |
| `harden_runner_allowlist`              | organisation list, pinned | Allow-list for the `Lint` and `JJB` jobs, in `harden-runner-block-action` coordinate grammar |
| `harden_runner_supplemental_allowlist` | empty                     | Extra allow-list merged with the baseline, for project-specific hosts                        |
| `harden_runner_supplemental_unpinned`  | `false`                   | Follow the supplemental list at its default branch; same organisation alone                  |
| `harden_runner_extra_endpoints`        | empty                     | Inline `host:port` endpoints added to the allow-list; a short-term fix                       |

The `harden_runner_*` inputs are common to every reusable workflow
here; [Egress allow-list](../README.md#egress-allow-list) describes
them once, with examples.

| Secret  | Purpose                                                                                               |
| ------- | ----------------------------------------------------------------------------------------------------- |
| `token` | Token to check out `repository`; defaults to `GITHUB_TOKEN`, which reads the calling repository alone |

The workflow publishes no outputs.

The `plan` job fails the run, naming the input without echoing its
value, when `path_prefix` or `jjb_path`:

- is empty or absolute;
- holds a `..` segment, or starts with `-`;
- holds whitespace, Unicode whitespace such as U+00A0 included, or a
  control character (C0, DEL, or C1 from U+0080 to U+009F).

It also rejects a `harden_runner_egress` other than `block` or
`audit`, and a supplemental allow-list without a baseline. These are
the rules `jjb-action` applies to its own path inputs, checked here
before either leg starts.

## Repository layout

Every consumer keeps `lfit/releng-global-jjb` as a submodule at its
repository root, linked into its JJB tree:

```text
ci-management/
├── .pre-commit-config.yaml
├── global-jjb/            (submodule)
└── jjb/
    ├── global-jjb -> ../global-jjb/jjb
    └── <project>/...
```

The `JJB` leg checks submodules out, so the link resolves. JJB reads a
linked directory, but not the directories below it.

## Credentials go first

Both legs act on content that the change under review controls. The
`Lint` leg runs whatever hooks the change's own
`.pre-commit-config.yaml` names, and the `JJB` leg parses a tree the
change wrote, through YAML tags that read further files from the
checkout. Neither leg may hold a token that content could reach.

In GitHub mode each leg checks out with `actions/checkout` and
`persist-credentials: false` (`JJB` adds `submodules: true`), so no
token remains after the checkout.

In Gerrit mode each leg checks out with
`lfreleng-actions/checkout-gerrit-change-action`, which persists its
token and has no input to stop it. `actions/checkout` v7.0.1, which
that action runs, writes the token to a `git-credentials-*.config`
file under `RUNNER_TEMP`, and points `.git/config` at it with
`includeIf` entries. With submodules it adds the same entries to every
submodule's own configuration under `.git/modules`. So, before
anything else runs, the `Remove checkout credentials` step:

- finds the superproject's git directory and every submodule's,
  nested ones included;
- deletes each credentials file and the `includeIf` entries that name
  one, and any `http.<url>.extraheader` older releases set directly;
- then reads each repository's effective configuration, includes and
  all, and fails the leg if git would still send a token anywhere.

It never prints a value. The step is the one `tox-verify.yaml` runs,
which now covers submodules too.

When the mirror cannot serve the change, the checkout step now names
the mirror, its state and who can act, instead of a bare `couldn't
find remote ref`. The diagnosis never changes the leg's result. The
`delay: '0s'` it may cite comes from this workflow, which fixes it
and has no input for it. See
[When the mirror is the problem](change-isolation.md#when-the-mirror-is-the-problem).

The `Lint` leg passes no `github_token` to
`standalone-linting-action`: the hooks are the change's own code, and
a hook that calls the GitHub API runs without a token.

In Gerrit mode the `Lint` leg also passes `cache_hooks: 'false'`, so
`standalone-linting-action` (v0.10.1 or later) restores and saves
neither prek's hook environments nor `setup-uv`'s cache: both caches
are off. gerrit_to_platform dispatches a Gerrit verify on the default
branch, and the default branch's cache scope is one that every later
run of the repository, trusted ones included, can restore from.
Either cache, saved by a run of an unmerged change's hooks, would let
that change plant code those trusted runs execute. Pull-request runs
in GitHub mode cache in their own scope and keep the default.

## Network egress

Every job starts with `step-security/harden-runner` v2.22.3, in `block`
mode unless `harden_runner_egress` is `audit`.

- `gerrit` and `plan` talk to GitHub alone, and allow
  `github.com:443` and nothing else.
- `Lint` and `JJB` load the shared organisation allow-list through
  `harden-runner-block-action`, merged with
  `harden_runner_supplemental_allowlist` when set. The hooks fetch
  their environments, `jjb-action` installs Python and JJB's locked
  packages, and the submodule comes from wherever `.gitmodules` points,
  for these consumers, their Gerrit server: hosts the list carries. The
  `Lint` leg alone writes the allow-list summary; both legs load the
  same list.

## Testing

`tests/test-ci-management-verify-plan.sh` extracts the `gerrit`,
`plan` and credential-removal scripts from between their
`BEGIN`/`END` markers and runs them offline:

- accepted and rejected `path_prefix`, `jjb_path` and hardening
  inputs, most of them rejections;
- the Gerrit refs `master` and `refs/meta/config`, and two
  rejections;
- a superproject it builds at run time with a submodule holding a
  nested one, each configured the way `actions/checkout` v7.0.1 leaves
  it, and a token hidden in a form the step does not know, which must
  fail the leg.

It also fails when the `gerrit` script drifts from
`change-isolation.yaml`'s, when either leg's credential removal
drifts from the other's or from `tox-verify.yaml`'s, when a `run:`
block interpolates an expression, when a harden-runner pin is not
v2.22.3, when the `Lint` leg's `cache_hooks` stops being `'false'`
in Gerrit mode, and when the example's concurrency group stops being
one per change or stops queueing in progress. The
`ci-management-verify-fixtures` prek hook runs it whenever any of the
workflows it reads, the example or the script changes.

`.github/workflows/ci-management-verify-action.yaml` calls the
workflow on this repository's own pull requests, in block mode,
against the fixture in `tests/fixtures/ci-management/`:

- `JJB` generates the fixture's one project from its one job
  template. The fixture holds a sibling `global-jjb/` but no
  `jjb/global-jjb` link, so its project uses no template from
  `global-jjb/`: this repository cannot commit the link, and the
  reusable's `JJB` leg cannot create one at run time. `jjb-action`'s
  own suite covers the linked layout: its `testing.yaml` at v0.0.1
  links `global-jjb` at run time, generates through the link, and
  expects a failure once it removes the link. The reusable hands its
  checkout to `jjb-action` unchanged.
- `Lint` runs the fixture's `check-yaml` and `actionlint` hooks. prek
  runs them from the git top level, so they check every YAML file and
  workflow in this repository rather than the fixture alone.

No run here covers Gerrit mode: a Gerrit checkout, a submodule fetched
through it, the credential removal against a real persisted token, or
a vote. The offline fixtures cover the ref resolution and the
credential removal.

## Migration

| Legacy input                                                       | This workflow                                                                                                                                                 |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| nine `GERRIT_*` inputs                                             | `repository`, `ref`, `gerrit_refspec`, `gerrit_project`, `gerrit_branch`, `gerrit_url`, as in `tox-verify.yaml`; `gerrit_url` falls back to `vars.GERRIT_URL` |
| `vars.JJB_VERSION` (fallback 6.4.3)                                | none: the `jjb-action` release pins JJB                                                                                                                       |
| (none)                                                             | `path_prefix` (`.`), `jjb_path` (`jjb`)                                                                                                                       |
| comment-&#111;nly                                                  | dropped: advisory or voting is the caller's choice of account                                                                                                 |
| `ENV_VARS`, `ENV_SECRETS`, `CLOUDS_ENV_2XB64`, `CLOUDS_YAML_2XB64` | dropped: packer is out of scope                                                                                                                               |
| `GERRIT_SSH_PRIVKEY`                                               | dropped: the caller votes                                                                                                                                     |

Copy [`examples/ci-management/gerrit-ci-management-verify.yaml`](../examples/ci-management/gerrit-ci-management-verify.yaml)
and pin a release **commit** SHA of this repository. Keep `gerrit`
and `verify` in the copy's file name, and keep `required` out of it,
or gerrit_to_platform will not dispatch it.

Every consumer:

- adds the `actionlint-py` hook to its `.pre-commit-config.yaml`,
  pinned to a commit as this repository's own configuration pins it.

Per consumer:

- **ONAP** and **O-RAN-SC** replace their callers of
  `gerrit-ci-management-verify.yaml`, and move from `@main` to a
  release SHA.
- **ONAP** also deletes `gerrit-ci-management-novote-verify.yaml`,
  which fails at startup on every run.
- **lfit** replaces its call to
  `gerrit-compose-ci-management-verify.yaml` (v0.2.26), and stops
  passing the SSH secret, which this workflow does not take.
- **FD.io** and **akraino** retire their callers, with their owners'
  agreement.

Behaviour that changes on migration:

- JJB moves to the version the `jjb-action` release pins, today
  6.5.0, from `vars.JJB_VERSION` or 6.4.3.
- Every job runs behind harden-runner in block mode; a project that
  reaches a host off the organisation list needs a supplemental list,
  or `harden_runner_egress: audit` while it finds out which.
- The concurrency group and the vote move into the caller. Keep the
  example's `cancel-in-progress: false`, so a cancelled run's vote
  cannot land after its replacement's clear.
