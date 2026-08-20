#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the lint plan resolver in
# .github/workflows/linting.yaml.
#
# The resolver decides which hooks run, against which configuration,
# from repository content that a fork pull request controls. Getting it
# wrong is expensive in both directions: too strict and a mandated
# estate-wide check blocks merges on repositories with nothing to lint,
# too loose and a hostile configuration steers the job. Half these
# fixtures are therefore rejection cases.
#
# The resolver is EXTRACTED from the workflow rather than copied here,
# so there is one implementation and these fixtures always exercise the
# code that actually runs in CI. Removing or renaming the markers in the
# workflow fails this script rather than silently testing nothing.
#
# Usage: tests/test-lint-plan.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflow="${repo_root}/.github/workflows/linting.yaml"

if [ ! -f "${workflow}" ]; then
  echo "ERROR: workflow not found: ${workflow}" >&2
  exit 1
fi

# Pick an interpreter that can import yaml.
#
# The resolver needs PyYAML, which reaches it by one of two routes.
# Locally, uv supplies it per-run. Under pre-commit/prek the hook is a
# 'language: python' hook whose environment declares PyYAML as an
# additional dependency, and pre-commit.ci's sandbox has no uv and no
# network to fetch one -- so requiring uv here failed every run there.
#
# Finding neither is a FAILURE, never a skip. A skip would let the
# hook report success without running a single fixture, which is the
# silent no-op these tests exist to catch elsewhere.
# The interpreter runs ISOLATED ('-I') under '--no-config', matching
# the workflow. Both are security controls there, not tidiness.
#
# '-I': the resolver is fed on stdin, so the current directory joins
# sys.path, and on a fork pull request that directory is the
# attacker's checkout.
#
# '--no-config': '--no-project' stops uv treating the checkout as a
# project but not DISCOVERING configuration in it, so a committed
# 'uv.toml' can redirect the index this '--with pyyaml' resolves
# from. Running the fixtures against an untrusted checkout without it
# would install a checkout-selected package before the isolated
# interpreter ever starts.
if command -v uv > /dev/null 2>&1; then
  PY_RUN=(uv run --no-project --no-config --with pyyaml==6.0.2
    python -I)
elif python3 -I -c 'import yaml' > /dev/null 2>&1; then
  PY_RUN=(python3 -I)
else
  echo 'ERROR: no interpreter with PyYAML available' >&2
  echo '       Install uv (https://docs.astral.sh/uv/), or run' >&2
  echo '       this through the pre-commit hook, which supplies' >&2
  echo '       PyYAML via additional_dependencies.' >&2
  exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
resolver="${workdir}/plan.py"

# Copy the marked region out of the heredoc, stripping the YAML block
# indentation measured from the BEGIN marker itself, so the extraction
# survives the workflow being re-nested.
awk '
  /# BEGIN lint_plan/ {
    indent = match($0, /[^ ]/) - 1
    capture = 1
    next
  }
  /# END lint_plan/ { capture = 0; next }
  capture { print substr($0, indent + 1) }
' "${workflow}" > "${resolver}"

if ! grep -q 'def add_hook_tasks' "${resolver}"; then
  echo "ERROR: no resolver between the markers in" >&2
  echo "       ${workflow}" >&2
  echo "       Restore the '# BEGIN lint_plan' and" >&2
  echo "       '# END lint_plan' comments around the Python body." >&2
  exit 1
fi

# A structural check, because the behaviour it guards needs a
# trickling HTTPS server to provoke and the resolver accepts https
# URLs alone -- so no fixture below can reach it.
#
# urlopen's 'timeout=' bounds ONE blocking socket operation, not the
# transfer. A server dribbling bytes inside that window holds a
# connection open indefinitely, and planning would then accept a URL
# the executor's 'curl --max-time 60' refuses -- a plan that resolves
# cleanly and fails in every lint job. The wall-clock deadline is what
# stops that, so assert it is still there.
if ! grep -q 'time.monotonic() + DOWNLOAD_TIMEOUT' "${resolver}"; then
  echo 'ERROR: the URL download in' >&2
  echo "       ${workflow}" >&2
  echo '       no longer enforces a wall-clock deadline.' >&2
  echo "       urlopen's timeout= bounds one socket read, not the" >&2
  echo '       transfer, so a slow-trickle server would be accepted' >&2
  echo "       at plan time and rejected by the executor's" >&2
  echo '       curl --max-time. Restore the monotonic deadline.' >&2
  exit 1
fi

# The deadline has to be tested after EVERY read, including the empty
# one that signals EOF. A server can deliver its last bytes inside the
# budget and then sit on the close for a full socket timeout, so a
# check placed after the EOF break lets that transfer through late.
#
# The read must also be read1, not read. HTTPResponse.read(n) loops on
# the socket until it has n bytes, so a trickling server keeps ONE
# call blocked and a deadline between calls never fires -- the check
# on ORDER alone would still pass. read1 performs at most one raw
# read, which is what makes the deadline reachable.
# Both guards match the COMMAND LINE, anchored, not any occurrence in
# the file. The comments that explain these flags quote them, so a
# loose 'grep -q' passes on the explanation alone -- the shipped
# command could lose the flag while its own justification kept the
# check green.
if ! grep -qE "^[[:space:]]*python -I - <<'PYEOF'\$" "${workflow}"
then
  echo 'ERROR: the resolver in' >&2
  echo "       ${workflow}" >&2
  echo '       no longer runs isolated (python -I -).' >&2
  echo "       'python -' puts the CHECKOUT on sys.path, so a fork" >&2
  echo '       can commit yaml.py or sitecustomize.py, write' >&2
  echo '       has_work=false to GITHUB_OUTPUT and exit 0 before' >&2
  echo '       the resolver runs a line.' >&2
  exit 1
fi

# '--no-project' does NOT stop uv discovering configuration in the
# checkout. A fork-committed 'uv.toml' can redirect the index that
# '--with pyyaml' resolves from, so the package imported ahead of the
# resolver becomes attacker code -- which '-I' cannot prevent,
# because it arrives AS PyYAML rather than beside it.
if ! grep -qE '^[[:space:]]*uv run --no-project --no-config --with' \
  "${workflow}"; then
  echo 'ERROR: the resolver in' >&2
  echo "       ${workflow}" >&2
  echo '       no longer runs uv with --no-config. A fork-committed' >&2
  echo '       uv.toml could then choose the index PyYAML installs' >&2
  echo '       from, and that package is imported before the' >&2
  echo '       resolver runs.' >&2
  exit 1
