#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the Dependabot single-commit title exception in
# .github/workflows/semantic-pull-request.yaml.
#
# The rule under test decides whether a Dependabot commit subject is the
# pull request title with the ' from <old> to <new>' version fragment
# removed. Getting it wrong is expensive in both directions: too strict
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
# fragment removed.
relax() { check 'relax' "$1" "$2"; }

# The exception does not apply and the strict exact match stands.
strict() { check 'strict' "$1" "$2"; }

# --- Trailing fragment: the case the original prefix rule handled ----

relax \
  'CI(actions): Bump lfit/releng-reusable-workflows/.github/workflows/reuse-openssf-scorecard.yaml from 0.9.1 to 0.10.1' \
  'CI(actions): Bump lfit/releng-reusable-workflows/.github/workflows/reuse-openssf-scorecard.yaml'

# --- Mid-string fragment: the case the prefix rule missed ------------

relax \
  'Chore: Bump cryptography from 49.0.0 to 50.0.0 in the uv group across 1 directory' \
  'Chore: Bump cryptography in the uv group across 1 directory'

relax \
  'CI(deps): Bump github-security-report from 0.8.0 to 0.10.0 in /.github/runtime-pin' \
  'CI(deps): Bump github-security-report in /.github/runtime-pin'

relax \
  'Chore: Bump urllib3 from 2.0.7 to 2.5.0 in /requirements' \
  'Chore: Bump urllib3 in /requirements'

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

# --- Result ----------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
  exit 1
fi
