#!/usr/bin/env bash
# =============================================================================
# install.sh — install or update the platform from an offline bundle.
# =============================================================================
# Same script for a first install and for an update; the only difference is
# what is already on the machine. Run it from inside the unpacked bundle.
#
# There is deliberately NO teardown option. The destructive path in this repo
# is scripts/uninstall.sh, which removes the stack, its secrets, EVERY
# ${ENV}-* volume (i.e. the databases), the network and the generated files.
# It confirms at each step, but nothing here should be able to reach it.
#
# The reverse proxy is NOT in that blast radius and is not in the bundle
# either: swarm sites run Traefik as a separate shared stack behind the
# external network traefik-shared_traefik-public, compose sites run Caddy
# outside the platform project. An update therefore never touches the proxy
# or the CA it issues from — but that also means the proxy must already be
# running, and its image already local, before install.sh deploys anything.
# =============================================================================
set -euo pipefail
BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TARGET:-$HOME/industream-platform}"
ASSUME_YES=false
NO_DEPLOY=false
# Deploy-call overrides — empty means "take it from bundle.json". PROJECT is
# also read by volume_name() (below) so an operator-supplied --project lands
# on the SAME compose project the deploy itself uses; guessing two different
# values here is exactly how a volume gets seeded under a name nothing reads.
RUNTIME_OPT="" EDITION_OPT="" ENV_OPT="" GROUPS_OPT="" STACK_OPT="" PROJECT=""

die() { echo "✗ $*" >&2; exit 1; }

# Read one key from bundle.json, with a fallback for keys a bundle may not
# carry (the swarm stack name is a site property, not a build property).
json_get() {
  python3 -c "
import json,sys
d=json.load(open('$BUNDLE/bundle.json'))
print(d.get('$1', '''${2:-}'''))"
}

# Bundle values as they will actually be used, i.e. an operator override if
# one was given, else whatever the bundle was built with. Used by BOTH the
# deploy call and the asset seeder below, so the two can never disagree.
resolved_runtime() { [[ -n "$RUNTIME_OPT" ]] && echo "$RUNTIME_OPT" || json_get runtime; }
resolved_edition() { [[ -n "$EDITION_OPT" ]] && echo "$EDITION_OPT" || json_get edition; }
resolved_env()     { [[ -n "$ENV_OPT" ]]     && echo "$ENV_OPT"     || json_get env; }
resolved_groups()  { [[ -n "$GROUPS_OPT" ]]  && echo "$GROUPS_OPT"  || json_get groups; }

# Compose has no fixed volume-naming convention the way the swarm overlays do
# (deploy.sh treats --project as an arbitrary value unrelated to --env) — this
# is the ONE place that default gets decided, so volume_name() and run_deploy()
# stay in agreement by construction rather than by two matching literals.
compose_project() { echo "${PROJECT:-fm-$(resolved_env)}"; }

preflight() {
  command -v docker >/dev/null || die "docker is not installed"

  local runtime; runtime="$(resolved_runtime)"
  if [[ "$runtime" == swarm ]]; then
    [[ "$(docker info -f '{{.Swarm.LocalNodeState}}' 2>/dev/null)" == active ]] \
      || die "this node is not in an active swarm — run 'docker swarm init' first"
  fi

  # Docker 29 stores images under /var/lib/containerd, NOT /var/lib/docker.
  # Checking only the latter is how a machine froze mid-install with 22GB
  # landing on a 20GB root.
  #
  # bundle.json is untrusted data (MANIFEST.sha256 is a checksum, not a
  # signature) — validate uncompressed_bytes is a plain non-negative integer
  # BEFORE any arithmetic use of it, so a crafted value dies cleanly here
  # instead of ever being handed to bash arithmetic unchecked.
  local raw_bytes; raw_bytes="$(json_get uncompressed_bytes 0)"
  [[ "$raw_bytes" =~ ^[0-9]+$ ]] || die "bundle.json has a malformed uncompressed_bytes value"
  local need_kb dir
  need_kb="$(( raw_bytes / 1024 + 2097152 ))"
  for dir in /var/lib/containerd /var/lib/docker; do
    [[ -d "$dir" ]] || continue
    local free_kb; free_kb="$(df -Pk "$dir" | awk 'NR==2{print $4}')"
    (( free_kb >= need_kb )) \
      || die "not enough free space on $dir: $((free_kb/1024))MB free, $((need_kb/1024))MB needed"
  done

  # A wrong clock breaks proxy TLS and Hub JWT with errors that never mention
  # time — the most expensive class of failure to diagnose on site.
  if command -v timedatectl >/dev/null; then
    timedatectl show -p NTPSynchronized --value | grep -q yes \
      || echo "⚠ clock is not NTP-synchronised — TLS and JWT failures will look like anything but a clock problem" >&2
  fi

  echo "▶ verifying the bundle"
  bash "$BUNDLE/tree/unified/scripts/airgap.sh" verify "$BUNDLE" || exit 1
}

