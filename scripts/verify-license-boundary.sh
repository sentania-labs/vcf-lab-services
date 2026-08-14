#!/bin/bash
set -euo pipefail

image="${1:?usage: verify-license-boundary.sh IMAGE}"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

tracked_vendor_artifacts="$(
	cd "$project_dir"
	git ls-files | grep -E '(^|/)vcf-download-tool$|vcf-download-tool-.*\.(tar\.gz|tgz|zip)$' || true
)"
if [ -n "$tracked_vendor_artifacts" ]; then
	echo "ERROR: licensed VCF Download Tool content is tracked:" >&2
	printf '%s\n' "$tracked_vendor_artifacts" >&2
	exit 1
fi

expected_ignore="$(mktemp /tmp/vcf-services-sync-base-ignore.XXXXXX)"
image_export="$(mktemp /tmp/vcf-services-sync-base-export.XXXXXX)"
image_listing="$(mktemp /tmp/vcf-services-sync-base-listing.XXXXXX)"
container_id=""
cleanup() {
	rm -f "$expected_ignore" "$image_export" "$image_listing"
	if [ -n "$container_id" ]; then
		docker rm "$container_id" >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

cat > "$expected_ignore" <<'EOF'
*
!Dockerfile.sync-base
!sync/
!sync/**
EOF
if ! cmp -s "$expected_ignore" "$project_dir/Dockerfile.sync-base.dockerignore"; then
	echo "ERROR: the sync-base build context allowlist changed" >&2
	diff -u "$expected_ignore" "$project_dir/Dockerfile.sync-base.dockerignore" >&2 || true
	exit 1
fi

container_id="$(docker create "$image")"
if ! docker export "$container_id" -o "$image_export"; then
	echo "ERROR: docker export failed for $image; boundary not verified" >&2
	exit 1
fi
if ! tar -tf "$image_export" > "$image_listing"; then
	echo "ERROR: could not list the exported filesystem of $image; boundary not verified" >&2
	exit 1
fi
if grep -E '(^|/)vcf-download-tool$|vcf-download-tool-.*\.(tar\.gz|tgz|zip)$' "$image_listing"; then
	echo "ERROR: the sync base image contains VCF Download Tool content" >&2
	exit 1
fi

echo "Licensed vendor content boundary verified for $image"
