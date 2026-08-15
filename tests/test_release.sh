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

grep -q 'pull_product_image "$ui_image"' "$project_dir/install.sh"
grep -q 'pull_product_image "$sync_base_image"' "$project_dir/install.sh"
grep -q 'docker pull "$image"' "$project_dir/install.sh"
grep -q 'could not pull \$image' "$project_dir/install.sh"
! grep -q 'Dockerfile.sync-base' "$project_dir/install.sh"
grep -q 'SYNC_BASE_IMAGE=$sync_base_image' "$project_dir/install.sh"
grep -q 'VCF_SERVICES_UI_IMAGE' "$project_dir/docker-compose.yml"
grep -qx '!build/vcfdt/\*\*' "$project_dir/Dockerfile.sync.dockerignore"

bundle_dir="$work_dir/vcf-lab-services-$version"
source_dir="$work_dir/source-checkout"
cp -a "$bundle_dir" "$source_dir"
rm -f "$source_dir/.release.env"

expect_failure() {
	local expected_status="$1" expected_text="$2" status=0 output
	shift 2
	output="$("$@" 2>&1 </dev/null)" || status=$?
	[ "$status" -eq "$expected_status" ] || {
		echo "expected exit $expected_status, got $status from: $*" >&2
		printf '%s\n' "$output" >&2
		exit 1
	}
	grep -q -e "$expected_text" <<< "$output" || {
		echo "expected output to mention: $expected_text" >&2
		printf '%s\n' "$output" >&2
		exit 1
	}
}

# A source checkout with no origin remote cannot derive images, and says so.
expect_failure 1 '--image-repository REPOSITORY' "$source_dir/install.sh"

# An explicit image repository restores installation from a source checkout:
# metadata resolution succeeds and the run reaches the first answer prompt.
expect_failure 2 'VCFDT_ARCHIVE is missing' \
	"$source_dir/install.sh" --image-repository ghcr.io/example/vcf-lab-services
expect_failure 2 'VCFDT_ARCHIVE is missing' \
	"$source_dir/install.sh" --image-repository ghcr.io/example/vcf-lab-services --version v9.9.9

# Overrides are still validated.
expect_failure 2 'not a valid Docker tag' \
	"$source_dir/install.sh" --image-repository ghcr.io/example/vcf-lab-services --version 'bad tag'
expect_failure 2 'not a valid lowercase repository path' \
	"$source_dir/install.sh" --image-repository 'GHCR.IO/Example/Repo'

# Bundle metadata stays strict.
printf 'VCF_SERVICES_UNEXPECTED=1\n' > "$bundle_dir/.release.env"
expect_failure 1 'unsupported release metadata key' "$bundle_dir/install.sh"
printf 'VCF_SERVICES_VERSION=1.0\nVCF_SERVICES_IMAGE_REPOSITORY=%s\n' "$repository" > "$bundle_dir/.release.env"
expect_failure 1 'invalid version' "$bundle_dir/install.sh"
printf 'VCF_SERVICES_VERSION=%s\nVCF_SERVICES_IMAGE_REPOSITORY=docker.io/example/repo\n' "$version" > "$bundle_dir/.release.env"
expect_failure 1 'invalid image repository' "$bundle_dir/install.sh"

echo "release packaging and image-consumption contract tests passed"
