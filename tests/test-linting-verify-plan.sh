#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the Gerrit, plan and harden-runner gate logic in
# .github/workflows/linting-verify.yaml, and for the vote rule and
# concurrency group in
# examples/linting-verify/gerrit-linting-verify.yaml.
#
# The plan checks path_prefix and skip_hooks, which reach
# standalone-linting-action and prek's command line, refuses a
# 'patchset-created' or 'comment-added' dispatch that passed no
# refspec, and accepts only a change ref matching the one the dispatch
# carried; the Lint job then checks HEAD against the dispatched
# revision. It fails closed, so most of these fixtures are rejection
# cases: a mistake that lets an unsafe value through hands it to that
# action.
#
# The scripts are EXTRACTED from the workflow rather than copied
# here, so these fixtures always exercise the code that runs in CI.
# tests/test-ci-management-verify-plan.sh holds the Gerrit script and
# the credential removal to their sibling copies, and the harden-runner
# check to linting.yaml's, byte for byte, and covers the credential
# removal against a real repository. Removing or renaming the markers
# fails this script rather than silently testing nothing.
#
# Usage: bash tests/test-linting-verify-plan.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflow="${repo_root}/.github/workflows/linting-verify.yaml"

if [ ! -f "${workflow}" ]; then
  echo "ERROR: workflow not found: ${workflow}" >&2
  exit 1
fi

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
extract "${workflow}" linting_verify_plan "${plan_script}" \
  'def check_skip_hooks'
extract "${workflow}" linting_verify_gerrit "${gerrit_script}" \
  'def checkout_ref'
gate_script="${workdir}/harden-gate.sh"
extract "${workflow}" linting_verify_harden_gate "${gate_script}" \
  'harden_runner_gate'
revision_script="${workdir}/revision.sh"
extract "${workflow}" linting_verify_revision "${revision_script}" \
  'GERRIT_PATCHSET_REVISION'
prek_toml_script="${workdir}/prek-toml.sh"
extract "${workflow}" linting_verify_prek_toml "${prek_toml_script}" \
  'prek.toml'

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

# Every harden-runner pin is v2.22.3, which fixes the westus2 DNS
# bypass, and every job carries one.
stale_pins=$(grep -n 'step-security/harden-runner@' "${workflow}" |
  grep -v '@46b06cea07f9e64621fdf066ba77ac6915163d43  # v2.22.3$' ||
  true)
if [ -z "${stale_pins}" ]; then
  pass
else
  fail 'a harden-runner pin is not v2.22.3' "${stale_pins}"
fi
harden_runs=$(grep -c 'step-security/harden-runner@' "${workflow}" || true)
if [ "${harden_runs}" -eq 3 ]; then
  pass
else
  fail "expected 3 harden-runner steps, one per job, found ${harden_runs}"
fi

# The Lint job runs the change's own code, so it may not hand it a
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
if [ "${unpersisted}" -eq 1 ]; then
  pass
else
  fail "expected 1 'persist-credentials: false' checkout, found ${unpersisted}"
fi

# Concurrency belongs to the caller, and the reusable starts with no
# permissions at all.
if grep -nE '^concurrency:' "${workflow}" > /dev/null; then
  fail 'the reusable carries a concurrency block'
else
  pass
fi
if grep -qE '^permissions: \{\}$' "${workflow}"; then
  pass
else
  fail "the reusable lacks a top-level 'permissions: {}'"
fi

# Read the linting action's inputs from the step that calls it.
read_action_inputs() {
  awk '
    /^[[:space:]]*- name:/ { inside = 0 }
    /uses: lfreleng-actions\/standalone-linting-action@/ { inside = 1 }
    inside && /^[[:space:]]+[a-z_]+:/ && !/uses:/ && !/with:/ {
      sub(/^[[:space:]]*/, "")
      print
    }
  ' "$1"
}
action_inputs=$(read_action_inputs "${workflow}")
# expect_action_input <line>: the step passes exactly that line.
expect_action_input() {
  if grep -qxF -- "$1" <<< "${action_inputs}"; then
    pass
  else
    fail "the linting step does not pass '$1'" "${action_inputs}"
  fi
}
expect_action_input "no_checkout: 'true'"
expect_action_input "run_all_hooks: 'true'"
expect_action_input "path_prefix: \${{ inputs.path_prefix }}"
expect_action_input "skip_hooks: \${{ inputs.skip_hooks }}"
# Both modes run code the repository's contributors control, in a
# cache scope trusted runs may share, so the hooks' caches stay off in
# both, and no other cache_hooks line may turn them back on.
expect_action_input "cache_hooks: 'false'"
cache_lines=$(grep -nE '^[[:space:]]*cache_hooks:' "${workflow}" || true)
if [ "$(printf '%s\n' "${cache_lines}" | grep -c .)" -eq 1 ]; then
  pass
else
  fail "expected one cache_hooks line" "${cache_lines:-none}"
fi
# The legacy workflow installed no dependencies and set up no
# toolchain, and the action's 'auto' defaults would run a Node.js
# install from a package.json and lockfile, or prepare a Rust
# toolchain for a Cargo.toml, that the change controls. So both stay
# off, with no other line for either input to undo it.
# setup_off <input> <file>: the linting step in <file> passes exactly
# <input>: 'false', and the file sets <input> nowhere else.
setup_off() {
  grep -qxF -- "$1: 'false'" <<< "$(read_action_inputs "$2")" &&
    [ "$(grep -cE "^[[:space:]]*$1:" "$2")" -eq 1 ]
}
setup_mutant="${workdir}/linting-verify-setup-mutant.yaml"
for setup_input in node_setup rust_toolchain_setup; do
  if setup_off "${setup_input}" "${workflow}"; then
    pass
  else
    fail "the linting step does not pass ${setup_input}: 'false' alone" \
      "${action_inputs}"
  fi
  for shape in dropped auto extra; do
    case "${shape}" in
      dropped) sed "/^[[:space:]]*${setup_input}: 'false'\$/d" "${workflow}" ;;
      auto) sed "s/^\([[:space:]]*\)${setup_input}: 'false'\$/\1${setup_input}: 'auto'/" \
        "${workflow}" ;;
      extra) sed "s/^\([[:space:]]*\)${setup_input}: 'false'\$/&\n\1${setup_input}: 'true'/" \
        "${workflow}" ;;
    esac > "${setup_mutant}"
    if cmp -s "${setup_mutant}" "${workflow}"; then
      fail "${setup_input} mutant '${shape}' did not change the workflow"
    elif setup_off "${setup_input}" "${setup_mutant}"; then
      fail "${setup_input} mutant '${shape}' passed the check"
    else
      pass
    fi
  done
done

