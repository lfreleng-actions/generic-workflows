#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the Gerrit and plan logic in
# .github/workflows/tox-verify.yaml.
#
# The plan turns 'tox_envs' into the matrix, and each name reaches
# tox-run-action, which splits it into a tox command line. The plan
# fails closed, so half these fixtures are rejection cases: a mistake
# that lets an unsafe name through hands it to that command line.
#
# The scripts are EXTRACTED from the workflow rather than copied
# here, so these fixtures always exercise the code that runs in CI.
# The Gerrit script must also match change-isolation.yaml's byte for
# byte: the two workflows share one ref-validation rule, and this
# script fails when they drift. Removing or renaming the markers
# fails this script rather than silently testing nothing.
#
# Usage: tests/test-tox-verify-plan.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflow="${repo_root}/.github/workflows/tox-verify.yaml"
isolation="${repo_root}/.github/workflows/change-isolation.yaml"

for file in "${workflow}" "${isolation}"; do
  if [ ! -f "${file}" ]; then
    echo "ERROR: workflow not found: ${file}" >&2
    exit 1
  fi
done

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# Copy a marked region out of its heredoc, stripping the YAML block
# indentation measured from the BEGIN marker itself, so the extraction
# survives the workflow being re-nested.
extract() {
  local source="$1" marker="$2" target="$3" sentinel="$4"
  awk -v marker="${marker}" '
    $0 ~ "# BEGIN " marker "$" {
      indent = match($0, /[^ ]/) - 1
      capture = 1
      next
    }
    $0 ~ "# END " marker "$" { capture = 0; next }
    capture { print substr($0, indent + 1) }
  ' "${source}" > "${target}"
  if ! grep -q "${sentinel}" "${target}"; then
    echo "ERROR: no ${marker} script between the markers in" >&2
    echo "       ${source}" >&2
    echo "       Restore the '# BEGIN ${marker}' and" >&2
    echo "       '# END ${marker}' comments around it." >&2
    exit 1
  fi
}

plan_script="${workdir}/plan.py"
gerrit_script="${workdir}/gerrit.py"
isolation_gerrit="${workdir}/isolation-gerrit.py"
extract "${workflow}" tox_verify_plan "${plan_script}" 'def parse_envs'
extract "${workflow}" tox_verify_gerrit "${gerrit_script}" 'def checkout_ref'
extract "${isolation}" change_isolation_gerrit "${isolation_gerrit}" \
  'def checkout_ref'
credentials_script="${workdir}/drop-credentials.sh"
extract "${workflow}" tox_verify_drop_credentials "${credentials_script}" \
  'git-credentials-'

passed=0
failed=0

pass() { passed=$((passed + 1)); }
fail() {
  failed=$((failed + 1))
  printf 'FAIL: %s\n' "$1" >&2
  if [ -n "${2:-}" ]; then
    printf '%s\n' "$2" | sed 's/^/  | /' >&2
  fi
}

# --- Structure ------------------------------------------------------

if diff -u "${isolation_gerrit}" "${gerrit_script}" > "${workdir}/drift"
then
  pass
else
  fail 'the Gerrit script differs from change-isolation.yaml' \
    "$(cat "${workdir}/drift")"
fi

# Both scripts read caller input, so they must run isolated. Match
# the command line, anchored, rather than any mention in a comment.
isolated_runs=$(grep -cE "^[[:space:]]*python3 -I - <<'PYEOF'\$" \
  "${workflow}" || true)
if [ "${isolated_runs}" -eq 2 ]; then
  pass
else
  fail "expected 2 'python3 -I - <<'PYEOF'' runs, found ${isolated_runs}"
fi