fi

if ! grep -q 'chunk = response.read1(' "${resolver}"; then
  echo 'ERROR: the URL download in' >&2
  echo "       ${workflow}" >&2
  echo '       no longer uses read1. HTTPResponse.read(n) loops on' >&2
  echo '       the socket until it has n bytes, so a slow-trickle' >&2
  echo '       server blocks inside one call and the wall-clock' >&2
  echo '       deadline is never consulted.' >&2
  exit 1
fi

# Assert the ORDER rather than proximity: the comment explaining this
# sits between the two statements, so a fixed-size window would be
# wrong either way round.
line_of() {
  grep -n "$1" "${resolver}" | head -1 | cut -d: -f1
}
read_line="$(line_of 'chunk = response.read1(')"
deadline_line="$(line_of 'if time.monotonic() > deadline:')"
eof_line="$(line_of 'if not chunk:')"

if [ -z "${read_line}" ] || [ -z "${deadline_line}" ] ||
  [ -z "${eof_line}" ] ||
  [ "${deadline_line}" -lt "${read_line}" ] ||
  [ "${deadline_line}" -gt "${eof_line}" ]; then
  echo 'ERROR: the download deadline in' >&2
  echo "       ${workflow}" >&2
  echo '       no longer sits between the read and the EOF break.' >&2
  echo '       After the break it misses a server that stalls on' >&2
  echo '       close, and planning then accepts a transfer the' >&2
  echo '       executor refuses.' >&2
  exit 1
fi

# The planner must refuse what the executor cannot fetch. These two
# numbers are one contract kept in two repositories, so a change here
# needs a matching change to standalone-linting-action.
if ! grep -q '^DOWNLOAD_TIMEOUT = 60$' "${resolver}"; then
  echo 'ERROR: DOWNLOAD_TIMEOUT no longer matches the executor' >&2
  echo "       action's 'curl --max-time 60'. Planning and" >&2
  echo '       execution would disagree about which URLs are' >&2
  echo '       fetchable. Change both, or neither.' >&2
  exit 1
fi

passed=0
failed=0

# Run the resolver against this repository's own configuration, with
# the environment the plan step would set. $1 is a label, $2 the
# expected verdict ('ok' or 'err'), and the rest are VAR=VALUE pairs
# layered over the defaults.
check() {
  local desc="$1" expect="$2"
  shift 2
  local got='ok'

  : > "${workdir}/out"
  : > "${workdir}/summary"

  if ! env \
    GITHUB_WORKSPACE="${repo_root}" \
    RUNNER_TEMP="${workdir}" \
    GITHUB_OUTPUT="${workdir}/out" \
    GITHUB_STEP_SUMMARY="${workdir}/summary" \
    PRIMARY='.pre-commit-config.yaml' \
    ORG_JSON='' \
    PRIMARY_ERROR='' \
    INPUT_PLAN='' \
    INPUT_HOOKS='' \
    INPUT_CONFIG_PATH='' \
    INPUT_CONFIG_URL='' \
    INPUT_CONFIG_SHA256='' \
    INPUT_CI_SKIPPED='false' \
    INPUT_SPLIT_HOOKS='true' \
    INPUT_ORG_CONFIG_PATH='linting/.pre-commit-config.yaml' \
    "$@" \
    "${PY_RUN[@]}" "${resolver}" \
    > "${workdir}/stdout" 2>&1; then
    got='err'
  fi

  if [ "${got}" = "${expect}" ]; then
    passed=$((passed + 1))
    return 0
  fi

  failed=$((failed + 1))
  printf 'FAIL: %s (expected %s, got %s)\n' "${desc}" "${expect}" \
    "${got}" >&2
  sed 's/^/  /' "${workdir}/stdout" >&2
}

# The resolver produces a plan.
accept() { check "$1" 'ok' "${@:2}"; }

# The resolver refuses, so no lint job ever starts.
reject() { check "$1" 'err' "${@:2}"; }

# Assert on the matrix the last accepted case wrote.
matrix_contains() {
  local desc="$1" needle="$2"

  if grep -q -- "${needle}" "${workdir}/out"; then
    passed=$((passed + 1))
    return 0
  fi

  failed=$((failed + 1))
  printf 'FAIL: %s (matrix lacks %s)\n' "${desc}" "${needle}" >&2
  sed 's/^/  /' "${workdir}/out" >&2
}

# Assert on the log the last case wrote.
stdout_contains() {
  local desc="$1" needle="$2"

  if grep -q -- "${needle}" "${workdir}/stdout"; then
    passed=$((passed + 1))
    return 0
  fi

  failed=$((failed + 1))
  printf 'FAIL: %s (log lacks %s)\n' "${desc}" "${needle}" >&2
  sed 's/^/  /' "${workdir}/stdout" >&2
}

stdout_lacks() {
  local desc="$1" needle="$2"

  if grep -q -- "${needle}" "${workdir}/stdout"; then
    failed=$((failed + 1))
    printf 'FAIL: %s (log unexpectedly has %s)\n' "${desc}" \
      "${needle}" >&2
    sed 's/^/  /' "${workdir}/stdout" >&2
    return 0
  fi

  passed=$((passed + 1))
}

# Count the tasks the last accepted case emitted.
#
# 'grep -o' exits 1 when it matches nothing, and under 'set -o
# pipefail' that failure propagates through the substitution and
# 'set -e' kills the suite -- silently, mid-run, with no output at
# all. So the helper could not express the one assertion an
# empty-configuration fixture needs: expect ZERO tasks.
matrix_task_count() {
  local desc="$1" expect="$2" got

  got="$( { grep -o '"name":' "${workdir}/out" || true; } |
    wc -l | tr -d ' ')"
  if [ "${got}" = "${expect}" ]; then
    passed=$((passed + 1))
    return 0
  fi

  failed=$((failed + 1))
  printf 'FAIL: %s (expected %s task(s), got %s)\n' "${desc}" \
    "${expect}" "${got}" >&2
  sed 's/^/  /' "${workdir}/out" >&2
}

# --- Selection modes -------------------------------------------------

# The estate-facing mode: run whatever this repository lists under
# ci.skip, one matrix entry per hook.
accept 'ci_skipped mode' INPUT_CI_SKIPPED='true'
matrix_contains 'ci_skipped mode picks up ci.skip' 'gha-workflow-linter'

