"""Gunicorn hooks for the admin console.

Gunicorn loads this file from the working directory on its own. The worker
hook starts the identity verification in app.py, so a tool release whose
Software Depot ID is not verified yet (after an appliance upgrade, an
identity file changed outside the console, or a failed install-time probe)
is verified once in the background and never on a request. The master
records its start time first, and every worker inherits it, so the workers
share one attempt per appliance start.
"""

import os
from datetime import datetime, timezone


def on_starting(server):
    os.environ["VCF_UI_STARTED_AT"] = datetime.now(timezone.utc).isoformat()


def post_worker_init(worker):
    import app as console

    console.verify_identity_on_start()
