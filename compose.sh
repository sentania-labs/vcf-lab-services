#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$project_dir"

if ! docker info >/dev/null 2>&1; then
	echo "ERROR: cannot reach the Docker daemon." >&2
	exit 1
fi

exec docker compose "$@"
