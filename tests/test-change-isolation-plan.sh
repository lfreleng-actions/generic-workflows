#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the Gerrit endpoint, plan and report logic in
# .github/workflows/change-isolation.yaml.
#
# The plan decides which files a change touches and which checks run
# against them; the report decides whether the run passes. Both fail
# closed, so half these fixtures are rejection cases: a mistake that
# turns a failure into a pass would let a change through a policy it
# breaks, and nobody investigates a green check.
#
# The scripts are EXTRACTED from the workflow rather than copied
# here, so there is one implementation and these fixtures always
# exercise the code that runs in CI. Removing or renaming the markers
# in the workflow fails this script rather than silently testing
# nothing.
#
# Usage: tests/test-change-isolation-plan.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflow="${repo_root}/.github/workflows/change-isolation.yaml"

if [ ! -f "${workflow}" ]; then
  echo "ERROR: workflow not found: ${workflow}" >&2
  exit 1
fi

# A git hook exports these for the repository it runs in, and they
# would point every fixture repository below back at that one.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# Copy a marked region out of its heredoc, stripping the YAML block
# indentation measured from the BEGIN marker itself, so the extraction
# survives the workflow being re-nested.
extract() {
  local marker="$1" target="$2" sentinel="$3"
  awk -v marker="${marker}" '
    $0 ~ "# BEGIN " marker "$" {
      indent = match($0, /[^ ]/) - 1
      capture = 1
      next
    }
    $0 ~ "# END " marker "$" { capture = 0; next }
    capture { print substr($0, indent + 1) }
  ' "${workflow}" > "${target}"
  if ! grep -q "${sentinel}" "${target}"; then
    echo "ERROR: no ${marker} script between the markers in" >&2
    echo "       ${workflow}" >&2
    echo "       Restore the '# BEGIN ${marker}' and" >&2
    echo "       '# END ${marker}' comments around it." >&2
    exit 1
  fi
}

plan_script="${workdir}/plan.py"
report_script="${workdir}/report.py"
gerrit_script="${workdir}/gerrit.py"
extract change_isolation_plan "${plan_script}" 'def changed_paths'
extract change_isolation_report "${report_script}" 'def evaluate'
extract change_isolation_gerrit "${gerrit_script}" 'def endpoint'

# The scripts read caller input, and the plan and report the checkout
# of the change under test, so they must keep running isolated. Match
# the command line, anchored, rather than any mention in a comment.
isolated_runs=$(grep -cE "^[[:space:]]*python3 -I - <<'PYEOF'\$" \
  "${workflow}" || true)
if [ "${isolated_runs}" -ne 3 ]; then
  echo 'ERROR: the Gerrit endpoint, plan and report scripts in' >&2
  echo "       ${workflow}" >&2
  echo "       must all run as: python3 -I - <<'PYEOF'" >&2
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

# Print one output from a GITHUB_OUTPUT file in heredoc form.
read_output() {
  python3 -I - "$1" "$2" <<'PYEOF'
import sys

path, wanted = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().split("\n")
index = 0
while index < len(lines):
    line = lines[index]
    if "<<" in line:
        name, delimiter = line.split("<<", 1)
        end = lines.index(delimiter, index + 1)
        if name == wanted:
            print("\n".join(lines[index + 1:end]))
            sys.exit(0)
        index = end
    index += 1
sys.exit(1)
PYEOF
}

# --- Fixture repositories -------------------------------------------

