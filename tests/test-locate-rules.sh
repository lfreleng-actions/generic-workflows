#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the shell decision rules in the locate step of
# .github/workflows/linting.yaml.
#
# tests/test-lint-plan.sh covers the Python resolver. These two rules
# sit earlier, in shell, and decide whether the resolver runs at all:
#
#   dangling_component  - is the configuration really absent, or did
#                         the sparse checkout leave a symlink hanging?
#   org_status_verdict  - does this HTTP status mean 'no configuration'
#                         or 'could not find out'?
#
# Both convert an unknown into a verdict, so a wrong answer here ends
# in a green check that linted nothing. Neither was covered before.
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
  /# BEGIN (locate_rules|plan_conflicts)/ {
    indent = match($0, /[^ ]/) - 1
    capture = 1
    next
  }
  /# END (locate_rules|plan_conflicts)/ { capture = 0; next }
  capture { print substr($0, indent + 1) }
' "${workflow}" > "${extracted}"

for fn in dangling_component org_status_verdict prefix_kind \
  contained_in_workspace plan_conflicts; do
  if ! grep -q "${fn}()" "${extracted}"; then
    echo "ERROR: no ${fn}() between the markers in" >&2
    echo "       ${workflow}" >&2
    echo "       Restore the '# BEGIN locate_rules' and" >&2
    echo "       '# END locate_rules' comments (or the" >&2
    echo "       plan_conflicts pair) around them." >&2
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

# --- prefix_kind -----------------------------------------------------

# Needs a real repository, because the rule deliberately asks git
# rather than the filesystem.
repo="${workdir}/repo"
rm -rf "${repo}"
mkdir -p "${repo}"
(
  cd "${repo}"
  git init -q .
  mkdir -p real/nested
  : > real/nested/.pre-commit-config.yaml
  : > plainfile.txt
  ln -s real linkdir
  ln -s . selfdir
  git add -A
  git -c user.email=t@t -c user.name=t commit -qm init
) > /dev/null 2>&1

check_kind() {
  local desc="$1" path="$2" expect="$3" got

  got="$(cd "${repo}" && prefix_kind "${path}")"
  if [ "${got}" = "${expect}" ]; then
    report yes "${desc}" "${expect:-<none>}" "${got:-<none>}"
  else
    report no "${desc}" "${expect:-<none>}" "${got:-<none>}"
  fi
}

check_kind 'a tracked directory is a tree' 'real' 'tree'
check_kind 'a nested tracked directory is a tree' \
  'real/nested' 'tree'

# Git stores a symlink as a BLOB (mode 120000), so 'ls-tree -d'
# reports no tree entry for a directory symlink. Reading the mode is
# what keeps a valid symlinked prefix from being rejected.
check_kind 'a directory symlink is a symlink' 'linkdir' 'symlink'
check_kind 'a self-referential symlink is a symlink' \
  'selfdir' 'symlink'

# A file-valued prefix stays a caller error.
check_kind 'a regular file is a blob' 'plainfile.txt' 'blob'

# Untracked, so 'no configuration' would be the wrong verdict.
check_kind 'an untracked path is absent' 'nosuchdir' ''
check_kind 'an untracked nested path is absent' \
  'real/nope' ''

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
  '' 'mypy' 'cfg.yaml' '' ''

check_conflicts 'a plan alone is legal' '' \
  '[{"name":"a"}]' '' '' '' ''

check_conflicts 'plan plus hooks conflicts' ' hooks' \
  '[{"name":"a"}]' 'mypy' '' '' ''

check_conflicts 'plan plus config_path conflicts' ' config_path' \
  '[{"name":"a"}]' '' 'cfg.yaml' '' ''

check_conflicts 'plan plus config_url conflicts' ' config_url' \
  '[{"name":"a"}]' '' '' 'https://e.org/c.yaml' ''

check_conflicts 'plan plus config_sha256 conflicts' ' config_sha256' \
  '[{"name":"a"}]' '' '' '' 'deadbeef'

# Every conflict is reported at once, so a caller with three stray
# scalars fixes them in one pass rather than one run at a time.
check_conflicts 'all conflicts are accumulated' \
  ' hooks config_path config_url config_sha256' \
  '[{"name":"a"}]' 'mypy' 'cfg.yaml' 'https://e.org/c.yaml' 'dead'

# --- Result ----------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
  exit 1
fi