# The DEFAULT is the inverse, and resolves to one whole-config task.
# A repository without pre-commit.ci has no meaningful ci.skip, so a
# ci.skip default would report green having linted nothing there.
accept 'default mode runs the whole configuration'
matrix_contains 'the default task selects no hooks' '"hooks":""'
matrix_task_count 'the default resolves to one job' 1

accept 'explicit hooks, comma separated' \
  INPUT_HOOKS='yamllint,markdownlint'
matrix_contains 'split_hooks fans out' '"name":"markdownlint"'

accept 'explicit hooks, grouped' \
  INPUT_HOOKS='yamllint markdownlint' INPUT_SPLIT_HOOKS='false'
matrix_contains 'grouped mode emits one task' \
  '"hooks":"yamllint markdownlint"'

# The configuration SOURCE and the hook SELECTION are orthogonal, and
# plan entries have always supported the combination. In scalar mode a
# named config reached the run-all branch first and discarded the
# ci_skipped the caller wrote -- an input that looks like it ran and
# did not.
accept 'ci_skipped narrows a named config_path' \
  INPUT_CONFIG_PATH='.pre-commit-config.yaml' \
  INPUT_CI_SKIPPED='true'
matrix_contains 'the ci.skip hook reached the matrix' \
  'gha-workflow-linter'

# And without it, the same named configuration still runs whole.
accept 'a named config_path alone runs whole' \
  INPUT_CONFIG_PATH='.pre-commit-config.yaml'
matrix_contains 'the whole-config task selects no hooks' '"hooks":""'
matrix_task_count 'it stays one job' 1

accept 'local config path' \
  INPUT_CONFIG_PATH='.pre-commit-config.yaml'

# A task that runs the WHOLE configuration is not a selection, so
# split_hooks has nothing to divide: prek runs a configuration in its
# declared order, and fanning it out would rebuild every hook
# environment once per job. Pin the grouping here, so a later reading
# of split_hooks as 'always one job per hook' cannot turn one job
# into one per hook in the whole file.
accept 'a bare config_path runs whole under split_hooks' \
  INPUT_CONFIG_PATH='.pre-commit-config.yaml' \
  INPUT_SPLIT_HOOKS='true'
matrix_contains 'a whole-config task selects no hooks' '"hooks":""'
matrix_task_count 'a whole-config task stays one job' 1

accept 'a plan entry with no selector runs whole' \
  INPUT_PLAN='[{"name":"everything"}]' INPUT_SPLIT_HOOKS='true'
matrix_contains 'the entry keeps its own name' '"name":"everything"'
matrix_task_count 'the entry stays one job' 1

accept 'plan with ci_skipped and an explicit task' \
  INPUT_PLAN='[{"name":"a","ci_skipped":true},{"name":"b","hooks":"mypy"}]'
# Split mode keeps the entry's label as a prefix, so a job name still
# says which plan entry it came from.
matrix_contains 'plan resolves both entries' '"name":"b / mypy"'

# An empty ci.skip is not an error: the workflow skips instead.
accept 'no work resolves cleanly' \
  PRIMARY='' ORG_JSON=''

# --- Hook validation -------------------------------------------------

reject 'hook absent from the configuration' \
  INPUT_HOOKS='no-such-hook-anywhere'

reject 'plan hook absent from the configuration' \
  INPUT_PLAN='[{"name":"a","hooks":"no-such-hook-anywhere"}]'

reject 'hooks and ci_skipped are mutually exclusive' \
  INPUT_PLAN='[{"name":"a","ci_skipped":true,"hooks":"mypy"}]'

# Both KEYS present is the conflict, whatever the boolean says.
# Testing the value accepted this and ignored the ci_skipped written.
reject 'hooks with ci_skipped false still conflicts' \
  INPUT_PLAN='[{"name":"a","ci_skipped":false,"hooks":"mypy"}]'

# A JSON boolean, not a truthy value. The string "false" is truthy in
# Python, so accepting it would select the opposite mode in silence.
reject 'ci_skipped as the string "false"' \
  INPUT_PLAN='[{"name":"a","ci_skipped":"false"}]'

reject 'ci_skipped as a number' \
  INPUT_PLAN='[{"name":"a","ci_skipped":1}]'

# An explicit false selects nothing, and falling through to the 'no
# selector' branch would run EVERY hook -- broadening the entry
# rather than narrowing it. Omitting the key is how you run all.
reject 'ci_skipped false alone' \
  INPUT_PLAN='[{"name":"a","ci_skipped":false}]'

# An empty string is a value the caller supplied, not an omission.
# Returning the default for it let {"config_path":""} fall through to
# the primary configuration and run every hook there -- the same
# silent discard as an explicit null, one type further on.
reject 'an empty config_path' \
  INPUT_PLAN='[{"name":"a","config_path":""}]'

reject 'an empty config_url' \
  INPUT_PLAN='[{"name":"a","config_url":""}]'

# An empty name would otherwise take the 'task-N' default, quietly
# renaming the job away from what the caller wrote.
reject 'an empty name' \
  INPUT_PLAN='[{"name":"","hooks":"yamllint"}]'

# Every later check guards on 'if sha', so an empty digest skipped
# the format rule AND the requires-config_url rule, leaving a caller
# believing content was pinned when nothing was.
reject 'an empty config_sha256' \
  INPUT_PLAN='[{"name":"a","config_sha256":"","hooks":"yamllint"}]'

# json.loads keeps the LAST occurrence of a duplicate key and says
# nothing, discarding the first value. That is an input which looks
# like it ran and did not -- a hard error everywhere else here, and
# it reached the resolver by a quieter route.
reject 'a plan entry with a duplicated selector key' \
  INPUT_PLAN='[{"name":"a","hooks":"mypy","hooks":"yamllint"}]'

# The duplicate need not be a selector: a repeated name relabels the
# job away from what the caller wrote.
reject 'a plan entry with a duplicated name key' \
  INPUT_PLAN='[{"name":"a","name":"b","hooks":"yamllint"}]'

# Ordered so the surviving value is VALID on its own. The reverse
# spelling collapses to 'ci_skipped: false', which the rule above
# already rejects, and the fixture would then pass without exercising
# the duplicate check at all.
reject 'a plan entry with a duplicated ci_skipped key' \
  INPUT_PLAN='[{"name":"a","ci_skipped":false,"ci_skipped":true}]'

