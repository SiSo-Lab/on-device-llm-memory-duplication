#!/usr/bin/env bash
# Boots the Cuttlefish device: crosvm, 12 GiB, guest kernel and initramfs from $GOOD_HOME,
# userdata image of DATA_IMG_SIZE (default 128G, as measured; created if missing, --data_policy=use_existing).
# launch_cvd needs that much free space in $FRESH. BASE_NUM=N selects instance N (adb port 6519+N).
# Stays in the foreground until stop_cvd. measure.sh starts it in the background for every run (fresh_vm in lib.sh).
set -euo pipefail
set +o histexpand 2>/dev/null || true

BASE_NUM="${BASE_NUM:-1}"

GOOD_HOME="${GOOD_HOME:?directory prepared by setup_cuttlefish.sh}"
SYSTEM_IMAGE_DIR="${SYSTEM_IMAGE_DIR:?image directory prepared by setup_cuttlefish.sh}"

FRESH="${FRESH:-$PWD/cf-run}"
INSTANCE_DIR="${INSTANCE_DIR:-$FRESH/cuttlefish}"
ASSEMBLY_DIR="${ASSEMBLY_DIR:-$FRESH/cuttlefish_assembly}"
TMPDIR_HOST="${TMPDIR_HOST:-$FRESH/tmp}"

DATA_IMG_SIZE="${DATA_IMG_SIZE:-128G}"
DATA_IMG="${DATA_IMG:-$FRESH/userdata.img}"

KERNEL_PATH="${KERNEL_PATH:-$GOOD_HOME/bzImage}"
INITRAMFS_PATH="${INITRAMFS_PATH:-$GOOD_HOME/initramfs.img}"
LAUNCH_CVD="${LAUNCH_CVD:-$GOOD_HOME/bin/launch_cvd}"

mkdir -p "$FRESH" "$TMPDIR_HOST" "$INSTANCE_DIR" "$ASSEMBLY_DIR"

if [ ! -x "$LAUNCH_CVD" ]; then
  echo "[ERROR] launch_cvd not found or not executable: $LAUNCH_CVD" >&2
  exit 1
fi
if [ ! -d "$SYSTEM_IMAGE_DIR" ]; then
  echo "[ERROR] system_image_dir not found: $SYSTEM_IMAGE_DIR" >&2
  exit 1
fi
if [ ! -f "$KERNEL_PATH" ]; then
  echo "[ERROR] kernel_path not found: $KERNEL_PATH" >&2
  exit 1
fi
if [ ! -f "$INITRAMFS_PATH" ]; then
  echo "[ERROR] initramfs_path not found: $INITRAMFS_PATH" >&2
  exit 1
fi

if [ ! -f "$DATA_IMG" ]; then
  truncate -s "$DATA_IMG_SIZE" "$DATA_IMG"
fi

echo "[INFO] Using:"
echo "  BASE_NUM=$BASE_NUM"
echo "  GOOD_HOME=$GOOD_HOME"
echo "  INSTANCE_DIR=$INSTANCE_DIR"
echo "  ASSEMBLY_DIR=$ASSEMBLY_DIR"
echo "  DATA_IMG=$DATA_IMG"
echo "  RAM=12288MB, INTERNAL_STORAGE(userdata)=$DATA_IMG_SIZE, SDCARD=OFF"

COLOR_FILTER='
/VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED|VIRTUAL_DEVICE_BOOT_STARTED|VIRTUAL_DEVICE_BOOT_COMPLETED|Virtual device rebooted successfully|VIRTUAL_DEVICE_NETWORK_MOBILE_CONNECTED/ {
  printf "\033[93m%s\033[0m\n", $0
  fflush()
  next
}
{
  print
  fflush()
}
'

env -i \
  HOME="$GOOD_HOME" \
  USER="$USER" \
  LOGNAME="$USER" \
  PATH="$GOOD_HOME/bin:/usr/bin:/bin" \
  TMPDIR="$TMPDIR_HOST" \
  "$LAUNCH_CVD" \
    --system_image_dir="$SYSTEM_IMAGE_DIR" \
    --config=phone \
    --base_instance_num="$BASE_NUM" \
    --instance_dir="$INSTANCE_DIR" \
    --assembly_dir="$ASSEMBLY_DIR" \
    --start_webrtc=true \
    --memory_mb=12288 \
    --use_sdcard=false \
    --data_image="$DATA_IMG" \
    --data_policy=use_existing \
    --console=true \
    --report_anonymous_usage_stats=n \
    --kernel_path="$KERNEL_PATH" \
    --initramfs_path="$INITRAMFS_PATH" \
    2>&1 | awk "$COLOR_FILTER"

