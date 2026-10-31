#!/usr/bin/env bash
# Prompts and measurement of one repetition, for every condition. Expects both apps to be running
# with their models loaded. P1 then P2 each receive 15 prompts, then memdump (before KSM),
# ksm (mark both PIDs, observe until stable), memdump (after KSM).
# Environment (set by the run_*.sh scripts): SERIAL, ADB_BIN, KO, PKG1, PKG2, MODEL_FILTER.
set -euo pipefail
: "${SERIAL:?}" "${ADB_BIN:?}" "${KO:?}" "${PKG1:?}" "${PKG2:?}" "${MODEL_FILTER:?}"
export SERIAL ADB_BIN KO PKG1 PKG2 MODEL_FILTER
H="$(cd "$(dirname "$0")" && pwd)"
ADB=("$ADB_BIN" -s "$SERIAL")

MIN_WAIT_BEFORE_UI_CHECK_SEC=60
UI_POLL_SEC=2
UI_READY_STABLE_SEC=12
UI_READY_TIMEOUT_SEC=900
NEXT_QUESTION_DELAY_SEC=10

PROMPTS_P1=(
  "Explain artificial intelligence and machine learning difference"
  "Explain neural network layer activation and training flow"
  "Describe transformer attention and positional encoding clearly"
  "Explain what context window means in llama models"
  "Compare mmap loading and direct io loading in simple terms"
  "Explain virtual memory paging and page tables"
  "Explain copy on write with fork example"
  "Describe Linux page cache and file backed mapping"
  "Explain anonymous memory and file backed memory difference"
  "Explain KSM and how page deduplication works"
  "Compare process and thread in operating systems"
  "Explain mutex semaphore and spinlock difference"
  "Explain Linux scheduler and context switching cost"
  "Describe filesystem inode and VFS path"
  "Explain why identical models may not share memory automatically"
)
PROMPTS_P2=(
  "Explain direct memory access and why it matters"
  "Describe how large language model weights are loaded"
  "Explain allocator fragmentation and memory overhead"
  "Compare anonymous pages and shared clean pages"
  "Explain what PSS RSS and private dirty mean"
  "Describe why KSM works on anonymous pages"
  "Explain mmap populate and page cache warming"
  "Explain buffered io mmap and direct io differences"
  "Describe how Android app sandbox affects model sharing"
  "Explain why inode difference matters for page cache sharing"
  "Explain scudo allocator and secondary region simply"
  "Describe model weights kv cache and runtime buffer difference"
  "Explain page fault handling in Linux step by step"
  "Compare static model pages and dynamic inference pages"
  "Explain why two apps with same model can still have different memory layout"
)

log(){ echo "[HOST][$(date '+%F %T')] $*"; }

require_alive(){
  local pid
  pid="$("${ADB[@]}" shell pidof "$1" 2>/dev/null | tr -d '\r' || true)"
  [ -n "$pid" ] || { log "[ERR] $2 process is not alive: $1"; exit 1; }
  log "[OK] $2 alive (pid=$pid)"
}

dump_ui_xml(){
  "${ADB[@]}" shell 'uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1 && cat /sdcard/window_dump.xml' 2>/dev/null | tr -d '\r'
}

# enabled attribute of the first node whose bounds contain (x, y), or "missing".
coord_enabled_from_xml(){
  XML_INPUT="$1" python3 - "$2" "$3" <<'PY'
import os, re, sys
xml = os.environ.get("XML_INPUT", "")
x = int(sys.argv[1])
y = int(sys.argv[2])

for line in xml.splitlines():
    if "<node " not in line:
        continue
    m = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', line)
    if not m:
        continue
    x1, y1, x2, y2 = map(int, m.groups())
    if x1 <= x <= x2 and y1 <= y <= y2:
        enabled = "false"
        m2 = re.search(r'enabled="([^"]+)"', line)
        if m2:
            enabled = m2.group(1)
        print(enabled)
        sys.exit(0)

print("missing")
PY
}