# No input may reach a 'run' block by expression interpolation:
# variable data travels through 'env'. Report any 'run' block line
# that carries '${{'.
interpolated=$(awk '
  /^[[:space:]]*run:[[:space:]]*\|/ {
    indent = match($0, /[^ ]/) - 1
    inside = 1
    next
  }
  inside {
    if ($0 !~ /^[[:space:]]*$/ && match($0, /[^ ]/) - 1 <= indent) {
      inside = 0
    } else if (index($0, "${{")) {
      print FNR ": " $0
    }
  }
' "${workflow}")
if [ -z "${interpolated}" ]; then
  pass
else
  fail 'a run block interpolates an expression' "${interpolated}"
fi

# Every harden-runner pin is v2.22.3, which fixes the westus2 DNS
# bypass.
stale_pins=$(grep -n 'step-security/harden-runner@' "${workflow}" |
  grep -v '@46b06cea07f9e64621fdf066ba77ac6915163d43 ' || true)
if [ -z "${stale_pins}" ]; then
  pass
else
  fail 'a harden-runner pin is not v2.22.3' "${stale_pins}"
fi

# Print one output from a GITHUB_OUTPUT file in heredoc form.
read_output() {
  python3 -I - "$1" "$2" <<'PYEOF'
import sys

path, wanted = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().split("\n")
index = 0
while index < len(lines):
    line = lines[index]
    if "<<" in line:
        name, delimiter = line.split("<<", 1)
        end = lines.index(delimiter, index + 1)
        if name == wanted:
            print("\n".join(lines[index + 1:end]))
            sys.exit(0)
        index = end
    index += 1
sys.exit(1)
PYEOF
}

# --- Gerrit ref -----------------------------------------------------

# run_gerrit <branch> [url]: sets gerrit_rc, gerrit_log and gerrit_out.
run_gerrit() {
  gerrit_out="${workdir}/gerrit-output-${RANDOM}"
  : > "${gerrit_out}"
  gerrit_rc=0
  gerrit_log=$(GERRIT_URL="${2-https://gerrit.example.org}" \
    GERRIT_PROJECT='project' GERRIT_BRANCH="$1" \
    GITHUB_OUTPUT="${gerrit_out}" \
    python3 -I "${gerrit_script}" 2>&1) || gerrit_rc=$?
}

# expect_ref <gerrit_branch> <expected ref>
expect_ref() {
  local actual
  run_gerrit "$1"
  actual=$(sed -n 's/^ref=//p' "${gerrit_out}")
  if [ "${gerrit_rc}" -eq 0 ] && [ "${actual}" = "$2" ]; then
    pass
  else
    fail "ref of $1: expected $2, got '${actual}'" "${gerrit_log}"
  fi
}

# expect_ref_error <label> <gerrit_branch> <substring of the message>:
# no output, and the message must not echo the value.
expect_ref_error() {
  run_gerrit "$2"
  if [ "${gerrit_rc}" -eq 0 ]; then
    fail "$1: resolver passed, expected an error" "${gerrit_log}"
  elif ! grep -qF -- "$3" <<< "${gerrit_log}"; then
    fail "$1: no '$3' in the error" "${gerrit_log}"
  elif [ -s "${gerrit_out}" ]; then
    fail "$1: a failed resolver wrote outputs" "$(cat "${gerrit_out}")"
  elif grep -qF -- "$2" <<< "${gerrit_log}"; then
    fail "$1: the error echoes the branch" "${gerrit_log}"
  else
    pass
  fi
}

expect_ref 'master' 'refs/heads/master'
expect_ref 'refs/meta/config' 'refs/meta/config'
expect_ref 'refs/heads/master' 'refs/heads/master'
expect_ref 'release/1.2' 'refs/heads/release/1.2'

expect_ref_error 'branch with a space' 'my branch' 'contains whitespace'
expect_ref_error 'branch with a newline' \
  "$(printf 'main\n::warning::x')" 'contains a control character'
expect_ref_error 'branch with DEL' "$(printf 'ma\177in')" \
  'contains a control character'
expect_ref_error 'branch with U+009B' "$(printf 'ma\302\233in')" \
  'contains a control character'
expect_ref_error 'branch with ..' 'release/../main' 'not a valid ref name'
expect_ref_error 'branch with //' 'release//1.2' 'not a valid ref name'
expect_ref_error 'branch with a leading -' '-main' 'not a valid ref name'
expect_ref_error 'branch with a trailing /' 'release/' \
  'not a valid ref name'
expect_ref_error 'branch ending .lock' 'main.lock' 'not a valid ref name'

run_gerrit 'master' 'http://gerrit.example.org'
if [ "${gerrit_rc}" -ne 0 ] && [ ! -s "${gerrit_out}" ] &&
  grep -qF 'must start with https://' <<< "${gerrit_log}"; then
  pass
else
  fail 'http Gerrit URL: expected a rejection' "${gerrit_log}"
fi

gerrit_rc=0
gerrit_log=$(GERRIT_URL='https://gerrit.example.org' GERRIT_PROJECT='' \
  GERRIT_BRANCH='master' GITHUB_OUTPUT="${workdir}/unused" \
  python3 -I "${gerrit_script}" 2>&1) || gerrit_rc=$?
if [ "${gerrit_rc}" -ne 0 ] &&
  grep -qF 'missing: gerrit_project' <<< "${gerrit_log}"; then
  pass
else
  fail 'missing gerrit_project: expected a rejection' "${gerrit_log}"
fi

# --- Plan -----------------------------------------------------------

# run_plan <tox_envs> [VAR=value ...]: sets plan_rc, plan_log and
# plan_out. Defaults match the workflow's input defaults.
run_plan() {
  local envs="$1"
  shift
  plan_out="${workdir}/plan-output-${RANDOM}"
  : > "${plan_out}"
  plan_rc=0
  plan_log=$(env -i PATH="${PATH}" \
    INPUT_TOX_ENVS="${envs}" \
    INPUT_PATH_PREFIX='.' \
    INPUT_PARALLEL='auto' \
    INPUT_HARDEN_RUNNER_EGRESS='block' \
    INPUT_HARDEN_RUNNER_ALLOWLIST='lfreleng-actions//list.txt@abc' \
    INPUT_HARDEN_RUNNER_SUPPLEMENTAL_ALLOWLIST='' \
    GITHUB_OUTPUT="${plan_out}" \
    "$@" python3 -I "${plan_script}" 2>&1) || plan_rc=$?
}

# expect_matrix <label> <tox_envs> <expected matrix> [VAR=value ...]
expect_matrix() {
  local label="$1" envs="$2" expected="$3" actual
  shift 3
  run_plan "${envs}" "$@"
  actual=$(read_output "${plan_out}" matrix) || actual='<missing>'
  if [ "${plan_rc}" -eq 0 ] && [ "${actual}" = "${expected}" ]; then
    pass
  else
    fail "${label}: expected ${expected}, got ${actual}" "${plan_log}"
  fi
}

# expect_plan_error <label> <tox_envs> <message> [VAR=value ...]: the
# plan fails, names the problem, writes no output, and never echoes
# the tox_envs value.
expect_plan_error() {
  local label="$1" envs="$2" message="$3"
  shift 3
  run_plan "${envs}" "$@"
  if [ "${plan_rc}" -eq 0 ]; then
    fail "${label}: plan passed, expected an error" "${plan_log}"
  elif ! grep -qF -- "${message}" <<< "${plan_log}"; then
    fail "${label}: no '${message}' in the error" "${plan_log}"
  elif [ -s "${plan_out}" ]; then
    fail "${label}: a failed plan wrote outputs" "$(cat "${plan_out}")"
  elif [ -n "${envs}" ] && grep -qF -- "${envs}" <<< "${plan_log}"; then
    fail "${label}: the error echoes tox_envs" "${plan_log}"
  else
    pass
  fi
}

# Accepted.
expect_matrix 'one env' '["py312"]' '{"tox_env":["py312"]}'
expect_matrix 'several envs' '["lint", "docs", "py3.12"]' \
  '{"tox_env":["lint","docs","py3.12"]}'
expect_matrix 'every allowed character' '["Docs-Linkcheck_1.0+x"]' \
  '{"tox_env":["Docs-Linkcheck_1.0+x"]}'
expect_matrix 'whitespace around the JSON' '  [ "lint" ]
' '{"tox_env":["lint"]}'
expect_matrix '100 characters' "[\"$(printf 'a%.0s' {1..100})\"]" \
  "{\"tox_env\":[\"$(printf 'a%.0s' {1..100})\"]}"
expect_matrix '256 envs' \
  "$(python3 -c 'import json; print(json.dumps([f"e{i}" for i in range(256)]))')" \
  "$(python3 -c 'import json; print(json.dumps({"tox_env": [f"e{i}" for i in range(256)]}, separators=(",", ":")))')"
expect_matrix 'parallel empty' '["lint"]' '{"tox_env":["lint"]}' \
  INPUT_PARALLEL=''
expect_matrix 'parallel all' '["lint"]' '{"tox_env":["lint"]}' \
  INPUT_PARALLEL='all'
expect_matrix 'parallel 4' '["lint"]' '{"tox_env":["lint"]}' \
  INPUT_PARALLEL='4'
expect_matrix 'audit egress' '["lint"]' '{"tox_env":["lint"]}' \
  INPUT_HARDEN_RUNNER_EGRESS='audit'
expect_matrix 'supplemental list' '["lint"]' '{"tox_env":["lint"]}' \
  INPUT_HARDEN_RUNNER_SUPPLEMENTAL_ALLOWLIST='org//extra.txt@abc'
expect_matrix 'path_prefix subdirectory' '["lint"]' \
  '{"tox_env":["lint"]}' INPUT_PATH_PREFIX='docs/sub'
expect_matrix 'path_prefix trailing slash' '["lint"]' \
  '{"tox_env":["lint"]}' INPUT_PATH_PREFIX='docs/'

# Rejected: the shape of tox_envs.
expect_plan_error 'empty input' '' 'not valid JSON'
expect_plan_error 'malformed JSON' '["lint",' 'not valid JSON'
expect_plan_error 'bare string' '"lint"' 'must be a JSON array'
expect_plan_error 'object' '{"env": "lint"}' 'must be a JSON array'
expect_plan_error 'empty array' '[]' 'at least one environment'
expect_plan_error '257 envs' \
  "$(python3 -c 'import json; print(json.dumps([f"e{i}" for i in range(257)]))')" \
  'at most 256'

# Rejected: one entry.
expect_plan_error 'number' '[1]' 'tox_envs[0] must be a string'
expect_plan_error 'null' '["lint", null]' 'tox_envs[1] must be a string'
expect_plan_error 'nested array' '[["lint"]]' 'must be a string'
expect_plan_error 'empty string' '[""]' 'tox_envs[0] is empty'
expect_plan_error 'duplicate' '["lint", "docs", "lint"]' \
  'tox_envs[2] duplicates tox_envs[0]'
expect_plan_error '101 characters' \
  "[\"$(printf 'a%.0s' {1..101})\"]" 'longer than 100'
expect_plan_error 'space' '["py 312"]' 'contains whitespace'
expect_plan_error 'leading space' '[" lint"]' 'contains whitespace'
expect_plan_error 'tab' '["py\t312"]' 'control character'
expect_plan_error 'newline' '["lint\n::warning::x"]' 'control character'
expect_plan_error 'NUL' '["li\u0000nt"]' 'control character'
expect_plan_error 'DEL' '["li\u007fnt"]' 'control character'
expect_plan_error 'U+0085' '["li\u0085nt"]' 'control character'
expect_plan_error 'U+009B' '["li\u009bnt"]' 'control character'
expect_plan_error 'no-break space' '["li\u00a0nt"]' 'contains whitespace'
expect_plan_error 'comma' '["lint,docs"]' 'contains a comma'
expect_plan_error 'leading -' '["-e"]' "starts with '-'"
expect_plan_error 'option' '["--version"]' "starts with '-'"
expect_plan_error 'factor braces' '["py{311,312}"]' 'contains a comma'
expect_plan_error 'brace' '["py{312}"]' 'outside letters'
expect_plan_error 'glob' '["py*"]' 'outside letters'
expect_plan_error 'shell' '["lint;id"]' 'outside letters'
# shellcheck disable=SC2016  # a literal $(id), not an expansion
expect_plan_error 'substitution' '["$(id)"]' 'outside letters'
expect_plan_error 'slash' '["a/b"]' 'outside letters'
expect_plan_error 'non-ASCII letter' '["lïnt"]' 'outside letters'
# Every bad entry is reported, not the first alone.
run_plan '["", "a b"]'
if [ "${plan_rc}" -ne 0 ] && grep -qF 'tox_envs[0] is empty' \
  <<< "${plan_log}" && grep -qF 'tox_envs[1] contains whitespace' \
  <<< "${plan_log}"; then
  pass
else
  fail 'two bad entries: expected both reported' "${plan_log}"
fi

# Rejected: the other inputs.
expect_plan_error 'parallel word' '["lint"]' 'parallel must be' \
  INPUT_PARALLEL='yes'
expect_plan_error 'parallel zero' '["lint"]' 'parallel must be' \
  INPUT_PARALLEL='0'
expect_plan_error 'parallel extra option' '["lint"]' 'parallel must be' \
  INPUT_PARALLEL='auto -e x'
expect_plan_error 'egress typo' '["lint"]' 'harden_runner_egress must' \
  INPUT_HARDEN_RUNNER_EGRESS='blocked'
expect_plan_error 'supplemental without baseline' '["lint"]' \
  'harden_runner_allowlist is empty' \
  INPUT_HARDEN_RUNNER_ALLOWLIST='' \
  INPUT_HARDEN_RUNNER_SUPPLEMENTAL_ALLOWLIST='org//extra.txt@abc'
expect_plan_error 'path_prefix empty' '["lint"]' 'path_prefix must be' \
  INPUT_PATH_PREFIX=''
expect_plan_error 'path_prefix absolute' '["lint"]' 'path_prefix must be' \
  INPUT_PATH_PREFIX='/etc'
expect_plan_error 'path_prefix traversal' '["lint"]' \
  'path_prefix must be' INPUT_PATH_PREFIX='docs/../..'
expect_plan_error 'path_prefix space' '["lint"]' 'path_prefix must be' \
  INPUT_PATH_PREFIX='my docs'

# --- Checkout credentials -------------------------------------------

# The Gerrit checkout persists its token, and tox then runs the
# change's own code; the removal step must leave no token behind.
# Run it against a repository configured the way actions/checkout
# leaves one, isolated from the host's own git configuration.
secret='AUTHORIZATION: basic c2VjcmV0LXRva2Vu'

# run_drop_credentials <repo>: sets cred_rc and cred_log.
run_drop_credentials() {
  cred_rc=0
  cred_log=$(cd "$1" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    RUNNER_TEMP="${runner_temp}" \
    bash -euo pipefail "${credentials_script}" 2>&1) || cred_rc=$?
}

# effective_headers <repo>: every extraheader git would send.
effective_headers() {
  (cd "$1" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git config --get-regexp '^http\..*\.extraheader$' || true)
}

runner_temp="${workdir}/runner-temp"
mkdir -p "${runner_temp}"
repo="${workdir}/checkout"
git init -q "${repo}"
credentials="${runner_temp}/git-credentials-0123.config"
printf '[http "https://github.com/"]\n\textraheader = %s\n' "${secret}" \
  > "${credentials}"
git -C "${repo}" config --local "includeIf.gitdir:${repo}/.git.path" \
  "${credentials}"
git -C "${repo}" config --local \
  "includeIf.gitdir:${repo}/.git/worktrees/*.path" "${credentials}"
git -C "${repo}" config --local \
  'includeIf.gitdir:/github/workspace/.git.path' \
  '/github/runner_temp/git-credentials-0123.config'
git -C "${repo}" config --local 'http.https://github.com/.extraheader' \
  "${secret}"
# Not a credentials file: the step must leave it alone.
git -C "${repo}" config --local 'includeIf.gitdir:/elsewhere/.path' \
  "${workdir}/unrelated.config"

if [ -n "$(effective_headers "${repo}")" ]; then
  pass
else
  fail 'credentials fixture: the token is not configured to begin with'
fi
run_drop_credentials "${repo}"
if [ "${cred_rc}" -ne 0 ]; then
  fail "credentials: exit ${cred_rc}, expected 0" "${cred_log}"
elif [ -e "${credentials}" ]; then
  fail 'credentials: the credentials file survives'
elif [ -n "$(effective_headers "${repo}")" ]; then
  fail 'credentials: an extraheader survives'
elif git -C "${repo}" config --local --get-regexp \
  '^includeif\..*\.path$' | grep -q 'git-credentials-'; then
  fail 'credentials: an includeIf entry survives'
elif ! git -C "${repo}" config --local \
  'includeIf.gitdir:/elsewhere/.path' > /dev/null; then
  fail 'credentials: an unrelated includeIf entry was removed'
elif grep -qF 'c2VjcmV0LXRva2Vu' <<< "${cred_log}"; then
  fail 'credentials: the log echoes the token' "${cred_log}"
else
  pass
fi

# Nothing persisted: the step passes and changes nothing.
clean="${workdir}/clean"
git init -q "${clean}"
run_drop_credentials "${clean}"
if [ "${cred_rc}" -eq 0 ]; then
  pass
else
  fail "credentials, none set: exit ${cred_rc}, expected 0" "${cred_log}"
fi

# A form the step does not know fails the leg rather than reaching
# tox: here, a token in a plain include.
other="${workdir}/other"
git init -q "${other}"
printf '[http "https://github.com/"]\n\textraheader = %s\n' "${secret}" \
  > "${workdir}/plain-include.config"
git -C "${other}" config --local include.path \
  "${workdir}/plain-include.config"
run_drop_credentials "${other}"
if [ "${cred_rc}" -eq 0 ]; then
  fail 'credentials, unknown form: expected a failure' "${cred_log}"
elif ! grep -qF 'Checkout credentials remain' <<< "${cred_log}"; then
  fail 'credentials, unknown form: no error message' "${cred_log}"
elif grep -qF 'c2VjcmV0LXRva2Vu' <<< "${cred_log}"; then
  fail 'credentials, unknown form: the log echoes the token' \
    "${cred_log}"
else
  pass
fi

# --- Summary --------------------------------------------------------

total=$((passed + failed))
if [ "${failed}" -ne 0 ]; then
  echo "${failed} of ${total} tox verify fixture(s) failed" >&2
  exit 1
fi
echo "All ${total} tox verify fixtures passed"