# --- Injection and traversal guards ----------------------------------

# A hook id carrying shell metacharacters must never reach a job name
# or a command line.
reject 'shell metacharacters in a hook id' \
  INPUT_PLAN='[{"name":"a","hooks":["x;rm -rf /"]}]'

# The single quotes below are deliberate: the fixture payload is the
# literal text '$(id)' and '${{ ... }}', which must reach the resolver
# unexpanded to test that it refuses them.
# shellcheck disable=SC2016
reject 'command substitution in a task name' \
  INPUT_PLAN='[{"name":"$(id)","hooks":"mypy"}]'

# shellcheck disable=SC2016
reject 'expression syntax in a task name' \
  INPUT_PLAN='[{"name":"${{ secrets.X }}","hooks":"mypy"}]'

# A hook id beginning '-' reaches the prek command line as an OPTION.
# 'prek run --help' exits 0, so such an id would report a hook as
# passed without running it.
reject 'hook id that is a prek option' \
  INPUT_PLAN='[{"name":"a","hooks":["--help"]}]'

reject 'hook id with a leading hyphen' \
  INPUT_HOOKS='-v'

# A glob must reach validation as the literal character. Splitting
# with an unquoted expansion would expand it against the checkout
# first, validating file names instead of the value in play.
reject 'glob as a hook id' \
  INPUT_HOOKS='*'

reject 'glob as a plan hook id' \
  INPUT_PLAN='[{"name":"a","hooks":["*"]}]'

reject 'task name with a leading hyphen' \
  INPUT_PLAN='[{"name":"-rf","hooks":"mypy"}]'

reject 'parent traversal in config_path' \
  INPUT_CONFIG_PATH='../.pre-commit-config.yaml'

reject 'absolute config_path' \
  INPUT_CONFIG_PATH='/etc/passwd'

reject 'parent traversal in a plan config_path' \
  INPUT_PLAN='[{"name":"a","config_path":"../../etc/passwd"}]'

# A plan entry's path is repository-controlled and lands on a command
# line, in GITHUB_OUTPUT, in a matrix value and in the Markdown step
# summary. It gets the same syntax contract as the scalar input.
reject 'leading hyphen in a plan config_path' \
  INPUT_PLAN='[{"name":"a","config_path":"-foo/cfg.yaml"}]'

reject 'leading hyphen on a plan config_path component' \
  INPUT_PLAN='[{"name":"a","config_path":"ok/-foo/cfg.yaml"}]'

# These two point at files that EXIST, so the syntax check is the only
# thing rejecting them. Were it removed, the entry would resolve and
# the case would pass -- which is what gives the fixture teeth.
mkdir -p "${workdir}/badnames"
for bad in 'a|b.yaml' 'a b.yaml'; do
  cat > "${workdir}/badnames/${bad}" <<'BADCFG'
ci:
  skip: []
repos:
  - repo: local
    hooks:
      - id: x
        name: x
        entry: true
        language: system
BADCFG
done

# A pipe would inject a column into the summary table.
reject 'pipe in a plan config_path' \
  INPUT_PLAN='[{"name":"a","config_path":"a|b.yaml"}]' \
  GITHUB_WORKSPACE="${workdir}/badnames"

reject 'space in a plan config_path' \
  INPUT_PLAN='[{"name":"a","config_path":"a b.yaml"}]' \
  GITHUB_WORKSPACE="${workdir}/badnames"

# A newline would inject a whole summary row.
reject 'newline in a plan config_path' \
  INPUT_PLAN='[{"name":"a","config_path":"a\nb.yaml"}]'

reject 'config_path that does not exist' \
  INPUT_CONFIG_PATH='no/such/config.yaml'

# --- URL guards ------------------------------------------------------

reject 'plaintext http URL' \
  INPUT_CONFIG_URL='http://example.org/config.yaml'

reject 'file scheme URL' \
  INPUT_CONFIG_URL='file:///etc/passwd'

reject 'config_path and config_url together' \
  INPUT_PLAN='[{"name":"a","config_path":".pre-commit-config.yaml","config_url":"https://example.org/c.yaml"}]'

reject 'malformed config_sha256 in a plan entry' \
  INPUT_PLAN='[{"name":"a","config_url":"https://example.org/c.yaml","config_sha256":"nothex"}]'

# A digest only travels with a config_url task, so accepting one
# without a URL would drop the pin while telling the caller nothing.
reject 'config_sha256 without config_url' \
  INPUT_CONFIG_SHA256='0000000000000000000000000000000000000000000000000000000000000000'

reject 'plan config_sha256 without config_url' \
  INPUT_PLAN='[{"name":"a","config_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}]'

reject 'non-string config_sha256' \
  INPUT_PLAN='[{"name":"a","config_url":"https://example.org/c.yaml","config_sha256":0}]'

# --- Plan type strictness -------------------------------------------

# 'raw or ""' would fold each of these into 'no selector', and no
# selector runs EVERY hook: malformed input must not broaden what
# executes.
reject 'hooks as false' \
  INPUT_PLAN='[{"name":"a","hooks":false}]'

reject 'hooks as zero' \
  INPUT_PLAN='[{"name":"a","hooks":0}]'

reject 'hooks as an empty array' \
  INPUT_PLAN='[{"name":"a","hooks":[]}]'

reject 'hooks as an empty string' \
  INPUT_PLAN='[{"name":"a","hooks":""}]'

reject 'hooks as an object' \
  INPUT_PLAN='[{"name":"a","hooks":{}}]'

reject 'hooks array holding a non-string' \
  INPUT_PLAN='[{"name":"a","hooks":[1]}]'

# 'str(x or "")' would accept any type: a numeric name becomes a
# valid string, and a falsey config_path reads as 'omitted', falling
# through to the primary configuration and running every hook there.
reject 'name as a number' \
  INPUT_PLAN='[{"name":1,"hooks":"mypy"}]'

reject 'config_path as false' \
  INPUT_PLAN='[{"name":"a","config_path":false}]'

reject 'config_url as a number' \
  INPUT_PLAN='[{"name":"a","config_url":0}]'

reject 'config_path as an object' \
  INPUT_PLAN='[{"name":"a","config_path":{}}]'

# An explicit null is a supplied value of the wrong type, not an
# omitted key. Treating the two alike drops a field the caller wrote
# -- and an omitted 'hooks' selector runs EVERY hook.
reject 'hooks as null' \
  INPUT_PLAN='[{"name":"a","hooks":null}]'

