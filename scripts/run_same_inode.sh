#!/usr/bin/env bash
# One same-inode repetition (1B/1B) on a running Cuttlefish device. Both apps mmap
# /data/local/tmp/model.gguf, so they map one inode. Sets SELinux permissive.
# Usage: run_same_inode.sh <run_dir>
# Environment: SERIAL, ADB_BIN, KO, ASSETS (models/llama-3.2-1b-instruct-q4_k_m.gguf, apks/same-inode/{p1,p2}.apk)
# Steps: install APKs, push and hash the model, reboot the guest, start both apps and check that they
# map the model, run probe/runner.sh, pull all device output.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
source "$H/lib.sh"
start_run "$1" run_same_inode
PKG1=com.example.llama.hard; PKG2=dev.filipfan.polyengineinfer.hard
MODEL_FILTER='/data/local/tmp/model\.gguf|/data/local/tmp|gguf|/data/local/tmp/model.gguf'
export PKG1 PKG2 MODEL_FILTER
MODEL=llama-3.2-1b-instruct-q4_k_m.gguf
HM=$ASSETS/models/$MODEL
DM=/data/local/tmp/model.gguf
APK1=$ASSETS/apks/same-inode/p1.apk; APK2=$ASSETS/apks/same-inode/p2.apk
log "serial=$SERIAL pair=1B/1B RD=$RD"

# The apps open /data/local/tmp/model.gguf only with SELinux permissive (not kept across reboots).
permissive(){
  "${ADB[@]}" shell setenforce 0 || fail "setenforce 0"
  "${ADB[@]}" shell getenforce | tr -d '\r' > "$RD/device/selinux.txt"
  [ "$(cat "$RD/device/selinux.txt")" = Permissive ] || fail "SELinux is not permissive"
}

# Start an app (it loads the model at start) and check that it maps the model file.
start_app(){
  local pkg="$1" pid=""
  "${ADB[@]}" shell am force-stop "$pkg" >/dev/null 2>&1 || true
  timeout 20s "${ADB[@]}" shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 || true
  for _ in $(seq 1 60); do
    pid="$("${ADB[@]}" shell pidof "$pkg" 2>/dev/null | tr -d '\r' | awk '{print $1}' || true)"
    [ -n "$pid" ] && break
    sleep 1
  done
  [ -n "$pid" ] || fail "$pkg not started"
  log "$pkg pid=$pid"
  sleep 8
  for _ in $(seq 1 60); do
    if "${ADB[@]}" shell "grep -F '$DM' /proc/$pid/maps" > "$RD/device/model_maps_$pkg.txt" 2>&1; then
      log "$pkg maps $DM"
      return 0
    fi
    sleep 2
  done
  fail "$pkg does not map $DM"
}

check_sha "$HM" "${MODEL_SHA[$MODEL]}"
sha256sum "$APK1" "$APK2" "$HM" > "$RD/host/host_inputs.sha256"
prepare_device
permissive
"${ADB[@]}" install -r -g "$APK1" || fail "install p1"
"${ADB[@]}" install -r -g "$APK2" || fail "install p2"
"${ADB[@]}" push "$HM" "$DM" || fail "push model"
"${ADB[@]}" shell chmod 644 "$DM" || fail "chmod model"
"${ADB[@]}" shell "sha256sum $DM; ls -liZ $DM; df -k /data" > "$RD/device/device_models.sha256" 2>&1 || fail "device sha"
[ "$(head -n1 "$RD/device/device_models.sha256" | awk '{print $1}')" = "${MODEL_SHA[$MODEL]}" ] || fail "device model sha256 mismatch"

reboot_device
wake
start_logcat
sleep 20
# These apps load the fixed path themselves (no file picker).
date +%s > "$RD/host/preload_done_epoch.txt"
permissive
"${ADB[@]}" logcat -c
start_app "$PKG1"
start_app "$PKG2"
"${ADB[@]}" shell "pidof $PKG1; pidof $PKG2" > "$RD/device/preload_pids.txt"
run_runner
finish_run
