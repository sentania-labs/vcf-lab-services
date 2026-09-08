#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$project_dir"

usage() {
	cat <<'EOF'
Usage: ./uninstall.sh [--purge-data]

Stops and removes VCF Services containers, the Compose network, and the three
VCF Services product images. Shared Caddy and Redis images are retained. Docker
volumes are preserved by default.

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

compose_environment="$(docker compose config --environment)"
compose_env_value() {
	local key="$1"
	awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' \
		<<<"$compose_environment"
}

depot_volume="$(compose_env_value DEPOT_VOLUME_NAME)"
backup_volume="$(compose_env_value BACKUP_VOLUME_NAME)"
ui_image="$(compose_env_value VCF_SERVICES_UI_IMAGE)"
sync_image="$(compose_env_value VCF_SERVICES_SYNC_IMAGE)"
sftp_image="$(compose_env_value VCF_SERVICES_SFTP_IMAGE)"
: "${depot_volume:=vcf-services-depot-store}"
: "${backup_volume:=vcf-services-backup-store}"
: "${ui_image:=ghcr.io/sentania-labs/vcf-lab-services/ui:latest}"
: "${sync_image:=ghcr.io/sentania-labs/vcf-lab-services/sync-base:latest}"
: "${sftp_image:=ghcr.io/sentania-labs/vcf-lab-services/sftp:latest}"
owned_images=("$ui_image" "$sync_image" "$sftp_image")
retained_owned_images=()

remove_owned_images() {
	local image
	for image in "${owned_images[@]}"; do
		if docker image inspect "$image" >/dev/null 2>&1; then
			if ! docker image rm "$image"; then
				retained_owned_images+=("$image")
			fi
		fi
	done
}

report_image_result() {
	if [ "${#retained_owned_images[@]}" -eq 0 ]; then
		echo "VCF Services product images were removed."
	else
		echo "VCF Services product images still used by another container were retained: ${retained_owned_images[*]}"
	fi
	echo "Shared third-party image caches retained: caddy:2.10.0-alpine and redis:7.4-alpine."
}

if [ "$purge_data" = true ]; then
	printf 'Type PURGE to permanently remove every VCF Services volume: '
	read -r confirmation
	if [ "$confirmation" != PURGE ]; then
		echo "Data purge cancelled. Nothing was removed."
		exit 1
	fi
	docker compose down --remove-orphans --volumes
	remove_owned_images
	echo "VCF Services containers, network, and stack volumes were removed."
	report_image_result
	echo "Left behind by VCF Services: no containers, network, or volumes."
	exit 0
fi

docker compose down --remove-orphans
remove_owned_images
cat <<EOF
VCF Services containers and network were removed.
EOF
report_image_result
cat <<EOF
Left behind in Docker volumes:
- depot content: $depot_volume at /depot
- Software Depot ID: vcf-services-vcfdt-state at /root/.local/share/vmware/vdt
- backups: $backup_volume at /mnt/backup
- settings: vcf-services-config at /config
- secrets: vcf-services-secrets at /run/vcf-services-secrets
- licensed tool releases: vcf-services-vcfdt-tool at /opt/vcfdt
- sync history: vcf-services-sync-state at /state
- TLS identity: vcf-services-caddy-data and vcf-services-caddy-config
- SFTP host keys: vcf-services-sftp-host-keys at /etc/ssh/keys
Run ./uninstall.sh --purge-data only when all of this retained state may be permanently removed.
EOF
