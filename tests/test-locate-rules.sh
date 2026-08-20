#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the shell decision rules in the locate step of
# .github/workflows/linting.yaml.
#
# tests/test-lint-plan.sh covers the Python resolver. The rules here
# sit earlier, in shell, and decide whether the resolver runs at all
# -- or whether the job is safe to run. Each turns an unknown into a
# verdict, so a wrong answer ends in a green check that linted
# nothing. For example:
#
#   dangling_component  - is the configuration really absent, or did
#                         the sparse checkout leave a symlink hanging?
#   org_status_verdict  - does this HTTP status mean 'no configuration'
#                         or 'could not find out'?
#   org_absence_verdict - a 404 on the file says nothing while the
#                         repository itself may be unreadable; was the
#                         file really absent?
#   skip_prefilter      - can a 'ci.skip' key be ruled out from the
#                         bytes alone, or must this parse?
#   harden_runner_verdict - is harden-runner actually monitoring this
#                         job, or did it return early and leave it
#                         unprotected?
#
# The authoritative list is the extraction check below, which fails
# if any named function goes missing -- so it stays correct as the
# suite grows, where a prose summary would drift.
#
# The rules are EXTRACTED from the workflow rather than copied, so
# there is one implementation and these fixtures always exercise the
# code that runs in CI. Removing or renaming the markers fails this
# script rather than silently testing nothing.
#
# Usage: tests/test-locate-rules.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflow="${repo_root}/.github/workflows/linting.yaml"

if [ ! -f "${workflow}" ]; then
  echo "ERROR: workflow not found: ${workflow}" >&2
  exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
extracted="${workdir}/rules.sh"

# Copy the marked regions out of the run: blocks, stripping the YAML
# block indentation measured from each BEGIN marker itself, so the
# extraction survives the workflow being re-nested.
awk '
  /# BEGIN (locate_rules|plan_conflicts|harden_check)/ {
    indent = match($0, /[^ ]/) - 1
    capture = 1
    next
  }
  /# END (locate_rules|plan_conflicts|harden_check)/ { capture = 0; next }
  capture { print substr($0, indent + 1) }
' "${workflow}" > "${extracted}"

# The harden_check region appears once per job, because harden-runner
# installs its agent per job and each must reach its own verdict. Two
# copies is one chance to drift, so prove they are byte-identical:
# a plan job refusing a runner the lint job then accepted is exactly
# the hole this rule exists to close.
harden_copies="$(grep -c '# BEGIN harden_check' "${workflow}")"
if [ "${harden_copies}" -ne 2 ]; then
  echo "ERROR: expected 2 harden_check regions in" >&2
  echo "       ${workflow}, found ${harden_copies}" >&2
  echo "       The plan job and the lint job must each carry one." >&2
  exit 1
fi

awk '
  /# BEGIN harden_check/ {
    indent = match($0, /[^ ]/) - 1
    copy++
    capture = 1
    next
  }
  /# END harden_check/ { capture = 0; next }
  capture { print substr($0, indent + 1) > (dest copy) }
' dest="${workdir}/harden-" "${workflow}"

if ! diff -u "${workdir}/harden-1" "${workdir}/harden-2" \
  > "${workdir}/harden.diff"; then
  echo "ERROR: the two harden_check regions have diverged:" >&2
  cat "${workdir}/harden.diff" >&2
  exit 1
fi

for fn in dangling_component org_status_verdict org_absence_verdict \
  contained_in_workspace explicit_prefix_empty single_line \
  skip_prefilter plan_conflicts harden_runner_verdict \
  harden_runner_gate; do
  if ! grep -q "${fn}()" "${extracted}"; then
    echo "ERROR: no ${fn}() between the markers in" >&2
    echo "       ${workflow}" >&2
    echo "       Restore the '# BEGIN locate_rules' and" >&2
    echo "       '# END locate_rules' comments (or the" >&2
    echo "       plan_conflicts / harden_check pair) around them." >&2
    exit 1
  fi
