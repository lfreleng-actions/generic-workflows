<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

<!-- markdownlint-disable MD013 -->

# CI management merge reusable workflow

`.github/workflows/ci-management-merge.yaml` runs after a change
merges to a ci-management repository: it pushes the repository's
Jenkins Job Builder (JJB) tree to Jenkins. It replaces
`gerrit-ci-management-merge.yaml` in `lfit/releng-reusable-workflows`.
Its verify counterpart is [`ci-management-verify.yaml`](ci-management-verify.md).

## Job graph

```text
plan ──► Update
```

- `plan` validates every input and decides whether to deploy. It
  checks nothing out.
- `Update` runs when the plan says to deploy. It hardens the runner,
  waits until the mirror's deploy branch holds the merged revision,
  checks out the exact commit that passed with its submodules, once,
  and runs `lfreleng-actions/jjb-action` with `mode: update`. The step
  summary reports the job count.

The workflow has no `concurrency` block, posts no comment, casts no
vote and holds no SSH key: the caller owns each of those. The example
carries the recommended concurrency group.

## Inputs

| Input                                  | Default                   | Purpose                                                                             |
| -------------------------------------- | ------------------------- | ----------------------------------------------------------------------------------- |
| `gerrit_branch`                        | required                  | Branch the change merged to, short (`master`) or full (`refs/heads/master`)         |
| `merged_revision`                      | required                  | Commit that merged, 40 hex digits; the deployed tree must contain it                |
| `deploy_branch`                        | required                  | Branch Jenkins deploys from, short or full; no default                              |
| `jenkins_url`                          | required                  | Jenkins URL; see below                                                              |
| `jenkins_user`                         | required                  | Jenkins user the update runs as                                                     |
| `workers`                              | `0`                       | JJB `--workers`, 0 to 64; `0` means one per CPU                                     |
| `delete_old`                           | `true`                    | Pass `--delete-old`, removing managed jobs the tree no longer defines               |
| `path_prefix`                          | `.`                       | Root of the ci-management tree; JJB runs from it                                    |
| `jjb_path`                             | `jjb`                     | JJB tree, relative to `path_prefix`, read recursively                               |
| `repository`                           | caller                    | Repository to check out (`owner/name`)                                              |
| `runs_on`                              | `ubuntu-latest`           | Runner label for both jobs; a Linux runner harden-runner supports                   |
| `timeout_minutes`                      | `30`                      | Timeout for the `Update` job                                                        |
| `harden_runner_egress`                 | `block`                   | `block` or `audit`                                                                  |
| `harden_runner_allowlist`              | organisation list, pinned | Allow-list for the `Update` job, in `harden-runner-block-action` coordinate grammar |
| `harden_runner_supplemental_allowlist` | empty                     | Extra allow-list merged with the baseline, for project-specific hosts               |
| `harden_runner_supplemental_unpinned`  | `false`                   | Follow the supplemental list at its default branch; same organisation alone         |
| `harden_runner_extra_endpoints`        | empty                     | Inline `host:port` endpoints added to the allow-list; a short-term fix              |

