#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the Dependabot single-commit title exception in
# .github/workflows/semantic-pull-request.yaml.
#
# The rule under test decides whether a Dependabot commit subject is the
# pull request title with the ' from <old> to <new>' version fragment
# removed, along with any directory and group context Dependabot deleted
# with it. Getting it wrong is expensive in both directions: too strict
# and a dependency bump can never merge, too loose and genuine title
# drift slips through a required check.
#
# The function is EXTRACTED from the workflow rather than copied here,
# so there is one implementation and these fixtures always exercise the
# code that actually runs in CI. Removing or renaming the markers in the
# workflow fails this script rather than silently testing nothing.
#
# Usage: tests/test-relax-matches.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflow="${repo_root}/.github/workflows/semantic-pull-request.yaml"

if [ ! -f "${workflow}" ]; then
  echo "ERROR: workflow not found: ${workflow}" >&2
  exit 1
fi

extracted="$(mktemp)"
trap 'rm -f "${extracted}"' EXIT

# Copy the marked region out of the run: block, stripping the YAML block
# indentation measured from the BEGIN marker itself, so the extraction
# survives the workflow being re-nested.
awk '
  /# BEGIN relax_matches/ {
    indent = match($0, /[^ ]/) - 1
    capture = 1
    next
  }
  /# END relax_matches/ { capture = 0; next }
  capture { print substr($0, indent + 1) }
' "${workflow}" > "${extracted}"

if ! grep -q 'relax_matches()' "${extracted}"; then
  echo "ERROR: no relax_matches() between the markers in" >&2
  echo "       ${workflow}" >&2
  echo "       Restore the '# BEGIN relax_matches' and" >&2
  echo "       '# END relax_matches' comments around the function." >&2
  exit 1
fi

# shellcheck source=/dev/null
. "${extracted}"

passed=0
failed=0

check() {
  local expect="$1" title="$2" subject="$3"
  local got='strict'

  if relax_matches "${title}" "${subject}"; then
    got='relax'
  fi

  if [ "${got}" = "${expect}" ]; then
    passed=$((passed + 1))
    return 0
  fi

  failed=$((failed + 1))
  printf 'FAIL: expected %s, got %s\n' "${expect}" "${got}" >&2
  printf '  title:   %s\n' "${title}" >&2
  printf '  subject: %s\n' "${subject}" >&2
}

# The exception applies: the subject is the title with one version
# fragment, and any context Dependabot deleted with it, removed.
relax() { check 'relax' "$1" "$2"; }

# The exception does not apply and the strict exact match stands.
strict() { check 'strict' "$1" "$2"; }

# --- Trailing fragment: the case the original prefix rule handled ----

relax \
  'CI(actions): Bump lfit/releng-reusable-workflows/.github/workflows/reuse-openssf-scorecard.yaml from 0.9.1 to 0.10.1' \
  'CI(actions): Bump lfit/releng-reusable-workflows/.github/workflows/reuse-openssf-scorecard.yaml'

# --- Mid-string fragment: the case the prefix rule missed ------------

# Dependabot before dependabot-core d0bf3df deleted the versions alone
# and kept the group suffix.
relax \
  'Chore: Bump cryptography from 49.0.0 to 50.0.0 in the uv group across 1 directory' \
  'Chore: Bump cryptography in the uv group across 1 directory'

relax \
  'CI(deps): Bump github-security-report from 0.8.0 to 0.10.0 in /.github/runtime-pin' \
  'CI(deps): Bump github-security-report in /.github/runtime-pin'

relax \
  'Chore: Bump urllib3 from 2.0.7 to 2.5.0 in /requirements' \
  'Chore: Bump urllib3 in /requirements'

relax \
  'Chore: Bump opentelemetry-instrumentation-requests from 0.48b0 to 0.49b0 in /services/api' \
  'Chore: Bump opentelemetry-instrumentation-requests in /services/api'

# --- Context deleted with the fragment -------------------------------

# Since dependabot-core d0bf3df the fragment match runs on to ' in /',
# ' (via audit fix)' or the end of the title, so a group suffix goes
# with the versions. A subject still over 72 characters is then cut at
# its first ' in ', taking a directory too. Every subject below is the
# output of Dependabot's commit_subject for its title.

# Grouped update with directories: the suffix goes with the versions.
relax \
  'Chore: Bump virtualenv from 20.36.1 to 21.7.13 in the uv group across 1 directory' \
  'Chore: Bump virtualenv'

relax \
  'Chore: Bump pyjwt from 2.13.0 to 2.15.0 in the uv group across 1 directory' \
  'Chore: Bump pyjwt'

