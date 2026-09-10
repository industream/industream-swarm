#!/usr/bin/env bash
# Disables Logto's Have I Been Pwned password check, which makes user creation
# fail with a 500 on a site with no egress. Idempotent; no restart needed.
#
# EVERY tenant is updated: the Admin Console signs in against `admin`, which is
# not editable from the console UI.
set -euo pipefail

CONTAINER=""
CHECK_ONLY=false

die() { printf '\033[0;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
info() { printf '▶ %s\n' "$1"; }
ok() { printf '\033[0;32m✓ %s\033[0m\n' "$1"; }

usage() {
  cat <<'USAGE'
Usage: logto-airgap-password-policy.sh [--check] [--container <id|name>]

  --check              report the current policy and exit; change nothing
  --container <ref>    use this container instead of auto-detecting it
                       (needed only when several Logto databases run on the host)

Run it on the site's Docker host — swarm or compose, it detects either.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)     CHECK_ONLY=true; shift ;;
    --container) CONTAINER="${2:?--container needs a value}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage >&2; die "unknown argument: $1" ;;
  esac
done

command -v docker >/dev/null || die "docker not found — run this on the site's Docker host"

# --- Locate Logto's database -------------------------------------------------
# Matching the middle substring covers both the swarm and compose naming schemes.
if [[ -z "$CONTAINER" ]]; then
  mapfile -t found < <(docker ps --filter "name=logto-postgres" --format '{{.ID}} {{.Names}}')
  case "${#found[@]}" in
    0) die "no running container matching 'logto-postgres' — is the stack up? (docker ps | grep logto)" ;;
    1) CONTAINER="${found[0]%% *}"
       info "database container: ${found[0]#* } (${CONTAINER})" ;;
    *) printf '  %s\n' "${found[@]}" >&2
       die "several candidates — re-run with --container <id>" ;;
  esac
fi

docker exec "$CONTAINER" psql -U postgres -d logto -c '\q' >/dev/null 2>&1 \
  || die "cannot reach the logto database inside $CONTAINER (tried: psql -U postgres -d logto)"

# A null `pwned` means Logto applies its own default, which is `true`.
show_state() {
  docker exec "$CONTAINER" psql -U postgres -d logto -tA -F' ' -c \
    "SELECT tenant_id, coalesce(password_policy->'rejects'->>'pwned', 'true (Logto default)')
       FROM sign_in_experiences ORDER BY tenant_id;"
}

info "current state (tenant → HIBP check enabled)"
show_state | sed 's/^/    /'

if [[ "$CHECK_ONLY" == true ]]; then
  info "--check: nothing was changed"
  exit 0
fi

# Not jsonb_set: with password_policy '{}' it would not create the missing
# `rejects` key, leaving the row unchanged and reporting success.
info "disabling the Have I Been Pwned check on every tenant"
docker exec -i "$CONTAINER" psql -U postgres -d logto -v ON_ERROR_STOP=1 -q -f - <<'SQL'
UPDATE sign_in_experiences
   SET password_policy = password_policy || jsonb_build_object(
         'rejects',
         coalesce(password_policy -> 'rejects', '{}'::jsonb) || '{"pwned": false}'::jsonb
       );
SQL

# Read back rather than trust the exit code: an UPDATE matching zero rows exits 0.
info "verifying"
show_state | sed 's/^/    /'

remaining="$(docker exec "$CONTAINER" psql -U postgres -d logto -tAc \
  "SELECT count(*) FROM sign_in_experiences
    WHERE coalesce(password_policy->'rejects'->>'pwned', 'true') <> 'false';")"

[[ "$remaining" == "0" ]] \
  || die "$remaining tenant(s) still have the check enabled — the update did not take"

ok "every tenant now skips the Have I Been Pwned check"
echo
echo "  No restart needed: Logto reads the sign-in experience on every request."
echo "  Creating a user should now work. If it still fails, the cause is NOT this"
echo "  check — capture the container log and look at what the 500 actually says:"
echo "    docker service logs --tail 50 \$(docker service ls --format '{{.Name}}' | grep -E '_logto\$')"
