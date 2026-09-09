# vcf-services

`vcf-services` is a self-hosted Docker Compose appliance that provides an HTTPS
VCF binary depot, a scheduled VCF Download Tool sync engine, an SFTP backup
target, and an admin console.

An official single-Pod Kubernetes deployment is also available. See
[docs/kubernetes.md](docs/kubernetes.md) for the storage, secret, ingress, and
failure-domain contract.

This branch is a workable GUI-first prototype. It is not the finished product.
The licensed VCF Download Tool is never included, downloaded, logged, or
redistributed by this project.

## First run

Requirements are Docker Engine 26.0 or newer, Docker Compose 2.26 or newer,
host port 443, and enough durable storage for the depot. Plan for roughly 0.5 to 1 TB for one VCF release
train.

Start the published images directly. There is no installer step and no local
image build:

```bash
docker compose up -d
```

For deployment image selection and release bundles, see
[the pinning contract](docs/releasing.md#where-pinning-belongs).

Browse to `https://<host>/admin/`. Caddy creates an internal certificate on the
first boot, so the browser warns until the local Caddy CA is trusted.

The first person to set the `vcf` owner password claims the appliance. This is
intentional trust on first use for the lab MVP. Claim it from a trusted network
before exposing it more broadly.

The console then walks through:

1. When retaining an existing registration, pasting its 36-character Software
   Depot ID into **Adopt an existing Software Depot ID** before the first tool
   install. The console writes `machine_id` to the durable VCFDT state volume.
2. Installing the licensed VCF Download Tool, either from an archive the sync
   already mirrored under `PROD/COMP/VCFDT` in the depot or by uploading the
   portal-downloaded archive. Both paths validate the archive the same way.
3. Confirming the persistent Software Depot ID with the tool and saving its
   activation code. For a retained ID, paste the already-issued activation code.
4. Confirming the platform-provided depot and backup mounts.
5. Choosing the VCF filter, SKU, targets, recurring schedule, timezone, CEIP,
   backup service state, SFTP identity, and download endpoints. The schedule
   is picked as daily, weekly, or custom cron (with an advanced cron toggle),
   and the console shows the next run the choice would produce before it is
   saved.
6. Running a sync and inspecting live state, logs, and available versions.

The ordering rule for a retained identity is strict: adopt the existing ID
before installing the tool. The console reports it as adopted and pending, then
the first installation probe must confirm the same ID. Adoption is refused once
a tool is installed, and adoption must wait while a sync or tool update is
running. A mismatch shows the adopted ID and the ID returned by the tool (or
reports that no recognizable ID was returned). Activation-code saving and setup
completion remain blocked until the adopted ID is confirmed.

The console is organised into Setup, Sync, Depot, Settings, Backup, and Logs tabs.
Every operator setting in this prototype remains editable in the console. The
settings file is the storage contract inside the `vcf-services-config` volume,
not an operator editing interface.

Settings can be saved while a sync is running. The run in progress keeps the
values it read when it started, and the console marks the saved values as
applying to the next run. A run takes the `settings-snapshot.lock` file in its
state volume before it reads `settings.env` and holds it until it exits, and
the console holds the same lock while it writes, so a save is classified
against the run's real snapshot rather than against the run state the sync
publishes a moment later. The run also names itself in `settings-snapshot.run`
before it takes that lock, so the "next run" notice is tied to one specific run
and is retired once that run ends.

Two groups of settings behave differently:

- The download endpoint and token URL are read from the mounted tool while a
  run is in flight, so saving either one waits until the run finishes and the
  console says so by name.
- The backup service state and the SFTP UID:GID are re-read by the backup
  service every few seconds, so they take effect immediately. The console
  reports them as applied now rather than as waiting for the next run, and
  turning backup off during a sync ends current SFTP sessions.

Tool installation (from the depot or by upload) and starting a sync keep
their existing running-sync guards. Replacing the tool retains the prior
extracted release and exposes a rollback button on Setup. The retained release
is removed only after a fully successful sync that includes at least one
successful tool-backed target (`esx`, `install`, `upgrade`, or `patches`). A
VKR-only run keeps the retained release because it uses a separate helper. If a
replacement has not synced successfully, installing another release keeps only
the current and immediately previous releases. To roll back, wait for any sync
to finish, open Setup, and select **Roll back to previous**. This swaps the two
tool releases without restoring depot content. The same retention rule applies
after rollback; a failed sync keeps the retained release.

## Storage ownership

The product consumes two fixed mounted paths:

- `/depot`, read-write in the sync service and console, and read-only in the
  web service. The console takes the existing sync and tool locks before an
  upload or delete, so it does not race either writer.
- `/mnt/backup`, read-write only in the SFTP service and read-only in the
  console.

Compose creates separate named volumes by default. A deployment platform can
replace those with pre-provisioned volumes, bind mounts, or Kubernetes
PersistentVolumes. The product does not configure NFS, Docker volume drivers,
or host paths.

Do not use `docker compose down -v` unless the intent is to erase appliance
state. Normal container recreation and `docker compose down` preserve the
named volumes. The most important small volumes are:

- `vcf-services-vcfdt-state`, the Software Depot ID bound to the activation
  code.
- `vcf-services-secrets`, the owner, activation, SFTP, Redis, and session
  secrets.
- `vcf-services-sftp-host-keys`, the stable consumer fingerprints.

The `vcf-services-vcfdt-tool` volume is disposable. Both the console and sync
service mount it read-write: the console installs the licensed tool, and the
tool rewrites its telemetry flag during every sync. Tool installation and sync
share an update lock, so they cannot modify the volume at the same time.
Restore it from the Setup tab by installing a tool archive already mirrored in
the depot, or by uploading the licensed archive again.

### Operator-provided depot content

Place operator-provided content as a top-level tree under `/depot/PROD/COMP`,
for example `/depot/PROD/COMP/SUPERVISOR`. The Depot tab inventories every tree
at that level. A tree containing both `items.json` and `lib.json` is detected as
a vSphere content library, recorded as operator-provided, and protected by
default. Its size, file count, and item count are visible in the console.

Ownership is stored in `/state/depot-ownership.json` on the durable sync-state
volume rather than inside `/depot`. This keeps the protection record when a
depot volume is replaced or reattached. Product-created trees are recorded as
product-managed. Other previously existing trees are recorded as unknown until
their origin can be established. Protected trees are skipped by matching sync
targets and remain protected until an operator turns protection off in the
Depot tab.

Adopting an existing VKR content tree as the VKR sync target is a follow-up.
This release inventories and protects that tree but does not adopt it.

The Depot tab also browses `/depot` and provides authenticated file uploads,
folder uploads from `.tar.gz`, `.tgz`, or `.zip` archives, and explicit
deletion. Archive uploads use the same member-count, expanded-size, path, and
file-type validation as the licensed-tool installer, then reject symbolic links
for depot content. Uploads refuse to overwrite an existing entry. A delete
shows recursive size and file count and proceeds only when the operator types
the displayed relative path exactly. Deleting a protected tree, anything below
it, or an ancestor containing it is refused until the tree is unprotected in the
Depot tab.

Every explorer path is resolved below `/depot`; absolute paths, parent
traversal, and symbolic-link paths are refused. Upload and delete take both the
sync lock and licensed-tool update lock, so they fail clearly while either job
is active. Uploading below `/umds-patch-store` is allowed, but the console shows
that those files are downloadable without credentials. Licensed VCF Download
Tool archives remain restricted to the Setup workflow and are not accepted by
the explorer.

For console-based identity migration, follow [First run](#first-run).
The retained depot-adoption helpers in `scripts/` are covered in
[validation boundaries](docs/validation.md).

The config volume carries separate product release and config schema markers.
An older schema is migrated forward in order. Every release marker change on
an existing config volume also takes this migration path, even when the schema
is unchanged. Before migration, top-level config files up to 1 MiB each are
copied to a timestamped directory under `/config/migration-backups`; this copy
does not include other volumes or nested directories. Existing setting
values and identity are preserved, new keys receive shipped defaults, and the
result plus recovery path is shown on Setup. A release refuses to use config
written by a newer release or schema and leaves the console reachable with a
clear recovery message. Downgrades never rewrite newer state.

## Network and credentials

HTTPS is fixed on host port 443 for the prototype. SFTP is fixed on port 2222.
The owner password is shared by the admin console, authenticated depot routes,
and the SFTP account. A password change in the console updates all three and
reminds the operator to update consumers.

Two HTTPS routes intentionally remain unauthenticated:

- `/healthz`, which reports only liveness.
- `/umds-patch-store/*`, because `vmware-umds` does not send basic auth.

All other depot content requires HTTP basic authentication as user `vcf`.
The SFTP account is also `vcf`, with paths under
`/mnt/backup/<component>`. ECDSA, Ed25519, and RSA host keys are generated once
and retained in their dedicated volume.

## Sync behavior

The sync service is the only writer of product-managed depot content. Admin
console uploads and explicit deletes share its lock. Scheduled and
console-triggered runs use the same lock, so only one can write at a time. Targets run sequentially,
later targets still run after a failure, state is written atomically, and only
the newest configured run logs are retained. Until an activation code is
saved, the stack stays healthy but sync reports `not armed`.

The Sync tab shows the tool version and outcome for each target's last run.
Setup's **Depot content produced by** summary is derived from those same rows,
so mixed versions and failed attempts remain visible. Older records without a
tool version display `unknown`. The persisted fields are defined in the
[sync status contract](docs/redis-contract.md#status-shape-vcf-servicessyncstatus).

The download host and token URL are generic advanced settings. Production
defaults are already present. Changing them patches the mounted tool only when
no sync is running, with no image build or container recreation.
Installation and endpoint changes update the existing endpoint keys in every
regular, non-symlink `conf/application-prod*.properties` file. Non-production
profiles are left untouched. Each changed file is replaced atomically, and a
failed profile update or settings-file save restores the previous profiles
under the update lock. The console reports the filenames changed after a
successful save or install; files already containing the requested values are
not listed. If neither endpoint key exists in any matching production profile,
installation or an endpoint change is rejected with an explicit error. Before
a tool is installed, endpoint settings can still be saved for its installation.

## Optional bootstrap helper

`./install.sh` remains a compatibility convenience. Its normal path checks the
Docker daemon and Compose v2, pulls the published images, starts Compose, and
verifies the live HTTPS health endpoint. `./install.sh --upgrade` pulls the
selected release and force-recreates the services without removing any volume.
It is safe to rerun. No current settings change requires an image rebuild. The
licensed tool replacement and rollback follow the Setup procedure above.

`./uninstall.sh` removes this stack's containers, network, and three product
images, but retains the shared Caddy and Redis image caches. It also retains
every named volume and reports each retained volume and mount path using the
names resolved by Compose, including values supplied through `.env`.
`./uninstall.sh --purge-data` is the separately named destructive path. It
requires typing `PURGE`, then removes all stack volumes including the depot and
Software Depot ID. Do not use it unless those durable copies are no longer
needed.

## Operations

```bash
docker compose ps
docker compose logs -f depot-sync
docker compose logs -f sftp-backup
docker compose up -d
docker compose down
./install.sh --upgrade
./uninstall.sh
```

Use `./compose.sh` only if a small Docker-daemon preflight is useful. Direct
Compose commands are the normal path.

## Prototype boundaries

Deferred work is explicit:

- Native in-product NFS configuration. Storage is platform-provided.
- Backup status by product and product release checking.
- A console path for adopting an existing depot content tree. The Software
  Depot ID now has a reachable Setup-tab path, while the broader depot-content
  adoption scripts remain in `scripts/` (see
  [docs/validation.md](docs/validation.md)).
- Restricting on-demand TLS certificate issuance to configured or observed
  appliance hostnames. The prototype keeps the open ask behavior unchanged.

The repository stub validates the setup workflow, but the following need the
captain's licensed archive and lab before they can be claimed as working:

- Machine ID output from the real licensed tool. Version output parsing is
  already confirmed against captured licensed output.
- Registration with a real activation code and an actual Broadcom download.
- A completed sync serving real depot content to VCF consumers.
- Consumer trust of the first-boot CA, and live VCF component SFTP behavior.

See [docs/validation.md](docs/validation.md) for the runnable checks and
[docs/releasing.md](docs/releasing.md) for packaging.