done

# shellcheck source=/dev/null
. "${extracted}"

passed=0
failed=0

report() {
  local ok="$1" desc="$2" expect="$3" got="$4"

  if [ "${ok}" = 'yes' ]; then
    passed=$((passed + 1))
    return 0
  fi

  failed=$((failed + 1))
  printf 'FAIL: %s (expected %s, got %s)\n' "${desc}" "${expect}" \
    "${got}" >&2
}

# --- org_status_verdict ----------------------------------------------

check_status() {
  local desc="$1" code="$2" expect="$3" got

  got="$(org_status_verdict "${code}")"
  if [ "${got}" = "${expect}" ]; then
    report yes "${desc}" "${expect}" "${got}"
  else
    report no "${desc}" "${expect}" "${got}"
  fi
}

check_status 'HTTP 200 is present' '200' 'present'

# The ONLY status that may mean 'absent'.
check_status 'HTTP 404 is absent' '404' 'absent'

# Everything below would, if read as 'absent', pass a mandated check
# without linting anything.
check_status 'HTTP 401 is an error' '401' 'error'
check_status 'HTTP 403 is an error' '403' 'error'
check_status 'HTTP 429 (rate limited) is an error' '429' 'error'
check_status 'HTTP 500 is an error' '500' 'error'
check_status 'HTTP 502 is an error' '502' 'error'
check_status 'curl failure (000) is an error' '000' 'error'
check_status 'an empty status is an error' '' 'error'
check_status 'a garbage status is an error' 'nonsense' 'error'

# --- org_absence_verdict ---------------------------------------------
#
# 'absent' above is provisional. GitHub answers 404 for anything the
# token cannot see rather than 403, so a PRIVATE '.github' repository
# returns 404 for a file that is sitting right there. Believing the
# file absent would report 'nothing to lint' for an organisation
# whose fallback exists and merely could not be read.
#
# The repository lookup settles it: readable means the absence is a
# fact, anything else means this token cannot tell.

check_absence() {
  local desc="$1" code="$2" expect="$3" got

  got="$(org_absence_verdict "${code}")"
  if [ "${got}" = "${expect}" ]; then
    report yes "${desc}" "${expect}" "${got}"
  else
    report no "${desc}" "${expect}" "${got}"
  fi
}

# The one case that confirms the file is genuinely missing.
check_absence 'readable repository confirms absence' '200' 'absent'

# The case this function exists for: a private '.github' is
# indistinguishable from none, so the run must ask rather than guess.
check_absence 'unreadable repository (404) is an error' '404' 'error'

check_absence 'repository 403 is an error' '403' 'error'
check_absence 'repository 401 is an error' '401' 'error'
check_absence 'repository 429 is an error' '429' 'error'
check_absence 'repository 500 is an error' '500' 'error'
check_absence 'repository curl failure (000) is an error' '000' 'error'
check_absence 'an empty repository status is an error' '' 'error'
check_absence 'a garbage repository status is an error' 'x' 'error'

# --- dangling_component ----------------------------------------------

check_dangling() {
  local desc="$1" path="$2" expect="$3" got

  got="$(cd "${workdir}/tree" && dangling_component "${path}")"
  if [ "${got}" = "${expect}" ]; then
    report yes "${desc}" "${expect:-<none>}" "${got:-<none>}"
  else
    report no "${desc}" "${expect:-<none>}" "${got:-<none>}"
  fi
}

rm -rf "${workdir}/tree"
mkdir -p "${workdir}/tree/real/nested"
: > "${workdir}/tree/real/nested/.pre-commit-config.yaml"
: > "${workdir}/tree/.pre-commit-config.yaml"
(
  cd "${workdir}/tree"
  # A configuration symlinked to a path the sparse checkout skipped.
  ln -s config/pre-commit.yaml dangling-file.yaml
  # A DIRECTORY component left hanging: the candidate is then merely
  # absent, never '-L', which is what the first version of this check
  # missed entirely.
  ln -s ../elsewhere dangling-dir
  # A symlink that resolves is not this rule's problem; containment
  # handles where it points.
  ln -s real/nested/.pre-commit-config.yaml resolving.yaml
)

