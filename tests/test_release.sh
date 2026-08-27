#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d /tmp/vcf-services-release-test.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

version=v0.2.3
repository=ghcr.io/example/vcf-lab-services
if "$project_dir/scripts/verify-compose-version.sh" v0.2.0 \
	"$project_dir/docker-compose.yml" > /dev/null 2>&1; then
	echo "release validation accepted a tag that differs from Compose" >&2
	exit 1
fi
"$project_dir/scripts/verify-compose-version.sh" "$version" \
	"$project_dir/docker-compose.yml" >/dev/null
bad_kubernetes="$work_dir/deployment-wrong-version.yaml"
cp "$project_dir/kubernetes/deployment.yaml" "$bad_kubernetes"
sed -i '0,/ui:v0.2.3/s//ui:v0.2.1/' "$bad_kubernetes"
if "$project_dir/scripts/verify-compose-version.sh" "$version" \
	"$project_dir/docker-compose.yml" "$bad_kubernetes" > /dev/null 2>&1; then
	echo "release validation accepted a Kubernetes image that differs from the tag" >&2
	exit 1
fi
grep -q 'verify-published-quickstart.sh.*GITHUB_REF_NAME' \
	"$project_dir/.github/workflows/release.yml"
grep -q '^docker compose up -d$' \
	"$project_dir/scripts/verify-published-quickstart.sh"
! grep -Eq 'VCF_SERVICES_(UI|SYNC|SFTP)_IMAGE=' \
	"$project_dir/scripts/verify-published-quickstart.sh"
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
	docs/kubernetes.md docs/releasing.md kubernetes/kustomization.yaml \
	kubernetes/namespace.yaml kubernetes/deployment.yaml kubernetes/storage.yaml \
	kubernetes/Caddyfile kubernetes/service.yaml kubernetes/service-sftp.yaml \
	kubernetes/ingress.yaml \
	scripts/verify-byte-exact.sh; do
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
					has_json=false
					has_jq=false
					jq_field=""
					while [ "$#" -gt 0 ]; do
						case "$1" in
							--json) has_json=true; shift ;;
							--jq) has_jq=true; jq_field="$2"; shift 2 ;;
							*) shift ;;
						esac
					done
					if [ "$has_jq" = true ] && [ "$jq_field" = ".isDraft" ]; then
						if [ "${MOCK_RELEASE_IS_DRAFT:-false}" = true ]; then
							echo true
						else
							echo false
						fi
					elif [ "$has_json" = true ]; then
						if [ "${MOCK_RELEASE_IS_DRAFT:-false}" = true ]; then
							echo '{"isDraft":true}'
						else
							echo '{"isDraft":false}'
						fi
					else
						echo "release view ok"
					fi
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
			download)
				if [ "${MOCK_RELEASE_EXISTS:-false}" = true ]; then
					dir="."
					while [ "$#" -gt 0 ]; do
						if [ "$1" = "--dir" ]; then
							dir="$2"
							shift 2
						else
							shift
						fi
					done
					if [ -d "$MOCK_EXISTING_ASSETS_DIR" ]; then
						cp -a "$MOCK_EXISTING_ASSETS_DIR"/* "$dir"/ 2>/dev/null || true
					fi
					exit 0
				else
					exit 1
				fi
				;;
			upload)
				if [ "${MOCK_RELEASE_EXISTS:-false}" = true ]; then
					exit 0
				else
					echo "release not found" >&2
					exit 1
				fi
				;;
			edit)
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
	local is_draft="${3:-false}"
	local existing_assets_dir="${4:-$work_dir/empty_existing}"
	MOCK_RELEASE_EXISTS="$release_exists" \
	MOCK_REMOTE_TAG_EXISTS="$remote_tag_exists" \
	MOCK_RELEASE_IS_DRAFT="$is_draft" \
	MOCK_EXISTING_ASSETS_DIR="$existing_assets_dir" \
	GIT_CALLS_LOG="$git_calls" \
	GH_CALLS_LOG="$gh_calls" \
	PATH="$stub_bin:$PATH" \
	bash "$project_dir/scripts/publish-release.sh" "v1.2.3" "$work_dir/runner_temp/release"
}

mkdir -p "$work_dir/runner_temp/release" "$work_dir/empty_existing"
echo "install script v1" > "$work_dir/runner_temp/release/install.sh"
echo "tarball bytes v1" > "$work_dir/runner_temp/release/vcf-lab-services-v1.2.3.tar.gz"
echo "checksum hash v1" > "$work_dir/runner_temp/release/vcf-lab-services-v1.2.3.tar.gz.sha256"

# 1. When release does not exist: creates release with --verify-tag, --generate-notes, --title
: > "$gh_calls"
: > "$git_calls"
create_output="$(run_release_step false true false)"
grep -q 'Release v1.2.3 does not exist; creating release.' <<< "$create_output"
grep -q '^release view v1.2.3$' "$gh_calls"
grep -q '^release create v1.2.3 .*/install.sh#Installer entry point .*/vcf-lab-services-v1.2.3.tar.gz#Installation bundle .*/vcf-lab-services-v1.2.3.tar.gz.sha256#Installation bundle checksum --verify-tag --generate-notes --title v1.2.3$' "$gh_calls"
grep -q '^ls-remote --exit-code --tags origin refs/tags/v1.2.3$' "$git_calls"

