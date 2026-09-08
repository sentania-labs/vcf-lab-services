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

1. Installing the licensed VCF Download Tool, either from an archive the sync
   already mirrored under `PROD/COMP/VCFDT` in the depot or by uploading the
   portal-downloaded archive. Both paths validate the archive the same way.
2. Reading the persistent Software Depot ID and saving its activation code.
3. Confirming the platform-provided depot and backup mounts.
4. Choosing the VCF filter, SKU, targets, recurring schedule, timezone, CEIP,
   backup service state, SFTP identity, and download endpoints. The schedule
   is picked as daily, weekly, or custom cron (with an advanced cron toggle),
   and the console shows the next run the choice would produce before it is
   saved.
5. Running a sync and inspecting live state, logs, and available versions.

The console is organised into Setup, Sync, Settings, Backup, and Logs tabs.
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
is removed only after the replacement completes a fully successful sync. If a
replacement has not synced successfully, installing another release keeps only
the current and immediately previous releases.

## Storage ownership

The product consumes two fixed mounted paths:

- `/depot`, read-write in the sync service and read-only in the web and console
  services.
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

The config volume carries separate product release and config schema markers.
An older schema is migrated forward in order after its small files are copied
to a timestamped directory under `/config/migration-backups`. Existing setting
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

The sync service is the only depot writer. Scheduled and console-triggered runs
use the same lock, so only one can write at a time. Targets run sequentially,
later targets still run after a failure, state is written atomically, and only
the newest configured run logs are retained. Until an activation code is
saved, the stack stays healthy but sync reports `not armed`.

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
licensed tool is replaced separately from Setup, where rollback is available
until its first successful sync.

`./uninstall.sh` removes this stack's containers, network, and images, but
retains every named volume and reports each retained volume and mount path.
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
- A console path for adopting an existing VCFDT depot and Software Depot ID.
  The adoption scripts remain in `scripts/`, but removing the installer left
  no reachable way to run them (see [docs/validation.md](docs/validation.md)).
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
