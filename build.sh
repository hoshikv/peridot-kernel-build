#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="${KERNEL_DIR:-$ROOT/kernel}"
DD_DIR="${DD_DIR:-$ROOT/display-drivers}"
TD_DIR="${TD_DIR:-$ROOT/touch-drivers}"
AD_DIR="${AD_DIR:-$ROOT/audio-drivers}"
MODULES_DIR="${MODULES_DIR:-$ROOT/modules}"
OUT="$ROOT/out"
ARCH=arm64
JOBS="${JOBS:-$(nproc --ignore=2)}"
VENDOR_DLKM="$OUT/vendor_dlkm"
MODDIR="$VENDOR_DLKM/lib/modules"

# display driver = standalone repo (hoshikv/vendor_opensource_display-drivers-peridot),
# cloned by the workflow into $DD_DIR (msm/ at repo root).
DISPLAY_ROOT="$DD_DIR"
# touch driver = standalone repo (hoshikv/vendor_opensource_touch-drivers-peridot),
# cloned by the workflow into $TD_DIR (xiaomi/ goodix_berlin_driver/ focaltech_3683g/ at repo root).
TOUCH_ROOT="$TD_DIR"
# audio driver = standalone repo (hoshikv/vendor_opensource-audio-drivers-sm8635),
# cloned by the workflow into $AD_DIR (audio-kernel techpack at repo root).
AUDIO_ROOT="$AD_DIR"
MM="$MODULES_DIR/qcom/opensource"
MMD="$MM/mm-drivers"
VENDOR_CFG="$KERNEL_DIR/arch/$ARCH/configs/vendor"
MERGED_DEFCONFIG="$OUT/merged_defconfig"
MODULES_URL="${MODULES_URL:-https://github.com/GuidixX/kernel_xiaomi_sm8635-modules.git}"
DISPLAY_URL="${DISPLAY_URL:-https://github.com/hoshikv/vendor_opensource_display-drivers-peridot.git}"
TOUCH_URL="${TOUCH_URL:-https://github.com/hoshikv/vendor_opensource_touch-drivers-peridot.git}"
AUDIO_URL="${AUDIO_URL:-https://github.com/hoshikv/vendor_opensource-audio-drivers-sm8635.git}"

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
[[ -f "$DISPLAY_ROOT/msm/Kbuild" ]] || { echo "display source missing at $DISPLAY_ROOT/msm"; exit 1; }
[[ -f "$TOUCH_ROOT/Kbuild" ]] || { echo "touch source missing at $TOUCH_ROOT"; exit 1; }
[[ -f "$AUDIO_ROOT/Kbuild" ]] || { echo "audio source missing at $AUDIO_ROOT"; exit 1; }

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

# ---- match kernelxc build (the kernel that currently BOOTS on the device) ----
# so that msm_drm.ko / touch verbsmagic + modversions (CRC) equal the flashed
# kernel (identical to peridot-msm-drm-build).
# 1) bump SUBLEVEL 174 -> 175 (GuidixX 16.2 Makefile) to 6.1.175
if grep -qE '^SUBLEVEL = 174$' "$KERNEL_DIR/Makefile"; then
  sed -i 's/^SUBLEVEL = 174$/SUBLEVEL = 175/' "$KERNEL_DIR/Makefile"
  echo "[*] Makefile SUBLEVEL bumped to 175 (match kernelxc boot)"
else
  echo "[*] Makefile SUBLEVEL already not 174; leave as-is: $(grep -E '^SUBLEVEL = ' "$KERNEL_DIR/Makefile")"
fi
# 2) KMI-compatible LOCALVERSION (same as Theettam/kernelxc) -> stock vendor_dlkm loads
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-android14-11-ga3b9c44908dd-ab13320413"/' \
  "$KERNEL_DIR/arch/$ARCH/configs/gki_defconfig"
grep '^CONFIG_LOCALVERSION=' "$KERNEL_DIR/arch/$ARCH/configs/gki_defconfig" | head -1
# 3) keep git tree clean (drops the dirty '+' from setlocalversion)
( cd "$KERNEL_DIR" \
  && git config user.email "actions@users.noreply.github.com" \
  && git config user.name "github-actions" \
  && git add Makefile arch/$ARCH/configs/gki_defconfig \
  && git commit -m "bump to 6.1.175 + KMI LOCALVERSION" 2>&1 | tail -1 || true )
