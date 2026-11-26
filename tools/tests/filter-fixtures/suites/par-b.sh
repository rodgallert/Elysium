#!/usr/bin/env bash
echo "$(date +%s%N) start" >>"$RUN_ALL_MARKS.$(basename "$0" .sh)"
sleep 2
echo "$(date +%s%N) end" >>"$RUN_ALL_MARKS.$(basename "$0" .sh)"
echo "par-b done"
