#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d /tmp/vcf-services-release-test.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

version=v0.0.0
repository=ghcr.io/example/vcf-lab-services
"$project_dir/scripts/package-release.sh" "$version" "$work_dir" "$repository" >/dev/null

archive="$work_dir/vcf-lab-services-$version.tar.gz"
[ -s "$archive" ]
[ -s "$archive.sha256" ]
[ -x "$work_dir/install.sh" ]
(
	cd "$work_dir"
	sha256sum -c "$(basename "$archive.sha256")"
)

required=(
	"vcf-lab-services-$version/.release.env"
	"vcf-lab-services-$version/install.sh"
	"vcf-lab-services-$version/docker-compose.yml"
	"vcf-lab-services-$version/Dockerfile.sync"
	"vcf-lab-services-$version/Dockerfile.sync.dockerignore"
	"vcf-lab-services-$version/caddy/Caddyfile"
	"vcf-lab-services-$version/docs/releasing.md"
	"vcf-lab-services-$version/scripts/install-checks.sh"
)
listing="$(tar -tzf "$archive")"
for path in "${required[@]}"; do
	grep -qx "$path" <<< "$listing"
done
! grep -Eq 'Dockerfile\.sync-base|Dockerfile\.ui|(^|/)ui/|(^|/)sync/' <<< "$listing"

tar -xzf "$archive" -C "$work_dir"
grep -qx "VCF_SERVICES_VERSION=$version" "$work_dir/vcf-lab-services-$version/.release.env"
grep -qx "VCF_SERVICES_IMAGE_REPOSITORY=$repository" "$work_dir/vcf-lab-services-$version/.release.env"
"$project_dir/tests/make-stub-vcfdt.sh" "$work_dir/vcf-download-tool-0.0.0-stub.tar.gz" >/dev/null
"$work_dir/vcf-lab-services-$version/install.sh" \
	--validate-archive "$work_dir/vcf-download-tool-0.0.0-stub.tar.gz" >/dev/null

grep -q 'docker pull "$ui_image"' "$project_dir/install.sh"
grep -q 'docker pull "$sync_base_image"' "$project_dir/install.sh"
! grep -q 'Dockerfile.sync-base' "$project_dir/install.sh"
grep -q 'SYNC_BASE_IMAGE=$sync_base_image' "$project_dir/install.sh"
grep -q 'VCF_SERVICES_UI_IMAGE' "$project_dir/docker-compose.yml"
grep -qx '!build/vcfdt/\*\*' "$project_dir/Dockerfile.sync.dockerignore"

echo "release packaging and image-consumption contract tests passed"
