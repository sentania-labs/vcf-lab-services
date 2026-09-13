#!/usr/bin/env python3
"""VCF Services admin console.

Depot ownership and explorer rules are documented in README.md under
"Operator-provided depot content". This app reads config and state files
and exchanges jobs with the sync service over the
password-protected Redis bus documented in docs/redis-contract.md. It never
talks to the Docker daemon.
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
import threading
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
VERSION_MARKER_FILE = Path(
    os.environ.get("VERSION_MARKER_FILE", "/config/.vcf-services-version")
)
VERSION_STATUS_FILE = Path(
    os.environ.get("VERSION_STATUS_FILE", "/config/.vcf-services-version-status.json")
)
MIGRATION_STATUS_FILE = Path(
    os.environ.get("MIGRATION_STATUS_FILE", "/config/.vcf-services-migration.json")
)
SOFTWARE_DEPOT_ID_FILE = Path(
    os.environ.get("SOFTWARE_DEPOT_ID_FILE", "/config/software-depot-id")
)
SOFTWARE_DEPOT_ADOPTION_FILE = Path(
    os.environ.get(
        "SOFTWARE_DEPOT_ADOPTION_FILE", "/config/.software-depot-id-adoption.json"
    )
)
VCFDT_STATE_DIR = Path(
    os.environ.get(
        "VCFDT_STATE_DIR", str(Path.home() / ".local" / "share" / "vmware" / "vdt")
    )
)
VCFDT_MACHINE_ID_FILE = VCFDT_STATE_DIR / "machine_id"
SETTINGS_PENDING_FILE = Path(
    os.environ.get("SETTINGS_PENDING_FILE", "/config/.settings-pending.json")
)
# sync.sh holds this lock for the whole run and takes it before it reads
# settings.env, so holding it around a save tells us whether the in-flight run
# read the old values or will read the new ones. See the settings section of
# README.md.
SYNC_SNAPSHOT_LOCK = Path(
    os.environ.get("SYNC_SNAPSHOT_LOCK", str(STATE / "settings-snapshot.lock"))
)
# sync.sh writes this file before it takes the snapshot lock, so an identity
# read here is never older than the lock state observed with it. It names the
# run a pending save belongs to, including in the moment before the run has
# published its running state.
SYNC_SNAPSHOT_RUN_FILE = Path(
    os.environ.get("SYNC_SNAPSHOT_RUN_FILE", str(STATE / "settings-snapshot.run"))
)
DEPOT_OWNERSHIP_FILE = Path(
    os.environ.get("DEPOT_OWNERSHIP_FILE", str(STATE / "depot-ownership.json"))
)
DEPOT_OWNERSHIP_LOCK = Path(
    os.environ.get("DEPOT_OWNERSHIP_LOCK", str(STATE / "depot-ownership.lock"))
)
CURRENT_VERSION = os.environ.get("VCF_SERVICES_VERSION", "dev")
VCFDT_STORE = Path(os.environ.get("VCFDT_STORE", "/opt/vcfdt"))
SECRETS_ROOT = "/etc/vcf-services/secrets"
AUTH_FILE = Path(os.environ.get("AUTH_FILE", f"{SECRETS_ROOT}/auth.json"))
ACTIVATION_CODE_FILE = Path(
    os.environ.get("ACTIVATION_CODE_FILE", f"{SECRETS_ROOT}/activation-code.txt")
)
SFTP_PASSWORD_FILE = Path(
    os.environ.get("SFTP_PASSWORD_FILE", f"{SECRETS_ROOT}/sftp-password")
)
FLASK_SECRET_FILE = Path(
    os.environ.get("FLASK_SECRET_FILE", f"{SECRETS_ROOT}/flask-secret")
)
CADDY_CA_FILE = Path(
    os.environ.get("CADDY_CA_FILE", "/caddy-data/caddy/pki/authorities/local/root.crt")
)
REDIS_HOST = os.environ.get("REDIS_HOST", "redis")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))
REDIS_PASSWORD_FILE = os.environ.get(
    "REDIS_PASSWORD_FILE", f"{SECRETS_ROOT}/redis-password"
)
REQUEST_QUEUE = "vcf-services:sync:requests"
STATUS_KEY = "vcf-services:sync:status"
LOG_KEY = "vcf-services:sync:log"
VERSIONS_KEY = "vcf-services:sync:versions"
VALID_TARGETS = ["esx", "install", "upgrade", "patches", "vkr"]
# settings.env keys the console owns, paired with their JSON field names.
SETTING_ENV_FIELDS = {
    "BACKUP_ENABLED": "backupEnabled",
    "CEIP": "ceip",
    "CRON_SCHEDULE": "cronSchedule",
    "DEPOT_ENDPOINT": "depotEndpoint",
    "ESX_MODE": "esxMode",
    "LOG_RETENTION": "logRetention",
    "SFTP_UID_GID": "uidGid",
    "SKU": "sku",
    "STORAGE_CONFIRMED": "storageConfirmed",
    "SYNC_DIAGNOSTICS": "syncDiagnostics",
    "SYNC_TARGETS": "syncTargets",
    "TOKEN_URL": "tokenUrl",
    "TZ": "timezone",
    "VCF_VERSION": "vcfVersion",
    "VKR_MATCH": "vkrMatch",
    "VKR_OS": "vkrOs",
}
# The download tool re-reads its own properties file while a run is in flight,
# so these two are the only settings a running sync can still observe. Every
# other setting is snapshotted by sync.sh when the run starts.
LIVE_TOOL_FIELDS = {"depotEndpoint", "tokenUrl"}
# The SFTP backup service re-reads these every few seconds, so a save takes
# effect at once and must never be reported as waiting for the next run.
LIVE_SERVICE_FIELDS = {"backupEnabled", "uidGid"}
BUILD_RE = re.compile(r"\b(2[0-9]{7})\b")
TOOL_VERSION_VALUE = r"v?[0-9]+(?:\.[0-9]+)+(?:[-+][0-9A-Za-z][0-9A-Za-z._-]*)?"
TOOL_VERSION_RE = re.compile(rf"^{TOOL_VERSION_VALUE}$", re.IGNORECASE)
TOOL_VERSION_LABEL_RE = re.compile(
    rf"^Version\s*:\s*(?P<version>{TOOL_VERSION_VALUE})$", re.IGNORECASE
)
SOFTWARE_DEPOT_ID_RE = re.compile(
    r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
)
# The sync tool mirrors its own distribution archives into this depot tree.
# The tree is flat: PROD/COMP/VCFDT/vcf-download-tool-<version>.tar.gz with no
# version subdirectories, and the listing and resolver accept only that layout.
DEPOT_TOOL_DIR = DEPOT / "PROD" / "COMP" / "VCFDT"
DEPOT_TOOL_ARCHIVE_RE = re.compile(
    rf"^vcf-download-tool-(?P<version>{TOOL_VERSION_VALUE})\.(?:tar\.gz|tgz|zip)$",
    re.IGNORECASE,
)
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


class DepotError(ValueError):
    """A depot explorer request failed a safety check."""


OWNERSHIP_VALUES = {"product-managed", "operator-provided", "unknown"}


@contextmanager
def _ownership_lock():
    DEPOT_OWNERSHIP_LOCK.parent.mkdir(parents=True, exist_ok=True)
    lock_file = open(DEPOT_OWNERSHIP_LOCK, "a+", encoding="utf-8")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        yield
    finally:
        lock_file.close()


def _read_ownership_manifest():
    try:
        document = json.loads(DEPOT_OWNERSHIP_FILE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        try:
            DEPOT_OWNERSHIP_FILE.lstat()
        except FileNotFoundError:
            return {"version": 1, "trees": {}}
        raise
    except (ValueError, UnicodeError) as exc:
        raise OSError("the depot ownership manifest is invalid") from exc
    if (
        not isinstance(document, dict)
        or type(document.get("version")) is not int
        or document["version"] != 1
        or not isinstance(document.get("trees"), dict)
    ):
        raise OSError("the depot ownership manifest schema is invalid")
    for name, entry in document["trees"].items():
        if (
            not name
            or name in {".", ".."}
            or "/" in name
            or "\\" in name
            or "\x00" in name
            or not isinstance(entry, dict)
            or not isinstance(entry.get("ownership"), str)
            or entry["ownership"] not in OWNERSHIP_VALUES
            or not isinstance(entry.get("protected"), bool)
        ):
            raise OSError("the depot ownership manifest tree entry is invalid")
    return document


def _write_ownership_manifest(document):
    DEPOT_OWNERSHIP_FILE.parent.mkdir(parents=True, exist_ok=True)
    handle, temp_name = tempfile.mkstemp(
        prefix=f".{DEPOT_OWNERSHIP_FILE.name}.", dir=DEPOT_OWNERSHIP_FILE.parent
    )
    try:
        os.fchmod(handle, 0o600)
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(document, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, DEPOT_OWNERSHIP_FILE)
    except Exception:
        try:
            os.close(handle)
        except OSError:
            pass
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


def _content_library_item_count(path):
    try:
        document = json.loads((path / "items.json").read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return None
    if isinstance(document, list):
        return len(document)
    if isinstance(document, dict):
        items = document.get("items")
        if isinstance(items, (list, dict)):
            return len(items)
        return len(document)
    return None


def _tree_usage(path):
    size_bytes = 0
    file_count = 0
    try:
        for root, dirs, files in os.walk(path, followlinks=False):
            root_path = Path(root)
            dirs[:] = [name for name in dirs if not (root_path / name).is_symlink()]
            for name in files:
                candidate = root_path / name
                try:
                    if candidate.is_symlink():
                        continue
                    size_bytes += candidate.stat().st_size
                    file_count += 1
                except OSError:
                    continue
    except OSError:
        pass
    return size_bytes, file_count


def _depot_comp_directories():
    root = DEPOT / "PROD" / "COMP"
    try:
        return sorted(
            path for path in root.iterdir() if path.is_dir() and not path.is_symlink()
        )
    except OSError:
        return []


def _ensure_ownership_manifest(directories=None):
    directories = _depot_comp_directories() if directories is None else directories
    changed = False
    with _ownership_lock():
        manifest = _read_ownership_manifest()
        entries = manifest["trees"]
        for path in directories:
            content_library = (path / "items.json").is_file() and (
                path / "lib.json"
            ).is_file()
            entry = entries.get(path.name)
            if entry is None:
                ownership = "operator-provided" if content_library else "unknown"
                entries[path.name] = {
                    "ownership": ownership,
                    "protected": ownership == "operator-provided",
                }
                changed = True
        if changed:
            _write_ownership_manifest(manifest)
    return manifest


def _depot_ownership_inventory():
    with _depot_discovery_guard():
        directories = _depot_comp_directories()
        manifest = _ensure_ownership_manifest(directories)
    rows = []
    for path in directories:
        content_library = (path / "items.json").is_file() and (
            path / "lib.json"
        ).is_file()
        item_count = _content_library_item_count(path) if content_library else None
        entry = manifest["trees"][path.name]
        size_bytes, file_count = _tree_usage(path)
        rows.append(
            {
                "name": path.name,
                "path": f"PROD/COMP/{path.name}",
                "sizeBytes": size_bytes,
                "fileCount": file_count,
                "itemCount": item_count,
                "contentLibrary": content_library,
                **entry,
            }
        )
    return rows


def _depot_relative_path(value, *, allow_root=True, must_exist=False):
    if not isinstance(value, str) or "\x00" in value or "\\" in value:
        raise DepotError("the depot path is invalid")
    normalized = value.strip("/")
    if value.startswith("/"):
        raise DepotError("absolute paths are not allowed")
    if not normalized:
        if not allow_root:
            raise DepotError("choose an entry below the depot root")
        parts = ()
    else:
        relative = PurePosixPath(normalized)
        if relative.is_absolute() or any(
            part in {"", ".", ".."} for part in relative.parts
        ):
            raise DepotError("the depot path must stay below the depot root")
        parts = relative.parts
    try:
        resolved_root = DEPOT.resolve(strict=True)
    except OSError as exc:
        raise DepotError("the depot root is not available") from exc
    candidate = DEPOT.joinpath(*parts)
    cursor = DEPOT
    for part in parts:
        cursor /= part
        if cursor.is_symlink() and not cursor.is_dir():
            raise DepotError("only directory links can be used through the depot explorer")
    try:
        resolved = candidate.resolve(strict=must_exist)
    except (OSError, RuntimeError) as exc:
        raise DepotError("the depot path does not exist") from exc
    if resolved != resolved_root and not resolved.is_relative_to(resolved_root):
        raise DepotError("the depot path escapes the depot root")
    return candidate, "/".join(parts)


def _entry_usage(path):
    if path.is_symlink():
        try:
            return path.lstat().st_size, 1
        except OSError:
            return 0, 0
    if path.is_file():
        try:
            return path.stat().st_size, 1
        except OSError:
            return 0, 0
    return _tree_usage(path)


def _protected_trees_for_path(
    relative, *, include_descendants=False, ownership_manifest=None
):
    path, _ = _depot_relative_path(relative)
    requested = path.resolve().relative_to(DEPOT.resolve()).parts
    manifest = (
        ownership_manifest
        if ownership_manifest is not None
        else _ensure_ownership_manifest()
    )
    matches = []
    for name, entry in manifest["trees"].items():
        if not entry.get("protected"):
            continue
        protected = ("PROD", "COMP", name)
        inside = len(requested) >= len(protected) and requested[: len(protected)] == protected
        contains = len(requested) < len(protected) and protected[: len(requested)] == requested
        if inside or (include_descendants and contains):
            matches.append(name)
    return sorted(matches)


def _top_level_comp_trees():
    root = DEPOT / "PROD" / "COMP"
    try:
        return {
            path.name
            for path in root.iterdir()
            if path.is_dir() and not path.is_symlink()
        }
    except OSError:
        return set()


def _record_operator_trees(names):
    if not names:
        return
    with _ownership_lock():
        manifest = _read_ownership_manifest()
        changed = False
        for name in names:
            if name not in manifest["trees"]:
                manifest["trees"][name] = {
                    "ownership": "operator-provided",
                    "protected": True,
                }
                changed = True
        if changed:
            _write_ownership_manifest(manifest)


def _forget_deleted_trees(relative):
    requested = tuple(PurePosixPath(relative).parts)
    with _ownership_lock():
        manifest = _read_ownership_manifest()
        removed = []
        for name in list(manifest["trees"]):
            tree = ("PROD", "COMP", name)
            common = min(len(requested), len(tree))
            if requested[:common] == tree[:common] and len(requested) <= len(tree):
                removed.append(name)
                del manifest["trees"][name]
        if removed:
            _write_ownership_manifest(manifest)


@contextmanager
def _depot_discovery_guard():
    STATE.mkdir(parents=True, exist_ok=True)
    sync_lock = open(STATE / "sync.lock", "a+", encoding="utf-8")
    try:
        fcntl.flock(sync_lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        yield
    finally:
        sync_lock.close()


@contextmanager
def _depot_mutation_guard():
    STATE.mkdir(parents=True, exist_ok=True)
    sync_lock = open(STATE / "sync.lock", "a+", encoding="utf-8")
    try:
        fcntl.flock(sync_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with _tool_update_lock():
            yield
    finally:
        sync_lock.close()


def _is_licensed_tool_name(name):
    return "vcf-download-tool" in name.lower()


def _validate_depot_staging(staging):
    for root, dirs, files in os.walk(staging, followlinks=False):
        root_path = Path(root)
        for name in dirs + files:
            path = root_path / name
            if path.is_symlink():
                raise DepotError("archives containing symbolic links are not accepted")
            if _is_licensed_tool_name(name):
                raise DepotError(
                    "licensed VCF Download Tool archives must use the Setup tab"
                )


def _paths_publicly_exposed(relatives, *, include_ancestors=False):
    try:
        public_root, _ = _depot_relative_path("umds-patch-store", must_exist=True)
    except DepotError:
        return False
    public_root = public_root.resolve()
    for relative in relatives:
        path, _ = _depot_relative_path(relative, must_exist=True)
        resolved = path.resolve()
        if resolved.is_relative_to(public_root) or (
            include_ancestors and path.is_dir() and public_root.is_relative_to(resolved)
        ):
            return True
    return False


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
    lock_path = AUTH_FILE.parent / ".credentials.lock"
    lock_handle = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    os.fchmod(lock_handle, 0o600)
    lock_file = os.fdopen(lock_handle, "a+", encoding="utf-8")
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
    version_problem = _version_problem()
    if request.path in public_paths:
        if version_problem and request.path in {"/auth/check", "/api/claim"}:
            return jsonify({"error": version_problem["message"]}), 503
        return None
    if _auth_doc() is None:
        return jsonify({"error": "claim this appliance before continuing"}), 403
    if not _is_authenticated():
        return jsonify({"error": "sign in to continue"}), 401
    allowed_during_version_block = {
        "/api/bootstrap",
        "/api/log",
        "/api/logout",
        "/api/status",
        "/api/tls/ca",
    }
    if version_problem and request.path not in allowed_during_version_block:
        return jsonify({"error": version_problem["message"]}), 409
    return None


def _version_problem():
    try:
        status = json.loads(VERSION_STATUS_FILE.read_text(encoding="utf-8"))
        if status.get("blocked") and status.get("message"):
            return status
    except (OSError, ValueError, TypeError):
        pass
    if CURRENT_VERSION == "dev":
        return None
    try:
        found = VERSION_MARKER_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        found = ""
    if found == CURRENT_VERSION:
        return None
    found_label = found or "unversioned state"
    return {
        "blocked": True,
        "expectedVersion": CURRENT_VERSION,
        "foundVersion": found or None,
        "message": (
            f"Startup is blocked because the config volume contains {found_label}, "
            f"but this appliance is {CURRENT_VERSION}. Stop the stack, preserve any "
            "data you need, then start with a matching new or restored config volume."
        ),
    }


def _migration_status():
    try:
        status = json.loads(MIGRATION_STATUS_FILE.read_text(encoding="utf-8"))
        if status.get("status") and status.get("migratedAt"):
            return status
    except (OSError, ValueError, TypeError):
        pass
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
                if not (
                    member.isfile()
                    or member.isdir()
                    or member.issym()
                    or member.islnk()
                ):
                    raise ToolArchiveError(
                        "the archive contains an unsupported file type"
                    )
                if member.issym() or member.islnk():
                    _safe_archive_path(member.linkname)
                extracted_bytes += max(member.size, 0)
                if extracted_bytes > MAX_EXTRACTED_BYTES:
                    raise ToolArchiveError("the expanded archive is too large")
            archive.extractall(destination, members=members, filter="data")
    except (tarfile.TarError, OSError) as exc:
        raise ToolArchiveError("the archive is not a readable tar.gz archive") from exc


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
                    raise ToolArchiveError(
                        "the archive contains an unsupported symbolic link"
                    )
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
        raise ToolArchiveError("the archive is not a readable zip archive") from exc


def _archive_kind(filename):
    lowered = filename.lower()
    if lowered.endswith((".tar.gz", ".tgz")):
        return "tar"
    if lowered.endswith(".zip"):
        return "zip"
    raise ToolArchiveError("choose a .tar.gz, .tgz, or .zip VCF Download Tool archive")


@contextmanager
def _patch_tool_endpoints(tool_root, settings=None):
    settings = _settings() if settings is None else settings
    replacements = {
        "lcm.depot.adapter.host": settings.get("DEPOT_ENDPOINT", "dl.broadcom.com"),
        "lcm.access_token.broadcom.authorization.server.url": settings.get(
            "TOKEN_URL", "https://eapi.broadcom.com/vcf/generateToken"
        ),
    }
    found_any = False
    changed = []
    conf_dir = tool_root / "conf"
    candidates = sorted(
        path
        for path in conf_dir.glob("application-prod*.properties")
        if path.is_file() and not path.is_symlink()
    )
    backups = []
    replaced = []
    try:
        for properties in candidates:
            original = properties.read_text()
            updated = []
            found_here = False
            for line in original.splitlines():
                key = line.split("=", 1)[0].strip()
                if key in replacements:
                    updated.append(f"{key}={replacements[key]}")
                    found_here = True
                    found_any = True
                else:
                    updated.append(line)
            if not found_here:
                continue
            updated_text = "\n".join(updated) + "\n"
            if updated_text == original:
                continue
            backup_handle, backup_name = tempfile.mkstemp(
                prefix=f".{properties.name}.rollback.", dir=properties.parent
            )
            os.close(backup_handle)
            backups.append(backup_name)
            shutil.copy2(properties, backup_name)
            mode = properties.stat().st_mode & 0o777
            handle, temp_name = tempfile.mkstemp(
                prefix=f".{properties.name}.", dir=properties.parent
            )
            try:
                os.fchmod(handle, mode)
                with os.fdopen(handle, "w", encoding="utf-8") as stream:
                    stream.write(updated_text)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temp_name, properties)
                replaced.append((properties, backup_name))
            except Exception:
                try:
                    os.close(handle)
                except OSError:
                    pass
                try:
                    os.unlink(temp_name)
                except OSError:
                    pass
                raise
            changed.append(str(properties.relative_to(tool_root)))
        if not found_any:
            raise ToolArchiveError(
                "no VCF Download Tool endpoint keys were found in conf/application-prod*.properties"
            )
        yield changed
    except Exception:
        for properties, backup_name in reversed(replaced):
            os.replace(backup_name, properties)
        raise
    finally:
        for backup_name in backups:
            Path(backup_name).unlink(missing_ok=True)


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
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    for line in lines:
        if len(line) > 120:
            continue
        match = TOOL_VERSION_LABEL_RE.fullmatch(line)
        if match is not None:
            return match.group("version")
    for line in lines:
        if len(line) <= 120 and TOOL_VERSION_RE.fullmatch(line) is not None:
            return line
    return None


def _probe_machine_id(tool_root):
    tool = tool_root / "bin" / "vcf-download-tool"
    try:
        result = subprocess.run(
            [tool, "configuration", "get", "--machineId"],
            cwd=tool_root,
            capture_output=True,
            text=True,
            timeout=90,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ToolArchiveError(
            "bin/vcf-download-tool could not read a Software Depot ID"
        ) from exc
    output = "\n".join(part for part in (result.stdout, result.stderr) if part).strip()
    match = SOFTWARE_DEPOT_ID_RE.search(output)
    if result.returncode != 0 or match is None:
        raise ToolArchiveError(
            "bin/vcf-download-tool did not return a recognizable Software Depot ID"
        )
    return match.group(0)


def _release_tool_info(link_name):
    release = VCFDT_STORE / link_name
    tool = release / "bin" / "vcf-download-tool"
    if (
        not release.is_dir()
        or not tool.is_file()
        or tool.is_symlink()
        or tool.stat().st_size == 0
    ):
        return {"installed": False, "version": "not installed"}
    metadata = {}
    try:
        metadata = json.loads((release / ".vcf-services.json").read_text())
    except (OSError, ValueError):
        pass
    return {
        "installed": True,
        "releaseId": metadata.get("releaseId"),
        "version": metadata.get("version", "unknown"),
        "versionVerified": bool(metadata.get("versionVerified", "version" in metadata)),
        "uploadedAt": metadata.get("uploadedAt"),
        "source": metadata.get("source", "upload"),
        "sourceFile": metadata.get("sourceFile"),
        **_recorded_identity(metadata),
    }


def _recorded_identity(metadata):
    """Read the identity probe outcome a release's metadata recorded.

    A release written before the console recorded probes, or by hand, has
    no outcome and reads as unverified; a recorded outcome without a valid
    ID means the probe ran and failed.
    """
    probed = bool(metadata.get("machineIdProbed", False))
    machine_id = metadata.get("machineId")
    if not isinstance(machine_id, str) or SOFTWARE_DEPOT_ID_RE.fullmatch(machine_id) is None:
        machine_id = None
    probed_at = metadata.get("machineIdProbedAt")
    return {
        "machineId": machine_id if probed else None,
        "machineIdProbed": probed,
        "machineIdProbedAt": probed_at if probed and isinstance(probed_at, str) else None,
    }


def _identity_changed_since(probed_at):
    """True when the tool's identity file was written after the recorded probe."""
    try:
        changed_at = VCFDT_MACHINE_ID_FILE.stat().st_mtime
    except OSError:
        return False
    try:
        recorded_at = datetime.fromisoformat(probed_at).timestamp()
    except (TypeError, ValueError):
        return True
    return changed_at > recorded_at


