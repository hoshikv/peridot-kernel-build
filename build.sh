#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="${KERNEL_DIR:-$ROOT/kernel}"
DD_DIR="${DD_DIR:-$ROOT/display-drivers}"
OUT="$ROOT/out"
ARCH=arm64
JOBS="${JOBS:-$(nproc --ignore=2)}"

DISPLAY_ROOT="$DD_DIR/vendor_opensource_display-drivers-peridot-u-oss"
VENDOR_CFG="$KERNEL_DIR/arch/$ARCH/configs/vendor"
MERGED_DEFCONFIG="$OUT/merged_defconfig"

if [[ -n "${CLANG_DIR:-}" ]]; then
  export CC="$CLANG_DIR/bin/clang"
  export PATH="$CLANG_DIR/bin:$PATH"
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

echo "[*] build msm_drm out-of-tree"
make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH -j"$JOBS" \
    M="$DISPLAY_ROOT/msm" \
    KBUILD_EXTRA_SYMBOLS="$OUT/Module.symvers" \
    modules 2>&1 | tee "$OUT/build.log"

echo "[*] locate result"
find "$DISPLAY_ROOT" -name 'msm_drm.ko' -exec ls -la {} \; 2>/dev/null || true
find "$DISPLAY_ROOT" -name 'msm_drm.ko' -exec cp {} "$OUT/" \; 2>/dev/null || true

echo "[*] done: $OUT/msm_drm.ko"