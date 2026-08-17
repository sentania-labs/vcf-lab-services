#!/bin/bash
set -euo pipefail

image="${1:?usage: import-vcfdt-state.sh IMAGE SOURCE_KIND SOURCE TARGET_VOLUME}"
source_kind="${2:?usage: import-vcfdt-state.sh IMAGE SOURCE_KIND SOURCE TARGET_VOLUME}"
source_value="${3:?usage: import-vcfdt-state.sh IMAGE SOURCE_KIND SOURCE TARGET_VOLUME}"
target_volume="${4:?usage: import-vcfdt-state.sh IMAGE SOURCE_KIND SOURCE TARGET_VOLUME}"

state_mount_spec() {
	local state_kind="$1" state_source="$2"
	case "$state_kind" in
		directory) printf 'type=bind,src=%s,dst=/root/.local/share/vmware/vdt,readonly' "$state_source" ;;
		volume) printf 'type=volume,src=%s,dst=/root/.local/share/vmware/vdt,readonly' "$state_source" ;;
		*) echo "ERROR: unsupported VCFDT state source type: $state_kind" >&2; return 1 ;;
	esac
}

read_state_machine_id() {
	local state_kind="$1" state_source="$2" mount_spec output machine_id
	mount_spec="$(state_mount_spec "$state_kind" "$state_source")" || return 1
	output="$(docker run --rm \
		--entrypoint /opt/vcfdt/bin/vcf-download-tool \
		--mount "$mount_spec" \
		"$image" configuration get --machineId)" || return 1
	machine_id="$(printf '%s\n' "$output" | tr -d '\r' | sed -n '/[^[:space:]]/h; ${x;p;}')"
	[ -n "$machine_id" ] || return 1
	printf '%s\n' "$machine_id"
}

state_volume_empty() {
	docker run --rm --entrypoint /bin/sh \
		--mount "type=volume,src=$1,dst=/state,readonly" \
		"$image" -c '[ -z "$(find /state -mindepth 1 -print -quit)" ]'
}

[[ "$target_volume" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]+$ ]] || {
	echo "ERROR: invalid target Docker volume name: $target_volume" >&2
	exit 2
}
if [ "$source_kind" = volume ] && [ "$source_value" = "$target_volume" ]; then
	echo "ERROR: VCFDT state source and target volumes must differ" >&2
	exit 2
fi

echo "Validating the existing VCFDT state read-only" >&2
if ! source_machine_id="$(read_state_machine_id "$source_kind" "$source_value" 2>/dev/null)"; then
	echo "ERROR: the VCFDT state source does not contain readable machine-ID state." >&2
	echo "       Point at the directory or volume mounted at /root/.local/share/vmware/vdt" >&2
	echo "       in the existing deployment. The source was mounted read-only and was not changed." >&2
	exit 1
fi

if docker volume inspect "$target_volume" >/dev/null 2>&1; then
	if state_volume_empty "$target_volume"; then
		:
	elif target_machine_id="$(read_state_machine_id volume "$target_volume" 2>/dev/null)"; then
		if [ "$target_machine_id" = "$source_machine_id" ]; then
			echo "The target VCFDT state volume already contains the adopted Software Depot ID; no copy is needed." >&2
			printf '%s\n' "$target_machine_id"
			exit 0
		fi
		echo "ERROR: refusing to overwrite $target_volume because it contains a different Software Depot ID." >&2
		echo "       Existing target ID: $target_machine_id" >&2
		echo "       Adoption source ID: $source_machine_id" >&2
		echo "       Back up both states and resolve the conflict before retrying." >&2
		exit 1
	else
		echo "ERROR: refusing to overwrite non-empty $target_volume because its machine-ID state could not be read." >&2
		echo "       Back up and inspect the target volume before retrying." >&2
		exit 1
	fi
else
	docker volume create "$target_volume" >/dev/null
fi

source_mount="$(state_mount_spec "$source_kind" "$source_value")"
echo "Importing the verified VCFDT state into $target_volume" >&2
if ! docker run --rm --entrypoint /bin/sh \
	--mount "$source_mount" \
	--mount "type=volume,src=$target_volume,dst=/imported-state" \
	"$image" -c \
	'set -eu; [ -z "$(find /imported-state -mindepth 1 -print -quit)" ]; cp -a /root/.local/share/vmware/vdt/. /imported-state/'; then
	echo "ERROR: VCFDT state import failed. No service has been started against the target volume." >&2
	exit 1
fi

if ! target_machine_id="$(read_state_machine_id volume "$target_volume" 2>/dev/null)"; then
	echo "ERROR: imported VCFDT state failed machine-ID verification. No service has been started." >&2
	exit 1
fi
if [ "$target_machine_id" != "$source_machine_id" ]; then
	echo "ERROR: imported Software Depot ID does not match the source. No service has been started." >&2
	exit 1
fi
echo "Imported VCFDT state verified with Software Depot ID: $target_machine_id" >&2
printf '%s\n' "$target_machine_id"
