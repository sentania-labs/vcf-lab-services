#!/usr/bin/env python3
"""VCF Services admin console.

The sync container remains the only depot writer. This app reads config and
state files and exchanges jobs with the sync service over the password
protected Redis bus documented in docs/redis-contract.md. It never talks to
the Docker daemon.
"""

import fcntl
import hashlib
import ipaddress
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
import uuid
import zipfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from zoneinfo import ZoneInfo

import bcrypt
import redis as redis_lib
from croniter import croniter
from flask import Flask, jsonify, render_template, request, send_file, session

DEPOT = Path(os.environ.get("DEPOT_DIR", "/depot"))
BACKUP = Path(os.environ.get("BACKUP_DIR", "/mnt/backup"))
STATE = Path(os.environ.get("STATE_DIR", "/state"))
SETTINGS = Path(os.environ.get("SETTINGS_FILE", "/config/settings.env"))
VCFDT_STORE = Path(os.environ.get("VCFDT_STORE", "/opt/vcfdt"))
AUTH_FILE = Path(os.environ.get("AUTH_FILE", "/run/secrets/auth.json"))
ACTIVATION_CODE_FILE = Path(
    os.environ.get("ACTIVATION_CODE_FILE", "/run/secrets/activation-code.txt")
)
SFTP_PASSWORD_FILE = Path(
    os.environ.get("SFTP_PASSWORD_FILE", "/run/secrets/sftp-password")
)
FLASK_SECRET_FILE = Path(
    os.environ.get("FLASK_SECRET_FILE", "/run/secrets/flask-secret")
)
CADDY_CA_FILE = Path(
    os.environ.get(
        "CADDY_CA_FILE", "/caddy-data/caddy/pki/authorities/local/root.crt"
    )
)
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
    "flow, then save the activation code here."
)

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 1024 * 1024 * 1024
try:
    app.secret_key = FLASK_SECRET_FILE.read_text().strip()
except OSError as exc:
    raise RuntimeError(
        f"the session secret at {FLASK_SECRET_FILE} is missing or unreadable; "
        "run the bootstrap container to initialize the secrets volume"
    ) from exc
if not app.secret_key:
    raise RuntimeError(f"the session secret at {FLASK_SECRET_FILE} is empty")
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Strict",
    SESSION_COOKIE_SECURE=True,
)
_local_cache = {"ts": 0.0, "builds": None}

MAX_ARCHIVE_MEMBERS = 20000
MAX_EXTRACTED_BYTES = 2 * 1024 * 1024 * 1024


class ToolArchiveError(ValueError):
    """An operator-supplied archive failed validation."""


def _auth_doc():
    try:
        doc = json.loads(AUTH_FILE.read_text())
        if doc.get("username") and doc.get("passwordHash"):
            return doc
    except (OSError, ValueError):
        pass
    return None


def _is_authenticated():
    auth = _auth_doc()
    return bool(auth and session.get("owner") == auth.get("username"))


_verified_cache = {"stamp": None, "entries": {}}
VERIFIED_CACHE_TTL = 300
VERIFIED_CACHE_MAX = 128


def _auth_file_stamp():
    try:
        stat = AUTH_FILE.stat()
        return (stat.st_mtime_ns, stat.st_size)
    except OSError:
        return None


def _verify_credentials(username, password):
    auth = _auth_doc()
    if not auth or username != auth.get("username"):
        return False
    stamp = _auth_file_stamp()
    if stamp != _verified_cache["stamp"] or stamp is None:
        _verified_cache.update(stamp=stamp, entries={})
    digest = hashlib.sha256(f"{username}\x00{password}".encode()).hexdigest()
    now = time.monotonic()
    expiry = _verified_cache["entries"].get(digest)
    if expiry is not None and expiry > now:
        return True
    try:
        verified = bcrypt.checkpw(password.encode(), auth["passwordHash"].encode())
    except (ValueError, TypeError):
        return False
    if verified:
        if len(_verified_cache["entries"]) >= VERIFIED_CACHE_MAX:
            _verified_cache["entries"].clear()
        _verified_cache["entries"][digest] = now + VERIFIED_CACHE_TTL
    return verified


def _write_secret(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temp_name = tempfile.mkstemp(prefix=f"{path.name}.", dir=path.parent)
    try:
        os.fchmod(handle, 0o600)
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, path)
    except Exception:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


