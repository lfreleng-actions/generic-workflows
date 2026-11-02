<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 🚀 generic-workflows

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/generic-workflows) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![pre-commit.ci status badge]][pre-commit.ci results page] [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/generic-workflows/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/generic-workflows)
<!-- prettier-ignore-end -->

Shared, reusable GitHub Actions workflows that projects run from a small
**thin caller** workflow. A calling repository keeps a short workflow
that delegates to a reusable workflow here, which helps to keep the
pipeline logic and security posture consistent across repositories and
projects.

## Release reusable workflow

[`.github/workflows/release.yaml`](.github/workflows/release.yaml) is a
tag-driven (Model A) release workflow. A thin `release.yaml` caller in
each repository runs on tag pushes and delegates to it; the reusable
checks the pushed tag against a configurable release-gating policy and
then promotes the matching draft GitHub release. A caller replaces a
per-repository release workflow with a single delegating job.

The gates default to a policy that prevents faulty, immutable
releases — for example a stale tag created long ago, or a tag pointing
at an outdated commit:

<!-- markdownlint-disable MD013 -->

| Gate               | Input                | Default                | Effect                                                                                      |
| ------------------ | -------------------- | ---------------------- | ------------------------------------------------------------------------------------------- |
| Version scheme     | `require_type`       | `semver`               | Tag must match `semver`, `calver`, `both`, or `none` to disable                             |
| Signature          | `require_signed`     | `ssh,gpg-unverifiable` | Tag must carry an accepted signature; empty disables                                        |
| GitHub key         | `require_github`     | `true`                 | Signing key registered on a GitHub account                                                  |
| Gerrit key         | `require_gerrit`     | `false`                | Signing key registered on Gerrit                                                            |
| Key owner          | `require_owner`      | `''`                   | Restrict signer to given GitHub username(s)/email(s)                                        |
| No pre-release     | `reject_development` | `true`                 | Reject alpha/rc/dev/snapshot tags                                                           |
| Increment          | `enforce_increment`  | `true`                 | Tag must exceed the highest existing comparable tag                                         |
| Branch containment | `require_branch`     | `''`                   | Tag commit must be reachable from a branch; empty uses the default branch, `false` disables |
| Recency            | `require_recent`     | `true`                 | Tag must be recent; `true` is a 3-minute window, or a minute count, `false` disables        |
| Latest commit      | `require_latest`     | `true`                 | Tag must point at the current tip of the target branch                                      |

<!-- markdownlint-enable MD013 -->

Copy the appropriate caller from
[`examples/release/`](examples/release/) into your project's
`.github/workflows/` directory as `release.yaml`, delete the
`tag-push.yaml` it replaces, and pin the `uses:` ref to a
`generic-workflows` release SHA:

```yaml
---
name: 'Release on Tag Push 🚀'

# yamllint disable-line rule:truthy
on:
  push:
    tags:
      - '**'

permissions: {}

concurrency:
  group: '${{ github.workflow }}-${{ github.ref }}'
  cancel-in-progress: false

jobs:
  release:
    name: 'Release'
    permissions:
      contents: write
    # Pin a real generic-workflows release SHA in place of <SHA>.
    uses: lfreleng-actions/generic-workflows/.github/workflows/release.yaml@<SHA>
```

- `examples/release/github.yaml` — GitHub-native projects.
- `examples/release/gerrit.yaml` — projects where Gerrit is the source
  of truth (the release tag replicates from Gerrit to the GitHub mirror
  and fires this tag-push).

All inputs are optional and default to the gating policy above. See
[`docs/release.md`](docs/release.md) for the full input/output reference
and the job graph.

## Semantic pull request reusable workflow

[`.github/workflows/semantic-pull-request.yaml`](.github/workflows/semantic-pull-request.yaml)
checks that a pull request title follows the Conventional Commits
convention, using the organisation's capitalised type vocabulary. A
thin `semantic-pull-request.yaml` caller in each repository runs on
pull request events and delegates to it. The workflow migrated from
`lfit/releng-reusable-workflows`, which it replaces.

