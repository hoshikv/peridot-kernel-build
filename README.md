# Peridot (Redmi Turbo 3) — msm_drm.ko build

Builds the Xiaomi `msm_drm.ko` display driver out-of-tree against the
Lineage GKI 6.1 kernel for peridot (KMI `android14-6.1`).

## Structure

- `kernel/`         — submodule: crdroidandroid/android_kernel_xiaomi_sm8635 (branch 16.0, GKI 6.1)
- `display-drivers/`— submodule: source display driver peridot-u-oss (dari repo kamu)
- `build.sh`        — build script (dijalankan di GitHub Actions runner)
- `.github/workflows/build.yml` — workflow: checkout + download clang prebuilt + build + upload artifact

## Cara pakai

1. Push ke repo (submodule kernel di-clone otomatis oleh Actions — beratnya di runner GitHub, bukan disk lokal).
2. Buka tab **Actions** → **Build msm_drm.ko** → *Run workflow* (atau otomatis saat push ke `main`).
3. Unduh artifact `msm_drm` (berisi `msm_drm.ko`).
4. Deploy ke device:
   ```sh
   adb push msm_drm.ko /data/local/tmp/
   adb shell su -c 'umount /vendor/lib/modules/...; mount -o bind ...'  # sesuaikan
   ```

## KMI match

Kernel device kamu `6.1.138-android14-11` termasuk KMI `android14-6.1` — tree
Lineage 16.0 di submodule punya ACK base `android14-6.1-2026-03_r1`.
Jika muncul `version magic`/`modversions` mismatch saat `modprobe`, pin
submodule `kernel` ke commit yang KMI-nya persis device.

## Edit & patch

Patch kustom (mis. FOD-LP1 saat suspend) dilakukan di `kernel/` tree atau
langsung di `display-drivers/` (file `.c`), lalu push — Actions build ulang otomatis.