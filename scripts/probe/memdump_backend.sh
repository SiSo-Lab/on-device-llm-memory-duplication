#!/usr/bin/env bash
# Reads /proc/<pid>/smaps of both apps on the device and writes, per app, a per-VMA table
# (now_<pkg>_pid<pid>_vma_table.tsv) and per-category sums (now_<pkg>_pid<pid>_sum.tsv:
# RuntimeCode, ModelWeights, Other, TOTAL) to /data/local/tmp/eksm_memdump/<timestamp>/.
# ModelWeights: read-only private or shared mappings whose path matches MODEL_FILTER; RuntimeCode: r-xp.
# Environment: SERIAL, ADB_BIN, PKG1, PKG2, MODEL_FILTER.
set -euo pipefail
: "${SERIAL:?}" "${ADB_BIN:?}" "${PKG1:?}" "${PKG2:?}" "${MODEL_FILTER:?}"
ADB=("$ADB_BIN" -s "$SERIAL")
DEV=/data/local/tmp/memdump.sh

"${ADB[@]}" shell "cat > $DEV" <<'EOS'
#!/system/bin/sh
set -eu
MODEL_FILTER="$3"
OUT_DIR="/data/local/tmp/eksm_memdump/$(date '+%Y%m%d_%H%M%S')"
mkdir -p "$OUT_DIR"
echo "[AVD][$(date '+%F %T')] OUT_DIR $OUT_DIR"

dump_one(){
  pkg="$1"
  pid="$(pidof "$pkg" | cut -d' ' -f1)"
  [ -n "$pid" ] || { echo "[AVD] ERR: $pkg not running"; exit 1; }
  table="$OUT_DIR/now_${pkg}_pid${pid}_vma_table.tsv"
  awk -v MF="$MODEL_FILTER" '
    function init_fields(){
      Size=Rss=Pss=Pss_Dirty=Shared_Clean=Shared_Dirty=Private_Clean=Private_Dirty=Anonymous=AnonHugePages=0
      FilePmdMapped=ShmemPmdMapped=Swap=SwapPss=Locked=LazyFree=0
      THPeligible=""; ProtectionKey=""; KSM=-1; VmFlags=""
    }
    function classify(){
      cat="Other"
      if(perms ~ /r-xp/) cat="RuntimeCode"
      else if((perms ~ /r--p/ || perms ~ /r--s/) && path ~ MF) cat="ModelWeights"
      return cat
    }
    function flush(){
      if(hdr=="") return
      cat=classify()
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\n",
        cat, range, perms, offset, dev, inode, path,
        Size, Rss, Pss, Pss_Dirty, Shared_Clean, Shared_Dirty, Private_Clean, Private_Dirty,
        Anonymous, AnonHugePages, FilePmdMapped, ShmemPmdMapped, Swap, SwapPss, Locked, LazyFree,
        KSM, THPeligible, ProtectionKey, VmFlags
      add(cat); add("TOTAL")
      hdr=""
    }
    function add(c){
      VMA_cnt[c]+=1
      Size_sum[c]+=Size
      Rss_sum[c]+=Rss
      Pss_sum[c]+=Pss
      ShC_sum[c]+=Shared_Clean
      PrD_sum[c]+=Private_Dirty
      Anon_sum[c]+=Anonymous
    }
    BEGIN{
      hdr=""; init_fields()
      print "cat\trange\tperms\toffset\tdev\tinode\tpath\tSize_kB\tRss_kB\tPss_kB\tPss_Dirty_kB\tShared_Clean_kB\tShared_Dirty_kB\tPrivate_Clean_kB\tPrivate_Dirty_kB\tAnonymous_kB\tAnonHugePages_kB\tFilePmdMapped_kB\tShmemPmdMapped_kB\tSwap_kB\tSwapPss_kB\tLocked_kB\tLazyFree_kB\tKSM_kB\tTHPeligible\tProtectionKey\tVmFlags"
    }
    /^[0-9a-f]+-[0-9a-f]+ /{
      flush()
      hdr=$0
      range=$1; perms=$2; offset=$3; dev=$4; inode=$5
      path=""
      if(NF>=6){
        path=$6
        for(i=7;i<=NF;i++) path=path" "$i
      }
      init_fields()
      next
    }
    /^Size:/            {Size=$2; next}
    /^Rss:/             {Rss=$2; next}
    /^Pss:/             {Pss=$2; next}
    /^Pss_Dirty:/       {Pss_Dirty=$2; next}
    /^Shared_Clean:/    {Shared_Clean=$2; next}
    /^Shared_Dirty:/    {Shared_Dirty=$2; next}
    /^Private_Clean:/   {Private_Clean=$2; next}
    /^Private_Dirty:/   {Private_Dirty=$2; next}
    /^Anonymous:/       {Anonymous=$2; next}
    /^AnonHugePages:/   {AnonHugePages=$2; next}
    /^FilePmdMapped:/   {FilePmdMapped=$2; next}
    /^ShmemPmdMapped:/  {ShmemPmdMapped=$2; next}
    /^Swap:/            {Swap=$2; next}
    /^SwapPss:/         {SwapPss=$2; next}
    /^Locked:/          {Locked=$2; next}
    /^LazyFree:/        {LazyFree=$2; next}
    /^THPeligible:/     {THPeligible=$2; next}
    /^ProtectionKey:/   {ProtectionKey=$2; next}
    /^KSM:/             {KSM=$2; next}
    /^Ksm:/             {KSM=$2; next}
    /^VmFlags:/         {VmFlags=$0; sub(/^VmFlags:[[:space:]]*/,"",VmFlags); next}
    END{
      flush()
      for(c in VMA_cnt){
        printf "##SUM##\t%s\tVMA=%d\tSize=%d\tRss=%d\tPss=%d\tShC=%d\tPrD=%d\tAnon=%d\n",
          c, VMA_cnt[c], Size_sum[c], Rss_sum[c], Pss_sum[c], ShC_sum[c], PrD_sum[c], Anon_sum[c]
      }
    }
  ' "/proc/$pid/smaps" > "$table"
  grep '^##SUM##' "$table" > "$OUT_DIR/now_${pkg}_pid${pid}_sum.tsv"
  echo "[AVD][$(date '+%F %T')] $pkg pid=$pid"
  cat "$OUT_DIR/now_${pkg}_pid${pid}_sum.tsv"
}

dump_one "$1"
dump_one "$2"
EOS
"${ADB[@]}" shell "sh $DEV '$PKG1' '$PKG2' '$MODEL_FILTER'" | tr -d '\r'
