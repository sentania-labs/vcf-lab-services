#!/usr/bin/env python3
"""Run a command on a pseudo-terminal so interactive prompts can be tested.

Usage: pty-run.py INPUT COMMAND [ARG...]

INPUT is a Python escaped string typed at the terminal once the command has
produced its first output, so the command is always running by the time the
input arrives. Use \\x04 for end-of-input and \\x03 for an interrupt. The
command's combined output is written to stdout and its exit status is returned,
with 128 + signal for a command killed by a signal.
"""
import os
import pty
import select
import signal
import sys
import time

TIMEOUT_SECONDS = 120
FIRST_OUTPUT_SECONDS = 60


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: pty-run.py INPUT COMMAND [ARG...]\n")
        return 2
    feed = sys.argv[1].encode("utf-8").decode("unicode_escape").encode("latin-1")
    command = sys.argv[2:]

    pid, master = pty.fork()
    if pid == 0:
        try:
            os.execvp(command[0], command)
        except OSError:
            pass
        os._exit(127)

    output = bytearray()
    deadline = time.monotonic() + TIMEOUT_SECONDS
    first_output_deadline = time.monotonic() + FIRST_OUTPUT_SECONDS
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
            remaining = min(remaining, max(0.05, first_output_deadline - time.monotonic()))
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
        if pending_feed and (output or time.monotonic() >= first_output_deadline):
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
