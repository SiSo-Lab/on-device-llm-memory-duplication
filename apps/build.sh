#!/usr/bin/env bash
# Usage: apps/build.sh <probe|lora|per-app-copy|same-inode> <src_dir> <out_dir>
# Builds the two debug APKs of a tree made by apps/fetch.sh and copies them to <out_dir>/{p1,p2}.apk.
# Needs JDK 17 (JAVA_HOME; the same-inode app does not build with a newer JDK) and an Android SDK (ANDROID_HOME) with platform 36, build-tools 35.0.0 and NDK 29.0.13113456 (P1)
# and 28.2.13676358 (P2). Gradle downloads its dependencies on the first run.
# Rebuilt APKs are not byte-identical to the measured ones (signing, timestamps); compare sources.
set -euo pipefail

cond="${1:?condition}"
src="$(cd "${2:?source directory}" && pwd)"
out="${3:?output directory}"
: "${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}"
mkdir -p "$out"

case "$cond" in
  per-app-copy) task=assembleADebug; apk=apk/a/debug/app-a-debug.apk ;;
  same-inode|probe|lora) task=assembleDebug; apk=apk/debug/app-debug.apk ;;
  *) echo "unknown condition: $cond" >&2; exit 2 ;;
esac

build() {
  local dir="$1" task="$2"
  echo "sdk.dir=$ANDROID_HOME" > "$dir/local.properties"
  (cd "$dir" && ./gradlew --no-daemon "$task")
}

build "$src/llama.cpp/examples/llama.android" "$task"
cp "$src/llama.cpp/examples/llama.android/app/build/outputs/$apk" "$out/p1.apk"
build "$src/PolyEngineInfer" "$task"
cp "$src/PolyEngineInfer/app/build/outputs/$apk" "$out/p2.apk"
sha256sum "$out/p1.apk" "$out/p2.apk"