reject 'config_path as null' \
  INPUT_PLAN='[{"name":"a","config_path":null}]'

reject 'config_sha256 as null' \
  INPUT_PLAN='[{"name":"a","config_url":"https://example.org/c.yaml","config_sha256":null}]'

reject 'name as null' \
  INPUT_PLAN='[{"name":null,"hooks":"mypy"}]'

# --- Plan shape guards -----------------------------------------------

reject 'plan that is not JSON' \
  INPUT_PLAN='not json at all'

reject 'plan that is not an array' \
  INPUT_PLAN='{"name":"a"}'

reject 'empty plan array' \
  INPUT_PLAN='[]'

reject 'plan entry that is not an object' \
  INPUT_PLAN='["mypy"]'

reject 'plan entry with an unknown key' \
  INPUT_PLAN='[{"name":"a","command":"whoami"}]'

# Built through PY_RUN, not a bare 'python3': the interpreter
# selection above may have settled on uv, and a uv-only machine need
# not carry a system Python at all.
over_cap="$("${PY_RUN[@]}" -c \
  'import json; print(json.dumps([{"name": f"t{i}"} for i in range(60)]))')"

reject 'plan exceeding the task cap' \
  INPUT_PLAN="${over_cap}"

# A long-but-legal hook id must survive being used as a task name.
# NAME_RE bounds what a CALLER may write (64 characters); a derived
# name built from an already-valid label and hook id gets a larger
# budget, so re-applying the caller limit would reject valid input.
long_id="$(printf 'a%.0s' {1..80})"
mkdir -p "${workdir}/longcfg"
cat > "${workdir}/longcfg/.pre-commit-config.yaml" <<LONGCFG
ci:
  skip: []
repos:
  - repo: local
    hooks:
      - id: ${long_id}
        name: long
        entry: true
        language: system
LONGCFG

accept 'hook id longer than the caller name limit' \
  INPUT_PLAN="[{\"name\":\"a\",\"hooks\":[\"${long_id}\"]}]" \
  GITHUB_WORKSPACE="${workdir}/longcfg" \
  PRIMARY='.pre-commit-config.yaml'

# --- ci.skip must name hooks that exist ------------------------------

# A stale or mistyped ci.skip entry used to be filtered away, leaving
# an empty selection, zero tasks and a green check. An explicit
# 'hooks' list already failed on an undefined id, so the same concept
# was held to two standards -- and the looser one governed the DEFAULT
# mode every repository in the estate runs.

skipdir="${workdir}/ciskip"
mkdir -p "${skipdir}"

write_skip_config() {
  printf '%s\n' "$1" > "${skipdir}/.pre-commit-config.yaml"
}

# A defined hook, so the fixtures below differ from this ONLY in
# whether ci.skip names something real.
write_skip_config 'ci:
  skip: [real-hook]
repos:
  - repo: local
    hooks:
      - id: real-hook
        name: real
        entry: true
        language: system'

accept 'ci.skip naming a defined hook' \
  GITHUB_WORKSPACE="${skipdir}" INPUT_CI_SKIPPED='true' \
  PRIMARY='.pre-commit-config.yaml'
matrix_contains 'the defined hook becomes a task' '"hooks":"real-hook"'

# The finding. Default mode, one mistyped id, nothing else wrong.
write_skip_config 'ci:
  skip: [real-hook-typo]
repos:
  - repo: local
    hooks:
      - id: real-hook
        name: real
        entry: true
        language: system'

reject 'ci.skip naming an undefined hook' \
  GITHUB_WORKSPACE="${skipdir}" INPUT_CI_SKIPPED='true' \
  PRIMARY='.pre-commit-config.yaml'

# A partial match is the more likely spelling of the mistake, and the
# old filter hid it completely: one hook ran, the other vanished, and
# the check went green having done half the job.
write_skip_config 'ci:
  skip: [real-hook, gone-hook]
repos:
  - repo: local
    hooks:
      - id: real-hook
        name: real
        entry: true
        language: system'

reject 'ci.skip mixing a defined and an undefined hook' \
  GITHUB_WORKSPACE="${skipdir}" INPUT_CI_SKIPPED='true' \
  PRIMARY='.pre-commit-config.yaml'

# Same rule through a plan entry, since the two paths had drifted
# apart once already.
reject 'a ci_skipped plan entry with an undefined hook' \
  INPUT_PLAN='[{"name":"a","ci_skipped":true}]' \
  GITHUB_WORKSPACE="${skipdir}" INPUT_CI_SKIPPED='true' \
  PRIMARY='.pre-commit-config.yaml'

# Syntax is diagnosed BEFORE definedness. The old order filtered a
# hostile id out first, so it was reported as merely absent -- or, in
# default mode, not reported at all.
write_skip_config 'ci:
  skip: ["--help"]
repos:
  - repo: local
    hooks:
      - id: real-hook
        name: real
        entry: true
        language: system'

reject 'ci.skip carrying an option-shaped id' \
  GITHUB_WORKSPACE="${skipdir}" INPUT_CI_SKIPPED='true' \
  PRIMARY='.pre-commit-config.yaml'

# An EMPTY ci.skip stays legitimate: the repository is saying
# pre-commit.ci skips nothing, so this workflow has nothing to pick
# up. It must resolve cleanly, not fail -- that is the estate-wide
# common case, and failing it would block merges everywhere.
write_skip_config 'ci:
  skip: []
repos:
  - repo: local
    hooks:
      - id: real-hook
        name: real
        entry: true
        language: system'

accept 'an empty ci.skip resolves cleanly' \
  GITHUB_WORKSPACE="${skipdir}" INPUT_CI_SKIPPED='true' \
  PRIMARY='.pre-commit-config.yaml'

# --- A deferred primary-configuration problem ------------------------

# The locate step no longer exits when the PRIMARY configuration is
# broken and a plan is in play: a plan whose entries each name their
# own config never reads the primary, so failing would abort tasks
# that had no use for it. The reason travels here instead, and only
# an entry that actually falls through pays for it.

broken="the default config is a symlink to nowhere"

accept 'an all-explicit plan ignores a broken primary' \
  PRIMARY='' PRIMARY_ERROR="${broken}" \
  INPUT_PLAN='[{"name":"a","config_path":".pre-commit-config.yaml"}]'