counter=0
git_q() { git -c user.name=fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

# new_repo: a repository with INFO.yaml, src/foo.py and a README in
# its first commit; sets 'repo' to its path. Not called in a command
# substitution, whose subshell would lose the counter.
new_repo() {
  counter=$((counter + 1))
  repo="${workdir}/repo${counter}"
  local dir="${repo}"
  mkdir -p "${dir}/src"
  git_q init -q "${dir}"
  printf 'project: fixture\n' > "${dir}/INFO.yaml"
  printf 'print("foo")\n' > "${dir}/src/foo.py"
  printf 'readme\n' > "${dir}/README.md"
  git_q -C "${dir}" add -A
  git_q -C "${dir}" commit -q -m 'Initial'
}

commit_all() {
  git_q -C "$1" add -A
  git_q -C "$1" commit -q --allow-empty -m 'Change'
}

# run_plan <repo> <checks> [info_yaml_path]: sets plan_rc, plan_log
# and plan_out.
run_plan() {
  local repo="$1" checks="$2" info_path="${3-INFO.yaml}"
  plan_out="${workdir}/plan-output-${counter}-${RANDOM}"
  : > "${plan_out}"
  plan_rc=0
  plan_log=$(cd "${repo}" && INPUT_CHECKS="${checks}" \
    INPUT_INFO_YAML_PATH="${info_path}" GITHUB_OUTPUT="${plan_out}" \
    GITHUB_STEP_SUMMARY='' python3 -I "${plan_script}" 2>&1) ||
    plan_rc=$?
}

expect_plan_ok() {
  local label="$1"
  if [ "${plan_rc}" -eq 0 ]; then
    pass
  else
    fail "${label}: plan failed (exit ${plan_rc})" "${plan_log}"
  fi
}

# expect_plan_error <label> <substring of the expected message>
expect_plan_error() {
  local label="$1" message="$2"
  if [ "${plan_rc}" -eq 0 ]; then
    fail "${label}: plan passed, expected an error" "${plan_log}"
  elif ! grep -qF -- "${message}" <<< "${plan_log}"; then
    fail "${label}: no '${message}' in the error" "${plan_log}"
  elif [ -s "${plan_out}" ]; then
    fail "${label}: a failed plan wrote outputs" "$(cat "${plan_out}")"
  else
    pass
  fi
}

expect_output() {
  local label="$1" name="$2" expected="$3" actual
  actual=$(read_output "${plan_out}" "${name}") || actual='<missing>'
  if [ "${actual}" = "${expected}" ]; then
    pass
  else
    fail "${label}: ${name}" "expected: ${expected}
actual:   ${actual}"
  fi
}

# --- Gerrit endpoint ------------------------------------------------

# run_gerrit <url> [project] [branch]: sets gerrit_rc, gerrit_log and
# gerrit_out.
run_gerrit() {
  gerrit_out="${workdir}/gerrit-output-${RANDOM}"
  : > "${gerrit_out}"
  gerrit_rc=0
  gerrit_log=$(GERRIT_URL="$1" GERRIT_PROJECT="${2-project}" \
    GERRIT_BRANCH="${3-main}" GITHUB_OUTPUT="${gerrit_out}" \
    python3 -I "${gerrit_script}" 2>&1) || gerrit_rc=$?
}

# expect_endpoint <url> <expected host:port>
expect_endpoint() {
  local actual
  run_gerrit "$1"
  actual=$(read_output_line "${gerrit_out}" endpoint)
  if [ "${gerrit_rc}" -eq 0 ] && [ "${actual}" = "$2" ]; then
    pass
  else
    fail "endpoint of $1: expected $2, got '${actual}'" "${gerrit_log}"
  fi
}

# expect_gerrit_error <label> <substring of the expected message>
expect_gerrit_error() {
  local label="$1" message="$2"
  if [ "${gerrit_rc}" -eq 0 ]; then
    fail "${label}: resolver passed, expected an error" "${gerrit_log}"
  elif ! grep -qF -- "${message}" <<< "${gerrit_log}"; then
    fail "${label}: no '${message}' in the error" "${gerrit_log}"
  elif [ -s "${gerrit_out}" ]; then
    fail "${label}: a failed resolver wrote outputs" \
      "$(cat "${gerrit_out}")"
  else
    pass
  fi
}

# Print one 'name=value' output.
read_output_line() {
  sed -n "s/^$2=//p" "$1"
}

expect_endpoint 'https://gerrit.example.org' 'gerrit.example.org:443'
expect_endpoint 'https://gerrit.example.org/' 'gerrit.example.org:443'
expect_endpoint 'https://Gerrit.Example.ORG/r/' 'gerrit.example.org:443'
expect_endpoint 'https://gerrit.example.org:8443/r' 'gerrit.example.org:8443'
expect_endpoint 'HTTPS://gerrit.example.org' 'gerrit.example.org:443'
expect_endpoint 'https://gerrit-1.example.org:0443' 'gerrit-1.example.org:443'

run_gerrit 'http://gerrit.example.org'
expect_gerrit_error 'http scheme' 'must start with https://'
run_gerrit 'ssh://gerrit.example.org:29418'
expect_gerrit_error 'ssh scheme' 'must start with https://'
run_gerrit 'gerrit.example.org'
expect_gerrit_error 'no scheme' 'must start with https://'
run_gerrit 'https://user@gerrit.example.org'
expect_gerrit_error 'userinfo' 'no user information'
run_gerrit 'https://user:pass@gerrit.example.org'
expect_gerrit_error 'userinfo with password' 'no user information'
run_gerrit 'https://gerrit.example.org:0'
expect_gerrit_error 'port zero' 'invalid port'
run_gerrit 'https://gerrit.example.org:65536'
expect_gerrit_error 'port too large' 'invalid port'
run_gerrit 'https://gerrit.example.org:'
expect_gerrit_error 'empty port' 'invalid port'
run_gerrit 'https://gerrit.example.org:443x'
expect_gerrit_error 'non-numeric port' 'invalid port'
run_gerrit 'https://'
expect_gerrit_error 'no host' 'invalid hostname'
run_gerrit 'https:///r'
expect_gerrit_error 'empty host' 'invalid hostname'
run_gerrit 'https://gerrit_x.example.org'
expect_gerrit_error 'underscore' 'invalid hostname'
run_gerrit 'https://-gerrit.example.org'
expect_gerrit_error 'leading hyphen' 'invalid hostname'
run_gerrit 'https://gerrit..example.org'
expect_gerrit_error 'empty label' 'invalid hostname'
run_gerrit 'https://gerrit.example.org.'
expect_gerrit_error 'trailing dot' 'invalid hostname'
run_gerrit "https://$(printf 'a%.0s' {1..64}).example.org"
expect_gerrit_error 'label too long' 'invalid hostname'
run_gerrit 'https://[::1]:8443'
expect_gerrit_error 'IPv6 literal' 'invalid'
run_gerrit 'https://gerrit.example.org/r?x=1'
expect_gerrit_error 'query' 'no query or fragment'
run_gerrit 'https://gerrit.example.org/r#x'
expect_gerrit_error 'fragment' 'no query or fragment'
run_gerrit 'https://gerrit.example.org?'
expect_gerrit_error 'empty query' 'no query or fragment'
run_gerrit 'https://gerrit.example.org /r'
expect_gerrit_error 'space' 'whitespace'
run_gerrit "$(printf 'https://gerrit.example.org\n::warning::x')"
expect_gerrit_error 'newline' 'control character'
run_gerrit 'https://gerrït.example.org'
expect_gerrit_error 'non-ASCII host' 'non-ASCII'

# expect_ref <gerrit_branch> <expected ref>
expect_ref() {
  local actual
  run_gerrit 'https://gerrit.example.org' 'project' "$1"
  actual=$(read_output_line "${gerrit_out}" ref)
  if [ "${gerrit_rc}" -eq 0 ] && [ "${actual}" = "$2" ]; then
    pass
  else
    fail "ref of $1: expected $2, got '${actual}'" "${gerrit_log}"
  fi
}

expect_ref 'master' 'refs/heads/master'
expect_ref 'refs/meta/config' 'refs/meta/config'
expect_ref 'refs/heads/master' 'refs/heads/master'
expect_ref 'release/1.2' 'refs/heads/release/1.2'

# expect_ref_error <label> <gerrit_branch> <substring of the message>:
# the message must not echo the value.
expect_ref_error() {
  run_gerrit 'https://gerrit.example.org' 'project' "$2"
  expect_gerrit_error "$1" "$3"
  if grep -qF -- "$2" <<< "${gerrit_log}"; then
    fail "$1: the error echoes the branch" "${gerrit_log}"
  fi
}

expect_ref_error 'branch with a space' 'my branch' 'contains whitespace'
expect_ref_error 'branch with a tab' "$(printf 'my\tbranch')" \
  'contains a control character'
expect_ref_error 'branch with a newline' \
  "$(printf 'main\n::warning::x')" 'contains a control character'
expect_ref_error 'branch with DEL' "$(printf 'ma\177in')" \
  'contains a control character'
expect_ref_error 'branch with BEL' "$(printf 'ma\007in')" \
  'contains a control character'
# C1 controls, U+0080 to U+009F, as UTF-8. U+009B is a one-character
# CSI escape.
expect_ref_error 'branch with U+0085' "$(printf 'ma\302\205in')" \
  'contains a control character'
expect_ref_error 'branch with U+009B' "$(printf 'ma\302\233in')" \
  'contains a control character'
expect_ref_error 'branch with U+009F' "$(printf 'ma\302\237in')" \
  'contains a control character'
# U+00A0 is whitespace to str.isspace(), not a control.
expect_ref_error 'branch with U+00A0' "$(printf 'ma\302\240in')" \
  'contains whitespace'
expect_ref "$(printf 'r\303\251sum\303\251')" \
  "refs/heads/$(printf 'r\303\251sum\303\251')"
expect_ref_error 'branch with ..' 'release/../main' 'not a valid ref'
expect_ref_error 'branch with //' 'release//1.2' 'not a valid ref'
expect_ref_error 'leading hyphen' '-main' 'not a valid ref'
expect_ref_error 'trailing slash' 'release/' 'not a valid ref'
expect_ref_error 'trailing .lock' 'main.lock' 'not a valid ref'
expect_ref_error 'bare refs/' 'refs/' 'not a valid ref'

run_gerrit 'https://gerrit.example.org' '' ''
expect_gerrit_error 'project and branch missing' \
  'missing: gerrit_project gerrit_branch'
run_gerrit '' 'project' 'main'
expect_gerrit_error 'URL missing' 'missing: gerrit_url/GERRIT_URL'

two_checks='[
  {"name": "INFO.yaml", "paths": "/INFO.yaml"},
  {"name": "CI/CD", "paths": [".github/**"], "advisory": true}
]'

