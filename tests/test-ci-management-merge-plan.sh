#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the plan and merged-revision wait in
# .github/workflows/ci-management-merge.yaml.
#
# The plan decides whether a merge deploys to Jenkins and checks every
# input before anything is checked out. It fails closed, so most of
# these fixtures are rejection cases: a mistake that lets a bad input
# through hands it to jjb-action, which pushes jobs to production.
#
# The scripts are EXTRACTED from the workflow rather than copied
# here, so these fixtures always exercise the code that runs in CI.
# Removing or renaming the markers fails this script rather than
# silently testing nothing.
#
# Usage: bash tests/test-ci-management-merge-plan.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflow="${repo_root}/.github/workflows/ci-management-merge.yaml"

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
wait_script="${workdir}/wait.sh"
extract "${workflow}" ci_management_merge_plan "${plan_script}" \
  'def jenkins_endpoint'
extract "${workflow}" ci_management_merge_wait "${wait_script}" \
  'merge-base --is-ancestor'

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

# The plan reads caller input, so it must run isolated. Match the
# command line, anchored, rather than any mention in a comment.
isolated_runs=$(grep -cE "^[[:space:]]*python3 -I - <<'PYEOF'\$" \
  "${workflow}" || true)
if [ "${isolated_runs}" -eq 1 ]; then
  pass
else
  fail "expected 1 'python3 -I - <<'PYEOF'' run, found ${isolated_runs}"
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
# bypass, and both jobs carry one.
stale_pins=$(grep -n 'step-security/harden-runner@' "${workflow}" |
  grep -v '@46b06cea07f9e64621fdf066ba77ac6915163d43 ' || true)
if [ -z "${stale_pins}" ]; then
  pass
else
  fail 'a harden-runner pin is not v2.22.3' "${stale_pins}"
fi
harden_runs=$(grep -c 'step-security/harden-runner@' "${workflow}" || true)
if [ "${harden_runs}" -eq 2 ]; then
  pass
else
  fail "expected 2 harden-runner steps, one per job, found ${harden_runs}"
fi

# The Jenkins password reaches the jjb-action step alone, through
# 'with:'.
password_uses=$(grep -n 'secrets\.jenkins_password' "${workflow}" || true)
password_line="jenkins_password: \${{ secrets.jenkins_password }}"
if [ "$(printf '%s\n' "${password_uses}" | grep -c .)" -eq 1 ] &&
  [ "$(grep -F "${password_line}" "${workflow}" | sed 's/^ *//')" = \
    "${password_line}" ]; then
  pass
else
  fail 'jenkins_password must reach one with: input alone' \
    "${password_uses:-no use of secrets.jenkins_password}"
fi

# No token persists from the checkout, and the caller owns
# concurrency: two merges must queue, which only the caller can key.
if [ "$(grep -cE '^[[:space:]]*persist-credentials: false$' \
  "${workflow}" || true)" -eq 1 ]; then
  pass
else
  fail "expected 1 'persist-credentials: false' checkout"
fi

# One checkout, of the commit the wait verified, and no git command
# after it: actions/checkout alone builds the deployed tree.
checkouts=$(grep -c 'uses: actions/checkout@' "${workflow}" || true)
verified_ref="ref: \${{ steps.wait.outputs.sha }}"
after_checkout=$(awk '/uses: actions\/checkout@/ { seen = 1; next }
  seen && $0 !~ /^[[:space:]]*#/ && /(^|[^[:alnum:]_-])git / {
    print FNR ": " $0
  }' "${workflow}")
if [ "${checkouts}" -ne 1 ]; then
  fail "expected 1 actions/checkout step, found ${checkouts}"
elif [ "$(grep -cF "${verified_ref}" "${workflow}" || true)" -ne 1 ]; then
  fail "the checkout must use '${verified_ref}'"
elif [ -n "${after_checkout}" ]; then
  fail 'a git command follows the checkout' "${after_checkout}"
else
  pass
fi
if grep -nE '^[[:space:]]*concurrency:' "${workflow}" > /dev/null; then
  fail 'the reusable sets concurrency; the caller owns it' \
    "$(grep -nE '^[[:space:]]*concurrency:' "${workflow}")"
else
  pass
fi

# --- Plan -----------------------------------------------------------

revision='0123456789abcdef0123456789abcdef01234567'

# run_plan [VAR=value ...]: sets plan_rc, plan_log and plan_out.
# Defaults are a valid deploying merge.
run_plan() {
  plan_out="${workdir}/plan-output-${RANDOM}"
  : > "${plan_out}"
  plan_rc=0
  plan_log=$(env -i PATH="${PATH}" GITHUB_OUTPUT="${plan_out}" \
    INPUT_GERRIT_BRANCH='master' \
    INPUT_DEPLOY_BRANCH='master' \
    INPUT_MERGED_REVISION="${revision}" \
    INPUT_JENKINS_URL='https://jenkins.example.org' \
    INPUT_JENKINS_USER='jobbuilder' \
    INPUT_WORKERS='0' \
    INPUT_PATH_PREFIX='.' \
    INPUT_JJB_PATH='jjb' \
    INPUT_REPOSITORY='' \
    INPUT_HARDEN_RUNNER_EGRESS='block' \
    INPUT_HARDEN_RUNNER_ALLOWLIST='lfreleng-actions//list.txt@abc' \
    INPUT_HARDEN_RUNNER_SUPPLEMENTAL_ALLOWLIST='' \
    "$@" python3 -I "${plan_script}" 2>&1) || plan_rc=$?
}

