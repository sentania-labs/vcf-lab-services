# vcf-services

`vcf-services` is a self-hosted Docker Compose appliance for services that sit
beside a VMware Cloud Foundation fleet. This first slice provides an HTTPS
offline depot, a scheduled VCF Download Tool sync engine, an SFTP file backup
target, and an admin console.

The licensed VCF Download Tool is never included, downloaded, or redistributed
by this project. After startup, upload the archive obtained from the Broadcom
support portal through the admin console.

Run `./install.sh` for the first installation. It creates the protected state
volume and starts the stack with the published, license-safe sync image. No
local image build is required.

## Requirements

- Linux on x86_64
- Docker Engine and Docker Compose v2
- OpenSSL, curl, and at least 500 GB free for the depot by default
- `ss` from the host's `iproute2` package for published-port collision checks
- Outbound HTTPS access to the configured download endpoint, and to `ghcr.io`
  so the installer can pull the product images without registry credentials
- A VCF Download Tool `.tar.gz`, `.tgz`, or `.zip` containing
  `bin/vcf-download-tool`, ready to upload in the console
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

Every prompt shows its default. The installer validates the host, pulls the
release's license-safe images, preserves the Software Depot ID in a dedicated
Docker volume, configures storage and TLS, generates the Redis job bus password,
starts the five services (depot web, sync, SFTP backup, admin console, Redis),
and performs live HTTPS and SFTP checks plus a Redis exposure check.
Use `./install.sh --answers-file answers.env`
for an unattended run. See [config/answers.example](config/answers.example) for
the supported keys. Keep completed answer files outside the repository with
mode `0600` because they contain the installation password.

Installation is safe to rerun. Existing depot data and the Software Depot ID
volume are retained. No password ships with the product, and installation
requires one.

Sign in at `/admin/`, select the VCF Download Tool archive, and choose
**Upload or replace tool**. The console extracts into staging, rejects unsafe
or incomplete archives, and switches the live tool only after validation. Use
the same control for later tool replacements. A replacement is refused while
a sync is running. Until the guided registration console slice lands, rerun
`./install.sh` once after the first upload to display the Software Depot ID and
save its activation code.

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

## SFTP backup target

The installer enables the backup target by default and prompts for its own
password, published host port, and UID:GID. The default endpoint is TCP 2222
because the Docker host normally owns TCP 22. The only allowed account is
`vcfbackup`. Its password is stored in `secrets/sftp/password`, not in Compose
or the settings file.

Use these backup-location strings, replacing the host and port with the values
shown by the installer:

- vCenter, confirmed for a nonstandard port by the vCenter 9.1 location syntax:
  `sftp://vcf-services.example.com:2222/mnt/backup/vcenter`
- NSX, pending captain UAT against a live deployment:
  `sftp://vcf-services.example.com:2222/mnt/backup/nsx`
- SDDC Manager, pending captain UAT against a live deployment:
  `sftp://vcf-services.example.com:2222/mnt/backup/sddc-manager`

For all three, enter `vcfbackup` and the SFTP password separately if the
component presents credential fields. Only vCenter's nonstandard-port support
is claimed as confirmed here. The NSX and SDDC Manager strings are the exact
UAT candidates, not claims of successful live validation.

The service deliberately has no chroot. This preserves the absolute
`/mnt/backup/<component>` namespace required by the VCF configurations. It uses
the external OpenSSH `sftp-server` subsystem and password authentication, and
`ForceCommand` restricts the account to file transfer, so the password grants no
shell or remote command execution. The installer prepares the component
directories using the configured numeric identity, default `1003:1003`. The
installer and the service share one re-own implementation: it compares the
backup root's actual owner first, and consults a marker keyed to both the
storage and the identity only to avoid rewalking a tree whose ownership the
storage already refused. A UID:GID change from the admin console re-owns the
tree once, a restart never rewalks it, and pointing the installer at a new
backup location re-owns that location. Where the storage refuses an ownership
change, such as an NFS export with `root_squash`, the service logs the required
owner; once that owner is set on the storage side the next start clears the
warning on its own.

ECDSA, Ed25519, and RSA host keys are generated once in the external
`vcf-services-sftp-host-keys` volume. Every container start prints all three
fingerprints:

```bash
docker compose logs sftp-backup
```

Record those fingerprints before configuring a consumer. Recreating the
container does not change them.

## Operations

If you need to start the stack manually after installation, use
`./compose.sh up -d`. It checks that the Docker daemon is reachable and that
the install-created state volume exists before invoking Compose with your
original arguments. The normal day-to-day commands remain direct Compose
commands:

