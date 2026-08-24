# vcf-services

`vcf-services` is a self-hosted Docker Compose appliance for services that sit
beside a VMware Cloud Foundation fleet. This first slice provides an HTTPS
offline depot, a scheduled VCF Download Tool sync engine, and an admin console.
The layout leaves room for the optional file backup target planned for the next
slice.

The licensed VCF Download Tool is never included, downloaded, or redistributed
by this project. You provide the archive obtained from the Broadcom support
portal during installation.

## Requirements

- Linux on x86_64
- Docker Engine and Docker Compose v2
- OpenSSL, curl, tar, and at least 500 GB free for the depot by default
- Outbound HTTPS access to the configured download endpoint, and to `ghcr.io`
  so the installer can pull the product images without registry credentials
- A VCF Download Tool `.tar.gz` or `.zip` containing
  `bin/vcf-download-tool`
- `nfs-common` or the equivalent NFS client package when using NFS storage

Plan for roughly 0.5 to 1 TB for one VCF release train. The full VKr library is
roughly 461 GB, so VKr is not selected by default.

## Quickstart

Download the installation bundle and its checksum from the desired entry on
the repository's GitHub Releases page. Then verify, extract, and run it:

```bash
sha256sum -c vcf-lab-services-v1.0.0.tar.gz.sha256
tar -xzf vcf-lab-services-v1.0.0.tar.gz
cd vcf-lab-services-v1.0.0
./install.sh
```

Installing from a source checkout is still supported for development and for
the pre-release proof: run `./install.sh` in the checkout, optionally with
`--version` and `--image-repository`. See
[docs/releasing.md](docs/releasing.md).

Every prompt shows its default. The installer validates the host and vendor
archive, pulls the release's admin UI and license-safe sync base images, layers
your VCF Download Tool archive into a local sync image, preserves the Software
Depot ID in a dedicated Docker volume, configures storage and TLS, generates
the Redis job bus password, starts the four services (depot web, sync, admin
console, Redis), and performs live HTTPS checks plus a Redis exposure check.
Use `./install.sh --answers-file answers.env`
for an unattended run. See [config/answers.example](config/answers.example) for
the supported keys. Keep completed answer files outside the repository with
mode `0600` because they contain the installation password.

Installation is safe to rerun. Existing depot data and the Software Depot ID
volume are retained. No password ships with the product, and installation
requires one.

If you skip the activation code, the stack remains healthy but sync is dormant.
The CLI and GUI report `not armed: activation code missing` and show the
registration steps. Rerun the installer after registering the displayed
Software Depot ID to arm it.

## Known unauthenticated routes

Two routes intentionally do not require credentials:

- `/healthz` returns only service liveness.
- `/umds-patch-store/*` exposes the ESX patch-store subtree because
  `vmware-umds` does not send basic authentication credentials.

The admin console at `/admin/` and every other depot path require the single
credential configured by the installer.

## Operations

```bash
docker compose ps
docker exec vcf-services-sync /usr/local/bin/sync.sh --status
docker exec vcf-services-sync /usr/local/bin/sync.sh patches
docker compose logs -f depot-sync
```

Sync targets are serialized with a lock and run sequentially. One failed target
does not prevent later targets from running. Run state is written atomically,
and only the newest configured number of run logs are retained. The depot is
cumulative and this product does not prune VCFDT-managed content.

The admin console displays current state, live logs, schedule and next run,
per-target results, and available versions. It publishes sync requests to a
password-protected Redis job bus that only the internal Compose network can
reach; the sync service consumes those requests and runs `sync.sh` locally.
No container mounts the Docker socket and the console has no Docker client.
The bus contract is documented in [docs/redis-contract.md](docs/redis-contract.md).

Settings hot-reload without recreating containers. The sync scheduler re-reads
`config/settings.env` every cycle, so schedule changes take effect within a
minute, and each run re-reads all sync settings. The only rebuild exception is
a VCFDT self-upgrade, which is performed by rerunning `install.sh`, never by
the GUI. HTTPS is served on a published host port, 443 by default.

## TLS trust

Self-signed TLS is the default. Export `secrets/tls/server.crt` and add it to
the VCF Installer and SDDC Manager trust stores before configuring depot
consumers. With a supplied certificate, import the issuing CA chain instead.
The installer validates that a supplied certificate matches the configured
FQDN and private key.

## Persistence and recovery

The depot store is mounted at `/depot` in both the web and sync containers.
This identical path is required because VCFDT writes absolute symlinks. The
web mount is read-only and the sync mount is read-write.

The external `vcf-services-vcfdt-state` volume stores the Software Depot ID.
The installer creates it before Compose starts, and Compose will not remove it.
Back up this small volume and `secrets/`; losing the ID invalidates the
activation code. The depot itself can be downloaded again. A plain copy of the
depot tree preserves its portable layout.

### Adopt an existing depot and Software Depot ID

Adoption points this stack at an existing depot tree and imports the existing
VCFDT state without changing either source. First back up the source state and
depot. Set the normal storage answers to the existing location, then add one
state-source option to the installer:

```bash
# Existing depot on a host path
./install.sh --answers-file /secure/adopt-local.env \
  --adopt-state-dir /srv/old-vcfdt-state/vdt

# Existing depot on NFS and state in another Docker volume
./install.sh --answers-file /secure/adopt-nfs.env \
  --adopt-state-volume old-vcfdt-state
```

For the local example, set `STORAGE_MODE=local` and `DEPOT_LOCAL_PATH` to the
existing depot root. For NFS, set `STORAGE_MODE=nfs`, `NFS_SERVER`,
`NFS_EXPORT`, and `NFS_OPTIONS` to the existing export. The state directory or
volume must contain the contents normally mounted at
`/root/.local/share/vmware/vdt`, not its parent directory.

Adoption reuses depot content that is already downloaded, so the installer
skips its free-space floor in adopt mode. `--min-free-gb` is not needed for an
existing depot that is already close to full.

The installer mounts both sources read-only for validation. A depot must have a
populated `PROD/COMP` tree. Every symlink must resolve when the tree is mounted
at `/depot`, and every absolute symlink must point to `/depot` or below it.
VCFDT writes absolute symlinks, so a depot created at another container path is
not eligible for adoption as-is. Validation failure names the first
incompatible path and starts no service against it.

To read the source Software Depot ID, the installer copies the small state tree
to a scratch volume it deletes afterwards and asks VCFDT for the ID there, so
the tool never writes into the operator's source.

After both sources pass validation, the installer copies only the small VCFDT
state into the fixed `vcf-services-vcfdt-state` volume, reads the imported
Software Depot ID back through VCFDT, and requires it to match the source. It
does not copy or write depot content. The copy lands in a staging directory
inside the fixed volume and is moved into place last, so an interrupted or
failed import is cleared and retried on the next run instead of leaving a
half-imported state behind. A rerun with the same imported ID skips the copy. If the fixed volume is non-empty and contains a different or
unreadable ID, the installer refuses to overwrite it so an existing activation
cannot be lost.

Configuration lives in `config/settings.env`. It is deliberately a simple,
atomic file-backed format so later GUI settings support can update it without
introducing a database. Compose-only storage and network selections are
mirrored there and in the generated `.env` file.

## Scope

This slice does not include the backup service, guided Supervisor or VKr
content injection, VCFDT self-upgrade, or stack upgrade. Those features are
planned without changing the depot persistence and config contracts
established here.

Release packaging, image names, and version authority are documented in
[docs/releasing.md](docs/releasing.md).