# Print the Lint job's steps, one line each, in order.
lint_steps=$(awk '
  /^  lint:$/ { inside = 1; next }
  inside && /^  [a-z]/ { inside = 0 }
  inside && /^      - name:/ { sub(/^ *- name: */, ""); print }
' "${workflow}")
# step_index <name>: the step's position in the Lint job, or 0.
step_index() {
  grep -nxF -- "'$1'" <<< "${lint_steps}" | cut -d: -f1 | sed -n 1p
}
harden_at=$(step_index 'Harden runner')
gate_at=$(step_index 'Check harden-runner is monitoring')
gerrit_at=$(step_index 'Checkout Gerrit change')
github_at=$(step_index 'Checkout repository')
hooks_at=$(step_index 'Run linting hooks')
# The agent check runs after harden-runner and before either checkout
# or the hooks: nothing the change controls may run unmonitored.
if [ -n "${harden_at}" ] && [ -n "${gate_at}" ] &&
  [ "${harden_at}" -lt "${gate_at}" ] &&
  [ "${gate_at}" -lt "${gerrit_at:-0}" ] &&
  [ "${gate_at}" -lt "${github_at:-0}" ] &&
  [ "${gate_at}" -lt "${hooks_at:-0}" ]; then
  pass
else
  fail 'the harden-runner check does not precede the checkouts' \
    "${lint_steps}"
fi

# The 'gerrit' job publishes the endpoint it validated, and the Lint
# job merges it into the block-action's extra_endpoints ahead of the
# caller's own, so the loader's DNS check and invalid_records policy
# cover it, and a '#' comment ending the caller's value cannot strip
# it. harden-runner's allowed-endpoints carries the loaded list alone:
# an endpoint added there skips that check, and one host that fails to
# resolve makes the agent drop the whole policy.
if grep -qxF \
  "      endpoint: \${{ steps.endpoint.outputs.endpoint }}" \
  "${workflow}"; then
  pass
else
  fail "the 'gerrit' job does not output its endpoint"
fi
list_expression="\${{ env.CONNECTION_ALLOW_LIST }}"
endpoint_expression="\${{ needs.gerrit.outputs.endpoint }}"
extra_expected="extra_endpoints: \${{ format('{0} {1}',"
extra_expected+=" needs.gerrit.outputs.endpoint,"
extra_expected+=" inputs.harden_runner_extra_endpoints) }}"
# endpoint_wiring <file>: prints each way the Lint job's endpoint
# wiring departs from the above; prints nothing when it holds.
endpoint_wiring() {
  local allowed extra
  allowed=$(awk '
    /^  lint:$/ { inside = 1; next }
    inside && /^  [a-z]/ { inside = 0 }
    inside && /^          allowed-endpoints: >$/ { block = 1; next }
    block && /^            / { sub(/^ */, ""); print; next }
    block { block = 0 }
  ' "$1")
  extra=$(awk '
    /^  lint:$/ { inside = 1; next }
    inside && /^  [a-z]/ { inside = 0 }
    inside && /^          extra_endpoints:/ { sub(/^ */, ""); print }
  ' "$1")
  if [ "${allowed}" != "${list_expression}" ]; then
    printf "allowed-endpoints is not the loaded list alone: %s\n" \
      "${allowed:-none}"
  fi
  if [ "${extra}" != "${extra_expected}" ]; then
    printf "extra_endpoints does not merge the Gerrit endpoint: %s\n" \
      "${extra:-none}"
  fi
}
wiring=$(endpoint_wiring "${workflow}")
if [ -z "${wiring}" ]; then
  pass
else
  fail "the Lint job's Gerrit endpoint wiring is wrong" "${wiring}"
fi

# extra_after_comments <file> <caller value> <endpoint>: renders the
# Lint job's extra_endpoints format() for those values, strips '#'
# comments as the loader's normalise() does, and prints the tokens
# left. The comment rule is a copy of harden-runner-block-action
# v0.15.0's src/sanitise.mjs regex, (^|[ \t])#[^\r\n]*, applied per
# line; the loader itself is not part of this repository and does not
# run here.
extra_after_comments() {
  local line first second rendered
  line=$(awk '
    /^  lint:$/ { inside = 1; next }
    inside && /^  [a-z]/ { inside = 0 }
    inside && /^          extra_endpoints:/ { sub(/^ */, ""); print }
  ' "$1")
  first=$(printf '%s\n' "${line}" | sed -nE \
    "s/^extra_endpoints: \\$\\{\\{ format\\('\\{0\\} \\{1\\}', ([^,]+), ([^)]+)\\) \\}\\}\$/\\1/p")
  second=$(printf '%s\n' "${line}" | sed -nE \
    "s/^extra_endpoints: \\$\\{\\{ format\\('\\{0\\} \\{1\\}', ([^,]+), ([^)]+)\\) \\}\\}\$/\\2/p")
  rendered=""
  for arg in "${first}" "${second}"; do
    case "${arg}" in
      inputs.harden_runner_extra_endpoints) rendered+="$2" ;;
      needs.gerrit.outputs.endpoint) rendered+="$3" ;;
      *) return 1 ;;
    esac
    [ "${arg}" = "${second}" ] || rendered+=" "
  done
  printf '%s\n' "${rendered}" | sed -E 's/(^|[[:blank:]])#.*$/\1/' |
    tr -s '[:space:]' '\n' | sed '/^$/d'
}
# endpoint_survives <file> <caller value>: succeeds when the Gerrit
# endpoint is still a token once the caller's value is merged in.
endpoint_survives() {
  extra_after_comments "$1" "$2" 'gerrit.example.org:443' |
    grep -qxF 'gerrit.example.org:443'
}
# A trailing comment in the caller's value, on one line and on the
# last of several, must leave the Gerrit endpoint in place; the
# caller's own endpoints must survive too.
for value in \
  'registry.example.org:443 # temporary access' \
  $'a.example.org:443\nregistry.example.org:443 # temporary access' \
  '' \
  '# only a comment'; do
  if endpoint_survives "${workflow}" "${value}"; then
    pass
  else
    fail "a caller's extra_endpoints of '${value}' strips the Gerrit endpoint"
  fi
done
if extra_after_comments "${workflow}" \
  'registry.example.org:443 # temporary access' \
  'gerrit.example.org:443' | grep -qxF 'registry.example.org:443'; then
  pass
else
  fail "the caller's own endpoint does not survive the merge"
fi
# The comment rule must catch the old order: the caller's input first,
# so its comment swallows the endpoint.
mutant="${workdir}/linting-verify-mutant.yaml"
sed -E "s/^(          extra_endpoints: ).*needs\.gerrit.*\$/\\1\${{ format('{0} {1}', inputs.harden_runner_extra_endpoints, needs.gerrit.outputs.endpoint) }}/" \
  "${workflow}" > "${mutant}"
if cmp -s "${mutant}" "${workflow}"; then
  fail "endpoint order mutant did not change the workflow"
elif [ -z "$(endpoint_wiring "${mutant}")" ]; then
  fail "endpoint order mutant passed the wiring check"
elif endpoint_survives "${mutant}" \
  'registry.example.org:443 # temporary access'; then
  fail "endpoint order mutant kept the endpoint behind a comment"
else
  pass
fi
if endpoint_survives "${mutant}" 'registry.example.org:443'; then
  pass
else
  fail "endpoint order mutant lost the endpoint with no comment"
fi

# The check must catch the endpoint returning to allowed-endpoints, or
# leaving extra_endpoints, alone or together.
back_in_allowed() {
  awk -v line="            ${endpoint_expression}" '
    { print }
    /^  lint:$/ { inside = 1 }
    inside && /^            \$\{\{ env\.CONNECTION_ALLOW_LIST \}\}$/ {
      print line
      inside = 0
    }
  ' "${workflow}"
}
out_of_extra() {
  sed -E "s/^(          extra_endpoints: ).*needs\.gerrit.*\$/\\1\${{ inputs.harden_runner_extra_endpoints }}/" \
    "${1:-${workflow}}"
}
for shape in allowed extra both; do
  case "${shape}" in
    allowed) back_in_allowed > "${mutant}" ;;
    extra) out_of_extra > "${mutant}" ;;
    both)
      back_in_allowed > "${mutant}.in"
      out_of_extra "${mutant}.in" > "${mutant}"
      ;;
  esac
  if cmp -s "${mutant}" "${workflow}"; then
    fail "endpoint wiring mutant '${shape}' did not change the workflow"
  elif [ -n "$(endpoint_wiring "${mutant}")" ]; then
    pass
  else
    fail "endpoint wiring mutant '${shape}' passed the check"
  fi
done

# --- Gerrit ref -----------------------------------------------------

# The script is change-isolation.yaml's, whose own fixtures cover it
# in full; these confirm the copy here runs.

# run_gerrit <branch> [url]: sets gerrit_rc, gerrit_log and gerrit_out.
run_gerrit() {
  gerrit_out="${workdir}/gerrit-output-${RANDOM}"
  : > "${gerrit_out}"
  gerrit_rc=0
  gerrit_log=$(GERRIT_URL="${2-https://gerrit.example.org}" \
    GERRIT_PROJECT='releng/project' GERRIT_BRANCH="$1" \
    GITHUB_OUTPUT="${gerrit_out}" \
    python3 -I "${gerrit_script}" 2>&1) || gerrit_rc=$?
}

