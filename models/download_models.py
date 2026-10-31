#!/usr/bin/env python3
"""Downloads the models and LoRA adapters from Hugging Face at fixed revisions.

usage: download_models.py <dir> [gguf|adapters|base|all]
  gguf      the seven Q4_K_M files of Figs. 1-2 into <dir>
  adapters  the four LoRA adapters of Fig. 3 (PEFT format) into <dir>/adapters/<A|B|C|D>
  base      meta-llama/Llama-3.2-1B-Instruct into <dir>/hf/Llama-3.2-1B-Instruct (gated: set HF_TOKEN)
Needs huggingface_hub. The GGUF and adapter sources were identified by matching the SHA-256 of the
measured files with the repository files; run models/check_models.py afterwards.
"""
import csv
import os
import shutil
import sys

from huggingface_hub import hf_hub_download, snapshot_download

GGUF = [
    ("hugging-quants/Llama-3.2-1B-Instruct-Q4_K_M-GGUF", "7d1f70022fcab2038000074bd0342e03e1d8b755",
     "llama-3.2-1b-instruct-q4_k_m.gguf"),
    ("hugging-quants/Llama-3.2-3B-Instruct-Q4_K_M-GGUF", "eb72f2a08dd2b9edd07ffacfe5aa56938b7939b0",
     "llama-3.2-3b-instruct-q4_k_m.gguf"),
    ("Bllossom/llama-3.2-Korean-Bllossom-3B-gguf-Q4_K_M", "c07b7a0f2688d1212612b653a752a0dfe4e18bae",
     "llama-3.2-Korean-Bllossom-3B-gguf-Q4_K_M.gguf"),
    ("bartowski/gemma-2-2b-it-GGUF", "855f67caed130e1befc571b52bd181be2e858883",
     "gemma-2-2b-it-Q4_K_M.gguf"),
    ("bartowski/Qwen2.5-1.5B-Instruct-GGUF", "9eadc66189c7641e1ddd226b8267a9119b2ce2d4",
     "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"),
    ("bartowski/Qwen2.5-3B-Instruct-GGUF", "f302c64a2269a69fb27b2f9473b362f5bb8e78d8",
     "Qwen2.5-3B-Instruct-Q4_K_M.gguf"),
    ("bartowski/SmolLM2-1.7B-Instruct-GGUF", "1f03464768bfcc0319fc50da8ff5fb20b6417ba2",
     "SmolLM2-1.7B-Instruct-Q4_K_M.gguf"),
]

ADAPTERS = [
    ("A", "xw17/Llama-3.2-1B-Instruct_finetuned_1_optimal_lora", "08691854cb5f10374dc6ba4b61781bfb4b396bee"),
    ("B", "xw17/Llama-3.2-1B-Instruct_finetuned_2_optimal_lora", "8e5befaacdcb7246fbce0cc52ac2e578038aef78"),
    ("C", "Cchaewon/lora-llama-3.2-1B-Instruct", "afe1ea93aaa7faa19ddf5351adb0f07e9f913612"),
    ("D", "bonginn/Llama-3.2-1B-Instruct-gkd-distilled-LoRA-Adapter", "d50d11c67b75d1bc53c679c4f97d3c9f21cd86e7"),
]

BASE = ("meta-llama/Llama-3.2-1B-Instruct", "9213176726f574b556790deb65791e0c5aa438b6")

MANIFEST = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "manifests/models.csv")
SIZE = {r["file"]: int(r["size_bytes"]) for r in csv.DictReader(open(MANIFEST, encoding="utf-8"))}


def main():
    out = sys.argv[1]
    what = sys.argv[2] if len(sys.argv) > 2 else "all"
    if what in ("gguf", "all"):
        for repo, rev, name in GGUF:
            dst = os.path.join(out, name)
            if os.path.exists(dst) and os.path.getsize(dst) == SIZE[name]:
                print(name, "exists")
                continue
            path = hf_hub_download(repo, name, revision=rev)
            shutil.copyfile(path, dst)
            print(name)
    if what in ("adapters", "all"):
        for slot, repo, rev in ADAPTERS:
            d = os.path.join(out, "adapters", slot)
            snapshot_download(repo, revision=rev, local_dir=d, ignore_patterns=["optimizer.pt"])
            print(d)
    if what in ("base", "all"):
        d = os.path.join(out, "hf", "Llama-3.2-1B-Instruct")
        snapshot_download(BASE[0], revision=BASE[1], local_dir=d,
                          allow_patterns=["*.json", "*.safetensors", "*.md"])
        print(d)


if __name__ == "__main__":
    os.makedirs(sys.argv[1], exist_ok=True)
    main()
