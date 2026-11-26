#!/usr/bin/env bash
echo "$(date +%s%N) start" >>"$RUN_ALL_MARKS.edge"
sleep 1
echo "$(date +%s%N) end" >>"$RUN_ALL_MARKS.edge"
echo "edge suite done"
