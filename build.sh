#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="${KERNEL_DIR:-$ROOT/kernel}"
DD_DIR="${DD_DIR:-$ROOT/display-drivers}"
OUT="$ROOT/out"
ARCH=arm64
JOBS="${JOBS:-$(nproc --ignore=2)}"

DISPLAY_ROOT="$DD_DIR/vendor_opensource_display-drivers-peridot-u-oss"

if [[ -n "${CLANG_DIR:-}" ]]; then
  export CC="$CLANG_DIR/bin/clang"
else
  export CC="$(command -v clang)"
fi
export LLVM=1
export LLVM_IAS=1
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export STRIP=llvm-strip
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export READELF=llvm-readelf

mkdir -p "$OUT"

[[ -f "$KERNEL_DIR/Makefile" ]] || { echo "kernel tree missing"; exit 1; }
[[ -f "$DISPLAY_ROOT/msm/Kbuild" ]] || { echo "display source missing"; exit 1; }

if [[ ! -f "$OUT/.config" ]]; then
  echo "[*] generate peridot GKI config"
  make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH \
    vendor/peridot_GKI.config
fi

echo "[*] modules_prepare"
make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH modules_prepare

echo "[*] sign tools (if any)"
make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH scripts 2>/dev/null || true

echo "[*] build msm_drm out-of-tree"
make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH -j"$JOBS" \
    M="$DISPLAY_ROOT/msm" \
    KBUILD_EXTRA_SYMBOLS="$OUT/Module.symvers" \
    modules

echo "[*] locate result"
find "$DISPLAY_ROOT" -name 'msm_drm.ko' -exec ls -la {} \;
find "$DISPLAY_ROOT" -name 'msm_drm.ko' -exec cp {} "$OUT/msm_drm.ko" \; 2>/dev/null || true

echo "[*] done: $OUT/msm_drm.ko"