#!/usr/bin/env python3
"""VCF Services admin console.

The sync container remains the only depot writer. This app reads config and
state files and exchanges jobs with the sync service over the password
protected Redis bus documented in docs/redis-contract.md. It never talks to
the Docker daemon.
"""

import hashlib
import json
import os
import re
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import redis as redis_lib
from croniter import croniter
from flask import Flask, jsonify, render_template, request

DEPOT = Path(os.environ.get("DEPOT_DIR", "/depot"))
STATE = Path(os.environ.get("STATE_DIR", "/state"))
SETTINGS = Path(os.environ.get("SETTINGS_FILE", "/config/settings.env"))
SFTP_SECRET_DIR = Path(os.environ.get("SFTP_SECRET_DIR", "/run/sftp-secrets"))
SFTP_PASSWORD_FILE = SFTP_SECRET_DIR / "password"
REDIS_HOST = os.environ.get("REDIS_HOST", "redis")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))
REDIS_PASSWORD_FILE = os.environ.get("REDIS_PASSWORD_FILE", "/run/redis/password")
REQUEST_QUEUE = "vcf-services:sync:requests"
STATUS_KEY = "vcf-services:sync:status"
LOG_KEY = "vcf-services:sync:log"
VERSIONS_KEY = "vcf-services:sync:versions"
VALID_TARGETS = ["esx", "install", "upgrade", "patches", "vkr"]
BUILD_RE = re.compile(r"\b(2[0-9]{7})\b")
ARMING_INSTRUCTIONS = (
    "Register the Software Depot ID in the Broadcom download tool registration "
    "flow, then rerun install.sh with the activation code."
)

app = Flask(__name__)
_local_cache = {"ts": 0.0, "builds": None}


def _redis():
    password = None
    try:
        password = Path(REDIS_PASSWORD_FILE).read_text().strip() or None
    except OSError:
        pass
    return redis_lib.Redis(
        host=REDIS_HOST,
        port=REDIS_PORT,
        password=password,
        socket_timeout=5,
        socket_connect_timeout=5,
        decode_responses=True,
    )


def _bus_get(key):
    try:
        return _redis().get(key)
    except (redis_lib.RedisError, OSError):
        return None


def _publish_request(payload):
    _redis().lpush(REQUEST_QUEUE, json.dumps(payload))


def _settings():
    values = {}
    try:
        for raw_line in SETTINGS.read_text().splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


def _write_settings(updates):
    lines = []
    replaced = set()
    try:
        existing = SETTINGS.read_text().splitlines()
    except OSError:
        existing = []
    for line in existing:
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", line)
        key = match.group(1) if match else None
        if key in updates:
            lines.append(_format_setting(key, updates[key]))
            replaced.add(key)
        else:
            lines.append(line)
    for key, value in updates.items():
        if key not in replaced:
            lines.append(_format_setting(key, value))

    SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    handle, temp_name = tempfile.mkstemp(prefix="settings.env.", dir=SETTINGS.parent)
    try:
        os.fchmod(handle, 0o640)
        with os.fdopen(handle, "w") as stream:
            stream.write("\n".join(lines) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, SETTINGS)
    except Exception:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


def _format_setting(key, value):
    escaped = str(value).replace("\\", "\\\\").replace('"', '\\"')
    escaped = escaped.replace("$", "\\$").replace("`", "\\`")
    return f'{key}="{escaped}"'


def _write_sftp_password(password):
    SFTP_SECRET_DIR.mkdir(parents=True, exist_ok=True)
    handle, temp_name = tempfile.mkstemp(prefix="password.", dir=SFTP_SECRET_DIR)
    try:
        os.fchmod(handle, 0o600)
        with os.fdopen(handle, "w") as stream:
            stream.write(password + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, SFTP_PASSWORD_FILE)
    except Exception:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


def _bool_setting(value, fallback=True):
    normalized = str(value or "").lower()
    if normalized in {"true", "yes", "1"}:
        return True
    if normalized in {"false", "no", "0"}:
        return False
    return fallback


def _int_setting(value, fallback):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return fallback


def _paths_are_disjoint(first, second):
    first = first.rstrip("/")
    second = second.rstrip("/")
    if not first or not second or first == second:
        return False
    return not (
        second.startswith(first + "/") or first.startswith(second + "/")
    )


