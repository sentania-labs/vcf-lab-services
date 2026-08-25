# Validation boundaries

Run the repository gates before release:

```bash
./tests/test_sync.sh
./tests/test_scheduler.sh
./tests/test_install_checks.sh
./tests/test_compose.sh
./tests/test_release.sh
./tests/test_sftp.sh
docker build -t vcf-services-sync-base:local -f Dockerfile.sync-base .
./scripts/verify-license-boundary.sh vcf-services-sync-base:local
docker build -t vcf-services-ui:local -f Dockerfile.ui .
docker build -t vcf-services-sftp:local -f Dockerfile.sftp .
docker run --rm -v "$PWD:/work:ro" -w /work vcf-services-ui:local \
  python tests/test_ui.py
```

The UI test covers first-person ownership, login, live depot authentication,
licensed archive staging, persistent Software Depot ID retrieval, activation
secret storage, storage confirmation, recurring schedule and endpoint editing,
setup completion, shared password replacement, sync dispatch, and version
parsing. The Compose test enforces published-image defaults, first-boot state
initialization, internal TLS, the platform-provided storage boundary, protected
Redis, fixed mount contracts, and the absence of a Docker socket. Shell tests
cover scheduler timing, single-writer sync behavior, log retention, SFTP
identity and host keys, Range serving, packaging, and license isolation.

Release validation also requires a real rendered browser check and live HTTPS
Range request against the candidate containers. A healthy container alone is
not sufficient.

The stub cannot verify these claims:

- Actual machine ID and version output from the licensed VCF Download Tool.
- Registration and download with a real activation code.
- A real content sync and consumption by VCF Installer, SDDC Manager, UMDS, or
  Fleet.
- Consumer trust import for the Caddy internal CA.
- NSX, vCenter, and SDDC Manager backup uploads against the live SFTP service.

Those remain captain UAT items and must be named in the PR and release notes.
