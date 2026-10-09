#!/bin/bash
# The averages from a perf-test.sh log, one line each: test, metric, average, values.
#   scripts/perf-summary.sh <log>
awk '
  /Test Case .* started/ { match($0, /PerformanceTour [a-zA-Z]+/); t = substr($0, RSTART + 16, RLENGTH - 16) }
  /measured \[/ {
    m = $0; sub(/.*measured \[/, "", m); name = m; sub(/\].*/, "", name)
    avg = m; sub(/.*average: /, "", avg); sub(/,.*/, "", avg)
    printf "%-32s %-58s %s\n", t, name, avg
  }
  /Test Case .* (failed|skipped)/ { print }
' "$1"
