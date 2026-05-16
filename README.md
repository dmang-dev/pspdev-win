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
| `psp-pacman` | ✅ builds, installs, syncs, installs packages | verified `psp-pacman -S sdl2` end-to-end on vanilla MSYS2 |
| `psp-packages` | ✅ via `psp-pacman -S` *or* bundle | bundle (`tools/build-library-bundle.sh`, see [LIBRARIES.md](LIBRARIES.md)) is recommended for end users; `psp-pacman -S` is fine for dev iteration |
| `psplinkusb` — `pspsh`, `usbhostfs_pc` | ⏭️ skipped | USB host-link debug tools — see [Roadmap](#whats-skipped-and-why) |

The result is a complete PSP homebrew toolchain: C and C++ cross-compiler,
newlib, libstdc++, the full pspsdk, and the standard host build tools — enough
to build essentially any PSP homebrew that doesn't depend on the prebuilt
`psp-packages` binaries or USB host-link debugging.

> [!IMPORTANT]
> **This is an MSYS2-hosted toolchain — the same architecture native PSP dev
> on Windows has always used.** The produced `psp-gcc.exe` & friends are
> `x86_64-pc-cygwin` binaries that depend on `msys-2.0.dll`; they run from
> any shell with both `<PSPDEV>\bin` **and** the MSYS2 `usr\bin` on `PATH`.
> Michael Grigorev / NVStat Team's **PSPDEV for Windows** shipped this same
> Cygwin-hosted approach from 2008–2016 (with GCC 4.3.2); we're just doing
> it again with GCC 15.2.0. A fully self-contained MINGW-hosted build, if
> anyone ever wants one, would be a separate effort.

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

## What's partial / skipped

### `psp-pacman` — fully working on Windows

Upstream pacman's `meson.build` does
`mkdir -p "$DESTDIR/<abs-path>"` in its install step. When `DESTDIR` is
empty (the typical case), MSYS2 sees `//<abs-path>` and interprets the
leading `//` as a UNC share prefix, failing with
`cannot create directory '//i': Read-only file system`. Linux's `mkdir`
treats `//` like `/` so the bug never surfaces there. The `windows-port`
branch of our pspdev fork ships a one-character patch
(`patches/psp-pacman/fix-destdir-double-slash.patch`) that drops the slash
between `$DESTDIR` and the absolute path — the standard Autotools
`$(DESTDIR)$(prefix)` pattern, identical on Linux/macOS, correct on MSYS2.

The fork also installs `libgpgme-devel` and `libcurl-devel` via
`prepare.sh`. Without these, pacman is built with `HAVE_LIBCURL` and
`HAVE_LIBGPGME` both `#undef`'d, which makes `pacman -Sy` fail with
`error invoking external downloader` (no libcurl → libalpm has no
internal HTTP path) and the default `pacman.conf` rejected because
`SigLevel = Optional TrustAll` is invalid without compiled-in signature
support.

**Verified end-to-end on standalone MSYS2**:

```
psp-pacman -Sy            -> syncs https://pspdev.github.io/psp-packages/pspdev.db
psp-pacman -Ss sdl2       -> lists sdl2, sdl2-image, sdl2-mixer, sdl2-ttf, ...
psp-pacman -S sdl2        -> downloads + installs sdl2 + pspgl + libpspvram (~1.2 MiB)
psp-pacman -Q             -> sdl2 2.32.8-3, pspgl r12-6, libpspvram r11.885fd3f-5
```

`libSDL2.a`, `libGL.a`, headers land in `$PSPDEV/psp/{lib,include}/`.

One minor cosmetic follow-up: pacman's `Hook Dirs` listing duplicates the
prefix at runtime (`$PSPDEV/$PSPDEV/share/libalpm/hooks/`). This is a
`RootDir`-vs-`HookDir` interaction in pacman when prefix isn't the system
root. Doesn't block `-S` (the unduplicated path is also in the list); a
cleaner fix is a future patch.

For shipping libraries **to users**, this repo still defaults to a
**single prebuilt bundle** (`tools/build-library-bundle.sh`, see
[LIBRARIES.md](LIBRARIES.md)) rather than asking users to run
`psp-pacman -S` themselves. The bundle path is simpler (one zip extracted
over `$PSPDEV`, done) and matches the historical MinPSPW model. But for
developers iterating on the toolchain, `psp-pacman -S <pkg>` now works as
a real alternative.

### `pspsh` + `usbhostfs_pc` — USB host-link debugging

The PSPLink PC-side tools: `usbhostfs_pc` shares a PC folder to the PSP over
USB; `pspsh` is a shell to load/run/debug homebrew on real hardware with
host-side `printf` output.

- **You lose:** the fast USB hardware debug loop.
- **You keep:** building homebrew; `libpsplink` + `psplink_boot.prx` (the
  *on-PSP* side) do build; and **PPSSPP** — how most PSP homebrew is tested
  today — needs none of this.
- **Fixable.** The only reason these are skipped today is that devkitPro's
  filtered MSYS2 doesn't ship `libusb`. PSPDEV for Windows bundled
  `libusb-win32` and shipped working `pspsh.exe` / `usbhostfs_pc.exe` for
  years, so this isn't novel territory — it's a one-time setup. On
  standalone MSYS2, `pacman -S libusb` + flipping our skip in
  `004-psplinkusb-extra.sh` is the obvious starting point.

---

## How the port works

All Windows-specific changes live on the **`windows-port`** branch of the
[`dmang-dev/pspdev`](https://github.com/dmang-dev/pspdev/tree/windows-port)
fork. Every change is gated behind OS detection, so it does not affect Linux
or macOS builds. The diff against upstream is small:

| File | Change |
|---|---|
| `prepare.sh` | Detect `MSYS_NT*` / `MINGW*` / `UCRT64*`; install host deps via `pacman` (correct package names, `--overwrite` for the autoconf `.info` conflict, `python3`/`pip3` symlink fallback, `libgpg-error-devel`, `libgpgme-devel`, `libcurl-devel`). |
| `scripts/001-psptoolchain.sh` | On Windows, build the allegrex toolchain; clone `psp-pacman` directly, inject our destdir patch, run `pacman.sh`; then build `psptoolchain-extra` steps 2+3 (pkg-config + cmake). |
| `patches/psp-pacman/fix-destdir-double-slash.patch` | One-character meson.build patch that fixes the `$DESTDIR/<abs>` → `//<abs>` UNC bug breaking `ninja install` on MSYS2. |
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

### Prior art

**PSPDEV for Windows** (a.k.a. Minimalist PSPSDK / MinPSPW) by
**Michael Grigorev / NVStat Team** — the Cygwin-hosted Windows port of
PSPSDK that served the community from ~2008 to 2016, bundling GCC 4.3.2,
PSPSDK build 2443, and ~30 prebuilt PSP libraries (SDL, SDL_mixer, SDL_ttf,
freetype, libpng, libvorbis, lua, ode, TinyGL, …) in a single installer.
That project established the architecture this repo uses today: a
Cygwin/MSYS-hosted toolchain with libraries delivered as one prebuilt set,
not via a package manager. Site:
<http://novell.chel.ru/start.php?dir=plugin/psp/dev&app=sdk&lng=english>
(intermittently available).

## License

MIT — see [LICENSE](LICENSE). The patched files on the `windows-port` branch
of the fork remain under upstream pspdev's MIT license; this wrapper repo is
MIT as well, so the whole thing is consistently MIT and friction-free to
upstream.
