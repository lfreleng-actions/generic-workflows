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
# setup-uv did the same through 'uv python find --directory'. So do
# variables an earlier step of the job can export through GITHUB_ENV
# and GITHUB_PATH: PATH, UV_PYTHON, UV_PYTHON_SEARCH_PATH,
# VIRTUAL_ENV, CONDA_PREFIX and UV_INTERNAL__PARENT_INTERPRETER.
#
# This runs the 'Install Python' and 'Resolve lint plan' steps' own
# shell, EXTRACTED from the workflow, inside a checkout holding a
# planted '.venv/', '.python-version' and 'uv.toml' whose
# interpreters append to a marker file and exit 1, once with the
# checkout alone and once for each group of planted variables. Each
# must produce a real plan and leave no marker. It also runs
# setup-uv's own lookup, 'uv python find', under the step's
# environment, which uv must refuse before looking. Controls run the
# previous commands (the resolver without '--python', the old
# 'uv python find --system' and setup-uv's lookup without
# UV_PYTHON_PREFERENCE) and must leave the marker: without them a
# case could pass because the plant never worked.
#
# Needs uv on PATH and the network (or a uv cache) for PyYAML and a
# uv-managed Python, so pre-commit.ci skips it.
#
# Usage: bash tests/test-lint-plan-interpreter.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflow="${repo_root}/.github/workflows/linting.yaml"
self_test="${repo_root}/.github/workflows/uv-isolation.yaml"

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
# step when $2 is 'step', from the workflow file $3 (linting.yaml by
# default). Ends at the first non-blank line indented less than the
# block (the next key or step).
extract() {
  local name="$1" what="${2:-run}" file="${3:-${workflow}}"
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
  ' "${file}"
}


# True when the text in $1 holds the line $2, leading spaces aside.
# No 'grep -q': it would close the pipe early, and under pipefail the
# killed awk fails the check on a long step.
has_line() {
  awk '{ sub(/^ +/, ""); print }' <<< "$1" |
    grep -xF -- "$2" > /dev/null
}

# --- Wiring ----------------------------------------------------------

setup_step="$(extract 'Set up uv' step)"
if [ -z "${setup_step}" ]; then
  fail "no 'Set up uv' step in ${workflow}"
else
  # setup-uv executes the interpreter 'uv python find --directory
  # <working-directory>' returns, and reads 'cache-dir' from a
  # 'uv.toml' there, so it must not run in the checkout; the invalid
  # preference makes uv refuse that lookup before it looks.
  # shellcheck disable=SC2016
  for pin in \
    'id: setup-uv' \
    'working-directory: ${{ runner.temp }}' \
    'tool-bin-dir: ${{ runner.temp }}/uv-tool-bin' \
    'enable-cache: false' \
    "UV_NO_CONFIG: '1'" \
    "UV_NO_PROJECT: '1'" \
    "UV_PYTHON_PREFERENCE: 'lookup-disabled'" \
    "UV_PYTHON_ARCH: ''"; do
    if has_line "${setup_step}" "${pin}"; then
      pass
    else
      fail "the 'Set up uv' step no longer sets '${pin}'"
    fi
  done
  # Each of these hands the choice of interpreter back to the job's
  # environment: UV_SYSTEM_PYTHON sends uv to PATH, 'python-version'
  # exports UV_PYTHON to every later step, 'activate-environment'
  # exports VIRTUAL_ENV, and UV_NO_MODIFY_PATH makes setup-uv's own
  # bare 'uv' resolve on PATH.
  for key in UV_SYSTEM_PYTHON UV_NO_MODIFY_PATH python-version \
    activate-environment; do
    if grep -qE "^[[:space:]]*${key}:" <<< "${setup_step}"; then
      fail "the 'Set up uv' step sets '${key}'"
    else
      pass
    fi
  done
fi

install_step="$(extract 'Install Python' step)"
# shellcheck disable=SC2016
for pin in \
  'id: python' \
  'shell: bash' \
  'working-directory: ${{ runner.temp }}' \
  'UV: ${{ steps.setup-uv.outputs.uv-path }}' \
  'INSTALL_DIR: ${{ runner.temp }}/uv-python'; do
  if has_line "${install_step}" "${pin}"; then
    pass
  else
    fail "the 'Install Python' step no longer sets '${pin}'"
  fi
done

install="${workdir}/install.sh"
extract 'Install Python' > "${install}"
# Both uv calls run under 'env -i' and by the path setup-uv reports.
# shellcheck disable=SC2016
for pin in \
  '^env -i "\$\{clean\[@\]\}" "\$UV" python install --quiet --no-bin 3\.13$' \
  '^py=\$\(env -i "\$\{clean\[@\]\}" "\$UV" python find --managed-python 3\.13\)$' \
  '^  "\$INSTALL_DIR"/\*\) ;;$'; do
  if grep -qE -- "${pin}" "${install}"; then
    pass
  else
    fail "the install command line no longer matches ${pin}"
  fi
