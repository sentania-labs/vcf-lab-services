"""Gunicorn hooks for the admin console.

Gunicorn loads this file from the working directory on its own. The one hook
starts the bounded identity verification in app.py, so a tool release whose
Software Depot ID is not verified yet (after an appliance upgrade, an
identity file changed outside the console, or a failed install-time probe)
is verified once in the background and never on a request.
"""


def post_worker_init(worker):
    import app as console

    console.verify_identity_on_start()
