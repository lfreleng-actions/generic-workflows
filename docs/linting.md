<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

<!-- markdownlint-disable MD013 -->

# Linting reusable workflow

`.github/workflows/linting.yaml` runs pre-commit hooks with
[prek](https://github.com/j178/prek), standalone from pre-commit.ci. A
thin caller in each consuming repository runs on pull request events
and delegates to it.

The primary use case is the hooks pre-commit.ci cannot run. The
pre-commit.ci sandbox blocks network access at scan time and caps hook
environment size, so hooks such as `gha-workflow-linter` (which calls
the GitHub API) or `aislop` (which runs dependency audits) get listed
under `ci.skip` in the repository's `.pre-commit-config.yaml` and never
run in CI at all. This workflow runs that precise set.

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
   gets installed. A configuration that never mentions it cannot carry
   a `ci.skip` key.
3. Should that pass, the job installs `uv` and parses the
   configuration.
4. When no tasks resolve, `has_work` is `false`, the `lint` matrix
   never instantiates, and the run ends green with a step summary
   saying so.

A repository with no configuration, no organisation fallback, or an
empty `ci.skip` never provisions a lint runner.

The pre-filter uses a loose substring test rather than a key-shaped
regex by design, because its failure modes are not symmetric. A false
positive costs one needless parse. A false negative reports a green
check having linted nothing, which is the worst outcome available to a
mandated check. YAML admits `skip:`, `skip :`, `"skip":` and the flow
form `ci: {"skip": [...]}`, and a pattern tight enough to match keys
alone missed three of those four; `tests/test-lint-plan.sh` pins every
spelling. The one residue is a key written with escapes (`\x73kip`),
which a repository could do to its own configuration alone, and which
would hide that repository's own hooks rather than affect anyone else.

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
| `config_path`/`config_url` | Every hook in that configuration                  |
| Nothing                    | The hook ids listed under `ci.skip` (the default) |

<!-- markdownlint-enable MD013 -->

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
job, so a slow hook does not delay the rest. Set it `false` to run them
sequentially in one job when start-up cost outweighs the parallelism.

## The JSON plan

For anything the scalar inputs cannot express — CI-excluded hooks, an
explicitly named subset, a remote configuration and a local
supplemental one, all in the same run — pass a JSON array. Each entry
is an object:

<!-- markdownlint-disable MD013 -->

| Key             | Type              | Meaning                                              |
| --------------- | ----------------- | ---------------------------------------------------- |
| `name`          | string            | Task label shown in the job name                     |
| `ci_skipped`    | boolean           | Run the hooks listed under `ci.skip`                 |
| `hooks`         | string or array   | Hook ids to run (exclusive with `ci_skipped`)        |
| `config_path`   | string            | Repository-relative configuration path               |
| `config_url`    | string            | HTTPS configuration URL (exclusive with the above)   |
| `config_sha256` | string            | Expected digest; requires `config_url`               |

<!-- markdownlint-enable MD013 -->

The resolver enforces these types rather than coercing them, so
`"ci_skipped": "false"`, `"hooks": []` or `"name": 1` fails with a
message naming the offending value instead of selecting another mode
in silence.

<!-- markdownlint-enable MD013 -->

An entry with neither `hooks` nor `ci_skipped` runs every hook in its
configuration. An entry naming no configuration uses the primary one.
Under `split_hooks`, the entry's `name` prefixes each job
(`docs / markdownlint`), so a job still says which entry produced it.

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
`repos`, a missing or null `hooks`, and non-mapping entries. A third
pins the fast-abort pre-filter against every YAML spelling of the
`skip` key.

`tests/test-locate-rules.sh` covers the four shell decisions that sit
*earlier* than the resolver and determine whether it runs at all: the
dangling-symlink walk, the organisation-fallback status mapping, the
`path_prefix` classification and the workspace-containment test. Each
turns an unknown into a verdict, so a wrong answer there ends in a
green check that linted nothing — or, as repeated rounds of review
found, a red one for a repository that was entirely valid. It asserts
that HTTP 404 alone reads as absent (401, 403, 429, 5xx and curl's own
`000` are errors), that the walk catches a dangling symlink at the
configuration filename or at a parent component, that the
classification accepts a directory symlink as a valid prefix, and that
the workspace root itself counts as contained while a same-prefix
sibling does not.

A note on `path_prefix`, the least obvious rule: **git** classifies
it, not the filesystem. Under the sparse checkout a directory whose
matched file is absent from the repository never gets materialised, so
"not on disk" is the normal case for a valid prefix that holds no
configuration. The classification reads the tree entry's mode rather
than filtering with `ls-tree -d`, because git stores a symlink as a
blob and `-d` would reject a symlinked prefix outright.

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
  attacker needs. Callers trigger on `pull_request` or `push`.
- **No secrets consumed.** The workflow uses none. It passes the
  workflow token to hooks needing API access, and a called workflow's
  token cannot exceed its caller's, which grants `contents: read`.

  Runs whose checkout can carry fork-controlled hooks never receive
  one, whatever `export_github_token` says: a **fork** pull request,
  and **`merge_group`**, whose temporary merge commit contains the
  queued pull requests. There the hooks come from outside the base
  repository and run arbitrary commands, so handing them the token
  invites exfiltration — trivially under the default `audit` egress
  policy, which observes rather than blocks — and even a read token
  reads private base-repository content. A same-repository pull
  request or a push has no such gap, because the hooks and the token
  share an origin. Set `export_github_token: false` to withhold it
  everywhere.
- **No expression interpolation in `run` blocks.** Every input, matrix
  value and repository-derived string reaches a shell through `env`,
  which closes template injection even though the configuration
  contents are attacker-controlled on a fork pull request.
- **Path containment before first read.** `path_prefix`,
  `config_path` and `org_config_path` must be relative, free of `..`,
  and free of any component starting with `-` (such a path reads as
  command-line options, and a failing `grep` would report "nothing to
  lint"); commands pass `--` as a second lock. The plan job then
  resolves them with `realpath` and confirms the real path stays
  inside `GITHUB_WORKSPACE`, which catches symlink escapes that a
  string check would miss. Containment runs *before* the file gets
  read, since both `[ -f ]` and `grep` follow symlinks; a
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
- **No planning/linting drift.** The plan job hashes every remote
  configuration and passes the digest to the lint job, which verifies
  the same bytes it fetches. A git blob SHA pins the organisation
  fallback, and its digest gets verified too, so what ran cannot
  differ from what the plan validated.
- **Bounded fan-out.** The plan caps at 50 tasks, and hook ids, task
  names and digests are pattern-checked, so a hostile configuration
  cannot spawn unbounded jobs or smuggle shell metacharacters into a
  job name.
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
the self-caller or the example.

## Runner

`runs_on` defaults to `ubuntu-slim`, GitHub's minimal Ubuntu image,
which provisions fastest — the right trade for a short job that runs on
every pull request across an estate. prek is a single static binary
that provisions the Python and Node.js toolchains a hook environment
declares, so the workflow does not depend on the runner's tool cache.
Set `runs_on: 'ubuntu-latest'` where a hook needs something the slim
image omits.

The runner must be Linux: harden-runner enforces an egress policy on
Linux alone, and elsewhere degrades to a warning. Both jobs check
`RUNNER_OS` and fail rather than run unhardened.

`harden_runner_egress` defaults to `audit`, not `block`. Hook
environments legitimately fetch from hosts specific to whichever hooks
a repository configures, and no fixed allow-list can predict them; a
blocking default would fail runs for sound
repositories. Callers with a known hook set should pass `block` and
extend `harden_runner_allowed_endpoints`.

## Inputs

<!-- markdownlint-disable MD013 -->

| Input                             | Type      | Default                           | Effect                                                           |
| --------------------------------- | --------- | --------------------------------- | ---------------------------------------------------------------- |
| `plan`                            | `string`  | `''`                              | JSON array of lint tasks; exclusive with the scalars             |
| `hooks`                           | `string`  | `''`                              | Space/comma separated hook ids to run                            |
| `config_path`                     | `string`  | `''`                              | Repository-relative configuration path                           |
| `config_url`                      | `string`  | `''`                              | HTTPS configuration URL                                          |
| `config_sha256`                   | `string`  | `''`                              | Expected digest; requires `config_url`                           |
| `path_prefix`                     | `string`  | `.`                               | Directory containing project code                                |
| `org_fallback`                    | `boolean` | `true`                            | Fall back to the organisation's `.github` repository             |
| `org_config_path`                 | `string`  | `linting/.pre-commit-config.yaml` | Fallback path inside that repository                             |
| `split_hooks`                     | `boolean` | `true`                            | One parallel matrix job per hook                                 |
| `fail_fast`                       | `boolean` | `false`                           | Cancel remaining lint jobs when one fails                        |
| `branch_name`                     | `string`  | `''`                              | Checkout this branch first (for `no-commit-to-branch`)           |
| `export_github_token`             | `boolean` | `true`                            | Export the workflow token to hooks; never on fork PR/merge_group |
| `prek_version`                    | `string`  | `0.4.14`                          | prek version used to run the hooks                               |
| `runs_on`                         | `string`  | `ubuntu-slim`                     | Runner label; Linux alone                                        |
| `timeout_minutes`                 | `number`  | `15`                              | Timeout for each lint job                                        |
| `harden_runner_egress`            | `string`  | `audit`                           | `audit` or `block`                                               |
| `harden_runner_allowed_endpoints` | `string`  | GitHub, PyPI/uv, Node.js hosts    | Allow-list applied when blocking                                 |

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
`pre_commit_skips` list, then ran every hook except those. The
selection is now inverted, and there are no required inputs:

<!-- markdownlint-disable MD013 -->

| compose-repo-linting        | linting                                             |
| --------------------------- | --------------------------------------------------- |
| `GERRIT_*` (nine, required) | none; the caller performs a plain checkout          |
| `pre_commit_skips`          | none; `ci.skip` in the configuration drives the run |
| `pipx run pre-commit`       | `prek` at a pinned version, via `uvx`               |
| separate actionlint job     | actionlint runs as a hook like any other            |
| runs everything not skipped | runs the skipped set (or an explicit selection)     |

<!-- markdownlint-enable MD013 -->

A Gerrit-mirrored project uses this workflow unchanged. The reusable
takes no Gerrit checkout inputs, matching the other reusables in this
repository.

## Relationship to standalone-linting-action

The action is the executor for a single task: resolve one
configuration, install prek, run one hook set. The workflow is the
planner: it decides what the tasks are and fans them out.

Use the action directly for a single fixed lint step inside an
existing job. Use the workflow when you want the default `ci.skip`
behaviour, the organisation fallback, or parallel tasks.
