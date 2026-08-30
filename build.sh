#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="${KERNEL_DIR:-$ROOT/kernel}"
DD_DIR="${DD_DIR:-$ROOT/display-drivers}"
OUT="$ROOT/out"
ARCH=arm64
JOBS="${JOBS:-$(nproc --ignore=2)}"

DISPLAY_ROOT="$DD_DIR/vendor_opensource_display-drivers-peridot-u-oss"
CFG_LINEAGE="$KERNEL_DIR/arch/$ARCH/configs/vendor/peridot_GKI.config"

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
    print("[*] no patch needed (key_pass already unconditional or pattern absent)")
EOF

if [[ ! -f "$OUT/.config" ]]; then
  echo "[*] configure kernel (defconfig linege peridot)"
  make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH defconfig
fi
echo "[*] disable -Werror (clang r530567 lebih baru dari source ACK 6.1)"
"$KERNEL_DIR/scripts/config" --file "$OUT/.config" -d WERROR
sed -i 's/^KBUILD_CFLAGS += -Werror$/KBUILD_CFLAGS += -Wno-error/' \
  "$KERNEL_DIR/scripts/Makefile.extrawarn"
make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH olddefconfig

echo "[*] modules_prepare"
make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH modules_prepare

echo "[*] build vmlinux + in-tree modules (membuat Module.symvers)"
if [[ ! -f "$OUT/Module.symvers" ]]; then
  make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH -j"$JOBS" vmlinux
  make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH -j"$JOBS" modules
fi

echo "[*] build msm_drm out-of-tree"
make -C "$KERNEL_DIR" O="$OUT" ARCH=$ARCH -j"$JOBS" \
    M="$DISPLAY_ROOT/msm" \
    KBUILD_EXTRA_SYMBOLS="$OUT/Module.symvers" \
    modules

echo "[*] locate result"
find "$DISPLAY_ROOT" -name 'msm_drm.ko' -exec ls -la {} \; 2>/dev/null
find "$DISPLAY_ROOT" -name 'msm_drm.ko' -exec cp {} "$OUT/" 2>/dev/null \; || true

echo "[*] done: $OUT/msm_drm.ko"