def _backup_settings_doc(settings=None):
    settings = settings or _settings()
    storage_mode = settings.get("STORAGE_MODE", "local")
    backup_local_path = settings.get("BACKUP_LOCAL_PATH", "")
    backup_nfs_export = settings.get("BACKUP_NFS_EXPORT", "")
    return {
        "enabled": _bool_setting(settings.get("BACKUP_ENABLED"), True),
        "port": _int_setting(settings.get("SFTP_PORT"), 2222),
        "user": "vcfbackup",
        "uidGid": settings.get("SFTP_UID_GID", "1003:1003"),
        "storageMode": storage_mode,
        "localPath": settings.get("DEPOT_LOCAL_PATH", ""),
        "backupLocalPath": backup_local_path,
        "nfsServer": settings.get("NFS_SERVER", ""),
        "nfsExport": settings.get("NFS_EXPORT", ""),
        "backupNfsExport": backup_nfs_export,
        "nfsOptions": settings.get(
            "NFS_OPTIONS", "nfsvers=4,rw,hard,timeo=600,retrans=2"
        ),
        "backupPath": backup_local_path
        if storage_mode == "local"
        else backup_nfs_export,
        "passwordConfigured": SFTP_PASSWORD_FILE.is_file()
        and SFTP_PASSWORD_FILE.stat().st_size > 0,
    }


def _state():
    raw = _bus_get(STATUS_KEY)
    if raw:
        try:
            return json.loads(raw)
        except ValueError:
            pass
    try:
        return json.loads((STATE / "state.json").read_text())
    except (OSError, ValueError):
        return {}


def _scan_local_builds(max_age=300):
    now = time.time()
    if _local_cache["builds"] is not None and now - _local_cache["ts"] < max_age:
        return _local_cache["builds"]
    builds = set()
    seen = 0
    try:
        for _root, dirs, files in os.walk(DEPOT):
            for name in dirs + files:
                seen += 1
                match = BUILD_RE.search(name)
                if match:
                    builds.add(match.group(1))
            if seen > 400000:
                break
    except OSError:
        pass
    _local_cache.update(ts=now, builds=builds)
    return builds


def _parse_binaries(text):
    rows = []
    for line in text.splitlines():
        if "|" not in line:
            continue
        parts = [part.strip() for part in line.split("|")]
        if len(parts) < 7 or not re.match(r"^[0-9a-f]{8}-[0-9a-f]{4}-", parts[0]):
            continue
        version = parts[3]
        rows.append(
            {
                "id": parts[0],
                "component": parts[1],
                "name": parts[2],
                "version": version,
                "build": version.split(".")[-1] if version else "",
                "date": parts[4],
                "size": parts[5],
                "type": parts[6],
            }
        )
    return rows


