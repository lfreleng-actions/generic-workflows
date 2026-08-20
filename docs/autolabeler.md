<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# Autolabeler reusable workflow

[`.github/workflows/autolabeler.yaml`](../.github/workflows/autolabeler.yaml)
applies labels to a pull request from the rules in a release-drafter
configuration. A thin `autolabeler.yaml` caller in each repository
runs on pull request events and delegates to it. The workflow migrated
from `lfit/releng-reusable-workflows`, which it replaces.

## What it does

The lane wraps
[`release-drafter/release-drafter/autolabeler`](https://github.com/release-drafter/release-drafter)
behind a block-mode harden-runner step. The action reads the
`autolabeler:` rules from `.github/<config_name>` and applies the
matching labels to the pull request.

Those labels matter beyond the pull request view. Release Drafter reads
them later to sort entries into release-note categories and to resolve
the next version, because each category in the organisation's
configuration carries its own `semver-increment`. A pull request that
picks up no label lands in no category and contributes no increment.

## The two triggers

A caller must trigger on **both** `pull_request` and
`pull_request_target`. Callers get this wrong more than any other
detail, and nothing reports the mistake.

GitHub hands a `pull_request` run a token without write access when the
pull request comes from another repository, so the labelling API call
fails there. `pull_request_target` runs with the base repository's
permissions and can label such a pull request, but carries more risk,
and using it for every pull request would be needless exposure.

The lane resolves this itself. Its job condition routes each pull
request down a single path:

| Pull request raised from | `pull_request` | `pull_request_target` |
| ------------------------ | -------------- | --------------------- |
| A branch of this repo    | Runs           | Skipped               |
| Another repository       | Skipped        | Runs                  |

Both events fire for a cross-repository pull request, so without that
condition the lane would label it twice.

The condition compares the head repository against the **base**
repository:

```yaml
github.event.pull_request.head.repo.full_name !=
  github.event.pull_request.base.repo.full_name
```

It avoids `github.event.pull_request.head.repo.fork`,
which answers a different question: whether the head repository is
itself a fork of something. In a repository that is itself a fork,
every internal pull request sets that flag, so keying on it would send
ordinary same-repository work down the elevated trigger. Both fields
here come from the event payload, which also keeps the check correct
inside a called workflow, where `github.repository` names the caller.

### The `edited` type

Use `types: [opened, synchronize, reopened, edited]` on both triggers.

`edited` is easy to leave out and costly to omit. Release Drafter
matches autolabeler rules against pull request metadata, and the
organisation's configuration matches on the **title** for every rule.
A title corrected after opening keeps whatever labels the original
earned. The common case is a pull request opened without a
Conventional Commits prefix, which the semantic pull request check then
rejects: the author fixes the title, the check goes green, and the pull
request stays unlabelled and so lands in no release-note category.

`synchronize` does not cover this, because it fires on a push rather
than on a metadata edit.

## Why `pull_request_target` is safe here

Calling a workflow from a `pull_request_target` context deserves
suspicion, because the run holds write permission while the pull
request author controls the code. That risk needs head-branch code to
reach the runner, and here none does:

1. The lane has no checkout step, so pull request head source never
   reaches the runner, let alone executes.
2. `pull_request_target` loads the workflow body from the base branch,
   and a pinned `uses:` ref fixes the content of the reusable.
3. Every step pins a commit SHA and runs trusted code.
   `harden-runner-block-action` fetches one allow-list file and
   publishes it, `harden-runner` installs the egress filter, and the
   autolabeler makes GitHub API calls against pull request metadata.
   None of the three reads or runs head source.
4. Permissions stop at `pull-requests: write` and `contents: read`, and
   the egress block lands before the autolabeler step runs.

zizmor still raises `dangerous-triggers` on the caller, since a
reusable workflow has no trigger of its own to annotate. Silence it on
the `pull_request_target` line:

```yaml
  pull_request_target:  # zizmor: ignore[dangerous-triggers]
    types: [opened, synchronize, reopened, edited]
```

## Inputs

<!-- markdownlint-disable MD013 -->

| Input                     | Type     | Default               | Effect                                              |
| ------------------------- | -------- | --------------------- | --------------------------------------------------- |
| `config_name`             | `string` | `release-drafter.yml` | Config file resolved under `.github/`               |
| `runs_on`                 | `string` | `ubuntu-latest`       | Runner label; Linux, because harden-runner needs it |
| `timeout_minutes`         | `number` | `3`                   | Job timeout                                         |
| `harden_runner_egress`    | `string` | `block`               | Egress policy: `block` or `audit`                   |
| `harden_runner_allowlist` | `string` | `.github` v0.15.0     | Out-of-band allow-list coordinate                   |

<!-- markdownlint-enable MD013 -->

## Secrets

<!-- markdownlint-disable MD013 -->

| Secret  | Required | Effect                                                    |
| ------- | -------- | --------------------------------------------------------- |
| `token` | No       | Authenticates the autolabeler; empty uses `GITHUB_TOKEN`  |

<!-- markdownlint-enable MD013 -->

Nearly every repository leaves `token` unset. Two cases call for one:
labels that must carry a different identity, and a downstream workflow
that has to react to the labelling event, since activity performed with
`GITHUB_TOKEN` raises no further workflow run.

The lane forwards this value to the action's `token` **input**. That
detail matters: the action declares `token` with a default of
`github.token`, and reads no `GITHUB_TOKEN` environment variable. A
lane that exported the secret as an environment variable instead would
leave the default in place, and the supplied token would go unused
while appearing configured.

## Config resolution

`config_name` resolves under `.github/` in the calling repository. When
that file is absent, release-drafter falls back to the same path in the
organisation's `.github` repository, which is how repositories in this
organisation inherit one shared label vocabulary without each carrying
a copy.

## Permissions

The lane's job declares `contents: read` to read the configuration and
`pull-requests: write` to apply labels. A called workflow never holds
more permission than its caller, so the calling job must declare both.
Omitting `pull-requests: write` produces a 403 at the labelling step.

## Why the runner must be Linux

`runs_on` must name a Linux runner, and the lane enforces that rather
than trusting it. harden-runner applies an egress policy on Linux
alone; elsewhere it degrades to a warning and returns success. Without
a check, a caller naming a macOS or Windows runner would get a green
job that applied labels holding `pull-requests: write` on an unhardened
runner.

A guard step fails the job when `RUNNER_OS` is anything other
than `Linux`, before the labelling step runs. It tests `RUNNER_OS`
rather than matching on the `runs_on` string, which would guess.

## Thin caller usage

Copy the caller from [`examples/autolabeler/`](../examples/autolabeler/)
into your project's `.github/workflows/` directory as
`autolabeler.yaml` and pin the `uses:` ref to a `generic-workflows`
release SHA.

### Concurrency

Set the concurrency group in the caller. Two details matter:

- Keep `github.event_name` in the key. The workflow triggers on both
  `pull_request` and `pull_request_target` for the same pull request,
  and a shared group would have one cancel the other.
- Key on the pull request number, not `github.ref`. On
  `pull_request_target`, `github.ref` resolves to the base branch, which
  would collapse every open pull request into a single group.

`cancel-in-progress: true` suits this lane, unlike the semantic pull
request check. Labelling is idempotent and publishes no check run that
a ruleset evaluates, so a superseded run leaves nothing behind for the
merge box to report.

## Gerrit support

None, by design. Gerrit projects review changes in Gerrit; their GitHub
mirror receives no pull requests to label.

## Migration from `lfit/releng-reusable-workflows`

Replace the `uses:` coordinate and rename one input:

```diff
-    uses: lfit/releng-reusable-workflows/.github/workflows/reuse-autolabeler.yaml@<SHA>
+    uses: lfreleng-actions/generic-workflows/.github/workflows/autolabeler.yaml@<SHA>
```

<!-- markdownlint-disable MD013 -->

| Old input              | New input                 | Note                            |
| ---------------------- | ------------------------- | ------------------------------- |
| `harden_runner_config` | `harden_runner_allowlist` | House vocabulary; pin bumped    |
| `config_name`          | `config_name`             | Unchanged                       |
| —                      | `runs_on`                 | New                             |
| —                      | `timeout_minutes`         | New; the old lane fixed it at 3 |
| —                      | `harden_runner_egress`    | New; the old lane fixed `block` |

<!-- markdownlint-enable MD013 -->

The job name stays `Label PR`, so a ruleset or branch rule naming that
check keeps matching it. The `token` secret carries over unchanged.