# --- Plan: valid checks ---------------------------------------------

new_repo
printf 'changed\n' >> "${repo}/README.md"
commit_all "${repo}"

run_plan "${repo}" "${two_checks}"
expect_plan_ok 'valid checks'
expect_output 'valid checks' has_work 'true'
expect_output 'valid checks' changed_files 'README.md'
expect_output 'valid checks' info_yaml_state 'untouched'
expect_output 'valid checks' head_sha "$(git -C "${repo}" rev-parse HEAD)"
expect_output 'valid checks' matrix \
  '{"include":[{"id":1,"name":"INFO.yaml","paths":"/INFO.yaml","advisory":false},{"id":2,"name":"CI/CD","paths":".github/**","advisory":true}]}'

run_plan "${repo}" '[{"name": "Docs", "paths": " docs/**\n\n*.md \n"}]'
expect_plan_ok 'paths string with blanks'
expect_output 'paths string with blanks' matrix \
  '{"include":[{"id":1,"name":"Docs","paths":"docs/**\n*.md","advisory":false}]}'

run_plan "${repo}" '[{"name": "A", "paths": ["a/**", "!a/keep"]}]'
expect_plan_ok 'paths array'
expect_output 'paths array' matrix \
  '{"include":[{"id":1,"name":"A","paths":"a/**\n!a/keep","advisory":false}]}'

