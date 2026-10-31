#!/usr/bin/env bash
# One LoRA (Fig. 3) repetition on a running Cuttlefish device.
# Usage: run_lora.sh <merged|separated> <A/B|C/D|A/C> <run_dir>
#   merged:    each app loads its own merged Q4_K_M model
#   separated: both apps load the base Q4_K_M model (two copies) and apply their adapter at load
# Environment:
#   SERIAL   adb serial of the device       ADB_BIN  adb binary
#   KO       eksm_p.ko built for the guest
#   ASSETS   directory with apks/lora/{p1,p2}.apk and lora/<file> (output of models/build_lora_models.sh)
#   READY_TIMEOUT_SEC  model load timeout (default 300 s)
# Steps: install the APKs, stage and hash the model and adapter files, write the paths the apps read
# at start, reboot the guest, start both apps and wait until their models are loaded, run
# probe/runner.sh (15 prompts per app, memdump, KSM, memdump), pull all device output.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
source "$H/lib.sh"
mode="$1"; pair="$2"
start_run "$3" run_lora
PKG1=com.example.llama.aichat; PKG2=dev.filipfan.polyengineinfer.mmapasdio
MODEL_FILTER="$(copies_filter)"
export PKG1 PKG2 MODEL_FILTER
# Input timing of the LoRA runs (adb_input_delay.sh).
RUNNER_ADB_BIN="$H/adb_input_delay.sh"

declare -A SHA=(
  [base.Q4_K_M.gguf]=178aea71417011d9921b45280e584a63a775d9c6ebabb42e50c92fb7bc03e571
  [merged_A.Q4_K_M.gguf]=59af93b387d457a36380e409fed2987187e707608c231b89036c25f99f6543bd
  [merged_B.Q4_K_M.gguf]=f0d83589af3ed42766b6a10786f8a274e5d31a08445df00579617db5f723f45b
  [merged_C.Q4_K_M.gguf]=0f19a5608dafd2892232c51545eaae8f9c1fc87bad53e1405b5e972732030a5e
  [merged_D.Q4_K_M.gguf]=3b85ef3dd1143c7835ce4c764c90b455bba7b68f06259946c29bbcfa6493707b
  [merged_C_for_AC.Q4_K_M.gguf]=1ee0c41000e9bf66fbe6f1f9107cd59586f1bad2590caacda29c3019bb368e7f
  [adapter_A.gguf]=e275518ea44bbf081e3fb9454d50ca5dc9b0c413ac4b78a11355a3b481f0f506
  [adapter_B.gguf]=78b4d64654bd3c58bd9fe4453f51a30a4a31ee6ba6c57da92e5768905d8ab58e
  [adapter_C.gguf]=c7aed24e25dcaf2f2113d38cf05ac1b8edda49cd0c63ba1d3c031e2c8103c4fd
  [adapter_D.gguf]=e19ac263acce6a5536abe9182b0ae5c5308b79a2ada0c10e35f822858d26d279
)
declare -A ADAPTER=(
  [A]=adapter_A.gguf [B]=adapter_B.gguf
  [C]=adapter_C.gguf [D]=adapter_D.gguf
)
case "$pair" in
  A/B|C/D|A/C) ;;
  *) fail "unknown pair $pair" ;;
esac
case "$mode/$pair" in
  merged/A/B) P1M=merged_A.Q4_K_M.gguf; P2M=merged_B.Q4_K_M.gguf ;;
  merged/C/D) P1M=merged_C.Q4_K_M.gguf; P2M=merged_D.Q4_K_M.gguf ;;
  merged/A/C) P1M=merged_A.Q4_K_M.gguf; P2M=merged_C_for_AC.Q4_K_M.gguf ;;
  separated/*) P1M=base.Q4_K_M.gguf; P2M=$P1M ;;
  *) fail "unknown mode $mode" ;;
esac
P1A=""; P2A=""
if [ "$mode" = separated ]; then
  P1A="${ADAPTER[${pair%/*}]}"; P2A="${ADAPTER[${pair#*/}]}"
fi
L=$ASSETS/lora
APK1=$ASSETS/apks/lora/p1.apk; APK2=$ASSETS/apks/lora/p2.apk
DEV=/data/local/tmp/lora/autoload
CFG=/data/local/tmp/lora_ksm

log "serial=$SERIAL mode=$mode pair=$pair RD=$RD"

