#!/usr/bin/env bash
# One per-app-copy repetition (1B/1B) on a running Cuttlefish device: each app mmaps its own copy
# of the model, as the unmodified apps do.
# Usage: run_per_app_copy.sh <run_dir>
# Environment:
#   SERIAL   adb serial of the device       ADB_BIN  adb binary
#   KO       eksm_p.ko built for the guest  ASSETS   directory with models/<file> and apks/per-app-copy/{p1,p2}.apk
# Steps: install APKs, stage and hash the models, let P1 import its copy, reboot the guest,
# load both models through the UI, run probe/runner.sh, pull all device output.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
source "$H/lib.sh"
start_run "$1" run_per_app_copy
PKG1=com.example.llama.aichat.a; PKG2=dev.filipfan.polyengineinfer.a
MODEL_FILTER="$(copies_filter)"
export PKG1 PKG2 MODEL_FILTER
M=$ASSETS/models
APK1=$ASSETS/apks/per-app-copy/p1.apk; APK2=$ASSETS/apks/per-app-copy/p2.apk
P1M=llama-3.2-1b-instruct-q4_k_m.gguf; P1N=1B.gguf; P2M=$P1M; P2N=1B.gguf
log "serial=$SERIAL pair=1B/1B RD=$RD"

stage_copies
reboot_device
start_logcat
sleep 20
preload_copies
run_runner
finish_run