load_images() {
  local base
  # Parts are streamed straight into docker load: never reassembled, so the
  # bundle is never duplicated on a disk that may not have room for it.
  for base in $(ls "$BUNDLE/images" 2>/dev/null | sed 's/\.[0-9][0-9]$//' | sort -u); do
    echo "▶ loading $base"
    # An unsplit group has only "$base"; a split group has only "$base".NN
    # (cmd_split removes the unsuffixed original). Feeding `cat` a path that
    # is guaranteed not to exist either way makes it exit 1 even though it
    # streamed everything real — which pipefail then turns into a script
    # abort. Build the real file list first instead.
    local files=() part
    [[ -e "$BUNDLE/images/$base" ]] && files+=("$BUNDLE/images/$base")
    for part in "$BUNDLE/images/$base".[0-9][0-9]; do
      [[ -e "$part" ]] && files+=("$part")
    done
    (( ${#files[@]} > 0 )) || die "no readable part found for $base"
    cat "${files[@]}" | zstd -dc | docker load
  done
}

# Site-local paths the bundle's tree never overwrites, and — just as
# important — never deletes. ONE list, consumed by both the rsync copy and
# the manifest that drives pruning: if the two ever disagreed, a path rsync
# skipped would still be recorded as "delivered by this bundle", and the next
# update would delete the site's own file at that path. That is not
# hypothetical — a real bundle tree carries `unified/.env.<env>`,
# `unified/custom/README.md` and `unified/instances/.gitignore`, all excluded
# from the copy, so a bundle built for a different --env would have taken the
# site's live .env file with it.
#
# Every pattern is anchored with a leading '/' (relative to the transfer
# root) and is either a directory prefix ending in '/' or a glob matching one
# path. path_is_excluded() below implements exactly those two shapes — keep
# new entries to them, or teach it the new shape at the same time.
readonly TREE_EXCLUDES=(
  '/unified/.env.*'
  '/secrets/'
  '/unified/custom/'
  '/unified/instances/'
  '/unified/base/certs/'
  '/.deploy-state/'
  '/backups/'
)

# True when $1 (a path relative to the tree root, no leading slash) is covered
# by TREE_EXCLUDES, i.e. rsync did not copy it and pruning must not touch it.
path_is_excluded() {
  local candidate="/$1" pattern
  for pattern in "${TREE_EXCLUDES[@]}"; do
    if [[ "$pattern" == */ ]]; then
      [[ "$candidate" == "$pattern"* ]] && return 0
    else
      # shellcheck disable=SC2053  # glob match is the point, not equality
      [[ "$candidate" == $pattern ]] && return 0
    fi
  done
  return 1
}

# Never `git reset --hard`, never a bare `cp -r`: both have already destroyed
# untracked site state on these hosts. rsync with hard exclusions, after a
# snapshot that makes the previous tree recoverable.
#
# Deletion is no longer "wipe everything the bundle doesn't ship, minus a
# hand-maintained exclude list" — that blocklist already deleted a real
# site's TLS certs once (unified/base/certs/ was simply missing from it) and
# every unlisted path is the same latent bug. Deletion is now allowlist-based
# instead: prune_stale_tree_paths() below removes only paths a PREVIOUS
# bundle actually delivered and this one no longer ships (tracked via
# AIRGAP_TREE_MANIFEST on the target), so a path nobody thought to exclude is
# structurally safe — it was never a bundle path, so it can never be a
# deletion candidate. The exclude list stays as defence in depth on the copy
# side (never overwrite site-local state even if a bundle somehow shipped a
# same-named path); it is no longer the only thing standing between an
# update and data loss.
sync_tree() {
  mkdir -p "$TARGET/backups"
  local is_update=false
  if [[ -d "$TARGET/unified" ]]; then
    is_update=true
    local snap; snap="$TARGET/backups/tree-$(date +%Y%m%d-%H%M%S).tar.gz"
    echo "▶ snapshotting the current tree → $snap"
    # tar's exclude anchoring is NOT the same idea as rsync's: with
    # `-C "$TARGET" … .`, member names are stored as `./backups`, not
    # `/backups`, so a leading-slash pattern like `--exclude=/backups`
    # matches nothing — tar then archives $TARGET/backups, the very
    # directory this snapshot is being written into, and GNU tar aborts
    # with "file changed as we read it" as the growing archive appears
    # mid-read. `--anchored` makes the pattern match from the start of
    # each member name as stored (i.e. against the leading `./`), so
    # `--anchored --exclude=./backups` excludes only $TARGET/backups
    # while still keeping scripts/backups/*.sh, which an unanchored
    # 'backups' pattern would also have swallowed.
    tar czf "$snap" -C "$TARGET" --anchored --exclude=./backups .
  fi
  echo "▶ syncing the tree"
  # Every TREE_EXCLUDES entry is anchored with a leading '/'. Unanchored, rsync
  # matches the pattern as a suffix at ANY depth, not just at the transfer
  # root — that bit twice already: an unanchored '.env.*' also hid every
  # releases/bundle-platform-*/.env.<group> file, so deploy.sh failed
  # globbing its own bundle dir (only surfacing once install.sh actually
  # called it, Task 10); an unanchored 'backups/' also caught the
  # git-tracked scripts/backups/*.sh tooling and silently dropped it from
  # every install and update. '/backups/' means only $TARGET/backups, the
  # snapshot dir this function creates above.
  #
  # '/unified/base/certs/' is site-local TLS material (gitignored, so `git
  # archive` never puts it in the bundle's tree) — omitting it wiped the
  # directory on every update on a real air-gapped site. runtime/swarm/
  # monitoring.yml bind-mounts base/certs/${INDUSTREAM_DOMAIN}.crt into
  # Grafana's extra-CAs, so losing it takes Grafana down outright ("bind
  # source path does not exist"). With TLS_MODE=selfsigned (the default)
  # regenerating the cert also invalidates the CA every workstation on site
  # already trusted — the same class of harm the missing teardown flag
  # deliberately avoids.
  #
  # No `--delete` here on purpose — see the comment above this function.
  # Copying only ever adds/updates paths this bundle ships; it never removes
  # anything, so a forgotten exclude entry can no longer cost a site its
  # certs. Stale-path removal happens explicitly below, from the manifest
  # diff, once the copy has landed.
  local rsync_excludes=() pattern
  for pattern in "${TREE_EXCLUDES[@]}"; do rsync_excludes+=("--exclude=$pattern"); done
  rsync -a "${rsync_excludes[@]}" "$BUNDLE/tree/" "$TARGET/"

  prune_stale_tree_paths "$is_update"

  # The checkout is knowingly detached from origin: offline it will never take
  # another `git pull`, so record what it actually holds.
  # The Forge reference, when the bundle came from one — "which Forge bundle is
  # this site running" is the first question asked of a misbehaving site, and
  # the bundle directory name does not answer it.
  local forge=""
  forge="$(python3 -c "
import json,sys
f=json.load(open(sys.argv[1])).get('forge')
print('%s@%s' % (f['exportKey'], f['version']) if f else '')
" "$BUNDLE/bundle.json" 2>/dev/null)" || forge=""

  printf 'commit=%s\nbundle=%s\ninstalled=%s\n' \
    "$(json_get commit)" "$(basename "$BUNDLE")" "$(date -Is)" > "$TARGET/AIRGAP_VERSION"
  # An `if`, not `[[ … ]] && …`: this is the function's last command, and the
  # && form returns 1 for a non-Forge bundle, which `set -e` turns into a
  # failed install.
  if [[ -n "$forge" ]]; then
    printf 'forge=%s\n' "$forge" >> "$TARGET/AIRGAP_VERSION"
  fi
}

# Removes exactly the tree paths a PREVIOUS bundle delivered and this one no
# longer ships, then records this bundle's own set for the next update.
#
# AIRGAP_TREE_MANIFEST lives at the TARGET root (like AIRGAP_VERSION), never
# under unified/ or any other path a bundle's tree could ship — rsync above
# has no `--delete` and only ever writes paths present in $BUNDLE/tree, so a
# file living outside that tree is never touched by the copy, and this
# bookkeeping file survives by construction, not merely by being excluded.
#
# Format: NUL-delimited relative paths (one bundle can easily ship a path
# with a space in it), so this file is not meant for a plain `cat` — use
# `tr '\0' '\n' < AIRGAP_TREE_MANIFEST` to read it.
prune_stale_tree_paths() {
  local is_update="$1"
  local manifest; manifest="$TARGET/AIRGAP_TREE_MANIFEST"

  # The manifest records what the copy DELIVERED, not what the bundle
  # contains: an excluded path (a real bundle ships unified/.env.<env> among
  # others) was never written to the target, so recording it would make the
  # next update delete the site's own file at that path — reinstating, one
  # level down, the exact data loss this mechanism removes.
  local current_list; current_list="$(mktemp)"
  local -A current_set=()
  local relpath
  while IFS= read -r -d '' relpath; do
    path_is_excluded "$relpath" && continue
    current_set["$relpath"]=1
    printf '%s\0' "$relpath" >> "$current_list"
  done < <( cd "$BUNDLE/tree" && find . -type f -printf '%P\0' )

  if [[ -f "$manifest" ]]; then
    echo "▶ pruning tree paths this bundle no longer ships"
    local removed=0
    while IFS= read -r -d '' relpath; do
      # Also skip anything the CURRENT exclude list protects: if a path became
      # site-local between two bundles (an entry added to TREE_EXCLUDES), the
      # older manifest still lists it and it is absent from current_set —
      # without this, growing the exclude list would itself delete the state
      # it was added to protect.
      path_is_excluded "$relpath" && continue
      if [[ -z "${current_set[$relpath]+x}" && -e "$TARGET/$relpath" ]]; then
        rm -f -- "$TARGET/$relpath"
        removed=$((removed + 1))
      fi
    done < "$manifest"
    echo "  removed $removed path(s) no longer shipped by this bundle"
  elif [[ "$is_update" == true ]]; then
    # A pre-existing tree with no manifest: a site that was last updated
    # before this mechanism existed. There is no safe way to know which of
    # its files a bundle put there versus a site put there, so the only safe
    # move is to delete nothing this run — never guess at a customer site.
    # Say so loudly rather than silently leaving stale files behind forever:
    # this run's manifest (written below) lets the NEXT update prune
    # correctly, so this gap is one update wide, not permanent.
    echo "⚠ no $manifest found on an existing target — this site predates" \
      "manifest-based pruning. Skipping stale-file removal this run: a path" \
      "a previous, pre-mechanism bundle left behind (e.g. a retired group" \
      "overlay) may still linger and be picked up by deploy.sh's config" \
      "globs. The manifest recorded by this run will let the next update" \
      "prune correctly."
  fi

  local next_manifest; next_manifest="$manifest.new"
  sort -z "$current_list" > "$next_manifest"
  mv -- "$next_manifest" "$manifest"
  rm -f -- "$current_list"
}

# Seeded on EVERY deploy, not only the first. GF_PLUGINS_PREINSTALL_SYNC is
# boot-blocking, so a plugin version bump with no reachable registry would stop
# Grafana from starting at all.
# Volume names differ per runtime, and NOT the way the `<stack>_<volume>`
# default would suggest: the swarm overlays pin an explicit
# `name: ${ENV}-<volume>` (runtime/swarm/monitoring.yml, core.yml), so the
# real volume is `prod-grafana-data`. Compose declares no name, so it gets the
# `<project>_<volume>` default. Seeding the wrong name silently creates an
# unused volume and leaves Grafana unable to boot.
volume_name() {
  if [[ "$(resolved_runtime)" == swarm ]]; then echo "$(resolved_env)-$1"
  else echo "$(compose_project)_$1"; fi
}

# The disposable containers below need a helper image. It must be the exact
# tag airgap.sh prepare saved into images/tooling.tar.zst (never a bare
# `alpine`, which docker would resolve as `alpine:latest` and try to pull
# from a registry this machine cannot reach) — read from the bundle's OWN
# tree copy of unified/versions.env, the single source of truth, rather than
# a second literal here that could drift from the producer's.
tooling_image_shipped() {
  [[ -e "$BUNDLE/images/tooling.tar.zst" ]] && return 0
  local part
  for part in "$BUNDLE/images/tooling.tar.zst".[0-9][0-9]; do
    [[ -e "$part" ]] && return 0
  done
  return 1
}

seed_assets() {
  # Fail here, before any volume is created, with a message that names the
  # problem — not with docker's opaque registry-lookup error further down. A
  # bundle built before this fix never saved a helper image at all, so a bare
  # `docker image inspect`/`run alpine` would otherwise be the first thing to
  # notice, offline, with no useful context.
  tooling_image_shipped \
    || die "no tooling image shipped in this bundle (images/tooling.tar.zst missing) — it predates airgap.sh saving its own alpine helper; rebuild the bundle with a fixed airgap.sh prepare"

  # shellcheck disable=SC1091
  set -a; source "$BUNDLE/tree/unified/versions.env"; set +a

  seed_volume() {
    local vol="$1" src="$2" sub="${3:-}"
    [[ -d "$src" && -n "$(ls -A "$src")" ]] || return 0
    docker volume create "$vol" >/dev/null
    docker run --rm -v "$vol:/dest" -v "$src:/src:ro" "alpine:${ALPINE_VERSION}" \
      sh -c "mkdir -p /dest/$sub && cp -a /src/. /dest/$sub"
  }
  echo "▶ seeding runtime assets"
  seed_volume "$(volume_name grafana-data)"       "$BUNDLE/assets/grafana-plugins"                 "plugins"
  seed_volume "$(volume_name cdn-server-storage)" "$BUNDLE/assets/cdn-packages/cdn-server-storage"
  seed_volume "$(volume_name cdn-cache-storage)"  "$BUNDLE/assets/cdn-packages/cdn-cache-storage"
}

# Closes the loop: replay the SAME deploy.sh that assembled the bundle's image
# set (airgap.sh's --list-images / verify), so what gets deployed never drifts
# from what was checked. --bundle is always taken from bundle.json and never
# overridden here — it selects the release dir carrying the full-ref
# ${X_IMAGE} vars (releases/bundle-platform-<ver>/), and the synced tree can
# carry more than one such dir (e.g. a leftover Forge bundle), at which point
# deploy.sh's auto-select refuses to guess and --bundle stops being optional.
run_deploy() {
  local runtime edition env_val groups bundle_ver
  runtime="$(resolved_runtime)"
  edition="$(resolved_edition)"
  env_val="$(resolved_env)"
  groups="$(resolved_groups)"
  bundle_ver="$(json_get bundle)"
  local args=(--runtime "$runtime" --edition "$edition" --env "$env_val" --airgap)
  [[ -n "$bundle_ver" ]] && args+=(--bundle "$bundle_ver")
  [[ -n "$groups" ]] && args+=(--groups "$groups")
  # deploy.sh requires --stack for swarm and --project for compose; compose_project()
  # is the SAME function volume_name() uses above, so the asset volumes and the
  # deploy always land under the same project name.
  if [[ "$runtime" == swarm ]]; then
    args+=(--stack "${STACK_OPT:-$(json_get stack industream-prod)}")
  else
    args+=(--project "$(compose_project)")
  fi
  echo "▶ deploying (--airgap)"
  ( cd "$TARGET/unified" && ./scripts/deploy.sh "${args[@]}" )
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)    TARGET="$2"; shift 2 ;;
      --yes)       ASSUME_YES=true; shift ;;
      --no-deploy) NO_DEPLOY=true; shift ;;
      --runtime)   RUNTIME_OPT="$2"; shift 2 ;;
      --edition)   EDITION_OPT="$2"; shift 2 ;;
      --env)       ENV_OPT="$2"; shift 2 ;;
      --groups)    GROUPS_OPT="$2"; shift 2 ;;
      --stack)     STACK_OPT="$2"; shift 2 ;;
      --project)   PROJECT="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  preflight
  load_images
  sync_tree
  seed_assets
  if [[ "$NO_DEPLOY" == true ]]; then
    echo "▶ --no-deploy: tree synced and assets seeded, deploy skipped"
  else
    run_deploy
  fi
}

main "$@"
