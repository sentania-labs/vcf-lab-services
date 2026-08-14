# Release and version contract

The Git tag is the single source of truth for a VCF Services release. Release
tags must match `vMAJOR.MINOR.PATCH`, for example `v1.2.3`. The release workflow
rejects any tag that does not match exactly.

For a release tag, the workflow publishes these version-specific images under
the current GitHub repository's GHCR namespace:

- `ui:vMAJOR.MINOR.PATCH`
- `sync-base:vMAJOR.MINOR.PATCH`

The same image digests also receive the convenience tag `latest`. The exact
release tag is embedded in both images as the
`org.opencontainers.image.version` label and the `VCF_SERVICES_VERSION`
environment value. Future installer upgrade and GUI release-check work must
compare against that exact tag value rather than maintaining a separate
version file.

The sync base is intentionally incomplete. It contains the scheduler, sync
scripts, and runtime dependencies, but never the licensed VCF Download Tool.
The installer pulls that base and layers the operator's portal-downloaded
archive into `vcf-services-sync:local`. Only that local image contains the
vendor tool. CI enforces the boundary with an allowlisted Docker build context
and an inspection of the built base image before publication.

Each GitHub release carries three operator-facing assets:

- `install.sh`, the auditable installer entry point
- `vcf-lab-services-vMAJOR.MINOR.PATCH.tar.gz`, the runnable installation
  bundle containing the installer and its required companion files
- the bundle's SHA-256 checksum

The bundle records the release tag and image repository in `.release.env`.
Operators download the bundle instead of cloning a tag. The installer refuses
to run without valid release metadata, which prevents an installer from
silently mixing one release with another release's images.

## Local release-path proof

Run the packaging and licensing checks without publishing anything:

```bash
./tests/test_release.sh
docker build -t vcf-services-sync-base:dry-run -f Dockerfile.sync-base .
./scripts/verify-license-boundary.sh vcf-services-sync-base:dry-run
```

These checks prove bundle construction, checksum verification, image version
metadata, and exclusion of licensed content. Only a real release tag can prove
GHCR authentication, package upload, GitHub release creation, and asset
download from GitHub.
