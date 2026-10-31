# Sourced by the run_*.sh scripts (which set H to the scripts directory): run directory and log,
# device preparation, reboot, host logcat, the runner call and the final pull and checks.
: "${SERIAL:?}" "${ADB_BIN:?}" "${KO:?}" "${ASSETS:?}"
export SERIAL ADB_BIN KO
ADB=("$ADB_BIN" -s "$SERIAL")
LOGCAT_PIDS=()
declare -A MODEL_SHA=(
  [llama-3.2-1b-instruct-q4_k_m.gguf]=1d0e9419ec4e12aef73ccf4ffd122703e94c48344a96bc7c5f0f2772c2152ce3
  [llama-3.2-3b-instruct-q4_k_m.gguf]=c55a83bfb6396799337853ca69918a0b9bbb2917621078c34570bc17d20fd7a1
  [llama-3.2-Korean-Bllossom-3B-gguf-Q4_K_M.gguf]=389f380bbfbe77d9171937b3d166a26ccc3e04201f3d9fb0ca1b5e01b6787621
  [gemma-2-2b-it-Q4_K_M.gguf]=e0aee85060f168f0f2d8473d7ea41ce2f3230c1bc1374847505ea599288a7787
  [Qwen2.5-1.5B-Instruct-Q4_K_M.gguf]=1adf0b11065d8ad2e8123ea110d1ec956dab4ab038eab665614adba04b6c3370
  [Qwen2.5-3B-Instruct-Q4_K_M.gguf]=9c9f56a391a3abbd5b89d0245bf6106081bcc3173119d4229235dd9d23253f94
  [SmolLM2-1.7B-Instruct-Q4_K_M.gguf]=77665ea4815999596525c636fbeb56ba8b080b46ae85efef4f0d986a139834d7
)

log(){ echo "[rep][$(date '+%F %T')] $*"; }
fail(){
  log "FAILED: $*"; echo "FAILED: $*" > "$RD/STATUS"
  local p; for p in "${LOGCAT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  exit 1
}

# start_run <run_dir> <log name>: new run directory, log of this script in host/<log name>.log.
start_run(){
  RD="$1"
  [ -z "$(ls -A "$RD" 2>/dev/null)" ] || { echo "run_dir is not empty: $RD (use a new run_dir)" >&2; exit 2; }
  mkdir -p "$RD/host" "$RD/device"
  RD="$(cd "$RD" && pwd)"
  exec > >(tee -a "$RD/host/$2.log") 2>&1
  echo RUNNING > "$RD/STATUS"
}

check_sha(){ [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ] || fail "$1 sha256 mismatch"; }

# Model filter of the builds that load from app storage: the private and external model
# directories of both packages, any path containing gguf, and /data/media/0.
copies_filter(){
  local e1 e2
  e1="$(printf '%s' "$PKG1" | sed -e 's/[.[\*^$()+?{|]/\\&/g')"
  e2="$(printf '%s' "$PKG2" | sed -e 's/[.[\*^$()+?{|]/\\&/g')"
  printf '%s' "/data/data/${e1}/files/models|/data/user/0/${e1}/files/models|/mnt/expand/.*/user/0/${e1}/files/models|/sdcard/Android/data/${e1}/files/models|/data/data/${e2}/files/models|/data/user/0/${e2}/files/models|/mnt/expand/.*/user/0/${e2}/files/models|/sdcard/Android/data/${e2}/files/models|gguf|/sdcard/Download/models|/data/media/0|llm_real_storage"
}

adb_root(){
  "${ADB[@]}" root >/dev/null 2>&1 || true; sleep 3; "$ADB_BIN" connect "$SERIAL" >/dev/null 2>&1 || true
  timeout 60 "${ADB[@]}" wait-for-device
}

# Stop the Cuttlefish instance of GOOD_HOME; nothing to stop is not an error.
stop_vm(){ HOME="$GOOD_HOME" "$GOOD_HOME/bin/stop_cvd" || true; }

