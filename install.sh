#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/install-checks.sh
. "$project_dir/scripts/install-checks.sh"
answers_file=""
minimum_free_gb=500
backup_minimum_free_gb=""
backup_advisory_free_gb=100
release_version=""
image_repository=""
release_version_override=""
image_repository_override=""
release_source=bundle
adopt_state_dir=""
adopt_state_volume=""
adopt_mode=false
confirm_old_writer_stopped=false

usage() {
	cat <<'EOF'
Usage: ./install.sh [--answers-file PATH] [--min-free-gb NUMBER]
                    [--min-backup-free-gb NUMBER]
                    [--version TAG] [--image-repository REPOSITORY]
                    [--adopt-state-dir PATH | --adopt-state-volume NAME]
                    [--confirm-old-writer-stopped]

The depot free-space floor defaults to 500 GB. Use --min-free-gb only when a
smaller lab or test store is intentional.

Backup storage is a smaller size class, so it is always checked for existence
and writability but its free space is only advisory: the installer warns below
100 GB and continues. Use --min-backup-free-gb to opt into a hard backup floor.

A packaged release bundle carries its own version and image repository, and is
the normal operator path. In a source checkout the image repository defaults to
the GHCR namespace of the checkout's origin remote and the image tag defaults to
"latest"; use --version and --image-repository to point at specific images.

The adopt options import an existing VCFDT state directory or Docker volume.
Select the existing depot through the normal local or NFS storage answers.
Before adoption, stop the previous VCFDT or depot-sync writer and keep it
stopped. Interactive adoption requires typing STOPPED at the safety prompt.
For scripted adoption, --confirm-old-writer-stopped asserts that automation
already stopped the previous writer. The installer cannot detect a writer on
another system.
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
		--min-backup-free-gb)
			[ "$#" -ge 2 ] || { echo "ERROR: --min-backup-free-gb requires a number" >&2; exit 2; }
			backup_minimum_free_gb="$2"
			shift 2
			;;
		--version)
			[ "$#" -ge 2 ] || { echo "ERROR: --version requires an image tag" >&2; exit 2; }
			release_version_override="$2"
			shift 2
			;;
		--image-repository)
			[ "$#" -ge 2 ] || { echo "ERROR: --image-repository requires a repository path" >&2; exit 2; }
			image_repository_override="$2"
			shift 2
			;;
		--adopt-state-dir)
			[ "$#" -ge 2 ] || { echo "ERROR: --adopt-state-dir requires a path" >&2; exit 2; }
			adopt_state_dir="$2"
			shift 2
			;;
		--adopt-state-volume)
			[ "$#" -ge 2 ] || { echo "ERROR: --adopt-state-volume requires a Docker volume name" >&2; exit 2; }
			adopt_state_volume="$2"
			shift 2
			;;
		--confirm-old-writer-stopped)
			confirm_old_writer_stopped=true
			shift
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
[ -z "$backup_minimum_free_gb" ] || [[ "$backup_minimum_free_gb" =~ ^[0-9]+$ ]] || {
	echo "ERROR: backup free-space floor must be a whole number" >&2
	exit 2
}
if [ -n "$adopt_state_dir" ] && [ -n "$adopt_state_volume" ]; then
	echo "ERROR: use only one of --adopt-state-dir or --adopt-state-volume" >&2
	exit 2
fi
if [ -n "$adopt_state_dir" ] || [ -n "$adopt_state_volume" ]; then
	adopt_mode=true
fi
if [ "$confirm_old_writer_stopped" = true ] && [ "$adopt_mode" = false ]; then
	echo "ERROR: --confirm-old-writer-stopped requires --adopt-state-dir or --adopt-state-volume" >&2
	exit 2
fi
if [ -n "$adopt_state_dir" ]; then
	case "$adopt_state_dir" in
		*,*|*=*)
			echo "ERROR: --adopt-state-dir path may not contain ',' or '=' because Docker's mount syntax cannot parse it: $adopt_state_dir" >&2
			exit 2
			;;
	esac
fi
if [ -n "$adopt_state_volume" ]; then
	[[ "$adopt_state_volume" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]+$ ]] || {
		echo "ERROR: invalid Docker volume name for --adopt-state-volume" >&2
		exit 2
	}
	[ "$adopt_state_volume" != vcf-services-vcfdt-state ] || {
		echo "ERROR: the adoption source must not be the fixed target volume vcf-services-vcfdt-state" >&2
		exit 2
	}
fi