# --- Plan: invalid checks -------------------------------------------

run_plan "${repo}" '[{"name": "A", "paths": "a"'
expect_plan_error 'malformed JSON' 'checks is not valid JSON'
run_plan "${repo}" ''
expect_plan_error 'empty input' 'checks is not valid JSON'
run_plan "${repo}" '{"name": "A", "paths": "a"}'
expect_plan_error 'object, not array' 'must be a JSON array'
run_plan "${repo}" '[]'
expect_plan_error 'empty array' 'at least one check'
run_plan "${repo}" '["a/**"]'
expect_plan_error 'entry not an object' 'checks[0] must be an object'
run_plan "${repo}" '[{"name": "A", "paths": "a", "path": "b"}]'
expect_plan_error 'unknown key' 'checks[0] ("A"): unknown key(s) "path"'
run_plan "${repo}" '[{"name": "A", "paths": "a"}, {"name": "A", "paths": "b"}]'
expect_plan_error 'duplicate name' 'checks[1] ("A"): duplicate name'
run_plan "${repo}" '[{"paths": "a"}]'
expect_plan_error 'missing name' "checks[0]: 'name' must be a non-empty"
run_plan "${repo}" '[{"name": "  ", "paths": "a"}]'
expect_plan_error 'blank name' "checks[0]: 'name' must be a non-empty"
run_plan "${repo}" '[{"name": 7, "paths": "a"}]'
expect_plan_error 'numeric name' "checks[0]: 'name' must be a non-empty"
run_plan "${repo}" '[{"name": "A\nB", "paths": "a"}]'
expect_plan_error 'name with a newline' 'no control characters'
run_plan "${repo}" '[{"name": " A", "paths": "a"}]'
expect_plan_error 'name with surrounding space' 'surrounding whitespace'
long_name=$(printf 'n%.0s' $(seq 1 101))
run_plan "${repo}" "[{\"name\": \"${long_name}\", \"paths\": \"a\"}]"
expect_plan_error 'name too long' 'at most 100 characters'
run_plan "${repo}" '[{"name": "A"}]'
expect_plan_error 'missing paths' "'paths' is required"
run_plan "${repo}" '[{"name": "A", "paths": " \n "}]'
expect_plan_error 'blank paths' "'paths' names no pattern"
run_plan "${repo}" '[{"name": "A", "paths": []}]'
expect_plan_error 'empty paths array' "'paths' names no pattern"
run_plan "${repo}" '[{"name": "A", "paths": ["a", 1]}]'
expect_plan_error 'non-string pattern' "'paths' must be a newline-separated"
run_plan "${repo}" '[{"name": "A", "paths": {"a": 1}}]'
expect_plan_error 'paths object' "'paths' must be a newline-separated"
run_plan "${repo}" '[{"name": "A", "paths": ["a\nb"]}]'
expect_plan_error 'newline inside an array pattern' 'control character'
run_plan "${repo}" '[{"name": "A", "paths": "a\u0000b"}]'
expect_plan_error 'NUL in a pattern' 'control character'
run_plan "${repo}" '[{"name": "A", "paths": "a", "advisory": "yes"}]'
expect_plan_error 'string advisory' "'advisory' must be true or false"
run_plan "${repo}" '[{"name": "A", "paths": "a", "advisory": 1}]'
expect_plan_error 'numeric advisory' "'advisory' must be true or false"

