#!/usr/bin/env bash
# Output larger than a pipe buffer, ending at the same moment as its twin.
sleep 1
seq 1 40000 | sed 's/^/big-a-line (a long line so that the output is a few megabytes) /'
