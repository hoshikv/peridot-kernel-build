#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="${KERNEL_DIR:-$ROOT/kernel}"
DD_DIR="${DD_DIR:-$ROOT/display-drivers}"
MODULES_DIR="${MODULES_DIR:-$ROOT/modules}"
OUT="$ROOT/out"
ARCH=arm64
JOBS="${JOBS:-$(nproc --ignore=2)}"
VENDOR_DLKM="$OUT/vendor_dlkm"
MODDIR="$VENDOR_DLKM/lib/modules"

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

mkdir -p "$OUT" "$MODDIR"
mkdir -p "$DISPLAY_ROOT/msm"

[[ -f "$KERNEL_DIR/Makefile" ]] || { echo "kernel tree missing"; exit 1; }
[[ -f "$DISPLAY_ROOT/msm/Kbuild" ]] || { echo "display source missing"; exit 1; }

# fix: key_pass undeclared
python3 - "$KERNEL_DIR/certs/extract-cert.c" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "#ifdef USE_PKCS11_ENGINE\nstatic const char *key_pass;\n#endif"
new = "static const char *key_pass;"
if old in s:
    s = s.replace(old, new)
    open(p, "w").write(s)
    print("[*] extract-cert.c patched")
else:
    print("[*] no patch needed")
EOF

# disable -Werror
sed -i 's/^KBUILD_CFLAGS += -Werror$/KBUILD_CFLAGS += -Wno-error/' \
  "$KERNEL_DIR/scripts/Makefile.extrawarn"

# companion modules source
if [[ ! -d "$MODULES_DIR/.git" ]]; then
  echo "[*] clone companion modules: $MODULES_URL"
  git clone --depth 1 "$MODULES_URL" "$MODULES_DIR"
fi
ln -sfn "$MODULES_DIR" "$ROOT/sm8635-modules"