def _epoch(iso_value):
    try:
        return datetime.fromisoformat(str(iso_value).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return None


@app.get("/healthz")
def healthz():
    return "ok", 200


@app.get("/")
def index():
    return render_template("index.html", targets=VALID_TARGETS)


@app.get("/api/status")
def status():
    state = _state()
    settings = _settings()
    cron = settings.get("CRON_SCHEDULE", "0 3 * * 0")
    try:
        tzinfo = ZoneInfo(settings.get("TZ") or "UTC")
    except (KeyError, ValueError):
        tzinfo = timezone.utc
    next_run = None
    try:
        next_run = croniter(cron, datetime.now(tzinfo)).get_next(datetime).isoformat()
    except (KeyError, ValueError):
        pass
    armed = bool(state.get("armed", False))
    return jsonify(
        {
            "running": state.get("running", False),
            "currentTarget": state.get("currentTarget"),
            "startedAt": state.get("startedAt"),
            "finishedAt": state.get("finishedAt"),
            "lastRun": state.get("lastRun", {}),
            "armed": armed,
            "armingInstructions": None if armed else ARMING_INSTRUCTIONS,
            "cron": cron,
            "nextRun": next_run,
            "targets": VALID_TARGETS,
            "defaultTargets": settings.get("SYNC_TARGETS", "").split(),
            "vcfVersion": settings.get("VCF_VERSION", "9.1.0"),
            "vcfdtVersion": settings.get("VCFDT_VERSION", "unknown"),
        }
    )


@app.get("/api/log")
def log():
    text = _bus_get(LOG_KEY)
    if text is None:
        try:
            text = "\n".join(
                (STATE / "latest.log").read_text(errors="replace").splitlines()[-500:]
            )
        except OSError:
            text = ""
    return jsonify({"log": text})


@app.get("/api/settings/backup")
def backup_settings():
    return jsonify(_backup_settings_doc())


@app.post("/api/settings/backup")
def update_backup_settings():
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        return jsonify({"error": "a JSON settings document is required"}), 400

    enabled = body.get("enabled")
    if not isinstance(enabled, bool):
        return jsonify({"error": "enabled must be true or false"}), 400

    port = body.get("port")
    if isinstance(port, bool) or not str(port).isdigit() or not 1 <= int(port) <= 65535:
        return jsonify({"error": "port must be a whole number from 1 through 65535"}), 400
    port = int(port)

    uid_gid = str(body.get("uidGid", ""))
    match = re.fullmatch(r"([0-9]+):([0-9]+)", uid_gid)
    if not match or any(not 1 <= int(value) <= 2147483647 for value in match.groups()):
        return jsonify({"error": "UID:GID must contain two non-root numeric values"}), 400

    storage_mode = str(body.get("storageMode", "")).lower()
    if storage_mode not in {"local", "nfs"}:
        return jsonify({"error": "storage mode must be local or nfs"}), 400

    stored = _settings()
    local_path = str(body.get("localPath", ""))
    backup_local_path = str(body.get("backupLocalPath", ""))
    nfs_server = str(body.get("nfsServer", ""))
    nfs_export = str(body.get("nfsExport", ""))
    backup_nfs_export = str(body.get("backupNfsExport", ""))
    nfs_options = str(body.get("nfsOptions", ""))
    if not re.fullmatch(r"[A-Za-z0-9_=,.-]+", nfs_options):
        return jsonify({"error": "NFS options contain unsupported characters"}), 400
    if storage_mode == "local":
        if not re.fullmatch(r"/[A-Za-z0-9_./-]+", local_path):
            return jsonify({"error": "local path must be a plain absolute path"}), 400
        if not re.fullmatch(r"/[A-Za-z0-9_./-]+", backup_local_path):
            return jsonify(
                {"error": "local backup path must be a plain absolute path"}
            ), 400
        if not _paths_are_disjoint(local_path, backup_local_path):
            return jsonify(
                {"error": "the backup path must sit outside the depot path"}
            ), 400
        nfs_server = stored.get("NFS_SERVER", "")
        nfs_export = stored.get("NFS_EXPORT", "")
        backup_nfs_export = stored.get("BACKUP_NFS_EXPORT", "")
        depot_material_path, backup_material_path = local_path, backup_local_path
        depot_material_export, backup_material_export = "", ""
        depot_material_server = ""
    else:
        if not re.fullmatch(r"[A-Za-z0-9.:-]+", nfs_server):
            return jsonify({"error": "NFS server is invalid"}), 400
        if not re.fullmatch(r"/[A-Za-z0-9_./-]+", nfs_export):
            return jsonify({"error": "NFS export must be a plain absolute path"}), 400
        if not re.fullmatch(r"/[A-Za-z0-9_./-]+", backup_nfs_export):
            return jsonify(
                {"error": "backup NFS export must be a plain absolute path"}
            ), 400
        if not _paths_are_disjoint(nfs_export, backup_nfs_export):
            return jsonify(
                {"error": "the backup export must sit outside the depot export"}
            ), 400
        local_path = stored.get("DEPOT_LOCAL_PATH", "")
        backup_local_path = stored.get("BACKUP_LOCAL_PATH", "")
        depot_material_path, backup_material_path = "", ""
        depot_material_export, backup_material_export = nfs_export, backup_nfs_export
        depot_material_server = nfs_server

    password = body.get("password")
    if password is not None:
        if not isinstance(password, str) or "\n" in password or "\r" in password:
            return jsonify({"error": "password must be one line"}), 400
        if len(password) > 1024:
            return jsonify({"error": "password is too long"}), 400
        if not password:
            password = None
    if enabled and not password and not (
        SFTP_PASSWORD_FILE.is_file() and SFTP_PASSWORD_FILE.stat().st_size > 0
    ):
        return jsonify({"error": "a password is required before backup can be enabled"}), 400

    depot_material = "|".join(
        [storage_mode, depot_material_path, depot_material_server,
         depot_material_export, nfs_options]
    )
    backup_material = "|".join(
        [storage_mode, backup_material_path, depot_material_server,
         backup_material_export, nfs_options]
    )
    updates = {
        "BACKUP_ENABLED": str(enabled).lower(),
        "SFTP_PORT": str(port),
        "SFTP_UID_GID": uid_gid,
        "STORAGE_MODE": storage_mode,
        "DEPOT_LOCAL_PATH": local_path,
        "NFS_SERVER": nfs_server,
        "NFS_EXPORT": nfs_export,
        "NFS_OPTIONS": nfs_options,
        "DEPOT_VOLUME_NAME": "vcf-services-depot-store-"
        + hashlib.sha256((depot_material + "\n").encode()).hexdigest()[:12],
        "BACKUP_VOLUME_NAME": "vcf-services-backup-store-"
        + hashlib.sha256((backup_material + "\n").encode()).hexdigest()[:12],
        "BACKUP_LOCAL_PATH": backup_local_path,
        "BACKUP_NFS_EXPORT": backup_nfs_export,
    }
    before = _backup_settings_doc()
    try:
        if password:
            _write_sftp_password(password)
        _write_settings(updates)
    except OSError as exc:
        return jsonify({"error": f"could not save backup settings: {exc}"}), 500

    after = _backup_settings_doc()
    restart_required = any(
        before[key] != after[key]
        for key in ("port", "storageMode", "localPath", "backupLocalPath",
                    "nfsServer", "nfsExport", "backupNfsExport", "nfsOptions")
    )
    return jsonify(
        {
            **after,
            "saved": True,
            "liveReloadSeconds": 5,
            "installerRerunRequired": restart_required,
        }
    )


@app.get("/api/versions/local")
def versions_local():
    return jsonify({"builds": sorted(_scan_local_builds(), reverse=True)})


@app.get("/api/versions/remote")
def versions_remote():
    doc = None
    raw = _bus_get(VERSIONS_KEY)
    if raw:
        try:
            doc = json.loads(raw)
        except ValueError:
            doc = None
    refresh = request.args.get("refresh") == "1" or doc is None
    if refresh:
        try:
            _publish_request(
                {
                    "kind": "versions",
                    "requestedAt": datetime.now(timezone.utc).isoformat(),
                }
            )
        except (redis_lib.RedisError, OSError) as exc:
            if doc is None:
                return jsonify({"error": f"job bus unavailable: {exc}", "components": []}), 502
    if doc is None:
        return jsonify({"components": [], "pending": True}), 202
    if doc.get("error"):
        return jsonify({"error": doc["error"], "components": []}), 502
    if doc.get("exitCode"):
        detail = (doc.get("output") or "").strip()[-500:]
        return (
            jsonify(
                {
                    "error": f"version query failed with exit code {doc['exitCode']}: {detail}",
                    "components": [],
                }
            ),
            502,
        )
    local = _scan_local_builds()
    rows = [
        {**row, "present": row.get("build") in local}
        for row in _parse_binaries(doc.get("output", ""))
    ]
    return jsonify(
        {
            "components": rows,
            "fetchedAt": _epoch(doc.get("fetchedAt")),
            "refreshRequested": refresh,
        }
    )


@app.post("/api/sync")
def sync():
    body = request.get_json(silent=True) or {}
    targets = [target for target in body.get("targets", []) if target in VALID_TARGETS]
    if not targets:
        return jsonify({"error": "select at least one valid target"}), 400
    state = _state()
    if not state.get("armed", False):
        return jsonify({"error": f"not armed: activation code missing. {ARMING_INSTRUCTIONS}"}), 409
    if state.get("running"):
        return jsonify({"error": "a sync is already running"}), 409
    try:
        _publish_request(
            {
                "kind": "sync",
                "targets": targets,
                "requestedAt": datetime.now(timezone.utc).isoformat(),
            }
        )
    except (redis_lib.RedisError, OSError) as exc:
        return jsonify({"error": f"could not publish sync request: {exc}"}), 502
    return jsonify({"published": True, "targets": targets}), 202


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
