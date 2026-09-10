#!/usr/bin/env bash
# On an air-gapped EE site, Logto's Have I Been Pwned check makes creation of
# the FIRST admin user answer 500 — the console is then unreachable and the site
# unusable. deploy.sh already knows it is EE, already finds logto-postgres and
# already waits for it, so --airgap applies the fix there rather than leaving it
# to an operator who has to know it exists.
#
# Online sites keep the check: it works there, and it is a real protection.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

# The marker is the script's own wording, not a word deploy.sh already prints:
# "Logto" alone matches its existing "▶ EE seeders (Logto app/roles/user …)"
# banner, so asserting on that passes whether or not anything was applied.
MARKER="Have I Been Pwned"

# The three deploys run concurrently: each one crosses deploy.sh's hardcoded
# 30 × 2s wait for logto-postgres, which the docker stub can never satisfy, so
# sequentially they cost three minutes of pure sleeping.
run_deploy() {  # run_deploy <out-file> <edition> [extra flags…]
  local out="$1" edition="$2"; shift 2
  DEPLOY_TIMEOUT=1 with_docker_stub ./scripts/deploy.sh \
    --runtime swarm --edition "$edition" --env prod --bundle 1.0.1 \
    --stack test-logto "$@" >"$out" 2>&1 || true
}

f_airgap="$(mktemp)"; f_online="$(mktemp)"; f_ce="$(mktemp)"
run_deploy "$f_airgap" ee --airgap &
run_deploy "$f_online" ee &
run_deploy "$f_ce" ce --airgap &
wait

assert_contains "$(cat "$f_airgap")" "$MARKER" \
  "an air-gapped EE deploy disables the Have I Been Pwned check"

out_online="$(cat "$f_online")"
[[ "$out_online" != *"$MARKER"* ]] \
  || fail "an online EE deploy must leave the check alone: it can reach the API, and it is a real protection"
pass "an online EE deploy leaves the Have I Been Pwned check alone"

out_ce="$(cat "$f_ce")"
[[ "$out_ce" != *"$MARKER"* ]] \
  || fail "CE ships no Logto — touching a database that is not there would be a confusing failure"
pass "an air-gapped CE deploy leaves Logto alone"

# The script has to be on the site to be runnable there, and install.sh writes
# the tree from `git archive`, so a file that is not tracked never arrives.
[[ -x "$REPO_ROOT/scripts/setup/logto-airgap-password-policy.sh" ]] \
  || fail "the policy script must be tracked and executable so it ships in the bundle tree"
pass "the policy script is tracked and executable"
