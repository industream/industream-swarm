# Airgap Bundle Runbook

Operational guide for installing and updating the Industream platform at a
site with **no internet access**, using the offline bundle built by
`unified/scripts/airgap.sh` and installed by its `install.sh`.

---

## Overview

| Step                  | Script                                  | Runs on           |
|------------------------|-----------------------------------------|--------------------|
| Build the bundle        | `unified/scripts/airgap.sh prepare`     | a connected machine |
| Verify before shipping  | `unified/scripts/airgap.sh verify`      | the connected machine, and again on site |
| Install / update        | `<bundle>/install.sh`                   | the airgapped site  |

A bundle is self-contained: the platform tree (`git archive` of the commit
it was built from), per-group `docker save` image tarballs, harvested
Grafana plugins and CDN packages, `bundle.json`, and checksum manifests
(`PARTS.sha256`, `MANIFEST.sha256`).

---

## 1. Build a bundle (connected machine)

The working tree must be clean (`prepare` refuses a dirty tree — what ships
must be what was tested):

```bash
cd unified
./scripts/airgap.sh prepare --runtime swarm --edition ee --out /media/usb
```

Common flags:

- `--env <env>` (default `prod`)
- `--groups "<group list>"` to ship a subset (default: everything
  `deploy.sh --print-groups` would deploy)
- `--max-part-size 3800M` (the default) keeps every shipped file under
  FAT32's 4 GiB per-file limit. **A real delivery hit this exactly** — a
  bundle built with a larger cap had to be reformatted onto a bigger stick
  before it would even copy. Leave it at the default unless the transport
  medium is known not to be FAT32.
- `--skip-images` / `--skip-assets` — testing/dev only, never for a bundle
  that will actually be shipped.

### The CDN harvest needs a warmed, connected instance

`airgap.sh prepare` harvests the CDN packages (FlowMaker box definitions)
from a **live, already-used** platform instance — `cdn-server` (Verdaccio)
only publishes a package the first time something asks for it, so an
instance nobody has pointed a build at yet has an **empty** cache. `prepare`
deliberately **fails loudly** rather than ship an empty one:

```
✗ CDN cache is empty — harvest from a warmed instance (--harvest-from) or the boxes will have no definition on site
```

On a real delivery this was missed once, and the empty cache only surfaced
much later, far from its actual cause: FlowMaker boxes with no definition
on the installed site.

If the build machine itself isn't the warmed instance, point the harvest at
one via a Docker context:

```bash
docker context create warmed-source --docker "host=ssh://user@warmed-host"
./scripts/airgap.sh prepare --runtime swarm --edition ee --out /media/usb \
  --harvest-from warmed-source
```

For **compose**, also pass `--harvest-project <project>` if the warmed
instance's compose project name differs from `--env` — compose has no fixed
volume-naming convention the way the swarm overlays do, so a mismatch here
silently harvests from (or reports empty against) the wrong volumes.

> **Verified once, on 2026-09-04.** The "CDN copy succeeds and yields real
> packages" path — long the least-tested step here — has now been exercised
> against a genuinely warmed Verdaccio volume: 6.4 MB of real npm packages
> (`@codemirror`, `@lezer`, `argparse`, `js-yaml`, …) landed in the bundle,
> alongside all four Grafana plugins. The "finds nothing → abort" guard was
> confirmed too: a run against an unwarmed volume stopped the build rather
> than shipping an empty cache.
>
> What that does **not** prove: the harvested packages have not yet been
> served to a FlowMaker box on a running air-gapped site. Until someone loads
> a box from a site installed this way, treat "the packages are present" and
> "the boxes resolve" as two different claims.

### Grafana plugin version bumps

If a bundle bumps `GRAFANA_DATABRIDGE_PLUGIN` (or any preinstalled plugin
version) since the site's last install, that bundle **must** be installed —
`install.sh` re-seeds the Grafana plugins volume on every run, not only the
first. `GF_PLUGINS_PREINSTALL_SYNC` is **boot-blocking**: if Grafana starts
looking for a plugin version that was never seeded, it never starts at all.

### Verify before shipping

```bash
./scripts/airgap.sh verify /media/usb/industream-airgap-<commit>-ee-swarm
```

This re-checks `MANIFEST.sha256` / `PARTS.sha256` and replays
`deploy.sh --list-images` against the bundle's own tree, catching a group
added after the build before it ever reaches a site.

---

## 2. Transport

Copy the bundle directory to the transport medium as-is — no
re-compression, no reassembly needed on either end. FAT32 works at the
default `--max-part-size` (3800M). Do not rename or restructure the bundle
directory; `install.sh` resolves everything relative to its own location.

---

## 3. Install on a fresh site

