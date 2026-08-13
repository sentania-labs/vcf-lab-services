#!/usr/bin/env python3
"""VCF Services admin console.

The sync container remains the only depot writer. This app reads config and
state files and exchanges jobs with the sync service over the password
protected Redis bus documented in docs/redis-contract.md. It never talks to
the Docker daemon.
"""

import json
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path

import redis as redis_lib
from croniter import croniter
from flask import Flask, jsonify, render_template, request

DEPOT = Path(os.environ.get("DEPOT_DIR", "/depot"))
STATE = Path(os.environ.get("STATE_DIR", "/state"))
SETTINGS = Path(os.environ.get("SETTINGS_FILE", "/config/settings.env"))
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
    next_run = None
    try:
        next_run = croniter(cron, datetime.now(timezone.utc)).get_next(datetime).isoformat()
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