check_dangling 'a real file is clean' \
  '.pre-commit-config.yaml' ''

check_dangling 'a resolving symlink is clean' \
  'resolving.yaml' ''

check_dangling 'an absent file is clean (genuinely no config)' \
  'nothing/here/.pre-commit-config.yaml' ''

check_dangling 'a dangling configuration symlink is caught' \
  'dangling-file.yaml' 'dangling-file.yaml'

check_dangling 'a dangling DIRECTORY component is caught' \
  'dangling-dir/.pre-commit-config.yaml' 'dangling-dir'

check_dangling 'the offending component is named, not the full path' \
  'dangling-dir/deeper/.pre-commit-config.yaml' 'dangling-dir'

# --- contained_in_workspace ------------------------------------------

check_contained() {
  local desc="$1" abs="$2" ws="$3" expect="$4" got='outside'

  if contained_in_workspace "${abs}" "${ws}"; then
    got='inside'
  fi

  if [ "${got}" = "${expect}" ]; then
    report yes "${desc}" "${expect}" "${got}"
  else
    report no "${desc}" "${expect}" "${got}"
  fi
}

check_contained 'a descendant is inside' \
  '/ws/sub' '/ws' 'inside'

check_contained 'a deep descendant is inside' \
  '/ws/a/b/c' '/ws' 'inside'

# Equality counts. A prefix symlink targeting '.' resolves to the
# workspace root, and rejecting that failed a valid configuration.
check_contained 'the workspace root itself is inside' \
  '/ws' '/ws' 'inside'

check_contained 'a sibling is outside' \
  '/elsewhere' '/ws' 'outside'

# A prefix match is not a path match: '/wsx' is not under '/ws'.
check_contained 'a same-prefix sibling is outside' \
  '/wsx' '/ws' 'outside'

check_contained 'a parent is outside' \
  '/' '/ws' 'outside'

# --- harden_runner_verdict -------------------------------------------

# harden-runner returns early and stays SILENT on ubuntu-slim, in
# containers, on community-tier ARM64 and on bare self-hosted runners.
# RUNNER_OS reads 'Linux' through all of them, so the platform test
# this replaced reported a hardened job that had no agent at all.

status_present="${workdir}/agent.status"
status_absent="${workdir}/no-such-agent.status"
: > "${status_present}"
rm -f "${status_absent}"

check_verdict() {
  local desc="$1" os="$2" status="$3" custom="$4" envn="$5" \
    expect="$6" got

  got="$(harden_runner_verdict "${os}" "${status}" "${custom}" \
    "${envn}")"
  if [ "${got}" = "${expect}" ]; then
    report yes "${desc}" "${expect}" "${got}"
  else
    report no "${desc}" "${expect}" "${got}"
  fi
}

check_verdict 'an installed agent is monitored' \
  'Linux' "${status_present}" '' 'github-hosted' 'monitored'

# A custom VM image ships the agent already running, so it writes no
# status file into the job and announces itself this way instead.
check_verdict 'a custom hardened image is monitored' \
  'Linux' "${status_absent}" 'true' 'github-hosted' 'monitored'

# ubuntu-slim, containers, ARM64: Linux, hosted, no agent.
check_verdict 'Linux without an agent is unmonitored' \
  'Linux' "${status_absent}" '' 'github-hosted' 'unmonitored'

# Any value but the literal 'true' leaves the flag off.
check_verdict 'a non-true custom flag does not count' \
  'Linux' "${status_absent}" 'false' 'github-hosted' 'unmonitored'

