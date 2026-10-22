<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

<!-- markdownlint-disable MD013 -->

# Change isolation reusable workflow

`.github/workflows/change-isolation.yaml` checks that a change keeps
sensitive files apart from everything else. A caller lists the
isolation policies it wants as data; each runs as its own named job,
in parallel. When the change touches `INFO.yaml`, a separate job
validates it. A final `report` job folds every result into one outcome
the caller votes on.

It replaces two workflows in `lfit/releng-reusable-workflows`:
`gerrit-compose-required-change-isolation-verify.yaml`, which bundles
the `INFO.yaml` and `.github/**` policies in one serial job, and
`gerrit-compose-required-info-yaml-verify.yaml`, which runs the
`INFO.yaml` policy alone. With the policies as data, a project that
wants one of them no longer inherits the other.

## Job graph

```text
plan ──► Isolation: <check 1>   (matrix, one leg per check, no checkout) ──┐
    ├──► Isolation: <check n>                                             ├──► report
    └──► INFO.yaml                (when the change touches it)            ┘
```

1. `plan` checks the change out at depth 2, lists the files it touches
   with `git diff --no-renames`, validates `checks`, and works out
   what the change does to `INFO.yaml`.
2. `Isolation: <name>` runs once per check.
   [`change-isolation-action`](https://github.com/lfreleng-actions/change-isolation-action)
   receives the plan's file list through its `changed-files` input, so
   no leg checks anything out. `fail-fast` is off: every policy reports.
   Each leg uploads its result as artifact
   `change-isolation-result-<key>-<id>` (one-day retention). The id is
   the plan's number for the check, never the caller's check name,
   and the key is a random token the plan draws per call, keeping two
   calls in one run apart.
3. `INFO.yaml` runs when `info_yaml_validate` is on and the change
   touches the file. A changed file goes through
   [`info-yaml-validate-action`](https://github.com/lfreleng-actions/info-yaml-validate-action);
   a removed one fails before it. Without a Gerrit refspec, the job
   checks out the exact commit `plan` listed files for, so a `ref`
   that moves between the jobs cannot change what it validates. When the change leaves the file
   alone, the job shows as skipped, which reads in the run as
   "INFO.yaml not touched".
4. `report` runs whatever happened before it, collects the result
   artifacts, writes a step-summary table and sets the `results`
   output.

Adding a check adds one parallel leg, not serial time.

### What the report fails on

- the `plan` job failed;
- a check that is not advisory found the change not isolated;
- a planned check left **no** result, or one the report cannot read:
  a missing result never counts as a pass;
- a check's action ended in error;
- the `INFO.yaml` job failed, ended cancelled, or did not run although
  the change touched the file;
- an isolation job did not succeed, even one whose recorded result
  reads clean, such as a leg that failed after uploading it.

A change that triggers no check and leaves `INFO.yaml` alone passes.

## `checks`

```yaml
with:
  checks: |
    [
      {"name": "INFO.yaml", "paths": "/INFO.yaml"},
      {"name": "CI/CD",     "paths": ".github/**"}
    ]
```

| Key        | Required | Meaning                                                                        |
| ---------- | -------- | ------------------------------------------------------------------------------ |
| `name`     | yes      | Non-empty, unique, at most 100 characters; the job becomes `Isolation: <name>` |
| `paths`    | yes      | gitignore-style patterns, as a newline-separated string or an array of strings |
| `advisory` | no       | `true` reports a violation without failing; defaults to `false`                |

The patterns follow `change-isolation-action`'s semantics: a leading
`/` anchors to the repository root, a bare name matches at any depth,
`**` crosses directories and `!` negates. A check passes when the
change touches none of its paths (not triggered) or touches nothing
else (isolated).

`checks` has no default. Releng writes a mandatory `.github` workflow
once, and a project must never run a policy it did not state. The `plan` job fails, naming the offending entry, on malformed
JSON, anything but a non-empty array of objects, an unknown key, a
duplicate or missing name, a name with control characters or
surrounding whitespace, `paths` with no pattern or a pattern holding a
control character, and an `advisory` that is not a boolean. The shape
mirrors the `plan` input of `linting.yaml` on purpose.

## Inputs

| Input                     | Type      | Default           | Notes                                                                |
| ------------------------- | --------- | ----------------- | -------------------------------------------------------------------- |
| `checks`                  | `string`  | **required**      | JSON array; see above                                                |
| `info_yaml_validate`      | `boolean` | `true`            | Run the `INFO.yaml` job when the change touches the file             |
| `info_yaml_path`          | `string`  | `INFO.yaml`       | Root-relative and normalised; also the path that triggers the job    |
| `repository`              | `string`  | `''`              | Target `owner/name`; empty means the caller                          |
| `ref`                     | `string`  | `''`              | Ref to check out without a Gerrit refspec; empty is the run's commit |
| `gerrit_refspec`          | `string`  | `''`              | Gerrit change under test; selects the Gerrit checkout                |
| `gerrit_project`          | `string`  | `''`              | Gerrit project; also the project `INFO.yaml` must describe           |
| `gerrit_branch`           | `string`  | `''`              | Branch the change targets                                            |
| `gerrit_url`              | `string`  | `''`              | Gerrit URL; falls back to the `GERRIT_URL` variable                  |
| `runs_on`                 | `string`  | `ubuntu-latest`   | Linux runner harden-runner supports; not `ubuntu-slim`               |
| `timeout_minutes`         | `number`  | `10`              | Timeout for each isolation leg and the `INFO.yaml` job               |
| `harden_runner_egress`    | `string`  | `block`           | `block` or `audit`                                                   |
| `harden_runner_allowlist` | `string`  | `.github` v0.17.2 | Out-of-band allow-list coordinate                                    |

With `gerrit_refspec` set, `gerrit_project`, `gerrit_branch` and a
Gerrit URL are mandatory, and the plan fails without them. With
`gerrit_project` empty, `info-yaml-validate-action` reads the project
from `.gitreview`.

| Secret  | Required | Notes                                                                                  |
| ------- | -------- | -------------------------------------------------------------------------------------- |
| `token` | no       | Checks out a private `repository`; `GITHUB_TOKEN` reaches the calling repository alone |

## Outputs

| Output            | From     | Value                                                                                            |
| ----------------- | -------- | ------------------------------------------------------------------------------------------------ |
| `changed_files`   | `plan`   | Newline-separated paths the change touches                                                       |
| `info_yaml_state` | `plan`   | `untouched`, `changed` or `removed`                                                              |
| `results`         | `report` | JSON array, one object per check: `name`, `advisory`, `triggered`, `isolated`, `violating_files` |

`triggered` and `isolated` are booleans, or `null` for a check that
left no result. A caller can read `results` to automate a judgement,
such as which changes releng may self-approve, instead of reading it
off the run.

## Renames and deletions

The plan lists files with rename detection **off**, as
`change-isolation-action` does when it asks git itself, so a rename
surfaces as both its old and its new path:

- `git mv src/foo.py .github/foo.py` reports `src/foo.py` beside
  `.github/foo.py`, so the `.github/**` check sees a change that
  reaches outside its scope and fails;
- renaming `INFO.yaml` to `INFO.yml` reports `INFO.yaml` as deleted,
  and the state reads `removed`, not `untouched`.

`INFO.yaml` is mandatory in every Gerrit project, and
committer-management automation depends on it. A change that deletes
it, or renames it away, **fails** the `INFO.yaml` job; the workflow
never skips or warns.

The plan also fails closed when:

- `HEAD~1` is unreachable, leaving nothing to diff against;
- the change touches no files;
- a path holds a control character or surrounding whitespace. The
  list travels newline-separated, and the action strips whitespace
  around each entry, so it would read `.github/x` as `.github/x`.

The plan reads the file list from git directly rather than from
`repository-metadata-action`. That action reports a rename as a change
to the new path alone and returns an empty list when git fails, which
would make every check pass.

## Voting

The reusable casts no vote. Voting stays in the caller, as
[`examples/change-isolation/`](../examples/change-isolation/) shows:
`prepare` clears the vote, this workflow runs, and `vote` reads the
run's conclusion with `im-open/workflow-conclusion` and posts it with
`lfreleng-actions/gerrit-review-action`. That keeps the Gerrit SSH key
out of the reusable, leaves the choice of voting account with the
caller, and lets a caller compose this workflow with other verifiers
under a single vote.

`workflow-conclusion` sees called-workflow matrix legs and treats a
skipped job as a success; the `report` job's result makes the outcome
explicit regardless. It does not recognise a timed-out job, so the
examples vote `failure` whenever `prepare` or this workflow did not
succeed and the conclusion still reads `success`.

The examples' concurrency group names the Gerrit project as well as
the branch and Change-Id: Gerrit allows the same Change-Id in more
than one project, and a central `.github` repository dispatches for
every project.

## Security notes

- `plan` and `INFO.yaml` are the jobs that check the change out,
  with read access and without persisted credentials on the GitHub
  path. The isolation legs and `report` hold no repository permission
  at all.
- The plan and report scripts run as `python3 -I`, so a module in the
  checkout cannot replace one they import. The plan runs `git diff`
  with `--no-ext-diff` and `--no-textconv`, and with
  `--ignore-submodules=none`, so an `ignore` setting in the change's
  `.gitmodules` cannot hide a submodule bump from the file list.
- All variable data reaches `run:` blocks through `env:`, and every
  `uses:` pins a commit SHA.
- Each job loads the organisation allow-list and runs harden-runner;
  `harden_runner_egress` defaults to `block`.
- Lines the plan prints about paths and names carry a prefix, so a
  path cannot start a line with `::` and act as a workflow command.

## Migration

| Legacy input                                                                                                                               | This workflow                                 |
| ------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------- |
| `GERRIT_REFSPEC`                                                                                                                           | `gerrit_refspec`                              |
| `GERRIT_PROJECT`                                                                                                                           | `gerrit_project`                              |
| `GERRIT_BRANCH`                                                                                                                            | `gerrit_branch`                               |
| `TARGET_REPO`                                                                                                                              | `repository`                                  |
| `GERRIT_CHANGE_ID`, `GERRIT_CHANGE_NUMBER`, `GERRIT_CHANGE_URL`, `GERRIT_EVENT_TYPE`, `GERRIT_PATCHSET_NUMBER`, `GERRIT_PATCHSET_REVISION` | dropped: the legacy workflows never used them |
| `vars.GERRIT_URL`                                                                                                                          | unchanged fallback, or pass `gerrit_url`      |
| secret `token` (change isolation)                                                                                                          | secret `token`                                |
| secret `GERRIT_SSH_REQUIRED_PRIVKEY` (INFO.yaml verify)                                                                                    | dropped: the reusable needs no SSH key        |
| (policy fixed in the workflow)                                                                                                             | `checks`                                      |

| Legacy workflow                                   | `checks`                                                                                   |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `gerrit-compose-required-change-isolation-verify` | `[{"name": "INFO.yaml", "paths": "/INFO.yaml"}, {"name": "CI/CD", "paths": ".github/**"}]` |
| `gerrit-compose-required-info-yaml-verify`        | `[{"name": "INFO.yaml", "paths": "/INFO.yaml"}]`                                           |

Behaviour that changes on migration:

- `INFO.yaml` validation uses `info-yaml-validate-action` and its
  bundled schema rather than downloading `info-schema.yaml` from
  `releng-global-jjb` at run time.
- The legacy INFO.yaml verify workflow failed any change that touched
  `INFO.yaml` and anything else, matching the file name anywhere in
  the path; the `/INFO.yaml` pattern anchors to the root file.
- Deleting or renaming `INFO.yaml` away now fails.

While migrating, also:

- replace the `@main` reference that `FDio/.github` uses with a
  release **commit** SHA of this repository;
- replace `lfit/gerrit-review-action` with
  `lfreleng-actions/gerrit-review-action`;
- replace the archived `technote-space/workflow-conclusion-action`
  with `im-open/workflow-conclusion`.

[`examples/change-isolation/`](../examples/change-isolation/) holds
two callers: `gerrit.yaml`, the full ONAP-style caller with both
checks, and the FD.io shape beside it, which checks `INFO.yaml`
alone.

## Testing

`tests/test-change-isolation-plan.sh` extracts the plan and report
scripts from between their `BEGIN`/`END` markers and runs them against
throwaway git repositories and result files: valid and invalid
`checks`, renames, `INFO.yaml` modified, removed and renamed away, an
empty change, control characters in paths, violations, advisory
violations and missing results. The `change-isolation-fixtures` prek
hook runs it whenever the workflow or the script changes.

`.github/workflows/change-isolation-action.yaml` calls the workflow on
this repository's own pull requests, which exercises the job wiring
and the `INFO.yaml` skip. No arbitrary pull request can force a
violation, so the offline fixtures cover that path.
