#!/bin/bash
# build-msys2.sh — MSYS2-side driver for the pspdev Windows port.
#
# Invoked from bootstrap-windows.ps1 with these env vars set:
#   PSPDEV                    install prefix (MSYS path, e.g. /i/pspdev-win/install)
#   PSPDEV_REPO               pspdev clone (MSYS path)
#   PSPDEV_WIN_PREPARE_ONLY   "1" to stop after prepare.sh
#   LOCAL_PACKAGE_BUILD       passed through to build-all.sh (unset or "1")

set -e

: "${PSPDEV:?PSPDEV not set (run via bootstrap-windows.ps1)}"
: "${PSPDEV_REPO:?PSPDEV_REPO not set (run via bootstrap-windows.ps1)}"

echo "[driver] PSPDEV       = $PSPDEV"
echo "[driver] PSPDEV_REPO  = $PSPDEV_REPO"
echo "[driver] uname        = $(uname -a)"

export PATH="$PSPDEV/bin:$PATH"

# Make line endings tolerant: build scripts run via bash, and a stray CR will
# break shebang dispatch (e.g. "bash\r: command not found"). If the user
# cloned with autocrlf=true at any point, normalize on the fly.
if grep -rl $'\r' "$PSPDEV_REPO"/*.sh "$PSPDEV_REPO"/scripts/*.sh "$PSPDEV_REPO"/depends/*.sh 2>/dev/null | head -1 >/dev/null; then
  echo "[driver] Normalizing CRLF line endings in pspdev shell scripts..."
  find "$PSPDEV_REPO" -maxdepth 3 -name '*.sh' -print0 | xargs -0 sed -i 's/\r$//'
fi

cd "$PSPDEV_REPO"

echo "[driver] Running prepare.sh"
./prepare.sh

if [ "$PSPDEV_WIN_PREPARE_ONLY" = "1" ]; then
  echo "[driver] PSPDEV_WIN_PREPARE_ONLY=1 — stopping after prepare."
  exit 0
fi

# Sanity: the toolchain's check-pspdev.sh wants $PSPDEV/bin on PATH.
mkdir -p "$PSPDEV/bin"

# Resume mode: the core cross toolchain (binutils/gcc/newlib/gcc-stage2) is
# expensive to rebuild (~30-90 min) and each sub-script `rm -rf`s its build
# dir, so a plain re-run of build-all.sh redoes everything. When the build
# only failed *after* the allegrex toolchain finished (e.g. in
# psptoolchain-extra, pspsdk, psp-packages...), resume mode skips the
# toolchain and picks up from psptoolchain-extra onward.
if [ "$PSPDEV_WIN_RESUME" = "1" ]; then
  echo "[driver] RESUME MODE — skipping core toolchain rebuild"

  EXTRA_DIR="$PSPDEV_REPO/build/psptoolchain/build/psptoolchain-extra"
  if [ -d "$EXTRA_DIR" ]; then
    # "2 3" = psp-pkg-config + psp-cmake only; skip 001-psp-pacman.sh, which
    # fails at its meson install step on MSYS2 (// UNC-path bug) and which
    # upstream intends to skip on Windows anyway. See pspdev/scripts/
    # 001-psptoolchain.sh for the full explanation.
    echo "[driver] Resuming psptoolchain-extra in $EXTRA_DIR (steps 2 3, skipping psp-pacman)"
    ( cd "$EXTRA_DIR" && ./build-all.sh 2 3 ) || { echo "[driver] psptoolchain-extra failed"; exit 1; }
  else
    echo "[driver] WARNING: $EXTRA_DIR not found — the core toolchain may not have"
    echo "[driver] been built yet. Run without -Resume for a full build."
    exit 1
  fi

  # Remaining top-level pspdev steps. build-all.sh step numbers:
  #   1=psptoolchain  2=pspsdk  3=psp-packages  4=psplinkusb-extra  5=ebootsigner-extra
  echo "[driver] Running build-all.sh steps 2 3 4 5 (pspsdk, psp-packages, psplinkusb, ebootsigner)"
  ./build-all.sh 2 3 4 5
  echo "[driver] Resume build complete. Toolchain installed under: $PSPDEV"
  exit 0
fi

echo "[driver] Running build-all.sh (full build)"
./build-all.sh

echo "[driver] Build complete. Toolchain installed under: $PSPDEV"