def _identity_record(machine_id):
    return {
        "machineId": machine_id,
        "machineIdProbed": True,
        "machineIdProbedAt": datetime.now(timezone.utc).isoformat(),
    }


def _record_release_identity(release_root, machine_id):
    """Store a probe outcome in the release metadata that bootstrap reads."""
    metadata_path = release_root / ".vcf-services.json"
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        metadata = {}
    if not isinstance(metadata, dict):
        metadata = {}
    metadata.update(_identity_record(machine_id))
    handle, temp_name = tempfile.mkstemp(prefix=".vcf-services.json.", dir=release_root)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(json.dumps(metadata) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, metadata_path)
    except Exception:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


def _current_tool_info():
    current = _release_tool_info("current")
    previous = _release_tool_info("previous")
    current["previous"] = previous if previous["installed"] else None
    return current


def _release_target(link_name):
    link = VCFDT_STORE / link_name
    if not link.is_symlink():
        return None
    target = (VCFDT_STORE / os.readlink(link)).resolve()
    releases = (VCFDT_STORE / "releases").resolve()
    if target.parent != releases:
        return None
    return target


@contextmanager
def _tool_update_lock():
    VCFDT_STORE.mkdir(parents=True, exist_ok=True)
    lock_file = open(VCFDT_STORE / ".update.lock", "a+", encoding="utf-8")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        lock_file.close()


