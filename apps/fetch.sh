#!/usr/bin/env bash
# Usage: apps/fetch.sh <probe|lora|per-app-copy|same-inode> <dest>
# Checks out the two apps at the upstream commits used for one loading
# condition and copies the modified files of apps/<condition>/ over them
# (lora = probe files, then lora files).
# Result: <dest>/llama.cpp (P1, examples/llama.android) and
#         <dest>/PolyEngineInfer (P2).
set -euo pipefail

cond="${1:?condition}"
dest="${2:?destination directory}"
here="$(cd "$(dirname "$0")" && pwd)"
LLAMA_URL="${LLAMA_URL:-https://github.com/ggml-org/llama.cpp}"
POLY_URL="${POLY_URL:-https://github.com/FilipFan/PolyEngineInfer}"

case "$cond" in
  per-app-copy)
    p1=4d3daf80f8834e0eb5148efc7610513f1e263653
    p2=446127d5232fbe7a5ad7aaef6535c27999c2169f ;;
  same-inode)
    p1=b39a7bf1b038e8d1c3d58a313228dfc4f3993f5c
    p2=d1f47fc974ddfbd667d4a2a195a34631ccce439b ;;
  probe|lora)
    p1=8bc492ebb407dfc8a61b8d92eced1b094ac1c823
    p2=d1f47fc974ddfbd667d4a2a195a34631ccce439b ;;
  *) echo "unknown condition: $cond" >&2; exit 2 ;;
esac
engine=bda62193b2a6bebbf515c3c389303094a44458c1

checkout() {
  local url="$1" commit="$2" dir="$3"
  git init -q "$dir"
  git -C "$dir" fetch -q --depth 1 "$url" "$commit"
  git -C "$dir" checkout -q FETCH_HEAD
  [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || { echo "$dir: HEAD is not $commit" >&2; exit 1; }
}

overlay() {
  cp -R "$here/$1/llama.cpp/." "$P1/"
  cp -R "$here/$1/PolyEngineInfer/." "$P2/"
}

[ ! -e "$dest" ] || { echo "$dest exists" >&2; exit 1; }
mkdir -p "$dest"
P1="$dest/llama.cpp"
P2="$dest/PolyEngineInfer"
checkout "$LLAMA_URL" "$p1" "$P1"
checkout "$POLY_URL" "$p2" "$P2"

if [ "$cond" = same-inode ]; then
  # P2 builds the same llama.cpp tree as P1 (b39a7bf), not its submodule.
  rmdir "$P2/external/llama.cpp"
  ln -s ../../llama.cpp "$P2/external/llama.cpp"
else
  checkout "$LLAMA_URL" "$engine" "$P2/external/llama.cpp"
fi

case "$cond" in
  lora) overlay probe; overlay lora ;;
  *) overlay "$cond" ;;
esac
echo "$cond sources ready in $dest"
