#!/bin/bash
set -euo pipefail

image="${1:?usage: import-vcfdt-state.sh IMAGE SOURCE_KIND SOURCE TARGET_VOLUME}"
source_kind="${2:?usage: import-vcfdt-state.sh IMAGE SOURCE_KIND SOURCE TARGET_VOLUME}"
source_value="${3:?usage: import-vcfdt-state.sh IMAGE SOURCE_KIND SOURCE TARGET_VOLUME}"
target_volume="${4:?usage: import-vcfdt-state.sh IMAGE SOURCE_KIND SOURCE TARGET_VOLUME}"
tool_volume="${5:-}"
tool_entrypoint=/opt/vcfdt/bin/vcf-download-tool
tool_mount=()
if [ -n "$tool_volume" ]; then
	tool_entrypoint=/opt/vcfdt/current/bin/vcf-download-tool
	tool_mount=(--mount "type=volume,src=$tool_volume,dst=/opt/vcfdt,readonly")
fi

state_dir=/root/.local/share/vmware/vdt
staging_dir_name=.vcf-services-import-staging
scratch_prefix=vcf-services-vcfdt-state-probe-
scratch_volume=""
scratch_serial=0
probed_machine_id=""
target_is_owned_by_this_run=false

cleanup() {
	if [ -n "$scratch_volume" ]; then
		docker volume rm -f "$scratch_volume" >/dev/null 2>&1 || true
		scratch_volume=""
	fi
}
trap cleanup EXIT
trap 'cleanup; trap - INT; kill -INT $$' INT
trap 'cleanup; exit 143' TERM

sweep_abandoned_scratch_volumes() {
	local name owner
	while read -r name; do
		[ -n "$name" ] || continue
		owner="${name#"$scratch_prefix"}"
		owner="${owner%%-*}"
		[[ "$owner" =~ ^[0-9]+$ ]] || continue
		[ "$owner" != "$$" ] || continue
		if kill -0 "$owner" 2>/dev/null; then continue; fi
		docker volume rm -f "$name" >/dev/null 2>&1 || true
	done < <(docker volume ls --quiet --filter "name=^${scratch_prefix}" 2>/dev/null || true)
}

state_mount_spec() {
	local state_kind="$1" state_source="$2" access="${3:-readonly}" suffix=""
	[ "$access" = readonly ] && suffix=',readonly'
	case "$state_kind" in
		directory)
			case "$state_source" in
				*,*|*=*)
					echo "ERROR: the VCFDT state directory path may not contain ',' or '=': $state_source" >&2
					return 1
					;;
			esac
			printf 'type=bind,src=%s,dst=%s%s' "$state_source" "$state_dir" "$suffix"
			;;
		volume) printf 'type=volume,src=%s,dst=%s%s' "$state_source" "$state_dir" "$suffix" ;;
		*) echo "ERROR: unsupported VCFDT state source type: $state_kind" >&2; return 1 ;;
	esac
}

read_volume_machine_id() {
	local state_volume="$1" access output machine_id
	for access in readonly writable; do
		output="$(docker run --rm \
			--entrypoint "$tool_entrypoint" \
			"${tool_mount[@]}" \
			--mount "$(state_mount_spec volume "$state_volume" "$access")" \
			"$image" configuration get --machineId)" || continue
		machine_id="$(printf '%s\n' "$output" | tr -d '\r' | sed -n '/[^[:space:]]/h; ${x;p;}')"
		[ -n "$machine_id" ] || continue
		printf '%s\n' "$machine_id"
		return 0
	done
	return 1
}

reset_scratch_volume() {
	cleanup
	scratch_serial=$((scratch_serial + 1))
	local name="$scratch_prefix$$-$scratch_serial"
	docker volume rm -f "$name" >/dev/null 2>&1 || true
	docker volume create "$name" >/dev/null
	scratch_volume="$name"
}