# wait_until_ui_ready <role> <input x> <input y> <send x> <send y>
wait_until_ui_ready(){
  local role="$1" ix="$2" iy="$3" sx="$4" sy="$5"
  local start elapsed xml send_enabled input_enabled stable_start=0
  start="$(date +%s)"
  while true; do
    elapsed=$(( $(date +%s) - start ))
    if (( elapsed < MIN_WAIT_BEFORE_UI_CHECK_SEC )); then
      sleep "$UI_POLL_SEC"
      continue
    fi
    xml="$(dump_ui_xml || true)"
    if [[ -n "$xml" ]] && grep -q '<hierarchy' <<< "$xml"; then
      send_enabled="$(coord_enabled_from_xml "$xml" "$sx" "$sy" || true)"
      input_enabled="$(coord_enabled_from_xml "$xml" "$ix" "$iy" || true)"
      if [[ "$send_enabled" == "true" && "$input_enabled" == "true" ]]; then
        if (( stable_start == 0 )); then
          stable_start="$(date +%s)"
          log "[READY-CANDIDATE] $role: input/send enabled after min wait ${MIN_WAIT_BEFORE_UI_CHECK_SEC}s"
        fi
        if (( $(date +%s) - stable_start >= UI_READY_STABLE_SEC )); then
          log "[NEXT-WAIT] $role: wait ${NEXT_QUESTION_DELAY_SEC}s after answer completion"
          sleep "$NEXT_QUESTION_DELAY_SEC"
          log "[READY] $role: proceed to next step"
          return 0
        fi
      else
        stable_start=0
      fi
    fi
    if (( elapsed >= UI_READY_TIMEOUT_SEC )); then
      log "[WARN] $role: UI ready timeout after ${elapsed}s"
      return 1
    fi
    sleep "$UI_POLL_SEC"
  done
}

# ask_all <role> <pkg> <input x> <input y> <send x> <send y> <prompt>...
ask_all(){
  local role="$1" pkg="$2" ix="$3" iy="$4" sx="$5" sy="$6"
  shift 6
  local n=$# i=0 q
  log "[FOREGROUND] $role: $pkg"
  timeout 15s "${ADB[@]}" shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 2>&1 || true
  sleep 3
  require_alive "$pkg" "$role after foreground"
  for q in "$@"; do
    i=$((i + 1))
    log "[ASK] $role Q$i/$n: $q"
    "${ADB[@]}" shell input tap "$ix" "$iy" >/dev/null
    sleep 1
    "${ADB[@]}" shell input text "${q// /%s}" >/dev/null
    sleep 1
    "${ADB[@]}" shell input tap "$sx" "$sy" >/dev/null
    sleep 1
    wait_until_ui_ready "$role" "$ix" "$iy" "$sx" "$sy"
  done
}

"${ADB[@]}" wait-for-device >/dev/null
log "[INIT] clear logcat buffer, unload eksm_p (after the reboot no module is loaded)"
"${ADB[@]}" logcat -c
"${ADB[@]}" shell 'rmmod eksm_p >/dev/null 2>&1; rm -f /data/local/tmp/eksm_p.ko'
require_alive "$PKG1" "P1 preloaded"
require_alive "$PKG2" "P2 preloaded"
sleep 1
log "[INFO] min_wait=${MIN_WAIT_BEFORE_UI_CHECK_SEC}s UI poll=${UI_POLL_SEC}s timeout=${UI_READY_TIMEOUT_SEC}s stable=${UI_READY_STABLE_SEC}s next_delay=${NEXT_QUESTION_DELAY_SEC}s"

# Input field and send button: P1 260,1100 and 620,1105; P2 280,1110 and 610,1108.
ask_all P1 "$PKG1" 260 1100 620 1105 "${PROMPTS_P1[@]}"
ask_all P2 "$PKG2" 280 1110 610 1108 "${PROMPTS_P2[@]}"

log "[CMD] memdump before KSM"
bash "$H/memdump_backend.sh"
log "[CMD] ksm"
bash "$H/ksm_backend.sh"
log "[CMD] memdump after KSM"
bash "$H/memdump_backend.sh"

require_alive "$PKG1" "P1 final"
require_alive "$PKG2" "P2 final"
log "[OK] all done"
