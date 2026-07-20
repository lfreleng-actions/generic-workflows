<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 🚀 gha-workflows

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/gha-workflows) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![pre-commit.ci status badge]][pre-commit.ci results page] [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/gha-workflows/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/gha-workflows)
<!-- prettier-ignore-end -->

Shared, centrally-maintained reusable GitHub Actions workflows for the
`lfreleng-actions` organisation. Consuming repositories replace their
per-repository "fat" workflows with a small **thin caller** that
delegates to a reusable here, so the organisation maintains the pipeline
logic and security posture in one place.

## Release reusable workflow

[`.github/workflows/release.yaml`](.github/workflows/release.yaml) is a
tag-driven (Model A) release workflow. A thin
`release-action.yaml` caller in each repository runs on tag pushes and
delegates to it; the reusable validates the pushed tag against the
organisation's release-gating policy and then promotes the matching
draft GitHub release. It replaces the ubiquitous per-repository
`tag-push.yaml`.

The gates default to the policy proven in `actions-template` and exist
to prevent faulty, immutable releases — for example a stale fork tag
pushed months ago, or a tag pointing at an outdated commit:

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
`.github/workflows/` directory as `release-action.yaml` and pin the
`uses:` ref to a `gha-workflows` release SHA:

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
    # Pin a real gha-workflows release SHA in place of <SHA>.
    uses: lfreleng-actions/gha-workflows/.github/workflows/release.yaml@<SHA>
```

- `examples/release/github.yaml` — GitHub-native projects.
- `examples/release/gerrit.yaml` — projects where Gerrit is the source
  of truth (the release tag replicates from Gerrit to the GitHub mirror
  and fires this tag-push).

All inputs are optional and default to the tested gating policy. See
[`docs/release.md`](docs/release.md) for the full input/output reference
and the job graph.

## Inherited template skeletons

> **Note:** This repository started as a copy of `workflows-template`
> and still carries its generic pipeline skeletons
> (`build-test.yaml`, `build-test-release.yaml`, `merge.yaml`) and their
> examples. Whether `gha-workflows` should keep these or become a
> dedicated release-workflow repository is a decision left to
> maintainers. The material below documents the inherited skeletons.

<!-- markdownlint-disable MD013 -->

| Workflow                                    | Purpose                                                                                                                         | Trigger style        |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | -------------------- |
| `.github/workflows/build-test.yaml`         | Build, test, audit, SBOM and Grype scan skeleton                                                                                | Pull request         |
| `.github/workflows/build-test-release.yaml` | Release skeleton (Model A, tag-driven): tag validation, release artefact attachment and draft-release promotion                 | Tag push             |
| `.github/workflows/merge.yaml`              | Merge/publish skeleton (Model B, merge-driven): snapshot publish on every merge plus `releases/` file-triggered release publish | Merge / push to main |

<!-- markdownlint-enable MD013 -->

These skeletons carry `# TEMPLATE:`-marked placeholder steps that
instantiators replace with real language actions. `python-workflows` is
the language-specific reference implementation of these patterns. See
[`docs/BRIEF.md`](docs/BRIEF.md) for the skeleton design decisions and
the instantiation checklist.

## Gerrit support

The reusable workflows are Gerrit-aware: when a caller sets the
`gerrit_refspec` input they check out the change with
`checkout-gerrit-change-action` instead of `actions/checkout`. A release
is tag-driven, so no Gerrit change context exists on the tag and the
workflow casts no votes or comments — the Gerrit and GitHub-native
release callers stay near-identical.

## Design

See [`docs/release.md`](docs/release.md) for the release reusable
workflow, and [`docs/BRIEF.md`](docs/BRIEF.md) for the inherited
skeleton design decisions.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/gha-workflows/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/gha-workflows/main.svg