# Every problem is reported, not just the first.
run_plan "${repo}" '[{"name": "A", "paths": "a", "x": 1}, {"name": "A"}]'
expect_plan_error 'several problems: unknown key' 'unknown key(s) "x"'
expect_plan_error 'several problems: missing paths' "'paths' is required"

# --- Plan: info_yaml_path -------------------------------------------

for bad in '' '/INFO.yaml' '../INFO.yaml' './INFO.yaml' 'a//INFO.yaml' \
  '.' ' INFO.yaml'; do
  run_plan "${repo}" "${two_checks}" "${bad}"
  expect_plan_error "info_yaml_path '${bad}'" 'info_yaml_path'
done

run_plan "${repo}" "${two_checks}" 'docs/INFO.yaml'
expect_plan_ok 'nested info_yaml_path'
expect_output 'nested info_yaml_path' info_yaml_state 'untouched'

# --- Plan: what the change does to INFO.yaml ------------------------

new_repo
printf 'committers: []\n' >> "${repo}/INFO.yaml"
commit_all "${repo}"
run_plan "${repo}" "${two_checks}"
expect_plan_ok 'INFO.yaml modified'
expect_output 'INFO.yaml modified' info_yaml_state 'changed'
expect_output 'INFO.yaml modified' changed_files 'INFO.yaml'

new_repo
git_q -C "${repo}" rm -q INFO.yaml
commit_all "${repo}"
run_plan "${repo}" "${two_checks}"
expect_plan_ok 'INFO.yaml removed'
expect_output 'INFO.yaml removed' info_yaml_state 'removed'

new_repo
git_q -C "${repo}" mv INFO.yaml INFO.yml
commit_all "${repo}"
run_plan "${repo}" "${two_checks}"
expect_plan_ok 'INFO.yaml renamed away'
expect_output 'INFO.yaml renamed away' info_yaml_state 'removed'
expect_output 'INFO.yaml renamed away' changed_files "INFO.yaml
INFO.yml"

new_repo
mkdir -p "${repo}/docs"
printf 'project: nested\n' > "${repo}/docs/INFO.yaml"
commit_all "${repo}"
run_plan "${repo}" "${two_checks}"
expect_plan_ok 'nested INFO.yaml added, root untouched'
expect_output 'nested INFO.yaml added, root untouched' \
  info_yaml_state 'untouched'
run_plan "${repo}" "${two_checks}" 'docs/INFO.yaml'
expect_output 'nested INFO.yaml added, path set' info_yaml_state 'changed'

