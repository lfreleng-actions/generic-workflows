#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the Gerrit, plan and credential-removal logic in
# .github/workflows/ci-management-verify.yaml.
#
# The plan checks path_prefix and jjb_path, which reach
# standalone-linting-action and jjb-action. It fails closed, so most
# of these fixtures are rejection cases: a mistake that lets an
# unsafe path through hands it to those actions.
#
# The scripts are EXTRACTED from the workflow rather than copied
# here, so these fixtures always exercise the code that runs in CI.
# The Gerrit script must match change-isolation.yaml's byte for byte,
# and each leg's credential removal must match the other leg's and
# tox-verify.yaml's: this script fails when any of them drift.
# linting-verify.yaml carries copies of the same Gerrit script and
# credential removal, held to the same drift check here, and a copy of
# linting.yaml's harden_check, held to the first of linting.yaml's two
# copies (tests/test-locate-rules.sh holds those two to each other).
# Removing or renaming the markers fails this script rather than
# silently testing nothing.
#
# Usage: bash tests/test-ci-management-verify-plan.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflow="${repo_root}/.github/workflows/ci-management-verify.yaml"
isolation="${repo_root}/.github/workflows/change-isolation.yaml"
tox_verify="${repo_root}/.github/workflows/tox-verify.yaml"
linting_verify="${repo_root}/.github/workflows/linting-verify.yaml"
linting="${repo_root}/.github/workflows/linting.yaml"

for file in "${workflow}" "${isolation}" "${tox_verify}" \
  "${linting_verify}" "${linting}"; do
  if [ ! -f "${file}" ]; then
    echo "ERROR: workflow not found: ${file}" >&2
    exit 1
  fi
done

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# Copy a marked region out of its block, stripping the YAML block
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
lint_credentials="${workdir}/drop-credentials-lint.sh"
jjb_credentials="${workdir}/drop-credentials-jjb.sh"
tox_credentials="${workdir}/drop-credentials-tox.sh"
linting_gerrit="${workdir}/linting-verify-gerrit.py"
linting_credentials="${workdir}/drop-credentials-linting-verify.sh"
extract "${workflow}" ci_management_verify_plan "${plan_script}" \
  'def check_path'
extract "${workflow}" ci_management_verify_gerrit "${gerrit_script}" \
  'def checkout_ref'
extract "${isolation}" change_isolation_gerrit "${isolation_gerrit}" \
  'def checkout_ref'
extract "${workflow}" ci_management_verify_drop_credentials_lint \
  "${lint_credentials}" 'git-credentials-'
extract "${workflow}" ci_management_verify_drop_credentials_jjb \
  "${jjb_credentials}" 'git-credentials-'
extract "${tox_verify}" tox_verify_drop_credentials "${tox_credentials}" \
  'git-credentials-'
extract "${linting_verify}" linting_verify_gerrit "${linting_gerrit}" \
  'def checkout_ref'
extract "${linting_verify}" linting_verify_drop_credentials \
  "${linting_credentials}" 'git-credentials-'
linting_verify_harden="${workdir}/harden-check-linting-verify.sh"
linting_harden="${workdir}/harden-check-linting.sh"
extract "${linting_verify}" linting_verify_harden_check \
  "${linting_verify_harden}" 'harden_runner_gate()'
# linting.yaml's marker carries a note after its name and appears once
# per job, so take its first region alone.
awk '
  /# BEGIN harden_check \(extracted by tests\/test-locate-rules\.sh\)$/ {
    indent = match($0, /[^ ]/) - 1
    capture = 1
    next
  }
  /# END harden_check$/ { if (capture) exit }
  capture { print substr($0, indent + 1) }
' "${linting}" > "${linting_harden}"
if ! grep -q 'harden_runner_gate()' "${linting_harden}"; then
  echo "ERROR: no harden_check region in ${linting}" >&2
  exit 1
fi

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

