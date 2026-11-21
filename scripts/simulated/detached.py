"""Runs a command in a session of its own.

A server started in the background by a script normally belongs to that
script's terminal session, and can be stopped along with it. This gives the
command its own session first, so it keeps running until it is killed.

    python detached.py <command> [arguments]
"""

import os
import sys

os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
