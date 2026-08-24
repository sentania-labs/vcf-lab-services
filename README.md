# vcf-services

`vcf-services` is a self-hosted Docker Compose appliance for services that sit
beside a VMware Cloud Foundation fleet. This first slice provides an HTTPS
offline depot, a scheduled VCF Download Tool sync engine, and an admin console.
The layout leaves room for the optional file backup target planned for the next
slice.

The licensed VCF Download Tool is never included, downloaded, or redistributed
by this project. You provide the archive obtained from the Broadcom support
portal during installation.

Run `./install.sh` for the first installation: `docker compose up` alone cannot work because the installer layers your operator-supplied licensed tool into a local image and creates its protected state volume.

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

If you need to start the stack manually after installation, use
`./compose.sh up -d`. It checks the install-created state volume and local sync
image before invoking Compose. The normal day-to-day commands remain direct
Compose commands:

```bash
docker compose ps
docker exec vcf-services-sync /usr/local/bin/sync.sh --status
docker exec vcf-services-sync /usr/local/bin/sync.sh patches
docker compose logs -f depot-sync
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
unauthenticated health route, without an insecure TLS option:

```bash
curl --fail --show-error https://vcf-services.example.com/healthz
```

An `ok` response means UMDS will accept the depot certificate. A TLS error means
the trust store still lacks the certificate.

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
