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

# Test GitHub release publication convergence (create-when-absent vs upload-when-present)
stub_bin="$work_dir/bin"
mkdir -p "$stub_bin"
gh_calls="$work_dir/gh.calls"
git_calls="$work_dir/git.calls"
touch "$gh_calls" "$git_calls"

cat > "$stub_bin/git" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GIT_CALLS_LOG"
case "$1" in
	ls-remote)
		if [ "${MOCK_REMOTE_TAG_EXISTS:-true}" = true ]; then
			exit 0
		else
			exit 2
		fi
		;;
	*)
		exec /usr/bin/git "$@"
		;;
esac
EOF
chmod 0755 "$stub_bin/git"

cat > "$stub_bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_CALLS_LOG"
case "$1" in
	release)
		case "$2" in
			view)
				if [ "${MOCK_RELEASE_EXISTS:-false}" = true ]; then
					exit 0
				else
					exit 1
				fi
				;;
			create)
				if [ "${MOCK_RELEASE_EXISTS:-false}" = true ]; then
					echo "a release with the same tag name already exists: $3" >&2
					exit 1
				fi
				exit 0
				;;
			upload)
				if [ "${MOCK_RELEASE_EXISTS:-false}" = true ]; then
					exit 0
				else
					echo "release not found" >&2
					exit 1
				fi
				;;
			*) exit 2 ;;
		esac
		;;
	*) exit 2 ;;
esac
EOF
chmod 0755 "$stub_bin/gh"

run_release_step() {
	local release_exists="$1"
	local remote_tag_exists="${2:-true}"
	MOCK_RELEASE_EXISTS="$release_exists" \
	MOCK_REMOTE_TAG_EXISTS="$remote_tag_exists" \
	GIT_CALLS_LOG="$git_calls" \
	GH_CALLS_LOG="$gh_calls" \
	PATH="$stub_bin:$PATH" \
	RUNNER_TEMP="$work_dir/runner_temp" \
	GITHUB_REF_NAME="v1.2.3" \
	bash -euo pipefail -c '
		version="$GITHUB_REF_NAME"
		git ls-remote --exit-code --tags origin "refs/tags/$version" >/dev/null

		assets=(
			"$RUNNER_TEMP/release/install.sh#Installer entry point"
			"$RUNNER_TEMP/release/vcf-lab-services-$version.tar.gz#Installation bundle"
			"$RUNNER_TEMP/release/vcf-lab-services-$version.tar.gz.sha256#Installation bundle checksum"
		)

		if gh release view "$version" >/dev/null 2>&1; then
			echo "Release $version already exists; uploading assets with --clobber."
			gh release upload "$version" "${assets[@]}" --clobber
		else
			echo "Release $version does not exist; creating release."
			gh release create "$version" \
				"${assets[@]}" \
				--verify-tag \
				--generate-notes \
				--title "$version"
		fi
	'
}

mkdir -p "$work_dir/runner_temp/release"
touch "$work_dir/runner_temp/release/install.sh" \
	"$work_dir/runner_temp/release/vcf-lab-services-v1.2.3.tar.gz" \
	"$work_dir/runner_temp/release/vcf-lab-services-v1.2.3.tar.gz.sha256"

# 1. When release does not exist: creates release with --verify-tag, --generate-notes, --title
: > "$gh_calls"
: > "$git_calls"
create_output="$(run_release_step false true)"
grep -q 'Release v1.2.3 does not exist; creating release.' <<< "$create_output"
grep -q '^release view v1.2.3$' "$gh_calls"
grep -q '^release create v1.2.3 .*/install.sh#Installer entry point .*/vcf-lab-services-v1.2.3.tar.gz#Installation bundle .*/vcf-lab-services-v1.2.3.tar.gz.sha256#Installation bundle checksum --verify-tag --generate-notes --title v1.2.3$' "$gh_calls"
grep -q '^ls-remote --exit-code --tags origin refs/tags/v1.2.3$' "$git_calls"

# 2. When release already exists: uploads assets with --clobber
: > "$gh_calls"
: > "$git_calls"
upload_output="$(run_release_step true true)"
grep -q 'Release v1.2.3 already exists; uploading assets with --clobber.' <<< "$upload_output"
grep -q '^release view v1.2.3$' "$gh_calls"
grep -q '^release upload v1.2.3 .*/install.sh#Installer entry point .*/vcf-lab-services-v1.2.3.tar.gz#Installation bundle .*/vcf-lab-services-v1.2.3.tar.gz.sha256#Installation bundle checksum --clobber$' "$gh_calls"
! grep -q '^release create' "$gh_calls"
grep -q '^ls-remote --exit-code --tags origin refs/tags/v1.2.3$' "$git_calls"

# 3. When tag does not exist remotely: fails before create or upload
: > "$gh_calls"
: > "$git_calls"
set +e
run_release_step false false >/dev/null 2>&1
tag_missing_rc=$?
set -e
[ "$tag_missing_rc" -ne 0 ]
! grep -q '^release create' "$gh_calls"
! grep -q '^release upload' "$gh_calls"

echo "release packaging and published-image contract tests passed"