# expect_same <label> <expected file> <actual file>
expect_same() {
  if diff -u "$2" "$3" > "${workdir}/drift"; then
    pass
  else
    fail "$1" "$(cat "${workdir}/drift")"
  fi
}

expect_same 'the Gerrit script differs from change-isolation.yaml' \
  "${isolation_gerrit}" "${gerrit_script}"
expect_same "the JJB leg's credential removal differs from the Lint leg's" \
  "${lint_credentials}" "${jjb_credentials}"
expect_same 'the credential removal differs from tox-verify.yaml' \
  "${tox_credentials}" "${lint_credentials}"
expect_same "linting-verify.yaml's Gerrit script differs from change-isolation.yaml" \
  "${isolation_gerrit}" "${linting_gerrit}"
expect_same "linting-verify.yaml's credential removal differs from the Lint leg's" \
  "${lint_credentials}" "${linting_credentials}"
expect_same "linting-verify.yaml's harden-runner check differs from linting.yaml's" \
  "${linting_harden}" "${linting_verify_harden}"

# Both Python scripts read caller input, so they must run isolated.
# Match the command line, anchored, rather than any mention in a
# comment.
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

# Every harden-runner pin is v2.22.4, which keeps the westus2 DNS
# bypass fix from v2.22.3, and every job carries one.
stale_pins=$(grep -n 'step-security/harden-runner@' "${workflow}" |
  grep -v '@1d88384fd173af6ecb012dfd0264a306b711241a ' || true)
if [ -z "${stale_pins}" ]; then
  pass
else
  fail 'a harden-runner pin is not v2.22.4' "${stale_pins}"
fi
harden_runs=$(grep -c 'step-security/harden-runner@' "${workflow}" || true)
if [ "${harden_runs}" -eq 4 ]; then
  pass
else
  fail "expected 4 harden-runner steps, one per job, found ${harden_runs}"
fi

# Both legs run the change's own code, so neither may hand it a
# token: no github_token for the hooks, and no persisted credentials
# from the GitHub-mode checkout.
if grep -nE '^[[:space:]]*github_token:' "${workflow}" > /dev/null; then
  fail 'the workflow passes a github_token to the hooks' \
    "$(grep -nE '^[[:space:]]*github_token:' "${workflow}")"
else
  pass
fi
unpersisted=$(grep -cE '^[[:space:]]*persist-credentials: false$' \
  "${workflow}" || true)
if [ "${unpersisted}" -eq 2 ]; then
  pass
else
  fail "expected 2 'persist-credentials: false' checkouts, found ${unpersisted}"
fi