copy_state_to_scratch() {
	local source_mount
	source_mount="$(state_mount_spec "$1" "$2" readonly)" || return 1
	docker run --rm --entrypoint /bin/sh \
		--mount "$source_mount" \
		--mount "type=volume,src=$scratch_volume,dst=/scratch" \
		"$image" -c '
			set -eu
			if [ -n "$(find /scratch -mindepth 1 -print -quit)" ]; then
				echo "ERROR: the VCFDT state inspection scratch volume was not empty" >&2
				exit 1
			fi
			cp -a "$1/." /scratch/
		' sh "$state_dir"
}

probe_machine_id() {
	local state_kind="$1" state_source="$2" copy_log machine_id
	probed_machine_id=""
	reset_scratch_volume
	if ! copy_log="$(copy_state_to_scratch "$state_kind" "$state_source" 2>&1)"; then
		[ -z "$copy_log" ] || printf '%s\n' "$copy_log" >&2
		cleanup
		return 2
	fi
	if ! machine_id="$(read_volume_machine_id "$scratch_volume" 2>/dev/null)"; then
		cleanup
		return 1
	fi
	cleanup
	probed_machine_id="$machine_id"
}

copy_state_into_volume() {
	local state_kind="$1" state_source="$2" destination_volume="$3" source_mount
	source_mount="$(state_mount_spec "$state_kind" "$state_source" readonly)" || return 1
	docker run --rm --entrypoint /bin/sh \
		--mount "$source_mount" \
		--mount "type=volume,src=$destination_volume,dst=/imported-state" \
		"$image" -c '
			set -eu
			rm -rf "/imported-state/$1"
			[ -z "$(find /imported-state -mindepth 1 -print -quit)" ]
			mkdir "/imported-state/$1"
			cp -a "$2/." "/imported-state/$1/"
			cd "/imported-state/$1"
			for entry in * .[!.]* ..?*; do
				[ -e "$entry" ] || [ -L "$entry" ] || continue
				mv -- "$entry" /imported-state/
			done
			cd /
			rmdir "/imported-state/$1"
		' sh "$staging_dir_name" "$state_dir"
}

volume_state_status() {
	docker run --rm --entrypoint /bin/sh \
		--mount "type=volume,src=$1,dst=/state,readonly" \
		"$image" -c '
			set -eu
			if [ -e "/state/$1" ]; then
				if [ -z "$(find /state -mindepth 1 -maxdepth 1 ! -name "$1" -print -quit)" ]; then
					echo staging-only
				else
					echo staging-mixed
				fi
			elif [ -z "$(find /state -mindepth 1 -print -quit)" ]; then
				echo empty
			else
				echo populated
			fi
		' sh "$staging_dir_name"
}

empty_volume() {
	docker run --rm --entrypoint /bin/sh \
		--mount "type=volume,src=$1,dst=/state" \
		"$image" -c 'set -eu; find /state -mindepth 1 -delete'
}

refuse_conflicting_target() {
	echo "ERROR: refusing to overwrite $target_volume because it contains a different Software Depot ID." >&2
	echo "       Existing target ID: $1" >&2
	echo "       Adoption source ID: $source_machine_id" >&2
	echo "       Back up both states and resolve the conflict before retrying." >&2
	exit 1
}

[[ "$target_volume" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]+$ ]] || {
	echo "ERROR: invalid target Docker volume name: $target_volume" >&2
	exit 2
}
if [ "$source_kind" = volume ] && [ "$source_value" = "$target_volume" ]; then
	echo "ERROR: VCFDT state source and target volumes must differ" >&2
	exit 2
fi

sweep_abandoned_scratch_volumes

echo "Validating the existing VCFDT state read-only" >&2
source_probe_status=0
probe_machine_id "$source_kind" "$source_value" || source_probe_status=$?
source_machine_id="$probed_machine_id"
if [ "$source_probe_status" -eq 2 ]; then
	echo "ERROR: the VCFDT state source could not be copied for inspection; see the error above." >&2
	echo "       The source was mounted read-only and was not changed." >&2
	exit 1