# --- Plan: renames surface both paths -------------------------------

# A rename into an isolated scope must also report the path it
# deletes, or 'git mv src/foo.py .github/foo.py' would pass the
# .github/** check while removing source.
new_repo
mkdir -p "${repo}/.github"
git_q -C "${repo}" mv src/foo.py .github/foo.py
commit_all "${repo}"
run_plan "${repo}" "${two_checks}"
expect_plan_ok 'rename into scope'
expect_output 'rename into scope' changed_files ".github/foo.py
src/foo.py"

# --- Plan: submodule bumps ------------------------------------------

# 'ignore = all' in .gitmodules must not hide a submodule bump, or a
# change touching INFO.yaml could carry one past the /INFO.yaml check.
new_repo
first=$(git_q -C "${repo}" rev-parse HEAD)
printf '[submodule "sub"]\n\tpath = sub\n\turl = ./sub\n\tignore = all\n' \
  > "${repo}/.gitmodules"
mkdir "${repo}/sub"
git_q -C "${repo}" update-index --add --cacheinfo "160000,${first},sub"
commit_all "${repo}"
second=$(git_q -C "${repo}" rev-parse HEAD)
git_q -C "${repo}" update-index --cacheinfo "160000,${second},sub"
printf 'committers: []\n' >> "${repo}/INFO.yaml"
commit_all "${repo}"
run_plan "${repo}" "${two_checks}"
expect_plan_ok 'submodule bump with ignore = all'
expect_output 'submodule bump with ignore = all' changed_files "INFO.yaml
sub"

# Each call draws its own artifact key.
key=$(read_output "${plan_out}" run_key) || key=''
if [[ "${key}" =~ ^[0-9a-f]{16}$ ]]; then
  pass
else
  fail 'run_key: not 16 hex digits' "${key}"
fi

# --- Plan: the change itself fails closed ---------------------------

new_repo
commit_all "${repo}"
run_plan "${repo}" "${two_checks}"
expect_plan_error 'empty change' 'the change touches no files'

new_repo
run_plan "${repo}" "${two_checks}"
expect_plan_error 'unreachable parent' 'HEAD~1) is unreachable'

new_repo
printf 'x\n' > "${repo}/tab"$'\t'"name"
commit_all "${repo}"
run_plan "${repo}" "${two_checks}"
expect_plan_error 'tab in a path' 'changed path "tab\tname"'

new_repo
printf 'x\n' > "${repo}/new"$'\n'"line"
commit_all "${repo}"
run_plan "${repo}" "${two_checks}"
expect_plan_error 'newline in a path' 'changed path "new\nline"'

new_repo
printf 'x\n' > "${repo}/esc"$'\x1b'"ape"
commit_all "${repo}"
run_plan "${repo}" "${two_checks}"
expect_plan_error 'escape in a path' 'control character'

# The isolation action strips whitespace around each entry, so it
# would read ' .github/x' as the in-scope '.github/x'.
new_repo
mkdir -p "${repo}/ .github"
printf 'x\n' > "${repo}/ .github/x"
commit_all "${repo}"
run_plan "${repo}" "${two_checks}"
expect_plan_error 'leading space in a path' 'surrounding whitespace'

# Not a git repository at all.
mkdir -p "${workdir}/not-a-repo"
run_plan "${workdir}/not-a-repo" "${two_checks}"
expect_plan_error 'no repository' 'HEAD~1) is unreachable'

# --- Report ---------------------------------------------------------

report_matrix='{"include":[{"id":1,"name":"INFO.yaml","paths":"/INFO.yaml","advisory":false},{"id":2,"name":"CI/CD","paths":".github/**","advisory":true}]}'

# write_result <dir> <id> <name> <outcome> <triggered> <isolated>
#   [violating file...]
write_result() {
  local dir="$1" id="$2" name="$3" outcome="$4" triggered="$5"
  local isolated="$6"
  shift 6
  mkdir -p "${dir}"
  python3 -I - "${dir}/${id}.json" "${id}" "${name}" "${outcome}" \
    "${triggered}" "${isolated}" "$@" <<'PYEOF'
import json
import sys

path, ident, name, outcome, triggered, isolated, *files = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "id": int(ident),
            "name": name,
            "advisory": False,
            "outcome": outcome,
            "triggered": triggered,
            "isolated": isolated,
            "violating_files": files,
        },
        handle,
    )