def _install_tool_archive(archive_path, filename, source):
    """Stage one validated archive as the new current release.

    The archive is read in place. An upload has already been saved under the
    tool store, and a depot archive is opened in place. Installation does not
    change that archive or write other depot content.
    """
    archive_kind = _archive_kind(filename)
    release_id = uuid.uuid4().hex
    incoming = VCFDT_STORE / ".incoming" / release_id
    extracted = incoming / "extracted"
    releases = VCFDT_STORE / "releases"
    release_path = releases / release_id
    next_link = VCFDT_STORE / f".current-{release_id}"
    incoming.mkdir(parents=True)
    extracted.mkdir()
    releases.mkdir(exist_ok=True)
    old_target = None
    swapped = False
    try:
        if archive_path.stat().st_size == 0:
            raise ToolArchiveError("the archive is empty")
        if archive_kind == "tar":
            _extract_tar(archive_path, extracted)
        else:
            _extract_zip(archive_path, extracted)
        tool_root = _find_tool_root(extracted)
        with _patch_tool_endpoints(tool_root) as patched_files:
            pass
        version = _probe_tool_version(tool_root)
        metadata = {
            "releaseId": release_id,
            "version": version if version else "unverified",
            "versionVerified": version is not None,
            "uploadedAt": datetime.now(timezone.utc).isoformat(),
            "source": source,
            "sourceFile": filename,
            "patchedFiles": patched_files,
        }
        try:
            machine_id = _probe_machine_id(tool_root)
        except ToolArchiveError:
            machine_id = None
        metadata.update(_identity_record(machine_id))
        (tool_root / ".vcf-services.json").write_text(json.dumps(metadata) + "\n")
        os.replace(tool_root, release_path)

        current = VCFDT_STORE / "current"
        old_target = _release_target("current")
        next_link.symlink_to(Path("releases") / release_id)
        os.replace(next_link, current)
        swapped = True
        return metadata, old_target, machine_id
    finally:
        if not swapped:
            shutil.rmtree(release_path, ignore_errors=True)
        next_link.unlink(missing_ok=True)
        shutil.rmtree(incoming, ignore_errors=True)


