#!/bin/bash
set -euo pipefail

release_version="${1:?usage: verify-compose-version.sh RELEASE_VERSION [COMPOSE_FILE]}"
compose_file="${2:-docker-compose.yml}"

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
