#!/usr/bin/env bash
# =============================================================================
# deploy.sh — the ONE assembler for the unified deploy tree.
# =============================================================================
# Builds the compose-file list from {edition, runtime, flags}, sources the single
# env sources, then dispatches: `docker compose up` (compose) or render →
# `docker stack deploy` (swarm). Same base/ + overlays for all 4 deploys.
#
#   ./deploy.sh --runtime swarm   --edition ee --env prod --bundle 1.0.1 --stack industream-prod
#   ./deploy.sh --runtime compose --edition ce --env dev  --bundle 1.0.1 --project fm-dev
#
# --bundle <ver> picks releases/bundle-platform-<ver>/ (the full-ref ${X_IMAGE}
# vars). Omit it when exactly one bundle exists (auto-selected).
#
# --forge <exportKey>@<version> | --forge-interactive downloads a bundle's .env.*
# from the Forge API (RELEASE_FORGE_URL) into releases/ and uses it as $BUNDLE —
# Forge is just a bundle SOURCE. See scripts/forge-bundle.sh.
#
# --workers "svcA,svcB,…" deploys ONLY those flow-box workers (subset of the
# `workers`/`workers-premium` groups); omit it to deploy every worker in the
# selected groups. Client custom/ worker overlays are never filtered.
#
# The CLI thin driver (industream-cli) calls this same logic. Plain Compose-Spec
# → the assembly is also reproducible by hand (BSL / CE no-CLI fallback).
#
# WIP: post-deploy seeders (Logto app/user + launchpad) wired in Phase 4.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # unified/
RUNTIME="" EDITION="ce" ENV="prod" STACK="" PROJECT="" COMMUNITY=false RENDER=false LIST_IMAGES=false PRINT_GROUPS=false AIRGAP=false BUNDLE=""
FORGE_SPEC="" FORGE_INTERACTIVE=false   # --forge <exportKey>@<version> | --forge-interactive
WORKERS_ENABLED=""   # CSV allowlist of flow-box worker services; empty = all
TYPE="" ATTACH=false
# GROUP_SET = the base/<group>.yml set to assemble. Default = full platform; an
# instance footprint narrows it (e.g. a core-only or a workers-only instance, T3).
GROUP_SET="core flowmaker datacatalog workers data monitoring"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)   RUNTIME="$2"; shift 2 ;;
    --edition)   EDITION="$2"; shift 2 ;;
    --env)       ENV="$2"; shift 2 ;;
    --stack)     STACK="$2"; shift 2 ;;
    --project)   PROJECT="$2"; shift 2 ;;
    --community) COMMUNITY=true; shift ;;
    --bundle)    BUNDLE="$2"; shift 2 ;;
    --forge)     FORGE_SPEC="$2"; shift 2 ;;
    --forge-interactive) FORGE_INTERACTIVE=true; shift ;;
    --groups)    GROUP_SET="$2"; shift 2 ;;
    --workers)   WORKERS_ENABLED="$2"; shift 2 ;;
    --type)      TYPE="$2"; shift 2 ;;
    --render)    RENDER=true; shift ;;
    --list-images) LIST_IMAGES=true; shift ;;
    --print-groups) PRINT_GROUPS=true; shift ;;
    --airgap)    AIRGAP=true; shift ;;
    -h|--help)   sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ "$RUNTIME" == swarm || "$RUNTIME" == compose ]] || { echo "✗ --runtime swarm|compose required" >&2; exit 1; }
[[ "$EDITION" == ce || "$EDITION" == ee ]]         || { echo "✗ --edition ce|ee required" >&2; exit 1; }

# ---- TYPE: core/workers split-stack footprint (deployment-v2 model) ---------
# --type core    = the platform MINUS workers (it creates the platform network).
# --type workers = base/workers.yml ALONE, ATTACHING to an existing core's
#                  ${FM_ATTACHED_CORE}-platform overlay — so a 2nd workers stack
#                  with newer worker versions registers with the SAME scheduler
#                  (canary/parallel). On compose the attach is already native
#                  (workers join the external ${FM_NETWORK} / flowmaker-net).
case "$TYPE" in
  core)    GROUP_SET="core flowmaker datacatalog data monitoring" ;;
  workers) GROUP_SET="workers"; ATTACH=true ;;
  "")      : ;;   # full platform, or an explicit --groups
  *) echo "✗ --type core|workers" >&2; exit 1 ;;
esac
# Which core a workers stack joins. David's convention: an env var (FM_ATTACHED_CORE),
# defaulting to this deploy's ENV. Exported so swarm `stack deploy` interpolates the
# external network name (flat — stack deploy can't nest ${A:-${B}}).
export FM_ATTACHED_CORE="${FM_ATTACHED_CORE:-$ENV}"
cd "$HERE"

# ---- EE gate: Enterprise-only, opt-in groups --------------------------------
# These groups are NOT in the default GROUP_SET and may only be assembled under
# --edition ee:
#   - timescale       : TimescaleDB store (CE uses InfluxDB via the `data` group).
#   - workers-premium : the 4 enterprise flow-box workers (opc-ua / rtsp /
#                       luminosity / minio-sink), pulled from ENTERPRISE_REGISTRY.
#   - ironstream      : the IronStream domain apps (material-catalog / recipe-maker
#                       / burden-descent / burden-layer / raceway). A SPECIAL
#                       licensed module — EE alone is NOT enough: it ships ONLY
#                       when explicitly `--groups …ironstream…`, NEVER by default
#                       (absent from every default GROUP_SET above). The CLI is
#                       expected to gate it further on the license entitlement
#                       (JWT `modules` list) before ever adding it here.
# Reject any of them present in GROUP_SET unless --edition ee.
EE_ONLY_GROUPS="timescale workers-premium ironstream data-simulator"
if [[ "$EDITION" != ee ]]; then
  for _g in $EE_ONLY_GROUPS; do
    if [[ " $GROUP_SET " == *" $_g "* ]]; then
      echo "✗ the '$_g' group is Enterprise-only — use --edition ee" >&2
      exit 1
    fi
  done
fi