fi
if [ "$source_probe_status" -ne 0 ]; then
	echo "ERROR: the VCFDT state source does not contain readable machine-ID state." >&2
	echo "       Point at the directory or volume mounted at $state_dir" >&2
	echo "       in the existing deployment. The source was mounted read-only and was not changed." >&2
	exit 1
fi

if docker volume inspect "$target_volume" >/dev/null 2>&1; then
	if ! target_status="$(volume_state_status "$target_volume")"; then
		echo "ERROR: refusing to touch $target_volume because its contents could not be inspected." >&2
		echo "       Confirm the Docker daemon is healthy and the volume is readable, then retry." >&2
		exit 1
	fi
	case "$target_status" in
		empty|staging-only|staging-mixed|populated) ;;
		*)
			echo "ERROR: refusing to touch $target_volume because its state could not be classified." >&2
			exit 1
			;;
	esac
	if [ "$target_status" = empty ]; then
		target_is_owned_by_this_run=true
	elif [ "$target_status" = staging-only ]; then
		echo "Clearing an incomplete earlier VCFDT state import from $target_volume" >&2
		empty_volume "$target_volume"
		target_is_owned_by_this_run=true
	else
		target_probe_status=0
		probe_machine_id volume "$target_volume" || target_probe_status=$?
		target_machine_id="$probed_machine_id"
		if [ "$target_probe_status" -eq 2 ]; then
			echo "ERROR: refusing to touch non-empty $target_volume because it could not be copied for inspection." >&2
			echo "       Back up and inspect the target volume before retrying." >&2
			exit 1
		fi
		if [ "$target_probe_status" -ne 0 ]; then
			echo "ERROR: refusing to overwrite non-empty $target_volume because its machine-ID state could not be read." >&2
			echo "       Back up and inspect the target volume before retrying." >&2
			exit 1
		fi
		if [ "$target_machine_id" != "$source_machine_id" ]; then
			refuse_conflicting_target "$target_machine_id"
		fi
		if [ "$target_status" = staging-mixed ]; then
			echo "Clearing an interrupted earlier VCFDT state import from $target_volume" >&2
			echo "       The target already carries the adopted Software Depot ID, so the state is reimported from the source." >&2
			empty_volume "$target_volume"
			target_is_owned_by_this_run=true
		else
			echo "The target VCFDT state volume already contains the adopted Software Depot ID; no copy is needed." >&2
			printf '%s\n' "$target_machine_id"
			exit 0
		fi
	fi
else
	docker volume create "$target_volume" >/dev/null
	target_is_owned_by_this_run=true
fi

if [ "$target_is_owned_by_this_run" != true ]; then
	echo "ERROR: refusing to import into $target_volume because this run does not own its contents." >&2
	exit 1
fi

echo "Importing the verified VCFDT state into $target_volume" >&2
if ! copy_state_into_volume "$source_kind" "$source_value" "$target_volume"; then
	empty_volume "$target_volume" >/dev/null 2>&1 || true
	echo "ERROR: VCFDT state import failed. No service has been started against the target volume." >&2
	exit 1
fi

if ! target_machine_id="$(read_volume_machine_id "$target_volume" 2>/dev/null)"; then
	empty_volume "$target_volume" >/dev/null 2>&1 || true
	echo "ERROR: imported VCFDT state failed machine-ID verification. No service has been started." >&2
	exit 1
fi
if [ "$target_machine_id" != "$source_machine_id" ]; then
	empty_volume "$target_volume" >/dev/null 2>&1 || true
	echo "ERROR: imported Software Depot ID does not match the source. No service has been started." >&2
	exit 1
fi
echo "Imported VCFDT state verified with Software Depot ID: $target_machine_id" >&2
printf '%s\n' "$target_machine_id"
