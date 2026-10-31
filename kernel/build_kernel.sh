#!/usr/bin/env bash
# Usage: kernel/build_kernel.sh <workspace_dir>
# Rebuilds the guest kernel, initramfs and eksm_p.ko with Kleaf, as for the measurements
# (tools/bazel run //common-modules/virtual-device:virtual_device_x86_64_dist, 2026-02-10).
# Needs the `repo` tool, about 100 GB of disk and network access.
# Output: <workspace_dir>/out/virtual_device_x86_64/dist/{bzImage,initramfs.img,eksm_p.ko}
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ws="${1:?workspace directory}"
mkdir -p "$ws" && cd "$ws"

repo init -u https://android.googlesource.com/kernel/manifest -b common-android-mainline
cp "$here/kleaf-manifest.xml" .repo/manifests/mobile-dedup.xml
repo init -m mobile-dedup.xml
repo sync -c -j8

git -C common apply "$here/android-mainline-build.diff"
cp "$here/gki_eksm.fragment" common/arch/x86/configs/gki_eksm.fragment
git -C common-modules/virtual-device apply "$here/virtual-device-build.diff"
mkdir -p eksm
cp "$here/eksm_p.c" "$here/Kbuild" "$here/Makefile" "$here/BUILD.bazel" eksm/

tools/bazel run //common-modules/virtual-device:virtual_device_x86_64_dist
sha256sum out/virtual_device_x86_64/dist/bzImage out/virtual_device_x86_64/dist/initramfs.img \
  out/virtual_device_x86_64/dist/eksm_p.ko