PYEOF
}

new_results() {
  counter=$((counter + 1))
  results="${workdir}/results${counter}"
  mkdir -p "${results}"
}

# run_report [VAR=value...]: defaults describe a clean run.
run_report() {
  report_out="${workdir}/report-output-${counter}-${RANDOM}"
  report_summary="${report_out}.md"
  : > "${report_out}"
  report_rc=0
  report_log=$(env PLAN_RESULT=success ISOLATION_RESULT=success \
    INFO_YAML_RESULT=skipped INFO_YAML_STATE=untouched \
    INFO_YAML_VALIDATE=true INFO_YAML_PATH=INFO.yaml \
    MATRIX="${report_matrix}" RESULTS_DIR="${results}" \
    GITHUB_OUTPUT="${report_out}" GITHUB_STEP_SUMMARY="${report_summary}" \
    "$@" python3 -I "${report_script}" 2>&1) || report_rc=$?
}

expect_report_pass() {
  local label="$1"
  if [ "${report_rc}" -eq 0 ]; then
    pass
  else
    fail "${label}: report failed (exit ${report_rc})" "${report_log}"
  fi
}

expect_report_fail() {
  local label="$1" message="$2"
  if [ "${report_rc}" -eq 0 ]; then
    fail "${label}: report passed, expected a failure" "${report_log}"
  elif ! grep -qF -- "${message}" <<< "${report_log}"; then
    fail "${label}: no '${message}' in the failure" "${report_log}"
  else
    pass
  fi
}

expect_results() {
  local label="$1" expected="$2" actual
  actual=$(read_output "${report_out}" results) || actual='<missing>'
  if [ "${actual}" = "${expected}" ]; then
    pass
  else
    fail "${label}: results" "expected: ${expected}
actual:   ${actual}"
  fi
}

new_results
write_result "${results}" 1 'INFO.yaml' success false true
write_result "${results}" 2 'CI/CD' success true true
run_report
expect_report_pass 'all isolated'
expect_results 'all isolated' \
  '[{"name":"INFO.yaml","advisory":false,"triggered":false,"isolated":true,"violating_files":[]},{"name":"CI/CD","advisory":true,"triggered":true,"isolated":true,"violating_files":[]}]'
if grep -qF '| CI/CD | yes | ✅ isolated |' "${report_summary}"; then
  pass
else
  fail 'all isolated: summary row' "$(cat "${report_summary}")"
fi

new_results
write_result "${results}" 1 'INFO.yaml' failure true false 'src/foo.py'
write_result "${results}" 2 'CI/CD' success false true
run_report ISOLATION_RESULT=failure
expect_report_fail 'violation' 'Isolation: INFO.yaml is not isolated'
expect_results 'violation' \
  '[{"name":"INFO.yaml","advisory":false,"triggered":true,"isolated":false,"violating_files":["src/foo.py"]},{"name":"CI/CD","advisory":true,"triggered":false,"isolated":true,"violating_files":[]}]'

# The plan, not the artifact, says whether a check is advisory.
new_results
write_result "${results}" 1 'INFO.yaml' success false true
write_result "${results}" 2 'CI/CD' success true false 'README.md'
run_report
expect_report_pass 'advisory violation'
expect_results 'advisory violation' \
  '[{"name":"INFO.yaml","advisory":false,"triggered":false,"isolated":true,"violating_files":[]},{"name":"CI/CD","advisory":true,"triggered":true,"isolated":false,"violating_files":["README.md"]}]'
if grep -qF 'not isolated (advisory)' "${report_summary}"; then
  pass
else
  fail 'advisory violation: summary' "$(cat "${report_summary}")"
fi

new_results
write_result "${results}" 1 'INFO.yaml' success false true
run_report
expect_report_fail 'missing result artifact' 'Isolation: CI/CD left no result'
expect_results 'missing result artifact' \
  '[{"name":"INFO.yaml","advisory":false,"triggered":false,"isolated":true,"violating_files":[]},{"name":"CI/CD","advisory":true,"triggered":null,"isolated":null,"violating_files":[]}]'

new_results
run_report ISOLATION_RESULT=skipped
expect_report_fail 'no results at all' 'Isolation: INFO.yaml left no result'