# The entry names no configuration, so it does fall through, and the
# deferred reason becomes the failure rather than a bare 'none
# exists' that discards the diagnosis.
reject 'a plan entry falling through to a broken primary' \
  PRIMARY='' PRIMARY_ERROR="${broken}" \
  INPUT_PLAN='[{"name":"a"}]'

# Without a recorded problem the old message still applies, so the
# deferral cannot mask a genuinely absent configuration.
reject 'a plan entry needing an absent primary' \
  PRIMARY='' ORG_JSON='' \
  INPUT_PLAN='[{"name":"a"}]'

# --- Malformed configurations ----------------------------------------

# A configuration that asks for work but is structurally wrong must
# FAIL, not resolve to zero tasks and report green. Each fixture below
# carries a non-empty ci.skip, so "no tasks" would be the silent
# wrong answer rather than an honest one.
reject_config() {
  local desc="$1" content="$2"
  local dir="${workdir}/cfg"

  rm -rf "${dir}"
  mkdir -p "${dir}"
  printf '%s\n' "${content}" > "${dir}/.pre-commit-config.yaml"

  check "${desc}" 'err' \
    GITHUB_WORKSPACE="${dir}" \
    PRIMARY='.pre-commit-config.yaml'
}

# As above, but in ci_skipped mode. The 'ci' block is read there and
# nowhere else, so validating it under the run-all default would
# break the rule the rest of this workflow follows: inspect only what
# will be read.
reject_ci_config() {
  local desc="$1" content="$2"
  local dir="${workdir}/cicfg"

  rm -rf "${dir}"
  mkdir -p "${dir}"
  printf '%s\n' "${content}" > "${dir}/.pre-commit-config.yaml"

  check "${desc}" 'err' \
    GITHUB_WORKSPACE="${dir}" \
    INPUT_CI_SKIPPED='true' \
    PRIMARY='.pre-commit-config.yaml'
}

# A scalar ci.skip iterates CHARACTER BY CHARACTER, so 'skip: mypy'
# yields m, y, p, y -- none a hook id, resolving no tasks.
reject_ci_config 'ci.skip as a scalar' 'ci:
  skip: mypy
repos:
  - repo: local
    hooks:
      - id: mypy
        name: mypy
        entry: mypy
        language: system'

reject_ci_config 'ci.skip holding a non-string' 'ci:
  skip: [1]
repos:
  - repo: local
    hooks:
      - id: mypy
        name: mypy
        entry: mypy
        language: system'

reject_ci_config 'ci as a scalar' 'ci: enabled
repos:
  - repo: local
    hooks:
      - id: mypy
        name: mypy
        entry: mypy
        language: system'

reject_config 'repos as a mapping' 'ci:
  skip: [mypy]
repos:
  local:
    - id: mypy'

reject_config 'a repos entry that is not a mapping' 'ci:
  skip: [mypy]
repos:
  - just-a-string'

reject_config 'hooks as a scalar' 'ci:
  skip: [mypy]
repos:
  - repo: local
    hooks: mypy'

reject_config 'a hooks entry that is not a mapping' 'ci:
  skip: [mypy]
repos:
  - repo: local
    hooks:
      - just-a-string'

reject_config 'a hook with no id' 'ci:
  skip: [mypy]
repos:
  - repo: local
    hooks:
      - name: mypy
        entry: mypy
        language: system'

reject_config 'a hook with a non-string id' 'ci:
  skip: [mypy]
repos:
  - repo: local
    hooks:
      - id: 1
        name: mypy
        entry: mypy
        language: system'

reject_config 'a hook with an empty id' 'ci:
  skip: [mypy]
repos:
  - repo: local
    hooks:
      - id: ""
        name: mypy
        entry: mypy
        language: system'

# 'repos' is required by pre-commit's schema, so an absent key is
# malformed rather than empty. Returning an empty hook set would
# resolve no tasks and report green for a config asking for work.
reject_config 'no repos key at all' 'ci:
  skip: [mypy]'

reject_config 'repos explicitly null' 'ci:
  skip: [mypy]
repos:'

# 'hooks' is required per repo, and 'ci.skip' must be a real list;
# an explicit null in either place is a typo that would otherwise
# resolve to no tasks and report green.
reject_config 'a repo with no hooks key' 'ci:
  skip: [mypy]
repos:
  - repo: local'

reject_config 'a repo with hooks null' 'ci:
  skip: [mypy]
repos:
  - repo: local
    hooks:'

reject_ci_config 'ci.skip explicitly null' 'ci:
  skip:
repos:
  - repo: local
    hooks:
      - id: mypy
        name: mypy
        entry: mypy
        language: system'

# yaml.safe_load keeps the LAST value for a duplicate mapping key and
# says nothing, so the first is discarded. Here that turns a file
# plainly listing a hook into an empty selection, zero tasks and a
# green check -- and on a fork pull request this file is
# attacker-controlled.
reject_config 'a duplicated ci.skip key' 'ci:
  skip: [mypy]
  skip: []
repos:
  - repo: local
    hooks:
      - id: mypy
        name: mypy
        entry: mypy
        language: system'

# The rule is not special-cased to ci.skip: a duplicate anywhere
# discards a value the file supplied. Both blocks here are VALID, so
# last-wins yields a working configuration and nothing but the
# duplicate check can reject it.
reject_config 'a duplicated top-level repos key' 'ci:
  skip: [mypy]
repos:
  - repo: local
    hooks:
      - id: mypy
        name: mypy
        entry: mypy
        language: system
repos:
  - repo: local
    hooks:
      - id: mypy
        name: mypy
        entry: mypy
        language: system'

# Nested mappings are covered too, since the loader applies at every
# level rather than to the document root.
reject_config 'a duplicated key inside a hook' 'ci:
  skip: [mypy]
repos:
  - repo: local
    hooks:
      - id: mypy
        name: mypy
        entry: mypy
        entry: true
        language: system'

# A merge key is valid pre-commit YAML, and the duplicate-key
# hardening must not narrow the accepted syntax. This scan runs
# before flatten_mapping, so the '<<' node still carries the merge
# tag and a naive construct_object on it fails outright.
accept_config() {
  local desc="$1" content="$2"
  local dir="${workdir}/okcfg"

  rm -rf "${dir}"
  mkdir -p "${dir}"
  printf '%s\n' "${content}" > "${dir}/.pre-commit-config.yaml"

  # ci_skipped mode, so the assertions below can name the hook that
  # reached the matrix. Under the run-all default every one of these
  # would resolve to the same anonymous whole-config task, which
  # would not distinguish a merge key that resolved from one that
  # silently lost its contents.
  accept "${desc}" GITHUB_WORKSPACE="${dir}" \
    INPUT_CI_SKIPPED='true' \
    PRIMARY='.pre-commit-config.yaml'
}

