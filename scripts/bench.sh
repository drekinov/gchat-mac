#!/bin/zsh
# usage: bench.sh <path to .app> <seconds> [bench flags...]
# Launches through LaunchServices so the window opens and the app is frontmost, then prints only BENCH lines.
app=$1
seconds=$2
shift 2
root=${0:A:h:h}
log=$root/build/bench.log
: > $log
tail -f $log | grep --line-buffered '^BENCH' &
printer=$!
(sleep 4; osascript -e 'tell application id "io.github.drekinov.gchat-mac" to activate' >/dev/null 2>&1) &
open -n -W --stdout $log --stderr $log $app --args --bench $seconds "$@"
sleep 1
kill $printer 2>/dev/null
exit 0