run_gerrit 'master'
if [ "${gerrit_rc}" -eq 0 ] &&
  grep -qxF 'ref=refs/heads/master' "${gerrit_out}" &&
  grep -qxF 'endpoint=gerrit.example.org:443' "${gerrit_out}"; then
  pass
else
  fail 'Gerrit branch master: expected refs/heads/master' "${gerrit_log}"
fi

run_gerrit 'release/../main'
if [ "${gerrit_rc}" -ne 0 ] && [ ! -s "${gerrit_out}" ]; then
  pass
else
  fail 'branch with ..: expected a rejection' "${gerrit_log}"
fi

run_gerrit 'master' 'http://gerrit.example.org'
if [ "${gerrit_rc}" -ne 0 ] && [ ! -s "${gerrit_out}" ]; then
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
    INPUT_SKIP_HOOKS='' \
    INPUT_PATH_PREFIX='.' \
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
  INPUT_PATH_PREFIX='tests/fixtures/linting-verify'
expect_plan_ok 'path_prefix trailing slash' INPUT_PATH_PREFIX='lint/'
expect_plan_ok 'path_prefix with dots in a name' INPUT_PATH_PREFIX='a..b'
expect_plan_ok 'audit egress' INPUT_HARDEN_RUNNER_EGRESS='audit'
expect_plan_ok 'supplemental list' \
  INPUT_HARDEN_RUNNER_SUPPLEMENTAL_ALLOWLIST='org//extra.txt@abc'
expect_plan_ok 'one skipped hook' INPUT_SKIP_HOOKS='actionlint'
expect_plan_ok 'skip_hooks, space separated' \
  INPUT_SKIP_HOOKS='actionlint write-good'
expect_plan_ok 'skip_hooks, comma separated' \
  INPUT_SKIP_HOOKS='actionlint,write-good, check_yaml.v2'
expect_plan_ok 'skip_hooks, stray separators' INPUT_SKIP_HOOKS=' ,yamllint, '

# Rejected: path_prefix.
expect_plan_error 'path_prefix empty' 'path_prefix is empty' \
  INPUT_PATH_PREFIX=
expect_plan_error 'path_prefix absolute' 'path_prefix must be a relative' \
  INPUT_PATH_PREFIX=/etc/lint
expect_plan_error 'path_prefix root' 'path_prefix must be a relative' \
  INPUT_PATH_PREFIX=/
expect_plan_error 'path_prefix parent' "path_prefix contains a '..' segment" \
  INPUT_PATH_PREFIX=..
expect_plan_error 'path_prefix traversal' \
  "path_prefix contains a '..' segment" INPUT_PATH_PREFIX=lint/../../etc
expect_plan_error 'path_prefix trailing ..' \
  "path_prefix contains a '..' segment" INPUT_PATH_PREFIX=lint/..
expect_plan_error 'path_prefix leading -' "path_prefix starts with '-'" \
  INPUT_PATH_PREFIX=--version
expect_plan_error 'path_prefix space' 'path_prefix contains whitespace' \
  INPUT_PATH_PREFIX='my lint'
expect_plan_error 'path_prefix no-break space' \
  'path_prefix contains whitespace' \
  INPUT_PATH_PREFIX="$(printf 'li\302\240nt')"
expect_plan_error 'path_prefix tab' 'path_prefix contains a control character' \
  INPUT_PATH_PREFIX="$(printf 'li\tnt')"
expect_plan_error 'path_prefix newline' \
  'path_prefix contains a control character' \
  INPUT_PATH_PREFIX="$(printf 'abc\n::warning::injected')"
expect_plan_error 'path_prefix DEL' 'path_prefix contains a control character' \
  INPUT_PATH_PREFIX="$(printf 'li\177nt')"
expect_plan_error 'path_prefix U+0080' \
  'path_prefix contains a control character' \
  INPUT_PATH_PREFIX="$(printf 'li\302\200nt')"
expect_plan_error 'path_prefix U+0085' \
  'path_prefix contains a control character' \
  INPUT_PATH_PREFIX="$(printf 'li\302\205nt')"
expect_plan_error 'path_prefix U+009B' \
  'path_prefix contains a control character' \
  INPUT_PATH_PREFIX="$(printf 'li\302\233nt')"

# Rejected: skip_hooks.
expect_plan_error 'skip_hooks newline' \
  'skip_hooks contains a control character' \
  INPUT_SKIP_HOOKS="$(printf 'actionlint\n::warning::injected')"
expect_plan_error 'skip_hooks tab' 'skip_hooks contains a control character' \
  INPUT_SKIP_HOOKS="$(printf 'action\tlint')"
expect_plan_error 'skip_hooks U+009B' \
  'skip_hooks contains a control character' \
  INPUT_SKIP_HOOKS="$(printf 'action\302\233lint')"
expect_plan_error 'skip_hooks semicolon' 'skip_hooks holds an invalid hook id' \
  INPUT_SKIP_HOOKS='actionlint;id'
expect_plan_error 'skip_hooks command substitution' \
  'skip_hooks holds an invalid hook id' INPUT_SKIP_HOOKS="\$(id)"
expect_plan_error 'skip_hooks backtick' 'skip_hooks holds an invalid hook id' \
  INPUT_SKIP_HOOKS="\`id\`"
expect_plan_error 'skip_hooks pipe' 'skip_hooks holds an invalid hook id' \
  INPUT_SKIP_HOOKS='yamllint|id'
expect_plan_error 'skip_hooks glob' 'skip_hooks holds an invalid hook id' \
  INPUT_SKIP_HOOKS='yaml*'
expect_plan_error 'skip_hooks leading -' 'skip_hooks holds an invalid hook id' \
  INPUT_SKIP_HOOKS='--all-files'
expect_plan_error 'skip_hooks no-break space' \
  'skip_hooks holds an invalid hook id' \
  INPUT_SKIP_HOOKS="$(printf 'yamllint\302\240actionlint')"
expect_plan_error 'skip_hooks non-ASCII letter' \
  'skip_hooks holds an invalid hook id' \
  INPUT_SKIP_HOOKS="$(printf 'yaml\303\251lint')"

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
run_plan INPUT_PATH_PREFIX='/abs' INPUT_SKIP_HOOKS='a;b' \
  INPUT_HARDEN_RUNNER_EGRESS='off'
if [ "${plan_rc}" -ne 0 ] &&
  grep -qF 'path_prefix must be a relative' <<< "${plan_log}" &&
  grep -qF 'skip_hooks holds an invalid hook id' <<< "${plan_log}" &&
  grep -qF 'harden_runner_egress must' <<< "${plan_log}"; then
  pass
else
  fail 'three bad inputs: expected all reported' "${plan_log}"
fi

# --- Plan: patchset dispatch without a refspec ---------------------

# gerrit_to_platform dispatches on the target branch, so a
# 'patchset-created' dispatch whose caller dropped gerrit_refspec would
# fall into GitHub mode and lint the branch tip; so would a
# 'comment-added' one, a recheck say. The plan reads the
# caller's event input and the refspec through 'env'. These run the
# extracted logic; they cannot show that GitHub hands a called
# workflow the caller's event inputs.
for line in \
  "          INPUT_GERRIT_REFSPEC: \${{ inputs.gerrit_refspec }}" \
  "          CALLER_GERRIT_EVENT_TYPE: \${{ github.event.inputs.GERRIT_EVENT_TYPE }}"; do
  if grep -qxF -- "${line}" "${workflow}"; then
    pass
  else
    fail "the plan step does not set '${line#"${line%%[! ]*}"}'"
  fi
done

