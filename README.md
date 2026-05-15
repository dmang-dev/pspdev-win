# pspdev-win

Build the [**pspdev**](https://github.com/pspdev/pspdev) PSP homebrew toolchain
natively on **Windows**, under MSYS2 — no WSL, no Docker, no Linux VM.

One PowerShell command takes you from a clean Windows box to a working
`psp-gcc` that compiles real PlayStation Portable executables.

```powershell
.\bootstrap-windows.ps1
```

---

## Status — verified working

Built and verified end-to-end on devkitPro's bundled MSYS2 (`MSYS_NT-10.0`,
GCC 15.2.0 host). `psp-gcc` compiles and links a real `ELF32 / MIPS R3000`
PSP executable.

| Component | State | Notes |
|---|---|---|
| `prepare.sh` (host deps) | ✅ builds | MSYS2/MINGW/UCRT detection + `pacman` install list |
| `psptoolchain-allegrex` — binutils, gcc (C + C++), newlib, pthread-embedded | ✅ builds & installs | the cross compiler; ~30–90 min |
| `psptoolchain-extra` — `psp-pkg-config`, `psp-cmake` | ✅ builds & installs | wrapper tools into `$PSPDEV/bin` |
| `pspsdk` | ✅ builds & installs | all `libpsp*.a`, headers, samples, host tools (`psp-prxgen`, `pack-pbp`, `mksfoex`, …) |
| `psplinkusb` — `libpsplink`, `psplink_boot.prx` | ✅ builds & installs | the on-PSP debug stub |
| `ebootsigner` | ✅ builds & installs | EBOOT signing tool |
| `psp-pacman` / `psp-packages` | ⏭️ skipped | prebuilt-library package manager — see [Roadmap](#whats-skipped-and-why) |
| `psplinkusb` — `pspsh`, `usbhostfs_pc` | ⏭️ skipped | USB host-link debug tools — see [Roadmap](#whats-skipped-and-why) |

The result is a complete PSP homebrew toolchain: C and C++ cross-compiler,
newlib, libstdc++, the full pspsdk, and the standard host build tools — enough
to build essentially any PSP homebrew that doesn't depend on the prebuilt
`psp-packages` binaries or USB host-link debugging.

> [!IMPORTANT]
> **This is an MSYS2-hosted toolchain, not a standalone native one.**
> The build uses MSYS2's GCC, so the produced `psp-gcc.exe` & friends are
> `x86_64-pc-cygwin` binaries that depend on `msys-2.0.dll`. They run *under
> MSYS2* (or from any shell that has both `<PSPDEV>\bin` **and** the MSYS2
> `usr\bin` on `PATH`). A fully self-contained, MINGW-hosted toolchain you can
> zip up and hand to anyone is a larger separate effort — see the roadmap.

---

## Requirements

- **Windows 10/11 x64**
- **An MSYS2 install**, either:
  - standalone MSYS2 from <https://www.msys2.org/> (preferred — clean package
    namespace, current packages), or
  - devkitPro's bundled MSYS2 at `C:\devkitPro\msys2` (auto-detected as a
    fallback)
- **Git** (Git for Windows is fine)
- **~5 GB** free disk for the build

`bootstrap-windows.ps1` auto-detects MSYS2 at `C:\msys64`, `C:\msys2`, or
`C:\devkitPro\msys2`. Override with `-Msys2Root <path>`.

---

## Quick start

```powershell
git clone https://github.com/dmang-dev/pspdev-win.git
cd pspdev-win

# 1. Install host build dependencies first (fast — fail early on package issues)
.\bootstrap-windows.ps1 -PrepareOnly

# 2. Full build (30-90 min: binutils -> gcc -> newlib -> gcc stage 2 -> pspsdk -> ...)
.\bootstrap-windows.ps1
```

