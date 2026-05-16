# Prebuilt PSP libraries

**Status: implemented; first bundle not yet shipped.** This file describes
how `pspdev-win` builds and ships prebuilt PSP libraries (SDL2, zlib,
libpng, freetype, …) without requiring `psp-pacman`, which is currently
skipped on Windows.

The implementation lives in:

- [`tools/build-library-bundle.sh`](tools/build-library-bundle.sh) —
  drives PSPBUILD files from `pspdev/psp-packages` directly, with no
  `psp-pacman` / `psp-makepkg` dependency.
- [`.github/workflows/build-libraries.yml`](.github/workflows/build-libraries.yml) —
  `workflow_dispatch` CI workflow that builds the toolchain (cached
  per-fork-commit), runs the bundle script, and optionally publishes a
  GitHub Release.

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
prioritized by what modern PSP homebrew actually uses. Package names match
the directory names in `pspdev/psp-packages`.

**Tier 1 (shipped in the bundle, first release):**

User-requested:
- `sdl2`, `sdl2-image`, `sdl2-mixer`, `sdl2-ttf`
- `zlib`, `libpng`, `jpeg`
- `freetype2`
- `libogg`, `libvorbis`, `tremor`

Pulled in transitively by `get_build_order.py` (the user doesn't have to
list these explicitly):
- `bzip2` (via freetype2)
- `libmodplug` (via sdl2-mixer)
- `harfbuzz` (via sdl2-ttf)
- `libpspvram`, `pspgl` (via sdl2)

`pthread-embedded` is already installed by `psptoolchain-allegrex` during
the core toolchain build; it's part of the toolchain install, not the
library bundle.

**Tier 2 (commonly wanted, planned follow-up):**
- `lua` / `luajit`
- `libmad`, `mikmod`, `flac`
- `libpspmath`
- `intrafont`
- `tinygl`

**Tier 3 (nice to have, evaluate by request):**
- `curl`, `libssh2` (PSP networking is a niche)
- `libchm`, `libtga`
- `libid3tag`, `libexif`
- `ode`, `libbulletml` (physics — heavy)

First release ships Tier 1 only — keeps the bundle small (~few MB compiled)
and the scope bounded. Tier 2 follows in subsequent releases. The package
list passed to `--packages` is the only thing that changes between tiers.

## Build approach

### Bypassing `psp-pacman`

`psp-packages/build.sh --install` (which is what `bootstrap-windows.ps1
-LocalPackageBuild` would have called) goes through `psp-makepkg` to
tarball each library and then `psp-pacman -U` to install it — both
unavailable on MSYS2 today thanks to the meson `//` UNC bug in pacman.

A PSPBUILD itself, though, is just a small bash script with `prepare()`,
`build()`, and `package()` functions that produce a clean
`${pkgdir}/psp/{lib,include,share}/...` staging tree. The tarball-and-DB
step that `makepkg` + `pacman` add on top is irrelevant for a bundle
release. So the bundle script drives PSPBUILDs directly:

1. Clone `pspdev/psp-packages` at a pinned commit.
2. Use the repo's own `get_build_order.py` to resolve transitive
   dependencies into a topologically-sorted list.
3. For each package, in a subshell:
   - download + verify the `source=()` entries against `sha256sums=()`,
   - extract,
   - run `prepare()` / `build()` / `package()` with `$srcdir` and `$pkgdir`
     pointing at per-package working dirs,
   - capture any `LICENSE` / `COPYING` files into a `licenses/<pkg>/` dir.
4. Merge every package's `${pkgdir}/psp/` tree into a single staging area.
5. Emit `libraries.json` manifest (versions, releases, SPDX licenses,
   `psp-packages` commit, GCC version).
6. Zip the staging area as
   `pspdev-win-libraries-<gcc-version>-<bundle-version>.zip`.

The user extracts that zip over `$PSPDEV/` and is done. Layout matches
`$PSPDEV/psp/` exactly.

### CI workflow

`.github/workflows/build-libraries.yml` wraps the above for GitHub Actions:

- **Trigger**: `workflow_dispatch` only — library bundles are curated
  releases, not every-commit artifacts.
- **Runner**: `windows-2022`.
- **MSYS2**: `msys2/setup-msys2@v2` (standalone MSYS2 is the only
  supported environment).
- **Toolchain cache**: keyed on the pspdev fork's HEAD commit. First run is
  ~60–90 min; cache hits skip straight to library build.
- **Inputs**:
  - `bundle_version` (e.g. `v1`) — surfaces in the zip filename, manifest,
    and (optional) release tag.
  - `create_release` (bool) — when true, the workflow tags
    `libs-<bundle_version>` and uploads the zip as a GitHub Release.
  - `pspdev_ref` / `psp_packages_ref` — let the workflow pin to specific
    commits for reproducibility.

### Per-library license aggregation

Each library's `LICENSE` / `COPYING` / `COPYRIGHT` files (best-effort glob
under `$srcdir`) are copied into `licenses/<pkg>/` in the bundle. The
`license` field from each PSPBUILD goes into `libraries.json`; not always
SPDX-canonical (PSPBUILDs use shorthand like `'custom'` or `'Zlib'`), but
enough to point a reader at the right file.

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

1. Per-library zips alongside the combined bundle? (No, for v1 — keep it
   simple. Reconsider if anyone asks.)
2. Pin `psp-packages` to a tagged commit per bundle release, or always
   build off `master`? Probably pin once the first bundle ships; lets us
   reproduce older bundles from the manifest.

## How to use it

Locally (after `bootstrap-windows.ps1` has built the toolchain at least
once), from an MSYS2 shell:

```bash
export PSPDEV="$(pwd)/install"
export PATH="$PSPDEV/bin:$PATH"
tools/build-library-bundle.sh --bundle-version v1
```

In CI: go to **Actions → Build library bundle → Run workflow**, fill in
the bundle version, and decide whether to publish a Release.
