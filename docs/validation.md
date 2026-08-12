# Validation boundaries

Slice 1 is testable without the licensed VCF Download Tool by running:

```bash
./tests/test_sync.sh
docker run --rm -v "$PWD:/work:ro" -w /work vcf-services-ui:local \
  python tests/test_ui.py
```

The repository stub covers installer archive validation, persistent machine-ID
storage, dormant operation, per-target sequencing after a failure, state JSON,
log retention, version parsing, HTTPS authentication, the open UMDS route, and
byte-exact Range responses. The stub is test-only and is not copied into a
product image unless an operator explicitly supplies its generated archive to
the installer.

The following items require captain UAT and are not claimed as verified:

- Actual downloads using the licensed VCFDT binary and a real activation code
- The vendor binary's real machine-ID and version output shapes
- A live NFS export, including capacity reporting and hard-mount behavior
- A live pre-existing macvlan network and reserved address
- Consumer trust import in VCF Installer and SDDC Manager

The delivered reference named a VKr mirror file that was absent from its
archive, while the slice scope defers the guided VKr flow. This slice keeps VKr
as an explicit pluggable target, excludes it from defaults, and records a clear
failed target if selected before the later extension is installed.
