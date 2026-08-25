#!/bin/bash
set -euo pipefail

version="${1:?usage: publish-release.sh VERSION RELEASE_DIR}"
release_dir="${2:?usage: publish-release.sh VERSION RELEASE_DIR}"

# Verify the tag exists remotely before creating or uploading to a release
git ls-remote --exit-code --tags origin "refs/tags/$version" >/dev/null

assets=(
	"$release_dir/install.sh#Installer entry point"
	"$release_dir/vcf-lab-services-$version.tar.gz#Installation bundle"
	"$release_dir/vcf-lab-services-$version.tar.gz.sha256#Installation bundle checksum"
)

if gh release view "$version" >/dev/null 2>&1; then
	echo "Release $version already exists; inspecting existing release and assets."
	is_draft="$(gh release view "$version" --json isDraft --jq .isDraft)"

	# Check existing assets and upload only missing or differing assets
	existing_dir="$(mktemp -d)"
	gh release download "$version" --dir "$existing_dir" >/dev/null 2>&1 || true

	upload_assets=()
	for asset_spec in "${assets[@]}"; do
		asset_path="${asset_spec%%#*}"
		asset_name="$(basename "$asset_path")"
		if [ -f "$existing_dir/$asset_name" ] && cmp -s "$asset_path" "$existing_dir/$asset_name"; then
			echo "Asset $asset_name already exists and matches; skipping upload."
		else
			echo "Asset $asset_name is missing or differs; queuing for upload."
			upload_assets+=("$asset_spec")
		fi
	done
	rm -rf "$existing_dir"

	if [ "${#upload_assets[@]}" -gt 0 ]; then
		gh release upload "$version" "${upload_assets[@]}" --clobber
	fi

	if [ "$is_draft" = "true" ]; then
		echo "Release $version is a draft; publishing release."
		gh release edit "$version" --draft=false
	fi
else
	echo "Release $version does not exist; creating release."
	gh release create "$version" \
		"${assets[@]}" \
		--verify-tag \
		--generate-notes \
		--title "$version"
fi
