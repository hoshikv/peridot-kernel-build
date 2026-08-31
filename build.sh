#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="${KERNEL_DIR:-$ROOT/kernel}"
DD_DIR="${DD_DIR:-$ROOT/display-drivers}"
MODULES_DIR="${MODULES_DIR:-$ROOT/modules}"
OUT="$ROOT/out"
ARCH=arm64
JOBS="${JOBS:-$(nproc --ignore=2)}"

DISPLAY_ROOT="$DD_DIR/vendor_opensource_display-drivers-peridot-u-oss"
MM="$MODULES_DIR/qcom/opensource"
MMD="$MM/mm-drivers"
VENDOR_CFG="$KERNEL_DIR/arch/$ARCH/configs/vendor"
MERGED_DEFCONFIG="$OUT/merged_defconfig"
MODULES_URL="${MODULES_URL:-https://github.com/crdroidandroid/android_kernel_xiaomi_sm8635-modules.git}"

if [[ -n "${CLANG_DIR:-}" ]]; then
  export CC="$CLANG_DIR/bin/clang"
  export PATH="$CLANG_DIR/bin:$PATH"
else
  export CC="$(command -v clang)"
fi
export LLVM=1
export LLVM_IAS=1
export SUBARCH=arm64
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export STRIP=llvm-strip
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export READELF=llvm-readelf

mkdir -p "$OUT"
mkdir -p "$DISPLAY_ROOT/msm"

[[ -f "$KERNEL_DIR/Makefile" ]] || { echo "kernel tree missing"; exit 1; }
[[ -f "$DISPLAY_ROOT/msm/Kbuild" ]] || { echo "display source missing"; exit 1; }

# fix: key_pass undeclared when USE_PKCS11_ENGINE not defined but pkcs11 branch compiled
python3 - "$KERNEL_DIR/certs/extract-cert.c" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "#ifdef USE_PKCS11_ENGINE\nstatic const char *key_pass;\n#endif"
new = "static const char *key_pass;"
if old in s:
    s = s.replace(old, new)
    open(p, "w").write(s)
    print("[*] extract-cert.c patched (key_pass unconditional)")
else:
    print("[*] no patch needed")
EOF

# disable -Werror (clang r530567 lebih baru dari source ACK 6.1)
sed -i 's/^KBUILD_CFLAGS += -Werror$/KBUILD_CFLAGS += -Wno-error/' \
  "$KERNEL_DIR/scripts/Makefile.extrawarn"

# companion modules source (crdroid sm8635)
if [[ ! -d "$MODULES_DIR/.git" ]]; then
  echo "[*] clone companion modules: $MODULES_URL"
  git clone --depth 1 "$MODULES_URL" "$MODULES_DIR"
fi
# securemsm trace header requires TLMM ../sm8635-modules symlink
ln -sfn "$MODULES_DIR" "$ROOT/sm8635-modules"

if [[ ! -f "$MERGED_DEFCONFIG" ]]; then
  echo "[*] merge config gki_defconfig + pineapple_GKI + peridot_GKI"
  "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -m -r \
    "$KERNEL_DIR/arch/$ARCH/configs/gki_defconfig" \
    "$VENDOR_CFG/pineapple_GKI.config" \
    "$VENDOR_CFG/peridot_GKI.config" 2>&1 | tail -4
  [[ -f "$KERNEL_DIR/.config" ]] && cp "$KERNEL_DIR/.config" "$MERGED_DEFCONFIG"
  rm -f "$KERNEL_DIR/.config"
fi

if [[ ! -f "$OUT/.config" ]]; then
  echo "[*] configure using merged defconfig"
  cp "$MERGED_DEFCONFIG" "$OUT/.config"
fi
"$KERNEL_DIR/scripts/config" --file "$OUT/.config" -d WERROR

echo "[*] olddefconfig + modules_prepare"
make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH olddefconfig
make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH modules_prepare

echo "[*] build vmlinux + in-tree modules (Module.symvers utk CRC)"
if [[ ! -f "$OUT/Module.symvers" ]]; then
  make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH -j"$JOBS" vmlinux
  make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH -j"$JOBS" modules
fi

echo "[*] build kernel Image (untuk boot)"
make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH -j"$JOBS" Image dtbs
cp -f "$OUT/arch/arm64/boot/Image" "$OUT/Image" 2>/dev/null || true
gzip -9 -f -k "$OUT/Image" 2>/dev/null || true
ls -la "$OUT/Image" "$OUT/Image.gz" 2>/dev/null || true