done

resolve_step="$(extract 'Resolve lint plan' step)"
# shellcheck disable=SC2016
if has_line "${resolve_step}" 'PYTHON: ${{ steps.python.outputs.path }}'
then
  pass
else
  fail "the resolve step no longer takes PYTHON from 'Install Python'"
fi

# uv-isolation.yaml runs copies of both steps under planted job
# variables on a real runner; a copy that drifts tests nothing.
# Compared without the 'if:' line, which only linting.yaml needs.
for step in 'Set up uv' 'Install Python'; do
  ours="$(extract "${step}" step | grep -vE '^[[:space:]]+if: ')"
  theirs="$(extract "${step}" step "${self_test}")"
  if [ -n "${ours}" ] && [ "${ours}" = "${theirs}" ]; then
    pass
  else
    fail "uv-isolation.yaml's '${step}' step differs from linting.yaml's"
    diff <(printf '%s\n' "${ours}") <(printf '%s\n' "${theirs}") |
      sed 's/^/  /' >&2 || true
  fi
done

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
  '^uv run --no-project --no-config --with pyyaml==6\.0\.2 \\$' \
  '^  --python "\$PYTHON" \\$' \
  "^  python -I - <<'PYEOF'\$"; do
  if grep -qE -- "${pin}" "${block}"; then
    pass
  else
    fail "the resolver command line no longer matches ${pin}"
  fi
done
if grep -qE '^[^#]*uv python find' "${block}"; then
  fail 'the resolve step still looks an interpreter up itself'
else
  pass
fi

# The control drops '--python "$PYTHON"', which leaves uv to choose.
# Checked, so a reworded line cannot make the control run the fixed
# command and pass vacuously.
control="${workdir}/resolve-control.sh"
# shellcheck disable=SC2016
grep -vE '^  --python "\$PYTHON" \\$' "${block}" > "${control}"
if [ "$(wc -l < "${control}")" -ne "$(($(wc -l < "${block}") - 1))" ]
then
  fail 'could not derive the control command from the step'
fi

# setup-uv's own lookup, run with the step's environment, and the
# same lookup with the environment the step had before. Both from
# RUNNER_TEMP, its working directory.
lookup="${workdir}/lookup.sh"
cat > "${lookup}" <<'SH'
cd "$RUNNER_TEMP"
uv python find --directory "$RUNNER_TEMP"
SH
# The resolve step's lookup before 'Install Python' replaced it.
old_lookup="${workdir}/old-lookup.sh"
cat > "${old_lookup}" <<'SH'
cd "$RUNNER_TEMP"
UV_NO_CONFIG=1 uv python find --system --no-project
SH

# --- Planted interpreters --------------------------------------------

checkout="${workdir}/checkout"
runner_temp="${workdir}/runner-temp"
install_dir="${runner_temp}/uv-python"
marker="${workdir}/marker"
bait_bin="${checkout}/.venv/bin"
mkdir -p "${bait_bin}" "${checkout}/.venv/conda-meta" "${runner_temp}"
cp "${repo_root}/.pre-commit-config.yaml" "${checkout}/"

# Executable at run time only: nothing committed needs the mode.
planted() {
  cat > "$1" <<SH
#!/bin/sh
echo "\$0 \$*" >> '${marker}'
exit 1
SH
  chmod +x "$1"
}
for name in python python3 python3.13 uv; do
  planted "${bait_bin}/${name}"
done
printf 'home = %s\nversion_info = 3.13.0\n' "${bait_bin}" \
  > "${checkout}/.venv/pyvenv.cfg"
planted "${checkout}/planted-python"
printf '%s\n' "${checkout}/planted-python" \
  > "${checkout}/.python-version"
printf 'cache-dir = "%s"\n' "${checkout}/uv-cache" \
  > "${checkout}/uv.toml"

# setup-uv adds its own directory to PATH after any GITHUB_PATH entry
# an earlier step wrote, so it comes first there, and the bait
# directory follows it.
real_uv="$(command -v uv)"
uv_bin="${workdir}/uv-bin"
mkdir -p "${uv_bin}"
ln -s "${real_uv}" "${uv_bin}/uv"

case "$(uname -m)" in
  arm64) arch='aarch64' ;;
  *) arch="$(uname -m)" ;;
esac

# What an earlier step can export through GITHUB_PATH and GITHUB_ENV,
# in the groups the issue names. 'checkout' plants files only.
leg_env() {
  local common=("PATH=${uv_bin}:${bait_bin}:${PATH}"
    "UV_PYTHON_ARCH=${arch}" 'UV_NO_CACHE=1')
  case "$1" in
    checkout) leg=() ;;
    uv-python)
      leg=("${common[@]}" "UV_PYTHON=${bait_bin}/python3"
        "UV_PYTHON_SEARCH_PATH=${bait_bin}")
      ;;
    venv)
      leg=("${common[@]}" "VIRTUAL_ENV=${checkout}/.venv"
        "CONDA_PREFIX=${checkout}/.venv"
        "UV_INTERNAL__PARENT_INTERPRETER=${bait_bin}/python3")
      ;;
  esac
}

