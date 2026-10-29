#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the breaking-change marker rules in
# .github/workflows/semantic-pull-request.yaml.
#
# The rules decide whether a commit message, or a pull request title,
# declares a breaking change. A false negative lets a breaking commit
# ship as a minor release; a false positive fails a pull request that
# breaks nothing.
#
# The functions are EXTRACTED from the workflow rather than copied
# here, so these fixtures exercise the code that runs in CI. Removing
# or renaming the markers in the workflow fails this script rather
# than silently testing nothing.
#
# Usage: bash tests/test-breaking-marker.sh

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

# Copy the marked region out of the run: block, stripping the YAML
# block indentation measured from the BEGIN marker itself.
awk '
  /# BEGIN breaking_marker/ {
    indent = match($0, /[^ ]/) - 1
    capture = 1
    next
  }
  /# END breaking_marker/ { capture = 0; next }
  capture { print substr($0, indent + 1) }
' "${workflow}" > "${extracted}"

if ! grep -q 'breaking_marker()' "${extracted}" \
  || ! grep -q 'breaking_header()' "${extracted}" \
  || ! grep -q 'ignored_label()' "${extracted}"; then
  echo "ERROR: breaking_header(), breaking_marker() and" >&2
  echo "       ignored_label() not all found between the markers" >&2
  echo "       in ${workflow}" >&2
  echo "       Restore the '# BEGIN breaking_marker' and" >&2
  echo "       '# END breaking_marker' comments around them." >&2
  exit 1
fi

# shellcheck source=/dev/null
. "${extracted}"

passed=0
failed=0

# Expect breaking_marker to print EXPECT ('header', 'footer' or
# 'none' for a non-zero return) for MESSAGE.
check() {
  local expect="$1" message="$2" got

  if ! got="$(breaking_marker "${message}")"; then
    got='none'
  fi

  if [ "${got}" = "${expect}" ]; then
    passed=$((passed + 1))
    return 0
  fi

  failed=$((failed + 1))
  printf 'FAIL: expected %s, got %s\n' "${expect}" "${got}" >&2
  printf '  message: %s\n' "${message}" >&2
}

# Expect breaking_header to accept ('yes') or reject ('no') TITLE.
title() {
  local expect="$1" text="$2" got='no'

  if breaking_header "${text}"; then
    got='yes'
  fi

  if [ "${got}" = "${expect}" ]; then
    passed=$((passed + 1))
    return 0
  fi

  failed=$((failed + 1))
  printf 'FAIL: title expected %s, got %s\n' "${expect}" "${got}" >&2
  printf '  title: %s\n' "${text}" >&2
}

# Expect ignored_label to match ('yes') or not ('no') any of LABELS
# against the ignore_labels LIST.
ignored() {
  local expect="$1" list="$2" got='no'
  shift 2

  if ignored_label "${list}" "$@"; then
    got='yes'
  fi

  if [ "${got}" = "${expect}" ]; then
    passed=$((passed + 1))
    return 0
  fi

  failed=$((failed + 1))
  printf 'FAIL: ignored expected %s, got %s\n' "${expect}" "${got}" >&2
  printf '  list: %s  labels: %s\n' "${list}" "$*" >&2
}

nl=$'\n'
cr=$'\r'

# --- Header marker ---------------------------------------------------

check header 'Feat!: Drop Python 3.9 support'
check header 'Feat(api)!: Remove the v1 endpoints'
check header 'feat(api)!: Remove the v1 endpoints'
check header 'Refactor(core/io)!: Rename the reader'
check header "Feat!: Drop support${nl}${nl}Body text."

# '!' elsewhere in the header is not a marker.
check none 'Fix: Handle ! in code'
check none 'Fix(parser): Accept a trailing !'
check none 'Fix!bad: Not a marker'
check none 'Feat(x) !: Space before the bang'
check none 'Revert "Feat!: Drop Python 3.9 support"'

# A header marker in the body is not a header.
check none "Fix: Tidy up${nl}${nl}Feat!: Quoted in the body"

# --- Footer marker ---------------------------------------------------

check footer "Feat: Add a flag${nl}${nl}BREAKING CHANGE: The old flag is gone."
check footer "Feat: Add a flag${nl}${nl}BREAKING-CHANGE: The old flag is gone."
check footer "Feat: Add a flag${nl}${nl}Body.${nl}${nl}BREAKING CHANGE: Gone.${nl}Signed-off-by: A <a@example.org>"
check footer "Feat: Add a flag${cr}${nl}${cr}${nl}BREAKING CHANGE: CRLF.${cr}"
check footer "Feat: Add a flag${nl}BREAKING CHANGE:${nl}"

# The footer token is upper case, at the start of a line, with a
# colon, in the body rather than the header.
check none "Feat: Add a flag${nl}${nl}breaking change: lower case"
check none "Feat: Add a flag${nl}${nl}Breaking Change: mixed case"
check none "Feat: Add a flag${nl}${nl}  BREAKING CHANGE: indented"
check none "Feat: Add a flag${nl}${nl}See BREAKING CHANGE: mid-line"
check none "Feat: Add a flag${nl}${nl}BREAKING CHANGES: plural"
check none "Feat: Add a flag${nl}${nl}BREAKING CHANGE without a colon"
check none "Feat: Add a flag${nl}${nl}BREAKINGCHANGE: no separator"
check none 'BREAKING CHANGE: In the header'

# --- Neither ---------------------------------------------------------

check none 'Fix: Correct the race condition'
check none "Docs: Explain the flag${nl}${nl}No breaking change here."
check none ''

# --- Pull request titles ---------------------------------------------

title yes 'Feat!: Drop Python 3.9 support'
title yes 'Feat(api)!: Remove the v1 endpoints'
title yes 'chore(deps)!: Bump a major version'
title no 'Feat(api): Remove the v1 endpoints'
title no 'Fix: Handle ! in code'
title no 'Feat: Wow!: Still not a marker'

# --- Ignored labels --------------------------------------------------

# Like the title action, the list splits on newlines alone and each
# entry is trimmed, so a label may hold spaces or commas.
ignored yes 'skip breaking' 'skip breaking'
ignored no 'skip breaking' 'breaking'
ignored no 'skip breaking' 'skip'
ignored yes 'a, b' 'a, b'
ignored no 'a, b' 'a'
ignored yes "  spaced  ${nl}other" 'spaced'
ignored yes "first${nl}${nl}second${nl}" 'second'
ignored yes "dependencies${cr}${nl}wip" 'dependencies'
ignored yes "wip" 'bug' 'wip'
ignored no '' 'wip'
ignored no "${nl}  ${nl}" ''
ignored no 'wip'

# --- Result ----------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
  exit 1
fi
