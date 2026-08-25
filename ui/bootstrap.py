#!/usr/bin/env python3
"""Initialize and verify file-backed appliance state before services start."""

import json
import os
import secrets
import tempfile
from datetime import datetime, timezone
from pathlib import Path


CONFIG_DIR = Path(os.environ.get("CONFIG_DIR", "/config"))
SECRETS_DIR = Path(os.environ.get("SECRETS_DIR", "/secrets"))
SETTINGS = CONFIG_DIR / "settings.env"
VERSION_MARKER = CONFIG_DIR / ".vcf-services-version"
VERSION_STATUS = CONFIG_DIR / ".vcf-services-version-status.json"
CURRENT_VERSION = os.environ.get("VCF_SERVICES_VERSION", "dev")

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


def write_once(path, content, mode=0o600):
    if path.exists():
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


def verify_config_version(config_was_empty):
    found = None
    try:
        found = VERSION_MARKER.read_text(encoding="utf-8").strip() or None
    except OSError:
        pass

    if found == CURRENT_VERSION:
        VERSION_STATUS.unlink(missing_ok=True)
        return True
    if found is None and config_was_empty:
        write_once(VERSION_MARKER, CURRENT_VERSION + "\n", 0o640)
        VERSION_STATUS.unlink(missing_ok=True)
        return True

    found_label = found or "unversioned state"
    message = (
        f"Startup is blocked because the config volume contains {found_label}, "
        f"but this appliance is {CURRENT_VERSION}. Existing settings, secrets, and "
        "service identity were not trusted or changed; only this diagnostic block "
        "record was added so the console can explain the problem. Stop the stack, "
        f"preserve any data you need, then start {CURRENT_VERSION} with a new config "
        f"volume or restore a config volume marked for {CURRENT_VERSION}."
    )
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


def main():
    config_existed = CONFIG_DIR.exists()
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    config_was_empty = not config_existed or not any(CONFIG_DIR.iterdir())
    if not verify_config_version(config_was_empty):
        return

    SECRETS_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o750)
    os.chmod(SECRETS_DIR, 0o700)

    settings_text = "".join(
        f'{key}="{value}"\n' for key, value in DEFAULT_SETTINGS.items()
    )
    write_once(SETTINGS, settings_text, 0o640)

    for consumer in ("redis", "sync", "sftp", "ui"):
        subdir = SECRETS_DIR / consumer
        subdir.mkdir(exist_ok=True)
        os.chmod(subdir, 0o700)

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
