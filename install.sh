#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
answers_file=""
minimum_free_gb=500
validate_only=""

usage() {
	cat <<'EOF'
Usage: ./install.sh [--answers-file PATH] [--min-free-gb NUMBER]
       ./install.sh --validate-archive PATH

The free-space floor defaults to 500 GB. Use --min-free-gb only when a smaller
lab or test store is intentional.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--answers-file)
			[ "$#" -ge 2 ] || { echo "ERROR: --answers-file requires a path" >&2; exit 2; }
			answers_file="$2"
			shift 2
			;;
		--min-free-gb)
			[ "$#" -ge 2 ] || { echo "ERROR: --min-free-gb requires a number" >&2; exit 2; }
			minimum_free_gb="$2"
			shift 2
			;;
		--validate-archive)
			[ "$#" -ge 2 ] || { echo "ERROR: --validate-archive requires a path" >&2; exit 2; }
			validate_only="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "ERROR: unknown option: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

[[ "$minimum_free_gb" =~ ^[0-9]+$ ]] || { echo "ERROR: free-space floor must be a whole number" >&2; exit 2; }

declare -A answers=()
allowed_answer() {
	case "$1" in
		VCFDT_ARCHIVE|PRODUCT_FQDN|TZ|STORAGE_MODE|DEPOT_LOCAL_PATH|NFS_SERVER|NFS_EXPORT|NFS_OPTIONS|TLS_MODE|TLS_CERT_PATH|TLS_KEY_PATH|AUTH_USERNAME|AUTH_PASSWORD|HTTPS_PORT|VCF_VERSION|SKU|SYNC_TARGETS|CRON_SCHEDULE|CEIP|ESX_MODE|LOG_RETENTION|VKR_MATCH|VKR_OS|DEPOT_ENDPOINT|TOKEN_URL|ACTIVATION_CODE) return 0 ;;
		*) return 1 ;;
	esac
}

