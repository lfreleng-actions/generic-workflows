#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the interpreter the lint plan resolver runs under, in
# .github/workflows/linting.yaml.
#
# In plan mode the job checks out the whole pull request. 'uv run'
# then picks the interpreter of a '.venv/' in the current directory
# or any parent, whatever '--no-project' and '--no-config' say, and
# 'python -I' applies only once uv has picked one. A committed
# interpreter therefore ran before the resolver and could write
# has_work=false, turning the lint check green with nothing linted.
# setup-uv did the same through 'uv python find --directory'.
#
# This runs the 'Resolve lint plan' step's own shell, EXTRACTED from
# the workflow, inside a checkout holding a planted '.venv/',
# '.python-version' and 'uv.toml' whose interpreters append to a
# marker file and exit 1. It must produce a real plan and leave no
# marker. A control runs the same step without '--python', which is
# the previous command, and must leave the marker: without it the
# case could pass because the plant never worked.
#
# Needs uv on PATH and the network (or a uv cache) for PyYAML, so
# pre-commit.ci skips it.
#
# Usage: bash tests/test-lint-plan-interpreter.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflow="${repo_root}/.github/workflows/linting.yaml"

if [ ! -f "${workflow}" ]; then
  echo "ERROR: workflow not found: ${workflow}" >&2
  exit 1
fi

# A FAILURE, never a skip: what this exercises is uv's own choice of
# interpreter, which no other tool can stand in for.
if ! command -v uv > /dev/null 2>&1; then
  echo 'ERROR: uv not found; install it (https://docs.astral.sh/uv/)' >&2
  exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

passed=0
failed=0

