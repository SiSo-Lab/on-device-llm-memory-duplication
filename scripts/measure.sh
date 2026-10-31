#!/usr/bin/env bash
# One repetition and its per-run values (<run_dir>/values.csv). For per-app-copy, probe and same-inode it
# also runs the warm-up check (warmup_check.json; exit 1 if an app did not run inference before KSM).
# Each run starts in a new Cuttlefish device (fresh_vm in lib.sh), which is stopped at the end.
# Environment: SERIAL, ADB_BIN, KO, ASSETS, GOOD_HOME, SYSTEM_IMAGE_DIR; optional FRESH, BASE_NUM (see README.md).
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
usage(){
  cat >&2 <<'USAGE'
Usage: measure.sh <condition> <pair> <run> <run_dir>
  per-app-copy    1B/1B                                                         (Fig. 1)
  same-inode      1B/1B                                                         (Fig. 1)
  probe           1B/1B 1B/3B 3B/3B 3B/3B-kor Q1.5/Q1.5 Q1.5/S1.7 1B/G2B 3B/Q3B   (Figs. 1-2)
  lora-merged     A/B C/D A/C                                                   (Fig. 3)
  lora-separated  A/B C/D A/C                                                   (Fig. 3)
USAGE
  exit 2
}
[ $# -eq 4 ] || usage
cond="$1"; pair="$2"; run="$3"; RD="$4"
case "$cond" in
  per-app-copy) [ "$pair" = 1B/1B ] || usage; cmd=(run_per_app_copy.sh "$RD") ;;
  same-inode) [ "$pair" = 1B/1B ] || usage; cmd=(run_same_inode.sh "$RD") ;;
  probe) cmd=(run_probe.sh "$pair" "$RD") ;;
  lora-merged) cmd=(run_lora.sh merged "$pair" "$RD") ;;
  lora-separated) cmd=(run_lora.sh separated "$pair" "$RD") ;;
  *) usage ;;
esac
source "$H/lib.sh"
: "${GOOD_HOME:?directory prepared by setup_cuttlefish.sh}" "${SYSTEM_IMAGE_DIR:?image directory prepared by setup_cuttlefish.sh}"
[ -z "$(ls -A "$RD" 2>/dev/null)" ] || { echo "run_dir is not empty: $RD (use a new run_dir)" >&2; exit 2; }
mkdir -p "$RD"
# Every run boots a new device and stops it at the end, also on failure; the boot output goes to host/boot.log.
end_vm(){ stop_vm; mkdir -p "$RD/host"; cp "$FRESH/boot.log" "$RD/host/boot.log" || true; }
trap end_vm EXIT
fresh_vm
bash "$H/${cmd[0]}" "${cmd[@]:1}"
RD="$(cd "$RD" && pwd)"
EX="$H/extract_values.py"
{ python3 "$EX" --header
  python3 "$EX" "$RD" "$cond" "$pair" "$run" "$(basename "$RD")" "$(date -Is)" "$(git -C "$H" rev-parse --short HEAD 2>/dev/null || echo -)"; } > "$RD/values.csv"
case "$cond" in
  per-app-copy|probe|same-inode) python3 "$H/warmup_check.py" "$RD" "$cond" "$pair" ;;
esac