# ---------- defconfig ----------
if [[ ! -f "$MERGED_DEFCONFIG" ]]; then
  echo "[*] merge config"
  ( cd "$KERNEL_DIR" && \
    "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -m -r \
      "$KERNEL_DIR/arch/$ARCH/configs/gki_defconfig" \
      "$VENDOR_CFG/pineapple_GKI.config" \
      "$VENDOR_CFG/peridot_GKI.config" 2>&1 | tail -4 )
  [[ -f "$KERNEL_DIR/.config" ]] && cp "$KERNEL_DIR/.config" "$MERGED_DEFCONFIG" || { echo "ERROR: merge_config produced no .config"; exit 1; }
  rm -f "$KERNEL_DIR/.config"
fi

if [[ ! -f "$OUT/.config" ]]; then
  echo "[*] configure using merged defconfig"
  cp "$MERGED_DEFCONFIG" "$OUT/.config"
else
  # compare: re-copy if merged defconfig changed
  if ! cmp -s "$MERGED_DEFCONFIG" "$OUT/.config"; then
    echo "[*] merged defconfig changed, reconfiguring"
    cp "$MERGED_DEFCONFIG" "$OUT/.config"
    # config changed => invalidate vmlinux/module rebuild guard minimally
    rm -f "$OUT/Module.symvers"
  fi
fi
"$KERNEL_DIR/scripts/config" --file "$OUT/.config" -d WERROR
"$KERNEL_DIR/scripts/config" --file "$OUT/.config" -d DEBUG_INFO_BTF

echo "[*] olddefconfig + modules_prepare"
make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH olddefconfig
make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH modules_prepare

# ---------- kernel + in-tree modules ----------
echo "[*] build vmlinux + in-tree modules"
if [[ ! -f "$OUT/Module.symvers" ]]; then
  make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH -j"$JOBS" vmlinux 2>&1 | tee "$OUT/vmlinux.log"
  rc=${PIPESTATUS[0]}
  [[ $rc -ne 0 ]] && { echo "ERROR: vmlinux build failed (rc=$rc)"; tail -50 "$OUT/vmlinux.log"; exit 1; }
  make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH -j"$JOBS" modules 2>&1 | tee "$OUT/modules.log"
  rc=${PIPESTATUS[0]}
  [[ $rc -ne 0 ]] && { echo "ERROR: modules build failed (rc=$rc)"; tail -50 "$OUT/modules.log"; exit 1; }
fi

echo "[*] build kernel Image"
make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH -j"$JOBS" Image dtbs
cp -f "$OUT/arch/arm64/boot/Image" "$OUT/Image" 2>/dev/null || true
gzip -9 -f -k "$OUT/Image" 2>/dev/null || true
ls -la "$OUT/Image" "$OUT/Image.gz" 2>/dev/null || true

# ---------- companion out-of-tree modules ----------
SYNC="$MMD/sync_fence"
HW="$MMD/hw_fence"
EXT="$MMD/msm_ext_display"
MMRM="$MM/mmrm-driver"
MMRM_SYM="$MMRM/driver"
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

# ---------- msm_drm out-of-tree (doze patched) ----------
# mi_dsi_panel.c does: #include "../../../../kernel/kernel/irq/internals.h"
# from $DISPLAY_ROOT/msm/mi_disp/ -> resolves to $ROOT/kernel/kernel/irq/internals.h
echo "[*] verify kernel/irq/internals.h reachable for display module"
REPO_KERNEL_IRQ="$ROOT/kernel/kernel/irq"
if [[ ! -f "$REPO_KERNEL_IRQ/internals.h" ]]; then
  echo "    internals.h not at $REPO_KERNEL_IRQ; creating symlink from KERNEL_DIR"
  if [[ -f "$KERNEL_DIR/kernel/irq/internals.h" ]]; then
    mkdir -p "$ROOT/kernel/kernel"
    ln -sfn "$KERNEL_DIR/kernel/irq" "$ROOT/kernel/kernel/irq"
  else
    echo "    ERROR: $KERNEL_DIR/kernel/irq/internals.h also missing"
  fi
fi
test -f "$REPO_KERNEL_IRQ/internals.h" && echo "    internals.h OK" || echo "    WARNING: internals.h still not found"

echo "[*] build msm_drm (doze patched)"
make -C "$KERNEL_DIR" O="$OUT" -j"$JOBS" ARCH=$ARCH \
    M="$DISPLAY_ROOT" DISPLAY_ROOT="$DISPLAY_ROOT" OUT="$OUT" \
    KBUILD_EXTRA_SYMBOLS="$SYNC/Module.symvers $HW/Module.symvers $EXT/Module.symvers $MMRM_SYM/Module.symvers $SECURE/Module.symvers" \
    CONFIG_DRM_MSM=y CONFIG_DRM_MSM_SDE=y CONFIG_SYNC_FILE=y CONFIG_DRM_MSM_DSI=y \
    CONFIG_DRM_MSM_DP=y CONFIG_DRM_MSM_DP_MST=y CONFIG_DSI_PARSER=y CONFIG_QCOM_MDSS_PLL=y \
    CONFIG_DRM_SDE_RSC=y CONFIG_DRM_SDE_WB=y CONFIG_DRM_MSM_REGISTER_LOGGING=y CONFIG_MSM_MMRM=y \
    CONFIG_DISPLAY_BUILD=m CONFIG_HDCP_QSEECOM=y CONFIG_DRM_SDE_VM=y CONFIG_QTI_HW_FENCE=y \
    CONFIG_QCOM_SPEC_SYNC=y CONFIG_QCOM_WCD939X_I2C=y MI_DISPLAY_MODIFY=y \
    modules 2>&1 | tee "$OUT/build.log"

find "$DISPLAY_ROOT" -name 'msm_drm.ko' -exec cp {} "$OUT/" \; 2>/dev/null || true
ls -la "$OUT/msm_drm.ko" 2>/dev/null || { echo "ERROR: msm_drm.ko not produced"; exit 1; }

# ---------- collect all .ko into vendor_dlkm ----------
echo "[*] collect all .ko into vendor_dlkm"
KVER=$(ls -d "$OUT/lib/modules/"*/ 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo "unknown")
echo "    kernel version dir: $KVER"

# 1) in-tree modules
if [[ -d "$OUT/lib/modules/$KVER" ]]; then
  find "$OUT/lib/modules/$KVER" -name '*.ko' -exec cp {} "$MODDIR/" \;
  echo "    in-tree: $(find "$MODDIR" -name '*.ko' | wc -l) modules"
fi

# 2) companion modules
for ko in "$SYNC"/*.ko "$HW"/*.ko "$EXT"/*.ko "$MMRM"/*.ko "$MMRM_SYM"/*.ko "$SECURE"/*.ko; do
  [[ -f "$ko" ]] && cp "$ko" "$MODDIR/"
done

# 3) msm_drm
cp -f "$OUT/msm_drm.ko" "$MODDIR/"

echo "    total .ko: $(find "$MODDIR" -name '*.ko' | wc -l)"

# ---------- generate modules.load ----------
echo "[*] generate modules.load"
find "$MODDIR" -name '*.ko' -printf '%f\n' | sort > "$MODDIR/modules.load"
echo "    modules.load: $(wc -l < "$MODDIR/modules.load") entries"

# ---------- generate modules.dep ----------
echo "[*] generate modules.dep"
> "$MODDIR/modules.dep"
for ko in "$MODDIR"/*.ko; do
  bn=$(basename "$ko")
  # for now, simple (no deps tracked between out-of-tree)
  echo "$bn:" >> "$MODDIR/modules.dep"
done

# ---------- package vendor_dlkm.img ----------
echo "[*] package vendor_dlkm.img"
KVERDIR="$VENDOR_DLKM/lib/modules/$KVER"
if [[ -d "$KVERDIR" ]]; then
  # move modules.load etc into versioned dir
  mv "$MODDIR/modules.load" "$KVERDIR/modules.load" 2>/dev/null || true
  mv "$MODDIR/modules.dep" "$KVERDIR/modules.dep" 2>/dev/null || true
  # move .ko from flat MODDIR into versioned dir
  find "$MODDIR" -maxdepth 1 -name '*.ko' -exec mv {} "$KVERDIR/" \; 2>/dev/null || true
  # symlink
  ln -sfn "$KVER" "$VENDOR_DLKM/lib/modules/latest" 2>/dev/null || true
fi

MKFS="$ROOT/../../tmp/opencode/erofs-install/bin/mkfs.erofs"
if [[ ! -x "$MKFS" ]]; then
  MKFS=$(command -v mkfs.erofs 2>/dev/null || echo "")
fi
if [[ -n "$MKFS" ]]; then
  "$MKFS" -z lz4 -b 4096 --all-root -T 0 \
    "$OUT/vendor_dlkm.img" "$VENDOR_DLKM" 2>&1 | tail -5
  ls -la "$OUT/vendor_dlkm.img"
else
  echo "    WARNING: mkfs.erofs not found, skipping vendor_dlkm.img packaging"
  echo "    vendor_dlkm contents at: $VENDOR_DLKM"
fi

echo ""
echo "========== BUILD COMPLETE =========="
ls -la "$OUT/Image" "$OUT/Image.gz" "$OUT/msm_drm.ko" "$OUT/vendor_dlkm.img" 2>/dev/null
echo "vermagic: $(strings "$OUT/msm_drm.ko" | grep -m1 'vermagic=')"