```bash
docker compose ps
docker exec vcf-services-sync /usr/local/bin/sync.sh --status
docker exec vcf-services-sync /usr/local/bin/sync.sh patches
docker compose logs -f depot-sync
docker compose logs -f sftp-backup
docker compose restart
docker compose down
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

Sync settings hot-reload without recreating containers. The sync scheduler
re-reads `config/settings.env` every cycle, so schedule changes take effect
within a minute, and each run re-reads all sync settings. VCFDT replacement is
performed in the console and does not rebuild or recreate a container. HTTPS
is served on a published host port, 443 by default.

The admin console includes SFTP backup controls for enablement, password,
UID:GID, port, and the shared local or NFS storage selection. Enablement,
password, and UID:GID changes reload within five seconds. Disabling the backup
target stops the listener and terminates sessions that already authenticated,
so an active transfer loses access rather than running to completion. If saving
a settings change fails, the stored password is left unchanged, so the console
and the running service cannot diverge. Port and storage changes are saved as
desired settings but require rerunning `install.sh`, which performs the host
port collision and mount checks before recreating services.

## TLS trust

Self-signed TLS is the default. Export `secrets/tls/server.crt` and add it to
the VCF Installer and SDDC Manager trust stores before configuring depot
consumers. With a supplied certificate, import the issuing CA chain instead.
The installer validates that a supplied certificate matches the configured
FQDN and private key.

`vmware-umds` verifies certificates against the operating system trust store
on the host where UMDS runs. That host is separate from the VCF Installer and
SDDC Manager, so trusting the depot on those appliances does not make UMDS
trust it.

For the default self-signed certificate, securely copy
`secrets/tls/server.crt` from the depot host to the UMDS host as
`/tmp/vcf-services-depot.crt` (use the `.pem` extension on Photon OS). For a
supplied certificate, copy each issuing root and intermediate CA certificate
from your PKI instead of the depot's server certificate, keeping each CA
certificate in a separate file with its own name. Then install the certificate
material as root on the UMDS host:

```bash
# Ubuntu or Debian UMDS host
install -m 0644 /tmp/vcf-services-depot.crt \
  /usr/local/share/ca-certificates/vcf-services-depot.crt
update-ca-certificates

# Photon OS UMDS host
install -m 0644 /tmp/vcf-services-depot.pem \
  /etc/ssl/certs/vcf-services-depot.pem
/usr/bin/rehash_ca_certificates.sh
```

Repeat the `install` command for each root and intermediate file when using a
supplied certificate. Verify the trust from the UMDS host against the
unauthenticated health route, without an insecure TLS option. Use
`https://<PRODUCT_FQDN>/healthz` when HTTPS uses port 443, and
`https://<PRODUCT_FQDN>:<HTTPS_PORT>/healthz` for any other configured port:

```bash
# HTTPS on the default port 443
curl --fail --show-error https://vcf-services.example.com/healthz

# HTTPS on a nonstandard port, for example 8443
curl --fail --show-error https://vcf-services.example.com:8443/healthz
```

An `ok` response means UMDS will accept the depot certificate. A TLS error means
the trust store still lacks the certificate. A connection refused or timeout
means the URL is using the wrong port, not that the certificate is untrusted.

Then configure UMDS with the patch-store base URL.
The URL is `https://<PRODUCT_FQDN>/umds-patch-store/` when HTTPS uses port 443.
For any other configured port, it is
`https://<PRODUCT_FQDN>:<HTTPS_PORT>/umds-patch-store/`, for example
`https://vcf-services.example.com:8443/umds-patch-store/`.

## Persistence and recovery

The depot store is mounted at `/depot` in both the web and sync containers.
This identical path is required because VCFDT writes absolute symlinks. The
web mount is read-only and the sync mount is read-write.

The external `vcf-services-vcfdt-state` volume stores the Software Depot ID.
The installer creates it before Compose starts, and Compose will not remove it.
Back up this small volume and `secrets/`; losing the ID invalidates the
activation code. The depot itself can be downloaded again. A plain copy of the
depot tree preserves its portable layout.

The separate `vcf-services-vcfdt-tool` volume stores the uploaded executable.
It is disposable and can be restored by uploading the archive again. It must
never be merged with `vcf-services-vcfdt-state`, whose machine identity is not
disposable.

Backup data uses a separate volume mounted read-write at `/mnt/backup`. Its
location is prompted separately from the depot and must sit outside the depot
tree: `BACKUP_LOCAL_PATH` in local mode, `BACKUP_NFS_EXPORT` in NFS mode. The
installer and the admin console both reject a backup location nested inside the
depot, and reject any path containing a `..` segment, so backups are never
browsed or served by the depot web service and never scanned as depot content.
The NFS export must allow the Docker host and the configured SFTP UID:GID to
write it. Depot content is never exposed through the SFTP account.

Backup storage is always checked for existence and writability. Its free space
is advisory: the installer warns below 100 GB and continues, because backups are
a smaller size class than the depot. Pass `--min-backup-free-gb NUMBER` to turn
that into a hard floor.

### Adopt an existing depot and Software Depot ID