dispatch_refused="A 'patchset-created' or 'comment-added' Gerrit"
dispatch_refused+=" dispatch passed no gerrit_refspec"
dispatch_cases() {
  local event
  for event in patchset-created comment-added; do
    expect_plan_error "${event} without a refspec" \
      "${dispatch_refused}" INPUT_GERRIT_REFSPEC= \
      CALLER_GERRIT_EVENT_TYPE="${event}"
    expect_plan_ok "${event} with a refspec" \
      CALLER_GERRIT_EVENT_TYPE="${event}" \
      INPUT_GERRIT_REFSPEC='refs/changes/21/46421/1'
  done
  # The match is exact and case-sensitive: only the two event types
  # gerrit_to_platform sends are refused.
  for event in change-merged comment-added-extra Comment-Added \
    Patchset-Created; do
    expect_plan_ok "${event} without a refspec" \
      CALLER_GERRIT_EVENT_TYPE="${event}" INPUT_GERRIT_REFSPEC=
  done
  expect_plan_ok 'empty event type without a refspec' \
    CALLER_GERRIT_EVENT_TYPE= INPUT_GERRIT_REFSPEC=
  expect_plan_ok 'no event type without a refspec'
}
dispatch_cases

# Each refused event type, dropped from a copy of the plan, and the
# match, loosened to a prefix or made case-insensitive, must fail the
# cases above.
dispatch_mutant() {
  case "$1" in
    no-patchset-created) sed '/^ *"patchset-created",$/d' ;;
    no-comment-added) sed '/^ *"comment-added",$/d' ;;
    prefix) sed 's/if event in (/if event.startswith((/; s/^\( *\)) and not environ.get("INPUT_GERRIT_REFSPEC"/\1)) and not environ.get("INPUT_GERRIT_REFSPEC"/' ;;
    any-case) sed 's/if event in (/if event.lower() in (/' ;;
  esac < "${real_plan_script}"
}
real_plan_script="${plan_script}"
for shape in no-patchset-created no-comment-added prefix any-case; do
  plan_script="${workdir}/plan-dispatch-${shape}.py"
  dispatch_mutant "${shape}" > "${plan_script}"
  if cmp -s "${plan_script}" "${real_plan_script}"; then
    fail "dispatch mutant '${shape}' did not change the plan"
    continue
  fi
  # A mutant that does not compile fails every case, proving nothing.
  if ! python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' \
    "${plan_script}" 2> /dev/null; then
    fail "dispatch mutant '${shape}' is not valid Python"
    continue
  fi
  passed_before="${passed}"
  failed_before="${failed}"
  dispatch_cases 2> /dev/null
  # The mutant's results stand for one check, which its failures pass.
  mutant_failed=$((failed - failed_before))
  passed="${passed_before}"
  failed="${failed_before}"
  if [ "${mutant_failed}" -gt 0 ]; then
    pass
  else
    fail "dispatch mutant '${shape}' passed the fixtures"
  fi
done
plan_script="${real_plan_script}"

# --- Plan: refspec shape and dispatch match ------------------------

# A refspec naming a branch checks the branch out and lints its tip;
# one that differs from the dispatch's lints some other patchset.
# Either way the vote would follow. The plan reads the dispatch's
# GERRIT_REFSPEC through 'env' as it reads GERRIT_EVENT_TYPE.
if grep -qxF -- \
  "          CALLER_GERRIT_REFSPEC: \${{ github.event.inputs.GERRIT_REFSPEC }}" \
  "${workflow}"; then
  pass
else
  fail "the plan step does not read the dispatch's GERRIT_REFSPEC"
fi

expect_plan_error 'refspec, a short branch name' \
  'gerrit_refspec is not a Gerrit change ref' INPUT_GERRIT_REFSPEC=master
expect_plan_error 'refspec, a branch ref' \
  'gerrit_refspec is not a Gerrit change ref' \
  INPUT_GERRIT_REFSPEC=refs/heads/master
expect_plan_error 'refspec, a one-digit shard' \
  'gerrit_refspec is not a Gerrit change ref' \
  INPUT_GERRIT_REFSPEC=refs/changes/5/5/1
expect_plan_error 'refspec, a trailing segment' \
  'gerrit_refspec is not a Gerrit change ref' \
  INPUT_GERRIT_REFSPEC=refs/changes/45/12345/1/x
expect_plan_error 'refspec, no patchset' \
  'gerrit_refspec is not a Gerrit change ref' \
  INPUT_GERRIT_REFSPEC=refs/changes/45/12345
expect_plan_error 'refspec, a trailing newline' \
  'gerrit_refspec is not a Gerrit change ref' \
  INPUT_GERRIT_REFSPEC="$(printf 'refs/changes/45/12345/1\n::warning::x')"
expect_plan_error 'refspec, non-ASCII digits' \
  'gerrit_refspec is not a Gerrit change ref' \
  INPUT_GERRIT_REFSPEC="$(printf 'refs/changes/45/1234\331\245/1')"
expect_plan_error 'refspec, the wrong two-digit part' \
  "gerrit_refspec's two-digit part does not match" \
  INPUT_GERRIT_REFSPEC=refs/changes/46/12345/1
expect_plan_error 'refspec, an unpadded change in the wrong shard' \
  "gerrit_refspec's two-digit part does not match" \
  INPUT_GERRIT_REFSPEC=refs/changes/50/5/1
expect_plan_ok 'refspec, a five-digit change' \
  INPUT_GERRIT_REFSPEC=refs/changes/45/12345/1
expect_plan_ok 'refspec, a one-digit change, zero padded' \
  INPUT_GERRIT_REFSPEC=refs/changes/05/5/3

expect_plan_error 'refspec differs from the dispatch' \
  'gerrit_refspec differs from the GERRIT_REFSPEC' \
  INPUT_GERRIT_REFSPEC=refs/changes/45/12345/2 \
  CALLER_GERRIT_REFSPEC=refs/changes/45/12345/1 \
  CALLER_GERRIT_EVENT_TYPE='patchset-created'
expect_plan_error 'refspec, another change than the dispatch' \
  'gerrit_refspec differs from the GERRIT_REFSPEC' \
  INPUT_GERRIT_REFSPEC=refs/changes/21/46421/1 \
  CALLER_GERRIT_REFSPEC=refs/changes/45/12345/1
expect_plan_ok 'refspec matches the dispatch' \
  INPUT_GERRIT_REFSPEC=refs/changes/45/12345/1 \
  CALLER_GERRIT_REFSPEC=refs/changes/45/12345/1 \
  CALLER_GERRIT_EVENT_TYPE='patchset-created'
expect_plan_ok 'refspec, the dispatch carries none (hybrid caller)' \
  INPUT_GERRIT_REFSPEC=refs/changes/45/12345/1 CALLER_GERRIT_REFSPEC=

# The caller votes on the dispatch's GERRIT_CHANGE_NUMBER and
# GERRIT_PATCHSET_NUMBER, so the refspec linted must carry the same
# numbers, compared as digit strings. The plan reads both through
# 'env'.
for line in \
  "          CALLER_GERRIT_CHANGE_NUMBER: \${{ github.event.inputs.GERRIT_CHANGE_NUMBER }}" \
  "          CALLER_GERRIT_PATCHSET_NUMBER: \${{ github.event.inputs.GERRIT_PATCHSET_NUMBER }}"; do
  if grep -qxF -- "${line}" "${workflow}"; then
    pass
  else
    fail "the plan step does not set '${line#"${line%%[! ]*}"}'"
  fi
done

# expect_numbers_ok <label> <change> <patchset>: the dispatch values
# against refspec refs/changes/21/46421/1.
expect_numbers_ok() {
  expect_plan_ok "$1" INPUT_GERRIT_REFSPEC=refs/changes/21/46421/1 \
    CALLER_GERRIT_CHANGE_NUMBER="$2" CALLER_GERRIT_PATCHSET_NUMBER="$3"
}
# expect_numbers_error <label> <message> <change> <patchset>
expect_numbers_error() {
  expect_plan_error "$1" "$2" INPUT_GERRIT_REFSPEC=refs/changes/21/46421/1 \
    CALLER_GERRIT_CHANGE_NUMBER="$3" CALLER_GERRIT_PATCHSET_NUMBER="$4"
}
change_differs="gerrit_refspec's change number differs"
patchset_differs="gerrit_refspec's patchset number differs"
number_cases() {
  expect_numbers_error 'refspec, another change than the dispatch number' \
    "${change_differs}" 46422 1
  expect_numbers_error 'refspec, a zero-padded dispatch change number' \
    "${change_differs}" 046421 1
  expect_numbers_error 'refspec, another patchset than the dispatch number' \
    "${patchset_differs}" 46421 2
  expect_numbers_error 'refspec, a zero-padded dispatch patchset number' \
    "${patchset_differs}" 46421 01
  expect_numbers_ok 'refspec matches the dispatch numbers' 46421 1
  expect_numbers_ok 'refspec, no dispatch change number' '' 1
  expect_numbers_ok 'refspec, no dispatch patchset number' 46421 ''
  expect_numbers_ok 'refspec, no dispatch numbers' '' ''
}
number_cases
# Both numbers wrong reports both, so neither check hides the other.
run_plan INPUT_GERRIT_REFSPEC=refs/changes/21/46421/1 \
  CALLER_GERRIT_CHANGE_NUMBER=46422 CALLER_GERRIT_PATCHSET_NUMBER=2
