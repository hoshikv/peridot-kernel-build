# Peridot (Redmi Turbo 3) — msm_drm.ko build

Builds the Xiaomi `msm_drm.ko` display driver out-of-tree against the Lineage GKI 6.1 kernel for peridot (KMI `android14-6.1`).

## Structure

- `kernel/` — submodule: crdroidandroid/android_kernel_xiaomi_sm8635 (branch 16.0, GKI 6.1)
- `display-drivers/` — submodule: source display driver peridot-u-oss (your repo)
- `build.sh` — build script (runs on the GitHub Actions runner)
- `.github/workflows/build.yml` — workflow: checkout + download clang prebuilt + build + upload artifact

## KMI match

Device kernel `6.1.138-android14-11` is KMI `android14-6.1` — the Lineage 16.0 tree in the submodule uses ACK base `android14-6.1-2026-03_r1`. On a `version magic`/`modversions` mismatch during `modprobe`, pin the `kernel` submodule to a commit matching your device's exact KMI.

## Patching

Custom patches (e.g. FOD-LP1 during suspend) go in the `kernel/` tree or directly in `display-drivers/` (`.c` files), then push — Actions rebuilds automatically.
