#!/bin/sh
set -eu

depot_root="${1:-/depot}"

fail() {
	printf 'ERROR: adopted depot validation failed: %s\n' "$*" >&2
	exit 1
}

[ -d "$depot_root" ] || fail "$depot_root is not a directory"
[ -d "$depot_root/PROD/COMP" ] || fail "$depot_root/PROD/COMP is missing; this does not look like a VCFDT depot"

if ! content_entry="$(find "$depot_root/PROD/COMP" -mindepth 1 \( -type f -o -type l \) -print -quit)"; then
	fail "$depot_root/PROD/COMP could not be read"
fi
[ -n "$content_entry" ] || fail "$depot_root/PROD/COMP contains no files or symlinks; this does not look like a populated VCFDT depot"

if ! symlink_errors="$(find "$depot_root" -type l -exec sh -c '
	for link do
		target="$(readlink "$link")" || {
			printf "%s cannot be read\n" "$link"
			continue
		}
		case "$target" in
			/*)
				case "$target" in
					/depot|/depot/*) ;;
					*)
						printf "%s points to %s; VCFDT absolute symlinks must stay under /depot\n" "$link" "$target"
						continue
						;;
				esac
				;;
		esac
		[ -e "$link" ] || printf "%s points to %s, which does not resolve with the depot mounted at /depot\n" "$link" "$target"
	done
' sh {} +)"; then
	fail "$depot_root could not be scanned for symlinks"
fi

if [ -n "$symlink_errors" ]; then
	first_error="$(printf '%s\n' "$symlink_errors" | sed -n '1p')"
	fail "$first_error"
fi

printf 'Adopted depot validation passed: %s\n' "$depot_root"
