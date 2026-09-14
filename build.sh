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

# filtered walt exports for OOT consumers: walt's fixup.o re-exports core GKI
# symbols that already live in vmlinux.symvers -> modpost would flag those as
# 'exported twice' if passed verbatim. Dedup against vmlinux.symvers.
awk 'NR==FNR{k[$2]=1;next}!k[$2]' \
  "$OUT/vmlinux.symvers" "$OUT/kernel/sched/walt/Module.symvers" \
  > "$OUT/walt-extra.symvers" 2>/dev/null || true

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

# ---------- OPLUS frameboost DLKM modules (out-of-tree) ----------
# The module repos are FLAT (one folder per module). We stage a symlink farm
# that mirrors the OPLUS kernel/oplus_cpu layout, then mount it into the kernel
# tree so the OPLUS `#include <../kernel/oplus_cpu/...>` / `<../kernel/sched/...>`
# / `"../sched/..."` relative include paths resolve during builds.
STAGE="$OUT/oplus-stage"
FB_STAGE="$STAGE/fb/kernel"
FB_DIR="${FB_DIR:-$ROOT/frameboost-drivers}"
FB_URL="${FB_URL:-https://github.com/hoshikv/vendor_frameboost-drivers}"
echo "[*] frameboost drivers ($FB_DIR)"
if [[ ! -d "$FB_DIR/.git" ]]; then
  git clone --depth 1 "$FB_URL" "$FB_DIR"
fi
test -f "$FB_DIR/sched_assist/Makefile" || { echo "frameboost source missing (sched_assist)"; exit 1; }
mkdir -p "$FB_STAGE/oplus_cpu/sched"
for pair in "sched_assist:sched_assist" "frame_boost:frame_boost" "qos_sched:qos_sched" \
            "sched_tune:sched_tune" "eas_opt:eas_opt"; do
  ln -sfn "$FB_DIR/${pair%%:*}" "$FB_STAGE/oplus_cpu/sched/${pair##*:}"
done
ln -sfn "$FB_DIR/uad"  "$FB_STAGE/oplus_cpu/uad"
ln -sfn "$FB_DIR/hans" "$FB_STAGE/oplus_cpu/hans"
ln -sfn "$FB_STAGE/oplus_cpu" "$KERNEL_DIR/oplus_cpu"

FB_DIR_SRC="$FB_STAGE/oplus_cpu"   # relative dirs below are under this

fb_inject() { # $1=rel dir  $2=defines (prefer Kbuild; others have plain Makefile)
  local f="$FB_DIR_SRC/$1/Kbuild"
  [[ -f "$f" ]] || f="$FB_DIR_SRC/$1/Makefile"
  for d in $2; do
    grep -qF -- "$d" "$f" || echo "ccflags-y += -D$d=1" >> "$f"
  done
}
fb_inject sched/sched_tune   "CONFIG_OPLUS_SYSTEM_KERNEL_QCOM CONFIG_OPLUS_SCHED_TUNE"
fb_inject sched/eas_opt      "CONFIG_OPLUS_SYSTEM_KERNEL_QCOM CONFIG_OPLUS_FEATURE_EAS_OPT CONFIG_OPLUS_FEATURE_VT_CAP CONFIG_OPLUS_CPUFREQ_IOWAIT_PROTECT"
fb_inject sched/sched_assist "CONFIG_OPLUS_SYSTEM_KERNEL_QCOM CONFIG_OPLUS_FEATURE_SCHED_ASSIST"
fb_inject sched/frame_boost  "CONFIG_OPLUS_SYSTEM_KERNEL_QCOM CONFIG_OPLUS_FEATURE_FRAME_BOOST"
fb_inject sched/qos_sched    "CONFIG_OPLUS_SYSTEM_KERNEL_QCOM CONFIG_OPLUS_FEATURE_QOS_SCHED"
fb_inject uad                "CONFIG_OPLUS_SYSTEM_KERNEL_QCOM CONFIG_OPLUS_CPU_FREQ_GOV_UAG CONFIG_UA_KERNEL_CPU_IOCTL CONFIG_OPLUS_FEATURE_FRAME_BOOST"
fb_inject hans               "CONFIG_OPLUS_SYSTEM_KERNEL_QCOM CONFIG_OPLUS_FEATURE_HANS"

