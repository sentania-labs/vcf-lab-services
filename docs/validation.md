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
setup completion, shared password replacement, sync dispatch, partial settings
merges over the stored document, advisory tool version and Software Depot ID
probes that preserve the last verified ID, and config version marker
quarantine. The Compose test enforces release-pinned published-image defaults,
first-boot state initialization, internal TLS, the platform-provided storage
boundary, protected Redis, fixed mount contracts, version mismatch safe-stop
wiring, and the absence of a Docker socket. Shell tests cover scheduler timing,
single-writer sync behavior, sync safe-stop on a version mismatch, log
retention, SFTP identity and host keys, Range serving, packaging, rejection of
release tags that disagree with the Compose defaults, idempotent release
publication, and license isolation.

`tests/test_install_checks.sh` is a regression guard, not a gate for a
reachable operator path. It exercises the retained depot-adoption scripts
(`scripts/install-checks.sh`, `scripts/import-vcfdt-state.sh`, and
`scripts/validate-adopted-depot.sh`) that let an existing VCFDT depot and
Software Depot ID be adopted without re-downloading. The GUI-first prototype
removed their installer entry point, so adoption currently has no reachable
path and needs a console path before that flow can be claimed working. The
scripts stay in place until that console path exists.

Release validation also requires a live HTTP walk through claim, upload,
registration, and settings, plus an authenticated HTTPS Range request. The
release workflow repeats this proof against the published tagged images on
clean volumes before creating the GitHub release. Healthy containers alone are
not sufficient.

The stub cannot verify these claims:

- Actual machine ID output from the licensed VCF Download Tool. Version
  output is already confirmed against captured licensed tool output (see
  `docs/releasing.md`).
- Registration and download with a real activation code.
- A real content sync and consumption by VCF Installer, SDDC Manager, UMDS, or
  Fleet.
- Consumer trust import for the Caddy internal CA.
- NSX, vCenter, and SDDC Manager backup uploads against the live SFTP service.

Those remain captain UAT items and must be named in the PR and release notes.