### First, create the platform secrets — the install stops dead without them

`deploy.sh` requires the `${ENV}_*` swarm secrets to already exist. On a site
that has never been deployed they do not, and `install.sh` gets all the way
through verification, image load, tree sync and asset seeding before failing
at the deploy step with:

```
service industream-hub-backend: secret not found: <env>_hub_jwt_signing_key
```

Observed on a real air-gapped install. The generator ships inside the bundle,
so this is done offline, once, before the first `install.sh`:

```bash
cd /opt/industream-platform          # the --target you are about to use
./scripts/setup/create-secrets.sh --env prod
```

Two things to know:

- It accepts **only** `prod`, `dev` or `staging`. An arbitrary `--env` value
  is rejected outright — so if you plan to pass `--env` to `install.sh`, it
  has to be one of those three.
- It is idempotent and never rewrites an existing secret, so re-running it
  before an update is safe. Updates to an already-deployed site need nothing
  here; this is a first-install step only.

If the target directory does not exist yet, run `install.sh --no-deploy`
first: it syncs the tree (which is what puts `create-secrets.sh` on the
machine) and seeds the assets without attempting the deploy. Then create the
secrets, then run `install.sh` for real.

### EE only: Logto cannot create users offline until this is applied

Logto checks every new password against `api.pwnedpasswords.com` with a bare
`fetch()` and no error handling, so with no egress user creation answers 500 —
including the **first admin user**, which locks the Admin Console entirely:

```
POST /api/experience/profile 500 5,062ms
cause: Error: getaddrinfo EAI_AGAIN api.pwnedpasswords.com
```

Run this once on the site, after the stack is up:

```bash
scripts/setup/logto-airgap-password-policy.sh --check   # report only
scripts/setup/logto-airgap-password-policy.sh
```

→ **verify:** every tenant reports `false`, then a real user creation logs
`POST /api/experience/profile 204` in a few hundred ms. The multi-second
duration is the tell that the external call is still being attempted.

