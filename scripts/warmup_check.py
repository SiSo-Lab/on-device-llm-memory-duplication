#!/usr/bin/env python3
"""Warm-up check of one repetition: both apps ran inference before KSM. Reads the run directory only.

  (a) P1 ran inference: logcat `InferenceEngineImpl: Sending user prompt` >= 1, P1's KV buffer is not
      entirely KSM-merged, and P1's compute buffer Rss > 4 kB. The number of accepted prompts is recorded.
      For the same-inode P1 build the prompt log tag is not checked; (b) decides.
  (b) compute buffer Rss > 4 kB for P1 and P2. The VMA is found by its size from logcat
      `compute buffer size = X MiB` (X MiB + 4 kB).
  (c) No DocumentsUI PickActivity was resumed after P1's model was loaded (preload_done_epoch).
  (d) MainActivity was created exactly once in each measured process (wm_on_create_called).
KV buffer VMA: scudo:secondary of size Y MiB + 4 kB (logcat `KV buffer size = Y MiB`) with Rss == Size.

usage: warmup_check.py <run_dir> <scenario> <pair>   -> <run_dir>/warmup_check.json, exit 0 PASS / 1 FAIL
"""
import csv, datetime as dt, glob, json, os, re, sys

PKGS = {"per-app-copy": ("com.example.llama.aichat.a", "dev.filipfan.polyengineinfer.a"),
        "probe": ("com.example.llama.aichat", "dev.filipfan.polyengineinfer.mmapasdio"),
        "same-inode": ("com.example.llama.hard", "dev.filipfan.polyengineinfer.hard")}
LOGCAT_RE = re.compile(r"^(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d{3})\s+(\d+)\s+(\d+)\s+\w\s+(.*)$")

def lines(path):
    if not os.path.exists(path):
        return []
    with open(path, errors="replace") as f:
        return f.read().splitlines()

def logcat(path):
    out = []
    for l in lines(path):
        m = LOGCAT_RE.match(l)
        if m:
            g = m.groups()
            out.append(tuple(int(x) for x in g[:6]) + (g[6], g[8]))
    return out

def device_year(rd, tz):
    for l in lines(os.path.join(rd, "host/device_clock.txt")):
        m = re.search(r"device_epoch=(\d+)", l)
        if m:
            return dt.datetime.fromtimestamp(int(m.group(1)), tz).year
    return dt.date.today().year

def device_tz(rd):
    for l in lines(os.path.join(rd, "host/device_clock.txt")):
        m = re.match(r"device_tz=([+-])(\d\d)(\d\d)", l)
        if m:
            s = 1 if m.group(1) == "+" else -1
            return dt.timezone(s * dt.timedelta(hours=int(m.group(2)), minutes=int(m.group(3))))
    return dt.timezone.utc

def ts_of(r, year, tz):
    return dt.datetime(year, r[0], r[1], r[2], r[3], r[4], r[5] * 1000, tzinfo=tz)

def vma_rows(path):
    with open(path, errors="replace") as f:
        return {(d["range"], d["perms"], d["offset"], d["path"]): d for d in csv.DictReader(f, delimiter="\t") if not d["cat"].startswith("##")}

def buf_sizes(lc, pid):
    """KV and compute buffer sizes of that PID from logcat (kB, including the 4 kB scudo header)."""
    kv = comp = None
    for r in lc:
        if r[6] != pid:
            continue
        m = re.search(r"KV buffer size =\s*([\d.]+) MiB", r[7])
        if m:
            kv = int(round(float(m.group(1)) * 1024)) + 4
        m = re.search(r"compute buffer size =\s*([\d.]+) MiB", r[7])
        if m:
            comp = int(round(float(m.group(1)) * 1024)) + 4
    return kv, comp

