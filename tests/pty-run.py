#!/usr/bin/env python3
"""Run a command on a pseudo-terminal so interactive prompts can be tested.

Usage: pty-run.py [--wait-for MARKER] INPUT COMMAND [ARG...]

INPUT is a Python escaped string typed at the terminal once the command has
produced its first output, so the command is always running by the time the
input arrives. Pass --wait-for to hold the input back until MARKER appears in
the output instead, which pins the input to a specific prompt rather than to
whatever the command printed first. Use \\x04 for end-of-input and \\x03 for an
interrupt. The command's combined output is written to stdout and its exit
status is returned, with 128 + signal for a command killed by a signal.
"""
import os
import pty
import select
import signal
import sys
import time

TIMEOUT_SECONDS = 120
FEED_TRIGGER_SECONDS = 60


def main():
    argv = sys.argv[1:]
    marker = b""
    if argv[:1] == ["--wait-for"]:
        if len(argv) < 2:
            sys.stderr.write("pty-run.py: --wait-for needs a marker\n")
            return 2
        marker = argv[1].encode("utf-8")
        argv = argv[2:]
    if len(argv) < 2:
        sys.stderr.write("usage: pty-run.py [--wait-for MARKER] INPUT COMMAND [ARG...]\n")
        return 2
    feed = argv[0].encode("utf-8").decode("unicode_escape").encode("latin-1")
    command = argv[1:]

    pid, master = pty.fork()
    if pid == 0:
        try:
            os.execvp(command[0], command)
        except OSError:
            pass
        os._exit(127)

    output = bytearray()
    deadline = time.monotonic() + TIMEOUT_SECONDS
    feed_deadline = time.monotonic() + FEED_TRIGGER_SECONDS
    pending_feed = feed
    timed_out = False
    finished = False
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = True
            os.kill(pid, signal.SIGKILL)
            break
        if pending_feed:
            remaining = min(remaining, max(0.05, feed_deadline - time.monotonic()))
        readable, _, _ = select.select([master], [], [], remaining)
        if readable:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                finished = True
            else:
                if chunk:
                    output.extend(chunk)
                else:
                    finished = True
        feed_is_due = bytes(marker) in bytes(output) if marker else bool(output)
        if pending_feed and (feed_is_due or time.monotonic() >= feed_deadline):
            os.write(master, pending_feed)
            pending_feed = b""
        if finished:
            break

    os.close(master)
    _, status = os.waitpid(pid, 0)
    sys.stdout.buffer.write(bytes(output))
    sys.stdout.buffer.flush()
    if timed_out:
        sys.stderr.write("pty-run.py: command did not finish in time\n")
        return 124
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


sys.exit(main())