On top of a bare call to
[`amannn/action-semantic-pull-request`](https://github.com/amannn/action-semantic-pull-request)
it adds two rules the action cannot express: a narrow exception for
Dependabot's truncated single-commit subjects, and an opt-in check
that no commit declares a breaking change the title does not.

Dependabot shortens a long commit subject by deleting the
`from <old> to <new>` version fragment, and sometimes the directory
and group context after it, while the pull request title keeps them,
so the two differ and the exact single-commit match fails on a bump
nobody can fix without rewriting Dependabot's commit. The gate step
recognises that specific deletion — one contiguous span, on whitespace
boundaries, reading `from <old> to <new>` where either value may be a
multi-token version range, optionally with Dependabot's own trailing
context and audit fix marker — and relaxes the match for it alone.
Genuine drift, such as a title updated to a newer version while the
commit subject keeps the old one, still fails.

With `validate_breaking_marker: true`, the job also fails when a
non-merge commit carries a `!` before its colon or a
`BREAKING CHANGE:` footer while the title carries no `!`.
release-drafter's autolabeler reads the title alone, so such a change
would otherwise ship as a minor release.

<!-- markdownlint-disable MD013 -->

| Input                                     | Type      | Default              | Effect                                               |
| ----------------------------------------- | --------- | -------------------- | ---------------------------------------------------- |
| `types`                                   | `string`  | 11 capitalised types | Newline-separated allowed Conventional Commit types  |
| `scopes` / `disallow_scopes`              | `string`  | `''`                 | Newline-separated scope allow-list and deny-list     |
| `require_scope`                           | `boolean` | `false`              | Require every title to carry a scope                 |
| `subject_pattern`                         | `string`  | `''`                 | Regex the subject must match                         |
| `ignore_labels`                           | `string`  | `''`                 | Newline-separated labels that skip validation        |
| `validate_single_commit`                  | `boolean` | `true`               | Check the message on single-commit pull requests     |
| `validate_single_commit_matches_pr_title` | `boolean` | `true`               | Require the single commit subject to match the title |
| `dependabot_relax`                        | `boolean` | `true`               | Allow the Dependabot version-fragment exception      |
| `validate_breaking_marker`                | `boolean` | `false`              | Fail on a breaking commit the title does not declare |

<!-- markdownlint-enable MD013 -->

Copy the caller from
[`examples/semantic-pull-request/`](examples/semantic-pull-request/)
into your project's `.github/workflows/` directory as
`semantic-pull-request.yaml` and pin the `uses:` ref to a
`generic-workflows` release SHA:

```yaml
jobs:
  semantic-pull-request:
    name: 'Semantic Pull Request'
    permissions:
      contents: read
      pull-requests: read  # read PR title and commits (avoids 403)
    # Pin a real generic-workflows release SHA in place of <SHA>.
    uses: lfreleng-actions/generic-workflows/.github/workflows/semantic-pull-request.yaml@<SHA>
```

Keep the file name, job id and job name as the example has them: a
ruleset matches a required status check by name, and renaming any of
them detaches the ruleset from the check it gates.

`pull-requests: read` is not optional. A called workflow cannot hold
more permission than its caller, so the calling job declares the grant
the reusable needs to read the pull request and its commits.

See [`docs/semantic-pull-request.md`](docs/semantic-pull-request.md)
for the full input/output reference, the exception rule in detail, and
the migration notes.

## Linting reusable workflow

[`.github/workflows/linting.yaml`](.github/workflows/linting.yaml)
runs pre-commit hooks with [prek](https://github.com/j178/prek),
standalone from pre-commit.ci. A thin `linting.yaml` caller in each
repository delegates to it on whichever events that repository
supports — pull requests where they exist, and `push` for the Gerrit
mirrors, which never see one. The workflow supersedes
`compose-repo-linting.yaml` in `lfit/releng-reusable-workflows`.

It serves two populations. Repositories with **no** pre-commit.ci at
all — every Gerrit-mirrored project among them — need something to run
their hooks in CI. Repositories that do have it still need the hooks
it cannot run: that sandbox blocks network access at scan time and
caps hook environment size, so hooks such as `gha-workflow-linter` or
`aislop` end up listed under `ci.skip` and never run in CI at all.

With no inputs it runs **every hook** in the configuration, in one
job. Set `ci_skipped: true` to run the `ci.skip` set instead, one
parallel job per hook, or name hooks explicitly with `hooks`.

The default follows the direction it fails in: a repository
without pre-commit.ci has no meaningful `ci.skip`, so defaulting to
that set would report a green check having linted nothing. Defaulting
to everything makes the same mistake duplicated work instead —
visible, and never unsafe.

The design assumes estate-wide adoption from an organisation ruleset,
so a repository with no configuration at all costs close to nothing: a
sparse checkout of the configuration file alone, then any tooling.
When nothing resolves, the lint matrix never instantiates and the run
ends green without blocking a merge.

A green check must always mean "linted, nothing wrong", never "could
not tell". The pre-filter uses a loose substring test by design. An
organisation fallback counts as absent when the `.github` repository
reads back and the file within it does not; any other failure to read
one stops the job rather than reporting success. Where the repository
itself answers 404, nothing distinguishes the two possibilities — no
such repository, or one this token may not read — so the run warns
and carries on, and `org_fallback_required` turns that into a
failure.

<!-- markdownlint-disable MD013 -->

| Input                   | Type      | Default                           | Effect                                               |
| ----------------------- | --------- | --------------------------------- | ---------------------------------------------------- |
| `plan`                  | `string`  | `''`                              | JSON array of lint tasks; exclusive with the scalars |
| `hooks`                 | `string`  | `''`                              | Space/comma separated hook ids to run                |
| `skip_hooks`            | `string`  | `''`                              | Hook ids to EXCLUDE; applies to every task           |
| `ci_skipped`            | `boolean` | `false`                           | Run the `ci.skip` set; exclusive with `hooks`        |
| `config_path`           | `string`  | `''`                              | Repository-relative configuration path               |
| `config_url`            | `string`  | `''`                              | HTTPS configuration URL                              |
| `config_sha256`         | `string`  | `''`                              | Expected digest; requires `config_url`               |
| `org_fallback`          | `boolean` | `true`                            | Fall back to the organisation's `.github` repository |
| `org_fallback_required` | `boolean` | `false`                           | Fail when the fallback lookup reaches no verdict     |
| `org_config_path`       | `string`  | `linting/.pre-commit-config.yaml` | Fallback path inside that repository                 |
| `split_hooks`           | `boolean` | `true`                            | One matrix job per SELECTED hook                     |
| `per_hook_runs`         | `boolean` | `false`                           | One prek invocation per hook; ignored by run-all     |
| `commit_range`          | `string`  | `''`                              | `<from>..<to>`; also runs commit-msg stage hooks     |
| `export_github_token`   | `boolean` | `true`                            | Export the workflow token to hooks on trusted events |
| `runs_on`               | `string`  | `ubuntu-latest`                   | Runner label; harden-runner must support it          |

<!-- markdownlint-enable MD013 -->

The organisation fallback lets an estate keep one central
configuration rather than a copy in every repository. It applies
where a repository has none of its own, and needs the organisation's
`.github` repository to be public.

Copy the caller from [`examples/linting/`](examples/linting/) into
your project's `.github/workflows/` directory as `linting.yaml` and
pin the `uses:` ref to a `generic-workflows` release SHA:

```yaml
jobs:
  linting:
    name: 'Linting'
    permissions:
      contents: read
    # Pin a real generic-workflows release SHA in place of <SHA>.
    uses: lfreleng-actions/generic-workflows/.github/workflows/linting.yaml@<SHA>
```

Trigger on `pull_request`, `push`, `schedule` or `workflow_dispatch`.
The reusable **refuses** `pull_request_target`, which would run
repository-defined tools against fork code under a base-repository
token. It withholds the workflow token on any event whose trust it
cannot establish, including `merge_group` and a `pull_request` from a
fork.

See [`docs/linting.md`](docs/linting.md) for the JSON plan format,
the full input/output reference, the security model and the migration
notes.

## Cache housekeeping reusable workflow

[`.github/workflows/clear-action-cache.yaml`](.github/workflows/clear-action-cache.yaml)
lists a repository's Actions caches, deletes the entries matching the
supplied filters, and then confirms the deletion. A thin
`clear-action-cache.yaml` caller in each repository surfaces the
filters as a `workflow_dispatch` form and delegates to it.

<!-- markdownlint-disable MD013 -->

| Input                                  | Type      | Default           | Effect                                                                          |
| -------------------------------------- | --------- | ----------------- | ------------------------------------------------------------------------------- |
| `key_pattern`                          | `string`  | `''`              | Substring filter applied to cache keys; empty targets every entry               |
| `ref_filter`                           | `string`  | `''`              | Limit deletion to one git ref, such as `refs/heads/main`; empty ignores the ref |
| `dry_run`                              | `boolean` | `false`           | List the matching entries and delete nothing                                    |
| `harden_runner_egress`                 | `string`  | `block`           | Egress policy: `block` or `audit`                                               |
| `harden_runner_allowlist`              | `string`  | `.github` v0.19.0 | Out-of-band allow-list coordinate                                               |
| `harden_runner_supplemental_allowlist` | `string`  | `''`              | Extra allow-list merged with the baseline, for project-specific hosts           |
| `harden_runner_supplemental_unpinned`  | `boolean` | `false`           | Follow the supplemental list at its default branch; same organisation alone     |
| `harden_runner_extra_endpoints`        | `string`  | `''`              | Inline `host:port` endpoints added to the allow-list; a short-term fix          |

<!-- markdownlint-enable MD013 -->

The `harden_runner_*` inputs are common to every reusable workflow
here; [Egress allow-list](#egress-allow-list) describes them.

Deleting nothing succeeds: an empty filter set targets every cache, and a
filter matching no entry exits cleanly.

The verification step asserts that the specific cache IDs captured before
deletion have gone, rather than that no cache still matches the filters.
Other workflows save caches while this one runs, so a match count of zero
is not a condition the job can guarantee. An earlier revision made that
stricter claim and failed runs that had deleted every entry the caller
asked for.

Copy the caller from
[`examples/clear-action-cache/`](examples/clear-action-cache/) into your
project's `.github/workflows/` directory as
`clear-action-cache.yaml` and pin the `uses:` ref to a
`generic-workflows` release SHA:

```yaml
jobs:
  clear-action-cache:
    name: 'Clear Action Cache'
    permissions:
      actions: write  # list and delete repository Actions caches
    # Pin a real generic-workflows release SHA in place of <SHA>.
    uses: lfreleng-actions/generic-workflows/.github/workflows/clear-action-cache.yaml@<SHA>
    with:
      key_pattern: ${{ inputs.key_pattern }}
      ref_filter: ${{ inputs.ref_filter }}
      dry_run: ${{ inputs.dry_run }}
```

The reusable needs `actions: write` to list and delete caches. A called
workflow cannot hold more permission than its caller, so the calling job
declares the grant.

`workflow_call` accepts `boolean`, `string` and `number` inputs but not
`choice`, so `dry_run` takes a boolean. A caller wanting a dispatch menu
keeps a `choice` input of its own and passes the value through.

## Autolabeler reusable workflow

[`.github/workflows/autolabeler.yaml`](.github/workflows/autolabeler.yaml)
applies labels to a pull request from the rules in a release-drafter
configuration. A thin `autolabeler.yaml` caller in each repository runs
on pull request events and delegates to it. The workflow migrated from
`lfit/releng-reusable-workflows`, which it replaces.

Those labels reach further than the pull request view. Release Drafter
reads them later to sort entries into release-note categories and to
resolve the next version, because each category in the organisation's
configuration carries its own `semver-increment`.

<!-- markdownlint-disable MD013 -->

| Input                                  | Type      | Default               | Effect                                                                      |
| -------------------------------------- | --------- | --------------------- | --------------------------------------------------------------------------- |
| `config_name`                          | `string`  | `release-drafter.yml` | Config file resolved under `.github/`                                       |
| `runs_on`                              | `string`  | `ubuntu-latest`       | Runner label; Linux, because harden-runner needs it                         |
| `timeout_minutes`                      | `number`  | `3`                   | Job timeout                                                                 |
| `harden_runner_egress`                 | `string`  | `block`               | Egress policy: `block` or `audit`                                           |
| `harden_runner_allowlist`              | `string`  | `.github` v0.17.1     | Out-of-band allow-list coordinate                                           |
| `harden_runner_supplemental_allowlist` | `string`  | `''`                  | Extra allow-list merged with the baseline, for project-specific hosts       |
| `harden_runner_supplemental_unpinned`  | `boolean` | `false`               | Follow the supplemental list at its default branch; same organisation alone |
| `harden_runner_extra_endpoints`        | `string`  | `''`                  | Inline `host:port` endpoints added to the allow-list; a short-term fix      |

<!-- markdownlint-enable MD013 -->

The `harden_runner_*` inputs are common to every reusable workflow
here; [Egress allow-list](#egress-allow-list) describes them.

A caller must trigger on **both** `pull_request` and
`pull_request_target`, the detail callers get wrong more than any
other. GitHub hands a `pull_request` run a token without write access
when the pull request comes from a fork, so labelling fails there;
`pull_request_target` can label a fork pull request but is the more
dangerous trigger. The reusable's job condition routes each pull
request down a single path, so a fork pull request runs through
`pull_request_target`, a same-repository one through `pull_request`,
and neither runs twice.

Use `types: [opened, synchronize, reopened, edited]` on both. Release
Drafter matches the organisation's autolabeler rules against the pull
request **title**, so without `edited` a title corrected after opening
keeps whatever labels the original earned, and a pull request that
gained its Conventional Commits prefix on the second attempt stays
unlabelled.

That `pull_request_target` usage is safe because the lane checks
nothing out: head-branch source never reaches the runner. zizmor still
raises `dangerous-triggers` on the caller, since a reusable workflow
has no trigger of its own to annotate, so the example silences it on
the `pull_request_target` line.

Copy the caller from [`examples/autolabeler/`](examples/autolabeler/)
into your project's `.github/workflows/` directory as
`autolabeler.yaml` and pin the `uses:` ref to a `generic-workflows`
release SHA:

```yaml
jobs:
  autolabel:
    name: 'Label PR'
    permissions:
      contents: read  # read the release-drafter config from the repo
      pull-requests: write  # apply labels to the pull request
    # Pin a real generic-workflows release SHA in place of <SHA>.
    uses: lfreleng-actions/generic-workflows/.github/workflows/autolabeler.yaml@<SHA>
```

The reusable needs both grants. A called workflow cannot hold more
permission than its caller, so the calling job declares them on the
reusable's behalf.

See [`docs/autolabeler.md`](docs/autolabeler.md) for the full
input/secret reference, the trigger routing table, and the migration
notes.

## Change isolation reusable workflow

[`.github/workflows/change-isolation.yaml`](.github/workflows/change-isolation.yaml)
checks that a change keeps sensitive files apart from everything else.
The caller lists its isolation policies as data in `checks`; each runs
as its own `Isolation: <name>` job, in parallel. When the change
touches `INFO.yaml`, a separate job validates it, and deleting the
file fails. A `report` job folds every result into one outcome. The
workflow replaces the two Gerrit change isolation workflows in
`lfit/releng-reusable-workflows`.

```yaml
jobs:
  change-isolation:
    name: 'Change Isolation'
    permissions:
      contents: read
    # Pin a real generic-workflows release SHA in place of <SHA>.
    uses: lfreleng-actions/generic-workflows/.github/workflows/change-isolation.yaml@<SHA>
    with:
      checks: |
        [
          {"name": "INFO.yaml", "paths": "/INFO.yaml"},
          {"name": "CI/CD", "paths": ".github/**"}
        ]
      gerrit_refspec: ${{ inputs.GERRIT_REFSPEC }}
      gerrit_project: ${{ inputs.GERRIT_PROJECT }}
      gerrit_branch: ${{ inputs.GERRIT_BRANCH }}
```

The reusable casts no vote: the caller clears and sets it around the
call, so the Gerrit SSH key never reaches the reusable. The example
callers first check that the voting account can read the change, and
skip every later job for a private one. Copy a caller from
[`examples/change-isolation/`](examples/change-isolation/), and see
[`docs/change-isolation.md`](docs/change-isolation.md) for the
`checks` format, the inputs and outputs, the rename and deletion
rules, the visibility gate, and the migration from the legacy
workflows.

## Tox verify reusable workflow

[`.github/workflows/tox-verify.yaml`](.github/workflows/tox-verify.yaml)
runs a project's tox environments, one `Tox: <env>` job each, against
a Gerrit change or a GitHub commit. A plan job validates `tox_envs`
first and fails on an empty, duplicate or unsafe entry, or one
`tox-run-action` would reject, as it does a `parallel` value other
than `auto`, `all`, `off`, a number or empty. tox runs on Python 3.11
or newer; a `python_version` older than that still sets up the
requested Python for the environments, with a newer one added for tox
and a warning. Each tox job runs in block mode behind the
organisation egress allow-list. The
workflow replaces `gerrit-compose-required-tox-verify.yaml` in
`lfit/releng-reusable-workflows`.

```yaml
jobs:
  tox-verify:
    name: 'Tox Verify'
    permissions:
      contents: read
    # Pin a real generic-workflows release SHA in place of <SHA>.
    uses: lfreleng-actions/generic-workflows/.github/workflows/tox-verify.yaml@<SHA>
    with:
      tox_envs: '["lint", "docs"]'
      gerrit_refspec: ${{ inputs.GERRIT_REFSPEC }}
      gerrit_project: ${{ inputs.GERRIT_PROJECT }}
      gerrit_branch: ${{ inputs.GERRIT_BRANCH }}
```

As with change isolation, the reusable casts no vote, and the Gerrit
example caller checks that the voting account can read the change
first. Copy a caller from
[`examples/tox-verify/`](examples/tox-verify/), and see
[`docs/tox-verify.md`](docs/tox-verify.md) for the inputs, the
`tox_envs` rules, the Python handling, the egress allow-lists, and
the migration from the legacy workflow, including its dropped inline
and URL pre-build scripts.

## CI management verify reusable workflow

[`.github/workflows/ci-management-verify.yaml`](.github/workflows/ci-management-verify.yaml)
verifies a change to a ci-management repository against a Gerrit
change or a GitHub commit. A `Lint` job runs every hook in the
change's pre-commit configuration, and a `JJB` job checks the change
out with its `global-jjb` submodule and generates the Jenkins jobs
with Jenkins Job Builder in test mode. Both run the change's own
content, so each removes the Gerrit checkout's persisted token, from
every submodule too, before anything else runs. The workflow replaces
the three ci-management verify workflows in
`lfit/releng-reusable-workflows`.

```yaml
jobs:
  ci-management-verify:
    name: 'CI Management Verify'
    permissions:
      contents: read
    # Pin a real generic-workflows release SHA in place of <SHA>.
    uses: lfreleng-actions/generic-workflows/.github/workflows/ci-management-verify.yaml@<SHA>
    with:
      gerrit_refspec: ${{ inputs.GERRIT_REFSPEC }}
      gerrit_project: ${{ inputs.GERRIT_PROJECT }}
      gerrit_branch: ${{ inputs.GERRIT_BRANCH }}
```

As with tox verify, the reusable casts no vote, and the Gerrit example
caller checks that the voting account can read the change first. Copy
the caller from
[`examples/ci-management/`](examples/ci-management/), and see
[`docs/ci-management-verify.md`](docs/ci-management-verify.md) for the
inputs, the credential handling, and the migration of each consumer.

## CI management merge reusable workflow

[`.github/workflows/ci-management-merge.yaml`](.github/workflows/ci-management-merge.yaml)
pushes a ci-management repository's Jenkins jobs to Jenkins after a
change merges. A plan job validates every input and decides whether
to deploy: a merge to `deploy_branch` deploys, and a merge to any
other branch succeeds without touching Jenkins. The `Update` job
waits until the GitHub mirror's branch holds the merged revision,
failing after about five minutes rather than deploying a tree without
it, checks out the exact commit that passed with its submodules, and
runs Jenkins Job Builder in update mode. The workflow replaces
`gerrit-ci-management-merge.yaml` in `lfit/releng-reusable-workflows`.

```yaml
jobs:
  ci-management-merge:
    name: 'CI Management Merge'
    permissions:
      contents: read
    # Pin a real generic-workflows release SHA in place of <SHA>.
    uses: lfreleng-actions/generic-workflows/.github/workflows/ci-management-merge.yaml@<SHA>
    with:
      gerrit_branch: ${{ inputs.GERRIT_BRANCH }}
      merged_revision: ${{ inputs.GERRIT_PATCHSET_REVISION }}
      deploy_branch: 'master'
      jenkins_url: ${{ vars.JENKINS_URL }}
      jenkins_user: ${{ vars.JOBBUILDER_PROD_USR }}
    secrets:
      jenkins_password: ${{ secrets.JOBBUILDER_PROD_PSW }}
```

The reusable posts no comment and sets no concurrency group: the
Gerrit example caller comments on the change, and keys the group of
deploy-branch merges to the repository so two updates never overlap.
This repository has no self-caller for it, since a pull request has
no Jenkins to update.
Copy the caller from
[`examples/ci-management/`](examples/ci-management/), and see
[`docs/ci-management-merge.md`](docs/ci-management-merge.md) for the
inputs, the deploy-branch rule, the ancestry check, and the migration
of each consumer.

## Egress allow-list

Every reusable workflow here that loads its egress allow-list through
[`harden-runner-block-action`](https://github.com/lfreleng-actions/harden-runner-block-action)
takes the same five inputs, and passes them to every block-action step
it runs: `autolabeler.yaml`, `ci-management-merge.yaml`,
`ci-management-verify.yaml`, `clear-action-cache.yaml`, `linting.yaml`,
`release.yaml`, `semantic-pull-request.yaml` and `tox-verify.yaml`.
Each workflow's own reference lists them and links here. Jobs that
talk to GitHub alone, such as the `gerrit` and `plan` jobs, use a
fixed `github.com:443` list instead and take none of them.

<!-- markdownlint-disable MD013 -->

| Input                                  | Type      | Default                             | Passed to block-action as                                    |
| -------------------------------------- | --------- | ----------------------------------- | ------------------------------------------------------------ |
| `harden_runner_egress`                 | `string`  | `block` (`audit` in `linting.yaml`) | harden-runner's `egress-policy`                              |
| `harden_runner_allowlist`              | `string`  | the organisation list, pinned       | `config`                                                     |
| `harden_runner_supplemental_allowlist` | `string`  | `''`                                | `supplemental_config`, with `supplemental_required` when set |
| `harden_runner_supplemental_unpinned`  | `boolean` | `false`                             | `supplemental_unpinned`                                      |
| `harden_runner_extra_endpoints`        | `string`  | `''`                                | `extra_endpoints`                                            |

<!-- markdownlint-enable MD013 -->

`tests/test-harden-runner-inputs.sh` fails when a workflow drops one
of these inputs, changes its type or default, passes it in another
form, or lets a block-action step carry on past a missing named list.
The set thus stays the same across every `*-workflows` repository.

### A supplemental list of your own organisation

The organisation list covers the hosts every project needs. A project
that reaches hosts of its own, such as ONAP's `registry.nordix.org`,
names a supplemental list, which the action merges with the baseline
in the same coordinate grammar. An organisation that keeps its list in
its own `.github` repository can follow it at the default branch
rather than a pinned commit, so a host added there takes effect on the
next run without a pin bump in every caller:

```yaml
    with:
      harden_runner_supplemental_allowlist: 'onap//'
      harden_runner_supplemental_unpinned: true
```

`onap//` names the `onap` organisation's `.github` repository with no
file path, so the action searches that repository, at its default
branch, for the organisation's list. From an `onap` repository it
tries these files in order, and the first that exists wins:

1. `.github/harden-runner/onap/allow_list.txt`, the organisation's
   own list;
2. `.github/harden-runner/allow_list.txt`, the repository-wide
   default;
3. `.github/harden-runner/<org>/allow_list.txt`, when a single
   organisation directory carries that file (the sole-org fallback;
   two or more such directories match nothing).

Putting the list at the first path keeps the search unambiguous. When
none of the three exists, the job fails, because the workflows require
a supplemental list a caller names (see
[A missing list fails the job](#a-missing-list-fails-the-job)). The
*Search / fallback chain* section of the action's README describes the
search in full.

The action allows an unpinned list from the caller's own
organisation alone, so `onap//` unpinned works from an `onap`
repository and nowhere else.

### A list in another organisation

A supplemental list from any other organisation must carry a pin,
`<org>//<path>@<commit SHA>`, and `harden_runner_supplemental_unpinned`
stays `false`. The action refuses to follow another organisation's
default branch: a push there would otherwise change what your runners
may reach.

### A missing list fails the job

Whenever a caller names `harden_runner_supplemental_allowlist`, the
workflows also pass `supplemental_required: 'true'`. A caller naming a list
depends on it, so a list the action cannot find fails the job at the
block-action step, before anything runs, rather than at the first
blocked connection. This holds under `audit` too: `linting.yaml`, whose
default is `audit`, tolerates a failure to load the allow-list when
the caller names no supplemental list, and at no other time.

### Inline endpoints, a short-term fix

`harden_runner_extra_endpoints` adds `host:port` endpoints to the
allow-list inline, for example while a supplemental list waits for a
review:

```yaml
    with:
      harden_runner_extra_endpoints: 'registry.nordix.org:443'
```

Treat it as a stopgap. Endpoints passed inline live in one caller, so
every other caller that needs the host fails until it copies them;
the lasting fix is to add the host to the organisation's list or to a
supplemental list. The action validates the endpoints before it
fetches anything, and reports any the list already carries as
redundant. The *Inline extra endpoints* section of the action's README
gives the accepted format.

### Audit trail for an unpinned list

An unpinned list can change between two runs of the same commit.
`harden-runner-block-action` records which list it read and the
commit it resolved in its `supplemental_source` and `supplemental_sha`
outputs, which together say which revision of the list a given run
allowed.

## Caller filenames

A consuming repository names its callers after the reusable it calls:
`release.yaml`, `semantic-pull-request.yaml`, `linting.yaml`,
`clear-action-cache.yaml` and `autolabeler.yaml`. The callers in this
repository carry an `-action` suffix (`release-action.yaml`,
`semantic-pull-request-action.yaml`, `linting-action.yaml`,
`clear-action-cache-action.yaml`, `autolabeler-action.yaml`,
`change-isolation-action.yaml`, `tox-verify-action.yaml`,
`ci-management-verify-action.yaml`) because a caller here cannot share
a filename with the reusable it calls. Do not copy that suffix into a
consuming repository. Gerrit verify callers, such as the change
isolation, tox verify and ci-management verify examples, follow
gerrit_to_platform's naming instead: the filename must contain both
`gerrit` and `verify`, and must not contain `required`, which
gerrit_to_platform keeps for an organisation's required workflows.
The ci-management merge example follows the same rule with `merge` in
place of `verify`.

## Gerrit support

Gerrit-mirrored projects use these workflows unchanged. Apart from
change isolation, tox verify and ci-management verify, none of the
reusables here takes
Gerrit *checkout* inputs, and none performs a dual checkout. The
release reusable keeps `require_gerrit`, which verifies a tag's
signing key against a Gerrit account and has nothing to do with
checkout.

That deviates from the sibling reusables in `python-workflows`,
`node-workflows` and the rest, which run per patchset. Those accept a
Gerrit refspec and pick between checking out the change and checking out
the branch. A tag push carries no change, so that second path could
never execute here. Carrying the `gerrit_*` inputs would advertise a
capability the workflow does not have, and leave a dead branch to
maintain.

The release tag replicates from Gerrit to the GitHub mirror and the push
triggers the caller, so what differs for a Gerrit project is where
signing keys get verified: see `examples/release/gerrit.yaml`, which
sets `require_gerrit: 'true'` and `require_github: 'false'`.

Cache housekeeping acts on the GitHub mirror's Actions caches, which
have no counterpart in Gerrit. The semantic pull request check carries
no Gerrit inputs either, and cannot: Gerrit projects review changes in
Gerrit, so their GitHub mirror receives no pull requests for it to
read. The autolabeler is out for the same reason, having no pull
request to label. The linting reusable takes no Gerrit checkout
inputs; a Gerrit project calls it from a `push` trigger on the mirror.

Change isolation, tox verify and ci-management verify are the
exceptions, because they run per patchset: gerrit_to_platform
dispatches their callers for each change, and each reusable checks
that change out with
`checkout-gerrit-change-action` whenever the caller passes
`gerrit_refspec`, and falls back to a normal checkout otherwise.

The ci-management merge reusable takes `gerrit_branch` and
`merged_revision` but checks out no change: gerrit_to_platform
dispatches its caller when a change merges, and it deploys the
mirror's deploy branch once that branch holds the merged revision.

## Design

See [`docs/release.md`](docs/release.md) for the release reusable
workflow's full input/output reference and job graph,
[`docs/semantic-pull-request.md`](docs/semantic-pull-request.md) for
the semantic pull request reusable workflow, and
[`docs/linting.md`](docs/linting.md) for the linting reusable
workflow, [`docs/autolabeler.md`](docs/autolabeler.md) for the
autolabeler, [`docs/change-isolation.md`](docs/change-isolation.md)
for change isolation, [`docs/tox-verify.md`](docs/tox-verify.md)
for tox verify,
[`docs/ci-management-verify.md`](docs/ci-management-verify.md) for
ci-management verify, and
[`docs/ci-management-merge.md`](docs/ci-management-merge.md) for
ci-management merge.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/generic-workflows/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/generic-workflows/main.svg
