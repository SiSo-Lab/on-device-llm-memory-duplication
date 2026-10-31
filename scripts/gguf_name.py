#!/usr/bin/env python3
"""Prints the file name under which P1 (llama.cpp Android app) stores an imported GGUF:
"<general.basename>-<general.size_label>.gguf", or "<general.basename>.gguf" without a size label,
as in GgufMetadata.filename() of the app. Exits 3 if the file has no general.basename.
"""
import struct, sys

T_SIZES = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}

def rd_str(f):
    n, = struct.unpack("<Q", f.read(8))
    return f.read(n).decode("utf-8", "replace")

def skip_val(f, t):
    if t in T_SIZES:
        f.read(T_SIZES[t])
    elif t == 8:
        rd_str(f)
    elif t == 9:
        at, = struct.unpack("<I", f.read(4)); n, = struct.unpack("<Q", f.read(8))
        if at in T_SIZES:
            f.read(T_SIZES[at] * n)
        else:
            for _ in range(n):
                skip_val(f, at)
    else:
        raise ValueError(t)

def main(path):
    kv = {}
    with open(path, "rb") as f:
        assert f.read(4) == b"GGUF"
        f.read(12)
        nkv, = struct.unpack("<Q", f.read(8))
        for _ in range(nkv):
            k = rd_str(f); t, = struct.unpack("<I", f.read(4))
            if t == 8 and k in ("general.size_label", "general.basename"):
                kv[k] = rd_str(f)
            else:
                skip_val(f, t)
    name = kv.get("general.basename")
    if not name:
        print("NO_NAME", file=sys.stderr); sys.exit(3)
    sl = kv.get("general.size_label")
    print((f"{name}-{sl}" if sl else name) + ".gguf")

if __name__ == "__main__":
    main(sys.argv[1])