if [ "${plan_rc}" -ne 0 ] && grep -qF "${change_differs}" <<< "${plan_log}" \
  && grep -qF "${patchset_differs}" <<< "${plan_log}"; then
  pass
else
  fail 'refspec, both dispatch numbers differ: expected two errors' \
    "${plan_log}"
fi

# Each comparison, weakened in a copy of the plan, must fail the cases
# above: dropped, or made tolerant of leading zeros.
number_mutant() {
  case "$1" in
    no-change) sed 's/if dispatched_change and change != dispatched_change:/if False:/' ;;
    no-patchset) sed 's/if dispatched_patchset and patchset != dispatched_patchset:/if False:/' ;;
    int-change) sed 's/and change != dispatched_change:/and int(change) != int(dispatched_change):/' ;;
    int-patchset) sed 's/and patchset != dispatched_patchset:/and int(patchset) != int(dispatched_patchset):/' ;;
  esac < "${real_plan_script}"
}
real_plan_script="${plan_script}"
for shape in no-change no-patchset int-change int-patchset; do
  plan_script="${workdir}/plan-${shape}.py"
  number_mutant "${shape}" > "${plan_script}"
  if cmp -s "${plan_script}" "${real_plan_script}"; then
    fail "refspec number mutant '${shape}' did not change the plan"
    continue
  fi
  passed_before="${passed}"
  failed_before="${failed}"
  number_cases 2> /dev/null
  # The mutant's results stand for one check, which its failures pass.
  mutant_failed=$((failed - failed_before))
  passed="${passed_before}"
  failed="${failed_before}"
  if [ "${mutant_failed}" -gt 0 ]; then
    pass
  else
    fail "refspec number mutant '${shape}' passed the fixtures"
  fi
done
plan_script="${real_plan_script}"
# An empty gerrit_refspec selects GitHub mode, which check_dispatch
# governs: right for 'change-merged', refused for 'patchset-created'
# and 'comment-added'.
expect_plan_ok 'change-merged, GitHub mode, dispatch carries a refspec' \
  INPUT_GERRIT_REFSPEC= CALLER_GERRIT_REFSPEC=refs/changes/45/12345/1 \
  CALLER_GERRIT_EVENT_TYPE='change-merged'

# --- Checked-out revision -----------------------------------------

# After the Gerrit checkout, HEAD must be the patchset revision the
# dispatch carried, when it carried one. The step reads it through
# 'env', runs in Gerrit mode alone, after that checkout and before the
# hooks.
if grep -qxF -- \
  "          CALLER_GERRIT_PATCHSET_REVISION: \${{ github.event.inputs.GERRIT_PATCHSET_REVISION }}" \
  "${workflow}"; then
  pass
else
  fail "the revision step does not read GERRIT_PATCHSET_REVISION"
fi
revision_at=$(step_index 'Verify the checked-out revision')
if [ -n "${revision_at}" ] && [ -n "${gerrit_at}" ] &&
  [ "${gerrit_at}" -lt "${revision_at}" ] &&
  [ "${revision_at}" -lt "${hooks_at:-0}" ]; then
  pass
else
  fail 'the revision check does not follow the Gerrit checkout' \
    "${lint_steps}"
