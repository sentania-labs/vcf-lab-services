#!/bin/bash
set -euo pipefail

settings_file="${SETTINGS_FILE:-/etc/vcf-services/settings.env}"
if [ -f "$settings_file" ]; then
	set -a
	# shellcheck disable=SC1090
	. "$settings_file"
	set +a
fi

: "${CRON_SCHEDULE:=0 3 * * 0}"
: "${STATE_DIR:=/state}"
: "${AUTH_FILE:=/run/secrets/activation-code.txt}"

mkdir -p "$STATE_DIR"
armed=false
if [ -s "$AUTH_FILE" ]; then armed=true; fi
tmp_state="$(mktemp "$STATE_DIR/state.json.XXXXXX")"
if [ -s "$STATE_DIR/state.json" ]; then
	jq --argjson armed "$armed" '. + {running:false, armed:$armed, currentTarget:null}' \
		"$STATE_DIR/state.json" > "$tmp_state"
else
	jq -n --argjson armed "$armed" \
		'{running:false, armed:$armed, currentTarget:null, lastRun:{}}' > "$tmp_state"
fi
mv "$tmp_state" "$STATE_DIR/state.json"

if [ -f /opt/vcfdt/conf/application-prodv2.properties ]; then
	: "${DEPOT_ENDPOINT:=dl.broadcom.com}"
	: "${TOKEN_URL:=https://eapi.broadcom.com/vcf/generateToken}"
	properties=/opt/vcfdt/conf/application-prodv2.properties
	safe_token_url="$(printf '%s' "$TOKEN_URL" | sed 's/[\\&|]/\\&/g')"
	sed -i -E "s|^lcm\.depot\.adapter\.host=.*$|lcm.depot.adapter.host=${DEPOT_ENDPOINT}|" "$properties"
	if grep -q '^lcm.access_token.broadcom.authorization.server.url=' "$properties"; then
		sed -i -E "s|^lcm\.access_token\.broadcom\.authorization\.server\.url=.*$|lcm.access_token.broadcom.authorization.server.url=${safe_token_url}|" "$properties"
	else
		printf '%s\n' "lcm.access_token.broadcom.authorization.server.url=${TOKEN_URL}" >> "$properties"
	fi
fi

cat > /etc/cron.d/vcf-services-sync <<EOF
SHELL=/bin/bash
PATH=/opt/vcfdt/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$CRON_SCHEDULE root /usr/local/bin/sync.sh >/proc/1/fd/1 2>/proc/1/fd/2
EOF
chmod 0644 /etc/cron.d/vcf-services-sync

echo "[entrypoint] vcf-services sync ready, schedule: '$CRON_SCHEDULE'"
if [ "$armed" = false ]; then
	echo "[entrypoint] not armed: activation code missing"
	echo "[entrypoint] Register the Software Depot ID in the Broadcom download tool registration flow, then rerun install.sh."
fi
exec cron -f