# The stale-file hole. '/home/agent/agent.status' is exactly what
# harden-runner's isAgentInstalled() tests, and its self-hosted
# post-step leaves the file behind -- so on a PERSISTENT runner a
# file from an earlier job would read as 'monitored' while nothing
# runs. It also makes harden-runner skip installing, so the stale
# file causes the gap and hides it at once.
check_verdict 'a self-hosted runner cannot prove liveness' \
  'Linux' "${status_present}" '' 'self-hosted' 'unmonitored'

# harden-runner honours the custom-image variable only when
# isGithubHosted(), so trusting it elsewhere would trust a flag the
# action itself ignores.
check_verdict 'a custom-image flag off a hosted runner is ignored' \
  'Linux' "${status_absent}" 'true' 'self-hosted' 'unmonitored'

# An older runner may not set RUNNER_ENVIRONMENT at all. Absence
# must fail closed rather than read as hosted.
check_verdict 'an unset runner environment is unmonitored' \
  'Linux' "${status_present}" '' '' 'unmonitored'

check_verdict 'macOS is not Linux' \
  'macOS' "${status_present}" '' 'github-hosted' 'not-linux'
check_verdict 'Windows is not Linux' \
  'Windows' "${status_present}" '' 'github-hosted' 'not-linux'

# --- harden_runner_gate ----------------------------------------------

# The message text names RUNNER_OS, so the extracted function needs
# one; the value never reaches a decision.
RUNNER_OS='Linux'
export RUNNER_OS

check_gate() {
  local desc="$1" verdict="$2" policy="$3" expect="$4" got='pass'

  if ! harden_runner_gate "${verdict}" "${policy}" > /dev/null 2>&1
  then
    got='fail'
  fi

  if [ "${got}" = "${expect}" ]; then
    report yes "${desc}" "${expect}" "${got}"
  else
    report no "${desc}" "${expect}" "${got}"
  fi
}

check_gate 'a monitored runner passes under block' \
  'monitored' 'block' 'pass'
check_gate 'a monitored runner passes under audit' \
  'monitored' 'audit' 'pass'

# The headline rule. Under 'block' the caller asked for egress
# enforcement and is not getting it, so a green check would mean
# 'ran the repository's own hooks with the network wide open'.
check_gate 'an unmonitored runner fails under block' \
  'unmonitored' 'block' 'fail'

# Under 'audit' nothing was ever enforced -- audit records traffic
# and blocks none of it -- so the loss is telemetry. Failing here
# would block every pull request across the estate whenever the
# vendor had a bad afternoon.
check_gate 'an unmonitored runner warns under audit' \
  'unmonitored' 'audit' 'pass'

# A caller mistake, and deterministic, so the policy does not soften
# it: this workflow's own steps assume Linux regardless.
check_gate 'a non-Linux runner fails under block' \
  'not-linux' 'block' 'fail'
check_gate 'a non-Linux runner fails under audit' \
  'not-linux' 'audit' 'fail'

# --- explicit_prefix_empty -------------------------------------------

# The rule that replaced the prefix classification. A caller who names
# a directory has asserted a configuration is in it, so an absence is
# a caller error whatever the cause -- and the empty default prefix
# must stay exempt, or every repository without a configuration would
# fail the estate-wide check instead of skipping.

check_prefix_empty() {
  local desc="$1" prefix="$2" primary="$3" expect="$4" got='no'

  if explicit_prefix_empty "${prefix}" "${primary}"; then
    got='yes'
  fi

  if [ "${got}" = "${expect}" ]; then
    report yes "${desc}" "${expect}" "${got}"
  else
    report no "${desc}" "${expect}" "${got}"
  fi
}

# The case the whole rule exists for, and the one the classification
# it replaced let through: a named prefix that produced nothing.
check_prefix_empty 'a named prefix with no configuration is an error' \
  'subdir' '' 'yes'
check_prefix_empty 'a nested named prefix counts too' \
  'a/b/c' '' 'yes'

