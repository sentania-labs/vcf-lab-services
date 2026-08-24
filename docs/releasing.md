# Release and version contract

The Git tag is the single source of truth for a VCF Services release. Release
tags must match `vMAJOR.MINOR.PATCH`, for example `v1.2.3`. The release workflow
rejects any tag that does not match exactly.

For a release tag, the workflow publishes these version-specific images under
the current GitHub repository's GHCR namespace:

- `ui:vMAJOR.MINOR.PATCH`
- `sync-base:vMAJOR.MINOR.PATCH`
- `sftp:vMAJOR.MINOR.PATCH`

The `latest` convenience tags follow the highest semantic version that exists
in the repository, so a back-port tag such as `v1.0.1` pushed after `v1.1.0`
publishes only its exact version tags and leaves `latest` on `v1.1.0`. The exact
release tag is embedded in every image as the
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
Operators download the bundle instead of cloning a tag; that is the normal and
supported operator path. When `.release.env` is present the installer requires
it to be valid, which prevents an installer from silently mixing one release
with another release's images. A locally created `.release.env` is ignored by
Git so a test copy can never be committed.

## Package visibility

All container packages are intentionally public. This product is public and
its installer pulls without any registry credentials, so a private package
breaks every operator install. GHCR can create a package as private on its
first publish, so the release workflow sets every package public through the
GitHub API, hard-fails if any of them is not public, and proves a credential-free
pull before the GitHub release is created. The installer never carries registry
credentials. If the workflow's token cannot change package visibility, add a
`GHCR_VISIBILITY_TOKEN` repository secret with `admin:packages`, or set the
packages public once by hand; the verification gate stays either way.

## Source-checkout installs

A source checkout has no `.release.env`. In that case the installer derives the
image repository from the checkout's `origin` remote and defaults the image tag
to `latest`. Two flags override that:

- `--image-repository REPOSITORY`, for example `ghcr.io/example/vcf-lab-services`
- `--version TAG`, any published image tag

Both flags are source-checkout only. When a packaged bundle's `.release.env` is
present the installer rejects them, so a bundle always installs exactly the
images its release published.

In this mode the installer uses an image that is already present locally
instead of pulling it, which is what makes the pre-release live proof possible.

## Local release-path proof

Run the packaging and licensing checks without publishing anything:

```bash
./tests/test_release.sh
docker build -t vcf-services-sync-base:dry-run -f Dockerfile.sync-base .
./scripts/verify-license-boundary.sh vcf-services-sync-base:dry-run
```

For the pre-release live proof required by `AGENTS.md`, build and locally tag
the candidate images with the names the installer expects, then install from
the source checkout so nothing has to be published first:

```bash
candidate=v0.0.0-rc
repo=ghcr.io/$(git config --get remote.origin.url | sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#' | tr 'A-Z' 'a-z')
docker build --build-arg "VCF_SERVICES_VERSION=$candidate" -f Dockerfile.ui -t "$repo/ui:$candidate" .
docker build --build-arg "VCF_SERVICES_VERSION=$candidate" -f Dockerfile.sync-base -t "$repo/sync-base:$candidate" .
docker build --build-arg "VCF_SERVICES_VERSION=$candidate" -f Dockerfile.sftp -t "$repo/sftp:$candidate" .
./install.sh --version "$candidate"
```

That run performs the installer's live HTTPS Range check against the images
that the tag will publish. Then tag the release.

These checks prove bundle construction, checksum verification, image version
metadata, exclusion of licensed content, and the live installed stack. Only a
real release tag can prove GHCR authentication, package upload, package
visibility, GitHub release creation, and asset download from GitHub.
