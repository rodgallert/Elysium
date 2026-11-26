#!/usr/bin/env bash
# Output larger than a pipe buffer, ending at the same moment as its twin.
sleep 1
seq 1 20000 | sed 's/^/big-b-line /'
