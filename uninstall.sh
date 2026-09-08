#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$project_dir"

usage() {
	cat <<'EOF'
Usage: ./uninstall.sh [--purge-data]

Stops and removes VCF Services containers, the Compose network, and images used
by the stack. Docker volumes are preserved by default.

--purge-data also removes every stack volume after an explicit PURGE prompt.
This permanently removes depot content, Software Depot ID state, settings,
secrets, backups, installed tool releases, sync history, TLS state, and SFTP
host keys.
EOF
}

purge_data=false
case "${1:-}" in
	-h|--help) usage; exit 0 ;;
	--purge-data) purge_data=true ;;
	"") ;;
	*) echo "ERROR: unsupported option: $1" >&2; usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "ERROR: only one option is accepted." >&2; usage >&2; exit 2; }

command -v docker >/dev/null 2>&1 || {
	echo "ERROR: Docker Engine is required to remove VCF Services." >&2
	exit 1
}
docker info >/dev/null 2>&1 || {
	echo "ERROR: cannot reach the Docker daemon." >&2
	exit 1
}
docker compose version >/dev/null 2>&1 || {
	echo "ERROR: Docker Compose is required." >&2
	exit 1
}

if [ "$purge_data" = true ]; then
	printf 'Type PURGE to permanently remove every VCF Services volume: '
	read -r confirmation
	if [ "$confirmation" != PURGE ]; then
		echo "Data purge cancelled. Nothing was removed."
		exit 1
	fi
	docker compose down --remove-orphans --rmi all --volumes
	echo "VCF Services containers, network, images, and stack volumes were removed."
	echo "Left behind by this stack: nothing."
	exit 0
fi

docker compose down --remove-orphans --rmi all
cat <<EOF
VCF Services containers, network, and stack images were removed.
Left behind in Docker volumes:
- depot content: ${DEPOT_VOLUME_NAME:-vcf-services-depot-store} at /depot
- Software Depot ID: vcf-services-vcfdt-state at /root/.local/share/vmware/vdt
- backups: ${BACKUP_VOLUME_NAME:-vcf-services-backup-store} at /mnt/backup
- settings: vcf-services-config at /config
- secrets: vcf-services-secrets at /run/vcf-services-secrets
- licensed tool releases: vcf-services-vcfdt-tool at /opt/vcfdt
- sync history: vcf-services-sync-state at /state
- TLS identity: vcf-services-caddy-data and vcf-services-caddy-config
- SFTP host keys: vcf-services-sftp-host-keys at /etc/ssh/keys
Run ./uninstall.sh --purge-data only when all of this retained state may be permanently removed.
EOF