> [!WARNING]
> Stop the previous VCFDT or depot-sync writer before adoption, even when it
> runs in a container on another system. Keep it stopped throughout the new
> installation and do not run the old and new writers against the same depot.
> The installer cannot detect a writer on another system. Two active writers
> can mutate the state during import or corrupt the shared depot.

Adoption points this stack at an existing depot tree and imports the existing
VCFDT state without changing either source. Follow these steps in order:

1. Stop the previous VCFDT or depot-sync service and verify its writer process
   is no longer running. Keep that deployment stopped through cutover.
2. Back up the source VCFDT state, depot, and activation-code material.
3. Set the normal storage answers to the existing depot location, then run the
   installer with one state-source option:

```bash
# Existing depot on a host path
./install.sh --answers-file /secure/adopt-local.env \
  --adopt-state-dir /srv/old-vcfdt-state/vdt

# Existing depot on NFS and state in another Docker volume
./install.sh --answers-file /secure/adopt-nfs.env \
  --adopt-state-volume old-vcfdt-state
```

Interactive adoption displays the writer safety check before reading either
source and requires the operator to type `STOPPED`. A scripted run must stop
the previous writer through its own orchestration, verify that shutdown, and
then assert the completed prerequisite explicitly:

```bash
./install.sh --answers-file /secure/adopt-nfs.env \
  --adopt-state-volume old-vcfdt-state \
  --confirm-old-writer-stopped
```

`--confirm-old-writer-stopped` bypasses only the interactive prompt. It does
not detect or stop a remote writer, and must not be used until automation has
verified that the previous deployment is stopped.

For the local example, set `STORAGE_MODE=local` and `DEPOT_LOCAL_PATH` to the
existing depot root. For NFS, set `STORAGE_MODE=nfs`, `NFS_SERVER`,
`NFS_EXPORT`, and `NFS_OPTIONS` to the existing export. The state directory or
volume must contain the contents normally mounted at
`/root/.local/share/vmware/vdt`, not its parent directory.

Adoption reuses depot content that is already downloaded, so the installer
skips its free-space floor in adopt mode. `--min-free-gb` is not needed for an
existing depot that is already close to full.

Adoption is recorded in `config/settings.env` as `DEPOT_ADOPTED`, holding the
identity of the depot that was adopted, so it is a property of that depot rather
than of one command. Every later `./install.sh` rerun against the same depot
answers, for an activation code, a settings change, or an upgrade, keeps
skipping the free-space floor and does not ask for the writer confirmation
again, because a plain rerun re-imports nothing. Answer with a different depot
location and the full free-space floor applies again to that new location. Pass
the adopt options again only when you are importing state from a source once
more, and stop the current writer first when you do.

The installer mounts both sources read-only for validation. A depot must have a
populated `PROD/COMP` tree. Every absolute or relative symlink must resolve to
`/depot` or below it when the tree is mounted there. Normalized targets that
escape through `..` are rejected. VCFDT writes absolute symlinks, so a depot
created at another container path is not eligible for adoption as-is. A broken
symlink whose normalized target still stays inside `/depot` is reported as a
warning and adoption continues, because it is incomplete depot data rather than
a containment breach. The installer scans the whole tree in one pass and lists
every offending path, grouped so escaping links are separate from broken
internal links, and starts no service against a depot that has any escaping or
unreadable link.

To read a Software Depot ID, the installer copies the small state tree to a
scratch volume it deletes afterwards and asks VCFDT for the ID there. Neither
the operator's source nor a pre-existing fixed volume is ever written to while
its ID is being identified.

After both sources pass validation, the installer copies only the small VCFDT
state into the fixed `vcf-services-vcfdt-state` volume, reads the imported
Software Depot ID back through VCFDT, and requires it to match the source. It
does not copy or write depot content. The copy lands in a staging directory
inside the fixed volume and is moved into place last, so an interrupted or
failed import is cleared and retried on the next run instead of leaving a
half-imported state behind. That retry still identifies any ID already in the
fixed volume first and refuses if it differs from the source. A rerun with the
same imported ID skips the copy. If the fixed volume is non-empty and contains
a different or unreadable ID, the installer refuses to overwrite it so an
existing activation cannot be lost. A leftover staging directory alone is never
enough to justify clearing that volume: a volume that holds nothing but an
abandoned staging directory is cleared and retried, and a staging directory
found beside state whose ID already matches the source means an import was
interrupted part way, so the state is cleared and reimported from the
authoritative source rather than being declared complete.

Configuration lives in `config/settings.env`. It is deliberately a simple,
atomic file-backed format so later GUI settings support can update it without
introducing a database. Compose-only storage and network selections are
mirrored there and in the generated `.env` file.

## Scope

This slice does not include a dedicated-IP or macvlan mode for SFTP, guided
Supervisor or VKr content injection, or stack upgrade.
Those features are planned without changing the depot persistence and config
contracts established here.

Release packaging, image names, and version authority are documented in
[docs/releasing.md](docs/releasing.md).
