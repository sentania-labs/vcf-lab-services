# Release and version contract

The Git tag is the product version authority. Tags match `vMAJOR.MINOR.PATCH`.
The release workflow builds and publishes these license-safe images:

- `ghcr.io/sentania-labs/vcf-lab-services/ui:<tag>`
- `ghcr.io/sentania-labs/vcf-lab-services/sync-base:<tag>`
- `ghcr.io/sentania-labs/vcf-lab-services/sftp:<tag>`

The sync image contains the scheduler and runtime dependencies, never the
licensed VCF Download Tool. The operator supplies that archive through the
console, which stores it on a mounted disposable volume.

## Cutting a release

1. Merge the work to `main`.
2. Tag the merged commit locally: `git tag v0.2.6` (any `vMAJOR.MINOR.PATCH`).
3. Push the tag: `git push origin v0.2.6`.

The workflow does the rest: it runs the full CI gate, builds and publishes the
three images for exactly that tag, proves the published images boot from the
release bundle, and creates or updates the GitHub release with the bundle. No
version-bump commit or PR is required before the tag.

After the CI gate, the publish job refuses two things before building release
images: a tag that is not
shaped like `vMAJOR.MINOR.PATCH`, and a tag whose commit is not reachable from
`origin/main` (a tag pushed from an unmerged branch). That check lives in
`scripts/verify-release-tag.sh` and is exercised by `tests/test_release.sh`.

## Where pinning belongs

This repo builds the product; it is not a deployment repo. The checked-in
image defaults in `docker-compose.yml` and `kubernetes/deployment.yaml` track
the `latest` tags so a source checkout starts the newest release for
quickstart and testing. Compose pulls on `docker compose up`; Kubernetes
checks for the image when a container starts. Reapplying unchanged Kubernetes
manifests does not restart existing Pods. Deployments pin both the image and an
appropriate pull policy. The `VCF_SERVICES_UI_IMAGE`,
`VCF_SERVICES_SYNC_IMAGE`, and `VCF_SERVICES_SFTP_IMAGE` Compose variables and
`VCF_SERVICES_PULL_POLICY`, plus the Kubernetes image and `imagePullPolicy`
fields, carry that deployment policy. This is how `lab-deployment` consumes
the product with an exact release tag and a digest where wanted.

The highest semantic release owns the `latest` image tags, so re-releasing an
older line never moves `latest` backwards. The workflow publishes and proves
all versioned images before it moves any `latest` tag. A failed build, public
visibility check, anonymous pull, or live quickstart proof therefore leaves
`latest` on the last proven release. Each GitHub release bundle carries
a `.env` that pins Compose and a staged `kubernetes/deployment.yaml` whose
five product image references pin the exact release tag. Kubernetes does not
read the Compose `.env`. Packaging leaves the source manifests unchanged.
`install.sh` runs from the bundle, so an operator using its supplied image
settings starts the tagged images rather than `latest`.

After publishing and anonymously pulling the tagged images, the workflow runs
`scripts/verify-published-quickstart.sh` on clean named volumes. This packages
the release bundle for the tag, extracts it, and executes the README
`docker compose up -d` command inside it with no image overrides beyond the
bundle's own pinned `.env`, then proves the containers run the exact tagged
images pulled from GHCR, followed by claim, tool upload, registration, a
partial settings update, and an authenticated HTTPS Range response over the
live API. The GitHub release is not created unless this published-image proof
passes.

Tool archive validation, shared by the upload and depot install paths, is
structural: the archive must contain the expected
binary layout, but the `--version` shape check is deliberately advisory. The
version parser is confirmed against licensed VCF Download Tool output for
`9.1.0.0.25371089`: it scans past the banner, prefers the labelled `Version:`
line, and accepts the bare dotted version as a fallback. The probe remains
advisory by design so a future output-format change does not reject a valid
archive. An unexpected or failed version probe still installs the archive and
marks its version as unverified in the console. The published-quickstart proof
exercises both paths: the CI stub emits licensed-shaped `--version` output
(banner, `Version:` line, bare version, log-file line) and the proof asserts
the parsed version matches the stub exactly, then uploads an unparseable stub
and asserts it installs as unverified without disturbing the saved Software
Depot ID. A failed or implausible
Software Depot ID probe never blocks the install and never replaces the last
verified saved ID; the registration screen reports the probe failure.

The release bundle contains only the Compose and Kubernetes definitions, Caddy
configuration, thin optional bootstrap helper, operational documentation,
license, and Range verification script. It contains no product source and no
licensed content.

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
environment variables and `VCF_SERVICES_PULL_POLICY=never` to use the local
images. This local validation build is for release verification only. Operators never
build an image.
