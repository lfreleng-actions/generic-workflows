<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

<!-- markdownlint-disable MD013 -->

# Semantic pull request reusable workflow

`.github/workflows/semantic-pull-request.yaml` validates that a pull
request title follows the Conventional Commits convention, using the
organisation's capitalised type vocabulary. A thin caller in each
consuming repository runs on pull request events and delegates to it.

The workflow migrated from
`lfit/releng-reusable-workflows/.github/workflows/reuse-semantic-pull-request.yaml`,
which it replaces.

## What it does

```text
Load egress allow-list -> Harden runner -> Gate -> Title check
```

Everything happens in one job. The check gates every pull request event
in every repository that adopts it, so a separate validation job would
add a runner start-up to every title edit for no useful signal; the
runner-platform check that would justify one instead runs at the top of
the gate step.

1. **Gate** — decides whether the Dependabot single-commit exception
   applies to this pull request, and publishes the decision as the
   `relaxed` step output plus a step summary.
2. **Title check** — runs
   [`amannn/action-semantic-pull-request`](https://github.com/amannn/action-semantic-pull-request),
   with `validateSingleCommitMatchesPrTitle` computed from the caller's
   input and the gate's decision.

## The Dependabot exception

Dependabot shortens a commit subject that would otherwise run long by
deleting the `from <old> to <new>` version fragment, while the pull
request title keeps it. The two then differ, and the action's exact
`validateSingleCommitMatchesPrTitle` check fails on a bump nobody can
fix without rewriting Dependabot's commit.

The gate detects that specific transformation and nothing else. It
takes the longest common prefix and the longest common suffix of the
title and the subject; when the two runs together account for the whole
subject, a single contiguous span differs. Whitespace or the ends of
the title must delimit that span, once trimmed, on **both** sides, and
it must read `from <old> to <new>`.

<!-- markdownlint-disable MD013 -->

| Title                                                                                                                  | Subject                                                                                           | Decision |
| ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | -------- |
| `Chore: Bump cryptography from 49.0.0 to 50.0.0 in the uv group across 1 directory`                                    | `Chore: Bump cryptography in the uv group across 1 directory`                                     | relax    |
| `CI(deps): Bump github-security-report from 0.8.0 to 0.10.0 in /.github/runtime-pin`                                   | `CI(deps): Bump github-security-report in /.github/runtime-pin`                                   | relax    |
| `CI(actions): Bump lfit/releng-reusable-workflows/.github/workflows/reuse-openssf-scorecard.yaml from 0.9.1 to 0.10.1` | `CI(actions): Bump lfit/releng-reusable-workflows/.github/workflows/reuse-openssf-scorecard.yaml` | relax    |
| `Chore: Bump dependamerge from 0.9.2 to 0.10.0`                                                                        | `Chore: Bump dependamerge from 0.9.2 to 0.9.3`                                                    | strict   |
| `Chore: Bump requests from 1.0 to 2.0`                                                                                 | `Chore: Bump urllib3 from 1.0 to 2.0`                                                             | strict   |

<!-- markdownlint-enable MD013 -->

The fourth row is the one worth dwelling on. Someone moved the title to
a newer version while the commit subject kept the old one, so nothing
went missing and the prefix plus suffix do not cover the subject. That
drift is precisely what the check exists to catch, and it keeps
failing.

The rule is a strict superset of the leading-substring test it replaces:
the trailing-fragment case is the one where the common suffix has
length zero. Nothing that passed before starts failing.

Three guards sit outside the rule and survive the migration intact: the
author must be `dependabot[bot]`, the pull request must have one
non-merge commit and no more, and a subject already equal to the title
needs no exception. Setting `dependabot_relax: false` removes the
exception entirely, and `validate_single_commit: false` bypasses it too
— the action nests the title match inside its single-commit branch, so
with that off there is no check left to relax.

`tests/test-relax-matches.sh` pins the behaviour. It extracts the
function from the workflow rather than copying it, so the fixtures
always exercise the code that runs in CI, and pre-commit runs it
whenever either file changes.

## Inputs

All inputs are optional.

<!-- markdownlint-disable MD013 -->

| Input                                     | Type      | Default                                                        | Purpose                                                                |
| ----------------------------------------- | --------- | -------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `types`                                   | `string`  | `Fix Feat Chore Docs Style Refactor Perf Test Revert CI Build` | Newline-separated allowed Conventional Commit types                    |
| `scopes`                                  | `string`  | `''`                                                           | Newline-separated allowed scopes, as regex patterns; empty permits any |
| `disallow_scopes`                         | `string`  | `''`                                                           | Newline-separated rejected scopes                                      |
| `require_scope`                           | `boolean` | `false`                                                        | Require every title to carry a scope                                   |
| `subject_pattern`                         | `string`  | `''`                                                           | Regex the subject must match                                           |
| `subject_pattern_error`                   | `string`  | `''`                                                           | Message shown when `subject_pattern` fails                             |
| `ignore_labels`                           | `string`  | `''`                                                           | Newline-separated labels that skip validation                          |
| `validate_single_commit`                  | `boolean` | `true`                                                         | Check the commit message on single-commit pull requests                |
| `validate_single_commit_matches_pr_title` | `boolean` | `true`                                                         | Require the single commit subject to match the title                   |
| `dependabot_relax`                        | `boolean` | `true`                                                         | Allow the Dependabot version-fragment exception                        |
| `runs_on`                                 | `string`  | `ubuntu-latest`                                                | Runner label; must be Linux                                            |
| `timeout_minutes`                         | `number`  | `5`                                                            | Job timeout                                                            |
| `harden_runner_egress`                    | `string`  | `block`                                                        | `block` or `audit`                                                     |
| `harden_runner_allowlist`                 | `string`  | central org list                                               | Out-of-band harden-runner allow-list configuration                     |

<!-- markdownlint-enable MD013 -->

`runs_on` must name a Linux runner. Harden-runner enforces an egress
policy on Linux; elsewhere it degrades to a warning and the job would
run unhardened while still reporting success, so the gate step checks
`RUNNER_OS` and fails instead.

The workflow does not expose the upstream action's `headerPattern`,
`headerPatternCorrespondence` and `wip` inputs. The first two replace
Conventional Commits parsing wholesale, which defeats the point of a
shared policy; `wip` reports a second, separate status check, which
confuses required-check configuration for a feature GitHub's draft pull
requests already cover.

## Outputs

| Output    | Description                                       |
| --------- | ------------------------------------------------- |
| `relaxed` | `true` when the Dependabot exception applied      |
| `reason`  | Fixed-vocabulary explanation of the gate decision |

Both values come from a fixed vocabulary the gate computes. Neither
carries pull request title or commit text, so a caller may use them in a
`run:` block without laundering them first.

## Permissions

The calling job must grant **both** `contents: read` and
`pull-requests: read`. A caller caps the token permissions of the
workflow it calls, so omitting the second makes the pull request API
calls fail with 403 on repositories that default the token to a minimal
grant. The gate treats such a failure as non-fatal — it warns, keeps the
strict check, and carries on — so a missing grant shows up as a
confusing strict failure on a Dependabot pull request rather than an
obvious permissions error.

## Thin caller usage

Copy `examples/semantic-pull-request/github.yaml` into your project's
`.github/workflows/` directory as `semantic-pull-request.yaml` and pin
the `uses:` ref to a `generic-workflows` release SHA.

Keep the file name, the job id and the job name as the example has
them. A ruleset matches a required status check by name, and renaming
any of them detaches the ruleset from the check it gates.

Where the organisation's mandatory-workflows ruleset already injects a
required `Semantic Pull Request` workflow, a repository needs no caller
of its own, and adding one produces two check runs of the same name.
Adopt this caller where no such ruleset applies, or once the injected
copy has gone.

Inside this repository the caller is `semantic-pull-request-action.yaml`,
because a caller here cannot share a file name with the reusable it
calls. It also carries a `(self)` marker in its workflow name, job name
and concurrency group, for the collision reason under *Concurrency*
below. Neither the suffix nor the marker is the convention for
consuming repositories.

### Triggers

Use `pull_request` or `pull_request_target`. The action infers the pull
request from the event payload and fails on anything else, which is why
neither the example nor this repository's own caller offers a
`workflow_dispatch`. The gate step reports that against the caller's
trigger rather than letting it surface from inside the action.

`edited` catches a title correction and `synchronize` a push that
changes the commit count, and with it whether the single-commit rules
apply at all. Add `labeled` and `unlabeled` when using `ignore_labels`.

### Concurrency

Use a **literal** group, `cancel-in-progress: false` and `queue: max`,
as the example does:

```yaml
concurrency:
  group: 'semantic-pull-request-${{ github.ref }}'
  cancel-in-progress: false
  queue: max
```

Three mistakes lead here, and all produce the same symptom: a cancelled
check run sitting beside a successful one for the same head
SHA. The merge box then reads "Some checks were not successful", and
where the check is a **required** status check, ruleset evaluation
blocks on the cancelled run — the pull request counts the rule as
unsatisfied even though the check passed.

The first is `cancel-in-progress: true`. Back-to-back `edited` and
`synchronize` events cancel the run already under way.

The second is the **default `queue: single`**, which is easy to miss:
`cancel-in-progress: false` protects the run in flight and nothing
else. A single pending run waits behind it, and a third event cancels
*that* to take its place. `queue: max` holds up to 100 pending runs and
processes them in order, so a burst of events costs latency rather than
a cancelled check. The two keys are complementary; `queue: max`
combined with `cancel-in-progress: true` is a validation error. The
check takes seconds, so queueing costs almost nothing.

The third is `group: '${{ github.workflow }}-${{ github.ref }}'`.
`github.workflow` resolves to the workflow **name**, not the file path,
so any two workflows in a repository that share a `name:` share a
concurrency group. This repository reproduced it while adding the
workflow: the organisation's mandatory-workflows ruleset injects a
required workflow named `Semantic Pull Request 🛠️`, the new caller
carried the same name, and the injected one cancelled it. Naming the
group after the check rather than after the workflow removes the
coupling entirely.

Note that `actionlint` does not yet recognise the `queue` key and will
report it as unexpected. GitHub documents the key, so scope an ignore
rather than drop it.

The reusable declares no concurrency group of its own. A literal group
there would serialise the check across every open pull request, and
`github.workflow` resolves to the *caller's* workflow name inside a
called workflow, so reusing that expression on both sides produces one
shared group that the caller holds while waiting for the callee — which
GitHub cancels as a concurrency deadlock.

## Gerrit support

None, and none is possible. Gerrit projects review changes in Gerrit;
their GitHub mirror receives no pull requests for this check to read.
`examples/semantic-pull-request/` ships a `github.yaml` and nothing
else.

## Migration from `lfit/releng-reusable-workflows`

<!-- markdownlint-disable MD013 -->

| Old                                                                                 | New                                                                               |
| ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `lfit/releng-reusable-workflows/.github/workflows/reuse-semantic-pull-request.yaml` | `lfreleng-actions/generic-workflows/.github/workflows/semantic-pull-request.yaml` |

<!-- markdownlint-enable MD013 -->

Repoint the `uses:` line and pin a `generic-workflows` release SHA.
Existing `types`, `validate_single_commit` and
`validate_single_commit_matches_pr_title` inputs carry over unchanged
with the same defaults, so a caller that set none needs no `with:`
block. Everything else on the table above is new.

While repointing, take the caller-side corrections above: use a literal
concurrency group with `cancel-in-progress: false` and `queue: max`,
and confirm the calling job grants `pull-requests: read`.