# ---- FORGE: materialize a bundle from the Forge API (optional source) --------
# --forge <exportKey>@<version> (non-interactive, CI-friendly) or
# --forge-interactive (menu) download a release bundle's .env.* from Forge into
# releases/bundle-platform-forge-<…>/ and set $BUNDLE to it. Forge is just a
# SOURCE — the assembled deploy below consumes the bundle exactly like a local
# render-bundles.sh one. Mutually exclusive with an explicit --bundle.
if [[ "$FORGE_INTERACTIVE" == true || -n "$FORGE_SPEC" ]]; then
  [[ "$FORGE_INTERACTIVE" == true && -n "$FORGE_SPEC" ]] && { echo "✗ use --forge OR --forge-interactive, not both" >&2; exit 1; }
  [[ -n "$BUNDLE" ]] && { echo "✗ --bundle is incompatible with --forge/--forge-interactive (Forge sets the bundle)" >&2; exit 1; }
  if [[ "$FORGE_INTERACTIVE" == true ]]; then
    BUNDLE="$(scripts/forge-bundle.sh interactive)" || { echo "✗ Forge bundle selection failed" >&2; exit 1; }
  else
    # exportKey@version — '@' splits on the LAST occurrence so an exportKey may contain none.
    _fk="${FORGE_SPEC%@*}"; _fv="${FORGE_SPEC##*@}"
    [[ -n "$_fk" && -n "$_fv" && "$_fk" != "$_fv" ]] || { echo "✗ --forge expects <exportKey>@<version> (got '$FORGE_SPEC')" >&2; exit 1; }
    BUNDLE="$(scripts/forge-bundle.sh fetch "$_fk" "$_fv")" || { echo "✗ Forge bundle download failed" >&2; exit 1; }
  fi
  [[ -n "$BUNDLE" ]] || { echo "✗ Forge returned no bundle key" >&2; exit 1; }
  echo "▶ Forge bundle materialized: bundle-platform-${BUNDLE}"
fi

# ---- BUNDLE: resolve the release bundle holding the full-ref ${X_IMAGE} vars -
# base/*.yml reference ${HUB_API_IMAGE}, ${WORKER_*_IMAGE}, … which live ONLY in
# a release bundle (scripts/render-bundles.sh renders them license-aware from
# versions.env + registries.env). --bundle <ver> selects one; with exactly one
# bundle present it auto-selects; otherwise --bundle is required.
if [[ -n "$BUNDLE" ]]; then
  BUNDLE_DIR="releases/bundle-platform-${BUNDLE}"
  [[ -d "$BUNDLE_DIR" ]] || { echo "✗ no bundle at ${BUNDLE_DIR} — run: scripts/render-bundles.sh ${BUNDLE}" >&2; exit 1; }
else
  mapfile -t _bundles < <(ls -d releases/bundle-platform-*/ 2>/dev/null)
  case ${#_bundles[@]} in
    1) BUNDLE_DIR="${_bundles[0]%/}" ;;
    0) echo "✗ no release bundle in releases/ — run: scripts/render-bundles.sh <version>" >&2; exit 1 ;;
    *) echo "✗ multiple bundles in releases/ — pass --bundle <version>" >&2; exit 1 ;;
  esac
fi

# ---- ENV: the single sources, in order (later wins) -------------------------
ENV_FILES=(--env-file registries.env --env-file versions.env --env-file auth.env --env-file "runtime.${RUNTIME}.env")
for bf in "$BUNDLE_DIR"/.env.*; do ENV_FILES+=(--env-file "$bf"); done
[[ -f ".env.${ENV}" ]] && ENV_FILES+=(--env-file ".env.${ENV}")

# ---- FILES: neutral base + per-runtime overlays (group-selectable) ----------
FILES=()
for b in $GROUP_SET; do
  [[ -f "base/${b}.yml" ]] || { echo "✗ unknown group '${b}' (no base/${b}.yml)" >&2; exit 1; }
  FILES+=(-f "base/${b}.yml")
  [[ -f "runtime/${RUNTIME}/${b}.yml" ]] && FILES+=(-f "runtime/${RUNTIME}/${b}.yml")
done
# datacatalog increment-1 top-level overlay (until folded into runtime/<r>/) —
# only when the datacatalog group is in scope (else it merges onto a missing svc).
[[ -f "runtime.${RUNTIME}.yml" && " $GROUP_SET " == *" datacatalog "* ]] && FILES+=(-f "runtime.${RUNTIME}.yml")
# EE transform last (overrides win)
if [[ "$EDITION" == ee ]]; then
  FILES+=(-f "base/ee.yml")
  [[ -f "runtime/${RUNTIME}/ee.yml" ]] && FILES+=(-f "runtime/${RUNTIME}/ee.yml")
fi
# workers-attach (swarm): the platform overlay then declares the network EXTERNAL
# (the target core's ${FM_ATTACHED_CORE}-platform) instead of creating one, so the
# workers stack lands on the core's scheduler. (compose attaches natively.)
if [[ "$ATTACH" == true && "$RUNTIME" == swarm ]]; then
  FILES+=(-f "runtime/swarm/_platform-attach.yml")
