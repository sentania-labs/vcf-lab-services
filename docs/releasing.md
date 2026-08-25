# Release and version contract

The Git tag is the product version authority. Tags match `vMAJOR.MINOR.PATCH`.
The release workflow builds and publishes these license-safe images:

- `ghcr.io/sentania-labs/vcf-lab-services/ui:<tag>`
- `ghcr.io/sentania-labs/vcf-lab-services/sync-base:<tag>`
- `ghcr.io/sentania-labs/vcf-lab-services/sftp:<tag>`

The sync image contains the scheduler and runtime dependencies, never the
licensed VCF Download Tool. The operator supplies that archive through the
console, which stores it on a mounted disposable volume.

The highest semantic release also owns the `latest` image tags for operators
who deliberately select them. The Compose defaults are pinned to the concrete
release version, so a source checkout and its default images remain the tested
pair even when publication is delayed or fails. Each GitHub release bundle
also includes a `.env` that pins Compose to the same exact release tags.

Preparing a release starts by changing all product image defaults in
`docker-compose.yml` to the intended tag. That change lands before the tag is
pushed, so the tag names images the workflow is about to build. The release
workflow runs `scripts/verify-compose-version.sh` before building or packaging
and fails when any Compose default differs from the pushed tag. For the next
release, repeat the same version bump before tagging.

After publishing and anonymously pulling the tagged images, the workflow runs
`scripts/verify-published-quickstart.sh` on clean named volumes. This executes
the README `docker compose up -d` command with no image overrides, then proves
claim, tool upload, registration, a partial settings update, and an
authenticated HTTPS Range response over the live API. The GitHub release is
not created unless this published-image proof passes.

The release bundle contains only the Compose definition, Caddy configuration,
thin optional bootstrap helper, operational documentation, license, and Range
verification script. It contains no product source and no licensed content.

The workflow's publish step (`scripts/publish-release.sh`, exercised by
`tests/test_release.sh`) is idempotent per tag: it verifies the tag exists
on the remote and creates the GitHub release when none exists. When the
release already exists, it compares each labelled asset against the published
copy, skips identical assets, uploads only missing or differing assets with
`--clobber`, and publishes the release if it is still a draft. Re-running the
workflow for a tag therefore converges instead of failing.

## Local release checks

```bash
./tests/test_release.sh
docker build -t vcf-services-sync-base:local -f Dockerfile.sync-base .
./scripts/verify-license-boundary.sh vcf-services-sync-base:local
```

For the required pre-release live proof, build and tag candidate images with
local override names, then start an isolated Compose project using those image
environment variables. This local validation build is for release verification
only. Operators never build an image.