# Grouped update without directories.
relax \
  'CI(actions): Bump step-security/harden-runner from 2.21.0 to 2.21.1 in the github-actions group' \
  'CI(actions): Bump step-security/harden-runner'

# Directory and group: the fragment match stops at ' in /', and the
# 72-character cut then removes the rest.
relax \
  'Chore: Bump typing-extensions from 4.12.2 to 4.15.0 in /requirements/dev in the uv group across 1 directory' \
  'Chore: Bump typing-extensions'

# Directory alone, cut at ' in ' because it still ran long.
relax \
  'Chore: Bump opentelemetry-instrumentation-requests from 0.48b0 to 0.49b0 in /services/api-gateway' \
  'Chore: Bump opentelemetry-instrumentation-requests'

# Dependabot writes the directory verbatim, spaces included.
relax \
  'Chore: Bump opentelemetry-instrumentation-requests from 0.48b0 to 0.49b0 in /services/api gateway' \
  'Chore: Bump opentelemetry-instrumentation-requests'

relax \
  'Chore: Bump virtualenv from 20.36.1 to 21.7.13 in /services/api gateway in the uv group across 1 directory' \
  'Chore: Bump virtualenv'

# --- Requirements of several tokens -----------------------------------

# A library update names requirements, which can contain spaces, and
# Dependabot drops the whole of both. The first is dependabot-core's
# own fixture for the change.
relax \
  'Update JSON requirement from ^0.20, ^0.21 to ^0.20, ^0.21, 1.5 in /BasicPackage.jl' \
  'Update JSON requirement in /BasicPackage.jl'

relax \
  'Chore: Update requests requirement from >= 2.31, < 3 to >= 2.32, < 4 in the pip group' \
  'Chore: Update requests requirement'

relax \
  'Chore: Update plug requirement from ~> 1.14 or ~> 1.15 to ~> 1.15 or ~> 1.16' \
  'Chore: Update plug requirement'

relax \
  'Chore: Update semver requirement from ^6.3.1 || ^7.5.4 to ^7.6.3 in /packages/cli' \
  'Chore: Update semver requirement in /packages/cli'

# Elm writes a range around a bare 'v'.
relax \
  'Chore: Update elm/http requirement from 1.0.0 <= v < 2.0.0 to 1.0.0 <= v < 3.0.0 in /frontend' \
  'Chore: Update elm/http requirement in /frontend'

# Composer aliases a branch with 'as'.
relax \
  'Chore: Update acme/widgets requirement from dev-main as 1.0.x-dev to dev-main as 1.1.x-dev in /app' \
  'Chore: Update acme/widgets requirement in /app'

# Julia accepts Unicode comparison operators.
relax \
  'Chore: Update StatsBase requirement from ≥ 0.33, ≤ 0.34 to ≥ 0.34, ≤ 0.35 in /docs' \
  'Chore: Update StatsBase requirement in /docs'

# --- Audit fix marker ------------------------------------------------

# The fragment match stops at the marker, so the deletion is one span.
relax \
  'Chore: Bump @babel/traverse from 7.22.5 to 7.23.2 (via audit fix) in /web' \
  'Chore: Bump @babel/traverse (via audit fix) in /web'

# The 72-character cut then removes the context after the marker too,
# leaving a deletion either side of it.
relax \
  'Chore: Bump opentelemetry-instrumentation-requests from 0.48b0 to 0.49b0 (via audit fix) in the uv group' \
  'Chore: Bump opentelemetry-instrumentation-requests (via audit fix)'

relax \
  'Chore: Bump @typescript-eslint/eslint-plugin from 8.1.0 to 8.2.0 (via audit fix) in /web in the npm group across 1 directory' \
  'Chore: Bump @typescript-eslint/eslint-plugin (via audit fix)'

# --- Title drift: nothing was deleted, so nothing is forgiven --------

# The title moved to a newer version while the commit subject kept the
# old one. Exactly the drift the check exists to catch.
strict \
  'Chore: Bump dependamerge from 0.9.2 to 0.10.0' \
  'Chore: Bump dependamerge from 0.9.2 to 0.9.3'

strict \
  'Feat: Add support for X' \
  'Chore: Add support for X'

strict \
  'Chore: Bump requests from 1.0 to 2.0' \
  'Chore: Bump urllib3 from 1.0 to 2.0'

# Version drift is still caught when the title carries group context.
strict \
  'Chore: Bump foo from 1 to 3 in the uv group across 1 directory' \
  'Chore: Bump foo from 1 to 2'

# --- Shape guards ----------------------------------------------------