# 4) ensure LOCALVERSION env is set (even empty) so no trailing '+' (same as kernelxc)
export LOCALVERSION=

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
# hoshikv-shrink (match peridot-msm-drm-build): drop DWARF debug info from the
# whole build. Debug info is the reason msm_drm.ko was ~45MB instead of the stock
# ~5MB. Does NOT touch modversions (CRC) / vermagic, so modules still load.
"$KERNEL_DIR/scripts/config" --file "$OUT/.config" -d DEBUG_INFO
"$KERNEL_DIR/scripts/config" --file "$OUT/.config" -d DEBUG_INFO_BTF
"$KERNEL_DIR/scripts/config" --file "$OUT/.config" -d DEBUG_INFO_DWARF5
"$KERNEL_DIR/scripts/config" --file "$OUT/.config" -d DEBUG_INFO_DWARF4
"$KERNEL_DIR/scripts/config" --file "$OUT/.config" -d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
# Use STOCK (unsigned) vendor_dlkm modules -> disable module-signature enforcement
# so the .ko can be loaded on the flashed kernel.
"$KERNEL_DIR/scripts/config" --file "$OUT/.config" -d MODULE_SIG
"$KERNEL_DIR/scripts/config" --file "$OUT/.config" -d MODULE_SIG_FORCE
"$KERNEL_DIR/scripts/config" --file "$OUT/.config" -d MODULE_SIG_PROTECT
"$KERNEL_DIR/scripts/config" --file "$OUT/.config" -d MODULE_SIG_ALL
"$KERNEL_DIR/scripts/config" --file "$OUT/.config" -d MODULE_SIG_SHA256
"$KERNEL_DIR/scripts/config" --file "$OUT/.config" --set-str MODULE_SIG_HASH "sha1"

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
# force CONFIG_MSM_MMRM as a C define so the kernel header linux/soc/qcom/msm_mmrm.h
# takes the REAL-prototype branch (not the static-inline stubs), letting msm_mmrm.c
# provide the implementation without a "redefinition" error.
grep -q "^ccflags-y += -DCONFIG_MSM_MMRM=1" "$MMRM_SYM/Kbuild" || \
  sed -i 's/^ifdef CONFIG_MSM_MMRM$/ifdef CONFIG_MSM_MMRM\nccflags-y += -DCONFIG_MSM_MMRM=1 -DCONFIG_MSM_MMRM_MODULE/' "$MMRM_SYM/Kbuild"
make -C "$KERNEL_DIR" O="$OUT" -j"$JOBS" ARCH=$ARCH \
  SYNC_FENCE_ROOT="$MMD/" MSM_HW_FENCE_ROOT="$MMD/" MMRM_ROOT="$MM/mmrm-driver" \
  KBUILD_EXTRA_SYMBOLS="$SYNC/Module.symvers $HW/Module.symvers $EXT/Module.symvers" \
  CONFIG_MSM_MMRM=m CONFIG_DRM_MSM=y CONFIG_DRM_MSM_SDE=y \
  M="$MMRM_SYM" modules >"$OUT/mmrm.log" 2>&1 || {
    echo "ERROR: mmrm build failed (exit $?)"
    grep -nE "error:|fatal|undefined|no member|undeclared|cannot|No rule|No such" "$OUT/mmrm.log" | head -40 || true
    echo "----- last 8 lines of mmrm.log -----"
    tail -8 "$OUT/mmrm.log"
    exit 1
  }

echo "    mmrm Module.symvers: $MMRM_SYM/Module.symvers"
grep -c "mmrm_client" "$MMRM_SYM/Module.symvers" 2>/dev/null | xargs echo "    mmrm_client exports in symvers:" || true

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
    KERNEL_SRC="$KERNEL_DIR" KERNEL_ROOT="$KERNEL_DIR" \
    KBUILD_EXTRA_SYMBOLS="$SYNC/Module.symvers $HW/Module.symvers $EXT/Module.symvers $MMRM_SYM/Module.symvers $SECURE/Module.symvers" \
    CONFIG_ARCH_PINEAPPLE=y CONFIG_DRM_MSM=y CONFIG_DRM_MSM_SDE=y CONFIG_SYNC_FILE=y CONFIG_DRM_MSM_DSI=y \
    CONFIG_DRM_MSM_DP=y CONFIG_DRM_MSM_DP_MST=y CONFIG_DSI_PARSER=y CONFIG_QCOM_MDSS_PLL=y \
    CONFIG_DRM_SDE_RSC=y CONFIG_DRM_SDE_WB=y CONFIG_GKI_DISPLAY=y CONFIG_MSM_EXT_DISPLAY=y \
    CONFIG_MSM_MMRM=y CONFIG_DISPLAY_BUILD=m CONFIG_HDCP_QSEECOM=y CONFIG_QTI_HW_FENCE=y \
    CONFIG_QCOM_SPEC_SYNC=y CONFIG_QCOM_WCD939X_I2C=y MI_DISPLAY_MODIFY=y \
    modules 2>&1 | tee "$OUT/build.log"

find "$DISPLAY_ROOT" -name 'msm_drm.ko' -exec llvm-strip --strip-debug {} \; 2>/dev/null || true
find "$DISPLAY_ROOT" -name 'msm_drm.ko' -exec cp {} "$OUT/" \; 2>/dev/null || true
ls -la "$OUT/msm_drm.ko" 2>/dev/null || { echo "ERROR: msm_drm.ko not produced"; exit 1; }

