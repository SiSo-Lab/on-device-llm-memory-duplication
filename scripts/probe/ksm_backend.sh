#!/usr/bin/env bash
# Configures KSM, loads eksm_p for the two app PIDs, samples /sys/kernel/mm/ksm once per second
# until the first four digits of pages_sharing and pages_shared are unchanged over three samples
# (not before 60 s, at most 300 s), then prints all KSM values and the final counters.
# Environment: SERIAL, ADB_BIN, KO, PKG1, PKG2.
set -euo pipefail
: "${SERIAL:?}" "${ADB_BIN:?}" "${KO:?}" "${PKG1:?}" "${PKG2:?}"
ADB=("$ADB_BIN" -s "$SERIAL")
DEV=/data/local/tmp/ksm_watch.sh

"${ADB[@]}" push "$KO" /data/local/tmp/eksm_p.ko >/dev/null
"${ADB[@]}" shell "cat > $DEV" <<'EOS'
#!/system/bin/sh
set -eu
PKG1="$1"
PKG2="$2"
MIN_OBS_SEC=60
WAIT_STABLE_WINDOW=2
OBS_SEC=300
EVERY_SEC=1
KSM=/sys/kernel/mm/ksm

p(){ echo "[AVD][$(date '+%F %T')] $*"; }

PID1="$(pidof "$PKG1" | cut -d' ' -f1)"
PID2="$(pidof "$PKG2" | cut -d' ' -f1)"
p "Resolved PID1=$PID1 PID2=$PID2"
[ -n "$PID1" ] && [ -n "$PID2" ] || { p "ERR: $PKG1 or $PKG2 not running"; exit 1; }

p "Configure KSM"
echo 0 > "$KSM/run"
echo 20000 > "$KSM/pages_to_scan"
echo 20 > "$KSM/sleep_millisecs"
echo 1 > "$KSM/smart_scan"
echo none > "$KSM/advisor_mode"
echo 0 > "$KSM/use_zero_pages"
echo 2 > "$KSM/run"
echo 1 > "$KSM/run"

p "Load eksm_p with target_pids=$PID1,$PID2"
insmod /data/local/tmp/eksm_p.ko target_pids="$PID1,$PID2" verbose=1 hold_sec=0 max_tasks=0 only_private_anon=0 skip_file_vma=0

p "Watch KSM progress until stable"
t=0
last_key=""
stable_cnt=0
while [ "$t" -le "$OBS_SEC" ]; do
    runv="$(cat "$KSM/run")"
    scanned="$(cat "$KSM/pages_scanned")"
    full="$(cat "$KSM/full_scans")"
    sharing="$(cat "$KSM/pages_sharing")"
    shared="$(cat "$KSM/pages_shared")"
    reached_stable=0
    if [ "$sharing" -gt 0 ] && [ "$shared" -gt 0 ]; then
        key="$(echo "$sharing" | cut -c1-4):$(echo "$shared" | cut -c1-4)"
        if [ "$key" = "$last_key" ] && [ -n "$last_key" ]; then
            stable_cnt=$((stable_cnt+1))
        else
            stable_cnt=0
            last_key="$key"
        fi
        if [ "$stable_cnt" -ge "$WAIT_STABLE_WINDOW" ]; then
            reached_stable=1
        fi
    else
        stable_cnt=0
        last_key=""
    fi

    p "t=${t}s run=$runv scanned=$scanned full=$full sharing=$sharing shared=$shared stable_cnt=$stable_cnt/$WAIT_STABLE_WINDOW"

    if [ "$reached_stable" -eq 1 ]; then
        if [ "$t" -ge "$MIN_OBS_SEC" ]; then
            p "t=${t}s stable_cnt=$stable_cnt/$WAIT_STABLE_WINDOW -> REACHED STABLE after MIN_OBS_SEC=${MIN_OBS_SEC}s."
            break
        else
            p "t=${t}s stable_cnt=$stable_cnt/$WAIT_STABLE_WINDOW -> stable detected, but continue until MIN_OBS_SEC=${MIN_OBS_SEC}s."
        fi
    fi

    sleep "$EVERY_SEC"
    t=$((t+EVERY_SEC))
done

p "KSM_DUMP_ALL begin"
for f in "$KSM"/*; do
    base="$(basename "$f")"
    if [ -f "$f" ]; then
        p "KSM $base=$(cat "$f" 2>/dev/null || echo "<ERR>")"
    elif [ -d "$f" ]; then
        p "KSM $base=<dir>"
        for g in "$f"/*; do
            [ -f "$g" ] || continue
            p "KSM $base/$(basename "$g")=$(cat "$g" 2>/dev/null || echo "<ERR>")"
        done
    fi
done
p "KSM_DUMP_ALL end"

p "CONCLUSION shared=$(cat "$KSM/pages_shared") sharing=$(cat "$KSM/pages_sharing") general_profit=$(cat "$KSM/general_profit") full_scans=$(cat "$KSM/full_scans")"
p "END"
EOS
"${ADB[@]}" shell "sh $DEV '$PKG1' '$PKG2'" | tr -d '\r'