def main(a):
    rd, scen, pair = a[0], a[1], a[2]
    pk = PKGS[scen]
    dumps = sorted(d for d in glob.glob(os.path.join(rd, "device/eksm_memdump/*")) if os.path.isdir(d))
    lc_app = logcat(os.path.join(rd, "host/logcat_app.txt"))
    lc_ev = logcat(os.path.join(rd, "host/logcat_events.txt"))
    tz = device_tz(rd)
    year = device_year(rd, tz)
    res = {"run_dir": os.path.basename(os.path.normpath(rd)), "scenario": scen, "pair": pair, "per_app": {}, "reasons": []}
    if len(dumps) != 2:
        res["reasons"].append(f"memdump dirs={len(dumps)}")
    pre_done = None
    for l in lines(os.path.join(rd, "host/preload_done_epoch.txt")):
        if l.strip().isdigit():
            pre_done = dt.datetime.fromtimestamp(int(l.strip()), dt.timezone.utc)
    asks = []
    for l in lines(os.path.join(rd, "host/runner_stdout.log")):
        m = re.search(r"\[HOST\]\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] \[ASK\] P1 Q(\d+)/\d+:", l)
        if m:
            asks.append((dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").astimezone(dt.timezone.utc), int(m.group(2))))
    for role, pkg in (("p1", pk[0]), ("p2", pk[1])):
        g = {"pkg": pkg}
        f1 = glob.glob(os.path.join(dumps[0], f"*_{pkg}_pid*_vma_table.tsv")) if dumps else []
        f2 = glob.glob(os.path.join(dumps[1], f"*_{pkg}_pid*_vma_table.tsv")) if len(dumps) > 1 else []
        if len(f1) != 1 or len(f2) != 1:
            g["error"] = f"vma_table md1={len(f1)} md2={len(f2)}"
            res["per_app"][role] = g; res["reasons"].append(f"{role}:vma_table"); continue
        pid = re.search(r"_pid(\d+)_vma_table", f1[0]).group(1)
        g["pid"] = pid
        a1, b1 = vma_rows(f1[0]), vma_rows(f2[0])
        kv_kb, comp_kb = buf_sizes(lc_app, pid)
        g["kv_vma_kB"], g["compute_vma_kB"] = kv_kb, comp_kb
        def nearest(target, need_full):
            if not target:
                return []
            c = [(abs(int(d["Size_kB"]) - target), k, d) for k, d in a1.items()
                 if d["path"].startswith("[anon:scudo:secondary]") and abs(int(d["Size_kB"]) - target) <= 16
                 and (not need_full or int(d["Rss_kB"]) == int(d["Size_kB"]))]
            c.sort(key=lambda x: x[0])
            return [(c[0][1], c[0][2])] if c else []
        kv = nearest(kv_kb, True)
        cp = nearest(comp_kb, False)
        g["kv_vma_actual_kB"] = int(kv[0][1]["Size_kB"]) if kv else None
        g["compute_vma_actual_kB"] = int(cp[0][1]["Size_kB"]) if cp else None
        g["compute_rss_md1_kB"] = sum(int(d["Rss_kB"]) for _, d in cp) if cp else None
        g["kv_ksm_after_kB"] = sum(int(b1[k]["KSM_kB"] or 0) for k, _ in kv if k in b1) if kv else None
        g["kv_fully_merged"] = (g["kv_ksm_after_kB"] >= sum(int(d["Size_kB"]) for _, d in kv) - 4 * len(kv)) if kv else None
        g["dPSS_kv_kB"] = sum(int(d["Pss_kB"]) - int(b1[k]["Pss_kB"]) for k, d in kv if k in b1) if kv else None
        g["dPSS_compute_kB"] = sum(int(d["Pss_kB"]) - int(b1[k]["Pss_kB"]) for k, d in cp if k in b1) if cp else None
        g["b_pass"] = g["compute_rss_md1_kB"] is not None and g["compute_rss_md1_kB"] > 4
        creates = [r for r in lc_ev if r[6] == pid and r[7].startswith("wm_on_create_called:") and ".MainActivity," in r[7]]
        g["d_main_activity_creates"] = len(creates)
        g["d_pass"] = len(creates) == 1
        if role == "p1":
            pr = [r for r in lc_app if r[6] == pid and re.search(r"InferenceEngineImpl\s*:\s*Sending user prompt", r[7])]
            sent = []
            for r in pr:
                t = ts_of(r, year, tz).astimezone(dt.timezone.utc)
                prev = [q for (ta, q) in asks if ta <= t + dt.timedelta(seconds=1)]
                sent.append(prev[-1] if prev else None)
            g["prompts"] = len(pr)
            g["sent_q"] = sent
            g["missing_q"] = [i for i in range(1, 16) if i not in sent] if asks else None
            if scen in ("probe", "per-app-copy"):
                g["a_pass"] = len(pr) >= 1 and g["kv_fully_merged"] is False and g["b_pass"]
            else:
                g["a_pass"] = g["kv_fully_merged"] is False and g["b_pass"]
                g["a_note"] = "same-inode P1 build: prompt log tag not checked; judged by KV/compute"
            picks = []
            for r in lc_ev:
                if r[7].startswith("wm_set_resumed_activity:") and "documentsui" in r[7] and "PickActivity" in r[7]:
                    t = ts_of(r, year, tz).astimezone(dt.timezone.utc)
                    if pre_done is None or t > pre_done:
                        picks.append(r[7][:120])
            g["c_picks_after_preload"] = picks
            g["c_pass"] = pre_done is not None and not picks
        for k in ("a_pass", "b_pass", "c_pass", "d_pass"):
            if g.get(k) is False:
                res["reasons"].append(f"{role}:{k[0]}")
        res["per_app"][role] = g
    res["warmup_pass"] = not res["reasons"]
    ok = res["warmup_pass"]
    json.dump(res, open(os.path.join(rd, "warmup_check.json"), "w"), indent=2, ensure_ascii=False)
    print(("PASS" if ok else "FAIL") + " " + ",".join(res["reasons"]))
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main(sys.argv[1:])