# New device for a run: stop any instance, delete the instance, assembly, tmp and userdata files of
# boot_cuttlefish.sh, start it in the background (output in $FRESH/boot.log), wait until Android has
# booted and connect as root. Needs GOOD_HOME and SYSTEM_IMAGE_DIR; FRESH, BASE_NUM as in boot_cuttlefish.sh.
fresh_vm(){
  : "${GOOD_HOME:?directory prepared by setup_cuttlefish.sh}" "${SYSTEM_IMAGE_DIR:?image directory prepared by setup_cuttlefish.sh}"
  export GOOD_HOME SYSTEM_IMAGE_DIR FRESH="${FRESH:-$PWD/cf-run}"
  local pid t0
  stop_vm >/dev/null 2>&1
  "$ADB_BIN" disconnect "$SERIAL" >/dev/null 2>&1 || true
  rm -rf "${INSTANCE_DIR:-$FRESH/cuttlefish}" "${ASSEMBLY_DIR:-$FRESH/cuttlefish_assembly}" \
    "${TMPDIR_HOST:-$FRESH/tmp}" "${DATA_IMG:-$FRESH/userdata.img}" "$FRESH/boot.log"
  mkdir -p "$FRESH"
  setsid -w bash "$H/boot_cuttlefish.sh" > "$FRESH/boot.log" 2>&1 < /dev/null &
  pid=$!
  log "boot_cuttlefish.sh started (pid $pid, output in $FRESH/boot.log)"
  t0=$(date +%s)
  until [[ "$("$ADB_BIN" connect "$SERIAL" 2>&1)" == *"connected to"* ]] &&
    [ "$(timeout 10 "${ADB[@]}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
    kill -0 "$pid" 2>/dev/null || fail "boot_cuttlefish.sh exited (see $FRESH/boot.log)"
    [ $(( $(date +%s) - t0 )) -lt 600 ] || fail "boot timeout (see $FRESH/boot.log)"
    sleep 5
  done
  log "booted after $(( $(date +%s) - t0 )) s"
  adb_root || fail "adb root after boot"
}

current_user(){ "${ADB[@]}" shell am get-current-user | tr -d '\r'; }

# Connect as root, record the guest, switch to Android user 0.
prepare_device(){
  "$ADB_BIN" connect "$SERIAL" >/dev/null 2>&1 || true
  timeout 60 "${ADB[@]}" wait-for-device || fail "device not reachable"
  adb_root
  "${ADB[@]}" shell 'uname -a; getprop ro.build.fingerprint; cat /proc/cmdline' > "$RD/device/guest_info.txt" 2>&1 || true
  if [ "$(current_user)" != 0 ]; then
    "${ADB[@]}" shell am switch-user 0 >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do [ "$(current_user)" = 0 ] && break; sleep 2; done
    [ "$(current_user)" = 0 ] || fail "switch to user 0"
    sleep 8
  fi
}

# Reboot: empty page cache and KSM state; the staged files stay on /data.
reboot_device(){
  "${ADB[@]}" reboot || true
  sleep 8
  local t0; t0=$(date +%s)
  until [ "$(timeout 10 "${ADB[@]}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
    "$ADB_BIN" connect "$SERIAL" >/dev/null 2>&1 || true
    [ $(( $(date +%s) - t0 )) -lt 600 ] || fail "reboot timeout"
    sleep 3
  done
  adb_root
  "${ADB[@]}" shell 'cat /proc/uptime; for f in run pages_scanned pages_shared pages_sharing full_scans; do echo $f=$(cat /sys/kernel/mm/ksm/$f); done' > "$RD/device/after_reboot_ksm.txt"
  "${ADB[@]}" shell getenforce > "$RD/device/selinux.txt" 2>&1 || true
}

wake(){ "${ADB[@]}" shell 'svc power stayon true; input keyevent 224; wm dismiss-keyguard' >/dev/null 2>&1 || true; }

# Host-side logcat, read by warmup_check.py; not used for the memory values.
start_logcat(){
  "${ADB[@]}" shell 'date +%z' | tr -d '\r' | sed 's/^/device_tz=/' > "$RD/host/device_clock.txt"
  echo "device_epoch=$("${ADB[@]}" shell date +%s | tr -d '\r') host_epoch=$(date +%s)" >> "$RD/host/device_clock.txt"
  "${ADB[@]}" logcat -v threadtime -b events,crash > "$RD/host/logcat_events.txt" 2>&1 &
  LOGCAT_PIDS+=($!)
  "${ADB[@]}" logcat -v threadtime -b main,system 'lmkd:V' 'ActivityManager:I' 'MainActivity:V' 'InferenceEngineImpl:V' 'LLamaAndroid:V' 'llama-android.cpp:V' 'ai-chat:V' '*:S' > "$RD/host/logcat_app.txt" 2>&1 &
  LOGCAT_PIDS+=($!)
}

# Stage one model copy per app (probe, per-app-copy). Needs M, P1M, P1N, P2M, P2N, APK1, APK2.
# P1 reads /sdcard/model and copies the file into its private storage on import;
# P2 reads its external files directory.
stage_copies(){
  local m d f uid2 keep dsha
  for m in "$P1M" "$P2M"; do check_sha "$M/$m" "${MODEL_SHA[$m]}"; done
  { sha256sum "$APK1" "$APK2"; sha256sum "$M/$P1M"; [ "$P2M" = "$P1M" ] || sha256sum "$M/$P2M"; } > "$RD/host/host_inputs.sha256"
  P1_PRIV="$(python3 "$H/gguf_name.py" "$M/$P1M")" || fail "gguf name of $P1M"
  log "P1 model $P1M -> /sdcard/model/$P1N (app private name $P1_PRIV); P2 model $P2M -> $PKG2 files/models/$P2N"
  prepare_device
  "${ADB[@]}" install -r -g "$APK1" || fail "install p1"
  "${ADB[@]}" install -r -g "$APK2" || fail "install p2"
  uid2="$("${ADB[@]}" shell pm list packages -U --user 0 "$PKG2" | tr -d '\r' | sed -n "s/^package:$PKG2 uid://p")"
  case "$uid2" in ''|*[!0-9]*) fail "uid of $PKG2 not a single number: '$uid2'" ;; esac
  # Remove model files left by other pairs.
  keep=" $P1N $P2N $P1_PRIV "
  for d in /data/media/0/model "/data/media/0/Android/data/$PKG2/files/models" "/data/data/$PKG1/files/models"; do
    for f in $("${ADB[@]}" shell "ls '$d' 2>/dev/null" | tr -d '\r'); do
      case "$keep" in *" $f "*) ;; *) log "remove old model $d/$f"; "${ADB[@]}" shell "rm -f '$d/$f'" ;; esac
    done
  done
  "${ADB[@]}" shell 'df -k /data' > "$RD/device/df_data_before_staging.txt" 2>&1 || true
  "${ADB[@]}" shell 'mkdir -p /data/media/0/model' || fail mkdir
  "${ADB[@]}" push "$M/$P1M" "/data/media/0/model/$P1N" || fail "push p1 model"
  "${ADB[@]}" shell "mkdir -p /data/media/0/Android/data/$PKG2/files/models" || fail mkdir2
  "${ADB[@]}" push "$M/$P2M" "/data/media/0/Android/data/$PKG2/files/models/$P2N" || fail "push p2 model"
  "${ADB[@]}" shell "chown -R $uid2:1078 /data/media/0/Android/data/$PKG2 && chmod 2770 /data/media/0/Android/data/$PKG2 /data/media/0/Android/data/$PKG2/files /data/media/0/Android/data/$PKG2/files/models && chmod 660 /data/media/0/Android/data/$PKG2/files/models/$P2N && chown 1023:1023 /data/media/0/model/$P1N && chmod 664 /data/media/0/model/$P1N" || fail "chown p2"
  bash "$H/preload.sh" p1import "$P1N" || fail "p1 import"
  "${ADB[@]}" shell "ls -l /data/data/$PKG1/files/models/" | tee "$RD/device/p1_private_models.txt"
  grep -qF "$P1_PRIV" "$RD/device/p1_private_models.txt" || fail "p1 private copy name mismatch"
  "${ADB[@]}" shell "sha256sum /data/media/0/model/$P1N '/data/data/$PKG1/files/models/$P1_PRIV' /data/media/0/Android/data/$PKG2/files/models/$P2N" > "$RD/device/device_models.sha256" || fail "device sha"
  mapfile -t dsha < <(awk '{print $1}' "$RD/device/device_models.sha256")
  [ "${dsha[0]:-}" = "${MODEL_SHA[$P1M]}" ] && [ "${dsha[1]:-}" = "${MODEL_SHA[$P1M]}" ] && [ "${dsha[2]:-}" = "${MODEL_SHA[$P2M]}" ] || fail "device model sha256 mismatch"
  "${ADB[@]}" shell 'df -k /data' > "$RD/device/df_data_after_staging.txt" 2>&1 || true
}

