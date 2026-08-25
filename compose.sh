#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$project_dir"

compose_args=("$@")
compose_command=""
argument_index=0
while [ "$argument_index" -lt "${#compose_args[@]}" ]; do
	argument="${compose_args[$argument_index]}"
	case "$argument" in
		--all-resources|--compatibility|--dry-run|--all-resources=*|--compatibility=*|--dry-run=*)
			argument_index=$((argument_index + 1))
			;;
		--ansi|--env-file|-f|--file|--parallel|--profile|--progress|--project-directory|-p|--project-name)
			argument_index=$((argument_index + 2))
			;;
		--ansi=*|--env-file=*|--file=*|--parallel=*|--profile=*|--progress=*|--project-directory=*|--project-name=*|-f?*|-p?*)
			argument_index=$((argument_index + 1))
			;;
		--)
			argument_index=$((argument_index + 1))
			compose_command="${compose_args[$argument_index]:-}"
			break
			;;
		-*)
			break
			;;
		*)
			compose_command="$argument"
			break
			;;
	esac
done

if [ "$compose_command" = up ]; then
	if ! docker info >/dev/null 2>&1; then
		echo "ERROR: cannot reach the Docker daemon." >&2
		echo "Start Docker and make sure this account can use it, then retry." >&2
		exit 1
	fi
	missing=()
	if ! docker volume inspect vcf-services-vcfdt-state >/dev/null 2>&1; then
		missing+=("external volume vcf-services-vcfdt-state")
	fi
	if [ "${#missing[@]}" -gt 0 ]; then
		echo "ERROR: VCF Services installation is incomplete:" >&2
		printf '  - missing %s\n' "${missing[@]}" >&2
		echo "Run ./install.sh instead. It creates the persistent state volume and" >&2
		echo "the credentials required before the stack can start." >&2
		exit 1
	fi
fi

exec docker compose "${compose_args[@]}"