# Subject longer than the title: nothing was removed from the title.
strict \
  'Chore: Bump foo' \
  'Chore: Bump foo from 1 to 2'

# Identical strings. The caller settles equality before consulting the
# rule, but the rule must not claim a deletion that did not happen.
strict \
  'Chore: Bump foo from 1 to 2' \
  'Chore: Bump foo from 1 to 2'

# Empty subject.
strict \
  'Chore: Bump foo from 1 to 2' \
  ''

# The removed span is not a version fragment.
strict \
  'Chore: Bump foo in the middle here' \
  'Chore: Bump foo here'

# The span reads as a fragment but is fused to the text on both
# sides, so a rename could otherwise pose as truncation.
strict \
  'Chore: Bump xfrom 1 to 2y' \
  'Chore: Bump xy'

# Fused on the right only: whitespace delimits the fragment on the
# left, but it runs straight into the text that follows.
strict \
  'Chore: Bump x from 1 to 2y' \
  'Chore: Bump xy'

# Fused on the left only: the mirror of the case above.
strict \
  'Chore: Bump xfrom 1 to 2 y' \
  'Chore: Bump x y'

# Two separate spans differ, which is drift rather than truncation.
strict \
  'Chore: Bump a from 1 to 2 in /x and b from 3 to 4' \
  'Chore: Bump a in /x and b'

# A fragment with extra tokens is not the Dependabot shape.
strict \
  'Chore: Bump foo from 1 to 2 to 3 in /x' \
  'Chore: Bump foo in /x'

# Truncation of something other than a version fragment.
strict \
  'Chore: Bump foo from the old release in /x' \
  'Chore: Bump foo in /x'

# --- Context guards: only Dependabot's own suffixes ride along -------

# Group context removed without a version fragment before it.
strict \
  'Chore: Bump foo in the uv group across 1 directory' \
  'Chore: Bump foo'

# 'in the ...' that is not a group suffix.
strict \
  'Chore: Bump foo from 1 to 2 in the middle' \
  'Chore: Bump foo'

# Text after the group suffix.
strict \
  'Chore: Bump foo from 1 to 2 in the uv group across 1 directory and more' \
  'Chore: Bump foo'

# Text after the group suffix, with a directory before it.
strict \
  'Chore: Bump foo from 1 to 2 in /x in the uv group and more' \
  'Chore: Bump foo'

# Directory and group in the reverse of Dependabot's order.
strict \
  'Chore: Bump foo from 1 to 2 in the uv group in /x' \
  'Chore: Bump foo'

# A directory count that is not a number.
strict \
  'Chore: Bump foo from 1 to 2 in the uv group across some directories' \
  'Chore: Bump foo'

# A directory without its leading slash.
strict \
  'Chore: Bump foo from 1 to 2 in x' \
  'Chore: Bump foo'

# --- Requirement guards: only requirement tokens extend a value ------

# Prose inside the old value.
strict \
  'Chore: Update foo requirement from 1.0 or newer to 2.0' \
  'Chore: Update foo requirement'

# Prose after the new value.
strict \
  'Chore: Update foo requirement from >= 1.0 to >= 2.0 or later' \
  'Chore: Update foo requirement'

# Composer's 'as' does not admit prose after it.
strict \
  'Chore: Update foo requirement from 1.0 as needed to 2.0' \
  'Chore: Update foo requirement'

# --- Audit fix guards ------------------------------------------------

# Marker in the title alone: Dependabot never drops it.
strict \
  'Chore: Bump foo from 1 to 2 (via audit fix)' \
  'Chore: Bump foo'

# Marker in the subject alone.
strict \
  'Chore: Bump foo from 1.0.0 to 2.0.0 in /x' \
  'Chore: Bump foo (via audit fix)'

# A different package either side of the marker is drift.
strict \
  'Chore: Bump foo from 1 to 2 (via audit fix) in /x' \
  'Chore: Bump bar (via audit fix)'

# Marker moved ahead of the version fragment.
strict \
  'Chore: Bump foo (via audit fix) from 1 to 2' \
  'Chore: Bump foo (via audit fix)'

# Marker moved, with text either side of it differing.
strict \
  'Chore: Bump foo (via audit fix) from 1 to 2 in /x' \
  'Chore: Bump foo in /x (via audit fix)'

# Part of the text after the marker kept: the cut takes all of it.
strict \
  'Chore: Bump foo from 1 to 2 (via audit fix) in /x in the uv group' \
  'Chore: Bump foo (via audit fix) in /x'

# --- Result ----------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
  exit 1
fi