The bootstrap script clones the patched pspdev fork
([`dmang-dev/pspdev`](https://github.com/dmang-dev/pspdev), `windows-port`
branch) into `pspdev/` next to itself, then drives the build inside MSYS2.
The toolchain installs to `.\install` by default.

### Options

| Flag | Effect |
|---|---|
| `-PrepareOnly` | Run only `prepare.sh` (install host deps) and stop. |
| `-Resume` | Skip the expensive core toolchain rebuild; resume from `psptoolchain-extra` onward. Use after a full build got the cross compiler installed but failed in a later stage. |
| `-PspDev <path>` | Install location. Absolute, **no spaces, Latin chars only** (pspdev's own constraint). Default: `.\install`. |
| `-Msys2Root <path>` | Override MSYS2 auto-detection. |
| `-LocalPackageBuild` | Build `psp-packages` from source instead of skipping it (slow, fragile, see roadmap). |

### Use the toolchain

```powershell
[Environment]::SetEnvironmentVariable("PSPDEV", "$PWD\install", "User")
[Environment]::SetEnvironmentVariable("PATH", "$env:PATH;$PWD\install\bin", "User")
```

Then from an MSYS2 shell (or any shell with the MSYS2 `usr\bin` also on PATH):

```bash
psp-gcc --version          # -> psp-gcc (GCC) 15.2.0
psp-gcc -I$PSPDEV/psp/sdk/include -L$PSPDEV/psp/sdk/lib hello.c \
    -lpspdebug -lpspdisplay -lpspge -lpspctrl -lpspsdk -lpspkernel \
    -o hello.elf
```

To turn an `.elf` into a runnable `EBOOT.PBP`, use the standard pspsdk
`build.mak` flow — `psp-prxgen`, `mksfoex`, `pack-pbp` are all in
`$PSPDEV/bin`. Test in [PPSSPP](https://www.ppsspp.org/) or on real hardware.

---

## What's skipped, and why

Three pieces are deliberately skipped on Windows. **None of them block building
PSP homebrew** — but here's exactly what you give up, and how fixable each is.

### `psp-pacman` + `psp-packages` — prebuilt PSP libraries

`psp-packages` is a set of PSP ports of common libraries (SDL2, zlib, libpng,
freetype, libvorbis, …); `psp-pacman` is the host-side package manager that
installs them (`psp-pacman -S sdl2`).

- **You lose:** one-command install of those prebuilt libraries.
- **You keep:** building them from source (`-LocalPackageBuild` — untested on
  MSYS2, may need its own fixes), and *all* core homebrew dev on pspsdk.
- **Fixable?** **Yes, and it's close.** `psp-pacman` actually *compiles* fine
  (155/155 targets) — it dies on one meson install step: `mkdir -p
  "$DESTDIR/<abspath>"` produces a leading `//`, which MSYS2 interprets as a
  UNC path. The fix is one more patch to the bundled pacman's `meson.build`.
  Once `psp-pacman` installs, `psp-packages` works too (it just calls
  `psp-pacman -S`). **Good first contribution.**

### `pspsh` + `usbhostfs_pc` — USB host-link debugging

The PSPLink PC-side tools: `usbhostfs_pc` shares a PC folder to the PSP over
USB; `pspsh` is a shell to load/run/debug homebrew on real hardware with
host-side `printf` output.

- **You lose:** the fast USB hardware debug loop.
- **You keep:** building homebrew; `libpsplink` + `psplink_boot.prx` (the
  *on-PSP* side) do build; and **PPSSPP** — how most PSP homebrew is tested
  today — needs none of this.
- **Fixable?** **Yes, medium effort.** The blocker is `libusb`, which is
  filtered out of devkitPro's MSYS2 but available on standalone MSYS2
  (`pacman -S libusb`). These shipped as Windows `.exe`s in the old
  devkitPSP era, so it's well-trodden — likely libusb path fixes plus the
  WinUSB/Zadig driver setup for runtime USB access.

---

## How the port works

All Windows-specific changes live on the **`windows-port`** branch of the
[`dmang-dev/pspdev`](https://github.com/dmang-dev/pspdev/tree/windows-port)
fork. Every change is gated behind OS detection, so it does not affect Linux
or macOS builds. The diff against upstream is small:

| File | Change |
|---|---|
| `prepare.sh` | Detect `MSYS_NT*` / `MINGW*` / `UCRT64*`; install host deps via `pacman` (correct package names, `--overwrite` for the autoconf `.info` conflict, `python3`/`pip3` symlink fallback, `libgpg-error-devel`). |
| `scripts/001-psptoolchain.sh` | On Windows, build the allegrex toolchain, then build `psptoolchain-extra` *without* `psp-pacman` (steps 2 3). |
| `scripts/004-psplinkusb-extra.sh` | Widen the host-tools skip from `MINGW*` only to `MINGW*` / `MSYS_*` / `UCRT64*` (upstream's check missed the MSYS shell's `uname`). |
| `scripts/003-psp-packages.sh` | Cleanly skip on MSYS2 with a clear message; `-LocalPackageBuild` escape hatch preserved. |
| `depends/check-dependencies.sh` | Skip the `gpgme-tool` check on MSYS2 (not packaged there; only used by the skipped `psp-pacman`). |

This repo (`pspdev-win`) is just the **Windows entry point**:

- `bootstrap-windows.ps1` — PowerShell launcher: finds MSYS2, clones the fork,
  hands off to bash.
- `build-msys2.sh` — the MSYS2-side driver: normalizes line endings, runs
  `prepare.sh`, then `build-all.sh` (or the resume path).

---

## Troubleshooting

- **`bash\r: command not found` / `\r` errors** — CRLF line endings. The
  driver auto-normalizes the `pspdev/` clone, but not the sub-clones the build
  downloads itself. If it bites, inside MSYS2:
  `find pspdev/build -name '*.sh' -print0 | xargs -0 sed -i 's/\r$//'`
- **A late stage failed but the cross compiler is already built** — re-run with
  `-Resume` to skip the ~30–90 min toolchain rebuild.
- **`pacman` file conflict on `autoconf` / `automake`** — handled
  automatically (`--overwrite='/usr/share/info/*'`); if you see it, your MSYS2
  is mid-upgrade — run `pacman -Syu` once and retry.
- **A clean rebuild** — delete `install/` and `pspdev/build/`, then re-run
  `.\bootstrap-windows.ps1`. Everything is reproducible from scratch.

---

## Credits

- [**pspdev**](https://github.com/pspdev/pspdev) and the PSP Homebrew
  Development team — the actual toolchain. This project is a thin Windows
  enablement layer on top of their work.
- [**MSYS2**](https://www.msys2.org/) / [**devkitPro**](https://devkitpro.org/)
  — the POSIX build environment that makes this possible.

## License

MIT — see [LICENSE](LICENSE). The patched files on the `windows-port` branch
of the fork remain under upstream pspdev's MIT license; this wrapper repo is
MIT as well, so the whole thing is consistently MIT and friction-free to
upstream.