# A named prefix that found its configuration is fine, whatever route
# the checkout took to materialise it.
check_prefix_empty 'a named prefix that found one is fine' \
  'subdir' 'subdir/.pre-commit-config.yaml' 'no'

# The estate-wide default. An empty prefix with no configuration is
# the ORDINARY answer for a repository with nothing to lint, and must
# stay green: firing here would fail every such repository on a
# mandated check.
check_prefix_empty 'an empty prefix with no configuration is exempt' \
  '' '' 'no'
check_prefix_empty 'an empty prefix that found one is fine' \
  '' '.pre-commit-config.yaml' 'no'

# --- skip_prefilter --------------------------------------------------

# The fast-abort decision, extracted from the workflow rather than
# reimplemented. An earlier suite copied the grep into itself, so the
# 'must_parse' half of the shipped rule went uncovered: removing it
# would have left every assertion green while an escaped key produced
# a silent no-op again.

check_prefilter() {
  local desc="$1" expect="$2" content="$3"
  local fixture="${workdir}/prefilter.yaml" got

  printf '%s\n' "${content}" > "${fixture}"
  got="$(skip_prefilter "${fixture}")"

  if [ "${got}" = "${expect}" ]; then
    report yes "${desc}" "${expect}" "${got}"
  else
    report no "${desc}" "${expect}" "${got}"
  fi
}

# Every YAML spelling of the key must be seen, or those hooks never
# run and nothing says so. A key-shaped regex passes the first two
# and fails the rest.
check_prefilter 'block mapping' 'parse' 'ci:
  skip: [gha-workflow-linter]'
check_prefilter 'space before colon' 'parse' 'ci:
  skip : [gha-workflow-linter]'
check_prefilter 'flow mapping' 'parse' \
  'ci: {"skip": [gha-workflow-linter]}'
check_prefilter 'double-quoted key' 'parse' 'ci:
  "skip": [gha-workflow-linter]'
check_prefilter 'block sequence value' 'parse' 'ci:
  skip:
    - gha-workflow-linter'

# The escape that defeated the substring test. PyYAML decodes
# "\x73kip" as 'skip', and on a fork pull request this file is
# attacker-controlled, so aborting here passed a mandated check
# having linted nothing.
check_prefilter 'a key hidden behind a YAML escape' 'parse' 'ci:
  "\x73kip": [gha-workflow-linter]'

# Any backslash forces a parse, so no escape can hide.
check_prefilter 'an unrelated backslash still parses' 'parse' 'repos:
  - repo: local
    hooks:
      - id: example
        files: "\.py$"'

# Bytes that are not printable ASCII: the letters need not appear at
# all in a UTF-16 file, so absence is unprovable.
printf 'repos: []\n\303\251\n' > "${workdir}/nonascii.yaml"
nonascii_got="$(skip_prefilter "${workdir}/nonascii.yaml")"
if [ "${nonascii_got}" = 'parse' ]; then
  report yes 'non-ASCII bytes force a parse' 'parse' "${nonascii_got}"
else
  report no 'non-ASCII bytes force a parse' 'parse' "${nonascii_got}"
fi

# The abort case, which is what makes the rest meaningful: a rule
# that always parsed would satisfy every fixture above.
check_prefilter 'plain ASCII with no mention aborts' 'abort' 'repos:
  - repo: local
    hooks:
      - id: example'

# 'Could not read' is not 'no match'. Folding the two reported
# "nothing to lint" for a file the job failed to open. stderr is
# redirected here alone: in the workflow grep's own message belongs
# in the log beside the error.
unreadable_got="$(skip_prefilter \
  "${workdir}/no-such-file.yaml" 2>/dev/null)"
if [ "${unreadable_got}" = 'unreadable' ]; then
  report yes 'an unreadable file is not an abort' 'unreadable' \
    "${unreadable_got}"
