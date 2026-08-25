#!/bin/bash
set -euo pipefail

version="${1:?usage: package-release.sh VERSION OUTPUT_DIR IMAGE_REPOSITORY}"
output_dir="${2:?usage: package-release.sh VERSION OUTPUT_DIR IMAGE_REPOSITORY}"
image_repository="${3:?usage: package-release.sh VERSION OUTPUT_DIR IMAGE_REPOSITORY}"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
	echo "ERROR: release version must match vMAJOR.MINOR.PATCH" >&2
	exit 2
}
[[ "$image_repository" =~ ^ghcr\.io/[a-z0-9._-]+/[a-z0-9._-]+$ ]] || {
	echo "ERROR: image repository must be a lowercase GHCR repository path" >&2
	exit 2
}
"$project_dir/scripts/verify-compose-version.sh" "$version" "$project_dir/docker-compose.yml"

release_name="vcf-lab-services-$version"
stage_dir="$(mktemp -d /tmp/vcf-services-release.XXXXXX)"
trap 'rm -rf "$stage_dir"' EXIT
bundle_root="$stage_dir/$release_name"
mkdir -p "$bundle_root" "$output_dir"

files=(
	LICENSE
	README.md
	docker-compose.yml
	compose.sh
	install.sh
	caddy/Caddyfile
	docs/redis-contract.md
	docs/releasing.md
	scripts/verify-byte-exact.sh
)
for file in "${files[@]}"; do
	[ -f "$project_dir/$file" ] || { echo "ERROR: release file is missing: $file" >&2; exit 1; }
	mkdir -p "$bundle_root/$(dirname "$file")"
	cp "$project_dir/$file" "$bundle_root/$file"
done

cat > "$bundle_root/.release.env" <<EOF
VCF_SERVICES_VERSION=$version
VCF_SERVICES_IMAGE_REPOSITORY=$image_repository
EOF
cat > "$bundle_root/.env" <<EOF
VCF_SERVICES_UI_IMAGE=$image_repository/ui:$version
VCF_SERVICES_SYNC_IMAGE=$image_repository/sync-base:$version
VCF_SERVICES_SFTP_IMAGE=$image_repository/sftp:$version
EOF

archive="$output_dir/$release_name.tar.gz"
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
	-czf "$archive" -C "$stage_dir" "$release_name"
(
	cd "$output_dir"
	sha256sum "$release_name.tar.gz" > "$release_name.tar.gz.sha256"
)
cp "$project_dir/install.sh" "$output_dir/install.sh"

echo "$archive"