fi
# user-custom overlays (OPTIONAL) — appended LAST so user files override
# everything: platform base/, runtime overlays AND the EE transform. Drop your
# own *.yml under custom/ (runtime-neutral) or custom/<RUNTIME>/ (runtime-specific)
# to add services/workers or override platform ones WITHOUT forking. See
# custom/README.md. No-op when the dir/files are absent.
# nullglob makes a non-matching glob expand to NOTHING (not the literal pattern),
# so an absent custom/ dir yields empty arrays → a clean no-op. Bash expands
# globs already sorted, so neutral overlays precede their runtime-specific peers.
shopt -s nullglob
_custom_neutral=(custom/*.yml)
_custom_runtime=("custom/${RUNTIME}"/*.yml)
shopt -u nullglob
CUSTOM_FILES=("${_custom_neutral[@]}" "${_custom_runtime[@]}")
for cf in "${CUSTOM_FILES[@]}"; do FILES+=(-f "$cf"); done

# Progress banner, not data — sent to stderr so `--list-images`'s stdout is
# strictly the resolved image list (its designated single source of truth).
echo "▶ ${EDITION^^} / ${RUNTIME} / env=${ENV} / bundle=${BUNDLE_DIR##*/} / groups=[${GROUP_SET}]" >&2
echo "  files: ${FILES[*]//-f /}" >&2
[[ ${#CUSTOM_FILES[@]} -gt 0 ]] && echo "  custom overlays: ${CUSTOM_FILES[*]}" >&2

# ---- Per-worker selection (OPTIONAL) ----------------------------------------
# --workers "svcA,svcB,…" deploys ONLY those flow-box workers; empty = every
# worker in the selected groups (backward-compatible default). The CLI computes
# the list (CE: user multi-select; EE: license entitlements ∪ community choice).
# We rewrite ONLY the platform worker maps — base/workers*.yml + their runtime
# overlays — into temp files and swap them into FILES. Anchors live at the top
# level (x-worker/&worker-env), so dropping service entries is safe. Files NOT
# named workers*.yml are untouched, so client custom/ worker overlays are NEVER
# filtered — they always deploy.
if [[ -n "$WORKERS_ENABLED" ]]; then
  _wtmp="$(mktemp -d)"
  _newFILES=(); _i=0
  while [[ $_i -lt ${#FILES[@]} ]]; do
    if [[ "${FILES[$_i]}" == -f ]]; then
      _wf="${FILES[$((_i+1))]}"; _wb="$(basename "$_wf")"
      if [[ "$_wb" == workers.yml || "$_wb" == workers-premium.yml ]]; then
        _wout="$_wtmp/${_wf//\//_}"
        if WORKERS_CSV="$WORKERS_ENABLED" python3 - "$_wf" "$_wout" <<'PY'
import os, sys, yaml
src, out = sys.argv[1], sys.argv[2]
keep = {w.strip() for w in os.environ.get("WORKERS_CSV", "").split(",") if w.strip()}
doc = yaml.safe_load(open(src)) or {}
svcs = doc.get("services") or {}
doc["services"] = {n: s for n, s in svcs.items() if n in keep}
if not doc["services"]:
    sys.exit(3)  # nothing kept here → tell the caller to drop the whole file
yaml.safe_dump(doc, open(out, "w"), sort_keys=False)
PY
        then _newFILES+=(-f "$_wout")
        else
          _rc=$?
          [[ $_rc == 3 ]] || { echo "✗ worker filter failed on $_wf" >&2; exit 1; }
          # _rc==3 → drop this file (no selected workers in it)
        fi
        _i=$((_i + 2)); continue
      fi
    fi
    _newFILES+=("${FILES[$_i]}"); _i=$((_i + 1))
  done
  FILES=("${_newFILES[@]}")
  echo "  worker selection: ${WORKERS_ENABLED}"
fi

# ---- Render-only gate (validate the assembled config, deploy nothing) -------
if [[ "$RENDER" == true ]]; then
  if [[ "$RUNTIME" == compose ]]; then
    ENV=$ENV docker compose "${ENV_FILES[@]}" "${FILES[@]}" config
    exit $?
  fi
  # `docker compose config` can't render swarm overlays that use ${ENV} in
  # network-map KEYS (e.g. ${ENV}-platform) — those only interpolate at
  # `stack deploy` time. Validate each file is well-formed YAML instead.
  for f in "${FILES[@]}"; do [[ "$f" == -f ]] && continue
    python3 -c "import yaml; yaml.safe_load(open('$f'))" || { echo "✗ invalid YAML: $f" >&2; exit 1; }
  done
  echo "✓ ${#FILES[@]} swarm file refs are valid YAML (full validation = a live 'stack deploy')"
  exit 0
fi

# ---- Env peek ----------------------------------------------------------------
# Read a variable exactly as the assembled deploy will see it (same file chain,
# same order as ENV_FILES above), WITHOUT exporting anything into this process.
# The compose dispatch deliberately sources the env only AFTER `up -d`, so the
# pre-flight checks below cannot rely on the process env.
peek_env() {
  (
    set -a
    source registries.env; source versions.env; source auth.env; source "runtime.${RUNTIME}.env"
    for bf in "$BUNDLE_DIR"/.env.*; do source "$bf"; done
    [[ -f ".env.${ENV}" ]] && source ".env.${ENV}"
    set +a
    printf '%s' "${!1-}"
  )
}

# ---- Compose EE: FM_DOMAIN and INDUSTREAM_DOMAIN must be the SAME apex -------
# The compose topology is Caddy-fronted and every host label in
# runtime/compose/*.yml derives from ${FM_DOMAIN}, while the base/*.yml files
# (written for swarm) derive from ${INDUSTREAM_DOMAIN}. Under EE the two meet:
# Logto's public ENDPOINT is auth.${INDUSTREAM_DOMAIN} (base/ee.yml) but Caddy
# publishes auth.${FM_DOMAIN} (runtime/compose/ee.yml); Grafana's root_url is
# dashboard.${FM_DOMAIN} but its CSRF/Live origins come from INDUSTREAM_DOMAIN.
# If they diverge, the OIDC issuer no longer matches the reachable host and the
# whole login chain fails with opaque errors. .env.test happens to set both to
# the same value, which is exactly why this never showed up in testing.
# Fail LOUD here rather than silently wrong at runtime (same class as the Forge
# var-name blocker). Swarm is unaffected: it uses INDUSTREAM_DOMAIN throughout.
check_compose_domains() {
  local ind fm
  ind="$(peek_env INDUSTREAM_DOMAIN)"
  fm="$(peek_env FM_DOMAIN)"
  if [[ -z "$ind" || -z "$fm" ]]; then
    echo "✗ compose EE needs BOTH INDUSTREAM_DOMAIN and FM_DOMAIN set (got INDUSTREAM_DOMAIN='${ind}', FM_DOMAIN='${fm}')." >&2
    echo "  base/ee.yml builds Logto's public ENDPOINT from INDUSTREAM_DOMAIN; the Caddy routes use FM_DOMAIN." >&2
    exit 1
  fi
  if [[ "$ind" != "$fm" ]]; then
    echo "✗ compose EE requires INDUSTREAM_DOMAIN == FM_DOMAIN (got '${ind}' vs '${fm}')." >&2
    echo "  Logto is published at auth.\${FM_DOMAIN} but issues tokens for auth.\${INDUSTREAM_DOMAIN};" >&2
    echo "  Grafana's root_url uses FM_DOMAIN and its OIDC/CSRF origins INDUSTREAM_DOMAIN. Set both to the same apex in .env.${ENV}." >&2
    exit 1
  fi
}

# ---- EE: Grafana OIDC client secret (S2) ------------------------------------
# Grafana reads it from /run/secrets/<name> via
# GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET__FILE — never as an env VALUE, which
# `docker service inspect` prints in clear. Canonical home is
# scripts/setup/create-secrets-ee.sh; this function only makes a from-scratch
# deploy hands-off, because a missing external swarm secret aborts the WHOLE
# `stack deploy` and a missing compose `file:` secret aborts `compose up`.
# Idempotent: an existing file/secret is never touched (rotation is a dedicated
# procedure — the value also lives in Logto's applications row).
ensure_grafana_oidc_secret() {
  local canon="$HERE/../secrets/$ENV/grafana_oidc_client_secret"
  mkdir -p "$(dirname "$canon")"; chmod 700 "$(dirname "$canon")" 2>/dev/null || true
  if [[ ! -s "$canon" ]]; then
    openssl rand -hex 32 | tr -d '\n' > "$canon"
    chmod 600 "$canon"
    echo "  ✓ generated secrets/${ENV}/grafana_oidc_client_secret"
  fi
  if [[ "$RUNTIME" == swarm ]]; then
    docker secret inspect "${ENV}_grafana_oidc_client_secret" >/dev/null 2>&1 \
      || { docker secret create "${ENV}_grafana_oidc_client_secret" "$canon" >/dev/null \
           && echo "  ✓ created docker secret ${ENV}_grafana_oidc_client_secret"; }
  else
    # runtime/compose/ee.yml declares `file: ${SECRETS_DIR:-./secrets}/…`. Two
    # gotchas we MUST mirror exactly or the file lands where compose won't look:
    #   - SECRETS_DIR comes from the --env-file chain, not from this process
    #     (compose sources the env only after `up -d`) → peek_env.
    #   - compose resolves a RELATIVE path against the project directory, which
    #     is the directory of the FIRST -f file (unified/base/, not unified/).
    local dir projdir first
    first="${FILES[1]}"                      # FILES = (-f base/<group>.yml …)
    projdir="$(cd "$(dirname "$first")" && pwd)"
    dir="$(peek_env SECRETS_DIR)"
    [[ -z "$dir" ]] && dir="./secrets"
    [[ "$dir" != /* ]] && dir="$projdir/${dir#./}"
    if [[ ! -s "$dir/grafana_oidc_client_secret" ]]; then
      mkdir -p "$dir"
      cp "$canon" "$dir/grafana_oidc_client_secret"
      chmod 600 "$dir/grafana_oidc_client_secret"
      echo "  ✓ staged ${dir}/grafana_oidc_client_secret for compose"
    fi
  fi
}

# ---- Convergence helper -----------------------------------------------------
# List swarm services whose running replicas != desired. Called when the bounded
# `stack deploy` wait times out, so a non-converging deploy names its culprit(s)
# instead of hanging silently.
list_unstable_services() {
  docker stack services "$STACK" --format '{{.Name}} {{.Replicas}}' 2>/dev/null \
    | awk '{ if (split($2,a,"/")==2 && a[1]!=a[2]) print "    ✗ " $1 " (" $2 ")" }' \
    || true
}

# ---- Hub menu apps seeder (BOTH editions) -----------------------------------
# The Hub launchpad menu (flowmaker / datacatalog / grafana / databridge tiles)
# must be seeded for CE *and* EE — a fresh install otherwise shows an EMPTY menu.
# We run the canonical seeder from the REPO (<repo-root>/scripts/setup/
# seed-menu-apps-stack.sh — one level ABOVE unified/, i.e. "$HERE/.."; the previous
# cwd-relative "scripts/setup/…" resolved to unified/scripts/setup/ which does not
# exist, so seeding silently failed and the Hub menu was always empty) against the
# seeder discovers the container itself via --runtime/--stack/--project.
# Best-effort and strictly NON-FATAL — a deploy never fails because seeding did.
seed_menu_apps() {
  local hub_cid i domain scope
  echo ""
  echo "▶ Hub menu apps seeder (launchpad tiles)…"
  # Two-phase readiness, ORDERED to dodge a chicken-and-egg:
  #   1. wait for the hub-backend CONTAINER to exist (deploy returns early), then
  #   2. fix /app/data perms, THEN wait for /apps to answer 200.
  # The perm fix MUST precede the /apps probe: the hub image's /app/data volume
  # initialises root:root while the container runs as node(1000), so /apps 500s
  # (EACCES mkdir '/app/data/hub') until chowned — and `wget` exits non-zero on a
  # 500, so probing /apps BEFORE the chown looped forever ('not ready') and the
  # menu never seeded. (Real fix belongs in the hub image Dockerfile.)
  for i in $(seq 1 60); do
    if [[ "$RUNTIME" == swarm ]]; then
      hub_cid="$(docker ps -q --filter "name=${STACK}_industream-hub-backend" 2>/dev/null | head -1)"
    else
      hub_cid="$(docker ps -q --filter "name=${PROJECT}-industream-hub-backend" 2>/dev/null | head -1)"
      [[ -z "$hub_cid" ]] && hub_cid="$(docker ps -q --filter "name=${PROJECT}_industream-hub-backend" 2>/dev/null | head -1)"
    fi
    [[ -n "$hub_cid" ]] && break
    sleep 2
  done
  [[ -z "$hub_cid" ]] && { echo "  ⚠ hub-backend container not found — skipping menu-apps seeding (non-fatal)" >&2; return 0; }

  docker exec -u 0 "$hub_cid" chown -R node:node /app/data 2>/dev/null || true

  local apps_ready=false
  for i in $(seq 1 30); do
    if docker exec "$hub_cid" wget -qO- http://localhost:3051/apps >/dev/null 2>&1; then apps_ready=true; break; fi
    sleep 2
  done
  [[ "$apps_ready" != true ]] && { echo "  ⚠ hub-backend /apps not ready — skipping menu-apps seeding (non-fatal)" >&2; return 0; }

  # Run the seeder from the REPO (always present, preferred over the image copy).
  domain="${INDUSTREAM_DOMAIN:-localhost}"
  local scope_args=(--domain "$domain" --runtime "$RUNTIME" --groups "$GROUP_SET")
  [[ "$RUNTIME" == swarm ]] && scope_args+=(--stack "$STACK") || scope_args+=(--project "$PROJECT")
  if HUB_BACKEND_SERVICE=industream-hub-backend bash "$HERE/../scripts/setup/seed-menu-apps-stack.sh" "${scope_args[@]}" >/dev/null 2>&1; then
    echo "  ✓ Hub menu apps seeded"
  else
    echo "  ⚠ menu-apps seeding failed (non-fatal)"
  fi

  # Languages (BOTH editions). A fresh Hub knows only the locales that have been
  # POSTed to it, so every install was English-only until someone called the API
  # by hand. Override the set with HUB_LANGUAGES="en:English,de:Deutsch,…".
  # Registering a locale only makes it SELECTABLE — the translations and the
  # language selector ship with the Hub frontend.
  local lang_args=(--runtime "$RUNTIME")
  [[ "$RUNTIME" == swarm ]] && lang_args+=(--stack "$STACK") || lang_args+=(--project "$PROJECT")
  if HUB_BACKEND_SERVICE=industream-hub-backend bash "$HERE/../scripts/setup/seed-hub-languages-stack.sh" "${lang_args[@]}" >/dev/null 2>&1; then
    echo "  ✓ Hub languages seeded (${HUB_LANGUAGES:-en, de, fr})"
  else
    echo "  ⚠ language seeding failed (non-fatal)"
  fi
}

# ---- EE post-deploy seeders -------------------------------------------------
# A greenfield EE deploy is loginnable WITHOUT the interactive Logto admin
# wizard: the EE hub image ships offline seeders (/app/oidc-seeds, /app/menu-seeds)
# that write straight to logto-postgres (direct-DB, no Management-API M2M) and to
# the Hub internal launchpad port. We extract + run them on the host, reusing the
# same admin identity as the CE native admin (HUB_BACKEND_ADMIN_*) so login is
# identical across editions. Best-effort and strictly NON-FATAL — a deploy never
# fails because seeding did. Requires python3 + argon2-cffi on the host (Argon2i).
seed_ee() {
  local hub_cid pg_cid i tmp domain admin_user admin_pass hub_filter pg_filter
  echo ""
  echo "▶ EE seeders (Logto app/roles/user + launchpad)…"
  if [[ "$RUNTIME" == swarm ]]; then
    hub_filter="com.docker.swarm.service.name=${STACK}_industream-hub-backend"
    pg_filter="com.docker.swarm.service.name=${STACK}_logto-postgres"
  else
    hub_filter="com.docker.compose.project=${PROJECT}"
    pg_filter="com.docker.compose.project=${PROJECT}"
  fi
  hub_cid="$(docker ps -q --filter "label=${hub_filter}" \
            $([[ "$RUNTIME" == compose ]] && echo --filter label=com.docker.compose.service=industream-hub-backend) \
            2>/dev/null | head -1)"
  # Logto validates every new password against api.pwnedpasswords.com with a
  # bare fetch() and no try/catch, so with no egress user creation answers 500 —
  # including the first admin, which locks the console. Online sites keep the
  # check: it works there and is a real protection.
  #
  # Non-fatal: the deploy has just been issued and the database may still be
  # converging. The site is usable either way, and the script is idempotent, so
  # a later run (or the operator's) settles it.
  if [[ "$AIRGAP" == true ]]; then
    echo "  ▶ airgap: disabling Logto's Have I Been Pwned password check"
    bash "$HERE/../scripts/setup/logto-airgap-password-policy.sh" >/dev/null 2>&1 \
      && echo "  ✓ Logto: Have I Been Pwned check disabled on every tenant" \
      || echo "  ⚠ could not disable the Have I Been Pwned check — run scripts/setup/logto-airgap-password-policy.sh once Logto is up"
  fi

  [[ -z "$hub_cid" ]] && { echo "  ⚠ hub-backend container not found — skipping seeders" >&2; return 0; }

  # logto-postgres must accept connections (compose `up -d` returns before ready).
  for i in $(seq 1 30); do
    pg_cid="$(docker ps -q --filter "label=${pg_filter}" \
             $([[ "$RUNTIME" == compose ]] && echo --filter label=com.docker.compose.service=logto-postgres) \
             2>/dev/null | head -1)"
    [[ -n "$pg_cid" ]] && docker exec "$pg_cid" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 2
  done

  # Extract the seeders shipped in the EE image (absent on pre-2.1.3 images).
  tmp="$(mktemp -d)"
  docker cp "${hub_cid}:/app/oidc-seeds/logto/seed-logto-stack.sh" "$tmp/seed-logto-stack.sh" 2>/dev/null || true
  docker cp "${hub_cid}:/app/oidc-seeds/logto/seed-logto.sh" "$tmp/seed-logto.sh" 2>/dev/null \
    || { echo "  ⚠ seeders absent from the hub image (pre-2.1.3) — run scripts/setup/ manually" >&2; rm -rf "$tmp"; return 0; }

  local scope=(--runtime "$RUNTIME")
  [[ "$RUNTIME" == swarm ]] && scope+=(--stack "$STACK") || scope+=(--project "$PROJECT")
  domain="${INDUSTREAM_DOMAIN:-localhost}"
  # Seed the Logto bootstrap admin from the generated secret files (the strong
  # password create-secrets.sh produced) — fall back to env, then to "admin" only
  # if neither exists. Without this the seed silently used "admin"/"admin": the
  # secret was never wired into HUB_BACKEND_ADMIN_PASSWORD. ($(cat) strips the
  # trailing newline.)
  local secrets_dir="$HERE/../secrets/$ENV"
  # Fall back to "industream", the seeder's own default — NOT "admin", which is
  # also GF_SECURITY_ADMIN_USER. When both carry the same name, Grafana refuses to
  # link the OIDC identity to its pre-existing local admin and every EE login dies
  # on a misleading "user not found".
  admin_user="${HUB_BACKEND_ADMIN_USER:-$(cat "$secrets_dir/hub_backend_admin_user" 2>/dev/null || echo industream)}"
  admin_pass="${HUB_BACKEND_ADMIN_PASSWORD:-$(cat "$secrets_dir/hub_backend_admin_password" 2>/dev/null || echo admin)}"

  # The fallback above is only reached when nothing is configured. An EXISTING
  # secrets file or env var saying "admin" still lands us in the collision, which
  # is how the Bernegger install ended up unable to log in to Grafana at all:
  # Grafana already owns a local `admin` (GF_SECURITY_ADMIN_USER) and refuses to
  # attach an OIDC identity to it, reporting "user not found" — a message that
  # points nowhere near the real cause. Override rather than warn: a deploy that
  # knowingly provisions a broken login is worse than one that renames it.
  if [[ "$admin_user" == "admin" ]]; then
    echo "  ⚠ configured Logto user is 'admin', which collides with Grafana's local"
    echo "    admin account and breaks EE SSO — provisioning 'industream' instead."
    echo "    Set HUB_BACKEND_ADMIN_USER or secrets/$ENV/hub_backend_admin_user to"
    echo "    silence this."
    admin_user="industream"
  fi

  # Derive the email from the USERNAME, never a hardcoded "admin@". Logto enforces
  # UNIQUE (tenant_id, primary_email), so a fixed address collides the moment a
  # second account is seeded — including the rename above: provisioning
  # `industream` with admin@<domain> on an install whose existing `admin` already
  # holds it violates the index and the whole seeding step fails.
  admin_email="${HUB_BACKEND_ADMIN_EMAIL:-${admin_user}@${domain}}"

  # 1) Logto: OIDC app + roles + bootstrap user (Argon2i → needs python3 + argon2-cffi).
  if python3 -c 'import argon2' 2>/dev/null; then
    if bash "$tmp/seed-logto.sh" --client-id "${OIDC_CLIENT_ID:-industream-hub-app}" \
         --redirect "https://${domain}/" --user "$admin_user" --password "$admin_pass" \
         --email "$admin_email" --role admin "${scope[@]}" >/dev/null 2>&1; then
      echo "  ✓ Logto: app '${OIDC_CLIENT_ID:-industream-hub-app}' + roles + user '${admin_user}'"
    else echo "  ⚠ Logto seeding failed (non-fatal — see scripts/setup/seed-logto.sh)"; fi
  else
    echo "  ⚠ python3 argon2-cffi missing on host — Logto user bootstrap skipped"
  fi

  # 2) Register every service carrying io.industream.logto.* labels as an OIDC app
  #    (base/ee.yml puts them on grafana). Without this the app does not exist in
  #    Logto and the redirect fails with an opaque invalid_client.
  if [[ -f "$tmp/seed-logto-stack.sh" ]]; then
    if bash "$tmp/seed-logto-stack.sh" "${scope[@]}" >/dev/null 2>&1; then
      echo "  ✓ Logto: label-discovered OIDC apps registered"
    else echo "  ⚠ Logto app discovery failed (non-fatal)"; fi
  fi

  # 3) Grant the user scopes those apps request. Logto returns ONLY `sub` without
  #    them, so Grafana receives no email or username and refuses to create the
  #    user — surfacing as a misleading "user not found". The registrar does not
  #    do this, and installation-EE.md documents it as a manual console step.
  if [[ -n "$pg_cid" ]]; then
    if docker exec "$pg_cid" psql -U postgres -d logto -v ON_ERROR_STOP=1 -c "
         INSERT INTO application_user_consent_user_scopes (tenant_id, application_id, user_scope)
         SELECT 'default', a.id, s.scope
           FROM applications a
           CROSS JOIN (VALUES ('profile'),('email'),('roles')) AS s(scope)
          WHERE a.tenant_id = 'default'
         ON CONFLICT DO NOTHING;" >/dev/null 2>&1; then
      echo "  ✓ Logto: profile/email/roles scopes granted"
    else echo "  ⚠ Logto scope grant failed (non-fatal — roles will fall back)"; fi
  fi

  # 4) Align Logto's client secret for the Grafana app with the one Grafana
  #    actually presents (/run/secrets/…, see ensure_grafana_oidc_secret).
  #    seed-logto-stack.sh hardcodes `secret = 'unused-' || client_id` on INSERT
  #    — derivable from the public client_id and identical on every install —
  #    and its ON CONFLICT branch does NOT touch `secret`, so overwriting it here
  #    is stable across re-runs. The proper fix belongs in the registrar
  #    (industream-hub): generate a random secret and expose it to the deployer.
  #    Until then this is the only place the two ends can be made to agree.
  #
  #    The statement goes in on STDIN, not via -c: psql only performs :'var'
  #    interpolation on input it reads from stdin or -f. With -c the string is
  #    handed to the server verbatim and Postgres rejects the colon
  #    ("syntax error at or near \":\""), so this step failed on every fresh
  #    install and Grafana login died with invalid_client. Step 3 above survives
  #    with -c only because its SQL contains no variables.
  local oidc_secret_file="$HERE/../secrets/$ENV/grafana_oidc_client_secret"
  if [[ -n "$pg_cid" && -s "$oidc_secret_file" ]]; then
    if printf '%s\n' \
         "UPDATE applications SET secret = :'secret'
           WHERE tenant_id = 'default' AND id = :'cid';" \
       | docker exec -i "$pg_cid" psql -U postgres -d logto -v ON_ERROR_STOP=1 \
           -v cid="${GRAFANA_OIDC_CLIENT_ID:-grafana}" \
           -v secret="$(cat "$oidc_secret_file")" >/dev/null 2>&1; then
      echo "  ✓ Logto: Grafana client secret aligned with /run/secrets"
    else echo "  ⚠ Logto Grafana client-secret update failed (login will fail with invalid_client)"; fi
  fi

  # 5) Audit: Logto accepts a user with no email address, Grafana does not. When
  #    the userinfo response carries none, Grafana falls back to a GitHub-era
  #    /me/emails endpoint that Logto does not implement, and the sign-in dies on
  #    a 404 that names neither the user nor the missing field. Anyone creating an
  #    account from the Logto console will hit it. Report it here instead, where
  #    the operator is already looking.
  if [[ -n "$pg_cid" ]]; then
    local no_email
    no_email=$(docker exec "$pg_cid" psql -U postgres -d logto -tAc \
      "SELECT string_agg(username, ', ')
         FROM users
        WHERE tenant_id = 'default'
          AND username IS NOT NULL
          AND (primary_email IS NULL OR primary_email = '');" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$no_email" && "$no_email" != "" ]]; then
      echo "  ⚠ Logto users without an email address: ${no_email}"
      echo "    They can sign in to the Hub but NOT to Grafana — Grafana requires an"
      echo "    email and fails with an opaque 404. Add one in the Logto console."
    fi
  fi

  rm -rf "$tmp"
}

# ---- Resolve image list -------------------------------------------------------
# Resolve every `image:` reference in the assembled files against the CURRENT
# environment. Shared by --list-images and the pre-pull so the bundle can never
# disagree with what the deploy will ask for.
resolve_image_list() {
  python3 - "$@" <<'PY'
import sys, os, re
seen = set()
for fn in sys.argv[1:]:
    try:
        lines = open(fn).read().splitlines()
    except OSError:
        continue
    for ln in lines:
        m = re.match(r"\s*image:\s*(.+?)\s*$", ln)
        if not m:
            continue
        raw = re.sub(r"\s+#.*$", "", m.group(1).strip()).strip()
        img = os.path.expandvars(raw.strip("'\""))
        if "$" in img or not img or img in seen:
            continue
        seen.add(img)
        print(img)
PY
}

# ---- Dispatch ---------------------------------------------------------------
if [[ "$RUNTIME" == compose ]]; then
  [[ -n "$PROJECT" ]] || { echo "✗ --project required for compose" >&2; exit 1; }
  # Handle --list-images before any side effects (EE checks, deploy, etc)
  if [[ "$LIST_IMAGES" == true ]]; then
    (
      set -a; export ENV
      source registries.env; source versions.env; source auth.env; source "runtime.${RUNTIME}.env"
      for bf in "$BUNDLE_DIR"/.env.*; do source "$bf"; done
      [[ -f ".env.${ENV}" ]] && source ".env.${ENV}"
      set +a
      _li_files=(); for f in "${FILES[@]}"; do [[ "$f" == -f ]] || _li_files+=("$f"); done
      resolve_image_list "${_li_files[@]}"
    )
    exit 0
  fi
  # Same reasoning as --list-images above: print and exit before any side effect.
  if [[ "$PRINT_GROUPS" == true ]]; then echo "$GROUP_SET"; exit 0; fi
  if [[ "$EDITION" == ee ]]; then check_compose_domains; ensure_grafana_oidc_secret; fi
  # Pre-deploy live snapshot (best-effort): when a deploy-state repo exists, capture
  # the current Portainer-owned stacks BEFORE we overwrite them, so manual edits
  # made in the Portainer UI are never silently lost. Soft-fails (exit 3) when
  # Portainer is absent or credentials are not provided. ENV is passed explicitly
  # — it is not exported yet on this branch (the env sourcing happens after `up`).
  if [[ -d "$HERE/../.deploy-state/.git" ]]; then
    ENV="$ENV" bash "$HERE/scripts/deploy-state.sh" snapshot || echo "⚠ deploy-state snapshot skipped/failed (non-fatal)"
  fi
  docker compose -p "$PROJECT" "${ENV_FILES[@]}" "${FILES[@]}" up -d
  # Source the env so the seeders see INDUSTREAM_DOMAIN / OIDC_CLIENT_ID / admin creds
  # (compose dispatch uses --env-file, which doesn't export into this process).
  # Sourced UNCONDITIONALLY so seed_menu_apps runs for CE too.
  set -a; export ENV
  source registries.env; source versions.env; source auth.env; source "runtime.${RUNTIME}.env"
  for bf in "$BUNDLE_DIR"/.env.*; do source "$bf"; done
  [[ -f ".env.${ENV}" ]] && source ".env.${ENV}"
  set +a
  seed_menu_apps                              # both editions: seed the Hub launchpad
  [[ "$EDITION" == ee ]] && seed_ee           # EE-only: Logto app/roles/user
else
  [[ -n "$STACK" ]] || { echo "✗ --stack required for swarm" >&2; exit 1; }
  # Handle --list-images before any side effects (EE checks, env sourcing, deploy, etc)
  if [[ "$LIST_IMAGES" == true ]]; then
    # `docker stack deploy` interpolates ${VAR} from the PROCESS env (not
    # --env-file), and unlike `compose config` it handles ${ENV}-* network/secret
    # keys. Source the single env sources into the env, then deploy with -c.
    set -a; export ENV
    source registries.env; source versions.env; source auth.env; source "runtime.${RUNTIME}.env"
    for bf in "$BUNDLE_DIR"/.env.*; do source "$bf"; done
    [[ -f ".env.${ENV}" ]] && source ".env.${ENV}"
    set +a
    _li_files=(); for f in "${FILES[@]}"; do [[ "$f" == -f ]] || _li_files+=("$f"); done
    resolve_image_list "${_li_files[@]}"
    exit 0
  fi
  # Same reasoning as --list-images above: print and exit before any side effect.
  if [[ "$PRINT_GROUPS" == true ]]; then echo "$GROUP_SET"; exit 0; fi
  [[ "$EDITION" == ee ]] && ensure_grafana_oidc_secret
  # `docker stack deploy` interpolates ${VAR} from the PROCESS env (not
  # --env-file), and unlike `compose config` it handles ${ENV}-* network/secret
  # keys. Source the single env sources into the env, then deploy with -c.
  set -a; export ENV
  source registries.env; source versions.env; source auth.env; source "runtime.${RUNTIME}.env"
  for bf in "$BUNDLE_DIR"/.env.*; do source "$bf"; done
  [[ -f ".env.${ENV}" ]] && source ".env.${ENV}"
  set +a
  # Pre-deploy live snapshot (best-effort): when a deploy-state repo exists, capture
  # the current Portainer-owned stacks BEFORE we overwrite them, so manual edits
  # made in the Portainer UI are never silently lost. Soft-fails (exit 3) when
  # Portainer is absent or credentials are not provided.
  if [[ -d "$HERE/../.deploy-state/.git" ]]; then
    bash "$HERE/scripts/deploy-state.sh" snapshot || echo "⚠ deploy-state snapshot skipped/failed (non-fatal)"
  fi
  # Pre-pull images BEFORE the stack deploy, a FEW at a time. `docker stack deploy`
  # pulls one image per task ALL AT ONCE (~33 concurrent), which wedges containerd
  # on small nodes (tasks stuck in 'Preparing' even when the image is locally
  # available, while a manual `docker pull` returns instantly). A bounded pool
  # (-P 4) is well under that threshold yet ~4× faster than serial. Image refs are
  # resolved from the assembled files with the env sourced above (python3
  # os.path.expandvars) → covers platform + third-party. Best-effort/NON-FATAL:
  # any pull that fails is left for the stack deploy to retry.
  #
  # Each pull is BOUNDED by `timeout` (PULL_TIMEOUT, default 120s) with a couple of
  # retries: containerd occasionally wedges on a single layer (no progress for
  # minutes) — without the timeout the whole pre-pull (and the install) hangs
  # forever on that one image. On timeout we SIGTERM/-KILL the pull, retry, then
  # give up and leave the image to the stack deploy. Tune via PULL_TIMEOUT /
  # PULL_RETRIES env.
  if [[ "$AIRGAP" == true ]]; then
    echo "▶ airgap: skipping the pre-pull; images must already be loaded (see airgap.sh)"
  else
    _pp_files=(); for f in "${FILES[@]}"; do [[ "$f" == -f ]] || _pp_files+=("$f"); done
    export PULL_TIMEOUT="${PULL_TIMEOUT:-120}" PULL_RETRIES="${PULL_RETRIES:-2}"
    echo "▶ pre-pulling images (≤4 in parallel, ${PULL_TIMEOUT}s/pull, avoids swarm's all-at-once wedge)…"
    resolve_image_list "${_pp_files[@]}" | xargs -r -P 4 -n 1 sh -c '
      img="$1"; n=0
      while [ "$n" -lt "${PULL_RETRIES:-2}" ]; do
        n=$((n + 1))
        if timeout -k 10 "${PULL_TIMEOUT:-120}" docker pull "$img" >/dev/null 2>&1; then
          echo "  ✓ $img"; exit 0
        fi
        [ "$n" -lt "${PULL_RETRIES:-2}" ] && echo "  … retry $img ($n/${PULL_RETRIES:-2}, prev hit ${PULL_TIMEOUT:-120}s)"
      done
      echo "  ⚠ $img (slow/wedged after ${PULL_RETRIES:-2}× — left for the stack deploy)"
    ' _
  fi
  C_FILES=(); for f in "${FILES[@]}"; do [[ "$f" == -f ]] && C_FILES+=(-c) || C_FILES+=("$f"); done
  # Submit the stack (detached) then poll convergence OURSELVES. `--detach=false`
  # re-verifies every service SERIALLY (stable-window per service) → minutes for a
  # 45-service EE stack even when everything is already N/N, and a single transient
  # restart resets the window. Polling `docker stack services` returns as soon as
  # all replicas are N/N for 2 consecutive checks — bounded by DEPLOY_TIMEOUT; on
  # timeout we name the stragglers instead of hanging (the stack stays deployed).
  # `--resolve-image never` is REQUIRED offline: the default (`always`) contacts
  # the registry for every tag→digest even when the image is already local.
  DEPLOY_FLAGS=(--detach=true --prune)
  if [[ "$AIRGAP" == true ]]; then
    DEPLOY_FLAGS+=(--resolve-image never)
  else
    DEPLOY_FLAGS+=(--with-registry-auth)
  fi
  docker stack deploy "${DEPLOY_FLAGS[@]}" "${C_FILES[@]}" "$STACK"
  echo "▶ waiting for services to converge (≤${DEPLOY_TIMEOUT:-600}s)…"
  _deadline=$(( $(date +%s) + ${DEPLOY_TIMEOUT:-600} ))
  _stable=0
  while :; do
    _not_ready=$({ docker stack services "$STACK" --format '{{.Replicas}}' 2>/dev/null || true; } \
      | awk 'BEGIN{n=0}{split($1,a,"/"); if(a[1]!=a[2])n++}END{print n+0}')
    _total=$({ docker stack services "$STACK" -q 2>/dev/null || true; } | wc -l)
    if [[ "$_not_ready" -eq 0 && "$_total" -gt 0 ]]; then
      _stable=$((_stable + 1))
      [[ $_stable -ge 2 ]] && { echo "  ✓ all ${_total} services converged"; break; }
    else
      _stable=0
    fi
    if [[ $(date +%s) -ge $_deadline ]]; then
      echo "⚠ stack '${STACK}' not stable within ${DEPLOY_TIMEOUT:-600}s — still converging:" >&2
      list_unstable_services
      break
    fi
    sleep 3
  done
  seed_menu_apps                       # both editions: seed the Hub launchpad
  # NB: an `&&`-chained `seed_ee` as the script's LAST statement made deploy.sh
  # exit 1 on CE (the `[[ == ee ]]` test is false → non-zero → propagated as the
  # script's exit code → the CLI reported a phantom 'install failed'). Use a plain
  # `if` so the final statement is always success on CE.
  if [[ "$EDITION" == ee ]]; then
    seed_ee                            # EE-only: Logto app/roles/user (env sourced above)
  fi
fi