# Run a script from the checkout, as the workflow does, or from
# run_dir when set, with the environment the steps set, then the
# leg's assignments ($2...). Under 'bash -eo pipefail', as 'shell:
# bash' runs a step.
run_step() {
  local script="$1"
  shift
  : > "${workdir}/out"
  : > "${workdir}/summary"
  rm -f "${marker}"
  (cd "${run_dir:-${checkout}}" && env \
    -u UV_PYTHON -u UV_PYTHON_SEARCH_PATH -u VIRTUAL_ENV \
    -u CONDA_PREFIX -u UV_INTERNAL__PARENT_INTERPRETER \
    -u UV_PYTHON_PREFERENCE -u UV_SYSTEM_PYTHON \
    GITHUB_WORKSPACE="${checkout}" \
    RUNNER_TEMP="${runner_temp}" \
    GITHUB_OUTPUT="${workdir}/out" \
    GITHUB_STEP_SUMMARY="${workdir}/summary" \
    UV="${real_uv}" INSTALL_DIR="${install_dir}" \
    PYTHON="${python}" \
    PRIMARY='.pre-commit-config.yaml' \
    ORG_JSON='' PRIMARY_ERROR='' \
    INPUT_PLAN='' INPUT_HOOKS='' INPUT_SKIP_HOOKS='' \
    INPUT_CONFIG_PATH='' INPUT_CONFIG_URL='' INPUT_CONFIG_SHA256='' \
    INPUT_COMMIT_RANGE='' INPUT_CI_SKIPPED='false' \
    INPUT_SPLIT_HOOKS='true' \
    INPUT_ORG_CONFIG_PATH='linting/.pre-commit-config.yaml' \
    "$@" bash --noprofile --norc -eo pipefail "${script}") \
    > "${workdir}/stdout" 2>&1
}

dump() { sed 's/^/  /' "$1" >&2; }

no_marker() {
  if [ -e "${marker}" ]; then
    fail "$1 ran a planted interpreter"
    dump "${marker}"
  else
    pass
  fi
}

# Controls: the plant must be live, or a pass proves nothing.
marker_set() {
  if [ -s "${marker}" ]; then
    pass
  else
    fail "$1 did not run a planted interpreter"
    dump "${workdir}/stdout"
  fi
}

python=''
for name in checkout uv-python venv; do
  leg_env "${name}"

  # setup-uv's lookup: uv must refuse before looking. UV_PYTHON_ARCH
  # is empty, as the step sets it.
  if run_step "${lookup}" "${leg[@]}" UV_NO_CONFIG=1 UV_NO_PROJECT=1 \
    UV_PYTHON_PREFERENCE=lookup-disabled UV_PYTHON_ARCH=''; then
    fail "[${name}] uv ran setup-uv's lookup despite the preference"
    dump "${workdir}/stdout"
  else
    pass
  fi
  no_marker "[${name}] setup-uv's lookup"

  # From RUNNER_TEMP, its working directory.
  python=''
  if run_dir="${runner_temp}" run_step "${install}" "${leg[@]}"; then
    pass
  else
    fail "[${name}] the install step failed"
    dump "${workdir}/stdout"
  fi
  no_marker "[${name}] the install step"
  python="$(sed -n 's/^path=//p' "${workdir}/out")"
  case "${python}" in
    "${install_dir}"/*) pass ;;
    *) fail "[${name}] the install step reported '${python}'" ;;
  esac

  if run_step "${block}" "${leg[@]}"; then
    pass
  else
    fail "[${name}] the resolve step failed beside planted interpreters"
    dump "${workdir}/stdout"
  fi
  no_marker "[${name}] the resolve step"
  if grep -qx 'has_work=true' "${workdir}/out"; then
    pass
  else
    fail "[${name}] the resolve step did not plan any work"
    dump "${workdir}/out"
  fi

  run_step "${control}" "${leg[@]}" || true
  marker_set "[${name}] the resolver without '--python'"

  # 'uv python find --managed-python' still probes a '.venv/' in the
  # current directory, which is why the step does not run in the
  # checkout.
  if [ "${name}" = 'checkout' ]; then
    run_step "${install}" || true
    marker_set "[${name}] the install step run from the checkout"
  fi

  # The variable legs only: the checkout leg plants nothing that a
  # lookup from RUNNER_TEMP would reach.
  if [ "${name}" != 'checkout' ]; then
    run_step "${old_lookup}" "${leg[@]}" || true
    marker_set "[${name}] 'uv python find --system'"
    run_step "${lookup}" "${leg[@]}" UV_NO_CONFIG=1 UV_NO_PROJECT=1 \
      UV_SYSTEM_PYTHON=1 || true
    marker_set "[${name}] setup-uv's lookup without the preference"
  fi
done

# --- Result ----------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
  exit 1
fi