It writes to Logto's database, so it survives a service restart, a reboot and
a redeploy (the entrypoint's `db seed --swe` skips an already-seeded database).
Only recreating the `logto-postgres` volume would undo it. On a multi-node
swarm, run it on the node hosting that task
(`docker service ps <stack>_logto-postgres --format '{{.Node}}'`).

### The install itself

```bash
cd /media/usb/industream-airgap-<commit>-ee-swarm
bash install.sh --target /opt/industream-platform --stack industream-prod   # swarm
bash install.sh --target /opt/industream-platform --project fm-prod        # compose
```

For compose, pass `--project <name>` explicitly and pick a name deliberately
— `install.sh` will fall back to `fm-<env>` if you don't, but that default
is only ever a placeholder, not a site convention. `--stack` defaults to
`industream-prod` if omitted. `--runtime`, `--edition`, `--env`, `--groups` all default to
whatever `bundle.json` recorded and can be overridden with the
same-named flag if this install genuinely needs to diverge from how the
bundle was built.

`install.sh` runs, in order:

1. **Preflight** — docker present, swarm active (swarm only), disk space on
   **both** `/var/lib/containerd` and `/var/lib/docker` (Docker 29 stores
   images under the former, not the latter — a real machine froze mid-install
   because only `/var/lib/docker` was checked), clock NTP-sync warning, and a
   full `airgap.sh verify` of the bundle. Verification **hard-stops before
   any Docker mutation** — a bad bundle never gets partway loaded.
   Budget roughly **50 GB free** for a full platform install.
2. **Image load** — streamed straight into `docker load`, never reassembled
   to disk.
3. **Tree sync** — `rsync` (no `--delete`) copies the bundle's tree onto the
   target, then `install.sh` removes only the tree paths a **previous**
   bundle delivered and this one no longer ships — tracked in
   `$TARGET/AIRGAP_TREE_MANIFEST` (see below). Root-anchored exclusions
   (`/unified/.env.*`, `/secrets/`, `/unified/custom/`,
   `/unified/instances/`, `/unified/base/certs/`, `/.deploy-state/`,
   `/backups/`) are kept as defence in depth on the copy itself, but a path
   nobody thought to exclude can no longer be deleted just for being
   unlisted — it was never a bundle path, so it is never a stale-prune
   candidate either. A timestamped snapshot under `backups/` is taken first,
   as before.
4. **Asset seeding** — Grafana plugins and CDN packages, into
   `${ENV}-<volume>` (swarm) or `<project>_<volume>` (compose).
5. **Deploy** — `deploy.sh --airgap` with the runtime/edition/env/groups/
   bundle version from `bundle.json` (or your overrides) plus `--stack` or
   `--project`. `--airgap` skips the pre-pull and passes
   `--resolve-image never` to `stack deploy` — nothing reaches the network.

`--yes` is accepted (reserved for a future confirmation prompt — there is
none today). `--no-deploy` stops after asset seeding, before `deploy.sh`
runs — useful to stage a site without deploying yet.

---

## 4. Update an existing site

Same command, pointed at the **existing** `--target`:

```bash
cd /media/usb/industream-airgap-<new-commit>-ee-swarm
bash install.sh --target /opt/industream-platform --stack industream-prod
```

The sync step snapshots the current tree under `backups/` before touching
anything, and preserves every path listed above — `.env.<env>`, `secrets/`,
`custom/` overlays, `instances/`, `base/certs/` (site TLS material), and
`.deploy-state/` all survive. Any other site-local file, at any path,
survives too: only paths a previous bundle actually shipped and this one
drops (e.g. a retired group overlay) get removed.

**First update after adopting this mechanism:** if `$TARGET/AIRGAP_TREE_MANIFEST`
does not exist yet (a site last updated before this feature), `install.sh`
prints a warning and removes nothing that run — there is no safe way to
tell a bundle-delivered file from a site-created one without the manifest.
This run writes the manifest, so the **next** update prunes normally; the
gap is one update wide, not permanent. If a real stale file is a known
concern on such a site, check the warning's output and remove it by hand.

That case — an older site, installed before bundles existed, being brought
up to a current bundle offline — has its own step-by-step with a verifiable
signal at each step: [`airgap-update-legacy-site.md`](airgap-update-legacy-site.md).
Follow it rather than this section when the site has no
`AIRGAP_TREE_MANIFEST`.

---

## 5. Roll back

Rollback is **replaying the previous bundle's `install.sh`** against the
same `--target`. For this to work, **the previous bundle must still be
present on site** — never delete a bundle directory after installing it.

```bash
cd /path/to/previous/industream-airgap-<old-commit>-ee-swarm
bash install.sh --target /opt/industream-platform --stack industream-prod
```

This re-syncs the tree to the old commit, reloads the old images (already
on disk from the earlier install — nothing is re-fetched), and redeploys.

---

## Never do this

- **Never run `scripts/uninstall.sh` against a customer site.** It is the
  destructive path in this repo — it removes the stack, its secrets, **every
  `${ENV}-*` volume (i.e. the databases)**, the network and the generated
  files. It confirms at each step, but a confirmed mistake is still a
  mistake. `deploy.sh` itself has no teardown flag, and `install.sh`
  deliberately exposes **no** flag that reaches either.
- **Never `git reset --hard` (or a bare `cp -r`) on the site checkout.**
  Both have already destroyed untracked site state on real installs. The
  only supported way to update the tree is `install.sh` itself, which syncs
  via `rsync` plus a manifest-tracked prune (never a blanket `--delete`) and
  takes a snapshot first.

---

## The site checkout is not a git clone

`install.sh` writes the tree with `git archive` output, not a clone — the
checkout at `$TARGET` is **knowingly detached from `origin`**. It will never
take another `git pull`, `git fetch`, or `git log` against a real history.
The **only** record of what commit and bundle a site is running is:

```
$TARGET/AIRGAP_VERSION
```

written on every install/update:

```
commit=<short-sha>
bundle=<bundle-directory-name>
installed=<ISO-8601 timestamp>
```

Read this file first when diagnosing a site — never assume the checkout's
git metadata means anything.

Alongside it, `$TARGET/AIRGAP_TREE_MANIFEST` records the set of tree paths
the currently-installed bundle delivered. It is installer bookkeeping, not
an operator-facing file (NUL-delimited — use `tr '\0' '\n'` to read it), and
it is what the **next** update diffs against to decide what to prune. Like
`AIRGAP_VERSION`, it lives at the target root, never under `unified/` or any
other path a bundle's tree could ship, so the sync (which no longer runs
`--delete`) never touches it.

---

## Bench

`tests/airgap/bench/` holds the isolated-VM bench: a bare-VM cold-install
scenario and an update scenario, run on the `ho8-airgap` libvirt network
(genuinely no internet — no NAT, no DHCP) with `tests/airgap/bench/check-signals.sh`
verifying observable signals afterward (replica counts, Grafana's datasource
list, a served CDN package, the Hub's launchpad tiles, DataCatalog's auth
behavior). See that directory's `README.md` for exact VM requirements and the
current, honest status of what has and hasn't been run — as of 2026-09-04,
no VM on this workstation is sized and network-placed to run it yet.

Once the bench has actually run, append the measured numbers here — bundle
size, uncompressed size, install duration, disk consumed on
`/var/lib/containerd` — since these are what size a customer's VM. Not
recorded yet: no execution has happened to measure them.
