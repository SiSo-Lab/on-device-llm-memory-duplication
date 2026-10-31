#!/usr/bin/env bash
# Usage: setup_cuttlefish.sh <image.zip> <cvd-host_package.tar.gz> <kernel_dist_dir> <cvd_home> <image_dir>
# Prepares the layout boot_cuttlefish.sh expects: the host package and the guest kernel in
# <cvd_home> (GOOD_HOME), the system images in <image_dir> (SYSTEM_IMAGE_DIR).
# The host also needs the Cuttlefish Debian packages cuttlefish-base and cuttlefish-user 1.57.0
# (github.com/google/android-cuttlefish), membership in the kvm, cvdnetwork and render groups, and,
# for crosvm on Ubuntu 24.04, sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
set -euo pipefail
zip="${1:?aosp_cf_x86_64_only_phone-img-14654133.zip}"
host="${2:?cvd-host_package.tar.gz}"
dist="${3:?kernel dist directory (bzImage, initramfs.img, eksm_p.ko)}"
cvd_home="${4:?cvd home directory}"
image_dir="${5:?image directory}"

check() { [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ] || { echo "sha256 mismatch: $1" >&2; exit 1; }; }
check "$zip" 109f631776abc9e1a48a2259be84e5207ba97ec85cd412e6bd8fd0d15f0425a1
check "$host" 3f5696fa7efe5d3b49fba61de8dda95f7106af21f438642b868f0bdd75e09da5

mkdir -p "$cvd_home" "$image_dir"
tar -xzf "$host" -C "$cvd_home"
unzip -o -q "$zip" -d "$image_dir"
cp "$dist/bzImage" "$dist/initramfs.img" "$dist/eksm_p.ko" "$cvd_home/"