new_results
run_report RESULTS_DIR="${workdir}/does-not-exist"
expect_report_fail 'no results directory' 'left no result'

new_results
write_result "${results}" 1 'INFO.yaml' success false true
printf '{not json' > "${results}/2.json"
run_report
expect_report_fail 'unreadable result' 'CI/CD left an unreadable result'

new_results
write_result "${results}" 1 'INFO.yaml' success false true
write_result "${results}" 2 'Other' success false true
run_report
expect_report_fail 'result for another check' 'result for another check'

new_results
write_result "${results}" 1 'INFO.yaml' failure '' ''
write_result "${results}" 2 'CI/CD' success false true
run_report ISOLATION_RESULT=failure
expect_report_fail 'action crashed' 'INFO.yaml reported no verdict'

new_results
write_result "${results}" 1 'INFO.yaml' success false true
write_result "${results}" 2 'CI/CD' failure true false
run_report ISOLATION_RESULT=failure
expect_report_fail 'advisory leg failed' 'CI/CD did not complete'

new_results
write_result "${results}" 1 'INFO.yaml' success false true
write_result "${results}" 2 'CI/CD' success false true
run_report ISOLATION_RESULT=cancelled
expect_report_fail 'isolation cancelled' \
  'isolation jobs did not succeed (cancelled)'

# Clean verdicts, but a leg failed after recording its result.
new_results
write_result "${results}" 1 'INFO.yaml' success false true
write_result "${results}" 2 'CI/CD' success false true
run_report ISOLATION_RESULT=failure
expect_report_fail 'leg failed after a clean result' \
  'isolation jobs did not succeed (failure)'

new_results
run_report PLAN_RESULT=failure MATRIX= INFO_YAML_STATE= \
  ISOLATION_RESULT=skipped
expect_report_fail 'plan failed' 'The plan job did not succeed (failure)'
expect_results 'plan failed' '[]'

new_results
run_report MATRIX='{"include":[]}'
expect_report_fail 'empty matrix' 'planned no checks'

new_results
run_report MATRIX='not json'
expect_report_fail 'unreadable matrix' 'no readable matrix'

# --- Report: INFO.yaml ----------------------------------------------

clean_results() {
  new_results
  write_result "${results}" 1 'INFO.yaml' success false true
  write_result "${results}" 2 'CI/CD' success false true
}

clean_results
run_report INFO_YAML_STATE=changed INFO_YAML_RESULT=success
expect_report_pass 'INFO.yaml changed, valid'

clean_results
run_report INFO_YAML_STATE=changed INFO_YAML_RESULT=failure
expect_report_fail 'INFO.yaml changed, invalid' \
  'INFO.yaml changed: job failure'

clean_results
run_report INFO_YAML_STATE=removed INFO_YAML_RESULT=failure
expect_report_fail 'INFO.yaml removed' 'INFO.yaml removed: job failure'

clean_results
run_report INFO_YAML_STATE=changed INFO_YAML_RESULT=cancelled
expect_report_fail 'INFO.yaml cancelled' 'INFO.yaml changed: job cancelled'

clean_results
run_report INFO_YAML_STATE=changed INFO_YAML_RESULT=skipped
expect_report_fail 'INFO.yaml job skipped when due' \
  'INFO.yaml changed: job skipped'

clean_results
run_report INFO_YAML_STATE=changed INFO_YAML_RESULT=skipped \
  INFO_YAML_VALIDATE=false
expect_report_pass 'INFO.yaml validation disabled'

clean_results
run_report INFO_YAML_STATE=untouched INFO_YAML_RESULT=skipped
expect_report_pass 'INFO.yaml untouched'
# shellcheck disable=SC2016  # literal backticks, not an expansion
if grep -qF 'INFO.yaml (`INFO.yaml`): not touched' "${report_summary}"
then
  pass
else
  fail 'INFO.yaml untouched: summary' "$(cat "${report_summary}")"
fi

clean_results
run_report INFO_YAML_STATE=bogus
expect_report_fail 'unknown INFO.yaml state' 'Unknown INFO.yaml state'

# --- Summary --------------------------------------------------------

total=$((passed + failed))
if [ "${failed}" -ne 0 ]; then
  echo "${failed} of ${total} change isolation fixture(s) failed" >&2
  exit 1
fi
echo "All ${total} change isolation fixtures passed"
