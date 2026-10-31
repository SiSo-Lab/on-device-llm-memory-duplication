#!/usr/bin/env bash
# Builds the Fig. 3 files in <out dir>: base model (F16 and Q4_K_M GGUF), the five merged Q4_K_M
# models and the four adapters as F16 GGUF. Intermediate files are kept in <out dir>/work.
# Usage: models/build_lora_models.sh <llama.cpp checkout at 8bc492e> <base HF dir> <adapters dir> <out dir>
#   llama.cpp: an unmodified checkout (the probe tree reads files with O_DIRECT, which tmpfs supports only since Linux 6.6)
#   adapters dir: A B C D as written by download_models.py
#   Python: an environment with models/requirements-lora.txt (set PYTHON if not python3)
# convert_hf_to_gguf.py writes the input directory name into general.name, so the inputs are
# linked under the directory names used originally (base, A, B); otherwise the hashes differ.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lc="$(cd "${1:?llama.cpp}" && pwd)"; base="$(cd "${2:?base}" && pwd)"; ad="$(cd "${3:?adapters}" && pwd)"
out="$(mkdir -p "${4:?out}" && cd "$4" && pwd)"
PY="${PYTHON:-python3}"
export PYTHONPATH="$lc/gguf-py"
q="$lc/build/bin/llama-quantize"
if [ ! -x "$q" ]; then
  cmake -S "$lc" -B "$lc/build" -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF -DLLAMA_CURL=OFF
  cmake --build "$lc/build" --config Release -j 16 --target llama-quantize
fi
w="$out/work"
mkdir -p "$w/adapters/xw17_optimal_1_vs_2" "$w/adapters/broadmeta_cchaewon_r8_vs_bonginn_r64" "$w/f16"
ln -sfn "$base" "$w/base"
ln -sfn "$ad/A" "$w/adapters/xw17_optimal_1_vs_2/A"
ln -sfn "$ad/B" "$w/adapters/xw17_optimal_1_vs_2/B"
ln -sfn "$ad/C" "$w/adapters/broadmeta_cchaewon_r8_vs_bonginn_r64/A"
ln -sfn "$ad/D" "$w/adapters/broadmeta_cchaewon_r8_vs_bonginn_r64/B"

"$PY" "$lc/convert_hf_to_gguf.py" "$w/base" --outtype f16 --outfile "$out/base.F16.gguf"
"$q" "$out/base.F16.gguf" "$out/base.Q4_K_M.gguf" Q4_K_M

# group/slot of the merged model, adapter, output name
while read -r group slot adapter name; do
  m="$w/merged/$group/$slot"
  "$PY" "$here/merge_lora.py" --base "$w/base" --adapter "$ad/$adapter" --out "$m" --dtype float16
  f16="$w/f16/${name%.Q4_K_M.gguf}.F16.gguf"
  "$PY" "$lc/convert_hf_to_gguf.py" "$m" --outtype f16 --outfile "$f16"
  "$q" "$f16" "$out/$name" Q4_K_M
  rm -rf "$m"
done <<'LIST'
xw17_optimal_1_vs_2 A A merged_A.Q4_K_M.gguf
xw17_optimal_1_vs_2 B B merged_B.Q4_K_M.gguf
broadmeta_cchaewon_r8_vs_bonginn_r64 A C merged_C.Q4_K_M.gguf
broadmeta_cchaewon_r8_vs_bonginn_r64 B D merged_D.Q4_K_M.gguf
mixed_xw17A_vs_cchaewonC B C merged_C_for_AC.Q4_K_M.gguf
LIST

while read -r dir name; do
  "$PY" "$lc/convert_lora_to_gguf.py" --base "$w/base" --outtype f16 --outfile "$out/$name" "$w/adapters/$dir"
done <<'LIST'
xw17_optimal_1_vs_2/A adapter_A.gguf
xw17_optimal_1_vs_2/B adapter_B.gguf
broadmeta_cchaewon_r8_vs_bonginn_r64/A adapter_C.gguf
broadmeta_cchaewon_r8_vs_bonginn_r64/B adapter_D.gguf
LIST
# only the Fig. 3 rows; the Figs. 1-2 files are not in <out dir>
python3 "$here/check_models.py" "$out" | grep -E ' (base|merged_|adapter_)'