# output <name>: the value the plan wrote for one output.
output() {
  sed -n "s/^$1=//p" "${plan_out}"
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
# plan fails, names the problem, writes no output, and never echoes
# the first value.
expect_plan_error() {
  local label="$1" message="$2" value="${3#*=}"
  shift 2
  run_plan "$@"
  if [ "${plan_rc}" -eq 0 ]; then
    fail "${label}: plan passed, expected an error" "${plan_log}"
  elif ! grep -qF -- "${message}" <<< "${plan_log}"; then
    fail "${label}: no '${message}' in the error" "${plan_log}"
  elif [ -s "${plan_out}" ]; then
    fail "${label}: the failed plan wrote outputs" "$(cat "${plan_out}")"
  elif [ ${#value} -gt 2 ] && grep -qF -- "${value}" <<< "${plan_log}"
  then
    fail "${label}: the error echoes the value" "${plan_log}"
  else
    pass
  fi
}

# expect_deploy <label> <gerrit_branch> <deploy_branch> <deploy>
expect_deploy() {
  run_plan INPUT_GERRIT_BRANCH="$2" INPUT_DEPLOY_BRANCH="$3"
  if [ "${plan_rc}" -ne 0 ]; then
    fail "$1: plan failed" "${plan_log}"
  elif [ "$(output deploy)" != "$4" ]; then
    fail "$1: deploy is '$(output deploy)', expected '$4'" "${plan_log}"
  elif [ "$4" = false ] && ! grep -qF '::notice::' <<< "${plan_log}"; then
    fail "$1: a skipped update gives no notice" "${plan_log}"
  else
    pass
  fi
}

# expect_endpoint <url> <host:port>
expect_endpoint() {
  run_plan INPUT_JENKINS_URL="$1"
  if [ "${plan_rc}" -eq 0 ] && [ "$(output jenkins_endpoint)" = "$2" ]
  then
    pass
  else
    fail "endpoint of $1: expected $2, got '$(output jenkins_endpoint)'" \
      "${plan_log}"
  fi
}

# The deploy decision.
expect_deploy 'short names' 'master' 'master' true
expect_deploy 'full ref and short name' 'refs/heads/master' 'master' true
expect_deploy 'short name and full ref' 'master' 'refs/heads/master' true
expect_deploy 'full refs' 'refs/heads/main' 'refs/heads/main' true
expect_deploy 'refs/meta/config' 'refs/meta/config' 'master' false
expect_deploy 'another branch' 'stable/2026' 'master' false
expect_deploy 'another branch, full ref' 'refs/heads/main' 'master' false
expect_deploy 'a prefix of the deploy branch' 'mast' 'master' false

# The outputs the Update job reads.
run_plan INPUT_MERGED_REVISION="${revision^^}" INPUT_DEPLOY_BRANCH='main' \
  INPUT_GERRIT_BRANCH='main'
if [ "${plan_rc}" -eq 0 ] && [ "$(output ref)" = 'refs/heads/main' ] &&
  [ "$(output revision)" = "${revision}" ]; then
  pass
else
  fail 'outputs: expected refs/heads/main and the lower-case revision' \
    "${plan_log}"$'\n'"$(cat "${plan_out}")"
fi

expect_endpoint 'https://jenkins.example.org' 'jenkins.example.org:443'
expect_endpoint 'https://jenkins.opendaylight.org/releng' \
  'jenkins.opendaylight.org:443'
expect_endpoint 'https://Jenkins.Example.ORG./' 'jenkins.example.org:443'
expect_endpoint 'https://jenkins.example.org:8443/ci/' \
  'jenkins.example.org:8443'
expect_endpoint 'https://jenkins' 'jenkins:443'

# Accepted.
expect_plan_ok 'defaults'
expect_plan_ok 'workers 1' INPUT_WORKERS='1'
expect_plan_ok 'workers 64' INPUT_WORKERS='64'
expect_plan_ok 'user with an inner space' INPUT_JENKINS_USER='job builder'
expect_plan_ok 'user with an @' INPUT_JENKINS_USER='jobbuilder@example.org'
expect_plan_ok 'deploy branch with a slash' INPUT_DEPLOY_BRANCH='stable/x' \
  INPUT_GERRIT_BRANCH='stable/x'
expect_plan_ok 'path_prefix subdirectory' INPUT_PATH_PREFIX='ci/'
expect_plan_ok 'jjb_path nested' INPUT_JJB_PATH='jjb/global'
expect_plan_ok 'repository' INPUT_REPOSITORY='opendaylight/releng-builder'
expect_plan_ok 'repository with a dot' INPUT_REPOSITORY='o-ran-sc/ci.management'
expect_plan_ok 'audit egress' INPUT_HARDEN_RUNNER_EGRESS='audit'
expect_plan_ok 'supplemental list' \
  INPUT_HARDEN_RUNNER_SUPPLEMENTAL_ALLOWLIST='org//extra.txt@abc'

# Rejected: jenkins_url. Each value holds a recognisable string, so
# an error that echoes it is caught.
url_message='jenkins_url must be an https:// URL with a host'
expect_plan_error 'url empty' 'jenkins_url is empty' INPUT_JENKINS_URL=''
expect_plan_error 'url http' "${url_message}" \
  INPUT_JENKINS_URL='http://jenkins.example.org'
expect_plan_error 'url upper-case scheme' "${url_message}" \
  INPUT_JENKINS_URL='HTTPS://jenkins.example.org'
expect_plan_error 'url no host' "${url_message}" \
  INPUT_JENKINS_URL='https:///releng'
expect_plan_error 'url bad host' "${url_message}" \
  INPUT_JENKINS_URL='https://-jenkins.example.org'
expect_plan_error 'url empty label' "${url_message}" \
  INPUT_JENKINS_URL='https://jenkins..example.org'
expect_plan_error 'url credentials' 'must carry no user information' \
  INPUT_JENKINS_URL='https://admin:s3cr3t@jenkins.example.org'
expect_plan_error 'url query' 'must carry no query or fragment' \
  INPUT_JENKINS_URL='https://jenkins.example.org/?token=s3cr3t'
expect_plan_error 'url fragment' 'must carry no query or fragment' \
  INPUT_JENKINS_URL='https://jenkins.example.org/releng#top'
expect_plan_error 'url bare ?' 'must carry no query or fragment' \
  INPUT_JENKINS_URL='https://jenkins.example.org?'
expect_plan_error 'url IPv4' 'not an IP literal' \
  INPUT_JENKINS_URL='https://192.0.2.10/releng'
expect_plan_error 'url short IPv4' 'not an IP literal' \
  INPUT_JENKINS_URL='https://127.1'
expect_plan_error 'url hex IPv4' 'not an IP literal' \
  INPUT_JENKINS_URL='https://0x7f000001'
expect_plan_error 'url IPv6' 'not an IP literal' \
  INPUT_JENKINS_URL='https://[2001:db8::1]/releng'
expect_plan_error 'url port 0' 'invalid port' \
  INPUT_JENKINS_URL='https://jenkins.example.org:0'
expect_plan_error 'url port too high' 'invalid port' \
  INPUT_JENKINS_URL='https://jenkins.example.org:65536'
expect_plan_error 'url empty port' 'invalid port' \
  INPUT_JENKINS_URL='https://jenkins.example.org:/'
expect_plan_error 'url named port' 'invalid port' \
  INPUT_JENKINS_URL='https://jenkins.example.org:https'
expect_plan_error 'url space' 'contains whitespace' \
  INPUT_JENKINS_URL='https://jenkins.example.org/rel eng'
expect_plan_error 'url newline' 'contains whitespace' \
  INPUT_JENKINS_URL="$(printf 'https://jenkins.example.org\n::warning::x')"
expect_plan_error 'url non-ASCII' 'non-ASCII' \
  INPUT_JENKINS_URL="$(printf 'https://jenkins.example.org/r\303\251l')"

# Rejected: jenkins_user.
expect_plan_error 'user empty' 'jenkins_user is empty' INPUT_JENKINS_USER=''
expect_plan_error 'user newline' 'jenkins_user contains a control' \
  INPUT_JENKINS_USER="$(printf 'jobbuilder\npassword=x')"
expect_plan_error 'user tab' 'jenkins_user contains a control' \
  INPUT_JENKINS_USER="$(printf 'job\tbuilder')"
expect_plan_error 'user U+009B' 'jenkins_user contains a control' \
  INPUT_JENKINS_USER="$(printf 'job\302\233builder')"
expect_plan_error 'user leading space' 'starts or ends with whitespace' \
  INPUT_JENKINS_USER=' jobbuilder'
expect_plan_error 'user trailing no-break space' \
  'starts or ends with whitespace' \
  INPUT_JENKINS_USER="$(printf 'jobbuilder\302\240')"

# Rejected: the branches, each rule for each input.
for input in GERRIT_BRANCH DEPLOY_BRANCH; do
  name=$(tr '[:upper:]' '[:lower:]' <<< "${input}")
  expect_plan_error "${name} empty" "${name} is empty" "INPUT_${input}="
  expect_plan_error "${name} .." "${name} is not a valid ref name" \
    "INPUT_${input}=release/../main"
  expect_plan_error "${name} //" "${name} is not a valid ref name" \
    "INPUT_${input}=release//main"
  expect_plan_error "${name} leading -" "${name} is not a valid ref name" \
    "INPUT_${input}=--upload-pack=x"
  expect_plan_error "${name} trailing /" "${name} is not a valid ref name" \
    "INPUT_${input}=release/"
  expect_plan_error "${name} .lock" "${name} is not a valid ref name" \
    "INPUT_${input}=main.lock"
  expect_plan_error "${name} leading /" "${name} is not a valid ref name" \
    "INPUT_${input}=/master"
  expect_plan_error "${name} trailing ." "${name} is not a valid ref name" \
    "INPUT_${input}=master."
  expect_plan_error "${name} dot component" \
    "${name} is not a valid ref name" "INPUT_${input}=release/.hidden"
  expect_plan_error "${name} inner .lock" "${name} is not a valid ref name" \
    "INPUT_${input}=release/x.lock/topic"
  expect_plan_error "${name} @" "${name} is not a valid ref name" \
    "INPUT_${input}=@"
  expect_plan_error "${name} colon" "${name} contains a character git" \
    "INPUT_${input}=main:refs/heads/x"
  expect_plan_error "${name} @{" "${name} contains a character git" \
    "INPUT_${input}=main@{1}"
  expect_plan_error "${name} space" "${name} contains whitespace" \
    "INPUT_${input}=my branch"
  expect_plan_error "${name} newline" "${name} contains a control" \
    "INPUT_${input}=$(printf 'main\n::warning::x')"
done
expect_plan_error 'deploy_branch a tag' 'deploy_branch must name a branch' \
  INPUT_DEPLOY_BRANCH='refs/tags/v1.0.0'
expect_plan_error 'deploy_branch refs/meta/config' \
  'deploy_branch must name a branch' \
  INPUT_DEPLOY_BRANCH='refs/meta/config'

# Rejected: merged_revision.
revision_message='merged_revision must be a commit SHA'
expect_plan_error 'revision empty' "${revision_message}" \
  INPUT_MERGED_REVISION=''
expect_plan_error 'revision short' "${revision_message}" \
  INPUT_MERGED_REVISION='0123456789abcdef'
expect_plan_error 'revision 41 digits' "${revision_message}" \
  INPUT_MERGED_REVISION="${revision}8"
expect_plan_error 'revision non-hex' "${revision_message}" \
  INPUT_MERGED_REVISION="${revision%?}g"
expect_plan_error 'revision a branch' "${revision_message}" \
  INPUT_MERGED_REVISION='refs/heads/master'
expect_plan_error 'revision trailing newline' "${revision_message}" \
  INPUT_MERGED_REVISION="${revision}"$'\ninjected'

# Rejected: workers.
expect_plan_error 'workers empty' 'workers must be' INPUT_WORKERS=''
expect_plan_error 'workers 65' 'workers must be' INPUT_WORKERS='65'
expect_plan_error 'workers negative' 'workers must be' INPUT_WORKERS='-1'
expect_plan_error 'workers fraction' 'workers must be' INPUT_WORKERS='1.5'
expect_plan_error 'workers leading zero' 'workers must be' INPUT_WORKERS='01'

# Rejected: the paths, as in ci-management-verify.yaml.
for input in PATH_PREFIX JJB_PATH; do
  name=$(tr '[:upper:]' '[:lower:]' <<< "${input}")
  expect_plan_error "${name} empty" "${name} is empty" "INPUT_${input}="
  expect_plan_error "${name} absolute" "${name} must be a relative" \
    "INPUT_${input}=/etc/jjb"
  expect_plan_error "${name} traversal" "${name} contains a '..' segment" \
    "INPUT_${input}=jjb/../../etc"
  expect_plan_error "${name} leading -" "${name} starts with '-'" \
    "INPUT_${input}=--version"
  expect_plan_error "${name} space" "${name} contains whitespace" \
    "INPUT_${input}=my jjb"
  expect_plan_error "${name} newline" "${name} contains a control" \
    "INPUT_${input}=$(printf 'abc\n::warning::injected')"
done

# Rejected: repository. The wait sends the job's token to the URL
# built from it.
repo_message="repository must be empty or 'owner/name'"
expect_plan_error 'repository without owner' "${repo_message}" \
  INPUT_REPOSITORY='releng-builder'
expect_plan_error 'repository with a path' "${repo_message}" \
  INPUT_REPOSITORY='owner/name/extra'
expect_plan_error 'repository traversal' "${repo_message}" \
  INPUT_REPOSITORY='owner/..'
expect_plan_error 'repository URL' "${repo_message}" \
  INPUT_REPOSITORY='https://evil.example/owner/name'
expect_plan_error 'repository with a query' "${repo_message}" \
  INPUT_REPOSITORY='owner/name?x=leak'
expect_plan_error 'repository with a newline' "${repo_message}" \
  INPUT_REPOSITORY="$(printf 'org/repo\n::warning::injected')"

# Rejected: the hardening inputs.
expect_plan_error 'egress typo' 'harden_runner_egress must' \
  INPUT_HARDEN_RUNNER_EGRESS='blocked'
expect_plan_error 'egress empty' 'harden_runner_egress must' \
  INPUT_HARDEN_RUNNER_EGRESS=''
expect_plan_error 'supplemental without baseline' \
  'harden_runner_allowlist is empty' \
  INPUT_HARDEN_RUNNER_SUPPLEMENTAL_ALLOWLIST='org//extra.txt@abc' \
  INPUT_HARDEN_RUNNER_ALLOWLIST=''

# Every bad input is reported, not the first alone, and a merge to
# another branch with a bad input still fails.
run_plan INPUT_GERRIT_BRANCH='refs/meta/config' \
  INPUT_JENKINS_URL='http://jenkins.example.org' INPUT_WORKERS='99'
if [ "${plan_rc}" -ne 0 ] && [ ! -s "${plan_out}" ] &&
  grep -qF "${url_message}" <<< "${plan_log}" &&
  grep -qF 'workers must be' <<< "${plan_log}"; then
  pass
else
  fail 'two bad inputs on a skipped merge: expected both reported' \
    "${plan_log}"
fi

# --- Merged-revision wait -------------------------------------------

# A mirror whose deploy branch has not yet replicated the merged
# commit. The commit sits on a side branch the wait never fetches;
# publishing moves the deploy branch onto it, or onto a later commit
# built on it. The wait fetches '${SERVER_URL}/${REPOSITORY}', so the
# mirror's path is split in two.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fixture_git() {
  git -c user.name='Fixture' -c user.email='fixture@example.invalid' \
    -c init.defaultBranch=master "$@"
}

mirror="${workdir}/mirror"
origin="${mirror}/org/ci-management"
fixture_git init -q "${origin}"
git -C "${origin}" config uploadpack.allowFilter true
printf 'old\n' > "${origin}/jobs.yaml"
fixture_git -C "${origin}" add jobs.yaml
fixture_git -C "${origin}" commit -q -m 'Base'
base=$(git -C "${origin}" rev-parse HEAD)
fixture_git -C "${origin}" checkout -q -b pending
printf 'merged\n' > "${origin}/jobs.yaml"
fixture_git -C "${origin}" commit -q -am 'Merged change'
merged=$(git -C "${origin}" rev-parse HEAD)
printf 'later\n' > "${origin}/jobs.yaml"
fixture_git -C "${origin}" commit -q -am 'Later change'
later=$(git -C "${origin}" rev-parse HEAD)
fixture_git -C "${origin}" checkout -q -b rewritten "${base}"
printf 'rewritten\n' > "${origin}/jobs.yaml"
fixture_git -C "${origin}" commit -q -am 'Rewritten history'
rewritten=$(git -C "${origin}" rev-parse HEAD)
fixture_git -C "${origin}" checkout -q master

# A sleep that takes no time but advances the wait's clock: it runs as
# a function in the wait's shell, so adding its argument to SECONDS
# moves the clock the deadline reads. It counts the calls, records the
# clock after each, and moves the deploy branch to FIXTURE_REVISION on
# the call named by PUBLISH_ON_SLEEP, or on the first call that ends
# at or after PUBLISH_AT seconds. With SLEEP_SIGNAL set, the first
# call sends that signal to the wait instead. The wait exports
# GIT_DIR, so name the mirror's.
sleep() {
  local count
  if [ -n "${SLEEP_SIGNAL:-}" ]; then
    kill -s "${SLEEP_SIGNAL}" "$$"
  fi
  SECONDS=$((SECONDS + $1))
  count=$(($(cat "${SLEEP_COUNT}") + 1))
  printf '%s\n' "${count}" > "${SLEEP_COUNT}"
  printf '%s\n' "${SECONDS}" > "${SLEEP_CLOCK}"
  if [ "${count}" = "${PUBLISH_ON_SLEEP:-}" ] ||
    { [ -n "${PUBLISH_AT:-}" ] &&
      [ "${SECONDS}" -ge "${PUBLISH_AT}" ]; }; then
    GIT_DIR="${FIXTURE_ORIGIN}/.git" git update-ref refs/heads/master \
      "${FIXTURE_REVISION}"
  fi
}
export -f sleep

# A 'git' wrapper that records, on each fetch, the scratch
# repository's extra headers and the refs it holds; fails the first
# FAIL_TIMES fetches with the message FAIL_MESSAGE, as a remote would;
# and stalls the command named by STALL with a real sleep. Everything
# else reaches the real git. STALL matches the start of the arguments.
wrap_bin="${workdir}/wrap-bin"
mkdir -p "${wrap_bin}"
cat > "${wrap_bin}/git" << EOF
#!/usr/bin/env bash
real='$(command -v git)'
if [ "\${1:-}" = fetch ]; then
  "\${real}" config --get-regexp '^http\..*\.extraheader\$' \
    >> "\${HEADER_LOG}" || true
  printf 'fetch\n' >> "\${REFS_LOG}"
  "\${real}" for-each-ref --format='%(refname)' >> "\${REFS_LOG}"
  count=\$((\$(cat "\${FAIL_COUNT}") + 1))
  printf '%s\n' "\${count}" > "\${FAIL_COUNT}"
  if [ "\${count}" -le "\${FAIL_TIMES:-0}" ]; then
    printf '%s\n' "\${FAIL_MESSAGE}" >&2
    exit 128
  fi
fi
if [ -n "\${STALL:-}" ]; then
  case "\$*" in
    "\${STALL}"*) exec /usr/bin/env sleep 60 ;;
  esac
fi
exec "\${real}" "\$@"
EOF
chmod +x "${wrap_bin}/git"

token='fixture-token-0123456789'

# run_wait <label> <tip at start> <publish on sleep N, or empty>
# <revision to publish> [script] [command to stall]: sets wait_rc,
# wait_log, wait_sleeps, wait_clock (the wait's clock after its last
# sleep), wait_secs, wait_sha and temp, the RUNNER_TEMP the wait ran
# in. From the caller's environment, PUBLISH_AT publishes by clock;
# WAIT_REF and WAIT_REPOSITORY replace the deploy branch and the
# repository; FAIL_TIMES and FAIL_MESSAGE fail fetches; and
# SLEEP_SIGNAL signals the wait at its first sleep.
run_wait() {
  git -C "${origin}" update-ref refs/heads/master "$2"
  temp="${workdir}/temp-$1"
  mkdir -p "${temp}"
  local out="${workdir}/output-$1" started=${SECONDS}
  : > "${out}"
  : > "${workdir}/headers"
  : > "${workdir}/refs"
  printf '0\n' > "${workdir}/fetch-count"
  printf '0\n' > "${workdir}/sleeps"
  printf '0\n' > "${workdir}/clock"
  wait_rc=0
  wait_log=$(cd "${workdir}" && PATH="${wrap_bin}:${PATH}" \
    STALL="${6:-}" HEADER_LOG="${workdir}/headers" \
    REFS_LOG="${workdir}/refs" FAIL_COUNT="${workdir}/fetch-count" \
    FAIL_TIMES="${FAIL_TIMES:-0}" FAIL_MESSAGE="${FAIL_MESSAGE:-}" \
    SLEEP_SIGNAL="${SLEEP_SIGNAL:-}" \
    FIXTURE_ORIGIN="${origin}" FIXTURE_REVISION="$4" \
    SLEEP_COUNT="${workdir}/sleeps" SLEEP_CLOCK="${workdir}/clock" \
    PUBLISH_ON_SLEEP="$3" PUBLISH_AT="${PUBLISH_AT:-}" \
    RUNNER_TEMP="${temp}" GITHUB_OUTPUT="${out}" \
    SERVER_URL="${mirror}" \
    REPOSITORY="${WAIT_REPOSITORY:-org/ci-management}" \
    AUTH_TOKEN="${token}" DEPLOY_REF="${WAIT_REF:-refs/heads/master}" \
    MERGED_REVISION="${merged}" \
    bash -euo pipefail "${5:-${wait_script}}" 2>&1) || wait_rc=$?
  wait_secs=$((SECONDS - started))
  wait_sleeps=$(cat "${workdir}/sleeps")
  wait_clock=$(cat "${workdir}/clock")
  wait_sha=$(sed -n 's/^sha=//p' "${out}")
  wait_fetches=$(cat "${workdir}/fetch-count")
}

# expect_clean <label>: the scratch repository is gone and the token
# never reached the log.
expect_clean() {
  if [ -n "$(ls -A "${temp}")" ]; then
    fail "$1: the scratch repository was left behind" "$(ls -A "${temp}")"
  elif grep -qF "${token}" <<< "${wait_log}"; then
    fail "$1: the log carries the token" "${wait_log}"
  else
    pass
  fi
}

# Already replicated: one fetch, no wait, and the tip is the output.
run_wait present "${merged}" '' "${merged}"
if [ "${wait_rc}" -ne 0 ] || [ "${wait_sleeps}" -ne 0 ]; then
  fail 'wait, already replicated: expected success with no wait' \
    "${wait_log}"
elif [ "${wait_sha}" != "${merged}" ]; then
  fail "wait, already replicated: sha '${wait_sha}', expected merged" \
    "${wait_log}"
else
  pass
fi
expect_clean 'wait, already replicated'

# The fetch authenticates as the checkout would: the job token,
# through an extra header in the scratch repository's own config.
basic=$(printf 'x-access-token:%s' "${token}" | base64 -w 0)
header="http.${mirror}/.extraheader AUTHORIZATION: basic ${basic}"
if grep -qxF "${header}" "${workdir}/headers"; then
  pass
else
  fail 'wait: the fetch carried no token header' \
    "$(cat "${workdir}/headers")"
fi

# Arrives on the fourth fetch, after three waits.
run_wait late "${base}" 3 "${merged}"
if [ "${wait_rc}" -ne 0 ]; then
  fail "wait, late arrival: exit ${wait_rc}, expected 0" "${wait_log}"
elif [ "${wait_sleeps}" -ne 3 ]; then
  fail "wait, late arrival: ${wait_sleeps} waits, expected 3" "${wait_log}"
elif [ "${wait_sha}" != "${merged}" ]; then
  fail "wait, late arrival: sha '${wait_sha}', expected merged" \
    "${wait_log}"
else
  pass
fi
expect_clean 'wait, late arrival'

# Each fetch after the first starts from the commits already fetched:
# the scratch repository keeps the deploy branch in a remote-tracking
# ref, so the fetch offers that history rather than downloading it
# again.
retained=$(grep -cx 'refs/remotes/origin/deploy' "${workdir}/refs" || true)
if [ "${wait_fetches}" -ne 4 ] || [ "${retained}" -ne 3 ]; then
  fail "wait: ${retained} of ${wait_fetches} fetches held the deploy" \
    "branch's ref, expected 3 of 4" "$(cat "${workdir}/refs")"
else
  pass
fi

# The branch moves on past the merged revision during the wait: the
# output is the tip that passed, and it contains the merged revision.
run_wait moved "${base}" 2 "${later}"
if [ "${wait_rc}" -ne 0 ]; then
  fail "wait, branch moved on: exit ${wait_rc}, expected 0" "${wait_log}"
elif [ "${wait_sha}" != "${later}" ]; then
  fail "wait, branch moved on: sha '${wait_sha}', expected the tip" \
    "${wait_log}"
elif ! git -C "${origin}" merge-base --is-ancestor "${merged}" \
  "${wait_sha}"; then
  fail 'wait, branch moved on: the output lacks the merged revision' \
    "${wait_log}"
else
  pass
fi

# The deploy branch is rewritten during the wait: its first tip is not
# an ancestor of the next. The forced update takes the new tip, which
# holds the merged revision, and the output is that tip.
run_wait rewritten "${rewritten}" 1 "${merged}"
if [ "${wait_rc}" -ne 0 ]; then
  fail "wait, branch rewritten: exit ${wait_rc}, expected 0" "${wait_log}"
elif [ "${wait_sha}" != "${merged}" ]; then
  fail "wait, branch rewritten: sha '${wait_sha}', expected merged" \
    "${wait_log}"
else
  pass
fi
expect_clean 'wait, branch rewritten'

# Two fetches fail as a network error does: the wait retries them and
# finds the revision on the third.
FAIL_TIMES=2 FAIL_MESSAGE="fatal: unable to access '${mirror}/': Could not resolve host: example.invalid" \
  run_wait network "${merged}" '' "${merged}"
if [ "${wait_rc}" -ne 0 ]; then
  fail "wait, network error: exit ${wait_rc}, expected 0" "${wait_log}"
elif [ "${wait_sleeps}" -ne 2 ] || [ "${wait_sha}" != "${merged}" ]; then
  fail "wait, network error: ${wait_sleeps} waits and sha" \
    "'${wait_sha}', expected 2 and merged" "${wait_log}"
else
  pass
fi
expect_clean 'wait, network error'

# A failure that waiting cannot heal ends the wait at once, after one
# fetch and no sleep, with its own cause and not the mirror's.
# expect_refused <label> <message>
expect_refused() {
  if [ "${wait_rc}" -eq 0 ]; then
    fail "$1: expected a failure" "${wait_log}"
  elif [ "${wait_fetches}" -ne 1 ] || [ "${wait_sleeps}" -ne 0 ]; then
    fail "$1: ${wait_fetches} fetches and ${wait_sleeps} waits," \
      "expected 1 and 0" "${wait_log}"
  elif ! grep -qF "::error::$2" <<< "${wait_log}"; then
    fail "$1: no error saying '$2'" "${wait_log}"
  elif grep -qF 'mirror has not replicated' <<< "${wait_log}"; then
    fail "$1: blamed the mirror's replication" "${wait_log}"
  elif [ -n "${wait_sha}" ]; then
    fail "$1: wrote sha '${wait_sha}'" "${wait_log}"
  else
    pass
  fi
  expect_clean "$1"
}

WAIT_REF='refs/heads/missing' run_wait no-branch "${merged}" '' "${merged}"
expect_refused 'wait, missing deploy branch' \
  'The mirror of org/ci-management has no refs/heads/missing'

WAIT_REPOSITORY='org/missing' run_wait no-repository "${merged}" '' \
  "${merged}"
expect_refused 'wait, missing repository' 'Fetching org/missing was refused'

for message in \
  "fatal: Authentication failed for 'https://github.com/org/ci-management/'" \
  "fatal: could not read Username for 'https://github.com': terminal prompts disabled" \
  "fatal: unable to access 'https://github.com/org/ci-management/': The requested URL returned error: 403" \
  "remote: Repository not found." \
  "fatal: repository 'https://github.com/org/ci-management/' not found"; do
  FAIL_TIMES=1 FAIL_MESSAGE="${message}" \
    run_wait refused "${merged}" '' "${merged}"
  expect_refused "wait, refused (${message})" \
    'Fetching org/ci-management was refused'
done

# A signal during the wait still removes the scratch repository and
# its token header, and writes no output.
for signal in TERM INT HUP; do
  SLEEP_SIGNAL="${signal}" run_wait "signal-${signal}" "${base}" '' \
    "${merged}"
  if [ "${wait_rc}" -eq 0 ] || [ -n "${wait_sha}" ]; then
    fail "wait, ${signal}: exit ${wait_rc} and sha '${wait_sha}'," \
      'expected a failure and none' "${wait_log}"
  else
    pass
  fi
  expect_clean "wait, ${signal}"
done

# Never arrives, although the mirror holds the commit on another
# branch: fails after the bounded number of waits, naming the mirror,
# with no output.
run_wait never "${base}" '' "${merged}"
if [ "${wait_rc}" -eq 0 ]; then
  fail 'wait, never arrives: expected a failure' "${wait_log}"
elif ! grep -qF '::error::' <<< "${wait_log}" ||
  ! grep -qF 'mirror has not replicated' <<< "${wait_log}"; then
  fail 'wait, never arrives: no error naming the mirror' "${wait_log}"
elif [ "${wait_sleeps}" -ne 8 ]; then
  fail "wait, never arrives: ${wait_sleeps} waits, expected 8" \
    "${wait_log}"
elif [ -n "${wait_sha}" ]; then
  fail "wait, never arrives: wrote sha '${wait_sha}'" "${wait_log}"
elif [ "${wait_clock}" -ge 300 ]; then
  fail "wait, never arrives: the last wait ended at ${wait_clock}s," \
    "leaving no time for a final fetch" "${wait_log}"
else
  pass
fi
expect_clean 'wait, never arrives'

# Arrives late, at 270 seconds on the wait's clock, after the backoff
# has run past the last full delay. The final wait must stop short of
# the deadline and leave time for one more fetch and ancestry check,
# which finds the revision.
PUBLISH_AT=270 run_wait deadline "${base}" '' "${merged}"
if [ "${wait_rc}" -ne 0 ]; then
  fail "wait, arrives near the deadline: exit ${wait_rc}, expected 0" \
    "${wait_log}"
elif [ "${wait_clock}" -lt 270 ] || [ "${wait_clock}" -ge 300 ]; then
  fail "wait, arrives near the deadline: last wait ended at" \
    "${wait_clock}s, expected 270 to 299" "${wait_log}"
elif [ "${wait_sha}" != "${merged}" ]; then
  fail "wait, arrives near the deadline: sha '${wait_sha}'," \
    "expected merged" "${wait_log}"
else
  pass
fi
expect_clean 'wait, arrives near the deadline'

# A fetch that never returns ends at the deadline. The bound shrinks
# to two seconds in a copy of the script, and the wrapper stalls every
# fetch with a real sleep. The step fails naming the mirror.
short_wait="${workdir}/wait-short.sh"
sed 's/^limit=300$/limit=2/' "${wait_script}" > "${short_wait}"
if cmp -s "${wait_script}" "${short_wait}"; then
  fail "wait: no 'limit=300' line to shorten in the extracted script"
fi
run_wait stall "${base}" 1 "${merged}" "${short_wait}" fetch
if [ "${wait_rc}" -eq 0 ]; then
  fail 'wait, stalled fetch: expected a failure' "${wait_log}"
elif [ "${wait_secs}" -ge 30 ]; then
  fail "wait, stalled fetch: took ${wait_secs}s" "${wait_log}"
elif ! grep -qF 'mirror has not replicated' <<< "${wait_log}"; then
  fail 'wait, stalled fetch: no error naming the mirror' "${wait_log}"
elif [ -n "${wait_sha}" ]; then
  fail "wait, stalled fetch: wrote sha '${wait_sha}'" "${wait_log}"
else
  pass
fi
expect_clean 'wait, stalled fetch'

# Any other git command that never returns also ends at the deadline,
# with an error naming it rather than the mirror. The bound is four
# seconds here, so the fetches before the stall finish well inside it.
slow_wait="${workdir}/wait-slow.sh"
sed 's/^limit=300$/limit=4/' "${wait_script}" > "${slow_wait}"
for command in init config rev-parse merge-base; do
  run_wait "stall-${command}" "${base}" '' "${merged}" "${slow_wait}" \
    "${command}"
  if [ "${wait_rc}" -eq 0 ]; then
    fail "wait, stalled ${command}: expected a failure" "${wait_log}"
  elif [ "${wait_secs}" -ge 30 ]; then
    fail "wait, stalled ${command}: took ${wait_secs}s" "${wait_log}"
  elif ! grep -qF "::error::The wait reached its 4s limit at 'git ${command}'" \
    <<< "${wait_log}"; then
    fail "wait, stalled ${command}: no deadline error naming it" \
      "${wait_log}"
  elif grep -qF 'mirror has not replicated' <<< "${wait_log}"; then
    fail "wait, stalled ${command}: blamed the mirror" "${wait_log}"
  elif [ -n "${wait_sha}" ]; then
    fail "wait, stalled ${command}: wrote sha '${wait_sha}'" "${wait_log}"
  else
    pass
  fi
  expect_clean "wait, stalled ${command}"
done

# Every git command in the wait runs through 'bounded', so none can
# outlast the deadline. Report any line that calls git directly,
# skipping comments and quoted text.
unbounded=$(sed 's/"[^"]*"//g' "${wait_script}" |
  grep -nE '(^|[[:space:];|&(])git ' |
  grep -vE '^[0-9]+:[[:space:]]*#' |
  grep -vE '(bounded|prepare) git ' || true)
if [ -z "${unbounded}" ]; then
  pass
else
  fail "wait: a git command runs outside 'bounded'" "${unbounded}"
fi

# The waits the script would take sum to five minutes at most.
total_wait=$(sed -n 's/^delays=(\(.*\))$/\1/p' "${wait_script}" |
  tr ' ' '\n' | awk '{ sum += $1 } END { print sum + 0 }')
if [ "${total_wait}" -gt 0 ] && [ "${total_wait}" -le 300 ]; then
  pass
else
  fail "wait: the delays sum to ${total_wait}s, expected 1 to 300"
fi

# --- Summary --------------------------------------------------------

total=$((passed + failed))
if [ "${failed}" -ne 0 ]; then
  echo "${failed} of ${total} ci-management merge fixture(s) failed" >&2
  exit 1
fi
echo "All ${total} ci-management merge fixtures passed"
