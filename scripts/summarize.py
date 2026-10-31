#!/usr/bin/env python3
"""Mean and Student-t 95% confidence interval per condition and pair over the values.csv files of
the run directories found under the given directories.

usage: summarize.py <dir> [<dir> ...]

  pss_before_MiB     combined PSS of the two apps before KSM (Fig. 1)
  recovery_MiB, %    combined PSS before KSM minus after KSM (Fig. 1)
  shared_MiB         pages_shared x 4 KiB, distinct merged (Fig. 2)
  sharing_MiB        pages_sharing x 4 KiB, eliminated mappings (Fig. 2)
  pct_of_base        pages_shared x 4 KiB as % of one 770 MiB base model copy (Fig. 3)
"""
import csv
import glob
import json
import math
import os
import statistics
import sys

T95 = [12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
       2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086]
COLS = ["pss_before_MiB", "recovery_MiB", "recovery_%", "shared_MiB", "sharing_MiB", "pct_of_base"]


def metrics(r):
    m = {"shared_MiB": int(r["pages_shared"]) * 4 / 1024, "sharing_MiB": int(r["pages_sharing"]) * 4 / 1024}
    if r["scenario"].startswith("lora"):
        m["pct_of_base"] = m["shared_MiB"] / 770 * 100
    else:
        before = int(r["combined_pss_before_kb"]) / 1024
        rec = int(r["combined_pss_recovery_kb"]) / 1024
        m.update({"pss_before_MiB": before, "recovery_MiB": rec, "recovery_%": rec / before * 100})
    return m


def fmt(xs):
    if not xs:
        return ""
    mean = statistics.mean(xs)
    if len(xs) < 2:
        return f"{mean:.2f}"
    t = T95[len(xs) - 2] if len(xs) - 2 < len(T95) else 1.96
    return f"{mean:.2f} ± {t * statistics.stdev(xs) / math.sqrt(len(xs)):.2f}"


groups = {}
for d in sys.argv[1:]:
    for path in sorted(glob.glob(os.path.join(d, "**", "values.csv"), recursive=True)):
        for r in csv.DictReader(open(path)):
            if r.get("status", "ok") != "ok" or not r.get("pages_shared"):
                continue
            wc = os.path.join(os.path.dirname(path), "warmup_check.json")
            if os.path.exists(wc) and not json.load(open(wc))["warmup_pass"]:
                print(f"skip, warm-up check failed: {path}", file=sys.stderr)
                continue
            groups.setdefault((r["scenario"], r["pair"]), []).append(metrics(r))

rows = [["condition", "pair", "n"] + COLS]
for (cond, pair), ms in sorted(groups.items()):
    rows.append([cond, pair, str(len(ms))] + [fmt([m[c] for m in ms if c in m]) for c in COLS])
w = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
for r in rows:
    print("  ".join(v.ljust(w[i]) for i, v in enumerate(r)).rstrip())