# 2. When published release exists with missing assets: uploads missing assets with --clobber, no edit --draft=false
: > "$gh_calls"
: > "$git_calls"
upload_output="$(run_release_step true true false "$work_dir/empty_existing")"
grep -q 'Release v1.2.3 already exists; inspecting existing release and assets.' <<< "$upload_output"
grep -q '^release view v1.2.3$' "$gh_calls"
grep -q '^release upload v1.2.3 .*/install.sh#Installer entry point .*/vcf-lab-services-v1.2.3.tar.gz#Installation bundle .*/vcf-lab-services-v1.2.3.tar.gz.sha256#Installation bundle checksum --clobber$' "$gh_calls"
! grep -q '^release create' "$gh_calls"
! grep -q '^release edit' "$gh_calls"
grep -q '^ls-remote --exit-code --tags origin refs/tags/v1.2.3$' "$git_calls"

# 3. When draft release exists with missing assets (draft recovery): uploads assets and publishes release with edit --draft=false
: > "$gh_calls"
: > "$git_calls"
draft_output="$(run_release_step true true true "$work_dir/empty_existing")"
grep -q 'Release v1.2.3 is a draft; publishing release.' <<< "$draft_output"
grep -q '^release upload v1.2.3' "$gh_calls"
grep -q '^release edit v1.2.3 --draft=false$' "$gh_calls"

# 4. When all assets already match: skips upload entirely
matched_assets="$work_dir/matched_assets"
mkdir -p "$matched_assets"
cp "$work_dir/runner_temp/release"/* "$matched_assets/"
: > "$gh_calls"
: > "$git_calls"
skip_output="$(run_release_step true true false "$matched_assets")"
grep -q 'Asset install.sh already exists and matches; skipping upload.' <<< "$skip_output"
grep -q 'Asset vcf-lab-services-v1.2.3.tar.gz already exists and matches; skipping upload.' <<< "$skip_output"
grep -q 'Asset vcf-lab-services-v1.2.3.tar.gz.sha256 already exists and matches; skipping upload.' <<< "$skip_output"
! grep -q '^release upload' "$gh_calls"

# 5. When one asset differs and others match: uploads ONLY the differing asset
partial_assets="$work_dir/partial_assets"
mkdir -p "$partial_assets"
cp "$work_dir/runner_temp/release"/* "$partial_assets/"
echo "different checksum hash" > "$partial_assets/vcf-lab-services-v1.2.3.tar.gz.sha256"
: > "$gh_calls"
: > "$git_calls"
partial_output="$(run_release_step true true false "$partial_assets")"
grep -q 'Asset install.sh already exists and matches; skipping upload.' <<< "$partial_output"
grep -q 'Asset vcf-lab-services-v1.2.3.tar.gz already exists and matches; skipping upload.' <<< "$partial_output"
grep -q 'Asset vcf-lab-services-v1.2.3.tar.gz.sha256 is missing or differs; queuing for upload.' <<< "$partial_output"
grep -q '^release upload v1.2.3 .*/vcf-lab-services-v1.2.3.tar.gz.sha256#Installation bundle checksum --clobber$' "$gh_calls"
! grep -q 'install.sh' <(grep '^release upload' "$gh_calls")

# 6. When tag does not exist remotely: fails before create or upload
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
