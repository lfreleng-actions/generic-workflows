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
if command -v uv > /dev/null 2>&1; then
  PY_RUN=(uv run --no-project --with pyyaml==6.0.2 python)
elif python3 -c 'import yaml' > /dev/null 2>&1; then
  PY_RUN=(python3)
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
    INPUT_PLAN='' \
    INPUT_HOOKS='' \
    INPUT_CONFIG_PATH='' \
    INPUT_CONFIG_URL='' \
    INPUT_CONFIG_SHA256='' \
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

# --- Selection modes -------------------------------------------------

# The estate-wide default: run whatever this repository lists under
# ci.skip, one matrix entry per hook.
accept 'default ci.skip mode'
matrix_contains 'default mode picks up ci.skip' 'gha-workflow-linter'

accept 'explicit hooks, comma separated' \
  INPUT_HOOKS='yamllint,markdownlint'
matrix_contains 'split_hooks fans out' '"name":"markdownlint"'

accept 'explicit hooks, grouped' \
  INPUT_HOOKS='yamllint markdownlint' INPUT_SPLIT_HOOKS='false'
matrix_contains 'grouped mode emits one task' \
  '"hooks":"yamllint markdownlint"'

accept 'local config path' \
  INPUT_CONFIG_PATH='.pre-commit-config.yaml'

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

# A JSON boolean, not a truthy value. The string "false" is truthy in
# Python, so accepting it would select the opposite mode in silence.
reject 'ci_skipped as the string "false"' \
  INPUT_PLAN='[{"name":"a","ci_skipped":"false"}]'

reject 'ci_skipped as a number' \
  INPUT_PLAN='[{"name":"a","ci_skipped":1}]'

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
long_id="$(printf 'a%.0s' $(seq 1 80))"
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

# A scalar ci.skip iterates CHARACTER BY CHARACTER, so 'skip: mypy'
# yields m, y, p, y -- none a hook id, resolving no tasks.
reject_config 'ci.skip as a scalar' 'ci:
  skip: mypy
repos:
  - repo: local
    hooks:
      - id: mypy
        name: mypy
        entry: mypy
        language: system'

reject_config 'ci.skip holding a non-string' 'ci:
  skip: [1]
repos:
  - repo: local
    hooks:
      - id: mypy
        name: mypy
        entry: mypy
        language: system'

reject_config 'ci as a scalar' 'ci: enabled
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

reject_config 'ci.skip explicitly null' 'ci:
  skip:
repos:
  - repo: local
    hooks:
      - id: mypy
        name: mypy
        entry: mypy
        language: system'

# --- Fast-abort pre-filter -------------------------------------------

# The plan step greps a configuration for 'skip' before installing any
# tooling, and reports "nothing to lint" when the word is absent. That
# shortcut is the one place where a wrong answer is SILENT: a false
# negative reports a green check having run nothing at all.
#
# Assert the workflow still uses the LOOSE substring test, then confirm
# that test survives every YAML spelling of the key. A tighter,
# key-shaped pattern passes the first two fixtures and fails the rest.
if ! grep -q "grep -qi 'skip'" "${workflow}"; then
  echo 'ERROR: the fast-abort pre-filter in' >&2
  echo "       ${workflow}" >&2
  echo "       is no longer the loose \"grep -qi 'skip'\" test." >&2
  echo '       A key-shaped pattern misses the flow mapping and' >&2
  echo '       space-before-colon spellings, which silently skips' >&2
  echo '       linting. Update this test deliberately if the' >&2
  echo '       pre-filter genuinely changed.' >&2
  exit 1
fi

check_prefilter() {
  local desc="$1" expect="$2" content="$3"
  local fixture="${workdir}/prefilter.yaml" got='absent'

  printf '%s\n' "${content}" > "${fixture}"

  # The same test the workflow performs.
  if grep -qi 'skip' "${fixture}"; then
    got='present'
  fi

  if [ "${got}" = "${expect}" ]; then
    passed=$((passed + 1))
    return 0
  fi

  failed=$((failed + 1))
  printf 'FAIL: pre-filter %s (expected %s, got %s)\n' "${desc}" \
    "${expect}" "${got}" >&2
  printf '  fixture: %s\n' "${content}" >&2
}

# Every spelling must be seen, or those hooks silently never run.
check_prefilter 'block mapping' 'present' 'ci:
  skip: [gha-workflow-linter]'

check_prefilter 'space before colon' 'present' 'ci:
  skip : [gha-workflow-linter]'

check_prefilter 'flow mapping' 'present' \
  'ci: {"skip": [gha-workflow-linter]}'

check_prefilter 'double-quoted key' 'present' 'ci:
  "skip": [gha-workflow-linter]'

check_prefilter 'block sequence value' 'present' 'ci:
  skip:
    - gha-workflow-linter'

# No mention of the key anywhere, so the abort is sound.
check_prefilter 'no ci block' 'absent' 'repos:
  - repo: local
    hooks:
      - id: example'

# --- Result ----------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
  exit 1
fi