accept_config 'a merge key resolves normally' '.defaults: &defaults
  language: system
  entry: true
ci:
  skip: [mypy]
repos:
  - repo: local
    hooks:
      - id: mypy
        name: mypy
        <<: *defaults'
matrix_contains 'the merged hook still becomes a task' '"hooks":"mypy"'

# Overriding a merged value is what a merge key is FOR, so the
# collision it creates must stay legal.
accept_config 'a merge key overridden by a later key' '.defaults: &defaults
  language: system
  entry: false
ci:
  skip: [mypy]
repos:
  - repo: local
    hooks:
      - id: mypy
        name: mypy
        <<: *defaults
        entry: true'

# The sequence form is ONE merge key and the supported way to merge
# several mappings, so it stays legal too.
accept_config 'the sequence form of a merge key' '.base: &base
  language: system
.entry: &entry
  entry: true
ci:
  skip: [mypy]
repos:
  - repo: local
    hooks:
      - id: mypy
        name: mypy
        <<: [*base, *entry]'

# A SECOND merge key is the defect: PyYAML flattens both and lets the
# later win, so the first merge is discarded without a word. The scan
# for ordinary duplicates never sees it, because merge keys are
# skipped there.
reject_config 'a second merge key in one mapping' '.first: &first
  ci:
    skip: [mypy]
.second: &second
  ci:
    skip: []
repos:
  - repo: local
    hooks:
      - id: mypy
        name: mypy
        entry: mypy
        language: system
<<: *first
<<: *second'

# --- Organisation fallback size limit --------------------------------

# The Contents API returns the configuration base64-encoded inside a
# JSON envelope, so the curl that fetches it allows 2 MiB. The real
# 1 MiB limit therefore has to be enforced on the DECODED bytes, or
# the two paths disagree about what fits: an org configuration would
# be accepted where the identical bytes over config_url were refused.

make_org_json() {
  # $1=output path $2=payload size in bytes
  "${PY_RUN[@]}" - "$1" "$2" <<'ORGJSON'
import base64, hashlib, json, sys

path, size = sys.argv[1], int(sys.argv[2])
# A COMPLETE, valid configuration, padded to size with a comment.
# A payload that was merely large but malformed would be rejected
# whether or not the size check existed, and the fixture would prove
# nothing about the rule it names.
head = (
    b"ci:\n  skip: [mypy]\nrepos:\n  - repo: local\n"
    b"    hooks:\n      - id: mypy\n        name: mypy\n"
    b"        entry: mypy\n        language: system\n"
)
body = head + b"# " + b"x" * (size - len(head) - 2)
assert len(body) == size, (len(body), size)
blob = hashlib.sha1(b"blob %d\0" % len(body) + body).hexdigest()
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "sha": blob,
            "encoding": "base64",
            "content": base64.b64encode(body).decode(),
        },
        handle,
    )
ORGJSON
}

# One byte over, so nothing but the size check can refuse it.
make_org_json "${workdir}/org-big.json" 1048577
reject 'an organisation configuration over the size limit' \
  PRIMARY='' ORG_JSON="${workdir}/org-big.json"

# And one byte under, so a rule that rejected everything large would
# not satisfy the case above by accident.
make_org_json "${workdir}/org-ok.json" 1048576
accept 'an organisation configuration at the size limit' \
  PRIMARY='' INPUT_CI_SKIPPED='true' ORG_JSON="${workdir}/org-ok.json"
matrix_contains 'the large-but-legal configuration still plans' \
  '"hooks":"mypy"'

# --- Isolation from the checkout -------------------------------------

# The workflow feeds the resolver on stdin, which puts the CURRENT
# DIRECTORY on sys.path -- and on a fork pull request that directory
# is the attacker's checkout. A committed 'yaml.py' would be imported
# in place of PyYAML before the resolver runs a line, free to append
# 'has_work=false' to GITHUB_OUTPUT and exit 0.
#
# Run the resolver the way the workflow does -- on stdin, from a
# working directory holding a hostile module -- and assert it is not
# hijacked. The other fixtures pass the resolver as a FILE, where
# sys.path[0] is the script's own directory, so none of them can
# reach this.
hostile="${workdir}/hostile"
mkdir -p "${hostile}"
cat > "${hostile}/yaml.py" <<'HOSTILE'
import os
import sys

out = os.environ.get("GITHUB_OUTPUT")
if out:
    with open(out, "a", encoding="utf-8") as handle:
        handle.write("has_work=false\n")
sys.exit(0)
HOSTILE
cp "${repo_root}/.pre-commit-config.yaml" "${hostile}/"

: > "${workdir}/out"
if (cd "${hostile}" && env \
  GITHUB_WORKSPACE="${hostile}" \
  RUNNER_TEMP="${workdir}" \
  GITHUB_OUTPUT="${workdir}/out" \
  GITHUB_STEP_SUMMARY="${workdir}/summary" \
  PRIMARY='.pre-commit-config.yaml' \
  ORG_JSON='' INPUT_PLAN='' INPUT_HOOKS='' \
  INPUT_CONFIG_PATH='' INPUT_CONFIG_URL='' INPUT_CONFIG_SHA256='' \
  INPUT_SPLIT_HOOKS='true' PRIMARY_ERROR='' \
  INPUT_ORG_CONFIG_PATH='linting/.pre-commit-config.yaml' \
  "${PY_RUN[@]}" - < "${resolver}" > "${workdir}/stdout" 2>&1)
then
  if grep -q 'has_work=false' "${workdir}/out"; then
    failed=$((failed + 1))
    printf 'FAIL: %s\n' \
      'a hostile yaml.py in the checkout hijacked the resolver' >&2
    sed 's/^/  /' "${workdir}/out" >&2
  else
    passed=$((passed + 1))
  fi
else
  failed=$((failed + 1))
  printf 'FAIL: %s\n' \
    'the resolver failed to run from a hostile directory' >&2
  sed 's/^/  /' "${workdir}/stdout" >&2
fi