fb_license() { # $1=rel dir
  local d="$FB_DIR_SRC/$1" f of var
  if ! grep -raq 'MODULE_LICENSE' "$d" --include='*.c'; then
    echo -e '#include <linux/module.h>\nMODULE_LICENSE("GPL");' > "$d/license.c"
    f="$d/Kbuild"; [[ -f "$f" ]] || f="$d/Makefile"
    of=$(grep -oE '^obj-\$\([A-Za-z0-9_]+\)[[:space:]]+\+=[[:space:]]+[A-Za-z0-9_]+\.o' "$f" | head -1 | awk '{print $3}')
    var="${of%.o}-y"
    if [[ -n "$of" && -n "$var" ]]; then
      grep -q 'license.o' "$f" || echo "$var += license.o" >> "$f"
      echo "  + license.c (missing MODULE_LICENSE) in $1 [$var]"
    else
      echo "  ! license.c created but no obj line found to extend in $1"
    fi
  fi
}
fb_license sched/sched_tune
fb_license hans

fb_msym() { # $1=rel dir -> print existing Module.symvers (source or out) if any
  local cand
  for cand in "$FB_DIR_SRC/$1/Module.symvers" \
              "$OUT/$1/Module.symvers" \
              "$OUT/oplus_stage/$(basename "$1")/Module.symvers"; do
    [[ -f "$cand" ]] && { echo "$cand"; return 0; }
  done
  return 1
}
fb_cache() { # $1=rel dir : snapshot the module symvers for later consumers
  local p=$(fb_msym "$1") n=${1//\//_}
  if [[ -f "$p" ]]; then
    cp -f "$p" "$OUT/msym/$n.symvers"
  else
    : > "$OUT/msym/$n.symvers"
  fi
  echo "  cached symvers $OUT/msym/$n.symvers"
}
mkdir -p "$OUT/msym"

fb_mbuild() { # $1=rel dir  $2=extra Module.symvers  rest=CONFIG args
  local M="$1"; shift
  local EXTRA="$1"; shift
  make -C "$KERNEL_DIR" O="$OUT" -j"$JOBS" ARCH=$ARCH \
    KERNEL_SRC="$KERNEL_DIR" KERNEL_ROOT="$KERNEL_DIR" \
    KBUILD_EXTRA_SYMBOLS="$OUT/walt-extra.symvers $EXTRA" \
    CONFIG_ARCH_PINEAPPLE=y \
    M="$FB_DIR_SRC/$M" "$@" modules 2>&1 | tee -a "$OUT/frameboost.log" || {
      echo "ERROR: frameboost module $M failed"
      grep -nE "error:|fatal|undefined|no member|undeclared|cannot|No rule|No such" "$OUT/frameboost.log" | head -40 || true
      exit 1
    }
}

echo "[*] build frameboost sched_tune"
fb_mbuild sched/sched_tune "" \
  CONFIG_OPLUS_SCHED_TUNE=m CONFIG_OPLUS_SYSTEM_KERNEL_QCOM=y
fb_cache sched/sched_tune
echo "[*] build frameboost eas_opt"
fb_mbuild sched/eas_opt "" \
  CONFIG_OPLUS_FEATURE_EAS_OPT=m CONFIG_OPLUS_SYSTEM_KERNEL_QCOM=y \
  CONFIG_OPLUS_FEATURE_VT_CAP=y CONFIG_OPLUS_CPUFREQ_IOWAIT_PROTECT=y
fb_cache sched/eas_opt
echo "[*] build frameboost sched_assist"
fb_mbuild sched/sched_assist "$OUT/msym/sched_tune.symvers" \
  CONFIG_OPLUS_FEATURE_SCHED_ASSIST=m CONFIG_OPLUS_SYSTEM_KERNEL_QCOM=y
fb_cache sched/sched_assist
echo "[*] build frameboost frame_boost"
fb_mbuild sched/frame_boost "$OUT/msym/sched_assist.symvers" \
  CONFIG_OPLUS_FEATURE_FRAME_BOOST=m CONFIG_OPLUS_SYSTEM_KERNEL_QCOM=y
fb_cache sched/frame_boost
echo "[*] build frameboost qos_sched"
fb_mbuild sched/qos_sched "$OUT/msym/sched_assist.symvers $OUT/msym/frame_boost.symvers" \
  CONFIG_OPLUS_FEATURE_QOS_SCHED=m CONFIG_OPLUS_SYSTEM_KERNEL_QCOM=y
fb_cache sched/qos_sched
echo "[*] build frameboost uad (uag governor + ua_ioctl)"
fb_mbuild uad "$OUT/msym/eas_opt.symvers $OUT/msym/frame_boost.symvers" \
  CONFIG_OPLUS_CPU_FREQ_GOV_UAG=m CONFIG_UA_KERNEL_CPU_IOCTL=m CONFIG_OPLUS_SYSTEM_KERNEL_QCOM=y
fb_cache uad
echo "[*] build frameboost hans"
fb_mbuild hans "" CONFIG_OPLUS_FEATURE_HANS=m CONFIG_OPLUS_SYSTEM_KERNEL_QCOM=y

echo "[*] collect frameboost modules"
mkdir -p "$OUT/frameboost_modules"
while IFS= read -r ko; do
  [[ -f "$ko" ]] && cp "$ko" "$OUT/frameboost_modules/"
done < <(find "$FB_DIR" -name '*.ko')
for ko in "$OUT/frameboost_modules"/*.ko; do llvm-strip --strip-debug "$ko" 2>/dev/null || true; done
echo "    frameboost modules: $(ls "$OUT/frameboost_modules" 2>/dev/null | tr '\n' ' ')"

# ---------- OPLUS hybridswap DLKM modules (out-of-tree) ----------
HS_STAGE="$STAGE/hs/kernel"
HS_DIR="${HS_DIR:-$ROOT/hybridswap-driver}"
HS_URL="${HS_URL:-https://github.com/hoshikv/vendor_oplus-hybridswap-driver}"
echo "[*] hybridswap drivers ($HS_DIR)"
if [[ ! -d "$HS_DIR/.git" ]]; then
  git clone --depth 1 "$HS_URL" "$HS_DIR"
fi
test -f "$HS_DIR/hybridswap_zram/Makefile" || { echo "hybridswap source missing"; exit 1; }
mkdir -p "$HS_STAGE/oplus_mm" "$HS_STAGE/oplus_cpu/sched/sched_assist"
ln -sfn "$HS_DIR/hybridswap_zram" "$HS_STAGE/oplus_mm/hybridswap_zram"
ln -sfn "$HS_DIR/mm_osvelte"       "$HS_STAGE/oplus_mm/mm_osvelte"
ln -sfn "$HS_DIR/sa_common.h"      "$HS_STAGE/oplus_cpu/sched/sched_assist/sa_common.h"
ln -sfn "$HS_STAGE/oplus_mm"       "$KERNEL_DIR/mm/oplus_mm"
ln -sfn "$HS_STAGE/oplus_cpu"      "$KERNEL_DIR/oplus_cpu"

hs_inject() { # $1=tree-relative (under hybridswap_zram)  $2=defines
  local f="$KERNEL_DIR/mm/oplus_mm/$1/Makefile"
  [[ -f "$f" ]] || f="$KERNEL_DIR/mm/oplus_mm/$1/Kbuild"
  for d in $2; do
    grep -qF -- "$d" "$f" || echo "ccflags-y += -D$d=1" >> "$f"
  done
}
hs_inject . "CONFIG_HYBRIDSWAP CONFIG_HYBRIDSWAP_SWAPD CONFIG_HYBRIDSWAP_CORE"

hs_mbuild() { # $1=M dir (tree-relative)  rest=CONFIG args
  local M="$1"; shift
  make -C "$KERNEL_DIR" O="$OUT" -j"$JOBS" ARCH=$ARCH \
    KERNEL_SRC="$KERNEL_DIR" KERNEL_ROOT="$KERNEL_DIR" \
    CONFIG_ARCH_PINEAPPLE=y \
    M="$KERNEL_DIR/mm/oplus_mm/$M" "$@" modules 2>&1 | tee -a "$OUT/hybridswap.log" || {
      echo "ERROR: hybridswap module $M failed"
      grep -nE "error:|fatal|undefined|no member|undeclared|cannot|No rule|No such" "$OUT/hybridswap.log" | head -40 || true
      exit 1
    }
}

echo "[*] build hybridswap lz4k"
hs_mbuild hybridswap_zram/lz4k CONFIG_CRYPTO_LZ4K=m
echo "[*] build hybridswap zstd (zstdn)"
hs_mbuild hybridswap_zram/zstd CONFIG_CRYPTO_ZSTDN=m
echo "[*] build hybridswap zram root"
hs_mbuild hybridswap_zram \
  CONFIG_HYBRIDSWAP_ZRAM=m CONFIG_HYBRIDSWAP=y \
  CONFIG_HYBRIDSWAP_SWAPD=y CONFIG_HYBRIDSWAP_CORE=y

echo "[*] collect hybridswap modules"
mkdir -p "$OUT/hybridswap_modules"
while IFS= read -r ko; do
  [[ -f "$ko" ]] && cp "$ko" "$OUT/hybridswap_modules/"
done < <(find "$HS_DIR/hybridswap_zram" -name '*.ko')
for ko in "$OUT/hybridswap_modules"/*.ko; do llvm-strip --strip-debug "$ko" 2>/dev/null || true; done
echo "    hybridswap modules: $(ls "$OUT/hybridswap_modules" 2>/dev/null | tr '\n' ' ')"

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
# 2c) frameboost drivers
for ko in "$OUT/frameboost_modules"/*.ko; do
  [[ -f "$ko" ]] && cp "$ko" "$MODDIR/"
done
# 2d) hybridswap drivers
for ko in "$OUT/hybridswap_modules"/*.ko; do
  [[ -f "$ko" ]] && cp "$ko" "$MODDIR/"
done
# the OPLUS hybridswap zram replaces the stock GKI zram.ko (same "zram" major).
if ls "$MODDIR"/oplus_bsp_hybridswap_zram.ko >/dev/null 2>&1; then
  rm -f "$MODDIR/zram.ko"
  echo "    (stock zram.ko removed — OPLUS hybridswap zram takes over)"
fi


# 3) msm_drm
cp -f "$OUT/msm_drm.ko" "$MODDIR/"

echo "    total .ko: $(find "$MODDIR" -name '*.ko' | wc -l)"

# ---------- generate modules.load ----------
# frameboost/hybridswap modules must load in dependency order
FB_ORDER="sched-walt oplus_bsp_schedtune oplus_bsp_eas_opt oplus_bsp_sched_assist oplus_bsp_frame_boost oplus_bsp_qos_sched cpufreq_uag ua_cpu_ioctl oplus_hans"
HS_ORDER="crypto_zstdn oplus_bsp_lz4k oplus_bsp_hybridswap_zram"
echo "[*] generate modules.load"
{
  for b in $FB_ORDER; do
    [[ -f "$MODDIR/$b.ko" ]] && echo "$b.ko"
  done
  for b in $HS_ORDER; do
    [[ -f "$MODDIR/$b.ko" ]] && echo "$b.ko"
  done
  {
    printf '%s\n' $FB_ORDER | sed 's/$/.ko/'
    printf '%s\n' $HS_ORDER | sed 's/$/.ko/'
  } > "$MODDIR/.ordered"
  find "$MODDIR" -maxdepth 1 -name '*.ko' -printf '%f\n' | sort | \
    grep -vxFf "$MODDIR/.ordered"
  rm -f "$MODDIR/.ordered"
} > "$MODDIR/modules.load"
echo "    modules.load: $(wc -l < "$MODDIR/modules.load") entries"
head -20 "$MODDIR/modules.load" | tail -16

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
