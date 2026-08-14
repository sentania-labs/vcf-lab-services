# Validation boundaries

Slice 1 is testable without the licensed VCF Download Tool by running:

```bash
./tests/test_sync.sh
./tests/test_scheduler.sh
./tests/test_install_checks.sh
./tests/test_compose.sh
./tests/test_release.sh
docker build -t vcf-services-sync-base:local -f Dockerfile.sync-base .
./scripts/verify-license-boundary.sh vcf-services-sync-base:local
docker build -t vcf-services-ui:local -f Dockerfile.ui .
docker run --rm -v "$PWD:/work:ro" -w /work vcf-services-ui:local \
  python tests/test_ui.py
```

The repository stub covers installer archive validation, persistent machine-ID
storage, dormant operation, per-target sequencing after a failure, state JSON,
log retention, version parsing, HTTPS authentication, the open UMDS route, and
byte-exact Range responses. The scheduler test covers cron matching, dynamic
schedule reload, duplicate-dispatch prevention, Redis request dispatch
through a stub `redis-cli`, recovery from a malformed `state.json`, and
versions-refresh serialization behind the sync lock. The install checks test
covers cron field bounds (minute, hour, day-of-month, month, day-of-week) and
provided-TLS validation including hostname coverage, key match, and expiry.
The UI test covers next-run calculation in the configured timezone. The compose test statically enforces the captain
decisions: no Docker socket mount, no Docker client dependency, no macvlan, a
non-published password-protected Redis service, published-HTTPS-port-only
networking, and directory-based config mounts compatible with atomic settings
replacement. Live Redis authentication and non-exposure are also hard gates in
`install.sh`. The stub is test-only and is not copied into a
product image unless an operator explicitly supplies its generated archive to
the installer.

The release test dry-runs the versioned installation bundle, verifies its
checksum and required entry points, and proves that the bundle consumes the
published UI and sync base images. The license-boundary check locks the sync
base to an allowlisted build context and inspects the built filesystem for
vendor binary or archive names. CI runs the same checks before any image can be
published.

The following items require captain UAT and are not claimed as verified:

- Actual downloads using the licensed VCFDT binary and a real activation code
- The vendor binary's real machine-ID and version output shapes
- A live NFS export, including capacity reporting and hard-mount behavior
- Consumer trust import in VCF Installer and SDDC Manager

The delivered reference named a VKr mirror file that was absent from its
archive, while the slice scope defers the guided VKr flow. This slice keeps VKr
as an explicit pluggable target, excludes it from defaults, and records a clear
failed target if selected before the later extension is installed.
