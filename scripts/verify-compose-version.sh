#!/bin/bash
set -euo pipefail

release_version="${1:?usage: verify-compose-version.sh RELEASE_VERSION [COMPOSE_FILE] [KUBERNETES_FILE]}"
compose_file="${2:-docker-compose.yml}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
kubernetes_file="${3:-$script_dir/../kubernetes/deployment.yaml}"

[[ "$release_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
	echo "ERROR: release version must match vMAJOR.MINOR.PATCH" >&2
	exit 2
}
[ -f "$compose_file" ] || {
	echo "ERROR: Compose file is missing: $compose_file" >&2
	exit 2
}

mapfile -t defaults < <(
	sed -nE 's#.*ghcr\.io/sentania-labs/vcf-lab-services/(ui|sync-base|sftp):(v[0-9]+\.[0-9]+\.[0-9]+).*#\1 \2#p' "$compose_file"
)
[ "${#defaults[@]}" -eq 4 ] || {
	echo "ERROR: expected four pinned VCF Services image defaults in $compose_file" >&2
	exit 1
}

declare -A seen=()
for entry in "${defaults[@]}"; do
	component="${entry%% *}"
	compose_version="${entry#* }"
	seen["$component"]=$(( ${seen["$component"]:-0} + 1 ))
	if [ "$compose_version" != "$release_version" ]; then
		echo "ERROR: $component defaults to $compose_version, release tag is $release_version" >&2
		exit 1
	fi
done
[ "${seen[ui]:-0}" -eq 2 ] && [ "${seen[sync-base]:-0}" -eq 1 ] \
	&& [ "${seen[sftp]:-0}" -eq 1 ] || {
	echo "ERROR: Compose image defaults do not cover bootstrap, UI, sync-base, and SFTP" >&2
	exit 1
}

echo "Compose defaults match release $release_version"

[ -f "$kubernetes_file" ] || {
	echo "ERROR: Kubernetes deployment is missing: $kubernetes_file" >&2
	exit 2
}
mapfile -t kubernetes_defaults < <(
	sed -nE 's#.*image: ghcr\.io/sentania-labs/vcf-lab-services/(ui|sync-base|sftp):(v[0-9]+\.[0-9]+\.[0-9]+).*#\1 \2#p' \
		"$kubernetes_file"
)
[ "${#kubernetes_defaults[@]}" -eq 5 ] || {
	echo "ERROR: expected five pinned VCF Services images in $kubernetes_file" >&2
	exit 1
}
declare -A kubernetes_seen=()
for entry in "${kubernetes_defaults[@]}"; do
	component="${entry%% *}"
	kubernetes_version="${entry#* }"
	kubernetes_seen["$component"]=$(( ${kubernetes_seen["$component"]:-0} + 1 ))
	if [ "$kubernetes_version" != "$release_version" ]; then
		echo "ERROR: Kubernetes $component uses $kubernetes_version, release tag is $release_version" >&2
		exit 1
	fi
done
[ "${kubernetes_seen[ui]:-0}" -eq 3 ] \
	&& [ "${kubernetes_seen[sync-base]:-0}" -eq 1 ] \
	&& [ "${kubernetes_seen[sftp]:-0}" -eq 1 ] || {
	echo "ERROR: Kubernetes images do not cover volume setup, bootstrap, UI, sync-base, and SFTP" >&2
	exit 1
}

echo "Kubernetes defaults match release $release_version"