@contextmanager
def _credential_update_lock():
    AUTH_FILE.parent.mkdir(parents=True, exist_ok=True)
    lock_file = open(
        AUTH_FILE.parent / ".credentials.lock", "a+", encoding="utf-8"
    )
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        yield
    finally:
        lock_file.close()


def _replace_shared_credentials(auth_doc, password):
    previous_sftp = None
    sftp_existed = SFTP_PASSWORD_FILE.exists()
    if sftp_existed:
        previous_sftp = SFTP_PASSWORD_FILE.read_text(encoding="utf-8")

    sftp_replaced = False
    try:
        _write_sftp_password(password)
        sftp_replaced = True
        _write_secret(AUTH_FILE, json.dumps(auth_doc) + "\n")
    except OSError:
        if sftp_replaced:
            if sftp_existed:
                _write_secret(SFTP_PASSWORD_FILE, previous_sftp)
            else:
                SFTP_PASSWORD_FILE.unlink(missing_ok=True)
        raise


@app.before_request
def require_console_owner():
    public_paths = {
        "/",
        "/healthz",
        "/auth/check",
        "/tls/allow",
        "/api/session",
        "/api/claim",
        "/api/bootstrap",
        "/api/login",
    }
    if request.path in public_paths:
        return None
    if _auth_doc() is None:
        return jsonify({"error": "claim this appliance before continuing"}), 403
    if not _is_authenticated():
        return jsonify({"error": "sign in to continue"}), 401
    return None


def _safe_archive_path(name):
    normalized = str(name).replace("\\", "/")
    if not normalized or "\x00" in normalized:
        raise ToolArchiveError("the archive contains an unsafe path")
    path = PurePosixPath(normalized)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise ToolArchiveError("the archive contains an unsafe path")
    if path.parts and path.parts[0].endswith(":"):
        raise ToolArchiveError("the archive contains an unsafe path")
    return path


def _extract_tar(archive_path, destination):
    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            members = []
            extracted_bytes = 0
            for member in archive:
                members.append(member)
                if len(members) > MAX_ARCHIVE_MEMBERS:
                    raise ToolArchiveError("the archive contains too many files")
                _safe_archive_path(member.name)
                if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                    raise ToolArchiveError("the archive contains an unsupported file type")
                if member.issym() or member.islnk():
                    _safe_archive_path(member.linkname)
                extracted_bytes += max(member.size, 0)
                if extracted_bytes > MAX_EXTRACTED_BYTES:
                    raise ToolArchiveError("the expanded archive is too large")
            archive.extractall(destination, members=members, filter="data")
    except (tarfile.TarError, OSError) as exc:
        raise ToolArchiveError("the uploaded file is not a readable tar.gz archive") from exc


