#!/usr/bin/env python3
"""VCF Services admin console.

The sync container remains the only depot writer. This app reads config and
state files, then triggers selected runs through a restricted Docker API proxy.
"""

import json
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path

import docker
from croniter import croniter
from flask import Flask, jsonify, render_template, request

SYNC_CONTAINER = os.environ.get("SYNC_CONTAINER", "vcf-services-sync")
DEPOT = Path(os.environ.get("DEPOT_DIR", "/depot"))
STATE = Path(os.environ.get("STATE_DIR", "/state"))
SETTINGS = Path(os.environ.get("SETTINGS_FILE", "/config/settings.env"))
VCFDT = "/opt/vcfdt/bin/vcf-download-tool"
AUTH_FILE = "/run/secrets/activation-code.txt"
VALID_TARGETS = ["esx", "install", "upgrade", "patches", "vkr"]
BUILD_RE = re.compile(r"\b(2[0-9]{7})\b")
ARMING_INSTRUCTIONS = (
    "Register the Software Depot ID in the Broadcom download tool registration "
    "flow, then rerun install.sh with the activation code."
)

app = Flask(__name__)
_remote_cache = {"ts": 0.0, "rows": None}
_local_cache = {"ts": 0.0, "builds": None}


def _client():
    return docker.from_env()


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


def _fetch_remote():
    state = _state()
    if not state.get("armed", False):
        raise RuntimeError(f"not armed: activation code missing. {ARMING_INSTRUCTIONS}")
    settings = _settings()
    version = settings.get("VCF_VERSION", "9.1.0")
    container = _client().containers.get(SYNC_CONTAINER)
    result = container.exec_run(
        [
            VCFDT,
            "binaries",
            "list",
            f"--vcf-version={version}",
            "--type=UPGRADE",
            f"--depot-download-activation-code-file={AUTH_FILE}",
            "--ceip=DISABLE",
        ],
        workdir="/opt/vcfdt",
    )
    output = result.output
    text = output.decode(errors="replace") if isinstance(output, bytes) else str(output)
    if result.exit_code:
        raise RuntimeError(f"VCFDT exited with status {result.exit_code}")
    return _parse_binaries(text)


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
    try:
        lines = (STATE / "latest.log").read_text(errors="replace").splitlines()[-500:]
    except OSError:
        lines = []
    return jsonify({"log": "\n".join(lines)})


@app.get("/api/versions/local")
def versions_local():
    return jsonify({"builds": sorted(_scan_local_builds(), reverse=True)})


@app.get("/api/versions/remote")
def versions_remote():
    now = time.time()
    if (
        request.args.get("refresh") == "1"
        or _remote_cache["rows"] is None
        or now - _remote_cache["ts"] > 900
    ):
        try:
            _remote_cache.update(ts=now, rows=_fetch_remote())
        except (docker.errors.DockerException, RuntimeError) as exc:
            return jsonify({"error": str(exc), "components": []}), 502
    local = _scan_local_builds()
    rows = [{**row, "present": row.get("build") in local} for row in _remote_cache["rows"]]
    return jsonify({"components": rows, "fetchedAt": _remote_cache["ts"]})


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
        container = _client().containers.get(SYNC_CONTAINER)
        container.exec_run(["/usr/local/bin/sync.sh", *targets], detach=True)
    except docker.errors.DockerException as exc:
        return jsonify({"error": f"could not start sync: {exc}"}), 502
    return jsonify({"triggered": True, "targets": targets}), 202


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
