# Prebuilt PSP libraries — design doc

**Status: design only, not implemented.** This file describes how
`pspdev-win` plans to deliver prebuilt PSP libraries (SDL2, zlib, libpng,
freetype, …) without requiring `psp-pacman`, which is currently skipped on
Windows.

## Why a bundle, not a package manager

Upstream pspdev delivers third-party PSP libraries via `psp-pacman` — a
PSP-targeted clone of Arch's pacman that fetches per-library packages from
GitHub Releases. On Windows it doesn't currently work end-to-end (it
compiles, but its meson `install` step emits a `//` UNC path MSYS2 rejects),
and upstream pspdev's official Windows path is Docker, not native MSYS2.

Rather than maintain a forked pacman, this repo plans to follow the
historical native-Windows precedent set by **PSPDEV for Windows** (NVStat
Team, 2008–2016): **one prebuilt library bundle per release**. The user
extracts a single `.zip` into `$PSPDEV` and is done. No package manager,
no per-library installers, no maintained index.

Trade-offs vs `psp-pacman`:

| | psp-pacman | One bundle |
|---|---|---|
| Per-library updates | yes | no — wait for the next bundle release |
| Disk footprint | install only what you need | install everything (small overall — these are static `.a`s) |
| Infrastructure | a forked pacman | a CI workflow |
| Failure surface | meson, libalpm, signature checks | unzip |
| Matches historical native-Windows precedent | no | yes (MinPSPW) |

The trade-off favors the bundle for a community where a typical user wants
"all the homebrew libs" and the bundle ships a few times a year.

## Target library set

MinPSPW 2008–2016 bundled ~30 libraries. A useful 2026-era starter set,
prioritized by what modern PSP homebrew actually uses:

**Tier 1 (must have):**
- SDL2, SDL2_image, SDL2_mixer, SDL2_ttf
- zlib, libpng, libjpeg-turbo
- freetype
- libogg, libvorbis, libtremor
- pthread-embedded (already partly handled by pspdev itself)

**Tier 2 (commonly wanted):**
- lua / luajit
- libmad, libmikmod, libflac
- libpspmath, libpspvram
- intraFont
- TinyGL, pspgl

**Tier 3 (nice to have, evaluate by request):**
- libcurl, libssh2 (PSP networking is a niche)
- libchm, libtga
- libid3tag, libexif
- ode, libbulletml (physics — heavy)

First release ships Tier 1 only — keeps the bundle small (~few MB compiled)
and the scope bounded. Tier 2 follows in subsequent releases.

## Build approach

1. **CI workflow** (GitHub Actions) on `dmang-dev/pspdev-win`:
   - Trigger: manual `workflow_dispatch` (not automatic; library bundles are
     curated releases, not every-commit artifacts).
   - Runner: `windows-latest` (or `windows-2022`).
   - Install MSYS2 via `msys2/setup-msys2@v2`.
   - Run `bootstrap-windows.ps1 -LocalPackageBuild` against a known-good
     pspdev fork commit pinned in the workflow.
   - After build, walk `$PSPDEV/psp/{lib,include}` and snapshot the *new*
     files (diff against a baseline taken after a no-libraries build) per
     library. Group into one zip:
     - `pspdev-win-libraries-<gcc-version>-<bundle-version>.zip`
     - top-level structure mirrors `$PSPDEV/psp/`, so users extract over
       their existing install.
   - Attach to a GitHub Release; tag scheme: `libs-vN.M`.

2. **`-LocalPackageBuild` is presently untested.** First task in actually
   implementing this is to drive `bootstrap-windows.ps1 -LocalPackageBuild`
   to completion under MSYS2 and capture every failure as a patch against
   `pspdev/psp-packages` (or upstream library sources). The result is a
   sibling of the existing `windows-port` branch, plus the bundle zip.

3. **Per-library license aggregation.** Each library has its own license;
   the bundle release notes should include a list with SPDX identifiers.
   Trivial to generate from the source `LICENSE` files captured during build.

## Versioning

- Bundle tagged independently of the wrapper repo: `libs-v1`, `libs-v2`, …
- Pin the underlying pspdev commit + GCC version in the release notes.
- Bumping the toolchain (e.g. GCC 15.2.0 → 16.x) requires a new bundle —
  binary compat for libstdc++/newlib across major GCC versions isn't
  guaranteed, and the safe move is to rebuild.

## Out of scope

- **A `psp-pacman` port.** Possible (it's basically a `meson.build` patch),
  but not the plan here. If someone fixes it upstream and contributes it
  back, great; this repo isn't going to maintain that fork.
- **Per-library installers** (the old MinPSPW "DevPak per library" model).
  More moving parts than one bundle, less convenient for users, doesn't
  buy anything in 2026 (disk is cheap).
- **Auto-updating bundles** / a `pspdev-win update` command. Out of scope;
  users can re-extract a newer release when they want one.

## Open questions

1. Does `pspdev/psp-packages`' `build.sh --install` actually work end-to-end
   under MSYS2 today? (Untested. Probably needs its own small patch set.)
2. Should the bundle include a manifest file listing each library + version
   + license? (Yes, probably — one-line `libraries.json` at the zip root.)
3. Should we also publish each library as a separate zip for users who only
   want one? (No, for v1 — keep it simple. Reconsider if anyone asks.)
4. Standalone MSYS2 vs devkitPro MSYS2 in CI? (Standalone — clean repo
   namespace, current packages. devkitPro is the "yes it works on dkP too"
   fallback path, not the CI target.)

## How to follow / pick this up

Track as an issue on `dmang-dev/pspdev-win`. Anyone interested in working
on it: start by running `bootstrap-windows.ps1 -LocalPackageBuild` and
filing what breaks.