def _extract_zip(archive_path, destination):
    try:
        with zipfile.ZipFile(archive_path) as archive:
            members = archive.infolist()
            if len(members) > MAX_ARCHIVE_MEMBERS:
                raise ToolArchiveError("the archive contains too many files")
            extracted_bytes = 0
            seen = set()
            file_modes = []
            for member in members:
                path = _safe_archive_path(member.filename.rstrip("/"))
                if path in seen:
                    raise ToolArchiveError("the archive contains duplicate paths")
                seen.add(path)
                if (member.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ToolArchiveError("the archive contains an unsupported symbolic link")
                extracted_bytes += max(member.file_size, 0)
                if extracted_bytes > MAX_EXTRACTED_BYTES:
                    raise ToolArchiveError("the expanded archive is too large")
                if not member.is_dir():
                    file_modes.append((path, (member.external_attr >> 16) & 0o777))
            archive.extractall(destination)
            for path, mode in file_modes:
                if mode:
                    os.chmod(destination / path, mode)
    except (zipfile.BadZipFile, OSError) as exc:
        raise ToolArchiveError("the uploaded file is not a readable zip archive") from exc


def _archive_kind(filename):
    lowered = filename.lower()
    if lowered.endswith((".tar.gz", ".tgz")):
        return "tar"
    if lowered.endswith(".zip"):
        return "zip"
    raise ToolArchiveError("choose a .tar.gz, .tgz, or .zip VCF Download Tool archive")


def _patch_tool_endpoints(tool_root):
    properties = tool_root / "conf" / "application-prodv2.properties"
    if not properties.is_file():
        return
    settings = _settings()
    replacements = {
        "lcm.depot.adapter.host": settings.get("DEPOT_ENDPOINT", "dl.broadcom.com"),
        "lcm.access_token.broadcom.authorization.server.url": settings.get(
            "TOKEN_URL", "https://eapi.broadcom.com/vcf/generateToken"
        ),
    }
    lines = properties.read_text().splitlines()
    found = set()
    updated = []
    for line in lines:
        key = line.split("=", 1)[0]
        if key in replacements:
            updated.append(f"{key}={replacements[key]}")
            found.add(key)
        else:
            updated.append(line)
    updated.extend(f"{key}={value}" for key, value in replacements.items() if key not in found)
    properties.write_text("\n".join(updated) + "\n")


def _find_tool_root(extracted):
    candidates = [
        path
        for path in extracted.rglob("vcf-download-tool")
        if path.parent.name == "bin" and path.is_file() and not path.is_symlink()
    ]
    if len(candidates) != 1 or candidates[0].stat().st_size == 0:
        raise ToolArchiveError(
            "the archive must contain exactly one non-empty bin/vcf-download-tool file"
        )
    tool = candidates[0]
    tool.chmod(0o755)
    return tool.parent.parent


def _probe_tool_version(tool_root):
    try:
        result = subprocess.run(
            [tool_root / "bin" / "vcf-download-tool", "--version"],
            cwd=tool_root,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ToolArchiveError("bin/vcf-download-tool could not report its version") from exc
    first_line = next(
        (line.strip() for line in result.stdout.splitlines() if line.strip()), ""
    )
    version = re.sub(r"[^A-Za-z0-9._ +()-]", "", first_line)[:120].strip()
    if result.returncode != 0 or not version:
        raise ToolArchiveError("bin/vcf-download-tool could not report its version")
    return version


def _current_tool_info():
    current = VCFDT_STORE / "current"
    tool = current / "bin" / "vcf-download-tool"
    if not current.is_dir() or not tool.is_file() or tool.is_symlink() or tool.stat().st_size == 0:
        return {"installed": False, "version": "not installed"}
    metadata = {}
    try:
        metadata = json.loads((current / ".vcf-services.json").read_text())
    except (OSError, ValueError):
        pass
    return {
        "installed": True,
        "version": metadata.get("version", "unknown"),
        "uploadedAt": metadata.get("uploadedAt"),
    }


@contextmanager
def _tool_update_lock():
    VCFDT_STORE.mkdir(parents=True, exist_ok=True)
    lock_file = open(VCFDT_STORE / ".update.lock", "a+", encoding="utf-8")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        lock_file.close()


def _install_tool(upload):
    filename = Path(str(upload.filename or "").replace("\\", "/")).name
    archive_kind = _archive_kind(filename)
    release_id = uuid.uuid4().hex
    incoming = VCFDT_STORE / ".incoming" / release_id
    extracted = incoming / "extracted"
    archive_path = incoming / "upload"
    releases = VCFDT_STORE / "releases"
    release_path = releases / release_id
    next_link = VCFDT_STORE / f".current-{release_id}"
    incoming.mkdir(parents=True)
    extracted.mkdir()
    releases.mkdir(exist_ok=True)
    old_target = None
    swapped = False
    try:
        upload.save(archive_path)
        if archive_path.stat().st_size == 0:
            raise ToolArchiveError("the uploaded archive is empty")
        if archive_kind == "tar":
            _extract_tar(archive_path, extracted)
        else:
            _extract_zip(archive_path, extracted)
        tool_root = _find_tool_root(extracted)
        _patch_tool_endpoints(tool_root)
        metadata = {
            "version": _probe_tool_version(tool_root),
            "uploadedAt": datetime.now(timezone.utc).isoformat(),
        }
        (tool_root / ".vcf-services.json").write_text(json.dumps(metadata) + "\n")
        os.replace(tool_root, release_path)

        current = VCFDT_STORE / "current"
        if current.is_symlink():
            old_target = (VCFDT_STORE / os.readlink(current)).resolve()
        next_link.symlink_to(Path("releases") / release_id)
        os.replace(next_link, current)
        swapped = True
        return metadata, old_target
    finally:
        if not swapped:
            shutil.rmtree(release_path, ignore_errors=True)
        next_link.unlink(missing_ok=True)
        shutil.rmtree(incoming, ignore_errors=True)


@app.errorhandler(413)
def upload_too_large(_error):
    return jsonify({"error": "the uploaded archive exceeds the 1 GiB limit"}), 413


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
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
                quote = value[0]
                value = value[1:-1]
                if quote == '"':
                    value = re.sub(r"\\([\\\"$`])", r"\1", value)
            values[key.strip()] = value
    except OSError:
        pass
    return values


@contextmanager
def _settings_update_lock():
    SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    lock_file = open(SETTINGS.parent / ".settings.lock", "a+", encoding="utf-8")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        yield
    finally:
        lock_file.close()


def _write_settings(updates):
    with _settings_update_lock():
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

        handle, temp_name = tempfile.mkstemp(
            prefix="settings.env.", dir=SETTINGS.parent
        )
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
    _write_secret(SFTP_PASSWORD_FILE, password + "\n")


def _bool_setting(value, fallback=False):
    normalized = str(value or "").lower()
    if normalized in {"true", "yes", "1"}:
        return True
    if normalized in {"false", "no", "0"}:
        return False
    return fallback


def _settings_doc(settings=None):
    settings = settings or _settings()
    return {
        "backupEnabled": _bool_setting(settings.get("BACKUP_ENABLED")),
        "ceip": settings.get("CEIP", "DISABLE"),
        "cronSchedule": settings.get("CRON_SCHEDULE", "0 3 * * 0"),
        "depotEndpoint": settings.get("DEPOT_ENDPOINT", "dl.broadcom.com"),
        "esxMode": settings.get("ESX_MODE", "download"),
        "logRetention": _int_setting(settings.get("LOG_RETENTION"), 20),
        "setupComplete": _bool_setting(settings.get("SETUP_COMPLETE")),
        "sku": settings.get("SKU", "VCF"),
        "storageConfirmed": _bool_setting(settings.get("STORAGE_CONFIRMED")),
        "syncTargets": settings.get(
            "SYNC_TARGETS", "esx install upgrade patches"
        ).split(),
        "tokenUrl": settings.get(
            "TOKEN_URL", "https://eapi.broadcom.com/vcf/generateToken"
        ),
        "timezone": settings.get("TZ", "UTC"),
        "username": settings.get("AUTH_USERNAME", "vcf"),
        "vcfVersion": settings.get("VCF_VERSION", "9.1.0"),
        "uidGid": settings.get("SFTP_UID_GID", "1003:1003"),
        "vkrMatch": settings.get("VKR_MATCH", ""),
        "vkrOs": settings.get("VKR_OS", ""),
    }


def _int_setting(value, fallback):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return fallback


def _activation_configured():
    try:
        return bool(ACTIVATION_CODE_FILE.read_text().strip())
    except OSError:
        return False


_machine_id_cache = {"value": None}


def _machine_id():
    if _machine_id_cache["value"]:
        return _machine_id_cache["value"], None
    tool = VCFDT_STORE / "current" / "bin" / "vcf-download-tool"
    if not tool.is_file():
        return None, "Upload the VCF Download Tool first."
    try:
        result = subprocess.run(
            [tool, "configuration", "get", "--machineId"],
            cwd=tool.parent.parent,
            capture_output=True,
            text=True,
            timeout=90,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None, "The tool could not read its Software Depot ID."
    output = "\n".join(part for part in (result.stdout, result.stderr) if part).strip()
    if result.returncode != 0:
        return None, f"The tool returned exit code {result.returncode} while reading its ID."
    uuid_match = re.search(
        r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
        r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b",
        output,
    )
    if uuid_match:
        _machine_id_cache["value"] = uuid_match.group(0)
        return uuid_match.group(0), None
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    value = lines[-1].split(":", 1)[-1].strip() if lines else ""
    if not value or len(value) > 200 or not re.fullmatch(r"[A-Za-z0-9._:-]+", value):
        return None, "The tool did not return a recognizable Software Depot ID."
    _machine_id_cache["value"] = value
    return value, None


def _storage_entry(path):
    result = {"path": str(path), "mounted": path.is_dir(), "readable": False}
    if not path.is_dir():
        return result
    try:
        usage = shutil.disk_usage(path)
        result.update(
            readable=True,
            freeBytes=usage.free,
            totalBytes=usage.total,
            device=os.stat(path).st_dev,
        )
    except OSError:
        pass
    return result


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


@app.get("/tls/allow")
def allow_tls_name():
    domain = str(request.args.get("domain", ""))
    try:
        ipaddress.ip_address(domain)
        return "", 204
    except ValueError:
        pass
    if len(domain) <= 253 and re.fullmatch(
        r"(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*"
        r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?",
        domain,
    ):
        return "", 204
    return "invalid certificate name", 403


@app.get("/")
def index():
    return render_template("index.html", targets=VALID_TARGETS)


@app.get("/auth/check")
def auth_check():
    credentials = request.authorization
    if credentials and _verify_credentials(credentials.username, credentials.password):
        return "ok", 200
    return "authentication required", 401, {"WWW-Authenticate": 'Basic realm="VCF Services"'}


@app.get("/api/session")
def session_status():
    auth = _auth_doc()
    return jsonify(
        {
            "claimed": auth is not None,
            "authenticated": _is_authenticated(),
            "username": auth.get("username") if auth and _is_authenticated() else None,
        }
    )


@app.post("/api/claim")
def claim():
    body = request.get_json(silent=True) or {}
    username = str(body.get("username", "")).strip()
    password = body.get("password")
    if username != "vcf":
        return jsonify({"error": "the prototype owner username is vcf"}), 400
    if not isinstance(password, str) or len(password) < 12:
        return jsonify({"error": "use a password of at least 12 characters"}), 400
    if len(password) > 1024 or "\n" in password or "\r" in password:
        return jsonify({"error": "the password must be one line and at most 1024 characters"}), 400

    with _credential_update_lock():
        if _auth_doc() is not None:
            return jsonify({"error": "this appliance has already been claimed"}), 409
        password_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
        auth = {
            "username": username,
            "passwordHash": password_hash,
            "claimedAt": datetime.now(timezone.utc).isoformat(),
        }
        try:
            _write_settings({"AUTH_USERNAME": username})
            _replace_shared_credentials(auth, password)
        except OSError:
            return jsonify({"error": "the owner credentials could not be saved"}), 500
    session.clear()
    session["owner"] = username
    return jsonify({"claimed": True, "username": username}), 201


@app.post("/api/login")
def login():
    body = request.get_json(silent=True) or {}
    if not _verify_credentials(str(body.get("username", "")), str(body.get("password", ""))):
        return jsonify({"error": "the username or password is incorrect"}), 401
    session.clear()
    session["owner"] = body["username"]
    return jsonify({"authenticated": True, "username": body["username"]})


@app.post("/api/logout")
def logout():
    session.clear()
    return jsonify({"authenticated": False})


@app.get("/api/bootstrap")
def bootstrap_status():
    auth = _auth_doc()
    settings = _settings_doc()
    if auth and not _is_authenticated():
        return jsonify(
            {
                "claimed": True,
                "authenticated": False,
                "setupComplete": settings["setupComplete"],
            }
        )
    tool = _current_tool_info()
    machine_id, machine_error = (None, None)
    if tool["installed"]:
        machine_id, machine_error = _machine_id()
    return jsonify(
        {
            "claimed": auth is not None,
            "authenticated": _is_authenticated(),
            "setupComplete": settings["setupComplete"],
            "tool": tool,
            "machineId": machine_id,
            "machineIdError": machine_error,
            "activationConfigured": _activation_configured(),
            "storage": {
                "confirmed": settings["storageConfirmed"],
                "depot": _storage_entry(DEPOT),
                "backup": _storage_entry(BACKUP),
            },
            "settings": settings,
        }
    )


@app.get("/api/tls/ca")
def download_tls_ca():
    if not CADDY_CA_FILE.is_file():
        return jsonify({"error": "the first-boot CA is not available yet"}), 404
    return send_file(
        CADDY_CA_FILE,
        as_attachment=True,
        download_name="vcf-services-root-ca.crt",
        mimetype="application/x-x509-ca-cert",
    )


@app.get("/api/status")
def status():
    state = _state()
    settings = _settings()
    tool_info = _current_tool_info()
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
    armed = _activation_configured()
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
            "vcfdtInstalled": tool_info["installed"],
            "vcfdtVersion": tool_info["version"],
            "vcfdtUploadedAt": tool_info.get("uploadedAt"),
        }
    )


@app.get("/api/vcfdt")
def vcfdt_status():
    return jsonify(_current_tool_info())


@app.post("/api/vcfdt")
def upload_vcfdt():
    upload = request.files.get("archive")
    if upload is None or not upload.filename:
        return jsonify({"error": "choose a VCF Download Tool archive"}), 400
    try:
        with _tool_update_lock():
            if _state().get("running", False):
                return jsonify({"error": "wait for the running sync to finish"}), 409
            metadata, old_target = _install_tool(upload)
            if old_target and old_target.parent == (VCFDT_STORE / "releases").resolve():
                shutil.rmtree(old_target, ignore_errors=True)
    except BlockingIOError:
        return jsonify({"error": "wait for the running sync or tool update to finish"}), 409
    except ToolArchiveError as exc:
        return jsonify({"error": str(exc)}), 400
    except OSError:
        return jsonify({"error": "the tool could not be saved to its mounted volume"}), 500
    return jsonify({"installed": True, **metadata}), 201


@app.get("/api/registration")
def registration_status():
    machine_id, error = _machine_id()
    status_code = 200 if machine_id else 409
    return (
        jsonify(
            {
                "machineId": machine_id,
                "error": error,
                "activationConfigured": _activation_configured(),
                "instructions": ARMING_INSTRUCTIONS,
            }
        ),
        status_code,
    )


@app.post("/api/registration")
def save_registration():
    body = request.get_json(silent=True) or {}
    activation_code = body.get("activationCode")
    if _state().get("running", False):
        return jsonify({"error": "wait for the running sync to finish"}), 409
    machine_id, machine_error = _machine_id()
    if not machine_id:
        return jsonify({"error": machine_error}), 409
    if not isinstance(activation_code, str) or not activation_code.strip():
        return jsonify({"error": "enter the activation code from Broadcom"}), 400
    activation_code = activation_code.strip()
    if len(activation_code) > 4096 or "\n" in activation_code or "\r" in activation_code:
        return jsonify({"error": "the activation code must be one line"}), 400
    try:
        _write_secret(ACTIVATION_CODE_FILE, activation_code + "\n")
    except OSError:
        return jsonify({"error": "the activation code could not be saved"}), 500
    return jsonify({"saved": True, "machineId": machine_id})


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


@app.get("/api/settings")
def settings():
    return jsonify(_settings_doc())


@app.post("/api/settings")
def update_settings():
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        return jsonify({"error": "a JSON settings document is required"}), 400
    vcf_version = str(body.get("vcfVersion", "")).strip()
    if not re.fullmatch(r"[0-9][0-9A-Za-z.*_-]*(\.\.)?", vcf_version):
        return jsonify({"error": "the VCF version filter is invalid"}), 400
    sku = str(body.get("sku", ""))
    if sku not in {"VCF", "VVF"}:
        return jsonify({"error": "SKU must be VCF or VVF"}), 400
    targets = body.get("syncTargets")
    if not isinstance(targets, list) or not targets:
        return jsonify({"error": "select at least one sync target"}), 400
    if any(target not in VALID_TARGETS for target in targets) or len(set(targets)) != len(targets):
        return jsonify({"error": "the sync target selection is invalid"}), 400
    cron = str(body.get("cronSchedule", "")).strip()
    if len(cron.split()) != 5 or not re.fullmatch(r"[0-9*/ ,\-]+", cron):
        return jsonify({"error": "the schedule must use five cron fields"}), 400
    try:
        croniter(cron, datetime.now(timezone.utc)).get_next(datetime)
    except (KeyError, ValueError):
        return jsonify({"error": "the sync schedule is invalid"}), 400
    timezone_name = str(body.get("timezone", "")).strip()
    try:
        ZoneInfo(timezone_name)
    except (KeyError, ValueError):
        return jsonify({"error": "choose a valid IANA timezone"}), 400
    ceip = str(body.get("ceip", ""))
    if ceip not in {"DISABLE", "ENABLE"}:
        return jsonify({"error": "CEIP must be explicitly enabled or disabled"}), 400
    depot_endpoint = str(body.get("depotEndpoint", "")).strip().lower()
    if not re.fullmatch(r"[A-Za-z0-9.-]+", depot_endpoint) or ".." in depot_endpoint:
        return jsonify({"error": "the download endpoint hostname is invalid"}), 400
    token_url = str(body.get("tokenUrl", "")).strip()
    if not re.fullmatch(r"https://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+", token_url):
        return jsonify({"error": "the token URL must be a valid HTTPS URL"}), 400
    backup_enabled = body.get("backupEnabled")
    storage_confirmed = body.get("storageConfirmed")
    if not isinstance(backup_enabled, bool) or not isinstance(storage_confirmed, bool):
        return jsonify({"error": "storage and backup selections must be true or false"}), 400
    uid_gid = str(body.get("uidGid", ""))
    match = re.fullmatch(r"([0-9]+):([0-9]+)", uid_gid)
    if not match or any(not 1 <= int(value) <= 2147483647 for value in match.groups()):
        return jsonify({"error": "UID:GID must contain two non-root numeric values"}), 400
    esx_mode = str(body.get("esxMode", ""))
    if esx_mode not in {"download", "metadata"}:
        return jsonify({"error": "ESX mode must be download or metadata"}), 400
    log_retention = body.get("logRetention")
    if isinstance(log_retention, bool) or not str(log_retention).isdigit():
        return jsonify({"error": "log retention must be a whole number"}), 400
    log_retention = int(log_retention)
    if not 1 <= log_retention <= 1000:
        return jsonify({"error": "log retention must be from 1 through 1000"}), 400
    vkr_match = str(body.get("vkrMatch", "")).strip()
    vkr_os = str(body.get("vkrOs", "")).strip()
    if len(vkr_match) > 200 or len(vkr_os) > 100 or any(
        "\n" in value or "\r" in value for value in (vkr_match, vkr_os)
    ):
        return jsonify({"error": "VKr filters must be short single-line values"}), 400
    updates = {
        "BACKUP_ENABLED": str(backup_enabled).lower(),
        "CEIP": ceip,
        "CRON_SCHEDULE": cron,
        "DEPOT_ENDPOINT": depot_endpoint,
        "ESX_MODE": esx_mode,
        "LOG_RETENTION": str(log_retention),
        "SKU": sku,
        "SFTP_UID_GID": uid_gid,
        "STORAGE_CONFIRMED": str(storage_confirmed).lower(),
        "SYNC_TARGETS": " ".join(targets),
        "TOKEN_URL": token_url,
        "TZ": timezone_name,
        "VCF_VERSION": vcf_version,
        "VKR_MATCH": vkr_match,
        "VKR_OS": vkr_os,
    }
    if _state().get("running", False) and any(
        _settings().get(key) != value for key, value in updates.items()
    ):
        return jsonify({"error": "wait for the running sync to finish before changing settings"}), 409
    try:
        with _tool_update_lock():
            if _state().get("running", False):
                return jsonify({"error": "wait for the running sync to finish before changing settings"}), 409
            _write_settings(updates)
            current = VCFDT_STORE / "current"
            if current.is_dir():
                _patch_tool_endpoints(current)
    except BlockingIOError:
        return jsonify({"error": "wait for the running sync or tool update to finish"}), 409
    except OSError as exc:
        return jsonify({"error": f"could not save settings: {exc}"}), 500
    return jsonify({**_settings_doc(), "saved": True})


@app.post("/api/password")
def update_password():
    body = request.get_json(silent=True) or {}
    current = str(body.get("currentPassword", ""))
    new = body.get("newPassword")
    if not isinstance(new, str) or len(new) < 12:
        return jsonify({"error": "use a new password of at least 12 characters"}), 400
    if len(new) > 1024 or "\n" in new or "\r" in new:
        return jsonify({"error": "the password must be one line and at most 1024 characters"}), 400
    with _credential_update_lock():
        auth = _auth_doc()
        if not auth or not _verify_credentials(auth["username"], current):
            return jsonify({"error": "the current password is incorrect"}), 403
        updated = {
            **auth,
            "passwordHash": bcrypt.hashpw(new.encode(), bcrypt.gensalt()).decode(),
            "changedAt": datetime.now(timezone.utc).isoformat(),
        }
        try:
            _replace_shared_credentials(updated, new)
        except OSError:
            return jsonify({"error": "the shared password could not be saved"}), 500
    return jsonify({"saved": True, "consumerUpdateRequired": True})


@app.post("/api/setup/complete")
def complete_setup():
    settings_doc = _settings_doc()
    missing = []
    if not _current_tool_info()["installed"]:
        missing.append("licensed tool")
    machine_id, _error = _machine_id()
    if not machine_id:
        missing.append("Software Depot ID")
    if not _activation_configured():
        missing.append("activation code")
    if not settings_doc["storageConfirmed"]:
        missing.append("storage confirmation")
    if missing:
        return jsonify({"error": "finish setup first: " + ", ".join(missing)}), 409
    try:
        _write_settings({"SETUP_COMPLETE": "true"})
    except OSError:
        return jsonify({"error": "setup completion could not be saved"}), 500
    return jsonify({"setupComplete": True})


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
    if not _activation_configured():
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
