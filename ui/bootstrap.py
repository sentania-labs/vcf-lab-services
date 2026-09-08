#!/usr/bin/env python3
"""Initialize and verify file-backed appliance state before services start."""

import json
import os
import re
import secrets
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path


CONFIG_DIR = Path(os.environ.get("CONFIG_DIR", "/config"))
SECRETS_DIR = Path(os.environ.get("SECRETS_DIR", "/etc/vcf-services/secrets"))
SETTINGS = CONFIG_DIR / "settings.env"
VERSION_MARKER = CONFIG_DIR / ".vcf-services-version"
VERSION_STATUS = CONFIG_DIR / ".vcf-services-version-status.json"
SCHEMA_MARKER = CONFIG_DIR / ".vcf-services-schema"
MIGRATION_STATUS = CONFIG_DIR / ".vcf-services-migration.json"
MIGRATION_BACKUPS = CONFIG_DIR / "migration-backups"
CURRENT_VERSION = os.environ.get("VCF_SERVICES_VERSION", "dev")
CURRENT_SCHEMA = 1

DEFAULT_SETTINGS = {
    "AUTH_USERNAME": "vcf",
    "BACKUP_ENABLED": "false",
    "CEIP": "DISABLE",
    "CRON_SCHEDULE": "0 3 * * 0",
    "DEPOT_ENDPOINT": "dl.broadcom.com",
    "ESX_MODE": "download",
    "LOG_RETENTION": "20",
    "SETUP_COMPLETE": "false",
    "SFTP_UID_GID": "1003:1003",
    "SKU": "VCF",
    "STORAGE_CONFIRMED": "false",
    "SYNC_TARGETS": "esx install upgrade patches",
    "TOKEN_URL": "https://eapi.broadcom.com/vcf/generateToken",
    "TZ": "UTC",
    "VCF_VERSION": "9.1.0",
    "VKR_MATCH": "",
    "VKR_OS": "",
}


def _release_key(value):
    if value == "dev":
        return (10**9,)
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)(?:[-+].*)?", value or "")
    if match is None:
        return None
    return tuple(int(part) for part in match.groups())


def _settings_keys():
    keys = set()
    try:
        lines = SETTINGS.read_text(encoding="utf-8").splitlines()
    except OSError:
        return keys
    for line in lines:
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", line)
        if match:
            keys.add(match.group(1))
    return keys


def _fill_settings_defaults():
    existing = _settings_keys()
    additions = [
        f'{key}="{value}"' for key, value in DEFAULT_SETTINGS.items() if key not in existing
    ]
    if not SETTINGS.exists():
        write_atomic(SETTINGS, "\n".join(additions) + "\n", 0o640)
    elif additions:
        original = SETTINGS.read_text(encoding="utf-8")
        separator = "" if not original or original.endswith("\n") else "\n"
        write_atomic(
            SETTINGS,
            original + separator + "\n".join(additions) + "\n",
            0o640,
        )


def _migrate_schema_0_to_1():
    _fill_settings_defaults()


MIGRATIONS = (_migrate_schema_0_to_1,)


def write_once(path, content, mode=0o600):
    if path.exists():
        os.chmod(path, mode)
        return
    handle = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(handle, "w", encoding="utf-8") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())


def write_atomic(path, content, mode=0o600):
    handle, temp_name = tempfile.mkstemp(prefix=f"{path.name}.", dir=path.parent)
    try:
        os.fchmod(handle, mode)
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, path)
    except Exception:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


def _block_config(found, message):
    status = {
        "blocked": True,
        "expectedVersion": CURRENT_VERSION,
        "foundVersion": found,
        "message": message,
        "detectedAt": datetime.now(timezone.utc).isoformat(),
    }
    write_atomic(VERSION_STATUS, json.dumps(status) + "\n", 0o640)
    print(f"ERROR: {message}")
    return False


def _backup_config(from_schema):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    backup = MIGRATION_BACKUPS / f"{stamp}-schema-{from_schema}-to-{CURRENT_SCHEMA}"
    backup.mkdir(parents=True)
    for path in CONFIG_DIR.iterdir():
        if path == MIGRATION_BACKUPS or not path.is_file():
            continue
        if path.stat().st_size > 1024 * 1024:
            continue
        shutil.copy2(path, backup / path.name)
    return backup


