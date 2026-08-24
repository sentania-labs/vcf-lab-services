#!/bin/sh
set -eu

depot_root="${1:-/depot}"

fail() {
	printf 'ERROR: adopted depot validation failed: %s\n' "$*" >&2
	exit 1
}

[ -d "$depot_root" ] || fail "$depot_root is not a directory"
[ -d "$depot_root/PROD/COMP" ] || fail "$depot_root/PROD/COMP is missing; this does not look like a VCFDT depot"
if ! resolved_depot_root="$(readlink -f "$depot_root")"; then
	fail "$depot_root could not be resolved"
fi

if ! content_entry="$(find "$depot_root/PROD/COMP" -mindepth 1 \( -type f -o -type l \) -print -quit)"; then
	fail "$depot_root/PROD/COMP could not be read"
fi
[ -n "$content_entry" ] || fail "$depot_root/PROD/COMP contains no files or symlinks; this does not look like a populated VCFDT depot"

if ! symlink_report="$(find "$depot_root" -type l -exec sh -c '
	resolved_depot_root="$1"
	shift

	normalize_path() {
		np_out=""
		np_ifs="$IFS"
		IFS=/
		for np_seg in $1; do
			case "$np_seg" in
				""|.) ;;
				..) np_out="${np_out%/*}" ;;
				*) np_out="$np_out/$np_seg" ;;
			esac
		done
		IFS="$np_ifs"
		printf "%s" "${np_out:-/}"
	}

	contained() {
		case "$1" in
			"$resolved_depot_root"|"$resolved_depot_root"/*) return 0 ;;
			*) return 1 ;;
		esac
	}

	for link do
		target="$(readlink "$link")" || {
			printf "UNREADABLE\t%s\t\n" "$link"
			continue
		}
		if [ -e "$link" ] && resolved_target="$(readlink -f "$link" 2>/dev/null)" && [ -n "$resolved_target" ]; then
			contained "$resolved_target" || printf "ESCAPE\t%s\t%s\t%s\n" "$link" "$target" "$resolved_target"
			continue
		fi
		case "$target" in
			/*) candidate="$target" ;;
			*)
				link_dir="$(dirname "$link")"
				link_dir="$(readlink -f "$link_dir" 2>/dev/null || printf "%s" "$link_dir")"
				candidate="$link_dir/$target"
				;;
		esac
		candidate="$(normalize_path "$candidate")"
		if contained "$candidate"; then
			printf "DANGLING\t%s\t%s\t%s\n" "$link" "$target" "$candidate"
		else
			printf "ESCAPE\t%s\t%s\t%s\n" "$link" "$target" "$candidate"
		fi
	done
' sh "$resolved_depot_root" {} +)"; then
	fail "$depot_root could not be scanned for symlinks"
fi

escapes="$(printf '%s\n' "$symlink_report" | grep '^ESCAPE	' || true)"
unreadable="$(printf '%s\n' "$symlink_report" | grep '^UNREADABLE	' || true)"
dangling="$(printf '%s\n' "$symlink_report" | grep '^DANGLING	' || true)"

if [ -n "$dangling" ]; then
	dangling_count="$(printf '%s\n' "$dangling" | wc -l | tr -d ' ')"
	printf 'WARNING: %s symlink(s) in %s do not resolve but stay within /depot. Adoption continues; the depot content is incomplete:\n' \
		"$dangling_count" "$depot_root" >&2
	printf '%s\n' "$dangling" | while IFS='	' read -r _kind link target resolved; do
		printf '  %s points to %s, which does not resolve with the depot mounted at /depot but stays inside /depot as %s\n' "$link" "$target" "$resolved" >&2
	done
fi

if [ -n "$escapes" ] || [ -n "$unreadable" ]; then
	printf 'ERROR: adopted depot validation failed: symlinks in %s are not confined to /depot\n' "$depot_root" >&2
	if [ -n "$escapes" ]; then
		escape_count="$(printf '%s\n' "$escapes" | wc -l | tr -d ' ')"
		printf '  %s symlink(s) resolve outside /depot:\n' "$escape_count" >&2
		printf '%s\n' "$escapes" | while IFS='	' read -r _kind link target resolved; do
			printf '    %s points to %s, which resolves outside /depot as %s\n' "$link" "$target" "$resolved" >&2
		done
	fi
	if [ -n "$unreadable" ]; then
		unreadable_count="$(printf '%s\n' "$unreadable" | wc -l | tr -d ' ')"
		printf '  %s symlink(s) could not be read, so containment cannot be proven:\n' "$unreadable_count" >&2
		printf '%s\n' "$unreadable" | while IFS='	' read -r _kind link _target _resolved; do
			printf '    %s cannot be read\n' "$link" >&2
		done
	fi
	exit 1
fi

printf 'Adopted depot validation passed: %s\n' "$depot_root"