fi
revision_if=$(awk '
  /^      - name: .Verify the checked-out revision.$/ { inside = 1; next }
  inside && /^      - name:/ { inside = 0 }
  inside && /^        if:/ { sub(/^ *if: */, ""); print }
' "${workflow}")
if [ "${revision_if}" = "inputs.gerrit_refspec != ''" ]; then
  pass
else
  fail "the revision check does not run in Gerrit mode" \
    "${revision_if:-no condition}"
fi

# A throwaway repository with two commits, isolated from any user or
# system git configuration.
revision_repo="${workdir}/revision-repo"
revision_git() {
  env GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 git -C "${revision_repo}" \
    -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false "$@"
}
mkdir -p "${revision_repo}"
revision_git init -q
revision_git commit -q --allow-empty -m 'first'
old_revision=$(revision_git rev-parse HEAD)
revision_git commit -q --allow-empty -m 'second'
head_revision=$(revision_git rev-parse HEAD)

# run_revision [VAR=value ...]: sets revision_rc and revision_log.
run_revision() {
  revision_rc=0
  revision_log=$(cd "${revision_repo}" && env -i PATH="${PATH}" \
    GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 "$@" \
    bash -euo pipefail "${revision_script}" 2>&1) || revision_rc=$?
}

run_revision CALLER_GERRIT_PATCHSET_REVISION="${head_revision}"
if [ "${revision_rc}" -eq 0 ] &&
  grep -qF 'dispatched patchset revision ✅' <<< "${revision_log}"; then
  pass
else
  fail 'revision: HEAD equals the dispatch, expected a pass' \
    "${revision_log}"
fi
run_revision CALLER_GERRIT_PATCHSET_REVISION="${old_revision}"
if [ "${revision_rc}" -ne 0 ] &&
  grep -qF '::error::The checked-out commit is not' \
    <<< "${revision_log}" &&
  ! grep -qF "${old_revision}" <<< "${revision_log}"; then
  pass
else
  fail 'revision: HEAD differs from the dispatch, expected a failure' \
    "${revision_log}"
fi
run_revision \
  CALLER_GERRIT_PATCHSET_REVISION="$(printf '%s\n::warning::x' \
    "${head_revision}")"
if [ "${revision_rc}" -ne 0 ] &&
  ! grep -qF '::warning::x' <<< "${revision_log}"; then
  pass
else
  fail 'revision: a forged dispatch value, expected a quiet failure' \
    "${revision_log}"
fi
for empty in set unset; do
  if [ "${empty}" = set ]; then
    run_revision CALLER_GERRIT_PATCHSET_REVISION=
  else
    run_revision
  fi
  if [ "${revision_rc}" -eq 0 ] &&
    grep -qF 'No dispatched patchset revision' <<< "${revision_log}"; then
    pass
  else
    fail "revision: dispatch value ${empty} but empty, expected a skip" \
      "${revision_log}"
  fi
done

# --- prek.toml refusal ----------------------------------------------

# The linting action runs <path_prefix>/.pre-commit-config.yaml, and
# prek prefers a prek.toml beside it, so the Lint job refuses one in
# both modes, after either checkout has prepared the tree and the
# credentials have gone, and before any hook runs.
prek_toml_at=$(step_index 'Refuse a prek.toml configuration')
drop_at=$(step_index 'Remove checkout credentials')
if [ -n "${prek_toml_at}" ] &&
  [ "${prek_toml_at}" -gt "${gerrit_at:-0}" ] &&
  [ "${prek_toml_at}" -gt "${github_at:-0}" ] &&
  [ "${prek_toml_at}" -gt "${drop_at:-0}" ] &&
  [ "${prek_toml_at}" -lt "${hooks_at:-0}" ]; then
  pass
else
  fail 'the prek.toml refusal does not sit between the checkouts and' \
    "the hooks: ${lint_steps}"
fi
prek_toml_step=$(awk '
  /^      - name: .Refuse a prek.toml configuration.$/ {
    inside = 1
    next
  }
  inside && /^      - / { inside = 0 }
  inside { print }
' "${workflow}")
if ! grep -qE '^        if:' <<< "${prek_toml_step}"; then
  pass
else
  fail 'the prek.toml refusal must run in both modes' "${prek_toml_step}"
fi
if grep -qxF \
  "          INPUT_PATH_PREFIX: \${{ inputs.path_prefix }}" \
  <<< "${prek_toml_step}"; then
  pass
else
  fail 'the prek.toml refusal does not read path_prefix through env' \
    "${prek_toml_step}"
fi

# Each case builds a throwaway tree holding a .pre-commit-config.yaml
# at the root and under 'sub', plus whatever the case adds.
prek_case=0
# new_prek_tree: sets prek_tree to a fresh tree.
new_prek_tree() {
  prek_case=$((prek_case + 1))
  prek_tree="${workdir}/prek-tree-${prek_case}"
  mkdir -p "${prek_tree}/sub" "${prek_tree}/other"
  : > "${prek_tree}/.pre-commit-config.yaml"
  : > "${prek_tree}/sub/.pre-commit-config.yaml"
}
# run_prek_toml [VAR=value ...]: sets prek_toml_rc and prek_toml_log.
run_prek_toml() {
  prek_toml_rc=0
  prek_toml_log=$(cd "${prek_tree}" && env -i PATH="${PATH}" "$@" \
    bash -euo pipefail "${prek_toml_script}" 2>&1) || prek_toml_rc=$?
}
expect_prek_toml_refused() {
  local label="$1"
  shift
  run_prek_toml "$@"
  if [ "${prek_toml_rc}" -ne 0 ] &&
    grep -qF '::error::A prek.toml sits beside' <<< "${prek_toml_log}" &&
    ! grep -qF 'sub/' <<< "${prek_toml_log}"; then
    pass
  else
    fail "prek.toml: ${label}, expected a refusal" "${prek_toml_log}"
  fi
}
expect_prek_toml_ok() {
  local label="$1"
  shift
  run_prek_toml "$@"
  if [ "${prek_toml_rc}" -eq 0 ] &&
    grep -qF 'No prek.toml configuration found' <<< "${prek_toml_log}"; then
    pass
  else
    fail "prek.toml: ${label}, expected a pass" "${prek_toml_log}"
  fi
}
prek_toml_cases() {
  new_prek_tree
  : > "${prek_tree}/prek.toml"
  expect_prek_toml_refused 'prek.toml at the root' INPUT_PATH_PREFIX=.
  expect_prek_toml_refused 'prek.toml at the root, no prefix'
  new_prek_tree
  : > "${prek_tree}/sub/prek.toml"
  expect_prek_toml_refused 'prek.toml under path_prefix' \
    INPUT_PATH_PREFIX=sub
  new_prek_tree
  ln -s missing-target "${prek_tree}/prek.toml"
  expect_prek_toml_refused 'a dangling prek.toml symlink at the root' \
    INPUT_PATH_PREFIX=.
  new_prek_tree
  ln -s missing-target "${prek_tree}/sub/prek.toml"
  expect_prek_toml_refused 'a dangling prek.toml symlink under sub' \
    INPUT_PATH_PREFIX=sub
  new_prek_tree
  : > "${prek_tree}/other/prek.toml"
  expect_prek_toml_ok 'prek.toml in another directory, root prefix' \
    INPUT_PATH_PREFIX=.
  expect_prek_toml_ok 'prek.toml in another directory, sub prefix' \
    INPUT_PATH_PREFIX=sub
  new_prek_tree
  expect_prek_toml_ok 'no prek.toml, root prefix' INPUT_PATH_PREFIX=.
  expect_prek_toml_ok 'no prek.toml, sub prefix' INPUT_PATH_PREFIX=sub
}
prek_toml_cases

# Dropping either test, ignoring path_prefix, searching the whole
# tree, refusing everything, or not failing must each fail the cases
# above.
# shellcheck disable=SC2016  # sed expressions, not strings to expand
prek_toml_mutant() {
  case "$1" in
    no-symlink) sed 's/ || \[ -L "\${toml}" \]//' ;;
    no-exists) sed 's/\[ -e "\${toml}" \] || //' ;;
    root-only) sed 's|toml="\${prefix}/prek.toml"|toml=prek.toml|' ;;
    anywhere) sed 's/^if \[ -e "\${toml}" \] || \[ -L "\${toml}" \]; then$/if find . -name prek.toml | grep -q .; then/' ;;
    always) sed 's/^if \[ -e "\${toml}" \] || \[ -L "\${toml}" \]; then$/if true; then/' ;;
    no-exit) sed 's/^  exit 1$/  :/' ;;
  esac < "${real_prek_toml_script}"
}
real_prek_toml_script="${prek_toml_script}"
for shape in no-symlink no-exists root-only anywhere always no-exit; do
  prek_toml_script="${workdir}/prek-toml-${shape}.sh"
  prek_toml_mutant "${shape}" > "${prek_toml_script}"
  if cmp -s "${prek_toml_script}" "${real_prek_toml_script}"; then
    fail "prek.toml mutant '${shape}' did not change the script"
    continue
  fi
  if ! bash -n "${prek_toml_script}" 2> /dev/null; then
    fail "prek.toml mutant '${shape}' is not valid bash"
    continue
  fi
  passed_before="${passed}"
  failed_before="${failed}"
  prek_toml_cases 2> /dev/null
  # The mutant's results stand for one check, which its failures pass.
  mutant_failed=$((failed - failed_before))
  passed="${passed_before}"
  failed="${failed_before}"
  if [ "${mutant_failed}" -gt 0 ]; then
    pass
  else
    fail "prek.toml mutant '${shape}' passed the fixtures"
  fi
done
prek_toml_script="${real_prek_toml_script}"

# --- Harden-runner gate -------------------------------------------

# harden-runner's step succeeds with no agent when the agent times out
# or the 'skip-harden-runner' property is set; the Lint job must then
# stop. The extracted step runs against a scratch agent directory,
# with the wait cut to one second.
agent_dir="${workdir}/agent"
gate_run="${workdir}/harden-gate-run.sh"
sed -e "s#/home/agent/#${agent_dir}/#g" \
  -e 's#agent.status 60 #agent.status 1 #' "${gate_script}" > "${gate_run}"
if grep -q '/home/agent/' "${gate_run}" ||
  ! grep -q 'agent.status 1 ' "${gate_run}"; then
  echo 'ERROR: could not redirect the gate to a scratch agent' >&2
  exit 1
fi

# run_gate <egress> <agent.json?> <agent.status?> [VAR=value ...]: sets
# gate_rc and gate_log. A GitHub-hosted Linux runner unless overridden.
run_gate() {
  local egress="$1" config="$2" status="$3"
  shift 3
  rm -rf "${agent_dir}"
  mkdir -p "${agent_dir}"
  if [ "${config}" = yes ]; then : > "${agent_dir}/agent.json"; fi
  if [ "${status}" = yes ]; then : > "${agent_dir}/agent.status"; fi
  gate_rc=0
  gate_log=$(env -i PATH="${PATH}" RUNNER_OS=Linux \
    RUNNER_ENVIRONMENT=github-hosted \
    INPUT_HARDEN_RUNNER_EGRESS="${egress}" "$@" \
    bash -euo pipefail "${gate_run}" 2>&1) || gate_rc=$?
}

# expect_gate <label> <pass|fail> <egress> <config> <status> [VAR=...]
expect_gate() {
  local label="$1" want="$2"
  shift 2
  run_gate "$@"
  if { [ "${want}" = pass ] && [ "${gate_rc}" -eq 0 ] &&
    grep -qF 'is monitoring this runner' <<< "${gate_log}"; } ||
    { [ "${want}" = fail ] && [ "${gate_rc}" -ne 0 ] &&
      grep -qF '::error::' <<< "${gate_log}"; }; then
    pass
  else
    fail "harden gate, ${label}: expected it to ${want}" "${gate_log}"
  fi
}

