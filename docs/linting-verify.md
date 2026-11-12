<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

<!-- markdownlint-disable MD013 -->

# Linting verify reusable workflow

`.github/workflows/linting-verify.yaml` lints a Gerrit change per
patchset: it checks the change out and runs every pre-commit-stage
hook in its pre-commit configuration, less any the caller names. It
replaces `compose-repo-linting.yaml` in
`lfit/releng-reusable-workflows`.

Commit-msg hooks, gitlint say, do not run, as in the legacy workflow:
`standalone-linting-action` runs them when given a `commit_range`,
and this workflow passes none. A repository that wants them checked
keeps a separate job, such as Gerrit's own commit-message check or a
gitlint hook at the pre-commit stage.

[`linting.yaml`](linting.md) does not replace it for this caller.
gerrit_to_platform dispatches a workflow on the change's target
branch, never on the change's refspec, and `linting.yaml` checks out
the triggering commit: the branch tip, which does not contain the
change. It would lint the wrong tree and could report green.
`linting.yaml` serves the post-merge model instead, and a `push`
trigger on the GitHub mirror is the recommended form of it: it fires
on the replicated commit. A `change-merged` dispatch can arrive
before the mirror replicates the merge, so `linting.yaml` may lint
the previous tip; a caller using one must not dispatch until it has
confirmed replication, as
[the ancestry check](ci-management-merge.md#the-ancestry-check)
describes for ci-management merge. `linting.yaml` refuses a
`patchset-created` or `comment-added` dispatch, and one carrying a
`GERRIT_PATCHSET_NUMBER` unless its event type is `change-merged`,
with an error naming this workflow: a recheck, and a hybrid caller's
dispatch with no event type, arrive on the target branch too.

The workflow is the `Lint` job of
[`ci-management-verify.yaml`](ci-management-verify.md) without the
JJB leg, and follows [`tox-verify.yaml`](tox-verify.md) wherever this
page says nothing different: the same Gerrit inputs, ref resolution,
hardening inputs and checkout token handling.

## Job graph

```text
[gerrit] ──► plan ──► Lint
```

- `gerrit` runs in Gerrit mode alone (`gerrit_refspec` set). It checks
  the Gerrit inputs and resolves the ref to check out, with the same
  script as the `gerrit` job in `change-isolation.yaml`.
- `plan` validates the inputs. It checks nothing out.
- `Lint` hardens the runner, fails unless harden-runner's agent is
  running, checks the change out, confirms in Gerrit mode that `HEAD`
  matches the dispatched patchset, drops any persisted token, refuses
  a `prek.toml` at `path_prefix`, and runs every pre-commit-stage
  hook in
  `<path_prefix>/.pre-commit-config.yaml` but those in `skip_hooks`
  through `lfreleng-actions/standalone-linting-action`, with
  `no_checkout: 'true'`, `run_all_hooks: 'true'`,
  `cache_hooks: 'false'`, `node_setup: 'false'` and
  `rust_toolchain_setup: 'false'`.

The workflow has no `concurrency` block, casts no vote, sends no
notification and holds no SSH key: the caller owns them. The
example carries the recommended concurrency group, one per
patchset: the workflow, the change number (the run ID when that is
empty) and the patchset number, with `cancel-in-progress: false`.
A recheck can name an older patchset, so patchsets must not cancel
each other. A repeat dispatch for one patchset waits for the run in
flight rather than cancelling it: cancelling a run cannot retract a
vote it has already sent over SSH, which could then land after the
new run's `prepare` clear. GitHub keeps one pending run per group
and replaces a pending one with a newer. The change number is
unique within a Gerrit server and is digits, so GitHub's
case-insensitive group comparison cannot merge two changes. A
central `.github` repository serving more than one Gerrit server
must add the server to the key.

## Inputs

| Input                                  | Default                   | Purpose                                                                                                                                                                                                                                   |
| -------------------------------------- | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `skip_hooks`                           | empty                     | Space or comma separated hook ids to leave out; every other pre-commit-stage hook runs                                                                                                                                                    |
| `path_prefix`                          | `.`                       | Directory holding `.pre-commit-config.yaml`, relative to the repository root                                                                                                                                                              |
| `repository`                           | caller                    | Repository to check out (`owner/name`)                                                                                                                                                                                                    |
| `ref`                                  | empty                     | Branch, tag or SHA to check out in GitHub mode. Empty is the triggering commit for the calling repository alone; for a different `repository`, that repository's default branch, so a cross-repository caller passes the `ref` it intends |
| `gerrit_refspec`                       | empty                     | Gerrit refspec of the change; setting it selects Gerrit mode                                                                                                                                                                              |
| `gerrit_project`                       | empty                     | Gerrit project; required in Gerrit mode                                                                                                                                                                                                   |
| `gerrit_branch`                        | empty                     | Target branch, short (`master`) or full (`refs/meta/config`); required in Gerrit mode                                                                                                                                                     |
| `gerrit_url`                           | `vars.GERRIT_URL`         | Gerrit server URL; required in Gerrit mode                                                                                                                                                                                                |
| `runs_on`                              | `ubuntu-latest`           | Runner label for every job; a Linux runner harden-runner supports                                                                                                                                                                         |
| `timeout_minutes`                      | `15`                      | Timeout for the `Lint` job                                                                                                                                                                                                                |
| `harden_runner_egress`                 | `block`                   | `block` or `audit`                                                                                                                                                                                                                        |
| `harden_runner_allowlist`              | organisation list, pinned | Allow-list for the `Lint` job, in `harden-runner-block-action` coordinate grammar                                                                                                                                                         |
| `harden_runner_supplemental_allowlist` | empty                     | Extra allow-list merged with the baseline, for project-specific hosts                                                                                                                                                                     |
| `harden_runner_supplemental_unpinned`  | `false`                   | Follow the supplemental list at its default branch; same organisation alone                                                                                                                                                               |
| `harden_runner_extra_endpoints`        | empty                     | Inline `host:port` endpoints added to the allow-list; a short-term fix                                                                                                                                                                    |

The `harden_runner_*` inputs are common to every reusable workflow
here; [Egress allow-list](../README.md#egress-allow-list) describes
them once, with examples.

| Secret  | Purpose                                                                                               |
| ------- | ----------------------------------------------------------------------------------------------------- |
| `token` | Token to check out `repository`; defaults to `GITHUB_TOKEN`, which reads the calling repository alone |

The workflow publishes no outputs, and takes no `pre_commit_version`:
`standalone-linting-action` pins `prek`.

`skip_hooks` combines with running every pre-commit-stage hook:
everything at that stage runs but the ids it names. The default skips
**nothing**. prek ignores an id the configuration does not define, so
a stale entry weakens the run without failing it:
`skip_hooks: actionlint` against a configuration with no actionlint
hook does nothing at all.

The `plan` job fails the run, naming the input without echoing its
value, when `path_prefix`:

- is empty or absolute;
- holds a `..` segment, or starts with `-`;
- holds whitespace, Unicode whitespace such as U+00A0 included, or a
  control character (C0, DEL, or C1 from U+0080 to U+009F).

It rejects a `skip_hooks` holding a control character, or an id that
is not ASCII letters, digits, `.`, `_` and `-` starting with a letter
or digit, the rule `linting.yaml` applies: each id reaches prek's
command line. It also rejects a `harden_runner_egress` other than
`block` or `audit`, and a supplemental allow-list without a baseline.

It refuses a Gerrit change dispatch that passes no `gerrit_refspec`:
one whose `GERRIT_EVENT_TYPE` is `patchset-created` or
`comment-added`, or one that carries a non-empty
`GERRIT_PATCHSET_NUMBER` unless its event type is `change-merged`.
The second covers a hybrid caller, which github2gerrit drives with a
change and patchset but no event type or refspec. gerrit_to_platform
dispatches on the target branch, rechecks (`comment-added`) included,
and an empty refspec selects GitHub mode, so the job would lint the
branch tip, not the change, and could earn the change a vote. The
plan reads the caller's `GERRIT_EVENT_TYPE` and
`GERRIT_PATCHSET_NUMBER` dispatch inputs, the event type matched in
full and case-sensitively: in a called workflow `github.event` is the
caller's event. A `change-merged` dispatch, with or without a
patchset number, a dispatch carrying neither input, and any `push`,
`pull_request` or `schedule` caller, which has no such input, keep
GitHub mode.

## Gerrit mode

The `Lint` job would check out, lint and vote on whatever tree a
non-empty `gerrit_refspec` names, as if it were the change: passing
`inputs.GERRIT_BRANCH` there, say, lints the branch tip. Four checks
stop that, none of which echoes a value:

1. The `plan` job accepts a change ref and nothing else,
   `refs/changes/NN/<change>/<patchset>`, whose two-digit `NN` is the
   change number's last two digits, zero padded:
   `refs/changes/45/12345/1` and `refs/changes/05/5/1` pass;
   `master`, `refs/heads/master` and `refs/changes/46/12345/1` fail.
2. When the caller's dispatch carries a `GERRIT_REFSPEC`, read from
   `github.event.inputs` as `GERRIT_EVENT_TYPE` is, `gerrit_refspec`
   must equal it. An empty dispatch value skips the check: a hybrid
   caller, which github2gerrit drives, has no dispatch input. An
   empty `gerrit_refspec` is GitHub mode, which the rule above
   governs.
3. When the dispatch carries a `GERRIT_CHANGE_NUMBER`, the refspec's
   `<change>` must equal it, and when it carries a
   `GERRIT_PATCHSET_NUMBER`, the refspec's `<patchset>` must equal
   that. Both compare as digit strings, so a leading zero is a
   mismatch, and an empty dispatch value skips its comparison, for a
   hybrid caller. The example votes on those two dispatch inputs, so
   the lint and the vote name one patchset; a dispatch whose refspec
   names `refs/changes/21/46421/1` but whose change number is `46422`,
   or whose patchset number is `2`, fails the run.
4. After `Checkout Gerrit change`, when the dispatch carries a
   `GERRIT_PATCHSET_REVISION`, the `Lint` job's
   `Verify the checked-out revision` step fails unless `HEAD` is that
   commit. An empty dispatch value skips it.

The Gerrit checkout seeds from the target branch on the GitHub
mirror before it fetches the change, so a branch the mirror does not
carry yet, a new branch not yet replicated or `refs/meta/config`
say, fails at that step, with an error naming the mirror. Replicate
the branch first, or lint changes against a branch the mirror
carries.

## Credentials go first

The `Lint` job runs whatever hooks the change's own
`.pre-commit-config.yaml` names: code the change under review
controls. No Git credential may stay persisted where that code could
read it.

In GitHub mode the job checks out with `actions/checkout` and
`persist-credentials: false`, so the checkout persists no Git
credential.

In Gerrit mode it checks out with
`lfreleng-actions/checkout-gerrit-change-action` v1.4.1, which
persists its token by default; the job leaves its
`persist-credentials` input unset. The
`Remove checkout credentials` step, the one
`ci-management-verify.yaml` runs, then deletes the credentials file
and every `includeIf` entry or `http.<url>.extraheader` that names
it, and fails the job if git would still send a token anywhere. It
runs before any hook starts, and never prints a value.

In both modes the token the checkout receives still reaches its
post-job cleanup; see [Residual exposure](#residual-exposure).

The job passes no `github_token` to `standalone-linting-action`, and
passes `cache_hooks: 'false'` in both modes, so the job neither
restores nor saves prek's hook environments or uv's cache. Both modes run
code the repository's contributors control: a Gerrit change, a `ref`
naming an unmerged branch, or a `pull_request_target` caller's
contributor SHA. gerrit_to_platform dispatches on the default branch,
and a GitHub-mode caller may share that cache scope too, so a cache
those hooks saved would let them plant code trusted runs execute.

### Residual exposure

The hooks run in the job that did the checkout. The checkout's
post-job cleanup still receives its token and runs `git` from
`PATH`, which a hook can change through `$GITHUB_PATH`, so a hook can
capture that token; this exposure is not closed. That job's
`GITHUB_TOKEN` carries `contents: read` and nothing more, so give
`secrets.token` no wider scope than reading the mirror. A follow-up
across the verify workflows tracks separating checkout from hook
execution.

## Network egress

Every job starts with `step-security/harden-runner` v2.22.4, in
`block` mode unless `harden_runner_egress` is `audit`.

- `gerrit` and `plan` talk to GitHub alone, and allow
  `github.com:443` and nothing else.
- `Lint` loads the shared organisation allow-list through
  `harden-runner-block-action`, merged with
  `harden_runner_supplemental_allowlist` when set, and writes the
  allow-list summary. Hooks install their tools at run time, so the
  job cannot know its endpoints in advance; the organisation list is
  the one for that case. In Gerrit mode the endpoint the `gerrit` job
  validated goes first in the loader's `extra_endpoints`, ahead of
  `harden_runner_extra_endpoints`, so the Gerrit checkout can fall
  back to the Gerrit server over HTTPS when the GitHub mirror lags.
  It goes first because the loader strips a `#` comment to the end
  of its line: a caller's value ending in one, such as
  `registry.example.org:443 # temporary access`, would swallow an
  endpoint appended after it. Merged there, the endpoint passes the
  loader's DNS check and its `invalid_records: filter` policy; added
  to harden-runner's `allowed-endpoints` directly, one host that
  failed to resolve would make the agent drop the whole policy. The
  endpoint is empty in GitHub mode.

harden-runner's step can succeed without starting its agent: when the
agent does not come up in time, or when the repository's
administrators set the `skip-harden-runner` custom property, which
the workflow cannot see. The `Lint` job would then run the change's
hooks with no egress enforcement and report green. So before it
checks anything out, it runs `linting.yaml`'s `harden_check` logic,
byte for byte: on a GitHub-hosted Linux runner, which GitHub discards
after the job, the agent's status file proves the agent started; it
waits for an agent still starting, and fails when there is none. It
fails under `audit` too, since every hook here is code under review,
and fails on a self-hosted runner, where a status file left by an
earlier job proves nothing.

Every hook source in the 30 repositories that call
`compose-repo-linting.yaml` today lives on `github.com`, and the
tools those hooks install come from PyPI, npm and GitHub, all on the
organisation list. That conclusion comes from reading the hook
sources, not from running them. A hook that reaches another host
needs `harden_runner_supplemental_allowlist`, or
`harden_runner_egress: audit` while you find out which host.

## Testing

`tests/test-linting-verify-plan.sh` extracts the `gerrit` and `plan`
scripts from between their `BEGIN`/`END` markers and runs them
offline:

- accepted and rejected `path_prefix`, `skip_hooks` and hardening
  inputs, most of them rejections;
- the Gerrit ref for `master`, and two rejections;
- a `patchset-created` or `comment-added` dispatch with no refspec,
  refused, and with a refspec, a `change-merged` dispatch, the near
  misses `comment-added-extra`, `Comment-Added` and
  `Patchset-Created`, and an empty and a missing event type, all
  accepted; a patchset number with no event type, or with any event
  type but `change-merged`, and no refspec, refused without echoing
  either number, and with a refspec accepted; `change-merged` with a
  patchset number, and an empty patchset number and event type,
  accepted; each refused event type dropped, a prefix match, a
  case-insensitive match, the patchset clause dropped or made to
  ignore the number, the `change-merged` exemption dropped and the
  refspec ignored, in a copy of the plan, caught;
- the refspec checks: `master`, `refs/heads/master`, other malformed
  refs and a wrong two-digit part refused; a mismatch with the
  dispatch's refspec refused, a match and an empty dispatch value
  accepted; a change or patchset number that differs from the
  dispatch's, a zero-padded one included, refused, a match and each
  empty dispatch value accepted, and each of those comparisons,
  dropped or made tolerant of leading zeros in a copy of the plan,
  caught;
- the revision check, extracted from the `Lint` job and run in a
  throwaway repository: it passes when `HEAD` is the dispatched
  revision, fails on any other commit, and skips an empty or missing
  one;
- the `prek.toml` refusal, extracted from the `Lint` job and run
  against throwaway trees: a `prek.toml` at the root or under a
  `path_prefix` subdirectory, or a dangling symlink of that name at
  either, refused; one in another directory, and none, accepted; six
  mutants of it caught. It must sit after the checkouts and the
  credential removal and before the linting step, in both modes;
- the harden-runner check, extracted from the `Lint` job and run
  against a scratch agent directory: it passes with the agent's
  status file present, and fails with neither file (the
  `skip-harden-runner` shape), on a timed-out agent, under `audit`
  with no agent, on a self-hosted runner and off Linux;
- the example caller's vote rule, evaluated over every combination of
  job results for one, two and three needs and for a kept fourth job,
  with six wrong rules, the old `cancelled` branch among them, each
  caught;
- the example's `vote` job condition, which must be
  `!cancelled() && needs.visibility.outputs.visible == 'true'` with no
  `always()` in the job, and four mutants of it caught;
- the example's concurrency group, which must queue rather than
  cancel in progress, rendered through the same evaluator and
  compared case-insensitively: two patchsets, two
  changes, cherry-picks to `main` and `Main` and two workflows get
  different groups, a recheck of one patchset the same one whatever
  the project, branch or Change-Id, and an empty or missing change
  number the run ID; seven mutants of the key caught.

It also fails when a `run:` block interpolates an expression, when a
harden-runner pin is not v2.22.4 or a job lacks one, when the
workflow gains a `concurrency` block or hands the hooks a token, when
the harden-runner check stops preceding the checkouts, when the
Gerrit endpoint leaves the loader's `extra_endpoints`, follows the
caller's endpoints there, or returns to harden-runner's
`allowed-endpoints` (each of which it applies to a copy of the
workflow and expects to catch), when a caller's `extra_endpoints`
ending in a `#` comment would strip the endpoint (rendered for
sample values, with comments stripped by a copy of the loader's
comment rule rather than the loader itself), when the revision check
stops following the Gerrit checkout, and when the linting step stops
passing `skip_hooks`, `path_prefix`, `cache_hooks: 'false'`,
`node_setup: 'false'` or `rust_toolchain_setup: 'false'` (the last two
each dropped, changed and duplicated in copies of the workflow, each
of which it expects to catch). The `linting-verify-fixtures` prek
hook runs it whenever either workflow, the example or the script
changes.

The fixtures test the extracted logic. The dispatch checks (event
type, refspec, change and patchset numbers, and revision) and the
`linting.yaml` guard all read `github.event.inputs` in a called
workflow, which no real dispatch has exercised; the vote rule runs
through a small evaluator of the operators it uses, not GitHub's.

The same script runs the guard `linting.yaml` uses to refuse a
per-patchset dispatch, extracted from its plan job: it must refuse a
`workflow_dispatch` carrying `GERRIT_EVENT_TYPE: patchset-created` or
`comment-added`, or a `GERRIT_PATCHSET_NUMBER` with no event type or
any but `change-merged`, with a message that echoes no value. It must
pass `change-merged`, with or without a patchset number, the near
misses `comment-added-extra`, `Comment-Added` and `Patchset-Created`,
an empty or missing value, and a push, pull request or schedule. Each
refused event type dropped, a prefix match, a case-insensitive match,
a guard on any event, the patchset clause dropped or made to ignore
the number and the `change-merged` exemption dropped, in a copy of
the guard, must fail those cases. That tests the extracted logic, not
GitHub's handing of the caller's event to a called workflow.

`tests/test-ci-management-verify-plan.sh` fails when this workflow's
`gerrit` script drifts from `change-isolation.yaml`'s, its credential
removal from `ci-management-verify.yaml`'s, or its harden-runner
check from `linting.yaml`'s `harden_check`, and exercises that
credential removal against a repository it builds at run time.

`.github/workflows/linting-verify-action.yaml` calls the workflow on
this repository's own pull requests, in block mode, against the
fixture in `tests/fixtures/linting-verify/`. It skips `check-json`
and `linting-verify-self-test-trap` through `skip_hooks`, and runs
the fixture's `check-yaml` and `actionlint` hooks. The trap is a
local hook that fails whenever it runs in that self-test, where
`GITHUB_WORKFLOW_REF` names `linting-verify-action.yaml`, so the run
fails if `skip_hooks` stops reaching the hook executor; elsewhere,
from the repository root say, it passes. prek runs them from the git top level, so they
check every YAML file and workflow in this repository rather than
the fixture alone.

A pull request cannot dispatch Gerrit mode. No run here covers a
Gerrit checkout, the credential removal against a real persisted
token, a real vote or a gerrit_to_platform dispatch; the offline
fixtures cover the ref resolution and the credential removal.

## Migration

| compose-repo-linting                  | This workflow                                                                                                                                                 |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| nine `GERRIT_*` inputs                | `repository`, `ref`, `gerrit_refspec`, `gerrit_project`, `gerrit_branch`, `gerrit_url`, as in `tox-verify.yaml`; `gerrit_url` falls back to `vars.GERRIT_URL` |
| `pre_commit_skips`                    | `skip_hooks`, the same space or comma separated list, with `actionlint` removed once a self-installing hook is in place; its default is empty                 |
| `PRE_COMMIT_VERSION`                  | dropped: the legacy workflow never declared it, so it did nothing; the linting action pins `prek`                                                             |
| separate, unpinned actionlint job     | none: actionlint runs as a hook if the configuration defines one that installs itself; this workflow installs no executable                                   |
| `@main`, or one of seven older pins   | a release **commit** SHA of this repository                                                                                                                   |

Migrate the lint job, and nothing else. Most callers run other
verification jobs beside it, and the vote must keep counting them.
Measured on 2026-11-03, of the 30 callers:

- **7 run linting alone**: `FDio/.github`, `lfit/puppet-master`,
  `lfit/puppet-modules-profile`, `lfit/puppet-modules-role`,
  `lfit/releng-nexus-upload`, `o-ran-sc/.github` and `onap/.github`.
  Such a caller may adopt the job graph of
  [`examples/linting-verify/gerrit-linting-verify.yaml`](../examples/linting-verify/gerrit-linting-verify.yaml)
  whole.
- **23 run other verification jobs** beside the lint call: 17 call
  `compose-maven-verify.yaml`, 16 call
  `gerrit-compose-required-tox-verify.yaml`, and others run local
  `tox`, `docs`, `docs-linkcheck`, `license`, `python-*` or `eyaml`
  jobs, an rtdv3 verify or an info-yaml verify. Such a caller
  replaces its `compose-repo-linting` job, **and that job alone**,
  with the example's `linting-verify` job, and keeps every other job, each in the `vote`
  job's `needs`. Copying the example over it would delete those jobs,
  and the vote would stay green without them.

Replacing the `compose-repo-linting` job means changing what it
calls, not how it fits the caller:

- Keep its job ID: the `vote` job's `needs`, and any `if:`, name it.
- Keep its `needs` and its conditions.
- Keep its sources for the Gerrit values. Where the caller derives
  them from a job such as `call-gerrit-change-info`, pass
  `needs.<that job>.outputs.GERRIT_*` as `gerrit_refspec`,
  `gerrit_project` and `gerrit_branch`, not the example's
  `inputs.GERRIT_*`, and keep that job in the `linting-verify` job's
  `needs`. Measured on 2026-11-03, `opendaylight/docs` and
  `opendaylight/gnmi` do this: they are hybrid callers, also driven
  by github2gerrit, where the dispatch inputs are absent, so an
  `inputs.GERRIT_REFSPEC` there would select GitHub mode and lint the
  branch tip.

The vote must account for every job the caller keeps, beside
`linting-verify`. The example's rule does so by construction, since
it reads every result in `needs`: success when every result is
`success`, and failure otherwise, so a skipped job never earns a
positive vote:

```yaml
vote-type: ${{ !contains(needs.*.result, 'failure') && !contains(needs.*.result, 'cancelled') && !contains(needs.*.result, 'skipped') && 'success' || 'failure' }}
```

The `vote` job runs on `!cancelled()`, not `always()`, so a failed
job still reaches it and votes failure. A run cancelled by hand or
by the platform casts no vote, since the `prepare` job already
cleared the previous one, so it leaves nothing stale; rerun the
whole workflow to vote again. A recheck of the same patchset queues
behind the run in flight rather than cancelling it.

Each patchset has its own run, `prepare` clear and vote. A project
whose Verified label has a
[`copyCondition`](https://gerrit-review.googlesource.com/Documentation/config-labels.html#label_copyCondition)
accepts an older patchset's vote on a newer one whenever Gerrit's
condition holds, and an older run finishing after the newer patchset's
clear can land such a vote. A project wanting Verified to reflect the
current patchset's lint alone must not copy Verified votes.

Pin a release commit SHA. Keep `gerrit` and `verify` in the caller's
file name, and keep `required` out of it, or gerrit_to_platform will
not dispatch it; the existing `gerrit-verify.yaml` name qualifies.
The example uses
`vars.GERRIT_SERVER`, `vars.GERRIT_SSH_USER`, `vars.GERRIT_KNOWN_HOSTS`
and `secrets.GERRIT_SSH_PRIVKEY`, as most callers do today; the `lfit`
repositories substitute their `LFIT_GERRIT_*` names. Those callers
also pass the URL explicitly under the `with:` of the
`linting-verify` job, as
`gerrit_url: ${{ vars.LFIT_GERRIT_URL }}` (the variable name their
repository uses), because the reusable's fallback reads
`vars.GERRIT_URL` alone; without it, Gerrit mode fails to resolve the
endpoint before linting. A caller that
must not vote sets the `gerrit-review-action` input comment-&#111;nly
to `'true'` in both of its steps. The retired `lfit/gerrit-review-action`
and `technote-space/workflow-conclusion-action` references go with
the old caller: the example uses `lfreleng-actions/gerrit-review-action`,
and derives its vote from `needs` rather than reading the run's
conclusion from the jobs API, which can still list finished jobs as
running.

Per consumer, **decide on actionlint first**. The legacy workflow ran
actionlint as a separate job on every repository, from an unpinned
`curl | bash`. This workflow runs it if the repository's own
configuration defines the hook, and otherwise not at all. Of the 30 callers, 20 define no
actionlint hook, and would lose the check without a word on
migration: 18 in `opendaylight`, 1 in `lfit` and 1 in
`modeseven-opendaylight`. Each of them adds the `actionlint-py` hook
to its `.pre-commit-config.yaml` before it migrates, pinned to a
commit as this repository's own configuration pins it:

```yaml
  - repo: https://github.com/Mateusz-Grzelinski/actionlint-py
    rev: 357f7eec6dec49bf7693dc0dbec30212226d5492  # frozen: v1.7.12.25
    hooks:
      - id: actionlint
```

The other 10 define a hook, but 2 of those hooks cannot run here.
This workflow installs no `actionlint` executable, so a hook must
install its own. Measured on 2026-11-03:

- 8 define a hook that installs itself: `actionlint-py`
  (`opendaylight/docs` and `lfit/releng-nexus-upload`), or
  `rhysd/actionlint` at a release whose hook is `language: golang`
  (`o-ran-sc/.github` and 4 `lfit` repositories);
- 2, `FDio/.github` and `onap/.github`, define `rhysd/actionlint`
  v1.6.24 as `language: system`, which runs an `actionlint`
  executable already on `PATH`. The legacy workflow skipped it and
  ran its own job, so once the skip goes it fails for want of the
  executable.

Replace a `language: system` actionlint hook, `actionlint-system`
included, with the self-installing `actionlint-py` hook above, or
provision the executable before this workflow's hooks run; it
installs none. A step in the calling job cannot do that, because the
`Lint` job starts on a runner of its own: provisioning means a
`runs_on` runner whose image already has `actionlint` on `PATH`. The
pre-commit.ci `skip: [actionlint]` entry those two repositories
carry can stay or go: it affects pre-commit.ci alone.

Prefer `actionlint-py` to a `golang` hook. The self-test runs
`actionlint-py` inside the organisation allow-list in block mode; a
`golang` hook also needs its Go toolchain and module hosts allowed,
and nothing here has run one.

Remove `actionlint` from any skip list carried over from
`pre_commit_skips` once a self-installing hook is in place. The
legacy workflow's separate actionlint job ran regardless of that
list, but in `skip_hooks` the entry disables the hook.

Behaviour that changes on migration:

- The default skips nothing, where `pre_commit_skips` skipped
  `actionlint`. A carried-over `skip_hooks: actionlint` does nothing
  against a repository with no such hook, and disables the hook in
  one that has it; drop the entry, as above.
- A `prek.toml` at `path_prefix`, a dangling symlink of that name
  included, fails the `Lint` job before any hook runs. This workflow
  runs `<path_prefix>/.pre-commit-config.yaml` alone, and prek prefers
  `prek.toml` over it, so linting the YAML would run a configuration
  the repository has superseded. The legacy workflow ran pre-commit,
  which ignores `prek.toml`; `linting.yaml` refuses it too. Keep the
  hooks in `.pre-commit-config.yaml`. A `prek.toml` in another
  directory is not checked.
- Every job runs behind harden-runner in block mode; a project whose
  hooks reach a host off the organisation list needs a supplemental
  list, or `harden_runner_egress: audit` while it finds out which.
- The workflow installs no Node.js dependencies and sets up no Rust
  toolchain, as the legacy workflow did neither: it passes
  `node_setup: 'false'` and `rust_toolchain_setup: 'false'` to the
  linting action, whose defaults would run a frozen install from a
  `package.json` and lockfile, or prepare a Rust toolchain with
  `rustfmt` and `clippy` for a `Cargo.toml`, under `path_prefix`. A
  hook that needs those dependencies or that toolchain, a local
  `eslint` or `clippy` hook say, either installs its own environment
  through prek (`language: node` or `language: rust` with
  `additional_dependencies`) or stays in a separate job.
- The concurrency group and the vote stay in the caller. A caller
  keeping a per-change group should take the example's per-patchset
  one, so a recheck of an older patchset cannot cancel a newer one,
  and its `cancel-in-progress: false`, so a cancelled run's vote
  cannot land after its replacement's clear.
