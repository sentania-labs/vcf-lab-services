#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$project_dir"

usage() {
	cat <<'EOF'
Usage: ./install.sh

Optional compatibility bootstrap for VCF Services. It checks Docker, pulls the
published images, starts the Compose stack, and verifies the live HTTPS health
endpoint. Product setup happens in the browser at https://<host>/admin/.

The normal first-run path is simply: docker compose up -d
EOF
}

case "${1:-}" in
	-h|--help) usage; exit 0 ;;
	"") ;;
	*) echo "ERROR: install.sh no longer accepts setup answers or build options." >&2; usage >&2; exit 2 ;;
esac

command -v docker >/dev/null 2>&1 || {
	echo "ERROR: Docker is required before VCF Services can start." >&2
	exit 1
}
docker info >/dev/null 2>&1 || {
	echo "ERROR: cannot reach the Docker daemon." >&2
	exit 1
}
docker compose version >/dev/null 2>&1 || {
	echo "ERROR: Docker Compose v2 is required." >&2
	exit 1
}

docker compose pull
docker compose up -d

deadline=$((SECONDS + 120))
until curl --fail --silent --show-error --insecure https://127.0.0.1/healthz >/dev/null 2>&1; do
	if [ "$SECONDS" -ge "$deadline" ]; then
		echo "ERROR: the HTTPS health endpoint did not become ready within 120 seconds." >&2
		docker compose ps >&2 || true
		exit 1
	fi
	sleep 2
done

echo "VCF Services is running. Continue in the browser at https://$(hostname -f 2>/dev/null || hostname)/admin/."
echo "The browser will warn about the first-boot internal certificate until its CA is trusted."
