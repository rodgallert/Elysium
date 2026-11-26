#!/usr/bin/env bash
# A suite with a background child that ignores TERM and a slow cleanup trap, as the edge suite has (#126-AC2.4).
echo "cleanup suite: started"
trap 'echo cleanup-start >>"$RUN_ALL_MARKS.cleanup"; sleep 8; kill -9 "$child"; echo cleanup-end >>"$RUN_ALL_MARKS.cleanup"; exit 143' TERM
(trap "" TERM; exec sleep 62.33) &
child=$!
wait
