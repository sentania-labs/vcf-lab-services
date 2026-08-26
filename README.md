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

Browse to `https://<host>/admin/`. Caddy creates an internal certificate on the
first boot, so the browser warns until the local Caddy CA is trusted.

The first person to set the `vcf` owner password claims the appliance. This is
intentional trust on first use for the lab MVP. Claim it from a trusted network
before exposing it more broadly.

The console then walks through:

1. Uploading and validating the portal-downloaded VCF Download Tool archive.
2. Reading the persistent Software Depot ID and saving its activation code.
3. Confirming the platform-provided depot and backup mounts.
4. Choosing the VCF filter, SKU, targets, recurring schedule, timezone, CEIP,
   backup service state, SFTP identity, and download endpoints.
5. Running a sync and inspecting live state, logs, and available versions.

Every operator setting in this prototype remains editable in the console. The
settings file is the storage contract inside the `vcf-services-config` volume,
not an operator editing interface.

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

The `vcf-services-vcfdt-tool` volume is disposable. Restore it by uploading the
licensed archive again.

The config volume carries the product version that created it. If an unmarked
or differently marked config volume is found, the console stays reachable but
setup, sync, and SFTP operations remain blocked. The console reports both
versions and directs the operator to preserve needed data, then use a new
config volume or restore one created by the running version. This prevents a
failed mixed-version first boot from silently presenting contaminated setup
state as complete.

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

## Optional bootstrap helper

`./install.sh` remains only as a compatibility convenience. It checks that the
Docker daemon and Compose v2 are usable, pulls the published images, runs
`docker compose up -d`, and verifies the live HTTPS health endpoint. Those host
startup checks cannot run in the console because the console does not exist
until Compose has started it. The helper asks no product questions, creates no
settings, configures no storage, and builds no image.

## Operations

```bash
docker compose ps
docker compose logs -f depot-sync
docker compose logs -f sftp-backup
docker compose up -d
docker compose down
```

Use `./compose.sh` only if a small Docker-daemon preflight is useful. Direct
Compose commands are the normal path.

## Prototype boundaries

Deferred work is explicit:

- Native in-product NFS configuration. Storage is platform-provided.
- VCFDT self-upgrade from content already in the depot. Upload-driven atomic
  replacement is present.
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
