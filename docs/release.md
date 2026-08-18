<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

<!-- markdownlint-disable MD013 -->

# Release reusable workflow

`.github/workflows/release.yaml` is a reusable release workflow (Model A,
tag-driven). A thin caller in each consuming repository runs on tag
pushes and delegates to it. The reusable validates the pushed tag
against the organisation's release-gating policy and then promotes the
matching draft GitHub release.

This replaces the per-repository "fat" `tag-push.yaml` with a single,
centrally-maintained reusable and a small `release.yaml` caller. The
filename names the outcome rather than the trigger, and sits beside the
`release-drafter.yaml` that creates the draft this workflow publishes.

## What it does

```text
tag-validate -> promote-release
```

1. `tag-validate` — checks out the repository with full history and
   tags, then runs
   [`tag-validate-action`](https://github.com/lfreleng-actions/tag-validate-action)
   against every configured gate. On success it ensures a draft release
   exists (creating one if necessary), so promotion can proceed.
2. `promote-release` — publishes the draft release via
   [`draft-release-promote-action`](https://github.com/lfreleng-actions/draft-release-promote-action).
   Idempotent: a re-run after a successful promotion treats the
   already-published release as success.

Both jobs check out the repository, load the central allow-list and then
run a single harden-runner step that derives its egress policy from
`harden_runner_egress`, pin every `uses:` to a full commit SHA, and
never interpolate `${{ }}` into `run:` blocks.

## No Gerrit checkout inputs

The sibling reusables in `python-workflows`, `node-workflows` and the
rest run per patchset. They accept a Gerrit refspec and pick between
checking out the change and checking out the branch.

This workflow runs on a tag push, which carries no Gerrit change
context, so that second path could never execute. It takes no
`gerrit_*` inputs and performs one checkout rather than two. Carrying
them would advertise a capability the workflow does not have, and leave
a dead branch for a future reader to maintain.

This says nothing about `require_gerrit`, which the workflow keeps. That
gate verifies a tag's signing key against a Gerrit account and plays no
part in checkout.

Gerrit-mirrored projects use this workflow unchanged. The release tag
replicates from Gerrit to the GitHub mirror and the push triggers the
caller. What differs for a Gerrit project is where signing keys get
verified — see `require_gerrit` in the gates table below, and
`examples/release/gerrit.yaml`.

## Release gates

The gates below default to the policy proven in `actions-template`. They
exist to prevent faulty, immutable releases — for example a stale fork
tag pushed months ago, or a tag pointing at an outdated commit.

<!-- markdownlint-disable MD013 -->

| Gate               | Input                | Default                | Effect                                                                                                                      |
| ------------------ | -------------------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Version scheme     | `require_type`       | `semver`               | Tag must match `semver`, `calver`, `both`, or `none` to disable                                                             |
| Signature          | `require_signed`     | `ssh,gpg-unverifiable` | Tag must carry an accepted signature; empty disables                                                                        |
| GitHub key         | `require_github`     | `true`                 | Signing key registered on a GitHub account                                                                                  |
| Gerrit key         | `require_gerrit`     | `false`                | Signing key registered on Gerrit (`true` auto-detects the server, or supply a hostname)                                     |
| Key owner          | `require_owner`      | `''`                   | Restrict signer to given GitHub username(s)/email(s); implies `require_github`                                              |
| No pre-release     | `reject_development` | `true`                 | Reject alpha/rc/dev/snapshot tags                                                                                           |
| Increment          | `enforce_increment`  | `true`                 | Tag must exceed the highest existing comparable tag                                                                         |
| Branch containment | `require_branch`     | `''`                   | Tag commit must be reachable from this branch; empty uses the default branch, `false` disables                              |
| Recency            | `require_recent`     | `true`                 | Tag must be recent; `true` is a 3-minute window, or supply a minute count, `false` disables (needs an annotated/signed tag) |
| Latest commit      | `require_latest`     | `true`                 | Tag must point at the current tip of the target branch                                                                      |

<!-- markdownlint-enable MD013 -->

## Other inputs

<!-- markdownlint-disable MD013 -->

| Input                                                                | Default               | Purpose                                                                                       |
| -------------------------------------------------------------------- | --------------------- | --------------------------------------------------------------------------------------------- |
| `ref`                                                                | `''` (triggering tag) | Git ref to check out                                                                          |
| `mark_latest`                                                        | `true`                | Mark the promoted release as the repository's `latest`                                        |
| `harden_runner_egress`                                               | `block`               | `block` or `audit`                                                                            |
| `harden_runner_allowlist`                                            | central org list      | Out-of-band harden-runner allow-list configuration                                            |

<!-- markdownlint-enable MD013 -->

## Outputs

| Output        | Description                          |
| ------------- | ------------------------------------ |
| `tag`         | Validated release tag/version string |
| `release_url` | URL of the promoted GitHub release   |

## Thin caller usage

Copy the appropriate example from `examples/release/` into your
project's `.github/workflows/` directory as `release.yaml` and pin the
`uses:` ref to a `generic-workflows` release SHA. Delete the
`tag-push.yaml` it replaces in the same change.

Inside this repository the caller is `release-action.yaml`, because a
caller here cannot share a filename with the reusable it calls. That
suffix is a local disambiguator, not the convention for consuming
repositories.

Minimal GitHub-native caller:

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
  of truth. The release tag replicates from Gerrit to the GitHub
  mirror, where it fires this tag-push; the caller sets
  `require_gerrit: 'true'` and `require_github: 'false'` because signer
  keys live on Gerrit.

The caller owns the `${{ github.workflow }}`-derived concurrency group
shown above. The reusable declares its own group under a distinct
literal prefix, because `github.workflow` resolves to the *caller's*
workflow name inside a called workflow: reusing that expression on both
sides produces one shared group that the caller holds while waiting for
the callee, which GitHub cancels as a concurrency deadlock. Keep the
caller's group as shown, or omit it entirely.

All inputs are optional; the defaults carry the tested gating policy.
