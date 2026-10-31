#!/usr/bin/env python3
"""Minimal uiautomator driver used by preload.sh to open the apps and load a model.

usage:
  ui.py dump                      -> screen nodes (text/desc/res-id/bounds/enabled)
  ui.py tap  <regex> [--desc] [--timeout S]
  ui.py wait <regex> [--desc] [--timeout S]
  ui.py has  <regex> [--desc]     -> exit 0 if present
env: ADB_BIN (adb binary), SERIAL
"""
import os, re, subprocess, sys, time

ADB = os.environ["ADB_BIN"]
SERIAL = os.environ["SERIAL"]

def adb(*args, timeout=30):
    return subprocess.run([ADB, "-s", SERIAL, *args], capture_output=True, text=True, timeout=timeout).stdout

def dump():
    for _ in range(5):
        out = adb("shell", "uiautomator dump /data/local/tmp/ui_dump.xml >/dev/null 2>&1; cat /data/local/tmp/ui_dump.xml", timeout=40)
        if "<hierarchy" in out:
            return out
        time.sleep(1)
    return ""

NODE = re.compile(r"<node [^>]*>")

def attr(n, k):
    m = re.search(r'\b' + k + r'="([^"]*)"', n)
    return m.group(1) if m else ""

def nodes(xml):
    res = []
    for n in NODE.findall(xml):
        b = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", attr(n, "bounds"))
        if not b:
            continue
        x1, y1, x2, y2 = map(int, b.groups())
        res.append(dict(text=attr(n, "text"), desc=attr(n, "content-desc"), rid=attr(n, "resource-id"),
                        cls=attr(n, "class"), enabled=attr(n, "enabled"), clickable=attr(n, "clickable"),
                        cx=(x1 + x2) // 2, cy=(y1 + y2) // 2, bounds=(x1, y1, x2, y2)))
    return res

def find(pat, use_desc=False, xml=None):
    xml = xml if xml is not None else dump()
    rx = re.compile(pat)
    out = []
    for n in nodes(xml):
        key = n["desc"] if use_desc else n["text"]
        if key and rx.search(key):
            out.append(n)
    return out

def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__); sys.exit(2)
    cmd = a[0]
    use_desc = "--desc" in a
    timeout = float(a[a.index("--timeout") + 1]) if "--timeout" in a else 20.0
    if cmd == "dump":
        for n in nodes(dump()):
            if n["text"] or n["desc"] or n["clickable"] == "true":
                print(f'{n["cx"]:4d},{n["cy"]:4d} en={n["enabled"]} cl={n["clickable"]} text={n["text"]!r} desc={n["desc"]!r} rid={n["rid"]} cls={n["cls"]}')
        return
    pat = a[1]
    t0 = time.time()
    while True:
        hits = find(pat, use_desc)
        if hits:
            if cmd == "has":
                sys.exit(0)
            if cmd == "wait":
                print(f"found {pat!r}"); return
            if cmd == "tap":
                n = hits[0]
                adb("shell", "input", "tap", str(n["cx"]), str(n["cy"]))
                print(f'tapped {pat!r} at {n["cx"]},{n["cy"]} (text={n["text"]!r} desc={n["desc"]!r})')
                return
        if cmd == "has":
            sys.exit(1)
        if time.time() - t0 > timeout:
            print(f"timeout waiting for {pat!r}", file=sys.stderr)
            sys.exit(1)
        time.sleep(1.5)

if __name__ == "__main__":
    main()
