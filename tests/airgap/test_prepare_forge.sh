#!/usr/bin/env bash
# The Forge is the source of truth for what a site runs. These assertions cover
# the identity surviving all the way to the site, and the guards that stop a
# mismatched bundle from being built at all.
#
# Nothing here reaches the network: the Forge fetch itself is forge-bundle.sh's
# job (and deploy.sh already exercises it). What is tested is what prepare does
# with an already-materialised bundle, and how it rejects bad input.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT/unified"

FORGE_KEY="forge-test-community-9.9.9"
FORGE_DIR="releases/bundle-platform-${FORGE_KEY}"
cleanup() { rm -rf "${REPO_ROOT:?}/unified/$FORGE_DIR"; }
trap cleanup EXIT

# A bundle as forge-bundle.sh materialises one: the .env.* it downloaded, plus
# the FORGE_SOURCE manifest recording where it came from.
mkdir -p "$FORGE_DIR"
cp releases/bundle-platform-1.0.1/.env.* "$FORGE_DIR/" 2>/dev/null || true
cat > "$FORGE_DIR/FORGE_SOURCE" <<'EOF'
source=forge
exportKey=flowmaker-community
version=2.4.0
forgeUrl=https://forge-api.forge.industream.dev/
EOF

out="$(mktemp -d)"
bundle="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --bundle "$FORGE_KEY" --skip-images --skip-assets --out "$out" | tail -1)"

# --- The reference has to reach the site ------------------------------------
# Only .env.* were copied out of releases/ for untracked bundles, so a bundle
# fetched from the Forge arrived on site with no record of which Forge bundle
# it was. AIRGAP_VERSION answers "which commit"; nothing answered "which Forge
# bundle", which is the question asked first when a site misbehaves.
[[ -f "$bundle/tree/unified/$FORGE_DIR/FORGE_SOURCE" ]] \
  || fail "FORGE_SOURCE must travel into the bundle tree"
pass "FORGE_SOURCE travels into the bundle tree"

assert_eq "$(python3 -c "import json;print(json.load(open('$bundle/bundle.json'))['forge']['exportKey'])" 2>/dev/null)" \
  "flowmaker-community" "bundle.json records the Forge exportKey"
assert_eq "$(python3 -c "import json;print(json.load(open('$bundle/bundle.json'))['forge']['version'])" 2>/dev/null)" \
  "2.4.0" "bundle.json records the Forge version"

# Identity comes from FORGE_SOURCE, never from the directory name: a bundle
# fetched with `--name 1.0.1` lands in bundle-platform-1.0.1/ and its name then
# says nothing about the Forge at all.
assert_contains "$(python3 -c "import json;print(json.load(open('$bundle/bundle.json'))['forge'])" 2>/dev/null)" \
  "flowmaker-community" "the Forge identity is read from FORGE_SOURCE, not the bundle key"

# --- A non-Forge bundle must not grow a fake provenance ---------------------
plain_out="$(mktemp -d)"
plain="$(with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --bundle 1.0.1 --skip-images --skip-assets --out "$plain_out" | tail -1)"
assert_eq "$(python3 -c "import json;print(json.load(open('$plain/bundle.json'))['forge'])" 2>/dev/null)" \
  "None" "a locally-rendered bundle records forge: null"

# --- The site records it too ------------------------------------------------
target="$(mktemp -d)"
with_docker_stub bash "$bundle/install.sh" --target "$target" --yes --no-deploy >/dev/null 2>&1 || true
assert_contains "$(cat "$target/AIRGAP_VERSION")" "forge=flowmaker-community@2.4.0" \
  "AIRGAP_VERSION on the site names the Forge bundle and version"

# --- Guards -----------------------------------------------------------------
# --forge sets the bundle; accepting both would leave which one wins to
# argument order.
assert_fails ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --forge "flowmaker-community@2.4.0" --bundle 1.0.1 --out "$out" \
  "--forge and --bundle together are rejected"

assert_fails ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --forge "flowmaker-community" --out "$out" \
  "--forge without @version is rejected"

assert_fails ./scripts/airgap.sh prepare --runtime swarm --edition ce \
  --forge "flowmaker-community@2.4.0" --forge-interactive --out "$out" \
  "--forge and --forge-interactive together are rejected"

# --- Edition coherence ------------------------------------------------------
# A community bundle ships no EE images. Built with --edition ee it produces a
# bundle whose EE services have no image on site — a failure that only surfaces
# at deploy time, on the far side of a USB stick. forge-bundle.sh check already
# knows how to catch this; prepare has to call it.
#
# forge-ref-215 is a real committed `flowmaker-community` bundle, so it is
# genuinely missing HUB_API_ENTERPRISE_IMAGE and friends — unlike the fixture
# above, which borrows the full platform bundle's env files and therefore
# satisfies EE too.
ee_out="$(mktemp -d)"
assert_fails with_docker_stub ./scripts/airgap.sh prepare --runtime swarm --edition ee \
  --bundle forge-ref-215 --skip-images --skip-assets --out "$ee_out" \
  "a community Forge bundle built with --edition ee is refused at build time"