expect_gate 'agent running' pass block yes yes
expect_gate 'agent running, audit' pass audit yes yes
# 'skip-harden-runner': the pre-step returns before it writes either
# file.
expect_gate 'skip-harden-runner, block' fail block no no
expect_gate 'skip-harden-runner, audit' fail audit no no
# Startup timed out: the configuration exists, the status never came.
expect_gate 'agent timed out' fail block yes no
expect_gate 'custom image agent' pass block no no \
  STEP_SECURITY_HARDEN_RUNNER=true
expect_gate 'self-hosted runner, stale status file' fail block yes yes \
  RUNNER_ENVIRONMENT=self-hosted
expect_gate 'not Linux' fail block yes yes RUNNER_OS=Windows

# --- Example vote -------------------------------------------------

# The example derives its Gerrit vote from the 'needs' results. The
# vote job runs only when the run was not cancelled, so a run that a
# recheck superseded cannot overwrite the newer run's vote. A small
# evaluator for the GitHub expression operators the line uses runs
# the line itself over every combination of job results and compares
# it with the rule written out longhand: success only when every
# result is success, and failure otherwise. It tests the expression's
# logic, not GitHub's evaluator.
example="${repo_root}/examples/linting-verify/gerrit-linting-verify.yaml"
if [ ! -f "${example}" ]; then
  echo "ERROR: example not found: ${example}" >&2
  exit 1
fi
vote_lines=$(grep -cE '^[[:space:]]*vote-type: \$\{\{' "${example}" ||
  true)
vote_expression=$(sed -nE \
  's/^[[:space:]]*vote-type: \$\{\{ (.*) \}\}$/\1/p' "${example}")
if [ "${vote_lines}" -eq 1 ] && [ -n "${vote_expression}" ]; then
  pass
else
  fail "expected one 'vote-type' expression in the example" \
    "$(grep -n 'vote-type:' "${example}")"
fi
# The jobs API race: the example reads no conclusion from it, and so
# needs no 'actions: read'.
if grep -nE 'workflow-conclusion@|actions: read' "${example}"; then
  fail 'the example still reads the run conclusion from the jobs API'
else
  pass
fi

# vote_if_ok <file>: the vote job's only 'if' is the !cancelled()
# condition, and nothing in the job calls always(), which would keep
# a superseded run voting.
vote_if_ok() {
  local job
  job=$(awk '
    /^  vote:$/ { inside = 1; next }
    inside && /^  [a-z]/ { inside = 0 }
    inside && !/^[[:space:]]*#/
  ' "$1")
  [ "$(grep -cE '^    if:' <<< "${job}")" -eq 1 ] &&
    grep -qxF -- "    if: \${{ !cancelled() && needs.visibility.outputs.visible == 'true' }}" \
      <<< "${job}" &&
    ! grep -qF 'always()' <<< "${job}"
}
if vote_if_ok "${example}"; then
  pass
else
  fail "the vote job's 'if' is not the !cancelled() condition" \
    "$(grep -nE '^    if:' "${example}")"
fi
vote_if_mutant="${workdir}/gerrit-linting-verify-if-mutant.yaml"
for shape in always dropped both negation; do
  case "${shape}" in
    always) sed 's/^\(    if: \${{ \)!cancelled()/\1always()/' "${example}" ;;
    dropped) sed 's/^\(    if: \${{ \)!cancelled() && /\1/' "${example}" ;;
    both) sed 's/^\(    if: \${{ \)!cancelled()/\1always() \&\& !cancelled()/' \
      "${example}" ;;
    negation) sed 's/^\(    if: \${{ \)!cancelled()/\1cancelled()/' "${example}" ;;
  esac > "${vote_if_mutant}"
  if cmp -s "${vote_if_mutant}" "${example}"; then
    fail "vote 'if' mutant '${shape}' did not change the example"
  elif vote_if_ok "${vote_if_mutant}"; then
    fail "vote 'if' mutant '${shape}' passed the check"
  else
    pass
  fi
done

# The evaluator, shared by the vote rule and the concurrency group
# fixtures below.
expression_lib="${workdir}/expression.py"
cat > "${expression_lib}" <<'PYEOF'
import itertools
import re
import sys

TOKEN = re.compile(
    r"\s*(?:(?P<str>'(?:[^']|'')*')|(?P<op>&&|\|\||==|!=|[!().,*])"
    r"|(?P<name>[A-Za-z_][A-Za-z0-9_-]*))"
)


def tokenize(text):
    tokens, pos = [], 0
    while pos < len(text.rstrip()):
        match = TOKEN.match(text, pos)
        if not match:
            raise SyntaxError(f"cannot read {text[pos:]!r}")
        pos = match.end()
        kind = match.lastgroup
        value = match.group(kind)
        if kind == "str":
            value = value[1:-1].replace("''", "'")
        tokens.append((kind, value))
    return tokens


def truthy(value):
    return value not in (None, False, 0, "")


def equal(left, right):
    if isinstance(left, str) and isinstance(right, str):
        return left.lower() == right.lower()
    return left == right


def contains(search, item):
    if isinstance(search, list):
        return any(equal(element, item) for element in search)
    return str(item).lower() in str(search).lower()


class Parser:
    def __init__(self, text, context):
        self.tokens = tokenize(text)
        self.context = context

    def peek(self):
        return self.tokens[0] if self.tokens else (None, None)

    def take(self, value=None):
        token = self.tokens.pop(0)
        if value is not None and token[1] != value:
            raise SyntaxError(f"expected {value!r}, got {token[1]!r}")
        return token

    def parse(self):
        value = self.disjunction()
        if self.tokens:
            raise SyntaxError(f"trailing {self.tokens!r}")
        return value

    def disjunction(self):
        value = self.conjunction()
        while self.peek() == ("op", "||"):
            self.take()
            right = self.conjunction()
            value = value if truthy(value) else right
        return value

    def conjunction(self):
        value = self.comparison()
        while self.peek() == ("op", "&&"):
            self.take()
            right = self.comparison()
            value = right if truthy(value) else value
        return value

    def comparison(self):
        value = self.unary()
        while self.peek() in (("op", "=="), ("op", "!=")):
            negate = self.take()[1] == "!="
            result = equal(value, self.unary())
            value = not result if negate else result
        return value

    def unary(self):
        if self.peek() == ("op", "!"):
            self.take()
            return not truthy(self.unary())
        return self.postfix()

    def postfix(self):
        value = self.primary()
        while self.peek() == ("op", "."):
            self.take()
            kind, name = self.take()
            if name == "*":
                value = list(value.values()) if isinstance(
                    value, dict) else value
            elif isinstance(value, list):
                value = [
                    element.get(name) if isinstance(element, dict)
                    else None for element in value
                ]
            else:
                value = value.get(name) if isinstance(value, dict) else None
        return value

    def primary(self):
        kind, value = self.take()
        if kind == "str":
            return value
        if (kind, value) == ("op", "("):
            inner = self.disjunction()
            self.take(")")
            return inner
        if kind != "name":
            raise SyntaxError(f"unexpected {value!r}")
        if value in ("true", "false"):
            return value == "true"
        if value == "null":
            return None
        if self.peek() == ("op", "("):
            self.take()
            args = [self.disjunction()]
            while self.peek() == ("op", ","):
                self.take()
                args.append(self.disjunction())
            self.take(")")
            if value != "contains" or len(args) != 2:
                raise SyntaxError(f"unsupported function {value}")
            return contains(*args)
        return self.context.get(value)
PYEOF

vote_script="${workdir}/vote.py"
{
  cat "${expression_lib}"
  cat <<'PYEOF'


def expected(results):
    if all(result == "success" for result in results):
        return "success"
    return "failure"


RESULTS = ("success", "failure", "cancelled", "skipped")
expression = sys.argv[1]
failures = 0
cases = 0
# One, two and three needs, the last the example's own, then a
# caller that keeps a fourth job.
for jobs in (
    ("linting-verify",),
    ("prepare", "linting-verify"),
    ("visibility", "prepare", "linting-verify"),
    ("visibility", "prepare", "linting-verify", "tox-verify"),
):
    for combination in itertools.product(RESULTS, repeat=len(jobs)):
        needs = {
            job: {"result": result, "outputs": {}}
            for job, result in zip(jobs, combination)
        }
        vote = Parser(expression, {"needs": needs}).parse()
        cases += 1
        if vote != expected(combination):
            failures += 1
            print(f"{dict(zip(jobs, combination))}: voted {vote!r},"
                  f" expected {expected(combination)!r}")
print(f"{cases} vote cases, {failures} wrong")
sys.exit(1 if failures else 0)
PYEOF
} > "${vote_script}"
vote_rc=0
vote_log=$(python3 -I "${vote_script}" "${vote_expression}" 2>&1) ||
  vote_rc=$?