# host file, device file
STAGE=("$P1M" "$DEV/p1_model.gguf" "$P2M" "$DEV/p2_model.gguf")
[ -z "$P1A" ] || STAGE+=("$P1A" "$DEV/p1_adapter.gguf" "$P2A" "$DEV/p2_adapter.gguf")
for ((i = 0; i < ${#STAGE[@]}; i += 2)); do check_sha "$L/${STAGE[$i]}" "${SHA[${STAGE[$i]}]}"; done
sha256sum "$APK1" "$APK2" > "$RD/host/host_inputs.sha256"
for ((i = 0; i < ${#STAGE[@]}; i += 2)); do sha256sum "$L/${STAGE[$i]}"; done >> "$RD/host/host_inputs.sha256"
log "P1 model $P1M adapter ${P1A:-none}; P2 model $P2M adapter ${P2A:-none}"

prepare_device

"${ADB[@]}" install -r -d -g "$APK1" || fail "install p1"
"${ADB[@]}" install -r -d -g "$APK2" || fail "install p2"

# Every file is pushed again and checked on the device, so no file of an earlier pair is reused.
"${ADB[@]}" shell "rm -rf '$DEV' && mkdir -p '$DEV' '$CFG/llama' '$CFG/poly'" || fail "prepare device dirs"
for ((i = 0; i < ${#STAGE[@]}; i += 2)); do
  "${ADB[@]}" push "$L/${STAGE[$i]}" "${STAGE[$((i + 1))]}" || fail "push ${STAGE[$i]}"
done
put(){ printf '%s\n' "$1" | "${ADB[@]}" shell "cat > '$2'"; }
put "$DEV/p1_model.gguf" "$CFG/llama/model_path.txt"
put "$DEV/p2_model.gguf" "$CFG/poly/model_path.txt"
put "${P1A:+$DEV/p1_adapter.gguf}" "$CFG/llama/adapter_path.txt"
put "${P2A:+$DEV/p2_adapter.gguf}" "$CFG/poly/adapter_path.txt"
"${ADB[@]}" shell "chmod -R a+rX /data/local/tmp/lora '$CFG'" || fail "chmod"
"${ADB[@]}" shell "for f in $CFG/*/*.txt; do echo \"\$f: \$(cat \$f)\"; done" | tr -d '\r' > "$RD/device/path_files.txt"
cat "$RD/device/path_files.txt"

devfiles=""
for ((i = 1; i < ${#STAGE[@]}; i += 2)); do devfiles+=" ${STAGE[$i]}"; done
"${ADB[@]}" shell "sha256sum$devfiles" | tr -d '\r' > "$RD/device/device_inputs.sha256" || fail "device sha"
for ((i = 0; i < ${#STAGE[@]}; i += 2)); do
  d="${STAGE[$((i + 1))]}"
  grep -qx "${SHA[${STAGE[$i]}]}  $d" "$RD/device/device_inputs.sha256" || fail "device $d sha256 mismatch"
done

reboot_device
sleep 20
wake

# Start P1 (it loads its model when resumed), then P2; wait for P2, bring P1 back and wait for it.
launch(){
  local act
  act="$("${ADB[@]}" shell "cmd package resolve-activity --brief '$1' | tail -n 1" | tr -d '\r')"
  case "$act" in */*) "${ADB[@]}" shell "am start -n '$act'" >/dev/null ;; *) fail "no launcher activity for $1" ;; esac
  for _ in $(seq 1 30); do
    [ -n "$("${ADB[@]}" shell pidof "$1" | tr -d '\r')" ] && return 0
    sleep 1
  done
  fail "$1 not started"
}
wait_log(){
  local what="$1" pattern="$2" t=0
  until "${ADB[@]}" logcat -d | grep -qE "$pattern"; do
    "${ADB[@]}" logcat -d | grep -qF '[LORA_KSM] failed to load LoRA adapter' && fail "$what: adapter load failed"
    [ "$t" -lt "${READY_TIMEOUT_SEC:-300}" ] || fail "$what: not loaded after ${t}s"
    sleep 3; t=$((t + 3))
  done
  log "$what loaded after ${t}s"
  sleep 8
}
"${ADB[@]}" shell "am force-stop $PKG1; am force-stop $PKG2"
"${ADB[@]}" logcat -c
launch "$PKG1"
launch "$PKG2"
if [ -n "$P2A" ]; then
  wait_log "P2 model and adapter" 'Poly loaded model with LoRA adapter'
else
  wait_log "P2 model" 'Loaded model without LoRA adapter'
fi
launch "$PKG1"
[ -z "$P1A" ] || wait_log "P1 adapter" 'LoRA adapter loaded: '
wait_log "P1 model" 'Llama auto-load complete and UI is ready'
"${ADB[@]}" logcat -d > "$RD/device/logcat_load.txt" 2>&1 || true
"${ADB[@]}" shell "pidof $PKG1; pidof $PKG2" > "$RD/device/preload_pids.txt"

run_runner
finish_run