# An intentionally EMPTY configuration is valid -- 'repos: []' says
# 'no hooks' on purpose, and the loader accepts it deliberately. But
# prek errors on an empty selection, so emitting a whole-config task
# for one turned a valid repository into a FAILED lint job: the
# mirror of the silent green everything else here guards against.
empty_dir="${workdir}/emptycfg"
mkdir -p "${empty_dir}"
printf 'repos: []\n' > "${empty_dir}/.pre-commit-config.yaml"

accept 'an empty configuration resolves to no tasks' \
  GITHUB_WORKSPACE="${empty_dir}" PRIMARY='.pre-commit-config.yaml'
matrix_task_count 'it emits no lint job at all' 0

accept 'an empty configuration named explicitly' \
  GITHUB_WORKSPACE="${empty_dir}" PRIMARY='.pre-commit-config.yaml' \
  INPUT_CONFIG_PATH='.pre-commit-config.yaml'
matrix_task_count 'the named path emits none either' 0

accept 'an empty configuration through a plan entry' \
  GITHUB_WORKSPACE="${empty_dir}" PRIMARY='.pre-commit-config.yaml' \
  INPUT_PLAN='[{"name":"a"}]'
matrix_task_count 'the plan entry emits none either' 0

# --- Hook stages a run cannot reach ----------------------------------
#
# prek runs pre-commit hooks, and manual ones when named; the other
# nine stages it passes over without output at exit 0. So a
# configuration declaring 'stages: [commit-msg]' -- gitlint being the
# common one -- gets a green check that never touched it, and the
# run-all default reports 'all hooks' while doing so.
#
# The resolver cannot fix that; the executor decides what it ran, and
# standalone-linting-action#156 tracks it. What the resolver can do is
# refuse to let it pass unmentioned.

stage_dir="${workdir}/stagecfg"
rm -rf "${stage_dir}"
mkdir -p "${stage_dir}"

printf '%s\n' 'repos:
  - repo: local
    hooks:
      - id: ruff
        name: ruff
        entry: "true"
        language: system
      - id: gitlint
        name: gitlint
        entry: "true"
        language: system
        stages: [commit-msg]' \
  > "${stage_dir}/.pre-commit-config.yaml"

accept 'a configuration with a commit-msg hook still plans' \
  GITHUB_WORKSPACE="${stage_dir}" PRIMARY='.pre-commit-config.yaml'

# Named, so a reader of the run knows which hook went unrun rather
# than being told something vague about stages.
stdout_contains 'the unreachable hook is named' 'gitlint'
stdout_contains 'its stage is named' 'commit-msg'
stdout_contains 'it is a warning annotation' '::warning::'

# The reachable hook must NOT be reported: a warning naming every
# hook is one nobody reads, and ruff runs perfectly well.
stdout_lacks 'a runnable hook is not named' 'ruff ('

# 'manual' hooks DO run when a task names them, so they are not
# unreachable and must stay out of the warning.
printf '%s\n' 'repos:
  - repo: local
    hooks:
      - id: manual-hook
        name: manual hook
        entry: "true"
        language: system
        stages: [manual]' \
  > "${stage_dir}/.pre-commit-config.yaml"

accept 'a manual-stage hook plans' \
  GITHUB_WORKSPACE="${stage_dir}" PRIMARY='.pre-commit-config.yaml'
stdout_lacks 'a manual hook raises no warning' '::warning::'

# A hook listing BOTH reaches the run through pre-commit, so it is
# not unreachable either. Testing the intersection rather than the
# first element: a check reading stages[0] would report this one.
printf '%s\n' 'repos:
  - repo: local
    hooks:
      - id: both-stages
        name: both stages
        entry: "true"
        language: system
        stages: [commit-msg, pre-commit]' \
  > "${stage_dir}/.pre-commit-config.yaml"

accept 'a hook listing a reachable stage among others plans' \
  GITHUB_WORKSPACE="${stage_dir}" PRIMARY='.pre-commit-config.yaml'
stdout_lacks 'it raises no warning' '::warning::'

# --- display_config ---------------------------------------------------
#
# The job summary is readable by anyone who can see the run, and the
# accepted URL grammar admits userinfo and a query string -- which is
# how a private configuration is usually served, by a presigned URL or
# an embedded token. Writing the URL whole would publish them.
#
# Extracted and called directly: reaching this end to end needs a live
# HTTPS server, and the resolver accepts nothing else.

check_redaction() {
  local desc="$1" url="$2" expect="$3" got

  got="$("${PY_RUN[@]}" - "${resolver}" "${url}" <<'PYEOF'
import ast
import sys
import urllib.parse

source = open(sys.argv[1], encoding="utf-8").read()
namespace = {"urllib": urllib}
for node in ast.parse(source).body:
    if (
        isinstance(node, ast.FunctionDef)
        and node.name == "display_config"
    ):
        module = ast.Module(body=[node], type_ignores=[])
        exec(compile(module, "<display_config>", "exec"), namespace)
if "display_config" not in namespace:
    sys.exit("no display_config() in the resolver")
print(
    namespace["display_config"](
        {"kind": "url", "config": sys.argv[2]}
    )
)
PYEOF
)"

  if [ "${got}" = "${expect}" ]; then
    passed=$((passed + 1))
    return 0
  fi

  failed=$((failed + 1))
  printf 'FAIL: %s (expected %s, got %s)\n' "${desc}" "${expect}" \
    "${got}" >&2
}

check_redaction 'a plain URL is shown whole' \
  'https://example.org/linting/cfg.yaml' \
  'https://example.org/linting/cfg.yaml'

# The two that carry credentials in practice.
check_redaction 'userinfo is removed' \
  'https://user:s3cret@example.org/cfg.yaml' \
  'https://example.org/cfg.yaml (userinfo redacted)'

check_redaction 'a presigned query is removed' \
  'https://example.org/cfg.yaml?X-Amz-Signature=deadbeef' \
  'https://example.org/cfg.yaml (query redacted)'

check_redaction 'both are removed and both are named' \
  'https://u:p@example.org/cfg.yaml?sig=x#frag' \
  'https://example.org/cfg.yaml (userinfo/query/fragment redacted)'

# A port is part of the origin, not a secret, so it survives.
check_redaction 'a port survives' \
  'https://example.org:8443/cfg.yaml' \
  'https://example.org:8443/cfg.yaml'

# --- Result ----------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
  exit 1
fi
