#!/bin/bash
set -euo pipefail

if [ "${1:-}" = up ]; then
	missing=()
	if ! docker volume inspect vcf-services-vcfdt-state >/dev/null 2>&1; then
		missing+=("external volume vcf-services-vcfdt-state")
	fi
	if ! docker image inspect vcf-services-sync:local >/dev/null 2>&1; then
		missing+=("local image vcf-services-sync:local")
	fi
	if [ "${#missing[@]}" -gt 0 ]; then
		echo "ERROR: VCF Services installation is incomplete:" >&2
		printf '  - missing %s\n' "${missing[@]}" >&2
		echo "Run ./install.sh instead. It creates the persistent state volume and" >&2
		echo "layers your operator-supplied VCF Download Tool into the local sync image." >&2
		exit 1
	fi
fi

exec docker compose "$@"
