#!/usr/bin/env python3
"""Merges a PEFT LoRA adapter into the base model (merge_and_unload(safe_merge=True) on CPU) and
saves the merged model as safetensors.

usage: merge_lora.py --base <hf_dir> --adapter <adapter_dir> --out <dir> [--dtype float16]
"""
import argparse
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import PeftModel

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--adapter", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--dtype", default="float16", choices=["float16", "bfloat16", "float32"])
    args = parser.parse_args()

    dtype_map = {
        "float16": torch.float16,
        "bfloat16": torch.bfloat16,
        "float32": torch.float32,
    }
    dtype = dtype_map[args.dtype]

    print("=" * 100)
    print("[INFO] base    =", args.base)
    print("[INFO] adapter =", args.adapter)
    print("[INFO] out     =", args.out)
    print("[INFO] dtype   =", args.dtype)

    print("[STEP] loading base model")
    base_model = AutoModelForCausalLM.from_pretrained(
        args.base,
        torch_dtype=dtype,
        device_map="cpu",
        low_cpu_mem_usage=True,
    )

    print("[STEP] loading adapter")
    peft_model = PeftModel.from_pretrained(
        base_model,
        args.adapter,
        torch_dtype=dtype,
        device_map="cpu",
    )

    print("[STEP] merge_and_unload")
    merged = peft_model.merge_and_unload(safe_merge=True)
    merged.eval()

    print("[STEP] save merged model")
    merged.save_pretrained(
        args.out,
        safe_serialization=True,
        max_shard_size="2GB",
    )

    print("[STEP] save tokenizer")
    try:
        tokenizer = AutoTokenizer.from_pretrained(args.base)
        tokenizer.save_pretrained(args.out)
    except Exception as e:
        print("[WARN] tokenizer save failed:", repr(e))

    print("[DONE] merged model saved:", args.out)

if __name__ == "__main__":
    main()
