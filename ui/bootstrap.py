#!/usr/bin/env python3
"""Initialize the file-backed appliance state before services start."""

import os
import secrets
from pathlib import Path


CONFIG_DIR = Path(os.environ.get("CONFIG_DIR", "/config"))
SECRETS_DIR = Path(os.environ.get("SECRETS_DIR", "/secrets"))
SETTINGS = CONFIG_DIR / "settings.env"

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


def main():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    SECRETS_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o750)
    os.chmod(SECRETS_DIR, 0o700)

    settings_text = "".join(
        f'{key}="{value}"\n' for key, value in DEFAULT_SETTINGS.items()
    )
    write_once(SETTINGS, settings_text, 0o640)

    redis_password = SECRETS_DIR / "redis-password"
    write_once(redis_password, secrets.token_urlsafe(48) + "\n")
    password = redis_password.read_text(encoding="utf-8").strip()
    write_once(
        SECRETS_DIR / "redis.conf",
        "bind 0.0.0.0\n"
        "protected-mode yes\n"
        "port 6379\n"
        "save \"\"\n"
        "appendonly no\n"
        f"requirepass {password}\n",
    )
    write_once(SECRETS_DIR / "flask-secret", secrets.token_hex(48) + "\n")
    write_once(SECRETS_DIR / "activation-code.txt", "")
    print("VCF Services persistent configuration is ready")


if __name__ == "__main__":
    main()
