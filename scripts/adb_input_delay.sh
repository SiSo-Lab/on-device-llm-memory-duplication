#!/usr/bin/env bash
# adb wrapper used by run_lora.sh as ADB_BIN for probe/runner.sh: waits 2.0 s after "input text",
# 0.45 s before and 0.6 s after "input tap". Every other call goes straight to REAL_ADB_BIN.
set -uo pipefail
: "${REAL_ADB_BIN:?}"
args=("$@")
cmd=""
for i in "${!args[@]}"; do
  if [ "${args[$i]}" = shell ]; then
    cmd="${args[*]:$((i + 1))}"
    break
  fi
done
case "$cmd" in
  "input text "*)
    "$REAL_ADB_BIN" "$@"; rc=$?
    sleep 2.0
    exit "$rc" ;;
  "input tap "*)
    sleep 0.45
    "$REAL_ADB_BIN" "$@"; rc=$?
    sleep 0.6
    exit "$rc" ;;
esac
exec "$REAL_ADB_BIN" "$@"