declare -A answers=()
allowed_answer() {
	case "$1" in
		PRODUCT_FQDN|TZ|STORAGE_MODE|DEPOT_LOCAL_PATH|BACKUP_LOCAL_PATH|NFS_SERVER|NFS_EXPORT|BACKUP_NFS_EXPORT|NFS_OPTIONS|TLS_MODE|TLS_CERT_PATH|TLS_KEY_PATH|AUTH_USERNAME|AUTH_PASSWORD|HTTPS_PORT|BACKUP_ENABLED|SFTP_PORT|SFTP_PASSWORD|SFTP_UID_GID|VCF_VERSION|SKU|SYNC_TARGETS|CRON_SCHEDULE|CEIP|ESX_MODE|LOG_RETENTION|VKR_MATCH|VKR_OS|DEPOT_ENDPOINT|TOKEN_URL|ACTIVATION_CODE) return 0 ;;
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

saved_setting() {
	local key="$1" fallback="$2" value
	value="$(sed -nE "s/^${key}=\"?([^\"]*)\"?$/\\1/p" "$project_dir/config/settings.env" 2>/dev/null | tail -n 1)"
	printf '%s' "${value:-$fallback}"
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
}

confirm_previous_writer_is_stopped() {
	local scripted_confirmation="$1" reply
	cat >&2 <<'EOF'

ADOPTION SAFETY CHECK
Stop the previous VCFDT or depot-sync writer before continuing, including a
writer running in a container on another system. Keep it stopped throughout
this installation. The installer cannot detect that remote writer, and two
writers can change state during import or corrupt shared depot content.
EOF
	if [ "$scripted_confirmation" = true ]; then
		echo "Previous writer shutdown asserted by --confirm-old-writer-stopped." >&2
		return 0
	fi
	if [ ! -t 0 ]; then
		echo "ERROR: adoption requires confirmation that the previous writer is stopped." >&2
		echo "       After automation stops it, rerun with --confirm-old-writer-stopped." >&2
		return 1
	fi
	printf 'Type STOPPED to confirm the previous writer is stopped: ' >&2
	if ! IFS= read -r reply; then
		echo >&2
		echo "ERROR: adoption cancelled because writer shutdown was not confirmed." >&2
		return 1
	fi
	[ "$reply" = STOPPED ] || {
		echo "ERROR: adoption cancelled because writer shutdown was not confirmed." >&2
		return 1
	}
}

if [ "$adopt_mode" = true ]; then
	confirm_previous_writer_is_stopped "$confirm_old_writer_stopped" || exit 2
fi