# After the reboot: load both models through the UI (P2 first).
preload_copies(){
  bash "$H/preload.sh" p2 "$P2N" || fail "p2 preload"
  bash "$H/preload.sh" p1 "$P1N" || fail "p1 preload"
  "${ADB[@]}" shell "pidof $PKG1; pidof $PKG2" > "$RD/device/preload_pids.txt"
  date +%s > "$RD/host/preload_done_epoch.txt"
}

# probe/runner.sh with PKG1, PKG2, MODEL_FILTER; RUNNER_ADB_BIN, if set, replaces ADB_BIN for the runner.
run_runner(){
  local p ok=1
  "${ADB[@]}" shell 'rm -rf /data/local/tmp/eksm_memdump' || fail "remove old memdump"
  log "runner start"
  set +e
  REAL_ADB_BIN="$ADB_BIN" ADB_BIN="${RUNNER_ADB_BIN:-$ADB_BIN}" bash "$H/probe/runner.sh" > "$RD/host/runner_stdout.log" 2>&1
  RC=$?
  set -e
  log "runner rc=$RC"
  if [ ${#LOGCAT_PIDS[@]} -gt 0 ]; then
    for p in "${LOGCAT_PIDS[@]}"; do kill -0 "$p" 2>/dev/null || ok=0; kill "$p" 2>/dev/null || true; done
    LOGCAT_PIDS=()
    echo "logcat_streams_alive_at_end=$ok" > "$RD/host/logcat_streams.txt"
    [ "$ok" = 1 ] || log "WARN logcat stream lost; warm-up check incomplete"
  fi
}

# Record the end state, pull the memory dumps, check them against the device and the run's output.
finish_run(){
  local n_dumps
  "${ADB[@]}" shell 'for f in /sys/kernel/mm/ksm/*; do [ -f "$f" ] && echo "$(basename $f)=$(cat $f)"; done' > "$RD/device/ksm_sysfs_final.txt" 2>&1 || true
  "${ADB[@]}" shell "for p in \$(pidof $PKG1) \$(pidof $PKG2); do echo == \$p; cat /proc/\$p/smaps_rollup; cat /proc/\$p/ksm_stat 2>/dev/null; cat /proc/\$p/ksm_merging_pages 2>/dev/null; done" > "$RD/device/smaps_rollup_end.txt" 2>&1 || true
  "${ADB[@]}" shell dmesg > "$RD/device/dmesg.txt" 2>&1 || true
  "${ADB[@]}" logcat -d -b all > "$RD/device/logcat_all.txt" 2>&1 || true
  "${ADB[@]}" shell 'ps -A -o PID,PPID,RSS,NAME' > "$RD/device/ps.txt" 2>&1 || true
  "${ADB[@]}" shell 'cat /proc/meminfo; cat /proc/vmstat' > "$RD/device/meminfo_vmstat_end.txt" 2>&1 || true
  "${ADB[@]}" pull /data/local/tmp/eksm_memdump "$RD/device/" || fail "pull eksm_memdump"
  "${ADB[@]}" shell 'cd /data/local/tmp/eksm_memdump && find . -type f -exec sha256sum {} \;' | tr -d '\r' | sort -k2 > "$RD/host/device_eksm_memdump.sha256"
  ( cd "$RD/device/eksm_memdump" && find . -type f -exec sha256sum {} \; ) | sort -k2 > "$RD/host/pulled_eksm_memdump.sha256"
  diff -q "$RD/host/pulled_eksm_memdump.sha256" "$RD/host/device_eksm_memdump.sha256" >/dev/null || fail "pulled files differ from device"
  n_dumps=$(ls "$RD/device/eksm_memdump" | wc -l)
  ( cd "$RD" && find . -type f ! -name FILES.sha256 -printf '%s\t%p\n' | sort -k2 > FILES.sizes && find . -type f ! -name FILES.sha256 ! -name FILES.sizes -exec sha256sum {} \; | sort -k2 > FILES.sha256 )
  log "pulled: memdump dirs=$n_dumps"
  [ "$RC" = 0 ] || fail "runner rc=$RC"
  [ "$n_dumps" -ge 2 ] || fail "expected 2 memdump dirs, got $n_dumps"
  grep -q 'CONCLUSION shared=' "$RD/host/runner_stdout.log" || fail "no KSM CONCLUSION"
  grep -qE 'eksm-p: PASS_DONE .*tasks_applied\(at_least_1_vma\)=2 ' "$RD/device/dmesg.txt" || fail "eksm_p did not mark both apps (device/dmesg.txt)"
  echo PULLED_OK > "$RD/STATUS"
  log "done"
}
