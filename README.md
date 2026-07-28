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
tag-driven (Model A) release workflow. A thin
`release-action.yaml` caller in each repository runs on tag pushes and
delegates to it; the reusable checks the pushed tag against a
configurable release-gating policy and then promotes the matching draft
GitHub release. A caller replaces a per-repository release workflow with
a single delegating job.

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
`.github/workflows/` directory as `release-action.yaml` and pin the
`uses:` ref to a `generic-workflows` release SHA:

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

## Gerrit support

The reusable workflows are Gerrit-aware: when a caller sets the
`gerrit_refspec` input they check out the change with
`checkout-gerrit-change-action` instead of `actions/checkout`. A release
is tag-driven, so no Gerrit change context exists on the tag and the
workflow casts no votes or comments — the Gerrit and GitHub-native
release callers stay near-identical.

## Design

See [`docs/release.md`](docs/release.md) for the release reusable
workflow's full input/output reference and job graph.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/generic-workflows/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/generic-workflows/main.svg