derive_image_repository() {
	local url slug
	command -v git >/dev/null 2>&1 || return 1
	url="$(git -C "$project_dir" config --get remote.origin.url 2>/dev/null)" || return 1
	[ -n "$url" ] || return 1
	url="${url%/}"
	url="${url%.git}"
	case "$url" in
		*://*) slug="${url#*://}"; slug="${slug#*@}"; slug="${slug#*/}" ;;
		*:*) slug="${url#*@}"; slug="${slug#*:}" ;;
		*) slug="$url" ;;
	esac
	[[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
	printf 'ghcr.io/%s' "${slug,,}"
}

release_metadata="$project_dir/.release.env"
if [ -f "$release_metadata" ]; then
	if [ -n "$release_version_override" ] || [ -n "$image_repository_override" ]; then
		echo "ERROR: --version and --image-repository apply only to a source checkout." >&2
		echo "       This release bundle pins its own version and images. To install a" >&2
		echo "       different release, download that release's bundle." >&2
		exit 2
	fi
	while IFS='=' read -r key value || [ -n "$key$value" ]; do
		case "$key" in
			VCF_SERVICES_VERSION) release_version="$value" ;;
			VCF_SERVICES_IMAGE_REPOSITORY) image_repository="$value" ;;
			"") ;;
			*) echo "ERROR: unsupported release metadata key: $key" >&2; exit 1 ;;
		esac
	done < "$release_metadata"
	[[ "$release_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
		echo "ERROR: release metadata has an invalid version" >&2
		exit 1
	}
	[[ "$image_repository" =~ ^ghcr\.io/[a-z0-9._-]+/[a-z0-9._-]+$ ]] || {
		echo "ERROR: release metadata has an invalid image repository" >&2
		exit 1
	}
else
	release_source=source
	release_version="${release_version_override:-latest}"
	if [ -n "$image_repository_override" ]; then
		image_repository="$image_repository_override"
	else
		image_repository="$(derive_image_repository)" || {
			echo "ERROR: this is a source checkout with no usable origin remote, so the image repository cannot be derived." >&2
			echo "       Run the packaged release bundle's install.sh, or pass --image-repository REPOSITORY." >&2
			exit 1
		}
	fi
	[[ "$release_version" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || {
		echo "ERROR: image tag is not a valid Docker tag: $release_version" >&2
		exit 2
	}
	[[ "$image_repository" =~ ^[a-z0-9][a-z0-9.:-]*(/[a-z0-9._-]+)+$ ]] || {
		echo "ERROR: image repository is not a valid lowercase repository path: $image_repository" >&2
		exit 2
	}
	echo "No release metadata found; installing from this source checkout."
	echo "Operators should normally run the install.sh from a packaged release bundle instead."
fi

sync_base_image="$image_repository/sync-base:$release_version"
ui_image="$image_repository/ui:$release_version"
sftp_image="$image_repository/sftp:$release_version"

echo "VCF Services installer"
echo "The health endpoint and UMDS patch-store subtree are intentionally unauthenticated."
echo "Expected storage: 0.5 to 1 TB for one VCF train, plus about 461 GB for the full VKr library."

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

ask STORAGE_MODE "Depot and backup storage mode (local or nfs)" "$(saved_setting STORAGE_MODE local)"
storage_mode="${REPLY_VALUE,,}"
[[ "$storage_mode" == local || "$storage_mode" == nfs ]] || { echo "ERROR: storage mode must be local or nfs" >&2; exit 2; }

depot_local_path=""
backup_local_path=""
nfs_server=""
nfs_export=""
backup_nfs_export=""
nfs_options="nfsvers=4,rw,hard,timeo=600,retrans=2"
saved_depot_local_path="$(saved_setting DEPOT_LOCAL_PATH "$project_dir/data/depot")"
saved_backup_local_path="$(saved_setting BACKUP_LOCAL_PATH "$project_dir/data/backup")"
saved_nfs_server="$(saved_setting NFS_SERVER nfs.example.com)"
saved_nfs_export="$(saved_setting NFS_EXPORT /exports/vcf-services-depot)"
saved_backup_nfs_export="$(saved_setting BACKUP_NFS_EXPORT /exports/vcf-services-backup)"
if [ "$storage_mode" = local ]; then
	ask DEPOT_LOCAL_PATH "Local depot directory" "$saved_depot_local_path"
	depot_local_path="$REPLY_VALUE"
	[[ "$depot_local_path" = /* ]] || depot_local_path="$project_dir/${depot_local_path#./}"
	if [ "$adopt_mode" = true ]; then
		[ -d "$depot_local_path" ] || {
			echo "ERROR: adopted local depot directory not found: $depot_local_path" >&2
			exit 2
		}
		depot_local_path="$(realpath -e "$depot_local_path")"
		case "$depot_local_path" in
			*,*|*=*)
				echo "ERROR: adopted local depot path may not contain ',' or '=' because Docker's mount syntax cannot parse it: $depot_local_path" >&2
				exit 2
				;;
		esac
	else
		depot_local_path="$(realpath -m "$depot_local_path")"
	fi
	ask BACKUP_LOCAL_PATH "Local backup directory (kept outside the depot)" "$saved_backup_local_path"
	backup_local_path="$REPLY_VALUE"
	[[ "$backup_local_path" = /* ]] || backup_local_path="$project_dir/${backup_local_path#./}"
	backup_local_path="$(realpath -m "$backup_local_path")"
	paths_are_disjoint "$depot_local_path" "$backup_local_path" || exit 2
	saved_depot_local_path="$depot_local_path"
	saved_backup_local_path="$backup_local_path"
else
	ask NFS_SERVER "NFS server" "$saved_nfs_server"
	nfs_server="$REPLY_VALUE"
	[[ "$nfs_server" =~ ^[A-Za-z0-9.:-]+$ ]] || { echo "ERROR: invalid NFS server" >&2; exit 2; }
	ask NFS_EXPORT "NFS export path" "$saved_nfs_export"
	nfs_export="$REPLY_VALUE"
	[[ "$nfs_export" =~ ^/[A-Za-z0-9_./-]+$ ]] || { echo "ERROR: NFS export must be a plain absolute path" >&2; exit 2; }
	ask BACKUP_NFS_EXPORT "NFS export path for backups (kept outside the depot export)" "$saved_backup_nfs_export"
	backup_nfs_export="$REPLY_VALUE"
	[[ "$backup_nfs_export" =~ ^/[A-Za-z0-9_./-]+$ ]] || { echo "ERROR: backup NFS export must be a plain absolute path" >&2; exit 2; }
	paths_are_disjoint "$nfs_export" "$backup_nfs_export" || exit 2
	ask NFS_OPTIONS "NFS mount options" "$(saved_setting NFS_OPTIONS "$nfs_options")"
	nfs_options="$REPLY_VALUE"
	[[ "$nfs_options" =~ ^[A-Za-z0-9_=,.-]+$ ]] || { echo "ERROR: NFS options contain unsupported characters" >&2; exit 2; }
	saved_nfs_server="$nfs_server"
	saved_nfs_export="$nfs_export"
	saved_backup_nfs_export="$backup_nfs_export"
fi

depot_volume_fingerprint="$(printf '%s\n' "$storage_mode|$depot_local_path|$nfs_server|$nfs_export|$nfs_options" \
	| sha256sum | cut -c1-12)"
depot_volume_name="vcf-services-depot-store-$depot_volume_fingerprint"
adopted_depot_fingerprint="$(saved_setting DEPOT_ADOPTED "")"
if [ "$adopt_mode" = true ]; then
	adopted_depot_fingerprint="$depot_volume_fingerprint"
	skip_depot_free_space_floor=true
elif [ -n "$adopted_depot_fingerprint" ] && [ "$adopted_depot_fingerprint" = "$depot_volume_fingerprint" ]; then
	skip_depot_free_space_floor=true
else
	skip_depot_free_space_floor=false
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
validate_tcp_port "$https_port" || exit 2

ask BACKUP_ENABLED "Enable the SFTP backup target (true or false)" "$(saved_setting BACKUP_ENABLED true)"
backup_enabled="${REPLY_VALUE,,}"
case "$backup_enabled" in
	yes|1) backup_enabled=true ;;
	no|0) backup_enabled=false ;;
	true|false) ;;
	*) echo "ERROR: backup enabled must be true or false" >&2; exit 2 ;;
esac

ask SFTP_PORT "Published SFTP port" "$(saved_setting SFTP_PORT 2222)"
sftp_port="$REPLY_VALUE"
validate_tcp_port "$sftp_port" || exit 2
[ "$sftp_port" != "$https_port" ] || { echo "ERROR: SFTP_PORT must differ from HTTPS_PORT" >&2; exit 2; }

ask SFTP_UID_GID "Backup service UID:GID" "$(saved_setting SFTP_UID_GID 1003:1003)"
sftp_uid_gid="$REPLY_VALUE"
validate_uid_gid "$sftp_uid_gid" || exit 2

sftp_password=""
sftp_password_file="$project_dir/secrets/sftp/password"
if [ "$backup_enabled" = true ]; then
	if [[ -v "answers[SFTP_PASSWORD]" ]]; then
		sftp_password="${answers[SFTP_PASSWORD]}"
	elif [ ! -s "$sftp_password_file" ]; then
		ask SFTP_PASSWORD "SFTP backup password" "" true
		sftp_password="$REPLY_VALUE"
	fi
	if [ -n "$sftp_password" ]; then
		if [ -z "$answers_file" ]; then
			read -r -s -p "Confirm SFTP backup password [no default]: " sftp_password_confirm
			echo
			[ "$sftp_password" = "$sftp_password_confirm" ] || { echo "ERROR: SFTP passwords do not match" >&2; exit 2; }
		fi
	elif [ ! -s "$sftp_password_file" ]; then
		echo "ERROR: an SFTP backup password is required when backup is enabled" >&2
		exit 2
	fi
fi

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
validate_cron_schedule "$cron_schedule" || exit 2
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

sftp_uid="${sftp_uid_gid%%:*}"
sftp_gid="${sftp_uid_gid#*:}"
echo "Running host preflight checks"
[ "$(uname -m)" = x86_64 ] || { echo "ERROR: only x86_64 hosts are supported" >&2; exit 1; }
if [ "$EUID" -ne 0 ] && ! id -nG | tr ' ' '\n' | grep -qx docker; then
	echo "ERROR: run as root or as a member of the docker group" >&2
	exit 1
fi
for command_name in docker curl openssl jq realpath sha256sum ss; do require_command "$command_name"; done
docker info >/dev/null 2>&1 || { echo "ERROR: current user cannot access the Docker daemon" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: Docker Compose v2 is required" >&2; exit 1; }
if host_tcp_port_is_bound "$sftp_port" \
	&& ! container_publishes_tcp_port vcf-services-sftp "$sftp_port"; then
	echo "ERROR: SFTP_PORT $sftp_port is already bound on this host. Choose another port and rerun install.sh." >&2
	exit 1
fi
if [ -n "$adopt_state_dir" ]; then
	[ -d "$adopt_state_dir" ] || { echo "ERROR: VCFDT state directory not found: $adopt_state_dir" >&2; exit 1; }
	adopt_state_dir="$(realpath -e "$adopt_state_dir")"
elif [ -n "$adopt_state_volume" ]; then
	docker volume inspect "$adopt_state_volume" >/dev/null 2>&1 || {
		echo "ERROR: VCFDT state source volume not found: $adopt_state_volume" >&2
		exit 1
	}
fi
if [ "$storage_mode" = nfs ]; then
	command -v mount.nfs >/dev/null 2>&1 || { echo "ERROR: install nfs-common before using NFS storage" >&2; exit 1; }
fi
outbound_status="$(curl -sSIL --connect-timeout 10 --max-time 20 -o /dev/null -w '%{http_code}' "https://$depot_endpoint" || true)"
if [ "$outbound_status" = 000 ]; then
	echo "ERROR: outbound HTTPS check failed for $depot_endpoint" >&2
	exit 1
fi

mkdir -p "$project_dir/config" "$project_dir/secrets/tls" "$project_dir/secrets/sftp" \
	"$project_dir/data"
chmod 0700 "$project_dir/secrets"
chmod 0700 "$project_dir/secrets/sftp"
if [ -n "$sftp_password" ]; then
	printf '%s\n' "$sftp_password" > "$sftp_password_file"
	chmod 0600 "$sftp_password_file"
	sftp_password=""
fi

transient_volumes=()
cleanup_transient() {
	local volume
	for volume in ${transient_volumes[@]+"${transient_volumes[@]}"}; do
		docker volume rm "$volume" >/dev/null 2>&1 || true
	done
	transient_volumes=()
}
trap cleanup_transient EXIT

track_transient_volume() {
	transient_volumes+=("$1")
}

drop_transient_volume() {
	local kept=() volume
	for volume in ${transient_volumes[@]+"${transient_volumes[@]}"}; do
		[ "$volume" = "$1" ] || kept+=("$volume")
	done
	transient_volumes=(${kept[@]+"${kept[@]}"})
}

if [ "$storage_mode" = local ]; then
	mkdir -p "$backup_local_path"
	if [ "$adopt_mode" = true ]; then
		echo "Adoption reuses existing depot content; skipping the ${minimum_free_gb} GB free-space floor"
	elif [ "$skip_depot_free_space_floor" = true ]; then
		mkdir -p "$depot_local_path"
		echo "This depot was adopted with existing content; skipping the ${minimum_free_gb} GB free-space floor"
		echo "Point the depot answers at a different location to restore the floor"
	else
		mkdir -p "$depot_local_path"
		available_kb="$(df -Pk "$depot_local_path" | awk 'NR==2 {print $4}')"
		minimum_kb=$((minimum_free_gb * 1024 * 1024))
		[ "$available_kb" -ge "$minimum_kb" ] || {
			echo "ERROR: depot has less than ${minimum_free_gb} GB free. Override only after reviewing capacity." >&2
			exit 1
		}
	fi
	backup_available_kb="$(df -Pk "$backup_local_path" | awk 'NR==2 {print $4}')"
	check_backup_free_space "$backup_available_kb" "$backup_local_path" \
		"$backup_minimum_free_gb" "$backup_advisory_free_gb" || exit 1
else
	preflight_volume="vcf-services-nfs-preflight-$$"
	docker volume create --driver local --opt type=nfs \
		--opt "o=addr=$nfs_server,$nfs_options" --opt "device=:$nfs_export" \
		"$preflight_volume" >/dev/null
	track_transient_volume "$preflight_volume"
	if ! available_kb="$(docker run --rm -v "$preflight_volume:/depot:ro" alpine:3.20 \
		sh -c "df -Pk /depot | awk 'NR==2 {print \$4}'")"; then
		echo "ERROR: NFS export could not be mounted" >&2
		exit 1
	fi
	backup_preflight_volume="vcf-services-nfs-backup-preflight-$$"
	docker volume create --driver local --opt type=nfs \
		--opt "o=addr=$nfs_server,$nfs_options" --opt "device=:$backup_nfs_export" \
		"$backup_preflight_volume" >/dev/null
	track_transient_volume "$backup_preflight_volume"
	if ! backup_available_kb="$(docker run --rm --user "$sftp_uid:$sftp_gid" \
		-v "$backup_preflight_volume:/storage:rw" alpine:3.20 \
		sh -c "test -w /storage && df -Pk /storage | awk 'NR==2 {print \$4}'")"; then
		echo "ERROR: SFTP UID:GID $sftp_uid_gid cannot write $backup_nfs_export." >&2
		echo "       Confirm the backup NFS export ownership and that it permits the Docker host." >&2
		exit 1
	fi
	docker volume rm "$backup_preflight_volume" >/dev/null
	drop_transient_volume "$backup_preflight_volume"
	check_backup_free_space "$backup_available_kb" "$backup_nfs_export" \
		"$backup_minimum_free_gb" "$backup_advisory_free_gb" || exit 1
	if [ "$adopt_mode" = true ]; then
		echo "Adoption reuses existing depot content; skipping the ${minimum_free_gb} GB free-space floor"
	elif [ "$skip_depot_free_space_floor" = true ]; then
		echo "This depot was adopted with existing content; skipping the ${minimum_free_gb} GB free-space floor"
		echo "Point the depot answers at a different location to restore the floor"
	else
		minimum_kb=$((minimum_free_gb * 1024 * 1024))
		[ "$available_kb" -ge "$minimum_kb" ] || {
			echo "ERROR: NFS depot has less than ${minimum_free_gb} GB free. Override only after reviewing capacity." >&2
			exit 1
		}
	fi
fi

if [ "$adopt_mode" = true ]; then
	echo "Validating the existing depot read-only at /depot"
	case "$project_dir" in
		*,*|*=*)
			echo "ERROR: install directory may not contain ',' or '=' because Docker's mount syntax cannot parse it: $project_dir" >&2
			exit 2
			;;
	esac
	validator_mount="type=bind,src=$project_dir/scripts/validate-adopted-depot.sh,dst=/validate-adopted-depot.sh,readonly"
	if [ "$storage_mode" = local ]; then
		depot_validation_mount="type=bind,src=$depot_local_path,dst=/depot,readonly"
	else
		depot_validation_mount="type=volume,src=$preflight_volume,dst=/depot,readonly"
	fi
	if ! docker run --rm --mount "$depot_validation_mount" --mount "$validator_mount" \
		alpine:3.20 sh /validate-adopted-depot.sh /depot; then
		exit 1
	fi
fi
if [ "$storage_mode" = nfs ]; then
	docker volume rm "$preflight_volume" >/dev/null
	drop_transient_volume "$preflight_volume"
fi

backup_volume_fingerprint="$(printf '%s\n' "$storage_mode|$backup_local_path|$nfs_server|$backup_nfs_export|$nfs_options" \
	| sha256sum | cut -c1-12)"
backup_volume_name="vcf-services-backup-store-$backup_volume_fingerprint"

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
write_setting DEPOT_ADOPTED "$adopted_depot_fingerprint"
write_setting DEPOT_LOCAL_PATH "$saved_depot_local_path"
write_setting NFS_SERVER "$saved_nfs_server"
write_setting NFS_EXPORT "$saved_nfs_export"
write_setting NFS_OPTIONS "$nfs_options"
write_setting HTTPS_PORT "$https_port"
write_setting BACKUP_ENABLED "$backup_enabled"
write_setting SFTP_PORT "$sftp_port"
write_setting SFTP_UID_GID "$sftp_uid_gid"
write_setting BACKUP_VOLUME_NAME "$backup_volume_name"
write_setting BACKUP_LOCAL_PATH "$saved_backup_local_path"
write_setting BACKUP_NFS_EXPORT "$saved_backup_nfs_export"
write_setting VCFDT_VERSION "$(saved_setting VCFDT_VERSION "not installed")"
chmod 0640 "$settings_tmp"
mv "$settings_tmp" "$project_dir/config/settings.env"

env_tmp="$(mktemp "$project_dir/.env.XXXXXX")"
{
	printf 'HTTPS_PORT=%s\n' "$https_port"
	printf 'SFTP_PORT=%s\n' "$sftp_port"
	printf 'DEPOT_VOLUME_NAME=%s\n' "$depot_volume_name"
	printf 'BACKUP_VOLUME_NAME=%s\n' "$backup_volume_name"
	printf 'VCF_SERVICES_VERSION=%s\n' "$release_version"
	printf 'VCF_SERVICES_UI_IMAGE=%s\n' "$ui_image"
	printf 'VCF_SERVICES_SYNC_IMAGE=%s\n' "$sync_base_image"
	printf 'VCF_SERVICES_SFTP_IMAGE=%s\n' "$sftp_image"
	if [ "$storage_mode" = local ]; then
		printf 'DEPOT_VOLUME_TYPE=none\n'
		printf 'DEPOT_VOLUME_OPTIONS=bind\n'
		printf 'DEPOT_VOLUME_DEVICE=%s\n' "$depot_local_path"
		printf 'BACKUP_VOLUME_TYPE=none\n'
		printf 'BACKUP_VOLUME_OPTIONS=bind\n'
		printf 'BACKUP_VOLUME_DEVICE=%s\n' "$backup_local_path"
	else
		printf 'DEPOT_VOLUME_TYPE=nfs\n'
		printf 'DEPOT_VOLUME_OPTIONS=addr=%s,%s\n' "$nfs_server" "$nfs_options"
		printf 'DEPOT_VOLUME_DEVICE=:%s\n' "$nfs_export"
		printf 'BACKUP_VOLUME_TYPE=nfs\n'
		printf 'BACKUP_VOLUME_OPTIONS=addr=%s,%s\n' "$nfs_server" "$nfs_options"
		printf 'BACKUP_VOLUME_DEVICE=:%s\n' "$backup_nfs_export"
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
			-checkend 0 >/dev/null 2>&1 \
			&& openssl x509 -in "$project_dir/secrets/tls/server.crt" -noout \
				-checkhost "$product_fqdn" 2>/dev/null | grep -q "does match" \
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
	validate_provided_tls "$tls_cert_path" "$tls_key_path" "$product_fqdn" || exit 1
	cp "$tls_cert_path" "$project_dir/secrets/tls/server.crt"
	cp "$tls_key_path" "$project_dir/secrets/tls/server.key"
	echo "Provided TLS selected. Import its issuing CA chain into each VCF consumer trust store."
fi
chmod 0644 "$project_dir/secrets/tls/server.crt"
chmod 0600 "$project_dir/secrets/tls/server.key"

pull_product_image() {
	local image="$1"
	if [ "$release_source" = source ] && docker image inspect "$image" >/dev/null 2>&1; then
		echo "Using the locally present image $image"
		return 0
	fi
	docker pull "$image" && return 0
	echo "ERROR: could not pull $image" >&2
	echo "       If the image exists, its GHCR package may still be private. Set the package" >&2
	echo "       visibility to public under the repository's Packages page, or run" >&2
	echo "       'docker login ghcr.io' on this host with an account that can read it." >&2
	echo "       Otherwise confirm this host can reach ghcr.io and that the tag exists." >&2
	exit 1
}

echo "Pulling license-safe product images"
pull_product_image "$ui_image"
pull_product_image "$sync_base_image"
pull_product_image "$sftp_image"

docker volume create vcf-services-sftp-host-keys >/dev/null
if ! docker volume inspect "$backup_volume_name" >/dev/null 2>&1; then
	if [ "$storage_mode" = local ]; then
		docker volume create --driver local \
			--label com.docker.compose.project=vcf-services \
			--label com.docker.compose.volume=backup_store \
			--opt type=none --opt o=bind \
			--opt "device=$backup_local_path" "$backup_volume_name" >/dev/null
	else
		docker volume create --driver local \
			--label com.docker.compose.project=vcf-services \
			--label com.docker.compose.volume=backup_store \
			--opt type=nfs \
			--opt "o=addr=$nfs_server,$nfs_options" --opt "device=:$backup_nfs_export" \
			"$backup_volume_name" >/dev/null
	fi
fi
docker run --rm --entrypoint /usr/local/bin/sftp-own-backup.sh \
	-v "$backup_volume_name:/mnt/backup:rw" \
	-v vcf-services-sftp-host-keys:/etc/ssh/keys:rw \
	"$sftp_image" "$sftp_uid" "$sftp_gid" || true
if ! docker run --rm --user "$sftp_uid:$sftp_gid" --entrypoint /bin/sh \
	-v "$backup_volume_name:/mnt/backup:rw" "$sftp_image" \
	-c 'set -eu
		mkdir -p /mnt/backup/sddc-manager /mnt/backup/nsx /mnt/backup/vcenter
		touch /mnt/backup/.vcf-services-write-check
		rm /mnt/backup/.vcf-services-write-check'; then
	echo "ERROR: SFTP UID:GID $sftp_uid_gid cannot write the backup storage." >&2
	echo "       The re-own attempt did not take effect. Correct the share ownership, then rerun install.sh." >&2
	exit 1
fi
tool_installed=false
if docker volume inspect vcf-services-vcfdt-tool >/dev/null 2>&1 \
	&& docker run --rm --entrypoint /bin/sh \
	-v vcf-services-vcfdt-tool:/opt/vcfdt:ro "$sync_base_image" \
	-c 'test -s /opt/vcfdt/current/bin/vcf-download-tool'; then
	tool_installed=true
fi
if [ "$adopt_mode" = true ] && [ "$tool_installed" = false ]; then
	echo "ERROR: depot adoption needs the VCF Download Tool to read and verify the Software Depot ID." >&2
	echo "       Install normally, upload the tool in the admin console, then rerun with the adoption options." >&2
	exit 1
fi
if [ "$adopt_mode" = true ]; then
	if [ -n "$adopt_state_dir" ]; then
		state_source_kind=directory
		state_source_value="$adopt_state_dir"
	else
		state_source_kind=volume
		state_source_value="$adopt_state_volume"
	fi
	machine_id_output="$("$project_dir/scripts/import-vcfdt-state.sh" \
		"$sync_base_image" "$state_source_kind" "$state_source_value" \
		vcf-services-vcfdt-state vcf-services-vcfdt-tool)"
else
	docker volume create vcf-services-vcfdt-state >/dev/null
	if [ "$tool_installed" = true ]; then
		machine_id_output="$(docker run --rm \
			--entrypoint /opt/vcfdt/current/bin/vcf-download-tool \
			-v vcf-services-vcfdt-tool:/opt/vcfdt:ro \
			-v vcf-services-vcfdt-state:/root/.local/share/vmware/vdt \
			"$sync_base_image" configuration get --machineId)"
	fi
fi
if [ "$tool_installed" = true ]; then
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
	fi
else
	echo "VCF Download Tool is not installed yet. Upload it in the admin console after startup."
fi
if [ ! -s "$project_dir/secrets/activation-code.txt" ]; then
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

password_hash="$(printf '%s\n' "$auth_password" | docker run -i --rm caddy:2.10.0-alpine caddy hash-password)"
caddy_tmp="$(mktemp "$project_dir/secrets/caddy.env.XXXXXX")"
printf 'AUTH_USERNAME=%s\n' "$auth_username" > "$caddy_tmp"
printf "AUTH_PASSWORD_HASH='%s'\n" "$password_hash" >> "$caddy_tmp"
chmod 0600 "$caddy_tmp"
mv "$caddy_tmp" "$project_dir/secrets/caddy.env"

cd "$project_dir"
docker compose config >/dev/null
docker compose up -d
# A rerun that only adds the activation code changes no container config, so
# Compose keeps the old sync container. Restart it so it re-reads arming state.
docker compose restart depot-sync

containers=(vcf-services-depot-web vcf-services-sync vcf-services-sftp vcf-services-ui vcf-services-redis)
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
if [ "$backup_enabled" = true ]; then
	sftp_verify_password="$(cat "$sftp_password_file")"
	SSHPASS="$sftp_verify_password" docker run --rm --network host --entrypoint /bin/sh \
		-e SSHPASS -e "SFTP_PORT=$sftp_port" "$sftp_image" \
		-c 'printf "ls -la /mnt/backup\nbye\n" | sshpass -e sftp -q \
			-o BatchMode=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
			-P "$SFTP_PORT" vcfbackup@127.0.0.1 >/dev/null'
	sftp_verify_password=""
	docker compose logs sftp-backup | grep -q '(ECDSA)'
fi

echo
echo "VCF Services is running and passed live HTTPS checks."
echo "Depot: $base_url/"
echo "Admin: $base_url/admin/"
echo "UMDS patch store, unauthenticated: $base_url/umds-patch-store/"
echo "Health, unauthenticated: $base_url/healthz"
echo "Fleet content gateway source path: /PROD/COMP/VKR/"
echo "Credential format: $auth_username:<the password entered during installation>"
if [ "$backup_enabled" = true ]; then
	echo "SFTP backup: sftp://$product_fqdn:$sftp_port/mnt/backup/<component>"
	echo "SFTP credential: vcfbackup:<the SFTP password entered during installation>"
	echo "SFTP host fingerprints: docker compose logs sftp-backup"
else
	echo "SFTP backup: disabled in the admin settings"
fi
if [ ! -s "$project_dir/secrets/activation-code.txt" ]; then
	echo "Sync status: not armed: activation code missing. Register the Software Depot ID above, then rerun install.sh."
fi
