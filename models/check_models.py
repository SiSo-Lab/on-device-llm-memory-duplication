#!/usr/bin/env python3
"""Checks model and adapter files against manifests/models.csv.

usage: check_models.py <dir> [<dir> ...]   (files are matched by name, searched recursively)
Prints OK, MISMATCH or MISSING per manifest entry; exit 1 if any present file mismatches.
"""
import csv
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return h.hexdigest()


found = {}
for d in sys.argv[1:]:
    for root, _, files in os.walk(d):
        for name in files:
            found.setdefault(name, os.path.join(root, name))

bad = 0
for r in csv.DictReader(open(os.path.join(ROOT, "manifests/models.csv"), encoding="utf-8")):
    path = found.get(r["file"])
    if path is None:
        print(f"MISSING   {r['file']}")
        continue
    ok = sha256(path) == r["sha256"]
    bad += not ok
    print(f"{'OK' if ok else 'MISMATCH':9} {r['file']}  {path}")
sys.exit(1 if bad else 0)