def _install_tool(upload):
    filename = Path(str(upload.filename or "").replace("\\", "/")).name
    _archive_kind(filename)
    staging = VCFDT_STORE / ".incoming" / f"upload-{uuid.uuid4().hex}"
    staging.mkdir(parents=True)
    try:
        archive_path = staging / "upload"
        upload.save(archive_path)
        return _install_tool_archive(archive_path, filename, "upload")
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def _archive_version(path):
    match = DEPOT_TOOL_ARCHIVE_RE.fullmatch(path.name)
    return None if match is None else match.group("version")


def _version_sort_key(version):
    parts = []
    for part in re.split(r"[.+-]", (version or "").lstrip("vV")):
        parts.append((0, int(part)) if part.isdigit() else (1, part.lower()))
    return parts


def _depot_tool_archives():
    """List the tool archives the sync mirrored under PROD/COMP/VCFDT.

    Only regular files directly under the VCFDT tree that still resolve inside
    it after symlink resolution are offered.
    """
    root = DEPOT_TOOL_DIR
    if not root.is_dir():
        return []
    try:
        resolved_root = root.resolve(strict=True)
        candidates = sorted(root.iterdir())
    except OSError:
        return []
    installed = _current_tool_info()
    entries = []
    for path in candidates:
        try:
            _archive_kind(path.name)
        except ToolArchiveError:
            continue
        try:
            resolved = path.resolve(strict=True)
            if not resolved.is_file() or not resolved.is_relative_to(resolved_root):
                continue
            stat = resolved.stat()
        except OSError:
            continue
        version = _archive_version(path)
        entries.append(
            {
                "path": path.name,
                "filename": path.name,
                "version": version or "unknown",
                "versionKnown": version is not None,
                "sizeBytes": stat.st_size,
                "readable": os.access(resolved, os.R_OK),
                "modifiedAt": datetime.fromtimestamp(
                    stat.st_mtime, timezone.utc
                ).isoformat(),
                "installed": bool(
                    installed["installed"]
                    and (
                        (
                            installed.get("source") == "depot"
                            and installed.get("sourceFile") == path.name
                        )
                        or (version is not None and version == installed["version"])
                    )
                ),
            }
        )
    entries.sort(
        key=lambda entry: (
            entry["versionKnown"],
            _version_sort_key(entry["version"]),
            entry["modifiedAt"],
        ),
        reverse=True,
    )
    return entries


def _resolve_depot_archive(value):
    """Map an operator-chosen listing path back to a file inside the VCFDT tree."""
    if not isinstance(value, str) or not value.strip():
        raise ToolArchiveError("choose a VCF Download Tool archive from the depot")
    if "\x00" in value:
        raise ToolArchiveError("the chosen archive is not inside the depot VCFDT tree")
    name = value.replace("\\", "/")
    if "/" in name or name in {".", ".."}:
        raise ToolArchiveError("the chosen archive is not inside the depot VCFDT tree")
    try:
        resolved_root = DEPOT_TOOL_DIR.resolve(strict=True)
        candidate = (DEPOT_TOOL_DIR / name).resolve(strict=True)
    except (OSError, ValueError) as exc:
        raise ToolArchiveError("the chosen archive is not in the depot") from exc
    if candidate == resolved_root or not candidate.is_relative_to(resolved_root):
        raise ToolArchiveError("the chosen archive is not inside the depot VCFDT tree")
    if not candidate.is_file():
        raise ToolArchiveError("the chosen depot entry is not an archive file")
    _archive_kind(candidate.name)
    if not os.access(candidate, os.R_OK):
        raise ToolArchiveError(
            "the console cannot read that depot archive; check its file mode"
        )
    return candidate


def _replace_tool(install):
    """Run one tool replacement under the guards shared by upload and depot."""
    try:
        with _tool_update_lock():
            if _state().get("running", False):
                return jsonify({"error": "wait for the running sync to finish"}), 409
            metadata, old_target, machine_id = install()
            _reconcile_machine_id_adoption(machine_id)
            old_previous = _release_target("previous")
            previous = VCFDT_STORE / "previous"
            if old_target:
                next_previous = VCFDT_STORE / f".previous-{uuid.uuid4().hex}"
                next_previous.symlink_to(Path("releases") / old_target.name)
                os.replace(next_previous, previous)
            else:
                previous.unlink(missing_ok=True)
            if old_previous and old_previous != old_target:
                shutil.rmtree(old_previous, ignore_errors=True)
    except BlockingIOError:
        return jsonify(
            {"error": "wait for the running sync or tool update to finish"}
        ), 409
    except ToolArchiveError as exc:
        return jsonify({"error": str(exc)}), 400
    except OSError:
        return jsonify(
            {"error": "the tool could not be staged on its mounted volume"}
        ), 500
    return jsonify(
        {
            "installed": True,
            **metadata,
            "registration": _registration_details(_current_tool_info()),
        }
    ), 201


def _rollback_tool():
    try:
        with _tool_update_lock():
            if _state().get("running", False):
                return jsonify({"error": "wait for the running sync to finish"}), 409
            current_target = _release_target("current")
            previous_target = _release_target("previous")
            if current_target is None or previous_target is None:
                return jsonify({"error": "no previous tool release is available"}), 409
            swap_id = uuid.uuid4().hex
            next_current = VCFDT_STORE / f".current-rollback-{swap_id}"
            next_previous = VCFDT_STORE / f".previous-rollback-{swap_id}"
            next_current.symlink_to(Path("releases") / previous_target.name)
            next_previous.symlink_to(Path("releases") / current_target.name)
            current_swapped = False
            try:
                os.replace(next_current, VCFDT_STORE / "current")
                current_swapped = True
                os.replace(next_previous, VCFDT_STORE / "previous")
            except OSError:
                if current_swapped:
                    restore = VCFDT_STORE / f".current-restore-{swap_id}"
                    restore.symlink_to(Path("releases") / current_target.name)
                    os.replace(restore, VCFDT_STORE / "current")
                raise
            finally:
                next_current.unlink(missing_ok=True)
                next_previous.unlink(missing_ok=True)
            try:
                machine_id = _probe_machine_id(previous_target)
            except ToolArchiveError:
                machine_id = None
            _record_release_identity(previous_target, machine_id)
            _reconcile_machine_id_adoption(machine_id)
            return jsonify(_current_tool_info())
    except BlockingIOError:
        return jsonify(
            {"error": "wait for the running sync or tool update to finish"}
        ), 409
    except OSError:
        return jsonify({"error": "the tool rollback could not be completed"}), 500


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
        "syncDiagnostics": _bool_setting(settings.get("SYNC_DIAGNOSTICS")),
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


def _running_sync_id(state):
    """Identify the in-flight run, or None when no sync is running."""
    if not state.get("running", False):
        return None
    return str(state.get("startedAt") or "unknown-run")


def _snapshot_run_id(state=None):
    """Identify the run that owns the settings snapshot right now.

    Only meaningful while a run holds the snapshot lock: the file keeps the
    last run's identity afterwards, which is what makes a marker left by a
    finished run distinguishable from one saved during the current run.
    """
    try:
        recorded = SYNC_SNAPSHOT_RUN_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        recorded = ""
    if recorded:
        return recorded
    # A sync image that predates the identity file falls back to the published
    # run state, which is absent in the gap before the run publishes it.
    return _running_sync_id(_state() if state is None else state)


