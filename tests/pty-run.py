#!/usr/bin/env python3
"""Run a command on a pseudo-terminal so interactive prompts can be tested.

Usage: pty-run.py INPUT COMMAND [ARG...]

INPUT is a Python escaped string written to the terminal before the command
output is collected. Use \\x04 for end-of-input and \\x03 for an interrupt.
The command's combined output is written to stdout and its exit status is
returned, with 128 + signal for a command killed by a signal.
"""
import os
import pty
import select
import signal
import sys
import time

TIMEOUT_SECONDS = 120


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

    if feed:
        os.write(master, feed)

    output = bytearray()
    deadline = time.monotonic() + TIMEOUT_SECONDS
    timed_out = False
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = True
            os.kill(pid, signal.SIGKILL)
            break
        readable, _, _ = select.select([master], [], [], remaining)
        if not readable:
            continue
        try:
            chunk = os.read(master, 4096)
        except OSError:
            break
        if not chunk:
            break
        output.extend(chunk)

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