# A Gerrit verify is dispatched on the default branch, whose cache
# scope trusted runs share, so the Lint leg must neither restore nor
# save prek's hook environments or uv's cache in Gerrit mode; from
# v0.10.1, cache_hooks 'false' turns both off. GitHub mode keeps the
# action's default. Read the value from the step that calls the action,
# and require it to be the only cache_hooks in the workflow.
cache_lines=$(grep -nE '^[[:space:]]*cache_hooks:' "${workflow}" || true)
cache_step=$(awk '
  /^[[:space:]]*- name:/ { inside = 0 }
  /uses: lfreleng-actions\/standalone-linting-action@/ { inside = 1 }
  inside && /^[[:space:]]*cache_hooks:/ {
    sub(/^[[:space:]]*/, "")
    print
  }
' "${workflow}")
cache_expected="cache_hooks: \${{ inputs.gerrit_refspec != '' && 'false' || 'true' }}"
if [ "$(printf '%s\n' "${cache_lines}" | grep -c .)" -eq 1 ] &&
  [ "${cache_step}" = "${cache_expected}" ]; then
  pass
else
  fail "the Lint leg's cache_hooks is not 'false' in Gerrit mode" \
    "${cache_lines:-no cache_hooks line}"
fi

# --- Gerrit ref -----------------------------------------------------

# The script is change-isolation.yaml's, whose own fixtures and
# tests/test-tox-verify-plan.sh cover it in full; these confirm the
# copy here runs.

# run_gerrit <branch> [url]: sets gerrit_rc, gerrit_log and gerrit_out.
run_gerrit() {
  gerrit_out="${workdir}/gerrit-output-${RANDOM}"
  : > "${gerrit_out}"
  gerrit_rc=0
  gerrit_log=$(GERRIT_URL="${2-https://gerrit.example.org}" \
    GERRIT_PROJECT='ci-management' GERRIT_BRANCH="$1" \
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

expect_ref 'master' 'refs/heads/master'
expect_ref 'refs/meta/config' 'refs/meta/config'

run_gerrit 'release/../main'
if [ "${gerrit_rc}" -ne 0 ] && [ ! -s "${gerrit_out}" ] &&
  grep -qF 'not a valid ref name' <<< "${gerrit_log}"; then
  pass
else
  fail 'branch with ..: expected a rejection' "${gerrit_log}"
fi

run_gerrit 'master' 'http://gerrit.example.org'
if [ "${gerrit_rc}" -ne 0 ] && [ ! -s "${gerrit_out}" ] &&
  grep -qF 'must start with https://' <<< "${gerrit_log}"; then
  pass
else
  fail 'http Gerrit URL: expected a rejection' "${gerrit_log}"
fi

# --- Plan -----------------------------------------------------------

# run_plan [VAR=value ...]: sets plan_rc and plan_log. Defaults match
# the workflow's input defaults.
run_plan() {
  plan_rc=0
  plan_log=$(env -i PATH="${PATH}" \
    INPUT_PATH_PREFIX='.' \
    INPUT_JJB_PATH='jjb' \
    INPUT_HARDEN_RUNNER_EGRESS='block' \
    INPUT_HARDEN_RUNNER_ALLOWLIST='lfreleng-actions//list.txt@abc' \
    INPUT_HARDEN_RUNNER_SUPPLEMENTAL_ALLOWLIST='' \
    "$@" python3 -I "${plan_script}" 2>&1) || plan_rc=$?
}

# expect_plan_ok <label> [VAR=value ...]
expect_plan_ok() {
  local label="$1"
  shift
  run_plan "$@"
  if [ "${plan_rc}" -eq 0 ] && grep -qF 'Inputs are valid' \
    <<< "${plan_log}"; then
    pass
  else
    fail "${label}: plan failed, expected it to pass" "${plan_log}"
  fi
}

# expect_plan_error <label> <message> <VAR=value> [VAR=value ...]: the
# plan fails, names the problem, and never echoes the first value.
expect_plan_error() {
  local label="$1" message="$2" value="${3#*=}"
  shift 2
  run_plan "$@"
  if [ "${plan_rc}" -eq 0 ]; then
    fail "${label}: plan passed, expected an error" "${plan_log}"
  elif ! grep -qF -- "${message}" <<< "${plan_log}"; then
    fail "${label}: no '${message}' in the error" "${plan_log}"
  elif [ ${#value} -gt 2 ] && grep -qF -- "${value}" <<< "${plan_log}"
  then
    fail "${label}: the error echoes the value" "${plan_log}"
  else
    pass
  fi
}

# Accepted.
expect_plan_ok 'defaults'
expect_plan_ok 'path_prefix subdirectory' \
  INPUT_PATH_PREFIX='tests/fixtures/ci-management'
expect_plan_ok 'path_prefix trailing slash' INPUT_PATH_PREFIX='ci/'
expect_plan_ok 'jjb_path nested' INPUT_JJB_PATH='jjb/global'
expect_plan_ok 'jjb_path with a dot segment' INPUT_JJB_PATH='./jjb'
expect_plan_ok 'jjb_path with dots in a name' INPUT_JJB_PATH='jjb/a..b'
expect_plan_ok 'jjb_path with an inner -' INPUT_JJB_PATH='jjb/-x'
expect_plan_ok 'audit egress' INPUT_HARDEN_RUNNER_EGRESS='audit'
expect_plan_ok 'supplemental list' \
  INPUT_HARDEN_RUNNER_SUPPLEMENTAL_ALLOWLIST='org//extra.txt@abc'

# Rejected: each rule, for each path input.
for input in PATH_PREFIX JJB_PATH; do
  name=$(tr '[:upper:]' '[:lower:]' <<< "${input}")
  expect_plan_error "${name} empty" "${name} is empty" \
    "INPUT_${input}="
  expect_plan_error "${name} absolute" "${name} must be a relative" \
    "INPUT_${input}=/etc/jjb"
  expect_plan_error "${name} root" "${name} must be a relative" \
    "INPUT_${input}=/"
  expect_plan_error "${name} parent" "${name} contains a '..' segment" \
    "INPUT_${input}=.."
  expect_plan_error "${name} traversal" "${name} contains a '..' segment" \
    "INPUT_${input}=jjb/../../etc"
  expect_plan_error "${name} trailing .." \
    "${name} contains a '..' segment" "INPUT_${input}=jjb/.."
  expect_plan_error "${name} leading -" "${name} starts with '-'" \
    "INPUT_${input}=--version"
  expect_plan_error "${name} space" "${name} contains whitespace" \
    "INPUT_${input}=my jjb"
  expect_plan_error "${name} leading space" "${name} contains whitespace" \
    "INPUT_${input}= jjb"
  expect_plan_error "${name} no-break space" "${name} contains whitespace" \
    "INPUT_${input}=$(printf 'jj\302\240b')"
  expect_plan_error "${name} ideographic space" \
    "${name} contains whitespace" \
    "INPUT_${input}=$(printf 'jj\343\200\200b')"
  expect_plan_error "${name} tab" "${name} contains a control character" \
    "INPUT_${input}=$(printf 'jj\tb')"
  expect_plan_error "${name} newline" \
    "${name} contains a control character" \
    "INPUT_${input}=$(printf 'abc\n::warning::injected')"
  expect_plan_error "${name} DEL" "${name} contains a control character" \
    "INPUT_${input}=$(printf 'jj\177b')"
  expect_plan_error "${name} U+0085" \
    "${name} contains a control character" \
    "INPUT_${input}=$(printf 'jj\302\205b')"
  expect_plan_error "${name} U+009B" \
    "${name} contains a control character" \
    "INPUT_${input}=$(printf 'jj\302\233b')"
done

# Rejected: the hardening inputs.
expect_plan_error 'egress typo' 'harden_runner_egress must' \
  INPUT_HARDEN_RUNNER_EGRESS='blocked'
expect_plan_error 'egress empty' 'harden_runner_egress must' \
  INPUT_HARDEN_RUNNER_EGRESS=''
expect_plan_error 'supplemental without baseline' \
  'harden_runner_allowlist is empty' \
  INPUT_HARDEN_RUNNER_SUPPLEMENTAL_ALLOWLIST='org//extra.txt@abc' \
  INPUT_HARDEN_RUNNER_ALLOWLIST=''

# Every bad input is reported, not the first alone.
run_plan INPUT_PATH_PREFIX='/abs' INPUT_JJB_PATH='-x'
if [ "${plan_rc}" -ne 0 ] &&
  grep -qF 'path_prefix must be a relative' <<< "${plan_log}" &&
  grep -qF "jjb_path starts with '-'" <<< "${plan_log}"; then
  pass
else
  fail 'two bad inputs: expected both reported' "${plan_log}"
fi

# --- Checkout credentials -------------------------------------------

# The Gerrit checkout persists its token, in the superproject and in
# every submodule, and both legs then run the change's own code; the
# removal step must leave no token behind anywhere. Build a
# superproject with a submodule, itself holding a nested one, and
# configure each the way actions/checkout v7.0.1 leaves them, isolated
# from the host's own git configuration.
secret='AUTHORIZATION: basic c2VjcmV0LXRva2Vu'

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# Fixture-building git: an identity for the commits, and file://
# submodule clones, which git refuses by default.
fixture_git() {
  git -c user.name='Fixture' -c user.email='fixture@example.invalid' \
    -c protocol.file.allow=always -c init.defaultBranch=main "$@"
}

# run_drop_credentials <repo>: sets cred_rc and cred_log.
run_drop_credentials() {
  cred_rc=0
  cred_log=$(cd "$1" && RUNNER_TEMP="${runner_temp}" \
    bash -euo pipefail "${lint_credentials}" 2>&1) || cred_rc=$?
}

# effective_headers <git dir>: every extraheader git would send there.
effective_headers() {
  git --git-dir="$1" config --get-regexp '^http\..*\.extraheader$' ||
    true
}

# persist_like_checkout <git dir> <credentials file>: the includeIf
# entries actions/checkout writes into a repository's config.
persist_like_checkout() {
  git --git-dir="$1" config --local "includeIf.gitdir:$1.path" "$2"
  git --git-dir="$1" config --local \
    "includeIf.gitdir:/github/workspace/.git.path" \
    "/github/runner_temp/$(basename "$2")"
}

runner_temp="${workdir}/runner-temp"
mkdir -p "${runner_temp}"
credentials="${runner_temp}/git-credentials-0123abcd.config"

# make_superproject <dir>: a repository with global-jjb as a
# submodule, which holds 'nested' as one of its own, both checked out.
make_superproject() {
  local nested="${workdir}/origin-nested" global="${workdir}/origin-global"
  if [ ! -d "${global}" ]; then
    fixture_git init -q "${nested}"
    fixture_git -C "${nested}" commit -q --allow-empty -m 'Nested'
    fixture_git init -q "${global}"
    fixture_git -C "${global}" submodule add -q "${nested}" nested
    fixture_git -C "${global}" commit -q -m 'Global JJB'
  fi
  fixture_git init -q "$1"
  fixture_git -C "$1" submodule add -q "${global}" global-jjb
  fixture_git -C "$1" commit -q -m 'ci-management'
  fixture_git -C "$1" submodule update -q --init --recursive
}

repo="${workdir}/checkout"
make_superproject "${repo}"
top="${repo}/.git"
global_dir="${top}/modules/global-jjb"
nested_dir="${global_dir}/modules/nested"
git_dirs=("${top}" "${global_dir}" "${nested_dir}")

printf '[http "https://github.com/"]\n\textraheader = %s\n' "${secret}" \
  > "${credentials}"
for dir in "${git_dirs[@]}"; do
  persist_like_checkout "${dir}" "${credentials}"
done
git --git-dir="${top}" config --local \
  "includeIf.gitdir:${top}/worktrees/*.path" "${credentials}"
# The HTTPS-for-SSH rewrite checkout adds to each submodule: not a
# credential, so the step must leave it alone.
git --git-dir="${global_dir}" config --local \
  'url.https://github.com/.insteadOf' 'git@github.com:'
# The older form, an extraheader in the config itself, in the
# superproject and in the nested submodule.
for dir in "${top}" "${nested_dir}"; do
  git --git-dir="${dir}" config --local \
    'http.https://github.com/.extraheader' "${secret}"
done
# Not a credentials file: the step must leave it alone.
git --git-dir="${global_dir}" config --local \
  'includeIf.gitdir:/elsewhere/.path' "${workdir}/unrelated.config"
# A branch named 'config' puts a file of that name under the
# submodule's git directory, in a directory that is no repository.
fixture_git -C "${repo}/global-jjb" branch config

for dir in "${git_dirs[@]}"; do
  if [ -n "$(effective_headers "${dir}")" ]; then
    pass
  else
    fail "credentials fixture: no token configured in ${dir#"${repo}/"}"
  fi
done

run_drop_credentials "${repo}"
if [ "${cred_rc}" -ne 0 ]; then
  fail "credentials: exit ${cred_rc}, expected 0" "${cred_log}"
elif [ -e "${credentials}" ]; then
  fail 'credentials: the credentials file survives'
elif grep -qF 'c2VjcmV0LXRva2Vu' <<< "${cred_log}"; then
  fail 'credentials: the log echoes the token' "${cred_log}"
else
  pass
fi
for dir in "${git_dirs[@]}"; do
  where=${dir#"${repo}/"}
  if [ -n "$(effective_headers "${dir}")" ]; then
    fail "credentials: an extraheader survives in ${where}"
  elif git --git-dir="${dir}" config --local --get-regexp \
    '^includeif\..*\.path$' | grep -q 'git-credentials-'; then
    fail "credentials: an includeIf entry survives in ${where}"
  else
    pass
  fi
done
if git --git-dir="${global_dir}" config --local \
  'includeIf.gitdir:/elsewhere/.path' > /dev/null &&
  git --git-dir="${global_dir}" config --local \
    'url.https://github.com/.insteadOf' > /dev/null; then
  pass
else
  fail 'credentials: an unrelated submodule entry was removed'
fi

# Nothing persisted: the step passes and changes nothing.
clean="${workdir}/clean"
fixture_git init -q "${clean}"
run_drop_credentials "${clean}"
if [ "${cred_rc}" -eq 0 ]; then
  pass
else
  fail "credentials, none set: exit ${cred_rc}, expected 0" "${cred_log}"
fi

# A form the step does not know fails the leg rather than reaching
# the change's code: here, a token in a plain include, in the
# superproject and then in the nested submodule alone.
printf '[http "https://github.com/"]\n\textraheader = %s\n' "${secret}" \
  > "${workdir}/plain-include.config"
for where in superproject submodule; do
  other="${workdir}/other-${where}"
  make_superproject "${other}"
  if [ "${where}" = superproject ]; then
    dir="${other}/.git"
  else
    dir="${other}/.git/modules/global-jjb/modules/nested"
  fi
  git --git-dir="${dir}" config --local include.path \
    "${workdir}/plain-include.config"
  run_drop_credentials "${other}"
  if [ "${cred_rc}" -eq 0 ]; then
    fail "credentials, unknown form in the ${where}: expected a failure" \
      "${cred_log}"
  elif ! grep -qF 'Checkout credentials remain' <<< "${cred_log}"; then
    fail "credentials, unknown form in the ${where}: no error message" \
      "${cred_log}"
  elif grep -qF 'c2VjcmV0LXRva2Vu' <<< "${cred_log}"; then
    fail "credentials, unknown form in the ${where}: the log echoes the token" \
      "${cred_log}"
  else
    pass
  fi
done

# The Gerrit example keys its concurrency group by project, branch
# and Change-Id, and a repeat dispatch for one change must queue
# behind the run in flight rather than cancel it, since cancelling
# cannot retract a vote already sent over SSH.
# The key is literal workflow syntax, not shell expansion.
# shellcheck disable=SC2016
group_key='inputs.GERRIT_PROJECT }}-${{ inputs.GERRIT_BRANCH }}-'
# shellcheck disable=SC2016
group_key+='${{ inputs.GERRIT_CHANGE_ID || github.run_id }}'
example="${repo_root}/examples/ci-management/gerrit-ci-management-verify.yaml"
group_lines=$(grep -cE '^  group: ' "${example}" || true)
group_template=$(sed -nE 's/^  group: (.*)$/\1/p' "${example}")
if [ "${group_lines}" -eq 1 ] &&
  grep -qF "${group_key}" <<< "${group_template}" &&
  grep -qxF '  cancel-in-progress: false' "${example}"; then
  pass
else
  fail "${example#"${repo_root}/"}: expected one per-change group, queueing" \
    "$(grep -nE '^  (group|cancel-in-progress):' "${example}")"
fi

# --- Summary --------------------------------------------------------

total=$((passed + failed))
if [ "${failed}" -ne 0 ]; then
  echo "${failed} of ${total} ci-management verify fixture(s) failed" >&2
  exit 1
fi
echo "All ${total} ci-management verify fixtures passed"