def _sync_snapshot_active(state=None):
    """Report whether a sync run already holds the settings.env snapshot.

    A run holds the lock from before it reads settings.env until it exits, so
    the kernel releases it even if the run is killed. The published state is
    kept as a fallback for a sync image that predates the lock.
    """
    try:
        handle = os.open(SYNC_SNAPSHOT_LOCK, os.O_RDONLY)
    except OSError:
        handle = None
    if handle is not None:
        try:
            fcntl.flock(handle, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except OSError:
            return True
        else:
            fcntl.flock(handle, fcntl.LOCK_UN)
        finally:
            os.close(handle)
    state = _state() if state is None else state
    return bool(state.get("running", False))


@contextmanager
def _settings_snapshot_guard():
    """Serialise a settings save against the point a run reads settings.env.

    Yields True when a run already holds the snapshot, which means the save
    applies to the next run. While this shared lock is held, a starting run
    waits before reading settings.env, so a save can never land in the gap
    between a run reading the file and publishing its running state.
    """
    try:
        handle = os.open(SYNC_SNAPSHOT_LOCK, os.O_RDONLY)
    except OSError:
        yield bool(_state().get("running", False))
        return
    try:
        try:
            fcntl.flock(handle, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except OSError:
            yield True
            return
        try:
            yield bool(_state().get("running", False))
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
    finally:
        os.close(handle)


def _read_pending_document():
    try:
        document = json.loads(SETTINGS_PENDING_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(document, dict):
        return None
    return document


def _pending_document_fields(document):
    fields = document.get("fields")
    if not isinstance(fields, list):
        return []
    return [field for field in fields if isinstance(field, str)]


def _record_pending_settings(fields, run_id):
    known = set(fields)
    existing = _read_pending_document()
    if existing is not None and existing.get("syncStartedAt") == run_id:
        known.update(_pending_document_fields(existing))
    document = {"syncStartedAt": run_id, "fields": sorted(known)}
    SETTINGS_PENDING_FILE.parent.mkdir(parents=True, exist_ok=True)
    handle, temp_name = tempfile.mkstemp(
        prefix=f"{SETTINGS_PENDING_FILE.name}.", dir=SETTINGS_PENDING_FILE.parent
    )
    try:
        os.fchmod(handle, 0o640)
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(json.dumps(document) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, SETTINGS_PENDING_FILE)
    except Exception:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


def _live_tool_conflict(fields):
    return (
        "the running sync is still reading these from the mounted tool: "
        + ", ".join(fields)
        + ". Change them once the run finishes; every other setting saves now."
    )


def _clear_pending_settings():
    try:
        SETTINGS_PENDING_FILE.unlink()
    except OSError:
        pass


def _pending_settings(state=None, in_flight=None):
    """Report settings saved during the run that is still in flight."""
    state = _state() if state is None else state
    if in_flight is None:
        in_flight = _sync_snapshot_active(state)
    document = _read_pending_document()
    if document is None or not in_flight:
        return {"appliesToNextRun": False, "pendingFields": []}
    if document.get("syncStartedAt") != _snapshot_run_id(state):
        # The marker belongs to a run that has finished. The current run read
        # these values at its own start, so they are in use, not pending.
        return {"appliesToNextRun": False, "pendingFields": []}
    fields = _pending_document_fields(document)
    return {"appliesToNextRun": bool(fields), "pendingFields": fields}


def _activation_configured():
    try:
        return bool(ACTIVATION_CODE_FILE.read_text().strip())
    except OSError:
        return False


def _persisted_machine_id():
    try:
        value = SOFTWARE_DEPOT_ID_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return value if SOFTWARE_DEPOT_ID_RE.fullmatch(value) else None


def _remember_machine_id(value):
    if SOFTWARE_DEPOT_ID_RE.fullmatch(value) is None:
        raise ValueError("refusing to persist an invalid Software Depot ID")
    _write_secret(SOFTWARE_DEPOT_ID_FILE, value + "\n")


def _machine_id_adoption():
    try:
        document = json.loads(SOFTWARE_DEPOT_ADOPTION_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(document, dict):
        return None
    adopted_id = document.get("adoptedId")
    status = document.get("status")
    if (
        not isinstance(adopted_id, str)
        or SOFTWARE_DEPOT_ID_RE.fullmatch(adopted_id) is None
        or status not in {"adopted", "confirmed", "mismatch"}
    ):
        return None
    reported_id = document.get("reportedId")
    if reported_id is not None and (
        not isinstance(reported_id, str)
        or SOFTWARE_DEPOT_ID_RE.fullmatch(reported_id) is None
    ):
        reported_id = None
    return {
        "status": status,
        "adoptedId": adopted_id,
        "reportedId": reported_id,
    }


def _record_machine_id_adoption(adopted_id, status, reported_id=None):
    document = {
        "status": status,
        "adoptedId": adopted_id,
        "reportedId": reported_id,
        "updatedAt": datetime.now(timezone.utc).isoformat(),
    }
    _write_secret(SOFTWARE_DEPOT_ADOPTION_FILE, json.dumps(document) + "\n")
    return document


def _reconcile_machine_id_adoption(machine_id):
    adoption = _machine_id_adoption()
    if machine_id:
        _remember_machine_id(machine_id)
    if adoption is None:
        return None
    matches = bool(
        machine_id and machine_id.lower() == adoption["adoptedId"].lower()
    )
    return _record_machine_id_adoption(
        adoption["adoptedId"],
        "confirmed" if matches else "mismatch",
        machine_id,
    )


MACHINE_ID_PROBE_FAILED = (
    "The tool probe failed and did not return a recognizable Software Depot ID. "
    "The last verified ID is unchanged."
)
IDENTITY_VERIFICATION_RUNS = (
    "Verification runs on its own at appliance start and after tool changes; "
    "use Verify with the tool to run it now."
)


def _adoption_message(adoption, tool_installed):
    if adoption is None:
        return None
    adopted_id = adoption["adoptedId"]
    if not tool_installed:
        message = (
            f"Adopted {adopted_id}. It will be confirmed at the first tool install."
        )
    elif adoption["status"] == "adopted":
        message = (
            f"Adopted {adopted_id}. Verify with the installed tool to confirm it."
        )
    elif adoption["status"] == "confirmed":
        message = f"Confirmed {adopted_id} with the installed tool."
    else:
        reported = adoption.get("reportedId") or "no recognizable ID"
        message = f"Identity mismatch: adopted {adopted_id}, but the tool reported {reported}."
    return message


def _identity_changed_message(machine_id):
    return (
        f"{machine_id} was verified with the installed tool, but the tool's "
        f"identity changed afterwards. {IDENTITY_VERIFICATION_RUNS}"
    )


def _registration_details(tool=None):
    """Describe the Software Depot ID from durable state alone.

    Bootstrap and every dashboard read call this, so it never launches the
    tool. The install, replacement, rollback and verify actions run the probe
    and record its outcome with the release (and in the adoption record), and
    this reads those records back. A release with no recorded outcome is
    reported as unverified rather than assumed confirmed.
    """
    tool = _current_tool_info() if tool is None else tool
    adoption = _machine_id_adoption()
    installed = tool["installed"]
    saved = _persisted_machine_id()
    error = None
    message = _adoption_message(adoption, installed)
    verified_at = None
    if adoption is not None and installed and adoption["status"] != "adopted":
        status = adoption["status"]
        machine_id = (
            adoption["adoptedId"] if status == "confirmed" else adoption.get("reportedId")
        )
        if tool["machineIdProbed"] and _identity_changed_since(tool["machineIdProbedAt"]):
            status = "unverified"
            machine_id = adoption["adoptedId"]
            verified_at = tool["machineIdProbedAt"]
            message = _identity_changed_message(machine_id)
    elif adoption is not None:
        status = "adopted"
        machine_id = adoption["adoptedId"]
    elif not installed:
        status = None
        machine_id = saved
        error = "Install the VCF Download Tool before verifying its saved ID."
    elif not tool["machineIdProbed"]:
        status = "unverified"
        machine_id = saved
        message = (
            f"{saved} was saved earlier and has not been verified with the installed "
            f"tool yet. {IDENTITY_VERIFICATION_RUNS}"
            if saved
            else "The installed tool's Software Depot ID has not been read yet. "
            f"{IDENTITY_VERIFICATION_RUNS}"
        )
    elif tool["machineId"] is None:
        status = "failed"
        machine_id = saved
        error = MACHINE_ID_PROBE_FAILED
    elif _identity_changed_since(tool["machineIdProbedAt"]):
        status = "unverified"
        machine_id = tool["machineId"]
        verified_at = tool["machineIdProbedAt"]
        message = _identity_changed_message(machine_id)
    else:
        status = "confirmed"
        machine_id = tool["machineId"]
        verified_at = tool["machineIdProbedAt"]
    return {
        "machineId": machine_id,
        "machineIdError": error,
        "machineIdStatus": status,
        "machineIdVerifiedAt": verified_at,
        "adoptedMachineId": adoption["adoptedId"] if adoption else None,
        "reportedMachineId": adoption.get("reportedId") if adoption else None,
        "machineIdMessage": message,
    }


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
    return (
        "authentication required",
        401,
        {"WWW-Authenticate": 'Basic realm="VCF Services"'},
    )


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
        return jsonify(
            {"error": "the password must be one line and at most 1024 characters"}
        ), 400

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
    if not _verify_credentials(
        str(body.get("username", "")), str(body.get("password", ""))
    ):
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
    version_problem = _version_problem()
    if auth and not _is_authenticated():
        return jsonify(
            {
                "claimed": True,
                "authenticated": False,
                "setupComplete": False
                if version_problem
                else settings["setupComplete"],
                "versionProblem": version_problem,
            }
        )
    tool = _current_tool_info()
    registration = _registration_details(tool)
    return jsonify(
        {
            "claimed": auth is not None,
            "authenticated": _is_authenticated(),
            "setupComplete": False if version_problem else settings["setupComplete"],
            "versionProblem": version_problem,
            "migration": _migration_status(),
            "tool": tool,
            **registration,
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


def _cron_problem(cron):
    """Return the operator-facing reason a five-field cron string is invalid."""
    if len(cron.split()) != 5 or not re.fullmatch(r"[0-9*/ ,\-]+", cron):
        return "the schedule must use five cron fields"
    try:
        croniter(cron, datetime.now(timezone.utc)).get_next(datetime)
    except (KeyError, ValueError):
        return "the sync schedule is invalid"
    return None


def _zone(timezone_name):
    try:
        return ZoneInfo(timezone_name or "UTC")
    except (KeyError, ValueError):
        return timezone.utc


def _next_run(cron, tzinfo):
    try:
        return croniter(cron, datetime.now(tzinfo)).get_next(datetime).isoformat()
    except (KeyError, ValueError):
        return None


@app.get("/api/schedule/preview")
def schedule_preview():
    """Compute the next run for an unsaved schedule so the picker can show it.

    The picker composes the same five-field string that POST /api/settings
    stores, so the validation here is the one the save applies.
    """
    cron = str(request.args.get("cron", "")).strip()
    problem = _cron_problem(cron)
    if problem:
        return jsonify({"error": problem}), 400
    # The timezone is always supplied by the picker and validated the same way
    # the save validates it, so a blank or missing value is a 400, not a
    # fallback to the stored zone.
    timezone_name = str(request.args.get("timezone", "")).strip()
    try:
        tzinfo = ZoneInfo(timezone_name)
    except (KeyError, ValueError):
        return jsonify({"error": "choose a valid IANA timezone"}), 400
    return jsonify(
        {"cron": cron, "timezone": timezone_name, "nextRun": _next_run(cron, tzinfo)}
    )


@app.get("/api/status")
def status():
    state = _state()
    settings = _settings()
    tool_info = _current_tool_info()
    cron = settings.get("CRON_SCHEDULE", "0 3 * * 0")
    next_run = _next_run(cron, _zone(settings.get("TZ")))
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
            **_pending_settings(state),
        }
    )


@app.get("/api/vcfdt")
def vcfdt_status():
    return jsonify(_current_tool_info())


@app.get("/api/depot/ownership")
def depot_ownership():
    try:
        trees = _depot_ownership_inventory()
    except BlockingIOError:
        return jsonify({"error": "wait for the running sync to finish"}), 409
    except OSError as exc:
        return jsonify({"error": f"depot ownership could not be read: {exc}"}), 500
    return jsonify(
        {
            "manifest": str(DEPOT_OWNERSHIP_FILE),
            "root": str(DEPOT / "PROD" / "COMP"),
            "trees": trees,
        }
    )


@app.get("/api/depot/tree")
def depot_tree():
    try:
        with _depot_discovery_guard():
            ownership_manifest = _ensure_ownership_manifest()
        directory, relative = _depot_relative_path(
            request.args.get("path", ""), must_exist=True
        )
        if not directory.is_dir():
            raise DepotError("choose a depot directory to browse")
        entries = []
        for path in sorted(
            directory.iterdir(), key=lambda item: (not item.is_dir(), item.name.lower())
        ):
            if path.name.startswith(".vcf-services-upload-"):
                continue
            child_relative = "/".join(filter(None, (relative, path.name)))
            try:
                _depot_relative_path(child_relative, must_exist=True)
                accessible_directory = path.is_dir()
                protected = _protected_trees_for_path(
                    child_relative,
                    include_descendants=True,
                    ownership_manifest=ownership_manifest,
                )
            except DepotError:
                accessible_directory = False
                protected = []
            size_bytes, file_count = _entry_usage(
                path.resolve() if accessible_directory else path
            )
            entries.append(
                {
                    "name": path.name,
                    "path": child_relative,
                    "type": "directory"
                    if accessible_directory
                    else "symlink"
                    if path.is_symlink()
                    else "file",
                    "sizeBytes": size_bytes,
                    "fileCount": file_count,
                    "protected": bool(protected),
                    "protectedTrees": protected,
                }
            )
    except BlockingIOError:
        return jsonify({"error": "wait for the running sync to finish"}), 409
    except (DepotError, OSError) as exc:
        return jsonify({"error": str(exc)}), 400
    parent = "" if not relative or "/" not in relative else relative.rsplit("/", 1)[0]
    return jsonify(
        {
            "path": relative,
            "parent": parent,
            "publicDownload": _paths_publicly_exposed([relative]),
            "entries": entries,
        }
    )


@app.post("/api/depot/upload")
def upload_depot_entry():
    upload = request.files.get("upload")
    if upload is None or not upload.filename:
        return jsonify({"error": "choose a file or archive to upload"}), 400
    destination_value = request.form.get("path", "")
    extract = str(request.form.get("extract", "false")).lower() == "true"
    filename = PurePosixPath(str(upload.filename).replace("\\", "/")).name
    if not filename or filename in {".", ".."}:
        return jsonify({"error": "the upload filename is invalid"}), 400
    if _is_licensed_tool_name(filename):
        return jsonify(
            {"error": "licensed VCF Download Tool archives must use the Setup tab"}
        ), 400
    staging = None
    try:
        with _depot_mutation_guard():
            destination, destination_relative = _depot_relative_path(
                destination_value, must_exist=True
            )
            if not destination.is_dir():
                raise DepotError("choose a depot directory as the upload destination")
            before = _top_level_comp_trees()
            staging = Path(
                tempfile.mkdtemp(prefix=".vcf-services-upload-", dir=DEPOT)
            )
            uploaded_paths = []
            published = []
            try:
                if extract:
                    archive_path = staging / "archive"
                    content = staging / "content"
                    content.mkdir()
                    upload.save(archive_path)
                    try:
                        kind = _archive_kind(filename)
                    except ToolArchiveError as exc:
                        raise DepotError(
                            "choose a .tar.gz, .tgz, or .zip archive to extract"
                        ) from exc
                    if kind == "tar":
                        _extract_tar(archive_path, content)
                    else:
                        _extract_zip(archive_path, content)
                    _validate_depot_staging(content)
                    children = list(content.iterdir())
                    if not children:
                        raise DepotError("the archive contains no files")
                    for child in children:
                        target_relative = "/".join(
                            filter(None, (destination_relative, child.name))
                        )
                        protected = _protected_trees_for_path(target_relative)
                        if protected:
                            raise DepotError(
                                f"unprotect PROD/COMP/{protected[0]} before uploading there"
                            )
                        if (destination / child.name).exists() or (
                            destination / child.name
                        ).is_symlink():
                            raise DepotError(
                                f"{target_relative} already exists; delete it explicitly first"
                            )
                        uploaded_paths.append(target_relative)
                    for child in children:
                        target = destination / child.name
                        os.replace(child, target)
                        published.append((child, target))
                else:
                    target_relative = "/".join(
                        filter(None, (destination_relative, filename))
                    )
                    protected = _protected_trees_for_path(target_relative)
                    if protected:
                        raise DepotError(
                            f"unprotect PROD/COMP/{protected[0]} before uploading there"
                        )
                    target = destination / filename
                    if target.exists() or target.is_symlink():
                        raise DepotError(
                            f"{target_relative} already exists; delete it explicitly first"
                        )
                    staged_file = staging / filename
                    upload.save(staged_file)
                    os.replace(staged_file, target)
                    uploaded_paths.append(target_relative)
                    published.append((staged_file, target))
                public = _paths_publicly_exposed(
                    uploaded_paths, include_ancestors=True
                )
                _record_operator_trees(_top_level_comp_trees() - before)
            except (DepotError, OSError):
                for staged_path, published_path in reversed(published):
                    if published_path.exists() and not staged_path.exists():
                        os.replace(published_path, staged_path)
                raise
    except BlockingIOError:
        return jsonify(
            {"error": "wait for the running sync or tool update to finish"}
        ), 409
    except (DepotError, ToolArchiveError) as exc:
        return jsonify({"error": str(exc)}), 400
    except OSError as exc:
        return jsonify({"error": f"the depot upload could not be completed: {exc}"}), 500
    finally:
        if staging is not None:
            shutil.rmtree(staging, ignore_errors=True)
    return jsonify(
        {
            "uploaded": True,
            "path": destination_relative,
            "publicDownload": public,
            "notice": "Content under /umds-patch-store is downloadable without credentials."
            if public
            else None,
        }
    ), 201


@app.delete("/api/depot/entry")
def delete_depot_entry():
    body = request.get_json(silent=True) or {}
    value = body.get("path")
    confirmation = body.get("confirm")
    try:
        with _depot_mutation_guard():
            path, relative = _depot_relative_path(
                value, allow_root=False, must_exist=True
            )
            if confirmation != relative:
                raise DepotError(f"type {relative} exactly to confirm deletion")
            protected = _protected_trees_for_path(relative, include_descendants=True)
            if protected:
                raise DepotError(
                    f"unprotect PROD/COMP/{protected[0]} before deleting this path"
                )
            resolved_relative = path.resolve().relative_to(DEPOT.resolve()).as_posix()
            size_bytes, file_count = _entry_usage(path)
            if path.is_symlink():
                raise DepotError("symbolic links cannot be deleted through the explorer")
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
            _forget_deleted_trees(resolved_relative)
    except BlockingIOError:
        return jsonify(
            {"error": "wait for the running sync or tool update to finish"}
        ), 409
    except (DepotError, OSError) as exc:
        return jsonify({"error": str(exc)}), 400
    return jsonify(
        {
            "deleted": True,
            "path": relative,
            "sizeBytes": size_bytes,
            "fileCount": file_count,
        }
    )


@app.post("/api/depot/ownership")
def update_depot_ownership():
    body = request.get_json(silent=True) or {}
    name = body.get("name")
    protected = body.get("protected")
    if (
        not isinstance(name, str)
        or not name
        or "/" in name
        or "\\" in name
        or name in {".", ".."}
    ):
        return jsonify({"error": "choose one top-level PROD/COMP tree"}), 400
    if not isinstance(protected, bool):
        return jsonify({"error": "protected must be true or false"}), 400
    try:
        with _depot_mutation_guard():
            tree = DEPOT / "PROD" / "COMP" / name
            try:
                root = (DEPOT / "PROD" / "COMP").resolve(strict=True)
                resolved = tree.resolve(strict=True)
            except OSError:
                return jsonify({"error": "that PROD/COMP tree does not exist"}), 404
            if tree.is_symlink() or resolved.parent != root or not resolved.is_dir():
                return jsonify(
                    {"error": "choose one real top-level PROD/COMP tree"}
                ), 400
            _ensure_ownership_manifest()
            with _ownership_lock():
                manifest = _read_ownership_manifest()
                entry = manifest["trees"].get(name)
                if entry is None:
                    return jsonify(
                        {"error": "that PROD/COMP tree is not inventoried"}
                    ), 404
                entry["protected"] = protected
                _write_ownership_manifest(manifest)
    except BlockingIOError:
        return jsonify(
            {"error": "wait for the running sync or tool update to finish"}
        ), 409
    except OSError as exc:
        return jsonify({"error": f"depot ownership could not be saved: {exc}"}), 500
    return jsonify({"name": name, **entry})


@app.post("/api/vcfdt")
def upload_vcfdt():
    upload = request.files.get("archive")
    if upload is None or not upload.filename:
        return jsonify({"error": "choose a VCF Download Tool archive"}), 400
    return _replace_tool(lambda: _install_tool(upload))


@app.get("/api/vcfdt/depot")
def vcfdt_depot_archives():
    return jsonify(
        {
            "directory": str(DEPOT_TOOL_DIR),
            "mounted": DEPOT_TOOL_DIR.is_dir(),
            "installed": _current_tool_info(),
            "archives": _depot_tool_archives(),
        }
    )


@app.post("/api/vcfdt/depot")
def install_vcfdt_from_depot():
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        body = {}
    try:
        archive = _resolve_depot_archive(body.get("path"))
    except ToolArchiveError as exc:
        return jsonify({"error": str(exc)}), 400
    return _replace_tool(lambda: _install_tool_archive(archive, archive.name, "depot"))


@app.post("/api/vcfdt/rollback")
def rollback_vcfdt():
    return _rollback_tool()


@app.get("/api/registration")
def registration_status():
    details = _registration_details()
    status_code = 200 if details["machineIdStatus"] == "confirmed" else 409
    return (
        jsonify(
            {
                **details,
                "error": details["machineIdError"],
                "activationConfigured": _activation_configured(),
                "instructions": ARMING_INSTRUCTIONS,
            }
        ),
        status_code,
    )


@app.post("/api/registration/adopt")
def adopt_registration():
    body = request.get_json(silent=True)
    value = body.get("machineId") if isinstance(body, dict) else None
    if not isinstance(value, str):
        return jsonify({"error": "enter a 36-character Software Depot ID UUID"}), 400
    value = value.strip()
    if len(value) != 36 or SOFTWARE_DEPOT_ID_RE.fullmatch(value) is None:
        return jsonify({"error": "enter a 36-character Software Depot ID UUID"}), 400
    value = value.lower()
    try:
        with _tool_update_lock():
            if _state().get("running", False):
                return jsonify({"error": "wait for the running sync to finish"}), 409
            if _current_tool_info()["installed"]:
                return jsonify(
                    {"error": "adopt an existing Software Depot ID before installing the tool"}
                ), 409
            _write_secret(VCFDT_MACHINE_ID_FILE, value)
            _remember_machine_id(value)
            adoption = _record_machine_id_adoption(value, "adopted")
            return jsonify(
                {
                    "adopted": True,
                    "confirmed": False,
                    "machineId": value,
                    "status": "adopted",
                    "message": _adoption_message(adoption, False),
                }
            )
    except BlockingIOError:
        return jsonify(
            {"error": "wait for the running sync or tool update to finish"}
        ), 409
    except OSError:
        return jsonify(
            {"error": "the Software Depot ID could not be written to durable tool state"}
        ), 500


def _identity_verification_needed(tool, adoption):
    """Whether the installed tool's identity record is missing, failed, stale,
    or still waiting to confirm an adopted ID."""
    if not tool["installed"]:
        return False
    if adoption is not None and adoption["status"] == "adopted":
        return True
    if not tool["machineIdProbed"] or tool["machineId"] is None:
        return True
    return _identity_changed_since(tool["machineIdProbedAt"])


def _verify_identity_now():
    """Probe the installed tool and record the outcome durably.

    The caller holds the tool update lock, so the release cannot be swapped
    under the probe. A failed probe is recorded as failed and never replaces
    the last verified ID.
    """
    current = VCFDT_STORE / "current"
    try:
        machine_id = _probe_machine_id(current)
    except ToolArchiveError:
        machine_id = None
    _record_release_identity(current, machine_id)
    _reconcile_machine_id_adoption(machine_id)
    return machine_id


STARTUP_VERIFICATION_DELAYS = (10, 60, 300, 900)
STARTUP_VERIFICATION_RETRY_EVERY = 900


def _startup_identity_verification(
    delays=STARTUP_VERIFICATION_DELAYS,
    retry_every=STARTUP_VERIFICATION_RETRY_EVERY,
    sleep=time.sleep,
):
    """Verify a missing, failed, stale or pending identity once after start.

    This is the background verification behind an appliance upgrade (a
    release recorded by an older console), an identity file changed outside
    the console, or an install-time probe that failed. It launches the tool
    at most once and never runs on a request. A running sync or a tool
    update in flight defers it instead of launching the tool beside them:
    after the listed delays it keeps retrying every retry_every seconds for
    as long as it is deferred, so a long sync running at start only delays
    it. The exclusive lock also makes a second worker skip while the first
    is probing. It returns once verification is not needed or has run.
    """
    attempt = 0
    while True:
        sleep(delays[attempt] if attempt < len(delays) else retry_every)
        attempt += 1
        if not _identity_verification_needed(_current_tool_info(), _machine_id_adoption()):
            return "not needed"
        if _state().get("running", False):
            continue
        try:
            with _tool_update_lock():
                if not _identity_verification_needed(
                    _current_tool_info(), _machine_id_adoption()
                ):
                    return "not needed"
                machine_id = _verify_identity_now()
                outcome = "verified" if machine_id else "failed"
        except BlockingIOError:
            continue
        except (OSError, ValueError) as exc:
            print(f"[identity] startup verification could not be recorded: {exc}", flush=True)
            return "error"
        print(f"[identity] startup verification {outcome}", flush=True)
        return outcome


def verify_identity_on_start():
    """Start the bounded background verification; called by gunicorn.conf.py."""
    thread = threading.Thread(
        target=_startup_identity_verification,
        name="identity-verification",
        daemon=True,
    )
    thread.start()
    return thread


def _registration_problem(registration):
    return (
        registration["machineIdError"]
        or registration["machineIdMessage"]
        or "verify the Software Depot ID with the installed tool first"
    )


@app.post("/api/registration/verify")
def verify_registration():
    """Read the Software Depot ID from the installed tool on operator request.

    Install, replacement and rollback record a probe, and the startup hook
    verifies a missing, failed, stale or pending record on its own; this is
    the optional recovery path for running that verification right away.
    """
    try:
        with _tool_update_lock():
            if _state().get("running", False):
                return jsonify({"error": "wait for the running sync to finish"}), 409
            if not _current_tool_info()["installed"]:
                return jsonify(
                    {"error": "install the VCF Download Tool before verifying its ID"}
                ), 409
            _verify_identity_now()
    except BlockingIOError:
        return jsonify(
            {"error": "wait for the running sync or tool update to finish"}
        ), 409
    except OSError:
        return jsonify({"error": "the verification result could not be recorded"}), 500
    registration = _registration_details()
    if registration["machineIdStatus"] != "confirmed":
        return jsonify({**registration, "error": _registration_problem(registration)}), 409
    return jsonify({**registration, "verified": True})


@app.post("/api/registration")
def save_registration():
    body = request.get_json(silent=True) or {}
    activation_code = body.get("activationCode")
    if _state().get("running", False):
        return jsonify({"error": "wait for the running sync to finish"}), 409
    registration = _registration_details()
    machine_id = registration["machineId"]
    if registration["machineIdStatus"] != "confirmed":
        return jsonify({"error": _registration_problem(registration)}), 409
    if not isinstance(activation_code, str) or not activation_code.strip():
        return jsonify({"error": "enter the activation code from Broadcom"}), 400
    activation_code = activation_code.strip()
    if (
        len(activation_code) > 4096
        or "\n" in activation_code
        or "\r" in activation_code
    ):
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
    return jsonify({**_settings_doc(), **_pending_settings()})


@app.post("/api/settings")
def update_settings():
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        return jsonify({"error": "a JSON settings document is required"}), 400
    allowed_fields = set(SETTING_ENV_FIELDS.values())
    unknown_fields = sorted(set(body) - allowed_fields)
    if unknown_fields:
        return jsonify(
            {"error": "unknown settings field: " + ", ".join(unknown_fields)}
        ), 400
    body = {**_settings_doc(), **body}
    vcf_version = str(body["vcfVersion"]).strip()
    if not re.fullmatch(r"[0-9][0-9A-Za-z.*_-]*(\.\.)?", vcf_version):
        return jsonify({"error": "the VCF version filter is invalid"}), 400
    sku = str(body["sku"])
    if sku not in {"VCF", "VVF"}:
        return jsonify({"error": "SKU must be VCF or VVF"}), 400
    targets = body["syncTargets"]
    if not isinstance(targets, list) or not targets:
        return jsonify({"error": "select at least one sync target"}), 400
    if any(target not in VALID_TARGETS for target in targets) or len(
        set(targets)
    ) != len(targets):
        return jsonify({"error": "the sync target selection is invalid"}), 400
    cron = str(body["cronSchedule"]).strip()
    cron_problem = _cron_problem(cron)
    if cron_problem:
        return jsonify({"error": cron_problem}), 400
    timezone_name = str(body["timezone"]).strip()
    try:
        ZoneInfo(timezone_name)
    except (KeyError, ValueError):
        return jsonify({"error": "choose a valid IANA timezone"}), 400
    ceip = str(body["ceip"])
    if ceip not in {"DISABLE", "ENABLE"}:
        return jsonify({"error": "CEIP must be explicitly enabled or disabled"}), 400
    depot_endpoint = str(body["depotEndpoint"]).strip().lower()
    if not re.fullmatch(r"[A-Za-z0-9.-]+", depot_endpoint) or ".." in depot_endpoint:
        return jsonify({"error": "the download endpoint hostname is invalid"}), 400
    token_url = str(body["tokenUrl"]).strip()
    if not re.fullmatch(r"https://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+", token_url):
        return jsonify({"error": "the token URL must be a valid HTTPS URL"}), 400
    backup_enabled = body["backupEnabled"]
    storage_confirmed = body["storageConfirmed"]
    if not isinstance(backup_enabled, bool) or not isinstance(storage_confirmed, bool):
        return jsonify(
            {"error": "storage and backup selections must be true or false"}
        ), 400
    sync_diagnostics = body["syncDiagnostics"]
    if not isinstance(sync_diagnostics, bool):
        return jsonify(
            {"error": "verbose sync diagnostics must be true or false"}
        ), 400
    uid_gid = str(body["uidGid"])
    match = re.fullmatch(r"([0-9]+):([0-9]+)", uid_gid)
    if not match or any(not 1 <= int(value) <= 2147483647 for value in match.groups()):
        return jsonify(
            {"error": "UID:GID must contain two non-root numeric values"}
        ), 400
    esx_mode = str(body["esxMode"])
    if esx_mode not in {"download", "metadata"}:
        return jsonify({"error": "ESX mode must be download or metadata"}), 400
    log_retention = body["logRetention"]
    if isinstance(log_retention, bool) or not str(log_retention).isdigit():
        return jsonify({"error": "log retention must be a whole number"}), 400
    log_retention = int(log_retention)
    if not 1 <= log_retention <= 1000:
        return jsonify({"error": "log retention must be from 1 through 1000"}), 400
    vkr_match = str(body["vkrMatch"]).strip()
    vkr_os = str(body["vkrOs"]).strip()
    if (
        len(vkr_match) > 200
        or len(vkr_os) > 100
        or any("\n" in value or "\r" in value for value in (vkr_match, vkr_os))
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
        "SYNC_DIAGNOSTICS": str(sync_diagnostics).lower(),
        "SYNC_TARGETS": " ".join(targets),
        "TOKEN_URL": token_url,
        "TZ": timezone_name,
        "VCF_VERSION": vcf_version,
        "VKR_MATCH": vkr_match,
        "VKR_OS": vkr_os,
    }
    stored = _settings()
    before = _settings_doc(stored)
    after = _settings_doc({**stored, **updates})
    changed = sorted(
        field for field in SETTING_ENV_FIELDS.values() if before[field] != after[field]
    )
    live_tool_changes = [field for field in changed if field in LIVE_TOOL_FIELDS]
    applied_now = [field for field in changed if field in LIVE_SERVICE_FIELDS]
    deferred = [field for field in changed if field not in LIVE_SERVICE_FIELDS]
    patched_files = []
    try:
        # The guard is held across the write, so a run cannot read settings.env
        # while the save is in flight and the answer it yields stays true.
        with _settings_snapshot_guard() as snapshot_taken:
            if snapshot_taken and live_tool_changes:
                return jsonify({"error": _live_tool_conflict(live_tool_changes)}), 409
            state = _state()
            run_id = _snapshot_run_id(state) if snapshot_taken else None
            if live_tool_changes:
                with _tool_update_lock():
                    # The exclusive tool lock cannot be taken while a sync holds
                    # its shared lock, so a run that started since the check
                    # above keeps the endpoints it read.
                    if _sync_snapshot_active():
                        return jsonify(
                            {"error": _live_tool_conflict(live_tool_changes)}
                        ), 409
                    current = VCFDT_STORE / "current"
                    if current.is_dir():
                        with _patch_tool_endpoints(
                            current, {**stored, **updates}
                        ) as patched_files:
                            _write_settings(updates)
                    else:
                        _write_settings(updates)
            else:
                _write_settings(updates)
            if not snapshot_taken:
                _clear_pending_settings()
            elif deferred:
                _record_pending_settings(deferred, run_id)
            pending = _pending_settings(state, in_flight=snapshot_taken)
    except BlockingIOError:
        return jsonify(
            {"error": "wait for the running sync or tool update to finish"}
        ), 409
    except ToolArchiveError as exc:
        return jsonify({"error": f"could not update tool endpoints: {exc}"}), 409
    except OSError as exc:
        return jsonify({"error": f"could not save settings: {exc}"}), 500
    return jsonify(
        {
            **_settings_doc(),
            **pending,
            "appliedNow": applied_now,
            "patchedFiles": patched_files,
            "saved": True,
        }
    )


@app.post("/api/password")
def update_password():
    body = request.get_json(silent=True) or {}
    current = str(body.get("currentPassword", ""))
    new = body.get("newPassword")
    if not isinstance(new, str) or len(new) < 12:
        return jsonify({"error": "use a new password of at least 12 characters"}), 400
    if len(new) > 1024 or "\n" in new or "\r" in new:
        return jsonify(
            {"error": "the password must be one line and at most 1024 characters"}
        ), 400
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
    registration = _registration_details()
    if (
        not registration["machineId"]
        or registration["machineIdError"]
        or registration["machineIdStatus"] != "confirmed"
    ):
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
                return jsonify(
                    {"error": f"job bus unavailable: {exc}", "components": []}
                ), 502
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
        return jsonify(
            {"error": f"not armed: activation code missing. {ARMING_INSTRUCTIONS}"}
        ), 409
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