# ---------- touch drivers out-of-tree (grewal xiaomi + goodix + focaltech) ----------
echo "[*] build touch drivers ($TOUCH_ROOT)"
mkdir -p "$OUT/touch_modules"
make -C "$KERNEL_DIR" O="$OUT" -j"$JOBS" ARCH=$ARCH \
    M="$TOUCH_ROOT" TOUCH_ROOT="$TOUCH_ROOT" \
    KERNEL_SRC="$KERNEL_DIR" KERNEL_ROOT="$KERNEL_DIR" \
    KBUILD_EXTRA_SYMBOLS="$SYNC/Module.symvers $HW/Module.symvers $EXT/Module.symvers $MMRM_SYM/Module.symvers $SECURE/Module.symvers" \
    CONFIG_ARCH_PINEAPPLE=y CONFIG_MSM_TOUCH=m \
    CONFIG_TOUCHSCREEN_GOODIX_BRL=y \
    CONFIG_TOUCHSCREEN_FOCALTECH_3683G=y \
    CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE=y \
    CONFIG_TOUCHSCREEN_NT36XXX_I2C=n CONFIG_TOUCHSCREEN_ATMEL_MXT=n \
    CONFIG_TOUCHSCREEN_DUMMY=n CONFIG_TOUCHSCREEN_SYNAPTICS_TCM=n \
    CONFIG_QTS_ENABLE=y CONFIG_TOUCH_FOCALTECH=n \
    CONFIG_TOUCHSCREEN_PARADE=n CONFIG_TOUCHSCREEN_RAIDYUM=n \
    MODNAME=touch_dlkm \
    modules 2>&1 | tee "$OUT/touch.log" || {
      echo "ERROR: touch build failed"
      grep -nE "error:|fatal|undefined|no member|undeclared|cannot|No rule|No such" "$OUT/touch.log" | head -40 || true
      exit 1
    }
find "$TOUCH_ROOT" -name '*.ko' -print -exec cp {} "$OUT/touch_modules/" \;
for ko in "$OUT/touch_modules"/*.ko; do llvm-strip --strip-debug "$ko" 2>/dev/null || true; done
echo "    touch modules: $(ls "$OUT/touch_modules" 2>/dev/null | tr '\n' ' ')"

# ---------- audio drivers out-of-tree (aw882xx + fs19xx + full audio techpack) ----------
echo "[*] build audio drivers ($AUDIO_ROOT)"
mkdir -p "$OUT/audio_modules"
make -C "$KERNEL_DIR" O="$OUT" -j"$JOBS" ARCH=$ARCH \
    M="$AUDIO_ROOT" AUDIO_ROOT="$AUDIO_ROOT" OUT="$OUT" OUT_DIR="$OUT" \
    KERNEL_SRC="$KERNEL_DIR" KERNEL_ROOT="$KERNEL_DIR" \
    KBUILD_EXTRA_SYMBOLS="$SYNC/Module.symvers $HW/Module.symvers $EXT/Module.symvers $MMRM_SYM/Module.symvers $SECURE/Module.symvers" \
    CONFIG_ARCH_PINEAPPLE=y \
    BOARD_PLATFORM=pineapple TARGET_BOARD_PLATFORM=pineapple \
    MODNAME=audio_dlkm \
    modules 2>&1 | tee "$OUT/audio.log" || {
      echo "ERROR: audio build failed"
      grep -nE "error:|fatal|undefined|no member|undeclared|cannot|No rule|No such" "$OUT/audio.log" | head -40 || true
      echo "----- last 8 lines of audio.log -----"
      tail -8 "$OUT/audio.log"
      exit 1
    }
find "$AUDIO_ROOT" -name '*.ko' -print -exec cp {} "$OUT/audio_modules/" \;
for ko in "$OUT/audio_modules"/*.ko; do llvm-strip --strip-debug "$ko" 2>/dev/null || true; done
echo "    audio modules: $(ls "$OUT/audio_modules" 2>/dev/null | tr '\n' ' ')"

# ---------- qti battery ko (in-tree, from kernel source) ----------
echo "[*] collect qti battery modules"
for b in \
  "$OUT/drivers/power/supply/qti_battery_charger.ko" \
  "$OUT/drivers/soc/qcom/qti_battery_debug.ko"; do
  if [[ -f "$b" ]]; then
    cp -f "$b" "$OUT/"
    echo "    OK: $(basename "$b")"
  else
    echo "    WARN: $(basename "$b") not built"
  fi
done

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

# 2b) audio drivers
for ko in "$OUT/audio_modules"/*.ko; do
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

# ---------- package vendor_dlkm.img (SKIPPED: not needed, keep .ko + dir) ----------
echo "[*] vendor_dlkm.img packaging SKIPPED (only kernel Image + .ko modules deployed)"
echo "    vendor_dlkm contents at: $VENDOR_DLKM"

echo ""
echo "========== BUILD COMPLETE =========="
ls -la "$OUT/Image" "$OUT/Image.gz" "$OUT/msm_drm.ko" "$OUT/vendor_dlkm.img" 2>/dev/null || true
ls -la "$OUT/qti_battery_charger.ko" "$OUT/touch_modules/"*.ko 2>/dev/null || true
echo "vermagic: $(strings "$OUT/msm_drm.ko" | grep -m1 'vermagic=')"