# ---------- companion out-of-tree modules (dependencies of msm_drm) ----------
SYNC="$MMD/sync_fence"
HW="$MMD/hw_fence"
EXT="$MMD/msm_ext_display"
MMRM="$MM/mmrm-driver/driver"
SECURE="$MM/securemsm-kernel"

echo "[*] build sync_fence"
make -C "$KERNEL_DIR" O="$OUT" -j"$JOBS" ARCH=$ARCH \
  SYNC_FENCE_ROOT="$MMD/" MSM_HW_FENCE_ROOT="$MMD/" \
  M="$SYNC" modules 2>&1 | tail -3

echo "[*] build hw_fence"
make -C "$KERNEL_DIR" O="$OUT" -j"$JOBS" ARCH=$ARCH \
  SYNC_FENCE_ROOT="$MMD/" MSM_HW_FENCE_ROOT="$MMD/" \
  M="$HW" modules 2>&1 | tail -3

echo "[*] build msm_ext_display"
make -C "$KERNEL_DIR" O="$OUT" -j"$JOBS" ARCH=$ARCH \
  SYNC_FENCE_ROOT="$MMD/" MSM_HW_FENCE_ROOT="$MMD/" MSM_EXT_DISPLAY_ROOT="$MMD/" \
  KBUILD_EXTRA_SYMBOLS="$SYNC/Module.symvers $HW/Module.symvers" \
  M="$EXT" modules 2>&1 | tail -3

echo "[*] build mmrm"
make -C "$KERNEL_DIR" O="$OUT" -j"$JOBS" ARCH=$ARCH \
  SYNC_FENCE_ROOT="$MMD/" MSM_HW_FENCE_ROOT="$MMD/" MMRM_ROOT="$MM/mmrm-driver" \
  KBUILD_EXTRA_SYMBOLS="$SYNC/Module.symvers $HW/Module.symvers $EXT/Module.symvers" \
  M="$MMRM" modules 2>&1 | tail -3

echo "[*] build securemsm (hdcp + smcinvoke + tz_log)"
make -C "$KERNEL_DIR" O="$OUT" -j"$JOBS" ARCH=$ARCH \
  SSG_MODULE_ROOT="$MM/securemsm-kernel" \
  CONFIG_QCOM_SMCINVOKE=m CONFIG_HDCP_QSEECOM=m CONFIG_QTI_TZ_LOG=m \
  M="$SECURE" modules 2>&1 | tail -3

ls -la "$SYNC/Module.symvers" "$HW/Module.symvers" "$EXT/Module.symvers" \
      "$MM/mmrm-driver/Module.symvers" "$SECURE/Module.symvers"

# ---------- msm_drm out-of-tree (target yang di-patch) ----------
echo "[*] build msm_drm"
make -C "$KERNEL_DIR" O="$OUT" -j"$JOBS" ARCH=$ARCH \
    M="$DISPLAY_ROOT" DISPLAY_ROOT="$DISPLAY_ROOT" OUT="$OUT" \
    KBUILD_EXTRA_SYMBOLS="$SYNC/Module.symvers $HW/Module.symvers $EXT/Module.symvers $MM/mmrm-driver/Module.symvers $SECURE/Module.symvers" \
    CONFIG_DRM_MSM=y CONFIG_DRM_MSM_SDE=y CONFIG_SYNC_FILE=y CONFIG_DRM_MSM_DSI=y \
    CONFIG_DRM_MSM_DP=y CONFIG_DRM_MSM_DP_MST=y CONFIG_DSI_PARSER=y CONFIG_QCOM_MDSS_PLL=y \
    CONFIG_DRM_SDE_RSC=y CONFIG_DRM_SDE_WB=y CONFIG_DRM_MSM_REGISTER_LOGGING=y CONFIG_MSM_MMRM=y \
    CONFIG_DISPLAY_BUILD=m CONFIG_HDCP_QSEECOM=y CONFIG_DRM_SDE_VM=y CONFIG_QTI_HW_FENCE=y \
    CONFIG_QCOM_SPEC_SYNC=y CONFIG_QCOM_WCD939X_I2C=y MI_DISPLAY_MODIFY=y \
    modules 2>&1 | tee "$OUT/build.log"

echo "[*] locate result"
find "$DISPLAY_ROOT" -name 'msm_drm.ko' -exec ls -la {} \; 2>/dev/null || true
find "$DISPLAY_ROOT" -name 'msm_drm.ko' -exec cp {} "$OUT/" \; 2>/dev/null || true

ls -la "$OUT/msm_drm.ko" 2>/dev/null || { echo "ERROR: msm_drm.ko not produced"; exit 1; }
echo "[*] done: $OUT/msm_drm.ko + $OUT/Image"