#!/usr/bin/env bash
# One probe (O_DIRECT anonymous loading) repetition on a running Cuttlefish device.
# Usage: run_probe.sh <pair> <run_dir>
#   pair: 1B/1B 1B/3B 3B/3B 3B/3B-kor Q1.5/Q1.5 Q1.5/S1.7 1B/G2B 3B/Q3B
# Environment:
#   SERIAL   adb serial of the device       ADB_BIN  adb binary
#   KO       eksm_p.ko built for the guest  ASSETS   directory with models/<file> and apks/probe/{p1,p2}.apk
# Steps: install APKs, stage and hash the models, let P1 import its copy, reboot the guest,
# load both models through the UI, run probe/runner.sh, pull all device output.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
source "$H/lib.sh"
pair="$1"
start_run "$2" run_probe
PKG1=com.example.llama.aichat; PKG2=dev.filipfan.polyengineinfer.mmapasdio
MODEL_FILTER="$(copies_filter)"
export PKG1 PKG2 MODEL_FILTER
M=$ASSETS/models
APK1=$ASSETS/apks/probe/p1.apk; APK2=$ASSETS/apks/probe/p2.apk

# Host model file and the file name each app sees on the device.
case "$pair" in
  1B/1B)     P1M=llama-3.2-1b-instruct-q4_k_m.gguf; P1N=1B.gguf; P2M=llama-3.2-1b-instruct-q4_k_m.gguf; P2N=1B.gguf ;;
  1B/3B)     P1M=llama-3.2-1b-instruct-q4_k_m.gguf; P1N=1B.gguf; P2M=llama-3.2-3b-instruct-q4_k_m.gguf; P2N=3B.gguf ;;
  3B/3B)     P1M=llama-3.2-3b-instruct-q4_k_m.gguf; P1N=3B.gguf; P2M=llama-3.2-3b-instruct-q4_k_m.gguf; P2N=3B.gguf ;;
  3B/3B-kor) P1M=llama-3.2-3b-instruct-q4_k_m.gguf; P1N=3B.gguf; P2M=llama-3.2-Korean-Bllossom-3B-gguf-Q4_K_M.gguf; P2N=3B-Kor.gguf ;;
  Q1.5/Q1.5) P1M=Qwen2.5-1.5B-Instruct-Q4_K_M.gguf; P1N=qwen25-1.5b-instruct-q4_k_m.gguf; P2M=Qwen2.5-1.5B-Instruct-Q4_K_M.gguf; P2N=qwen25-1.5b-instruct-q4_k_m.gguf ;;
  Q1.5/S1.7) P1M=Qwen2.5-1.5B-Instruct-Q4_K_M.gguf; P1N=qwen25-1.5b-instruct-q4_k_m.gguf; P2M=SmolLM2-1.7B-Instruct-Q4_K_M.gguf; P2N=smollm2-1.7b-instruct-q4_k_m.gguf ;;
  1B/G2B)    P1M=llama-3.2-1b-instruct-q4_k_m.gguf; P1N=1B.gguf; P2M=gemma-2-2b-it-Q4_K_M.gguf; P2N=gemma2-2b-it-q4_k_m.gguf ;;
  3B/Q3B)    P1M=llama-3.2-3b-instruct-q4_k_m.gguf; P1N=3B.gguf; P2M=Qwen2.5-3B-Instruct-Q4_K_M.gguf; P2N=qwen25-3b-instruct-q4_k_m.gguf ;;
  *) fail "unknown pair $pair" ;;
esac
log "serial=$SERIAL pair=$pair RD=$RD"

stage_copies
reboot_device
start_logcat
sleep 20
preload_copies
run_runner
finish_run