The `harden_runner_*` inputs are common to every reusable workflow
here; [Egress allow-list](../README.md#egress-allow-list) describes
them once, with examples.

| Secret             | Purpose                                           |
| ------------------ | ------------------------------------------------- |
| `jenkins_password` | Password or API token of `jenkins_user`; required |

The workflow publishes no outputs.

The `plan` job fails the run, naming the input without echoing its
value, when:

- `jenkins_url` is not `https://`, carries user information, a query
  or a fragment, names its host by IP literal (bracketed IPv6, or a
  top-level label that starts with a digit, which covers dotted and
  shortened IPv4), holds an invalid port, or holds whitespace, a
  control character or a non-ASCII character. A path is fine:
  `https://jenkins.opendaylight.org/releng` passes. The host rules are
  those of `jjb-action` v0.0.1's input checks, and the plan
  refuses IP literals on top, so it never accepts a URL `jjb-action`
  would refuse;
- `jenkins_user` is empty, holds a control character, or starts or
  ends with whitespace;
- `gerrit_branch` or `deploy_branch` is empty, holds whitespace or a
  control character, contains `..` or an empty component (a leading,
  trailing or doubled `/`), starts with `-`, ends with `.`, is `@`,
  has a component that starts with `.` or ends with `.lock`, or holds
  a character git forbids in a ref (`~^:?*[\` or `@{`): the rules of
  the `gerrit` script in `change-isolation.yaml` plus those of
  `git check-ref-format`;
- `deploy_branch` names a ref outside `refs/heads/`;
- `merged_revision` is not 40 hex digits;
- `workers` is not an integer from 0 to 64;
- `path_prefix` or `jjb_path` breaks the rules of
  [`ci-management-verify.yaml`](ci-management-verify.md#inputs);
- `repository` is neither empty nor one `owner/name`: the wait sends
  the job's token to the URL built from it;
- `harden_runner_egress` is other than `block` or `audit`, or a
  supplemental allow-list has no baseline.

## The deploy branch

The plan reduces `gerrit_branch` and `deploy_branch` to full refs
(`master` becomes `refs/heads/master`) and deploys when they match.
Any other merge, to another branch or to `refs/meta/config`, skips
`Update` with a notice, and the run succeeds. The legacy workflow
deployed whichever branch the change merged to, so a merge to a
stable branch replaced the production jobs with that branch's
definitions, and `--delete-old` removed the rest.

`deploy_branch` has no default: the caller states which branch
Jenkins deploys from.

## The ancestry check

gerrit_to_platform dispatches the caller when the change merges in
Gerrit, and the GitHub mirror replicates the branch afterwards. The
legacy workflow slept for ten seconds and deployed the mirror's tip
without checking that it held the change.

`Update` waits before it checks anything out. In a scratch bare
repository under `RUNNER_TEMP`, with no working tree and no
submodules, it fetches the deploy branch, commits alone
(`--filter=tree:0`, no tags), and tests that `merged_revision` is an
ancestor of the fetched tip. Until that holds, it waits with backoff
(eight waits growing from 5 seconds to a minute, five minutes in all)
and fetches again. Each fetch force-updates a remote-tracking ref in
the scratch repository, so the next fetch offers the commits it
already holds and downloads the new ones alone, and a deploy branch
rewritten by a force push replaces the old tip rather than failing
the fetch. A revision the scratch repository does not hold, a network
error or a fetch cut off at the bound counts as not yet. If the
revision still has not arrived, the job fails with an error naming
the mirror as the cause, and deploys nothing. A tip past the merged
revision passes: its tree holds the change.

Waiting cannot heal a refused fetch, so the step fails at once, with
its own error and without blaming the mirror, when the mirror has no
deploy branch, or when the repository is missing or refuses the
token: an authentication failure, an HTTP 401 or 403, or
`Repository not found`. Git runs with `GIT_TERMINAL_PROMPT=0`, so it
fails rather than prompting for credentials, and in the C locale, so
the step can match its messages.

The five minutes bound the whole step, its waits included. Each wait
shrinks to the time left less a 20-second reserve, so a final fetch
and ancestry check always follow the last wait, about 20 seconds
before the bound. Every git command in the step, local ones such as
`init`, `config`, `rev-parse` and `merge-base` included, runs under
`timeout` with the time left, killing it 5 seconds later if it
ignores the stop: even a local command can block, on a lock or a
lazy fetch in the partial clone. A stalled mirror or command fails
the step at five minutes instead of holding the caller's concurrency
group until the job timeout. A fetch cut off at
the bound gives the error naming the mirror; any other command cut
off gives an error naming that command, since the wait could not
check the deploy branch.

The wait outputs the tip commit that passed, and a single
`actions/checkout` checks out that exact commit, not the branch,
with its submodules and `persist-credentials: false`. A branch that
moves on during the wait cannot slip an unchecked tree in, and no git
command follows the checkout: `actions/checkout` alone builds the
tree, its submodules and their URL rewriting.

The fetches authenticate as the checkout does, with the job's token,
through an `http.extraheader` in the scratch repository's own
configuration. An `EXIT` trap deletes the scratch repository, and the
token with it, on every exit path: success, failure, and `HUP`, `INT`
or `TERM`.

## Deleting old jobs, and an empty tree

`delete_old` defaults to `true`, as the legacy workflow always passed
`--delete-old`: Jenkins jobs the tree no longer defines go. Set it to
`false` to keep them.

With `delete_old` on, `jjb-action` refuses an update whose tree
generates no jobs, so a wrong `path_prefix` or `jjb_path`, or a tree
that expands to nothing, fails the run instead of deleting every
managed job. With it off, such an update changes nothing.

## Concurrency

The reusable sets no concurrency group: two merges into the same
Jenkins must queue, and the caller alone knows which runs share one.
The example keys the group of deploy-branch merges to the repository,
with `cancel-in-progress: false`:

- a running update always finishes, so two `--delete-old` runs never
  overlap;
- GitHub keeps one pending run per group, so a newer deploy-branch
  merge cancels an older pending one. Nothing goes missing, because
  the newer run checks out the branch tip, whose tree carries both
  changes;
- a merge to any other branch, `refs/meta/config` included, deploys
  nothing, so it runs in a group of its own (keyed to the run) and
  never cancels a pending deployment. The example compares
  `GERRIT_BRANCH` with the deploy branch in its short and full forms;
  a copy that changes `deploy_branch` must change that test too.

The legacy group was per change, so two merges could run
`--delete-old` at once.

## Credentials

The `jenkins_password` secret reaches one step, `jjb-action`, through
`with:`; no `run:` block sees it, and no input reaches a `run:` block
by expression. `jjb-action` writes it to a configuration file in a
private directory under `RUNNER_TEMP`, outside the workspace, and
removes it on every exit path. The checkout uses
`persist-credentials: false`. The wait writes the job's token to its
scratch repository's configuration alone, and deletes that repository
when it ends.

## Network egress

Both jobs start with `step-security/harden-runner` v2.22.3, in `block`
mode unless `harden_runner_egress` is `audit`.

- `plan` talks to GitHub alone, and allows `github.com:443` and
  nothing else.
- `Update` loads the shared organisation allow-list through
  `harden-runner-block-action`, merged with
  `harden_runner_supplemental_allowlist` when set, and adds the Jenkins
  host and port the plan resolved from `jenkins_url`. The checkout,
  the submodules, Python and JJB's locked packages come from hosts the
  list carries.

## Testing

`tests/test-ci-management-merge-plan.sh` extracts the `plan` script
and the merged-revision wait from between their `BEGIN`/`END` markers
and runs them offline:

- accepted and rejected inputs, most of them rejections, each checked
  for an error that does not echo the value;
- the deploy decision for short names, full refs, `refs/meta/config`
  and another branch, and the outputs `Update` reads;
- the wait against local repositories: a revision already present;
  one that arrives after three waits; a branch that moves on past the
  revision during the wait, whose newer tip is the output; a branch
  rewritten during the wait, whose new tip is not a descendant of the
  old; one that never arrives although another branch holds it; and
  one that arrives at 270 seconds, after the last full delay. A
  stand-in `sleep` takes no time but advances the wait's clock, so the
  cases check that the last wait ends before the deadline and a final
  fetch follows it. Each case checks the commit the wait outputs, that
  the fetch carried the token header, that the log never shows the
  token, and that no scratch repository remains;
- each fetch after the first holding the deploy branch's
  remote-tracking ref from the one before;
- fetch failures: two network errors that the wait retries, and a
  missing deploy branch, a missing repository and five refusals of
  the token, each failing after one fetch with its own error and not
  the mirror's;
- a `TERM`, `INT` or `HUP` during the wait, after which no scratch
  repository remains;
- the deadline: with the bound shortened to two seconds in a copy of
  the script, a fetch that never returns fails the step at the bound,
  naming the mirror; with it shortened to four, a stalled `git init`,
  `git config`, `git rev-parse` or `git merge-base` fails the step at
  the bound with an error naming that command, and no scratch
  repository remains.

It also fails when a `run:` block interpolates an expression, when a
harden-runner pin is not v2.22.3, when `jenkins_password` reaches
anything but the `jjb-action` input, when the workflow gains a
`concurrency` block, when the wait runs a git command outside its
`timeout` helper, and when the job has other than one checkout, of
the commit the wait verified, or runs a git command after it. The
`ci-management-merge-fixtures` prek hook runs it whenever the workflow
or the script changes.

This repository has no self-caller for the workflow: a pull request
has neither a Jenkins to update nor the secrets to reach one. No run
here covers a real Jenkins update or a Gerrit-dispatched merge.

## Migration

| Legacy                                  | This workflow             | Notes                                                     |
| --------------------------------------- | ------------------------- | --------------------------------------------------------- |
| `GERRIT_BRANCH`                         | `gerrit_branch`           | Required                                                  |
| `GERRIT_PATCHSET_REVISION` (never read) | `merged_revision`         | Required                                                  |
| none                                    | `deploy_branch`           | **Required, no default**: the branch Jenkins deploys from |
| `vars.JENKINS_URL`                      | `jenkins_url`             | Required                                                  |
| `vars.JOBBUILDER_PROD_USR`              | `jenkins_user`            | Required                                                  |
| `secrets.JOBBUILDER_PROD_PSW`           | secret `jenkins_password` | Required                                                  |
| `vars.JJB_WORKERS` (`0`)                | `workers`                 | Default `0`                                               |
| none (always on)                        | `delete_old`              | Boolean, default `true`                                   |
| `vars.JJB_VERSION`                      | none                      | The `jjb-action` release pins JJB                         |
| `GERRIT_SSH_PRIVKEY`, other `GERRIT_*`  | dropped                   | The caller notifies and reports                           |

Copy [`examples/ci-management/gerrit-ci-management-merge.yaml`](../examples/ci-management/gerrit-ci-management-merge.yaml),
set `deploy_branch`, and pin a release **commit** SHA of this
repository. Keep `gerrit` and `merge` in the copy's file name, and
keep `required` out of it, or gerrit_to_platform will not dispatch
it.

Per consumer:

- **ONAP** and **O-RAN-SC** replace their callers of
  `gerrit-ci-management-merge.yaml`, and move from `@main` to a
  release SHA.
- **OpenDaylight** replaces its caller, pinned at v0.11.0, moves to a
  release SHA, and passes `workers: 1`, its current `JJB_WORKERS`,
  and its `jenkins_url` with the `/releng` path.

Behaviour that changes on migration:

- A merge to a branch other than `deploy_branch` deploys nothing.
- A tree without the merged revision fails the run after about five
  minutes instead of deploying.
- JJB moves to the version the `jjb-action` release pins, today
  6.5.0, from `vars.JJB_VERSION` or 6.4.3.
- Every job runs behind harden-runner in block mode; a project that
  reaches a host off the organisation list needs a supplemental list,
  or `harden_runner_egress: audit` while it finds out which.
- The concurrency group moves into the caller and covers the
  repository's deploy-branch merges, not the change.