pass() { passed=$((passed + 1)); }
fail() {
  failed=$((failed + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

# Print the body of a step's 'run: |' block, dedented, or the whole
# step when $2 is 'step'. Ends at the first non-blank line indented
# less than the block (the next key or step).
extract() {
  local name="$1" what="${2:-run}"
  awk -v name="- name: '${name}'" -v what="${what}" '
    function indent_of(s) { return match(s, /[^ ]/) - 1 }
    !in_step {
      line = $0
      sub(/^ +/, "", line)
      if (line == name) {
        in_step = 1
        step_indent = indent_of($0)
        if (what == "step") print
      }
      next
    }
    what == "step" {
      if ($0 != "" && indent_of($0) <= step_indent) exit
      print
      next
    }
    !body {
      if ($0 ~ /^ *run: \|$/) { body = 1; body_indent = -1 }
      next
    }
    {
      if ($0 == "") { print ""; next }
      if (body_indent < 0) body_indent = indent_of($0)
      if (indent_of($0) < body_indent) exit
      print substr($0, body_indent + 1)
    }
  ' "${workflow}"
}

# --- Wiring ----------------------------------------------------------

setup_step="$(extract 'Set up uv' step)"
if [ -z "${setup_step}" ]; then
  fail "no 'Set up uv' step in ${workflow}"
else
  # setup-uv executes the interpreter 'uv python find --directory
  # <working-directory>' returns, and reads 'cache-dir' from a
  # 'uv.toml' there, so it must not run in the checkout.
  # shellcheck disable=SC2016
  for pin in \
    'working-directory: ${{ runner.temp }}' \
    "cache-dependency-glob: ''" \
    "UV_NO_CONFIG: '1'" \
    "UV_SYSTEM_PYTHON: '1'" \
    "UV_NO_PROJECT: '1'"; do
    if awk '{ sub(/^ +/, ""); print }' <<< "${setup_step}" |
      grep -qxF -- "${pin}"; then
      pass
    else
      fail "the 'Set up uv' step no longer sets '${pin}'"
    fi
  done
fi

block="${workdir}/resolve.sh"
extract 'Resolve lint plan' > "${block}"
if ! grep -q 'def add_hook_tasks' "${block}"; then
  echo "ERROR: no 'Resolve lint plan' run block in ${workflow}" >&2
  exit 1
fi

# Anchored to the command lines: the comments explaining them quote
# the same flags, and must not keep these checks green on their own.
# shellcheck disable=SC2016
for pin in \
  '^py="\$\(cd "\$RUNNER_TEMP" &&$' \
  '^  UV_NO_CONFIG=1 uv python find --system --no-project\)" \|\|$' \
  '^uv run --no-project --no-config --with pyyaml==6\.0\.2 \\$' \
  '^  --python "\$py" \\$' \
  "^  python -I - <<'PYEOF'\$"; do
  if grep -qE -- "${pin}" "${block}"; then
    pass
  else
    fail "the resolver command line no longer matches ${pin}"
  fi
done

# The control drops '--python "$py"', which restores the previous
# command. Checked, so a reworded line cannot make the control run
# the fixed command and pass vacuously.
control="${workdir}/resolve-control.sh"
# shellcheck disable=SC2016
grep -vE '^  --python "\$py" \\$' "${block}" > "${control}"
if [ "$(wc -l < "${control}")" -ne "$(($(wc -l < "${block}") - 1))" ]
then
  fail 'could not derive the control command from the step'
fi

# --- Planted interpreters --------------------------------------------

checkout="${workdir}/checkout"
runner_temp="${workdir}/runner-temp"
marker="${workdir}/marker"
mkdir -p "${checkout}/.venv/bin" "${runner_temp}"
cp "${repo_root}/.pre-commit-config.yaml" "${checkout}/"

# Executable at run time only: nothing committed needs the mode.
planted() {
  cat > "$1" <<EOF
#!/bin/sh
echo "\$0 \$*" >> '${marker}'
exit 1
EOF
  chmod +x "$1"
}
planted "${checkout}/.venv/bin/python"
ln -s python "${checkout}/.venv/bin/python3"
printf 'home = /usr/bin\nversion_info = 3.12.0\n' \
  > "${checkout}/.venv/pyvenv.cfg"
planted "${checkout}/planted-python"
printf '%s\n' "${checkout}/planted-python" \
  > "${checkout}/.python-version"
printf 'cache-dir = "%s"\n' "${checkout}/uv-cache" \
  > "${checkout}/uv.toml"

# Run a step body from the checkout, as the workflow does, with the
# environment the plan step sets.
run_step() {
  : > "${workdir}/out"
  : > "${workdir}/summary"
  rm -f "${marker}"
  (cd "${checkout}" && env \
    GITHUB_WORKSPACE="${checkout}" \
    RUNNER_TEMP="${runner_temp}" \
    GITHUB_OUTPUT="${workdir}/out" \
    GITHUB_STEP_SUMMARY="${workdir}/summary" \
    PRIMARY='.pre-commit-config.yaml' \
    ORG_JSON='' PRIMARY_ERROR='' \
    INPUT_PLAN='' INPUT_HOOKS='' INPUT_SKIP_HOOKS='' \
    INPUT_CONFIG_PATH='' INPUT_CONFIG_URL='' INPUT_CONFIG_SHA256='' \
    INPUT_COMMIT_RANGE='' INPUT_CI_SKIPPED='false' \
    INPUT_SPLIT_HOOKS='true' \
    INPUT_ORG_CONFIG_PATH='linting/.pre-commit-config.yaml' \
    bash "$1") > "${workdir}/stdout" 2>&1
}

if run_step "${block}"; then
  pass
else
  fail 'the resolve step failed beside planted interpreters'
  sed 's/^/  /' "${workdir}/stdout" >&2
fi
if [ -e "${marker}" ]; then
  fail 'the resolve step ran a planted interpreter'
  sed 's/^/  /' "${marker}" >&2
else
  pass
fi
if grep -qx 'has_work=true' "${workdir}/out"; then
  pass
else
  fail 'the resolve step did not plan any work'
  sed 's/^/  /' "${workdir}/out" >&2
fi

# The control: the previous command runs the planted '.venv'.
run_step "${control}" || true
if [ -s "${marker}" ]; then
  pass
else
  fail 'the control did not run a planted interpreter'
  sed 's/^/  /' "${workdir}/stdout" >&2
fi

# --- Result ----------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
  exit 1
fi
