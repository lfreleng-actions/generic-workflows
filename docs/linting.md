<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

<!-- markdownlint-disable MD013 -->

# Linting reusable workflow

`.github/workflows/linting.yaml` runs pre-commit hooks with
[prek](https://github.com/j178/prek), standalone from pre-commit.ci. A
thin caller in each consuming repository delegates to it on whichever
events that repository supports — pull requests where they exist, and
`push` for the Gerrit mirrors described below, which never see one.

This workflow serves two populations. Repositories with **no**
pre-commit.ci at all — every Gerrit-mirrored project among them —
need something to run their hooks in CI. Repositories that *do* have
it still need the hooks it cannot run: the pre-commit.ci sandbox
blocks network access at scan time and caps hook environment size, so
hooks such as `gha-workflow-linter` (which calls the GitHub API) or
`aislop` (which runs dependency audits) get listed under `ci.skip` and
never run in CI at all.

The default serves the first population: **every hook in the
configuration**. Set `ci_skipped: true` for the second, or name hooks
explicitly with `hooks`.

That default follows the direction it fails in. A repository
without pre-commit.ci has no meaningful `ci.skip`, so defaulting to
that set would resolve no tasks and report a green check having linted
nothing — silent, and on a mandated check nobody investigates a green
one. Defaulting to the whole configuration makes the same
misconfiguration *duplicated work*: visible, costed, and never unsafe.

The workflow supersedes
`lfit/releng-reusable-workflows/.github/workflows/compose-repo-linting.yaml`,
which ran the inverse selection (every hook except a `SKIP` list) on a
Gerrit checkout, and installed actionlint from an unpinned script.

## What it does

```text
plan (single job)  ->  lint (matrix, one job per task)
```

1. **plan** — guards the trigger, validates the inputs, locates a
   configuration file, and resolves the set of lint tasks. Publishes
   the matrix and a `has_work` verdict.
2. **lint** — one job per task, in parallel. Each runs
   [`lfreleng-actions/standalone-linting-action`](https://github.com/lfreleng-actions/standalone-linting-action),
   which installs prek at the pinned version and runs the task's hooks
   against the task's configuration.

## Fast abort

An organisation ruleset can mandate this workflow estate-wide, so the
common case — a repository with nothing extra to lint — must cost
close to nothing and must never block a merge.

The plan job decides as soon as it can, and each stage
avoids the work of the next:

1. A **sparse checkout** fetches the configuration file alone, not the
   repository (the JSON `plan` mode takes a full checkout, since it may
   name arbitrary paths).
2. A **grep pre-filter** looks for the word `skip` before any tooling
   gets installed, and aborts where a `ci.skip` key provably cannot be
   present. This applies in `ci_skipped` mode alone: under the default
   a configuration with no `ci.skip` still has a full run's worth of
   work, so aborting on its absence would be the silent-green the
   default exists to prevent.
3. Should that pass, the job installs `uv` and parses the
   configuration.
4. When no tasks resolve, `has_work` is `false`, the `lint` matrix
   never instantiates, and the run ends green with a step summary
   saying so.

A repository with no configuration and no organisation fallback never
provisions a lint runner; nor does one whose `ci.skip` is empty under
`ci_skipped`.

The pre-filter uses a loose substring test rather than a key-shaped
regex by design, because its failure modes are not symmetric. A false
positive costs one needless parse. A false negative reports a green
check having linted nothing, which is the worst outcome available to a
mandated check. YAML admits `skip:`, `skip :`, `"skip":` and the flow
form `ci: {"skip": [...]}`, and a pattern tight enough to match keys
alone missed three of those four; `tests/test-locate-rules.sh` pins
every
spelling.

A substring test alone still cannot *prove* a key absent, so the
filter aborts in one situation, where absence is provable: a file that
is printable
ASCII and carries no backslash. No YAML escape exists without a
backslash, so `"\x73kip"` — which PyYAML decodes as `skip` — cannot
hide there, and no alternate encoding such as UTF-16 can hide the
letters either. Every other file gets parsed.

An earlier version of this note claimed an escaped key could affect no
one but the repository that wrote it. That was wrong: on a fork pull
request the configuration is attacker-controlled, so an escaped key
would pass a mandated check having run nothing. The cost of the
correction is small, because the pre-filter saves an install in one
job and does not decide the matrix — a configuration full of regexes
still resolves to no tasks and provisions no lint runner.

An unreadable organisation fallback gets the same treatment. An HTTP
404 means "absent" and nothing else does: an authentication failure, a
rate limit, a server error or a network failure fails the job, because
"could not find out" must never resolve to "nothing to lint". Set
`org_fallback: false` to opt out of the lookup.

## Selecting what runs

Modes, in precedence order:

<!-- markdownlint-disable MD013 -->

| Given                      | Runs                                              |
| -------------------------- | ------------------------------------------------- |
| `plan` (JSON)              | The tasks the array describes, in parallel        |
| `hooks`                    | The named hook ids from the primary configuration |
| `ci_skipped: true`         | The hook ids listed under `ci.skip`               |
| `config_path`/`config_url` | Every hook in that configuration                  |
| Nothing                    | Every hook in the primary configuration (default) |

<!-- markdownlint-enable MD013 -->

`skip_hooks` sits across these: it excludes ids from whichever set
the mode selected, and is how a caller says "everything except
these" — `hooks` names a subset to include, which cannot express an
exclusion. It replaces the legacy workflow's `pre_commit_skips`.

It applies to **every** task, plan entries included, so it reads as a
policy for the run rather than a property of one selection — which is
why it stands as the one selector that composes with `plan` instead of
conflicting with it. Nothing gets discarded, and a discarded input is
the whole reason the others conflict.

The executor applies it rather than the plan job, so there is one
implementation of prek's matching rather than two. That includes
matching a hook's `alias`, which prek's `--skip` accepts as readily
as an id, so an exclusion naming an alias behaves the same in every
mode.

A task that excludes every one of its hooks resolves to a job
reporting nothing to do.

### Which hook stages a run reaches

prek runs `pre-commit` hooks, plus `manual` ones when a task names
them. It passes over the other nine stages without output and exits
zero, so a hook declaring `stages: [commit-msg]` — `gitlint` being
the common one — **never runs here**.

That matters for what a green check means. From `v0.4.1` the
executor drops such a hook from the reported set rather than
recording a tick against it, so the summary stops claiming work it
did not do. It does not run the hook, and this workflow offers no
way to ask for one.

A repository whose `.pre-commit-config.yaml` declares `gitlint`
should not read a green check here as proof that its commit
messages passed that hook. Run those hooks in a dedicated job until
lfreleng-actions/standalone-linting-action#143 lands.

One edge remains open, tracked as
lfreleng-actions/standalone-linting-action#156: the executor applies
the stage filter where an exclusion is in play, and a task naming
such a hook with no exclusion set can still report a pass.

Every id under `ci.skip` must name a hook the same configuration
defines. A stale or mistyped entry fails the run rather than dropping
out of the selection, because dropping it turns `ci.skip:
[mypy-typo]` into an empty selection, then into zero tasks and a green
check on a gate the organisation mandates. A partial mistake is worse
still: some hooks run while the rest disappear without trace. An
explicitly requested `hooks` list has always failed on an undefined
id, so holding `ci.skip` to the same standard closes a gap between two
spellings of one idea. An **empty** `ci.skip` stays legitimate and
selects nothing — a repository saying pre-commit.ci skips no hooks, so
this workflow has none to pick up.

`plan` and the scalar selectors are **mutually exclusive**: supplying
both fails, naming the conflicting inputs. Discarding a value a caller
supplied would look identical to running it, which is the failure this
workflow exists to avoid. Move each scalar into a plan entry instead.

<!-- markdownlint-enable MD013 -->

Configuration resolution, in precedence order:

1. `config_url` — an HTTPS download
2. `config_path` — a repository-relative path
3. `<path_prefix>/.pre-commit-config.yaml` — the repository's own
4. `<org_config_path>` in the organisation's `.github` repository

The organisation fallback means a repository estate needs one central
configuration rather than a copy in every repository. It applies
where the repository has no configuration of its own, and needs the
organisation's `.github` repository to be public: a workflow token
cannot read a private sibling repository. The lookup runs when
something may actually read the result, so naming a `config_path` or
`config_url` skips the API call entirely.

`split_hooks` (default `true`) gives each selected hook its own matrix
job. Set it `false` to run them in one job instead.

The trade is wall-clock time against billable minutes, and worth
stating plainly. Within a single job prek runs repository fetches and
hook environment setup concurrently, and shares toolchains between
hooks. prek does not run the hooks themselves concurrently by
default: that needs the hook-level `priority` key, an extension unique
to prek which upstream pre-commit may reject, so a repository sharing
one `.pre-commit-config.yaml` with pre-commit.ci cannot adopt it.

Fan-out is the route to concurrent execution, and it pays
the per-job fixed price — runner start-up, hardening, checkout,
toolchain install — once per hook, forfeiting the shared toolchain
cache across jobs. One job pays that price once and runs the hooks in
sequence.

Fan-out also gives each hook its own check run, so an organisation
ruleset can require checks by name and a failed pull request names the
linter that failed. That, together with hooks under `ci.skip` tending
to be the heavy ones, is why the default stays `true`.

It divides a *selection*, so it leaves a task that runs the whole
configuration alone: a plan entry with neither `hooks` nor
`ci_skipped`, and a bare `config_path` or `config_url` input, each
stay a single job. prek runs a configuration in its declared order,
and fanning that out would rebuild every hook environment once per
job.

## The JSON plan

For anything the scalar inputs cannot express — CI-excluded hooks, an
explicitly named subset, a remote configuration and a local
supplemental one, all in the same run — pass a JSON array. Each entry
is an object:

<!-- markdownlint-disable MD013 -->

| Key             | Type              | Meaning                                              |
| --------------- | ----------------- | ---------------------------------------------------- |
| `name`          | string            | Task label shown in the job name                     |
| `ci_skipped`    | boolean           | `true` runs the hooks listed under `ci.skip`         |
| `hooks`         | string or array   | Hook ids to run (exclusive with `ci_skipped`)        |
| `config_path`   | string            | Repository-relative configuration path               |
| `config_url`    | string            | HTTPS configuration URL (exclusive with the above)   |
| `config_sha256` | string            | Expected digest; requires `config_url`               |

<!-- markdownlint-enable MD013 -->

The resolver enforces these types rather than coercing them, so
`"ci_skipped": "false"`, `"hooks": []` or `"name": 1` fails with a
message naming the offending value instead of selecting another mode
in silence. Presence decides a conflict too: the resolver refuses
`hooks` beside `ci_skipped` whatever the boolean says, since accepting
`"ci_skipped": false` would discard a selector the caller wrote.

<!-- markdownlint-enable MD013 -->

An entry with neither `hooks` nor `ci_skipped` runs every hook in its
configuration. The resolver refuses `ci_skipped: false` rather than
treating it as that case: it selects nothing, so falling through would
*broaden* the entry to every hook instead of narrowing it. An entry
naming no configuration uses the primary one. Under `split_hooks`, the
entry's `name` prefixes each job (`docs / markdownlint`), so a job
still says which entry produced it.

```yaml
with:
  plan: |
    [
      {"name": "ci-skip-defaults", "ci_skipped": true},
      {"name": "heavy", "hooks": "mypy basedpyright"},
      {"name": "org-standard",
       "config_url": "https://example.org/lint.yaml",
       "config_sha256": "<64 hex characters>"},
      {"name": "supplemental",
       "config_path": ".github/supplemental-linting.yaml"}
    ]
```

The plan job validates every entry before the matrix exists, so a
malformed plan, an undefined hook id or an unreadable configuration
fails once with a clear message rather than once per job.

`tests/test-lint-plan.sh` extracts the resolver from the workflow and
runs it against a fixture suite, most of it rejection cases:
traversal, absolute paths, non-HTTPS URLs, shell metacharacters and
leading hyphens in hook ids, globs, expression syntax in task names,
unknown plan keys, wrong types for `hooks`, `ci_skipped`, `name`,
`config_path` and `config_sha256`, explicit nulls in each of those, a
digest supplied without a URL, and the task cap. A second group feeds
the resolver structurally malformed configurations that carry a
non-empty `ci.skip`, where "no tasks" would be the silent wrong
answer: a scalar or null `ci.skip`, a scalar `ci`, a missing or null
`repos`, a missing or null `hooks`, and non-mapping entries.

`tests/test-locate-rules.sh` covers the shell decisions that sit
*earlier* than the resolver and determine whether it runs at all: the
dangling-symlink walk, the organisation-fallback status mapping, the
empty-prefix rule, the workspace-containment test, the fast-abort
pre-filter, the single-line sanitiser and the runner-hardening
verdict. Each turns an unknown into a verdict, so a
wrong answer there ends in a green check that linted nothing — or, as
repeated rounds of review found, a red one for a repository that was
entirely valid. It asserts that HTTP 404 alone reads as absent (401,
403, 429, 5xx and curl's own `000` are errors), that the walk catches
a dangling symlink at the configuration filename or at a parent
component, and that the workspace root itself counts as contained
while a same-prefix sibling does not.

A note on `path_prefix`, because the rule is blunt on purpose.
Earlier revisions classified the prefix — asking git and the
filesystem in turn to name the prefix a real directory, a file, a
symlink or a typo — to separate "the prefix is wrong" from "the prefix is
fine and holds no configuration". That classification took nine
corrections across review without settling, because every instrument
is authoritative for one case and blind in another: the filesystem
cannot see a valid prefix the sparse checkout never materialised, and
git cannot see through a symlink.

The distinction turned out to be unnecessary. Naming a directory
asserts a configuration is in it, so an absence is a caller error
whatever the cause, and one rule replaces the lot. It also closes the
case the classification let through while rejecting the implausible
ones: a valid directory whose configuration had since moved elsewhere
fell to the organisation fallback and linted against a configuration
the caller never named, reporting success. The empty default prefix is
exempt, since a repository root with no configuration is the ordinary
case this workflow exists to wave through.

One consequence is worth stating, as a trade rather than an
oversight. `path_prefix` is also the working directory each lint
task runs in, and when `config_path` or `config_url` replaces the
primary configuration the plan job stops inspecting the prefix at all
— so a bad prefix in that mode surfaces once per lint job rather than
once at plan time. Validating it at plan time would mean asking
whether a path is a real directory under a sparse checkout, which is
the question that took nine corrections above. The failure stays
loud and never green; it arrives later and more than once.

Both suites extract their subject from the workflow rather than
copying it, and fail if the extraction markers go missing. Pre-commit
hooks run them whenever the workflow or the fixtures change, so the
tests exercise the code that runs in CI rather than a copy of it.

## Security

The workflow runs repository-defined tools against repository content,
including content from forks, so its threat model assumes the
configuration is attacker-controlled.

- **No `pull_request_target`.** The plan job refuses the trigger. Under
  it, both the tools and the content come from a fork while the token
  belongs to the base repository, which is the confusion an
  attacker needs. Callers trigger on `pull_request`, `push`,
  `schedule` or `workflow_dispatch`; any other event runs without the
  workflow token rather than with it.
- **No secrets consumed.** The workflow uses none. It passes the
  workflow token to hooks needing API access, and a called workflow's
  token cannot exceed its caller's, which grants `contents: read`.

  TRUSTED events receive one and no others: a push, a schedule, a
  manual dispatch, and a pull request whose head is this same
  repository.
  Every other event withholds it, whatever `export_github_token`
  says. That is an allow-list by design — enumerating the *unsafe*
  events kept missing cases (`merge_group`, whose temporary merge
  commit contains the queued pull requests; `pull_request_review`,
  which can check out a fork's commit), and any event GitHub adds
  later would default to trusted. Listing the safe shapes makes the
  default withhold. Where the hooks and the token share an origin,
  no gap exists; elsewhere a hook could exfiltrate the token and read
  private base-repository content. Set
  `export_github_token: false` to withhold it everywhere.
- **No expression interpolation in `run` blocks.** Every input, matrix
  value and repository-derived string reaches a shell through `env`,
  which closes template injection even though the configuration
  contents are attacker-controlled on a fork pull request.
- **The resolver runs isolated (`python -I -`) under `--no-config`.**
  Reading a script on stdin puts the current directory on `sys.path`,
  and that directory is the checkout. Without isolation a fork could
  commit `yaml.py`, `base64.py` or `sitecustomize.py`, have it
  imported ahead of the real module, write `has_work=false` to
  `GITHUB_OUTPUT` and exit 0 before the resolver ran a line — a green
  mandated check, and arbitrary code besides. `--no-config` closes
  the same door one layer earlier: `--no-project` stops uv treating
  the checkout as a project but not discovering a `uv.toml` in it,
  which could redirect the index PyYAML installs from so the hostile
  module arrives *as* PyYAML. `tests/test-lint-plan.sh` runs the
  resolver from a directory holding a hostile `yaml.py` and asserts
  no hijack.
- **The job summary redacts `config_url`.** The accepted URL grammar
  admits userinfo and a query string, which is how a private
  configuration commonly arrives — a presigned URL, or an embedded
  token. The executor receives the URL whole; the summary, which
  anyone able to see the run can read, receives an origin and a path
  plus a note naming each part it dropped.
- **Path containment before first read.** `path_prefix`,
  `config_path` and `org_config_path` must be relative, free of `..`,
  and free of any component starting with `-` (such a path reads as
  command-line options, and a failing `grep` would report "nothing to
  lint"); commands pass `--` as a second lock. The plan job then
  resolves the configuration path with `realpath` and confirms the
  real path stays inside `GITHUB_WORKSPACE`, which catches symlink
  escapes that a string check would miss — including a `path_prefix`
  pointing out of the tree, whose configuration either resolves
  outside (rejected here) or fails to appear at all (rejected by the
  empty-prefix rule). Containment runs *before* the file gets read,
  since both `[ -f ]` and `grep` follow symlinks; a
  `.pre-commit-config.yaml` symlink pointing out of the tree fails
  the job rather than reporting "no configuration". A symlink to an
  in-repository path the sparse checkout did not materialise fails
  too, naming the target — and the check walks every path component,
  since a dangling *directory* symlink in `path_prefix` leaves the
  configuration merely absent rather than visibly broken.
- **Download hygiene.** Remote configurations must be plain HTTPS
  URLs, with bounded redirects, a 1 MiB size cap and a time cap, and
  they land in the runner temp directory. A custom redirect handler
  refuses a redirect off HTTPS *before* opening it, rather than
  checking the final URL after `urlopen` has already issued the
  plaintext request. A remote configuration never overwrites a
  repository file; prek receives it via `--config`.

  The executor re-fetches the same URL with `curl`, and reaches the
  same property by a different mechanism — worth recording, because
  it reads like a gap, and review has flagged it twice. `--proto`
  is a ceiling on **every** request in the exchange, not a filter on
  the first, so `--proto-redir` is unnecessary:

  ```console
  $ curl --proto '=https' --tlsv1.2 --location http://host/start
  curl: (1) Protocol "http" disabled
  ```

  curl's manual states it directly: "Protocols denied by `--proto`
  are not overridden by this option." The digest verifies bytes and
  would not, on its own, prevent a plaintext request — which is why
  the transport restriction has to hold per hop on both sides.
- **No planning/linting drift.** The plan job hashes every remote
  configuration and passes the digest to the lint job, which verifies
  the same bytes it fetches. A git blob SHA pins the organisation
  fallback, and its digest gets verified too, so what ran cannot
  differ from what the plan validated.
- **Bounded fan-out.** The plan caps at 50 tasks, and hook ids, task
  names, paths and digests are pattern-checked, so a hostile
  configuration cannot spawn unbounded jobs, smuggle shell
  metacharacters into a job name, or inject rows into the step
  summary. Plan-entry paths carry the same syntax contract as the
  scalar inputs rather than a looser one.
- **Types validated, not coerced.** The resolver checks every plan
  value against its documented type rather than passing it through
  `or ""` or `bool()`. Those idioms fold `false`, `0`, `[]` and `{}`
  into the same state as an omitted key, and an omitted `hooks`
  selector runs *every* hook — so a coercion bug broadens execution
  instead of failing. Key *presence* decides omission, so an explicit
  `null` is a supplied value of the wrong type rather than a missing
  one. A supplied `config_sha256` likewise requires a `config_url`,
  since a digest travels with a URL task alone and a discarded pin
  would leave a caller believing the content carried a checksum.
- **Malformed configurations fail.** A structurally invalid
  configuration is an error, not an empty hook set. A scalar
  `ci.skip` would otherwise iterate character by character and match
  nothing, resolving zero tasks and reporting green for a repository
  that asked for work.
- **Pinned supply chain.** Every `uses:` is a commit SHA; prek and uv
  install at exact versions.

`zizmor --persona=auditor` reports no findings against the workflow,
the self-caller or the example — with one class recorded rather than
claimed clean. A whole-repository auditor run reports six low-severity
`self-repository` findings, two of them from this change's second
self-test job. That audit asks for GitHub's newer `uses: $/...`
syntax in place of `./...`, and actionlint blocks adoption:
**actionlint rejects `$/`** as a malformed reusable-workflow
reference, so the four pre-existing callers and these two stay on
`./` until actionlint learns it. Suppressing the finding would hide a
real improvement rather than a false positive, so it stands.

## Runner

`runs_on` defaults to `ubuntu-latest`. prek is a single static binary
that provisions the Python and Node.js toolchains a hook environment
declares, so the workflow does not depend on the runner's tool cache;
the pinned `ubuntu-24.04` and `ubuntu-22.04` images serve as well, as
do larger x64 runners for a hook that needs the headroom.

`ubuntu-slim` is not the default, despite provisioning
fastest. harden-runner does not support it: the action detects the
image, prints a note to the job log, and returns without installing its
agent. `RUNNER_OS` still reads `Linux`, so a platform test alone sees
nothing wrong, and the run reports success having enforced nothing.
The action returns the same way for a container job, for a
community-tier ARM64 image, for a self-hosted runner without the agent,
and where the repository carries the `skip-harden-runner` custom
property.

Neither job trusts the runner label. Each asks whether the agent
actually started, which is a positive fact rather than a list of
unsupported images a new runner could walk past:

| Condition                                     | `block`   | `audit`   |
| --------------------------------------------- | --------- | --------- |
| GitHub-hosted, agent running (or hardened VM) | proceeds  | proceeds  |
| GitHub-hosted, no agent                       | **fails** | warns     |
| Self-hosted, or runner environment unknown    | **fails** | warns     |
| Not Linux                                     | **fails** | **fails** |

The agent's status file counts as evidence on a GitHub-hosted runner
alone, because GitHub discards that runner after the job: the file
can be there because this job's pre-step wrote it, and for no other
reason. A persistent self-hosted runner gives no such guarantee.
`/home/agent/agent.status` is the same path harden-runner's own
`isAgentInstalled()` checks, and its self-hosted post-step leaves the
file in place, so a file from an earlier job would read as "agent
running" while nothing runs — and would also make harden-runner skip
installing this time, so the same stale file causes the gap and
conceals it. Self-hosted reports no monitoring instead, which is the
honest answer anyway: in the community tier harden-runner installs no
agent there without `deploy-on-self-hosted-vm`.

The check reads `RUNNER_ENVIRONMENT`, the same variable
harden-runner's `isGithubHosted()` branches on, so the two agree by
construction. An older runner that does not set it reports no
monitoring rather than assuming the favourable case.

The split follows what each policy loses. Under `block` the caller
asked for egress enforcement and is not getting it, so hooks the
repository controls would reach the network unchecked behind a green
check. Under `audit` nothing was ever enforced — audit records traffic
and blocks none of it — so the loss is telemetry, and failing every
pull request across the estate over a vendor outage would cost more
than it saved. A non-Linux runner fails either way: a caller
mistake, and these jobs assume a Linux shell regardless.

`harden_runner_egress` defaults to `audit`, not `block`. Hook
environments legitimately fetch from hosts specific to whichever hooks
a repository configures, and no fixed allow-list can predict them; a
blocking default would fail runs for sound
repositories. Callers with a known hook set should pass `block` and
extend `harden_runner_allowed_endpoints`.

The default list also carries `*.actions.githubusercontent.com` and
`*.blob.core.windows.net`, which the executor's cache restore needs.
That dependency belongs to the pinned action rather than to anything
a caller configures, so leaving it out would make `block` fail every
lint job for a reason nobody could reasonably trace.

## Inputs

<!-- markdownlint-disable MD013 -->

| Input                             | Type      | Default                           | Effect                                                 |
| --------------------------------- | --------- | --------------------------------- | ------------------------------------------------------ |
| `plan`                            | `string`  | `''`                              | JSON array of lint tasks; exclusive with the scalars   |
| `hooks`                           | `string`  | `''`                              | Space/comma separated hook ids to run                  |
| `skip_hooks`                      | `string`  | `''`                              | Hook ids to EXCLUDE; applies to every task             |
| `ci_skipped`                      | `boolean` | `false`                           | Run the `ci.skip` set; exclusive with `hooks`          |
| `config_path`                     | `string`  | `''`                              | Repository-relative configuration path                 |
| `config_url`                      | `string`  | `''`                              | HTTPS configuration URL                                |
| `config_sha256`                   | `string`  | `''`                              | Expected digest; requires `config_url`                 |
| `path_prefix`                     | `string`  | `.`                               | Config directory; if non-root, absence fails           |
| `org_fallback`                    | `boolean` | `true`                            | Fall back to the organisation's `.github` repository   |
| `org_config_path`                 | `string`  | `linting/.pre-commit-config.yaml` | Fallback path inside that repository                   |
| `split_hooks`                     | `boolean` | `true`                            | One matrix job per SELECTED hook                       |
| `fail_fast`                       | `boolean` | `false`                           | Cancel remaining lint jobs when one fails              |
| `branch_name`                     | `string`  | `''`                              | Checkout this branch first (for `no-commit-to-branch`) |
| `export_github_token`             | `boolean` | `true`                            | Export the workflow token to hooks on trusted events   |
| `prek_version`                    | `string`  | `0.4.14`                          | prek version used to run the hooks                     |
| `runs_on`                         | `string`  | `ubuntu-latest`                   | Runner label; Linux, and harden-runner must support it |
| `timeout_minutes`                 | `number`  | `15`                              | Timeout for each lint job                              |
| `harden_runner_egress`            | `string`  | `audit`                           | `audit` or `block`                                     |
| `harden_runner_allowed_endpoints` | `string`  | GitHub, PyPI/uv, Node, cache      | Allow-list applied when blocking                       |

<!-- markdownlint-enable MD013 -->

## Outputs

<!-- markdownlint-disable MD013 -->

| Output     | Description                                                        |
| ---------- | ------------------------------------------------------------------ |
| `has_work` | `'true'` when the plan resolved at least one lint task             |
| `matrix`   | The resolved plan as JSON with an `include` array; empty when idle |

<!-- markdownlint-enable MD013 -->

Both come from a fixed vocabulary or from plan-validated data, so a
caller may use `has_work` in a `run:` block without laundering it.

## Migration from compose-repo-linting

The legacy workflow took nine required `GERRIT_*` inputs and a
`pre_commit_skips` list, then ran every hook except those. This
workflow matches that behaviour with no inputs at all:

<!-- markdownlint-disable MD013 -->

| compose-repo-linting        | linting                                     |
| --------------------------- | ------------------------------------------- |
| `GERRIT_*` (nine, required) | none; the workflow checks out for itself    |
| `pre_commit_skips`          | `skip_hooks`, the same comma/space list     |
| `pipx run pre-commit`       | `prek` at a pinned version, via `uvx`       |
| separate actionlint job     | actionlint runs as a hook like any other    |
| runs everything not skipped | the same, and the default                   |

<!-- markdownlint-enable MD013 -->

A Gerrit-mirrored project migrates wholesale. A caller that set no
`pre_commit_skips` needs no `with:` block at all; one that did carries
the same list across to `skip_hooks`:

```yaml
with:
  skip_hooks: 'actionlint'
```

The reusable takes no Gerrit checkout inputs, matching the other
reusables in this repository.

An earlier revision of this workflow inverted the selection — running
the `ci.skip` set by default. That was wrong for precisely this
population: a Gerrit project has no pre-commit.ci and so no
meaningful `ci.skip`, so the default resolved no tasks and reported a
green check having linted nothing. `ci_skipped: true` now asks for
that set explicitly, and repositories where pre-commit.ci covers the
rest are the ones that want it.

## Relationship to standalone-linting-action

The action is the executor for a single task: resolve one
configuration, install prek, run one hook set. The workflow is the
planner: it decides what the tasks are and fans them out.

Neither needs a checkout from the caller. The plan job checks out for
itself (sparsely, or fully in `plan` mode), and each lint job's
checkout happens inside the action. A caller adding `actions/checkout`
gains nothing.

Use the action directly for a single fixed lint step inside an
existing job. Use the workflow when you want the organisation
fallback, hook selection by `ci.skip`, or parallel tasks.
