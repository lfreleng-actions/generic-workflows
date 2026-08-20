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
it adds one thing the action cannot express: a narrow exception for
Dependabot's truncated single-commit subjects.

Dependabot shortens a long commit subject by deleting the
`from <old> to <new>` version fragment while the pull request title
keeps it, so the two differ and the exact single-commit match fails on
a bump nobody can fix without rewriting Dependabot's commit. The gate
step recognises that specific deletion — one contiguous span, on
whitespace boundaries, reading `from <old> to <new>` — and relaxes the
match for it alone. Genuine drift, such as a title updated to a newer
version while the commit subject keeps the old one, still fails.

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

## Cache housekeeping reusable workflow

[`.github/workflows/clear-action-cache.yaml`](.github/workflows/clear-action-cache.yaml)
lists a repository's Actions caches, deletes the entries matching the
supplied filters, and then confirms the deletion. A thin
`clear-action-cache.yaml` caller in each repository surfaces the
filters as a `workflow_dispatch` form and delegates to it.

<!-- markdownlint-disable MD013 -->

| Input         | Type      | Default | Effect                                                                          |
| ------------- | --------- | ------- | ------------------------------------------------------------------------------- |
| `key_pattern` | `string`  | `''`    | Substring filter applied to cache keys; empty targets every entry               |
| `ref_filter`  | `string`  | `''`    | Limit deletion to one git ref, such as `refs/heads/main`; empty ignores the ref |
| `dry_run`     | `boolean` | `false` | List the matching entries and delete nothing                                    |

<!-- markdownlint-enable MD013 -->

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

| Input                     | Type     | Default               | Effect                                              |
| ------------------------- | -------- | --------------------- | --------------------------------------------------- |
| `config_name`             | `string` | `release-drafter.yml` | Config file resolved under `.github/`               |
| `runs_on`                 | `string` | `ubuntu-latest`       | Runner label; Linux, because harden-runner needs it |
| `timeout_minutes`         | `number` | `3`                   | Job timeout                                         |
| `harden_runner_egress`    | `string` | `block`               | Egress policy: `block` or `audit`                   |
| `harden_runner_allowlist` | `string` | `.github` v0.15.0     | Out-of-band allow-list coordinate                   |

<!-- markdownlint-enable MD013 -->

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

## Caller filenames

A consuming repository names its callers after the reusable it calls:
`release.yaml`, `semantic-pull-request.yaml`, `clear-action-cache.yaml`
and `autolabeler.yaml`. The callers in this repository carry an
`-action` suffix (`release-action.yaml`,
`semantic-pull-request-action.yaml`,
`clear-action-cache-action.yaml`, `autolabeler-action.yaml`) because a
caller here cannot share a filename with the reusable it calls. Do not
copy that suffix into a consuming repository.

## Gerrit support

Gerrit-mirrored projects use these workflows unchanged. None of the
reusables here takes Gerrit *checkout* inputs, and none performs a dual
checkout. The release reusable keeps `require_gerrit`, which verifies a
tag's signing key against a Gerrit account and has nothing to do with
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
request to label.

## Design

See [`docs/release.md`](docs/release.md) for the release reusable
workflow's full input/output reference and job graph,
[`docs/semantic-pull-request.md`](docs/semantic-pull-request.md) for
the semantic pull request reusable workflow, and
[`docs/autolabeler.md`](docs/autolabeler.md) for the autolabeler.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/generic-workflows/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/generic-workflows/main.svg
