#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the 'check-promoted' step in
# .github/workflows/release.yaml.
#
# The step decides whether a release is already published, and so
# whether the job promotes it. Text that gh writes to stderr on
# success (an update notice, a deprecation warning, GH_DEBUG output)
# must not reach jq, and a value other than an explicit true or false
# must fail the step rather than fall through to promotion.
#
# The run: block is EXTRACTED from the workflow rather than copied
# here, so these fixtures exercise the code that runs in CI. It runs
# under 'bash -eo pipefail', as GitHub's 'shell: bash' does, with a
# stub gh on PATH.
#
# Usage: bash tests/test-release-check-promoted.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflow="${repo_root}/.github/workflows/release.yaml"

if [ ! -f "${workflow}" ]; then
  echo "ERROR: workflow not found: ${workflow}" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/test-release-check-promoted.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

extracted="${work}/check-promoted.sh"

# Copy the run: block of the step whose id is check-promoted, quoted
# or not, stripping the block indentation measured from its first line.
awk '
  /^ *id: *["\047]?check-promoted["\047]? *$/ { in_step = 1; next }
  in_step && /^ *- name: / { exit }
  in_step && !in_run && /^ *run: \|$/ {
    run_indent = match($0, /[^ ]/) - 1
    in_run = 1
    next
  }
  in_run {
    if ($0 ~ /^ *$/) { print ""; next }
    indent = match($0, /[^ ]/) - 1
    if (indent <= run_indent) { exit }
    if (!body_indent) { body_indent = indent }
    print substr($0, body_indent + 1)
  }
' "${workflow}" > "${extracted}"

if ! grep -q 'gh release view' "${extracted}" \
  || ! grep -q 'already_promoted=' "${extracted}"; then
  echo "ERROR: could not extract the run: block of the" >&2
  echo "       'check-promoted' step from ${workflow}" >&2
  exit 1
fi

# A stub gh that prints STUB_STDERR to stderr and STUB_STDOUT to
# stdout, then exits with STUB_EXIT.
mkdir -p "${work}/bin"
cat > "${work}/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ -n "${STUB_STDERR:-}" ]; then
  printf '%s\n' "${STUB_STDERR}" >&2
fi
if [ -n "${STUB_STDOUT:-}" ]; then
  printf '%s\n' "${STUB_STDOUT}"
fi
exit "${STUB_EXIT:-0}"
EOF
chmod +x "${work}/bin/gh"

# A PATH holding the stub gh and the tools the step needs, but no jq.
# The links are made here, so the repository carries none.
mkdir -p "${work}/nojq"
ln -s "${work}/bin/gh" "${work}/nojq/gh"
for tool in bash cat mktemp rm; do
  ln -s "$(command -v "${tool}")" "${work}/nojq/${tool}"
done

bash_bin="$(command -v bash)"
# The PATH the step runs with; the no-jq case overrides it.
step_path="${work}/bin:${PATH}"

passed=0
failed=0

warning='A new release of gh is available: 2.0.0 -> 3.0.0'

# Run the step with the stub configured by STDOUT, STDERR and EXIT,
# then expect exit status WANT_RC and, when WANT_OUTPUT is non-empty,
# that line in GITHUB_OUTPUT; otherwise expect GITHUB_OUTPUT to be
# empty. When WANT_LOG is non-empty, expect it in the step's output.
check() {
  local label="$1" stdout="$2" stderr="$3" stub_rc="$4"
  local want_rc="$5" want_output="$6" want_log="${7:-}"
  local output="${work}/output" log="${work}/log" rc=0 ok=1

  : > "${output}"
  env PATH="${step_path}" \
    GITHUB_OUTPUT="${output}" \
    TAG='v1.2.3' \
    STUB_STDOUT="${stdout}" \
    STUB_STDERR="${stderr}" \
    STUB_EXIT="${stub_rc}" \
    "${bash_bin}" --noprofile --norc -eo pipefail "${extracted}" \
    > "${log}" 2>&1 || rc=$?

  if [ "${rc}" -ne "${want_rc}" ]; then
    ok=0
    printf 'FAIL: %s: exit %s, expected %s\n' \
      "${label}" "${rc}" "${want_rc}" >&2
  fi

  if [ -n "${want_output}" ]; then
    if [ "$(cat "${output}")" != "${want_output}" ]; then
      ok=0
      printf 'FAIL: %s: GITHUB_OUTPUT is not %s\n' \
        "${label}" "${want_output}" >&2
    fi
  elif [ -s "${output}" ]; then
    ok=0
    printf 'FAIL: %s: GITHUB_OUTPUT is not empty\n' "${label}" >&2
  fi

  if [ -n "${want_log}" ] && ! grep -qF -- "${want_log}" "${log}"; then
    ok=0
    printf 'FAIL: %s: output lacks: %s\n' "${label}" "${want_log}" >&2
  fi

  if [ "${ok}" -eq 1 ]; then
    passed=$((passed + 1))
    return 0
  fi

  failed=$((failed + 1))
  printf '  GITHUB_OUTPUT:\n' >&2
  sed 's/^/    /' "${output}" >&2
  printf '  step output:\n' >&2
  sed 's/^/    /' "${log}" >&2
}

# --- gh succeeds -----------------------------------------------------

check 'published, warning on stderr' \
  '{"isDraft":false}' "${warning}" 0 0 'already_promoted=true'
check 'draft, warning on stderr' \
  '{"isDraft":true}' "${warning}" 0 0 'already_promoted=false'
check 'published, quiet' \
  '{"isDraft":false}' '' 0 0 'already_promoted=true'
check 'draft, quiet' \
  '{"isDraft":true}' '' 0 0 'already_promoted=false'

# --- gh succeeds with no usable isDraft ------------------------------

check 'empty object' '{}' '' 0 1 '' '::error::'
check 'null isDraft' '{"isDraft":null}' '' 0 1 '' '::error::'
check 'string isDraft' '{"isDraft":"false"}' '' 0 1 '' '::error::'
check 'not JSON' 'not json' '' 0 1 '' \
  '::error::Unable to parse the response for release v1.2.3'
check 'no output' '' '' 0 1 '' '::error::'

# --- jq is missing ---------------------------------------------------

step_path="${work}/nojq"
check 'no jq' '{"isDraft":false}' '' 0 1 '' 'jq: command not found'
step_path="${work}/bin:${PATH}"

# --- gh fails --------------------------------------------------------

check 'gh fails' '' 'HTTP 404: release not found' 1 1 '' \
  '::error::Unable to query release v1.2.3: HTTP 404: release not found'

# --- Result ----------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
  exit 1
fi
