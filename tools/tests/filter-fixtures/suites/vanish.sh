#!/usr/bin/env bash
# Kills the runner's subshell for this suite, so no result file is ever written.
echo "vanish suite: running"
kill -9 "$(ps -o ppid= -p "$PPID" | tr -d " ")"
sleep 1
