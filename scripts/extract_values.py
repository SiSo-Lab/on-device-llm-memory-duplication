#!/usr/bin/env python3
"""One repetition (run directory) -> one CSV row of the per-run table.

Inputs in <run_dir>:
  device/eksm_memdump/<TS>/now_<pkg>_pid<pid>_sum.tsv  per-category sums written by memdump_backend.sh;
      the first <TS> is the dump before KSM, the second the dump after KSM
  host/runner_stdout.log  output of ksm_backend.sh (1 s samples, KSM_DUMP_ALL, CONCLUSION)
KSM columns:
  time          sample index t at which the observation loop stopped
  full_scans, general_profit, pages_shared, pages_sharing  final CONCLUSION / KSM_DUMP_ALL values
  pages_scanned KSM_DUMP_ALL value (cumulative since boot; not reset by run=2)
Values are copied, not computed. A category without VMAs is left empty.
usage: extract_values.py <run_dir> <scenario> <pair> <run> <run_id> <timestamp> <commit>
       extract_values.py --header
"""
import csv, glob, os, re, sys

CATS = ["RuntimeCode", "ModelWeights", "Other"]
FIELDS = ["Size", "Pss", "Rss", "ShC", "PrD", "Anon"]
KSM_COLS = ["time", "full_scans", "general_profit", "pages_scanned", "pages_shared", "pages_sharing"]
PROV = ["scenario", "pair", "run", "run_id", "timestamp", "commit"]
VAL_COLS = [f"{p}_{c}_{f}_kb_{ba}" for p in ("p1", "p2") for c in CATS for f in FIELDS for ba in ("before", "after")]
EXTRA = ["p1_pid", "p2_pid", "ksm_wall_s", "stable_reached", "combined_pss_before_kb", "combined_pss_after_kb", "combined_pss_recovery_kb"]
HEADER = PROV + VAL_COLS + KSM_COLS + EXTRA

PKGS = {
    "per-app-copy": ("com.example.llama.aichat.a", "dev.filipfan.polyengineinfer.a"),
    "probe": ("com.example.llama.aichat", "dev.filipfan.polyengineinfer.mmapasdio"),
    "same-inode": ("com.example.llama.hard", "dev.filipfan.polyengineinfer.hard"),
    "lora-merged": ("com.example.llama.aichat", "dev.filipfan.polyengineinfer.mmapasdio"),
    "lora-separated": ("com.example.llama.aichat", "dev.filipfan.polyengineinfer.mmapasdio"),
}
ANSI = re.compile(r"\x1b\[[0-9;]*m")

def read_sum(path):
    out = {}
    for line in open(path):
        p = line.rstrip("\n").split("\t")
        if not p or p[0] != "##SUM##":
            continue
        d = dict(kv.split("=", 1) for kv in p[2:])
        out[p[1]] = d
    return out

def main(a):
    if a and a[0] == "--header":
        print(",".join(HEADER)); return
    rd, scen, pair, run, run_id, ts, commit = a[:7]
    row = dict.fromkeys(HEADER, "")
    row.update(scenario=scen, pair=pair, run=run, run_id=run_id, timestamp=ts, commit=commit)
    pk1, pk2 = PKGS[scen]
    dumps = sorted(d for d in glob.glob(os.path.join(rd, "device/eksm_memdump/*")) if os.path.isdir(d))
    if len(dumps) != 2:
        raise SystemExit(f"expected 2 memdump dirs, got {len(dumps)}: {dumps}")
    pids = {}
    for ba, d in zip(("before", "after"), dumps):
        for p, pkg in (("p1", pk1), ("p2", pk2)):
            fs = glob.glob(os.path.join(d, f"now_{pkg}_pid*_sum.tsv"))
            if len(fs) != 1:
                raise SystemExit(f"{d}: sum.tsv for {pkg}: {fs}")
            pid = re.search(r"_pid(\d+)_sum", fs[0]).group(1)
            if pids.setdefault(p, pid) != pid:
                raise SystemExit(f"pid changed between dumps for {p}: {pids[p]} vs {pid}")
            s = read_sum(fs[0])
            for c in CATS:
                for f in FIELDS:
                    row[f"{p}_{c}_{f}_kb_{ba}"] = s[c][f] if c in s else ""
            row[f"{p}_TOTALPSS_{ba}"] = s.get("TOTAL", {}).get("Pss", "")
    row["p1_pid"], row["p2_pid"] = pids["p1"], pids["p2"]
    tb = int(row.pop("p1_TOTALPSS_before")) + int(row.pop("p2_TOTALPSS_before"))
    ta = int(row.pop("p1_TOTALPSS_after")) + int(row.pop("p2_TOTALPSS_after"))
    row["combined_pss_before_kb"], row["combined_pss_after_kb"], row["combined_pss_recovery_kb"] = tb, ta, tb - ta

    log = ANSI.sub("", open(os.path.join(rd, "host/runner_stdout.log"), errors="replace").read())
    tl = re.findall(r"\[AVD\]\[([0-9-]+ [0-9:]+)\] t=(\d+)s run=\S+ scanned=\S+ full=\S+ sharing=\S+ shared=\S+ stable_cnt", log)
    if not tl:
        raise SystemExit("no KSM sample lines")
    row["time"] = tl[-1][1]
    row["stable_reached"] = "1" if "REACHED STABLE" in log else "0"
    from datetime import datetime
    t0 = datetime.strptime(tl[0][0], "%Y-%m-%d %H:%M:%S"); t1 = datetime.strptime(tl[-1][0], "%Y-%m-%d %H:%M:%S")
    row["ksm_wall_s"] = int((t1 - t0).total_seconds())
    m = re.findall(r"CONCLUSION shared=(\d+) sharing=(\d+) general_profit=(-?\d+) full_scans=(\d+)", log)
    if not m:
        raise SystemExit("no CONCLUSION")
    row["pages_shared"], row["pages_sharing"], row["general_profit"], row["full_scans"] = m[-1]
    ps = re.findall(r"KSM pages_scanned=(\d+)", log)
    row["pages_scanned"] = ps[-1] if ps else ""
    w = csv.DictWriter(sys.stdout, HEADER); w.writerow(row)

if __name__ == "__main__":
    main(sys.argv[1:])