def _read_schema():
    if not SCHEMA_MARKER.exists():
        return 0
    try:
        return int(SCHEMA_MARKER.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None


def prepare_config(config_was_empty):
    found = None
    try:
        found = VERSION_MARKER.read_text(encoding="utf-8").strip() or None
    except OSError:
        pass

    if found is None and config_was_empty:
        _fill_settings_defaults()
        write_once(SCHEMA_MARKER, f"{CURRENT_SCHEMA}\n", 0o640)
        write_once(VERSION_MARKER, CURRENT_VERSION + "\n", 0o640)
        VERSION_STATUS.unlink(missing_ok=True)
        return True

    current_key = _release_key(CURRENT_VERSION)
    found_key = _release_key(found) if found else None
    if found and found != CURRENT_VERSION and (
        current_key is None or found_key is None or found_key > current_key
    ):
        message = (
            f"Startup is blocked because the config volume contains {found}, "
            f"which is newer than or incompatible with this appliance {CURRENT_VERSION}. "
            "Existing settings, secrets, and service identity were not trusted or "
            "changed; only this diagnostic block record was added so the console can "
            "explain the problem. Start the release that wrote this config volume or "
            "restore a backup created before that upgrade."
        )
        return _block_config(found, message)

    schema = _read_schema()
    if schema is None or schema < 0 or schema > CURRENT_SCHEMA:
        schema_label = schema if schema is not None else "unreadable"
        message = (
            f"Startup is blocked because the config volume schema is {schema_label}, "
            f"but this appliance supports schema {CURRENT_SCHEMA}. Existing settings, "
            "secrets, and service identity were not changed. Start a compatible newer "
            "release or restore a pre-upgrade backup."
        )
        return _block_config(found, message)

    if schema < CURRENT_SCHEMA:
        backup = _backup_config(schema)
        migrated_at = datetime.now(timezone.utc).isoformat()
        original_schema = schema
        try:
            while schema < CURRENT_SCHEMA:
                MIGRATIONS[schema]()
                schema += 1
                write_atomic(SCHEMA_MARKER, f"{schema}\n", 0o640)
            write_atomic(VERSION_MARKER, CURRENT_VERSION + "\n", 0o640)
            result = {
                "status": "completed",
                "fromSchema": original_schema,
                "toSchema": schema,
                "fromVersion": found,
                "toVersion": CURRENT_VERSION,
                "backupPath": str(backup),
                "migratedAt": migrated_at,
            }
            write_atomic(MIGRATION_STATUS, json.dumps(result) + "\n", 0o640)
        except Exception as exc:
            message = (
                f"Config migration failed after a backup was written to {backup}: {exc}. "
                "The stack is blocked so the backup can be inspected or restored."
            )
            return _block_config(found, message)
    elif found != CURRENT_VERSION:
        write_atomic(VERSION_MARKER, CURRENT_VERSION + "\n", 0o640)

    VERSION_STATUS.unlink(missing_ok=True)
    return True


def main():
    config_existed = CONFIG_DIR.exists()
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    config_was_empty = not config_existed or not any(CONFIG_DIR.iterdir())
    if not prepare_config(config_was_empty):
        return

    SECRETS_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o750)
    os.chmod(SECRETS_DIR, 0o700)

    _fill_settings_defaults()

    for consumer in ("redis", "sync", "sftp", "ui"):
        subdir = SECRETS_DIR / consumer
        subdir.mkdir(exist_ok=True)
        os.chmod(subdir, 0o700)

    # Kubernetes fsGroup can add group-write bits while mounting a volume.
    # Normalize private files on every start before their consumers run.
    for relative in (
        "redis/redis-password",
        "redis/redis.conf",
        "sync/activation-code.txt",
        "sync/redis-password",
        "sftp/sftp-password",
        "ui/.credentials.lock",
        "ui/auth.json",
        "ui/flask-secret",
        "ui/redis-password",
    ):
        secret = SECRETS_DIR / relative
        if secret.exists():
            os.chmod(secret, 0o600)

    redis_password = SECRETS_DIR / "redis" / "redis-password"
    write_once(redis_password, secrets.token_urlsafe(48) + "\n")
    password = redis_password.read_text(encoding="utf-8").strip()
    write_once(SECRETS_DIR / "sync" / "redis-password", password + "\n")
    write_once(SECRETS_DIR / "ui" / "redis-password", password + "\n")
    write_once(
        SECRETS_DIR / "redis" / "redis.conf",
        "bind 0.0.0.0\n"
        "protected-mode yes\n"
        "port 6379\n"
        "save \"\"\n"
        "appendonly no\n"
        f"requirepass {password}\n",
    )
    write_once(SECRETS_DIR / "ui" / "flask-secret", secrets.token_hex(48) + "\n")
    write_once(SECRETS_DIR / "sync" / "activation-code.txt", "")
    print("VCF Services persistent configuration is ready")


if __name__ == "__main__":
    main()