if [ -n "$answers_file" ]; then
	[ -f "$answers_file" ] || { echo "ERROR: answers file not found: $answers_file" >&2; exit 2; }
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		[[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
		[[ "$line" == *=* ]] || { echo "ERROR: invalid answers-file line" >&2; exit 2; }
		key="${line%%=*}"
		value="${line#*=}"
		key="${key//[[:space:]]/}"
		allowed_answer "$key" || { echo "ERROR: unsupported answers-file key: $key" >&2; exit 2; }
		if [[ "$value" == \"*\" && "$value" == *\" ]]; then value="${value:1:${#value}-2}"; fi
		if [[ "$value" == \'*\' && "$value" == *\' ]]; then value="${value:1:${#value}-2}"; fi
		answers["$key"]="$value"
	done < "$answers_file"
fi

ask() {
	local key="$1" label="$2" default_value="$3" secret="${4:-false}"
	if [[ -v "answers[$key]" ]]; then
		REPLY_VALUE="${answers[$key]}"
		return
	fi
	[ -t 0 ] || { echo "ERROR: $key is missing from the answers file" >&2; exit 2; }
	if [ "$secret" = true ]; then
		read -r -s -p "$label [no default]: " REPLY_VALUE
		echo
	else
		read -r -p "$label [$default_value]: " REPLY_VALUE
	fi
	REPLY_VALUE="${REPLY_VALUE:-$default_value}"
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
}

archive_listing() {
	local archive="$1"
	case "$archive" in
		*.tar.gz|*.tgz) tar -tzf "$archive" ;;
		*.zip) unzip -Z1 "$archive" ;;
		*) echo "ERROR: VCFDT archive must be .tar.gz, .tgz, or .zip" >&2; return 1 ;;
	esac
}

validate_archive() {
	local archive="$1" listing
	[ -f "$archive" ] || { echo "ERROR: VCFDT archive not found: $archive" >&2; return 1; }
	listing="$(archive_listing "$archive")" || return 1
	if printf '%s\n' "$listing" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
		echo "ERROR: VCFDT archive contains an unsafe path" >&2
		return 1
	fi
	printf '%s\n' "$listing" | grep -Eq '(^|/)bin/vcf-download-tool$' || {
		echo "ERROR: archive does not contain bin/vcf-download-tool" >&2
		return 1
	}
}

if [ -n "$validate_only" ]; then
	validate_archive "$validate_only"
	echo "VCFDT archive validation passed"
	exit 0
fi

echo "VCF Services installer"
echo "The health endpoint and UMDS patch-store subtree are intentionally unauthenticated."
echo "Expected storage: 0.5 to 1 TB for one VCF train, plus about 461 GB for the full VKr library."

ask VCFDT_ARCHIVE "Path to the VCF Download Tool archive" "./vcf-download-tool.tar.gz"
vcfdt_archive="$REPLY_VALUE"
validate_archive "$vcfdt_archive"

ask PRODUCT_FQDN "Depot FQDN" "vcf-services.example.com"
product_fqdn="$REPLY_VALUE"
[[ "$product_fqdn" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { echo "ERROR: invalid FQDN" >&2; exit 2; }

ask TZ "Container timezone" "UTC"
timezone="$REPLY_VALUE"
[[ "$timezone" =~ ^[A-Za-z0-9_+/-]+$ ]] || { echo "ERROR: invalid timezone" >&2; exit 2; }

ask DEPOT_ENDPOINT "VCFDT download endpoint" "dl.broadcom.com"
depot_endpoint="$REPLY_VALUE"
[[ "$depot_endpoint" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "ERROR: invalid download endpoint" >&2; exit 2; }

ask TOKEN_URL "VCFDT token URL" "https://eapi.broadcom.com/vcf/generateToken"
token_url="$REPLY_VALUE"
token_url_pattern='^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~:/?%&=+,@-]*)?$'
[[ "$token_url" =~ $token_url_pattern ]] || { echo "ERROR: token URL must be a valid HTTPS URL" >&2; exit 2; }

ask STORAGE_MODE "Depot storage mode (local or nfs)" "local"
storage_mode="${REPLY_VALUE,,}"
[[ "$storage_mode" == local || "$storage_mode" == nfs ]] || { echo "ERROR: storage mode must be local or nfs" >&2; exit 2; }

depot_local_path=""
nfs_server=""
nfs_export=""
nfs_options="nfsvers=4,rw,hard,timeo=600,retrans=2"
if [ "$storage_mode" = local ]; then
	ask DEPOT_LOCAL_PATH "Local depot directory" "$project_dir/data/depot"
	depot_local_path="$REPLY_VALUE"
	[[ "$depot_local_path" = /* ]] || depot_local_path="$project_dir/${depot_local_path#./}"
	depot_local_path="$(realpath -m "$depot_local_path")"
else
	ask NFS_SERVER "NFS server" "nfs.example.com"
	nfs_server="$REPLY_VALUE"
	[[ "$nfs_server" =~ ^[A-Za-z0-9.:-]+$ ]] || { echo "ERROR: invalid NFS server" >&2; exit 2; }
	ask NFS_EXPORT "NFS export path" "/exports/vcf-services-depot"
	nfs_export="$REPLY_VALUE"
	[[ "$nfs_export" =~ ^/[A-Za-z0-9_./-]+$ ]] || { echo "ERROR: NFS export must be a plain absolute path" >&2; exit 2; }
	ask NFS_OPTIONS "NFS mount options" "$nfs_options"
	nfs_options="$REPLY_VALUE"
	[[ "$nfs_options" =~ ^[A-Za-z0-9_=,.-]+$ ]] || { echo "ERROR: NFS options contain unsupported characters" >&2; exit 2; }
fi

ask TLS_MODE "TLS mode (self-signed or provided)" "self-signed"
tls_mode="${REPLY_VALUE,,}"
[[ "$tls_mode" == self-signed || "$tls_mode" == provided ]] || { echo "ERROR: TLS mode must be self-signed or provided" >&2; exit 2; }
tls_cert_path=""
tls_key_path=""
if [ "$tls_mode" = provided ]; then
	ask TLS_CERT_PATH "TLS certificate path" "/path/to/server.crt"
	tls_cert_path="$REPLY_VALUE"
	ask TLS_KEY_PATH "TLS private key path" "/path/to/server.key"
	tls_key_path="$REPLY_VALUE"
	[ -f "$tls_cert_path" ] && [ -f "$tls_key_path" ] || { echo "ERROR: TLS certificate or key not found" >&2; exit 2; }
fi

ask AUTH_USERNAME "Shared username" "vcf"
auth_username="$REPLY_VALUE"
[[ "$auth_username" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "ERROR: username contains unsupported characters" >&2; exit 2; }
ask AUTH_PASSWORD "Shared password" "" true
auth_password="$REPLY_VALUE"
[ -n "$auth_password" ] || { echo "ERROR: a password is required and no default is provided" >&2; exit 2; }
if [ -z "$answers_file" ]; then
	read -r -s -p "Confirm shared password [no default]: " password_confirm
	echo
	[ "$auth_password" = "$password_confirm" ] || { echo "ERROR: passwords do not match" >&2; exit 2; }
fi

ask HTTPS_PORT "Published HTTPS port" "443"
https_port="$REPLY_VALUE"
[[ "$https_port" =~ ^[0-9]+$ ]] && [ "$https_port" -ge 1 ] && [ "$https_port" -le 65535 ] || { echo "ERROR: invalid HTTPS port" >&2; exit 2; }

ask VCF_VERSION "VCF version filter" "9.1.0"
vcf_version="$REPLY_VALUE"
[[ "$vcf_version" =~ ^[0-9][0-9A-Za-z.,*_-]*\.?\.?$ ]] || { echo "ERROR: invalid VCF version filter" >&2; exit 2; }
ask SKU "SKU (VCF or VVF)" "VCF"
sku="${REPLY_VALUE^^}"
[[ "$sku" == VCF || "$sku" == VVF ]] || { echo "ERROR: SKU must be VCF or VVF" >&2; exit 2; }
ask SYNC_TARGETS "Sync targets (esx install upgrade patches vkr)" "esx install upgrade patches"
sync_targets="$REPLY_VALUE"
for target in $sync_targets; do
	case "$target" in esx|install|upgrade|patches|vkr) ;; *) echo "ERROR: invalid sync target: $target" >&2; exit 2 ;; esac
done
[ -n "$sync_targets" ] || { echo "ERROR: at least one sync target is required" >&2; exit 2; }
if [[ " $sync_targets " == *" vkr "* ]]; then
	echo "NOTICE: VKr is a pluggable target. The guided mirror extension is planned for a later slice."
fi
ask CRON_SCHEDULE "Cron schedule" "0 3 * * 0"
cron_schedule="$REPLY_VALUE"
cron_pattern='^[0-9*/,-]+([[:space:]][0-9*/,-]+){4}$'
[[ "$cron_schedule" =~ $cron_pattern ]] || { echo "ERROR: cron schedule must be five numeric cron fields" >&2; exit 2; }
[ "$(awk '{print NF}' <<< "$cron_schedule")" -eq 5 ] || { echo "ERROR: cron schedule must contain five fields" >&2; exit 2; }
ask CEIP "CEIP (ENABLE or DISABLE)" "DISABLE"
ceip="${REPLY_VALUE^^}"
[[ "$ceip" == ENABLE || "$ceip" == DISABLE ]] || { echo "ERROR: CEIP must be explicitly ENABLE or DISABLE" >&2; exit 2; }
ask ESX_MODE "ESX mode (download or metadata)" "download"
esx_mode="${REPLY_VALUE,,}"
[[ "$esx_mode" == download || "$esx_mode" == metadata ]] || { echo "ERROR: ESX mode must be download or metadata" >&2; exit 2; }
ask LOG_RETENTION "Run logs to retain" "20"
log_retention="$REPLY_VALUE"
[[ "$log_retention" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: log retention must be at least 1" >&2; exit 2; }
ask VKR_MATCH "Pinned VKr versions (blank for none)" ""
vkr_match="$REPLY_VALUE"
ask VKR_OS "VKr OS variant (blank for none)" ""
vkr_os="$REPLY_VALUE"
vkr_value_pattern='^[A-Za-z0-9._ -]*$'
[[ "$vkr_match" =~ $vkr_value_pattern && "$vkr_os" =~ $vkr_value_pattern ]] || {
	echo "ERROR: VKr selections contain unsupported characters" >&2
	exit 2
}

echo "Running host preflight checks"
[ "$(uname -m)" = x86_64 ] || { echo "ERROR: only x86_64 hosts are supported" >&2; exit 1; }
if [ "$EUID" -ne 0 ] && ! id -nG | tr ' ' '\n' | grep -qx docker; then
	echo "ERROR: run as root or as a member of the docker group" >&2
	exit 1
fi
for command_name in docker curl openssl jq realpath sha256sum; do require_command "$command_name"; done
case "$vcfdt_archive" in *.zip) require_command unzip ;; *) require_command tar ;; esac
docker info >/dev/null 2>&1 || { echo "ERROR: current user cannot access the Docker daemon" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: Docker Compose v2 is required" >&2; exit 1; }
if [ "$storage_mode" = nfs ]; then
	command -v mount.nfs >/dev/null 2>&1 || { echo "ERROR: install nfs-common before using NFS storage" >&2; exit 1; }
fi
outbound_status="$(curl -sSIL --connect-timeout 10 --max-time 20 -o /dev/null -w '%{http_code}' "https://$depot_endpoint" || true)"
if [ "$outbound_status" = 000 ]; then
	echo "ERROR: outbound HTTPS check failed for $depot_endpoint" >&2
	exit 1
fi

mkdir -p "$project_dir/config" "$project_dir/secrets/tls" "$project_dir/data" "$project_dir/build/vcfdt"
chmod 0700 "$project_dir/secrets"

if [ "$storage_mode" = local ]; then
	mkdir -p "$depot_local_path"
	available_kb="$(df -Pk "$depot_local_path" | awk 'NR==2 {print $4}')"
	minimum_kb=$((minimum_free_gb * 1024 * 1024))
	[ "$available_kb" -ge "$minimum_kb" ] || {
		echo "ERROR: depot has less than ${minimum_free_gb} GB free. Override only after reviewing capacity." >&2
		exit 1
	}
else
	preflight_volume="vcf-services-nfs-preflight-$$"
	docker volume create --driver local --opt type=nfs \
		--opt "o=addr=$nfs_server,$nfs_options" --opt "device=:$nfs_export" \
		"$preflight_volume" >/dev/null
	if ! available_kb="$(docker run --rm -v "$preflight_volume:/depot:ro" alpine:3.20 \
		sh -c "df -Pk /depot | awk 'NR==2 {print \$4}'")"; then
		docker volume rm "$preflight_volume" >/dev/null 2>&1 || true
		echo "ERROR: NFS export could not be mounted" >&2
		exit 1
	fi
	docker volume rm "$preflight_volume" >/dev/null
	minimum_kb=$((minimum_free_gb * 1024 * 1024))
	[ "$available_kb" -ge "$minimum_kb" ] || {
		echo "ERROR: NFS depot has less than ${minimum_free_gb} GB free. Override only after reviewing capacity." >&2
		exit 1
	}
fi

echo "Staging the licensed VCF Download Tool locally"
stage_dir="$(mktemp -d /tmp/vcf-services-vcfdt.XXXXXX)"
trap 'rm -rf "$stage_dir"' EXIT
case "$vcfdt_archive" in
	*.tar.gz|*.tgz) tar -xzf "$vcfdt_archive" -C "$stage_dir" ;;
	*.zip) unzip -q "$vcfdt_archive" -d "$stage_dir" ;;
esac
tool_path="$(find "$stage_dir" -type f -path '*/bin/vcf-download-tool' -print -quit)"
[ -n "$tool_path" ] || { echo "ERROR: staged archive lost bin/vcf-download-tool" >&2; exit 1; }
tool_root="$(dirname "$(dirname "$tool_path")")"
find "$project_dir/build/vcfdt" -mindepth 1 -delete
cp -a "$tool_root/." "$project_dir/build/vcfdt/"
chmod 0755 "$project_dir/build/vcfdt/bin/vcf-download-tool"

archive_name="$(basename "$vcfdt_archive")"
vcfdt_version="$(sed -nE 's/^vcf-download-tool-([0-9][0-9A-Za-z._-]*)\.(tar\.gz|tgz|zip)$/\1/p' <<< "$archive_name")"
vcfdt_version="${vcfdt_version:-unknown}"
depot_volume_fingerprint="$(printf '%s\n' "$storage_mode|$depot_local_path|$nfs_server|$nfs_export|$nfs_options" \
	| sha256sum | cut -c1-12)"
depot_volume_name="vcf-services-depot-store-$depot_volume_fingerprint"

write_setting() {
	local key="$1" value="$2" escaped
	escaped="${value//\\/\\\\}"
	escaped="${escaped//\"/\\\"}"
	escaped="${escaped//\$/\\\$}"
	escaped="${escaped//\`/\\\`}"
	printf '%s="%s"\n' "$key" "$escaped" >> "$settings_tmp"
}

settings_tmp="$(mktemp "$project_dir/config/settings.env.XXXXXX")"
write_setting PRODUCT_FQDN "$product_fqdn"
write_setting TZ "$timezone"
write_setting VCF_VERSION "$vcf_version"
write_setting SKU "$sku"
write_setting SYNC_TARGETS "$sync_targets"
write_setting CRON_SCHEDULE "$cron_schedule"
write_setting CEIP "$ceip"
write_setting ESX_MODE "$esx_mode"
write_setting LOG_RETENTION "$log_retention"
write_setting VKR_MATCH "$vkr_match"
write_setting VKR_OS "$vkr_os"
write_setting DEPOT_ENDPOINT "$depot_endpoint"
write_setting TOKEN_URL "$token_url"
write_setting AUTH_USERNAME "$auth_username"
write_setting TLS_MODE "$tls_mode"
write_setting STORAGE_MODE "$storage_mode"
write_setting DEPOT_VOLUME_NAME "$depot_volume_name"
write_setting DEPOT_LOCAL_PATH "$depot_local_path"
write_setting NFS_SERVER "$nfs_server"
write_setting NFS_EXPORT "$nfs_export"
write_setting NFS_OPTIONS "$nfs_options"
write_setting HTTPS_PORT "$https_port"
write_setting VCFDT_VERSION "$vcfdt_version"
chmod 0640 "$settings_tmp"
mv "$settings_tmp" "$project_dir/config/settings.env"

env_tmp="$(mktemp "$project_dir/.env.XXXXXX")"
{
	printf 'HTTPS_PORT=%s\n' "$https_port"
	printf 'DEPOT_VOLUME_NAME=%s\n' "$depot_volume_name"
	if [ "$storage_mode" = local ]; then
		printf 'DEPOT_VOLUME_TYPE=none\n'
		printf 'DEPOT_VOLUME_OPTIONS=bind\n'
		printf 'DEPOT_VOLUME_DEVICE=%s\n' "$depot_local_path"
	else
		printf 'DEPOT_VOLUME_TYPE=nfs\n'
		printf 'DEPOT_VOLUME_OPTIONS=addr=%s,%s\n' "$nfs_server" "$nfs_options"
		printf 'DEPOT_VOLUME_DEVICE=:%s\n' "$nfs_export"
	fi
} >> "$env_tmp"
chmod 0600 "$env_tmp"
mv "$env_tmp" "$project_dir/.env"

echo "Preparing TLS identity"
if [ "$tls_mode" = self-signed ]; then
	regenerate_cert=true
	if [ -s "$project_dir/secrets/tls/server.crt" ] && [ -s "$project_dir/secrets/tls/server.key" ]; then
		cert_pub="$(openssl x509 -in "$project_dir/secrets/tls/server.crt" -pubkey -noout 2>/dev/null | openssl sha256 || true)"
		key_pub="$(openssl pkey -in "$project_dir/secrets/tls/server.key" -pubout 2>/dev/null | openssl sha256 || true)"
		if openssl x509 -in "$project_dir/secrets/tls/server.crt" -noout \
			-checkhost "$product_fqdn" -checkend 0 >/dev/null 2>&1 \
			&& [ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ]; then
			regenerate_cert=false
		fi
	fi
	if [ "$regenerate_cert" = true ]; then
		openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
			-keyout "$project_dir/secrets/tls/server.key" \
			-out "$project_dir/secrets/tls/server.crt" \
			-subj "/CN=$product_fqdn" -addext "subjectAltName=DNS:$product_fqdn" >/dev/null 2>&1
	fi
	echo "Self-signed TLS selected. Import secrets/tls/server.crt into each VCF consumer trust store."
else
	openssl x509 -in "$tls_cert_path" -noout -checkhost "$product_fqdn" >/dev/null 2>&1 || {
		echo "ERROR: supplied certificate does not cover $product_fqdn" >&2
		exit 1
	}
	cert_pub="$(openssl x509 -in "$tls_cert_path" -pubkey -noout | openssl sha256)"
	key_pub="$(openssl pkey -in "$tls_key_path" -pubout 2>/dev/null | openssl sha256)"
	[ "$cert_pub" = "$key_pub" ] || { echo "ERROR: supplied certificate and key do not match" >&2; exit 1; }
	cp "$tls_cert_path" "$project_dir/secrets/tls/server.crt"
	cp "$tls_key_path" "$project_dir/secrets/tls/server.key"
	echo "Provided TLS selected. Import its issuing CA chain into each VCF consumer trust store."
fi
chmod 0644 "$project_dir/secrets/tls/server.crt"
chmod 0600 "$project_dir/secrets/tls/server.key"

echo "Building the sync base and local licensed layer"
docker build -f "$project_dir/Dockerfile.sync-base" -t vcf-services-sync-base:local "$project_dir"
docker build -f "$project_dir/Dockerfile.sync" -t vcf-services-sync:local "$project_dir"

tool_version_output="$(docker run --rm --entrypoint /opt/vcfdt/bin/vcf-download-tool vcf-services-sync:local --version 2>/dev/null | head -n 1 || true)"
if [ -n "$tool_version_output" ]; then
	vcfdt_version="$(tr -cd '[:alnum:]. _-' <<< "$tool_version_output" | cut -c1-80)"
	sed -i "s|^VCFDT_VERSION=.*$|VCFDT_VERSION=\"$vcfdt_version\"|" "$project_dir/config/settings.env"
fi

docker volume create vcf-services-vcfdt-state >/dev/null
machine_id_output="$(docker run --rm \
	--entrypoint /opt/vcfdt/bin/vcf-download-tool \
	-v vcf-services-vcfdt-state:/root/.local/share/vmware/vdt \
	vcf-services-sync:local configuration get --machineId)"
echo
echo "Software Depot ID"
echo "$machine_id_output"
echo "Open the Broadcom support portal download tool registration flow, register this ID, and obtain an activation code."
echo "The GetActivationCode.ps1 registration path is also supported by the vendor."
ask ACTIVATION_CODE "Activation code (blank to skip for now)" "" true
activation_code="$REPLY_VALUE"
if [ -n "$activation_code" ]; then
	printf '%s\n' "$activation_code" > "$project_dir/secrets/activation-code.txt"
	chmod 0600 "$project_dir/secrets/activation-code.txt"
elif [ ! -s "$project_dir/secrets/activation-code.txt" ]; then
	echo "Sync will start cleanly dormant because no activation code is present."
fi

echo "Preparing the Redis job bus credential"
mkdir -p "$project_dir/secrets/redis"
chmod 0700 "$project_dir/secrets/redis"
if [ ! -s "$project_dir/secrets/redis/password" ]; then
	openssl rand -hex 32 > "$project_dir/secrets/redis/password"
fi
chmod 0600 "$project_dir/secrets/redis/password"
{
	printf 'requirepass %s\n' "$(cat "$project_dir/secrets/redis/password")"
	printf 'protected-mode yes\n'
	printf 'save ""\n'
	printf 'appendonly no\n'
} > "$project_dir/secrets/redis/redis.conf"
chmod 0600 "$project_dir/secrets/redis/redis.conf"

password_hash="$(printf '%s' "$auth_password" | docker run -i --rm caddy:2.10.0-alpine caddy hash-password)"
caddy_tmp="$(mktemp "$project_dir/secrets/caddy.env.XXXXXX")"
printf 'AUTH_USERNAME=%s\n' "$auth_username" > "$caddy_tmp"
printf "AUTH_PASSWORD_HASH='%s'\n" "$password_hash" >> "$caddy_tmp"
chmod 0600 "$caddy_tmp"
mv "$caddy_tmp" "$project_dir/secrets/caddy.env"

cd "$project_dir"
docker compose config >/dev/null
docker compose up -d --build

containers=(vcf-services-depot-web vcf-services-sync vcf-services-ui vcf-services-redis)
deadline=$((SECONDS + 120))
while [ "$SECONDS" -lt "$deadline" ]; do
	all_healthy=true
	for container in "${containers[@]}"; do
		state="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>/dev/null || true)"
		[ "$state" = "running healthy" ] || all_healthy=false
	done
	[ "$all_healthy" = true ] && break
	sleep 2
done
if [ "${all_healthy:-false}" != true ]; then
	docker compose ps >&2
	docker compose logs --tail 100 >&2
	echo "ERROR: not all services became healthy" >&2
	exit 1
fi

if [ -n "$(docker port vcf-services-redis 2>/dev/null)" ]; then
	echo "ERROR: the Redis job bus must not publish a host port" >&2
	exit 1
fi
if docker exec vcf-services-redis redis-cli ping 2>/dev/null | grep -q PONG; then
	echo "ERROR: the Redis job bus accepted an unauthenticated ping" >&2
	exit 1
fi

verify_address=127.0.0.1
verify_port="$https_port"
resolve_arg="$product_fqdn:$verify_port:$verify_address"
base_url="https://$product_fqdn:$verify_port"
curl -kfsS --resolve "$resolve_arg" "$base_url/healthz" | grep -qx ok
curl -kfsS --resolve "$resolve_arg" -u "$auth_username:$auth_password" "$base_url/admin/" | grep -q "VCF Services"
AUTH_USERNAME="$auth_username" AUTH_PASSWORD="$auth_password" \
	"$project_dir/scripts/verify-byte-exact.sh" "$base_url" "$resolve_arg"

echo
echo "VCF Services is running and passed live HTTPS checks."
echo "Depot: $base_url/"
echo "Admin: $base_url/admin/"
echo "UMDS patch store, unauthenticated: $base_url/umds-patch-store/"
echo "Health, unauthenticated: $base_url/healthz"
echo "Fleet content gateway source path: /PROD/COMP/VKR/"
echo "Credential format: $auth_username:<the password entered during installation>"
if [ ! -s "$project_dir/secrets/activation-code.txt" ]; then
	echo "Sync status: not armed: activation code missing. Register the Software Depot ID above, then rerun install.sh."
fi
