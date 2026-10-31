#!/usr/bin/env bash
# Opens an app and loads a model through its UI.
# Usage: preload.sh p2 <file> | p1import <file> | p1 <file>
# Environment: SERIAL, ADB_BIN, PKG1 (P1 package), PKG2 (P2 package).
set -euo pipefail
: "${SERIAL:?}" "${ADB_BIN:?}" "${PKG1:?}" "${PKG2:?}"
H="$(cd "$(dirname "$0")" && pwd)"
ADB=("$ADB_BIN" -s "$SERIAL")
UI=(python3 "$H/ui.py")
log(){ echo "[preload][$(date '+%F %T')] $*"; }
esc(){ printf '%s' "$1" | sed -e 's/[.[\*^$()+?{|]/\\&/g'; }

wake(){ "${ADB[@]}" shell 'svc power stayon true; input keyevent 224; wm dismiss-keyguard' >/dev/null 2>&1 || true; }

p2_load() {
  local f="$1"
  wake
  "${ADB[@]}" shell monkey -p "$PKG2" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  "${UI[@]}" wait '^Settings$' --desc --timeout 60
  "${UI[@]}" tap '^Settings$' --desc
  "${UI[@]}" tap '^Model File$' --timeout 20
  "${UI[@]}" tap '^models$' --timeout 20
  "${UI[@]}" tap "^$(esc "$f")\$" --timeout 20
  "${UI[@]}" wait '^OK$' --timeout 20
  "${UI[@]}" tap '^OK$'
  "${UI[@]}" wait "^$(esc "$f") \\(llama\\.cpp\\)\$" --timeout 300
  "${UI[@]}" wait '^Type a message' --timeout 60
  if "${UI[@]}" has 'something went wrong|Error'; then log "ERR: P2 error dialog"; "${UI[@]}" dump; exit 1; fi
  log "P2 loaded $f pid=$("${ADB[@]}" shell pidof $PKG2 | tr -d '\r')"
}

p1_pick() {
  local f="$1"
  wake
  "${ADB[@]}" shell monkey -p "$PKG1" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  "${UI[@]}" wait 'pick a GGUF model' --timeout 60
  local fab
  fab="$(python3 - "$H" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import ui
for n in ui.nodes(ui.dump()):
    if n["rid"].endswith(":id/fab"): print(n["cx"], n["cy"]); break
PY
)"
  [ -n "$fab" ] || { log "ERR: FAB not found"; exit 1; }
  "${ADB[@]}" shell input tap $fab
  "${UI[@]}" wait '^Show roots$' --desc --timeout 30
  local fe; fe="^$(esc "$f")\$"
  if ! "${UI[@]}" has "$fe"; then
    "${UI[@]}" tap '^Show roots$' --desc
    "${UI[@]}" tap '^Cuttlefish x86_64' --timeout 20
    "${UI[@]}" tap '^model$' --timeout 20
  fi
  "${UI[@]}" tap "$fe" --timeout 20
  "${UI[@]}" wait '^Type and send a message' --timeout 600
  log "P1 loaded via picker $f pid=$("${ADB[@]}" shell pidof $PKG1 | tr -d '\r')"
}

case "${1:-}" in
  p2) p2_load "$2" ;;
  p1|p1import) p1_pick "$2" ;;
  *) echo "usage: $0 p2|p1|p1import <file>" >&2; exit 2 ;;
esac