if [ "${vote_rc}" -eq 0 ]; then
  pass
else
  fail "the example's vote rule is wrong" "${vote_log}"
fi

# The evaluator must catch a wrong rule: each mutant of the line, a
# clause dropped, the outcomes swapped or the old cancelled branch
# restored, has to fail it.
mapfile -t vote_mutants < <(python3 -I -c '
import sys
rule = sys.argv[1]
for old, new in (
    ("!contains(needs.*.result, \x27failure\x27) && ", ""),
    ("!contains(needs.*.result, \x27cancelled\x27) && ", ""),
    (" && !contains(needs.*.result, \x27skipped\x27)", ""),
    ("\x27success\x27 || \x27failure\x27",
     "\x27failure\x27 || \x27success\x27"),
):
    print(rule.replace(old, new, 1))
print("contains(needs.*.result, \x27cancelled\x27) && \x27cancelled\x27 || " + rule)
print("contains(needs.*.result, \x27failure\x27) && \x27failure\x27 || \x27success\x27")
' "${vote_expression}")
for vote_mutant in "${vote_mutants[@]}"; do
  if [ "${vote_mutant}" = "${vote_expression}" ]; then
    fail "vote mutant did not change the rule" "${vote_mutant}"
  elif python3 -I "${vote_script}" "${vote_mutant}" > /dev/null 2>&1; then
    fail "the vote evaluator passed a wrong rule" "${vote_mutant}"
  else
    pass
  fi
done

# --- Example concurrency group ------------------------------------

# The example keys its concurrency group by change and patchset
# number: a recheck naming an older patchset must not cancel a newer
# one's run, a repeat dispatch for one patchset must cancel the run in
# flight, and a dispatch with no change number must fall back to the
# run ID. GitHub compares group names case-insensitively, so the
# comparisons here do too. The same evaluator renders the group's
# expressions; it tests the key's logic, not GitHub's evaluator.
group_lines=$(grep -cE '^  group: ' "${example}" || true)
group_template=$(sed -nE 's/^  group: (.*)$/\1/p' "${example}")
if [ "${group_lines}" -eq 1 ] && [ -n "${group_template}" ] &&
  grep -qxF '  cancel-in-progress: true' "${example}"; then
  pass
else
  fail "expected one concurrency group, cancelling in progress" \
    "$(grep -nE '^  (group|cancel-in-progress):' "${example}")"
fi

group_script="${workdir}/group.py"
{
  cat "${expression_lib}"
  cat <<'PYEOF'


def render(template, context):
    def value(match):
        result = Parser(match.group(1), context).parse()
        if result is None:
            return ""
        if isinstance(result, bool):
            return "true" if result else "false"
        return str(result)

    return re.sub(r"\$\{\{(.*?)\}\}", value, template)


def group(template, run_id="100", workflow="Gerrit Linting Verify",
          **inputs):
    base = {
        "GERRIT_CHANGE_NUMBER": "46421",
        "GERRIT_PATCHSET_NUMBER": "1",
        "GERRIT_PROJECT": "releng/builder",
        "GERRIT_BRANCH": "main",
        "GERRIT_CHANGE_ID": "I0123456789abcdef0123456789abcdef01234567",
    }
    base.update(inputs)
    base = {key: val for key, val in base.items() if val is not None}
    context = {
        "github": {"workflow": workflow, "run_id": run_id},
        "inputs": base,
    }
    return render(template, context)


def same(left, right):
    return left.lower() == right.lower()


template = sys.argv[1]
failures = []


def check(name, condition):
    if not condition:
        failures.append(name)


check("two patchsets of one change share a group",
      not same(group(template, GERRIT_PATCHSET_NUMBER="1"),
               group(template, run_id="101", GERRIT_PATCHSET_NUMBER="2")))
check("a recheck of one patchset gets another group",
      same(group(template), group(template, run_id="101")))
check("two changes share a group",
      not same(group(template),
               group(template, run_id="101", GERRIT_CHANGE_NUMBER="46422")))
check("cherry-picks to 'main' and 'Main' share a group",
      not same(group(template),
               group(template, run_id="101", GERRIT_CHANGE_NUMBER="46430",
                     GERRIT_BRANCH="Main")))
check("change 1 patchset 23 shares a group with change 12 patchset 3",
      not same(group(template, GERRIT_CHANGE_NUMBER="1",
                     GERRIT_PATCHSET_NUMBER="23"),
               group(template, run_id="101", GERRIT_CHANGE_NUMBER="12",
                     GERRIT_PATCHSET_NUMBER="3")))
check("the group depends on the project, branch or Change-Id",
      same(group(template),
           group(template, run_id="101", GERRIT_PROJECT="other/project",
                 GERRIT_BRANCH="stable",
                 GERRIT_CHANGE_ID="Ifedcba9876543210fedcba9876543210fedcba98")))
check("two workflows share a group",
      not same(group(template),
               group(template, run_id="101", workflow="Other Verify")))
for empty in ("", None):
    first = group(template, GERRIT_CHANGE_NUMBER=empty)
    second = group(template, run_id="101", GERRIT_CHANGE_NUMBER=empty)
    check(f"an empty change number ({empty!r}) does not fall back to the"
          " run ID", "100" in first and "101" in second
          and not same(first, second))
for failure in failures:
    print(failure)
print(f"{len(failures)} concurrency group checks failed")
sys.exit(1 if failures else 0)
PYEOF
} > "${group_script}"
group_rc=0
group_log=$(python3 -I "${group_script}" "${group_template}" 2>&1) ||
  group_rc=$?
if [ "${group_rc}" -eq 0 ]; then
  pass
else
  fail "the example's concurrency group is wrong" "${group_log}"
fi

# Each mutant of the key, the patchset or the run ID fallback dropped,
# the old Change-Id or project and branch key restored, the run ID in
# place of the patchset, the workflow or a separator dropped, has to
# fail it.
group_mutate="${workdir}/group-mutants.py"
cat > "${group_mutate}" <<'PYEOF'
import sys
group = sys.argv[1]
for old, new in (
    ("-${{ inputs.GERRIT_PATCHSET_NUMBER }}", ""),
    ("${{ inputs.GERRIT_PATCHSET_NUMBER }}", "${{ github.run_id }}"),
    (" || github.run_id", ""),
    ("inputs.GERRIT_CHANGE_NUMBER", "inputs.GERRIT_CHANGE_ID"),
    ("${{ github.workflow }}-", ""),
    ("${{ github.workflow }}-",
     "${{ github.workflow }}-${{ inputs.GERRIT_PROJECT }}-"
     "${{ inputs.GERRIT_BRANCH }}-"),
    ("}}-${{ inputs.GERRIT_PATCHSET_NUMBER",
     "}}${{ inputs.GERRIT_PATCHSET_NUMBER"),
):
    print(group.replace(old, new, 1))
PYEOF
mapfile -t group_mutants < <(python3 -I "${group_mutate}" "${group_template}")
for group_mutant in "${group_mutants[@]}"; do
  if [ "${group_mutant}" = "${group_template}" ]; then
    fail "group mutant did not change the key" "${group_mutant}"
  elif python3 -I "${group_script}" "${group_mutant}" > /dev/null 2>&1; then
    fail "the group check passed a wrong key" "${group_mutant}"
  else
    pass
  fi
done

# --- Summary --------------------------------------------------------

total=$((passed + failed))
if [ "${failed}" -ne 0 ]; then
  echo "${failed} of ${total} linting verify fixture(s) failed" >&2
  exit 1
fi
echo "All ${total} linting verify fixtures passed"
