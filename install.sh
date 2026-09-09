#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$project_dir"

usage() {
	cat <<'EOF'
Usage: ./install.sh [--upgrade]

Optional compatibility bootstrap for VCF Services. It checks Docker, pulls the
published images, starts the Compose stack, and verifies the live HTTPS health
endpoint. Product setup happens in the browser at https://<host>/admin/.

The normal first-run path is simply: docker compose up -d

--upgrade pulls the selected release images and recreates every service without
removing or replacing any Docker volume. No current setting requires an image
rebuild. The licensed tool is replaced separately from the console Setup tab.
EOF
}

upgrade=false
case "${1:-}" in
	-h|--help) usage; exit 0 ;;
	--upgrade) upgrade=true ;;
	"") ;;
	*) echo "ERROR: install.sh no longer accepts setup answers or build options." >&2; usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "ERROR: only one option is accepted." >&2; usage >&2; exit 2; }

command -v docker >/dev/null 2>&1 || {
	echo "ERROR: Docker Engine 26.0 or newer is required before VCF Services can start." >&2
	exit 1
}
docker info >/dev/null 2>&1 || {
	echo "ERROR: cannot reach the Docker daemon." >&2
	exit 1
}
docker compose version >/dev/null 2>&1 || {
	echo "ERROR: Docker Compose 2.26 or newer is required." >&2
	exit 1
}

docker compose pull
if [ "$upgrade" = true ]; then
	docker compose up -d --force-recreate --remove-orphans
else
	docker compose up -d
fi

deadline=$((SECONDS + 120))
until curl --fail --silent --show-error --insecure https://127.0.0.1/healthz >/dev/null 2>&1; do
	if [ "$SECONDS" -ge "$deadline" ]; then
		echo "ERROR: the HTTPS health endpoint did not become ready within 120 seconds." >&2
		docker compose ps >&2 || true
		exit 1
	fi
	sleep 2
done

if [ "$upgrade" = true ]; then
	if ! bootstrap_status="$(curl --fail --silent --show-error --insecure \
		https://127.0.0.1/admin/api/bootstrap)"; then
		echo "ERROR: the admin console did not report its persistent-state status after upgrade." >&2
		exit 1
	fi
	if ! grep -Eq '"versionProblem"[[:space:]]*:' <<<"$bootstrap_status"; then
		echo "ERROR: the admin console returned an invalid persistent-state status after upgrade." >&2
		exit 1
	fi
	if grep -Eq '"blocked"[[:space:]]*:[[:space:]]*true' <<<"$bootstrap_status"; then
		echo "ERROR: upgrade recreated the services, but persistent-state migration was refused or failed." >&2
		echo "Open the admin console for the recovery details. No persistent data was removed." >&2
		exit 1
	fi
fi

echo "VCF Services is running. Continue in the browser at https://$(hostname -f 2>/dev/null || hostname)/admin/."
echo "The browser will warn about the first-boot internal certificate until its CA is trusted."
if [ "$upgrade" = true ]; then
	echo "Upgrade complete: services were recreated from the selected images."
	echo "Preserved: depot, Software Depot ID, settings, secrets, backups, tool releases, sync history, TLS state, and SFTP host keys."
	echo "Rebuild required for settings changes: none. Replace the licensed tool separately from the console Setup tab."
fi