else
  report no 'an unreadable file is not an abort' 'unreadable' \
    "${unreadable_got}"
fi

# --- single_line -----------------------------------------------------

# primary_error reaches the resolver as a single-line GITHUB_OUTPUT
# record, and one of its inputs is 'readlink' output -- the contents
# of a committed symlink, which a fork pull request controls. A
# newline there would append records of the attacker's choosing.

check_single_line() {
  local desc="$1" raw="$2" expect="$3" got

  got="$(single_line "${raw}")"
  if [ "${got}" = "${expect}" ]; then
    report yes "${desc}" "${expect}" "${got}"
  else
    report no "${desc}" "${expect}" "${got}"
  fi
}

check_single_line 'ordinary text passes through' \
  'config.yaml is a symlink' 'config.yaml is a symlink'

# The injection: these records would skip the resolver and finish the
# run green without linting.
check_single_line 'an injected output record is flattened' \
  "$(printf 'x\nproceed=false\nhas_work=false\ndummy=')" \
  'xproceed=falsehas_work=falsedummy='

check_single_line 'a carriage return is stripped' \
  "$(printf 'a\rb')" 'ab'

check_single_line 'a tab is stripped' "$(printf 'a\tb')" 'ab'

# --- plan_conflicts --------------------------------------------------

# This rule lives in the guard step, ahead of the Python resolver, so
# test-lint-plan.sh cannot reach it: the advertised behaviour that a
# plan refuses to combine with a scalar selector had no coverage at
# all until this suite existed.
check_conflicts() {
  local desc="$1" expect="$2"
  shift 2
  local got

  got="$(plan_conflicts "$@")"
  if [ "${got}" = "${expect}" ]; then
    report yes "${desc}" "${expect:-<none>}" "${got:-<none>}"
  else
    report no "${desc}" "${expect:-<none>}" "${got:-<none>}"
  fi
}

# No plan: the scalars are the supported mode, so nothing conflicts.
check_conflicts 'scalars alone are legal' '' \
  '' 'mypy' 'cfg.yaml' '' '' 'false'

check_conflicts 'a plan alone is legal' '' \
  '[{"name":"a"}]' '' '' '' '' 'false'

check_conflicts 'plan plus hooks conflicts' ' hooks' \
  '[{"name":"a"}]' 'mypy' '' '' '' 'false'

check_conflicts 'plan plus config_path conflicts' ' config_path' \
  '[{"name":"a"}]' '' 'cfg.yaml' '' '' 'false'

check_conflicts 'plan plus config_url conflicts' ' config_url' \
  '[{"name":"a"}]' '' '' 'https://e.org/c.yaml' '' 'false'

check_conflicts 'plan plus config_sha256 conflicts' ' config_sha256' \
  '[{"name":"a"}]' '' '' '' 'deadbeef' 'false'

check_conflicts 'plan plus ci_skipped conflicts' ' ci_skipped' \
  '[{"name":"a"}]' '' '' '' '' 'true'

# skip_hooks is NOT in this list, and that is the design rather than
# an omission: it excludes ids from whatever runs, so it composes with
# a plan instead of competing with it. Nothing gets discarded, which
# is the only reason the other five conflict.

# ci_skipped defaults to 'false', so only an explicit 'true' counts as
# supplied. Treating the default as a value would make EVERY plan
# conflict with an input its caller never mentioned.
check_conflicts 'a plan with ci_skipped left false is legal' '' \
  '[{"name":"a"}]' '' '' '' '' 'false'

# Every conflict is reported at once, so a caller with three stray
# scalars fixes them in one pass rather than one run at a time.
check_conflicts 'all conflicts are accumulated' \
  ' hooks config_path config_url config_sha256 ci_skipped' \
  '[{"name":"a"}]' 'mypy' 'cfg.yaml' 'https://e.org/c.yaml' 'dead' \
  'true'

# --- Result ----------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
  exit 1
fi
