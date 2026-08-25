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

bundle="vcf-lab-services-$version"
listing="$(tar -tzf "$archive")"
for path in .release.env .env install.sh compose.sh docker-compose.yml caddy/Caddyfile \
	docs/releasing.md scripts/verify-byte-exact.sh; do
	grep -qx "$bundle/$path" <<< "$listing"
done
! grep -Eq 'Dockerfile|(^|/)ui/|(^|/)sync/|config/answers' <<< "$listing"

tar -xzf "$archive" -C "$work_dir"
bundle_dir="$work_dir/$bundle"
grep -qx "VCF_SERVICES_VERSION=$version" "$bundle_dir/.release.env"
grep -qx "VCF_SERVICES_IMAGE_REPOSITORY=$repository" "$bundle_dir/.release.env"
grep -qx "VCF_SERVICES_UI_IMAGE=$repository/ui:$version" "$bundle_dir/.env"
grep -qx "VCF_SERVICES_SYNC_IMAGE=$repository/sync-base:$version" "$bundle_dir/.env"
grep -qx "VCF_SERVICES_SFTP_IMAGE=$repository/sftp:$version" "$bundle_dir/.env"

grep -q '^docker compose pull$' "$project_dir/install.sh"
grep -q '^docker compose up -d$' "$project_dir/install.sh"
! grep -q 'docker build' "$project_dir/install.sh"
! grep -Eq 'read -r|ask\(|answers-file|VCFDT' "$project_dir/install.sh"
! grep -Eq 'NFS_|STORAGE_MODE|DEPOT_LOCAL_PATH|BACKUP_LOCAL_PATH' "$project_dir/install.sh"

for image in ui sync-base sftp; do
	grep -q "VCF_SERVICES_.*IMAGE=.*$repository/$image:$version" "$bundle_dir/.env"
done

echo "release packaging and published-image contract tests passed"
