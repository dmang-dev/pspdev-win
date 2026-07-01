#!/bin/bash
# build-library-bundle.sh
#
# Build a zip of prebuilt PSP libraries by driving psp-packages PSPBUILD files
# directly — no psp-pacman, no psp-makepkg.
#
# Requires:
#   - PSPDEV set, with psp-gcc and psp-pkg-config on PATH
#   - cmake, make, curl, sha256sum, tar, unzip, zip, git, python3 in PATH (MSYS2 ships all)
#
# Side effect: this script installs each successfully-built library into
# $PSPDEV/psp/ as it goes — required so subsequent libraries can find the
# ones they depend on (find_package, pkg-config). The same end state results
# when a user extracts the produced zip over their $PSPDEV install.
#
# Usage:
#   tools/build-library-bundle.sh [--packages "<list>"] [--bundle-version vN]
#                                 [--output dist/] [--keep-work]
#
# See LIBRARIES.md for design notes.

set -euo pipefail

# === Configuration ===

# User-facing Tier 1 set. Transitive deps (bzip2, libmodplug, harfbuzz, libpspvram, pspgl)
# are pulled in by psp-packages/get_build_order.py.
PSPDEV_LIBRARY_LIST_TIER1="zlib libpng jpeg freetype2 libogg libvorbis tremor sdl2 sdl2-image sdl2-mixer sdl2-ttf"

PSP_PACKAGES_REPO="https://github.com/pspdev/psp-packages"
# Pin a known-good commit in CI by overriding --psp-packages-ref.
PSP_PACKAGES_DEFAULT_REF="master"

# === Argument parsing ===

PACKAGES="$PSPDEV_LIBRARY_LIST_TIER1"
BUNDLE_VERSION="v0-dev"
WORK_DIR=""
OUTPUT_DIR=""
PSP_PACKAGES_REF="$PSP_PACKAGES_DEFAULT_REF"
KEEP_WORK=0

usage() {
    cat <<USAGE
Usage: $0 [options]

Options:
  --packages "LIST"          Space-separated Tier-N package list
                             (default: Tier 1 = $PSPDEV_LIBRARY_LIST_TIER1)
  --bundle-version VER       Bundle version tag, e.g. v1  (default: $BUNDLE_VERSION)
  --work-dir DIR             Build work area (default: <repo>/build/library-bundle)
  --output DIR               Output zip destination (default: <repo>/dist)
  --psp-packages-ref REF     psp-packages git ref to use (default: $PSP_PACKAGES_DEFAULT_REF)
  --keep-work                Don't clean intermediate build trees on success
  -h, --help                 Show this help
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --packages)          PACKAGES="$2";          shift 2 ;;
        --bundle-version)    BUNDLE_VERSION="$2";    shift 2 ;;
        --work-dir)          WORK_DIR="$2";          shift 2 ;;
        --output)            OUTPUT_DIR="$2";        shift 2 ;;
        --psp-packages-ref)  PSP_PACKAGES_REF="$2";  shift 2 ;;
        --keep-work)         KEEP_WORK=1;            shift   ;;
        -h|--help)           usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

# Resolve script location → repo root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/build/library-bundle}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/dist}"

# === Preflight ===

# Logs go to stderr so they don't pollute command substitutions like
# fetched=$(fetch_source ...) — captured stdout must contain only the
# function's return value (a file path, a build order, etc.).
err() { echo "[bundle] ERROR: $*" >&2; }
info() { echo "[bundle] $*" >&2; }

preflight() {
    if [ -z "${PSPDEV:-}" ]; then
        err "PSPDEV not set in the environment"
        err ""
        err "From an MSYS2 shell with the toolchain installed at <repo>/install:"
        err "    export PSPDEV=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]:-\$0}\")/..\" && pwd)/install\""
        err "    export PATH=\"\$PSPDEV/bin:\$PATH\""
        err ""
        err "Or simply:"
        err "    export PSPDEV=/i/pspdev-win/install"
        err "    export PATH=\"\$PSPDEV/bin:\$PATH\""
        exit 1
    fi
    if [ ! -d "$PSPDEV" ]; then
        err "PSPDEV=$PSPDEV is not a directory"
        exit 1
    fi
    # Map tool name -> MSYS2 package name (identity except where noted).
    declare -A pkg_for
    pkg_for[cmake]="cmake"
    pkg_for[make]="make"
    pkg_for[curl]="curl"
    pkg_for[sha256sum]="coreutils"
    pkg_for[tar]="tar"
    pkg_for[unzip]="unzip"
    pkg_for[zip]="zip"
    pkg_for[git]="git"
    pkg_for[python3]="python"
    pkg_for[dos2unix]="dos2unix"

    local missing=() missing_pkgs=()
    for tool in psp-gcc psp-pkg-config cmake make curl sha256sum tar unzip zip git python3 dos2unix; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
            if [ -n "${pkg_for[$tool]:-}" ]; then
                missing_pkgs+=("${pkg_for[$tool]}")
            fi
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing required tools: ${missing[*]}"
        if [ ${#missing_pkgs[@]} -gt 0 ]; then
            # Dedupe the package list.
            local uniq_pkgs
            uniq_pkgs="$(printf '%s\n' "${missing_pkgs[@]}" | sort -u | tr '\n' ' ')"
            err ""
            err "On MSYS2, install them with:"
            err "    pacman -S --noconfirm $uniq_pkgs"
        fi
        # psp-gcc / psp-pkg-config not in the table — those mean the toolchain
        # hasn't been built yet or PSPDEV/bin isn't on PATH.
        for tool in "${missing[@]}"; do
            case "$tool" in
                psp-gcc|psp-pkg-config)
                    err ""
                    err "($tool comes from the pspdev toolchain — make sure"
                    err " \$PSPDEV/bin is on PATH, or run bootstrap-windows.ps1)"
                    break ;;
            esac
        done
        exit 1
    fi
    info "Preflight OK"
    info "  PSPDEV         = $PSPDEV"
    info "  psp-gcc        = $(command -v psp-gcc)"
    info "  bundle version = $BUNDLE_VERSION"
}

# === psp-packages checkout ===

# Force a git working tree to LF line endings.
#
# Two distinct problems we have to handle:
#   1. The user's global core.autocrlf=true (typical on Windows) causes git
#      to convert LF -> CRLF on checkout. We override locally.
#   2. Some upstream repos commit files with CRLF *in the blob itself* (tremor
#      does this for Version_script.in). PSPBUILD patches were generated
#      against LF versions, so context lines don't match the CRLF tree files.
#      Neither `core.autocrlf=false` nor `eol=lf` attributes help here — git
#      faithfully extracts whatever bytes are in the blob.
#
# So we re-extract the working tree fresh with autocrlf=false (handles
# problem 1), then run dos2unix over it (handles problem 2). dos2unix has
# built-in binary detection and skips non-text files automatically.
git_force_lf_working_tree() {
    local dir="$1"
    git -C "$dir" config core.autocrlf false
    git -C "$dir" config core.eol lf
    # Wipe working tree and re-extract from index.
    find "$dir" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
    git -C "$dir" checkout-index --force --all --quiet
    # Convert CRLF -> LF for every text file (handles upstream-committed CRLF).
    # Errors on individual files are non-fatal: dos2unix is a hint, not a hard
    # requirement, and a single binary-but-misidentified file shouldn't kill
    # the whole bundle.
    find "$dir" -type f ! -path "*/.git/*" -size -10M -print0 \
        | xargs -0 -r dos2unix --quiet 2>/dev/null || true
}

prepare_psp_packages() {
    local pkg_repo_dir="$1"
    if [ ! -d "$pkg_repo_dir/.git" ]; then
        info "Cloning psp-packages → $pkg_repo_dir"
        git clone -c core.autocrlf=false -c core.eol=lf \
            "$PSP_PACKAGES_REPO" "$pkg_repo_dir"
    else
        info "Updating psp-packages in $pkg_repo_dir"
        git -C "$pkg_repo_dir" fetch --tags --quiet origin
    fi
    info "Checking out $PSP_PACKAGES_REF"
    git -C "$pkg_repo_dir" checkout --quiet "$PSP_PACKAGES_REF"
    git_force_lf_working_tree "$pkg_repo_dir"
}

# === Build order resolution via psp-packages/get_build_order.py ===

resolve_build_order() {
    local pkg_repo_dir="$1"
    local requested="$2"  # space-separated requested package names

    # get_build_order.py prints a JSON list of build-orders, one per package
    # in psp-packages. Each entry is a space-separated string ending with the
    # package it resolves. We pick the entries for the requested packages and
    # merge them, deduping while preserving first occurrence.
    local all_orders
    all_orders="$(cd "$pkg_repo_dir" && python3 get_build_order.py)"

    # Pass both inputs as argv to avoid juggling stdin.
    python3 -c '
import json, sys
requested = sys.argv[1].split()
orders = json.loads(sys.argv[2])

# Index: target package name -> its full build order string.
index = {}
for o in orders:
    parts = o.split()
    if parts:
        index[parts[-1]] = parts

combined = []
seen = set()
for pkg in requested:
    if pkg not in index:
        print(f"[bundle] WARN: requested package {pkg!r} has no PSPBUILD in psp-packages", file=sys.stderr)
        continue
    for dep in index[pkg]:
        if dep not in seen:
            combined.append(dep)
            seen.add(dep)

print(" ".join(combined))
' "$requested" "$all_orders"
}

# === Per-package build ===

# Acquire one entry from a PSPBUILD source=() array — handles:
#   - https://host/path/archive.tar.gz  -> download + extract
#   - https://host/path/file.ogg        -> download + cp into $srcdir
#   - git+https://host/repo.git#commit=<sha>  -> clone + checkout + cp into $srcdir
#   - localfile.patch                   -> cp from PSPBUILD dir into $srcdir
#
# Also supports makepkg's "<localname>::<url>" rename prefix.
acquire_source() {
    local url="$1"
    local expected_sha="$2"
    local download_dir="$3"   # persists across runs (cache)
    local src_dir="$4"        # $srcdir — extracted/cloned content lands here
    local pkg_src_dir="$5"    # path to the PSPBUILD's own directory

    # Strip optional "<localname>::" rename prefix.
    local rename=""
    if [[ "$url" =~ ^[A-Za-z0-9_.+-]+:: ]]; then
        rename="${url%%::*}"
        url="${url#*::}"
    fi

    # --- git source ---
    if [[ "$url" =~ ^git\+ ]]; then
        local git_url="${url#git+}"
        local git_ref=""
        if [[ "$git_url" == *"#"* ]]; then
            local fragment="${git_url#*#}"
            git_url="${git_url%%#*}"
            case "$fragment" in
                commit=*) git_ref="${fragment#commit=}" ;;
                tag=*)    git_ref="${fragment#tag=}" ;;
                branch=*) git_ref="${fragment#branch=}" ;;
                *) err "unsupported git fragment: $fragment"; exit 1 ;;
            esac
        fi

        local dirname="${rename:-$(basename "${git_url%.git}")}"
        local clone_path="$download_dir/$dirname"

        if [ -d "$clone_path/.git" ]; then
            info "  updating clone of $git_url"
            git -C "$clone_path" fetch --tags --quiet origin
        else
            info "  cloning $git_url"
            rm -rf "$clone_path"
            git clone --quiet -c core.autocrlf=false -c core.eol=lf \
                "$git_url" "$clone_path"
        fi
        if [ -n "$git_ref" ]; then
            info "  checkout $git_ref"
            git -C "$clone_path" checkout --quiet "$git_ref"
        fi
        # Normalize LF in case the clone predates the autocrlf=false flag.
        git_force_lf_working_tree "$clone_path"

        # Stage into $srcdir. PSPBUILD prepare/build commonly do `cd "$pkgname"`,
        # so we keep the same dirname under $srcdir.
        cp -a "$clone_path" "$src_dir/$dirname"
        return
    fi

    # --- http(s)/ftp or local file ---
    local filename
    local is_remote=0
    if [[ "$url" =~ ^(http|https|ftp):// ]]; then
        is_remote=1
        filename="${rename:-$(basename "${url%%[\?#]*}")}"
        if [ ! -f "$download_dir/$filename" ]; then
            info "  fetching $url"
            curl -fsSL --retry 3 -o "$download_dir/$filename.part" "$url"
            mv "$download_dir/$filename.part" "$download_dir/$filename"
        fi
    else
        # Local file living next to the PSPBUILD (typically a .patch or
        # sample template).
        filename="${rename:-$url}"
        cp "$pkg_src_dir/$url" "$download_dir/$filename"
    fi

    # Verify sha256 only for remote downloads. Local files come from our
    # psp-packages clone, whose line endings we normalize via dos2unix —
    # the PSPBUILD's recorded sha256 was computed before that normalization
    # and will (correctly) no longer match.
    if [ "$is_remote" = "1" ] && [ "$expected_sha" != "SKIP" ]; then
        local actual
        actual="$(sha256sum "$download_dir/$filename" | awk '{print $1}')"
        if [ "$actual" != "$expected_sha" ]; then
            err "sha256 mismatch for $filename"
            err "  expected $expected_sha"
            err "  got      $actual"
            exit 1
        fi
    fi

    # Extract archives, copy everything else verbatim.
    case "$filename" in
        *.tar.gz|*.tgz)  tar_extract -xzf "$download_dir/$filename" "$src_dir" ;;
        *.tar.xz)        tar_extract -xJf "$download_dir/$filename" "$src_dir" ;;
        *.tar.bz2)       tar_extract -xjf "$download_dir/$filename" "$src_dir" ;;
        *.tar)           tar_extract  -xf "$download_dir/$filename" "$src_dir" ;;
        *.zip)           unzip -q "$download_dir/$filename" -d "$src_dir" ;;
        *) cp "$download_dir/$filename" "$src_dir/" ;;  # patches, samples, fonts, ...
    esac
}

# tar wrapper that ignores symlink/hardlink creation errors only. These show
# up on Windows MSYS2 when tarballs contain macOS .framework/ symlinks (e.g.
# SDL2_mixer ships a vendored SDL2.framework with Versions/Current/Resources
# symlinks). MSYS2 can't create those symlinks without dev mode, but the
# missing content is macOS-only and irrelevant to a PSP build. Real errors
# (corrupt archive, wrong format, etc.) still propagate.
tar_extract() {
    local mode="$1" archive="$2" dest_dir="$3"
    local stderr_file; stderr_file="$(mktemp)"

    if tar "$mode" "$archive" -C "$dest_dir" 2>"$stderr_file"; then
        rm -f "$stderr_file"
        return 0
    fi

    # tar exited non-zero. Filter for any tar: errors that aren't
    # symlink/hardlink related.
    local non_link_errors
    non_link_errors="$(grep '^tar:' "$stderr_file" | \
        grep -vE '(Cannot create (symlink|hardlink)|Cannot hard link|Exiting with failure status)' \
        || true)"

    if [ -n "$non_link_errors" ]; then
        echo "$non_link_errors" >&2
        rm -f "$stderr_file"
        return 1
    fi

    local n_skipped
    n_skipped="$(grep -cE 'Cannot create (symlink|hardlink)|Cannot hard link' "$stderr_file" \
        2>/dev/null || echo 0)"
    info "  (tar: $n_skipped symlink/hardlink(s) skipped — Windows limitation, not needed for PSP build)"
    rm -f "$stderr_file"
    return 0
}

build_one_package() {
    local pkgname="$1"
    local pkg_repo_dir="$2"
    local work_root="$3"
    local stage_root="$4"

    local pkg_src_dir="$pkg_repo_dir/$pkgname"
    if [ ! -f "$pkg_src_dir/PSPBUILD" ]; then
        err "no PSPBUILD for $pkgname (expected $pkg_src_dir/PSPBUILD)"
        return 1
    fi

    info "=== Building $pkgname ==="

    local pkg_work="$work_root/$pkgname"
    # Preserve the download cache across builds so git clones / tarballs
    # don't need to be re-fetched on iteration. src/ and pkg/ DO get wiped
    # for a clean build each time.
    rm -rf "$pkg_work/src" "$pkg_work/pkg"
    mkdir -p "$pkg_work/src" "$pkg_work/pkg" "$pkg_work/download"

    # Run the PSPBUILD in a subshell so its vars/functions don't pollute us.
    (
        # makepkg-style env that PSPBUILDs expect.
        export srcdir="$pkg_work/src"
        export pkgdir="$pkg_work/pkg"
        export startdir="$pkg_src_dir"
        export XTRA_OPTS=()
        export MAKEFLAGS="${MAKEFLAGS:--j$(nproc 2>/dev/null || echo 2)}"

        # Shim `patch` to handle git-format renames. Two real tools both
        # fail:
        #   - GNU patch 2.7.6 on MSYS2 doesn't reliably finalize renames
        #     (leaves `configure.ac.od0AHqd`-style temp files), so later
        #     hunks for the renamed file can't find it.
        #   - `git apply` does a strict whole-patch dry-run; later hunks
        #     reference paths that only exist AFTER the rename, so the
        #     dry-run fails before any operation runs.
        # Solution: preprocess the patch ourselves. Extract rename pairs,
        # perform the mv on disk, strip the rename/similarity directives,
        # and rewrite the diff/--- /+++ path headers to reference the new
        # name. Real `patch` then sees a rename-free diff and applies
        # cleanly. (Hits tremor's sezero.patch.)
        patch() {
            local tmp; tmp="$(mktemp)"
            cat > "$tmp"
            local rc

            if grep -qE '^rename (from|to) ' "$tmp"; then
                local tmp2 renames_csv
                tmp2="$(mktemp)"
                renames_csv="$(mktemp)"

                python3 -c '
import re, sys
src = open(sys.argv[1]).read()
out_path = sys.argv[2]
renames_path = sys.argv[3]

lines = src.split("\n")
renames = []
out = []
i = 0
while i < len(lines):
    line = lines[i]
    if line.startswith("similarity index "):
        i += 1
        continue
    if line.startswith("rename from "):
        f = line[12:]
        if i + 1 < len(lines) and lines[i + 1].startswith("rename to "):
            t = lines[i + 1][10:]
            renames.append((f, t))
            i += 2
            continue
    out.append(line)
    i += 1

text = "\n".join(out)
for f, t in renames:
    text = re.sub(
        rf"^(diff --git a/){re.escape(f)}( b/){re.escape(t)}$",
        rf"\g<1>{t}\g<2>{t}", text, flags=re.MULTILINE)
    text = re.sub(
        rf"^--- a/{re.escape(f)}$", f"--- a/{t}",
        text, flags=re.MULTILINE)
    text = re.sub(
        rf"^\+\+\+ b/{re.escape(f)}$", f"+++ b/{t}",
        text, flags=re.MULTILINE)
open(out_path, "w").write(text)
with open(renames_path, "w") as fh:
    for f, t in renames:
        fh.write(f"{f}\t{t}\n")
' "$tmp" "$tmp2" "$renames_csv"

                # Perform the renames the patch declared, before invoking
                # real `patch` on the rename-free version.
                while IFS=$'\t' read -r from to; do
                    if [ -e "$from" ]; then
                        mkdir -p "$(dirname "$to")"
                        mv "$from" "$to"
                    fi
                done < "$renames_csv"

                command patch "$@" < "$tmp2"
                rc=$?
                rm -f "$tmp2" "$renames_csv"
            else
                command patch "$@" < "$tmp"
                rc=$?
            fi

            rm -f "$tmp"
            return $rc
        }
        export -f patch

        # PSPBUILDs assume their own cwd is the package dir while building.
        cd "$pkg_src_dir"

        # `set -u` would break PSPBUILDs that reference optional/unset vars;
        # keep errexit only inside the build itself.
        set +u
        # shellcheck disable=SC1091
        source ./PSPBUILD
        set -u

        # Walk source[] / sha256sums[] in parallel. Both arrays are defined by
        # the PSPBUILD sourced just above (Arch PKGBUILD convention), so
        # shellcheck can't see their assignment — SC2154 is a false positive.
        local i=0
        # shellcheck disable=SC2154
        for src_url in "${source[@]}"; do
            local sha="SKIP"
            # shellcheck disable=SC2154
            if [ "${#sha256sums[@]}" -gt "$i" ]; then
                sha="${sha256sums[$i]}"
            fi
            acquire_source "$src_url" "$sha" "$pkg_work/download" "$srcdir" "$pkg_src_dir"
            i=$((i + 1))
        done

        # Real makepkg resets cwd to $srcdir before each function. PSPBUILDs
        # commonly do `cd "${pkgname}-${pkgver}"` in *both* prepare() and
        # build(), which only works if we reset between calls. Wrap each
        # function in a subshell with `set +u` (PSPBUILDs reference optional
        # vars), a fresh `cd "$srcdir"`, and stdin redirected from /dev/null
        # so anything that would prompt (e.g. `patch` asking "File to patch:")
        # fails fast instead of hanging on the user's terminal.
        if declare -F prepare >/dev/null; then
            info "  prepare()"
            ( cd "$srcdir"; set +u; prepare ) </dev/null
        fi

        info "  build()"
        ( cd "$srcdir"; set +u; build ) </dev/null

        info "  package()"
        ( cd "$srcdir"; set +u; package ) </dev/null
    )

    # Merge the package's $pkgdir/psp/ tree into the bundle staging area
    # AND into the real $PSPDEV/psp/. The latter step matches what
    # `psp-pacman -U pkg.tar.gz` does between packages in the normal flow:
    # subsequent libraries' `find_package(ZLIB)` / pkg-config lookups expect
    # to discover their deps under $PSPDEV/psp, not under our staging area.
    # Side effect: this script populates $PSPDEV with the bundle's libraries
    # as it goes. That's the same end state the user gets when they extract
    # the resulting zip anyway.
    if [ -d "$pkg_work/pkg/psp" ]; then
        mkdir -p "$stage_root/psp"
        cp -a "$pkg_work/pkg/psp/." "$stage_root/psp/"
        cp -a "$pkg_work/pkg/psp/." "$PSPDEV/psp/"
    else
        err "$pkgname produced no psp/ tree under \$pkgdir — install path mismatch?"
        return 1
    fi

    # Best-effort license capture: copy any LICENSE / COPYING / README files
    # from the extracted source into the bundle's licenses/<pkg>/ dir.
    local lic_dest="$stage_root/licenses/$pkgname"
    mkdir -p "$lic_dest"
    # The license files generally live one level under $srcdir (e.g. zlib-1.3.1/README).
    find "$pkg_work/src" -maxdepth 3 -type f \
        \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'COPYRIGHT*' -o -iname 'README' \) \
        -print0 2>/dev/null | \
        while IFS= read -r -d '' f; do
            cp -n "$f" "$lic_dest/$(basename "$f")" 2>/dev/null || true
        done
}

# === Manifest ===

generate_manifest() {
    local stage_root="$1"
    local pkg_repo_dir="$2"
    local packages_built="$3"
    local psp_packages_commit="$4"

    local gcc_version
    gcc_version="$(psp-gcc --version | head -1 | awk '{print $NF}')"

    # Build the manifest in Python so we get valid JSON without shell quoting pain.
    python3 - "$stage_root/libraries.json" \
        "$BUNDLE_VERSION" \
        "$gcc_version" \
        "$psp_packages_commit" \
        "$pkg_repo_dir" \
        "$packages_built" <<'PYEOF'
import json, re, sys
from pathlib import Path

dest, bundle_version, gcc_version, commit, pkg_repo_dir, packages_str = sys.argv[1:7]

def read_field(pspbuild_path, field):
    rx = re.compile(rf"^{field}=(.*)$")
    for line in pspbuild_path.read_text(errors="replace").splitlines():
        m = rx.match(line)
        if m:
            return m.group(1).strip()
    return None

def parse_array(value):
    # license=('FTL OR GPL-2.0-or-later') -> ["FTL OR GPL-2.0-or-later"]
    if value is None:
        return []
    inner = value.strip()
    if inner.startswith("(") and inner.endswith(")"):
        inner = inner[1:-1].strip()
    matches = re.findall(r"'([^']*)'|\"([^\"]*)\"", inner)
    if matches:
        return [a or b for a, b in matches]
    return [inner] if inner else []

libs = []
for pkg in packages_str.split():
    p = Path(pkg_repo_dir) / pkg / "PSPBUILD"
    if not p.exists():
        continue
    libs.append({
        "name": pkg,
        "version": read_field(p, "pkgver") or "",
        "release": read_field(p, "pkgrel") or "",
        "license": parse_array(read_field(p, "license")),
    })

manifest = {
    "bundle_version": bundle_version,
    "toolchain": {"gcc_version": gcc_version},
    "psp_packages_commit": commit,
    "libraries": libs,
}
Path(dest).write_text(json.dumps(manifest, indent=2) + "\n")
print(f"[bundle] Wrote {dest} ({len(libs)} libraries)")
PYEOF
}

# === Main ===

preflight

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

PKG_REPO_DIR="$WORK_DIR/psp-packages"
prepare_psp_packages "$PKG_REPO_DIR"
PSP_PACKAGES_COMMIT="$(git -C "$PKG_REPO_DIR" rev-parse HEAD)"
info "psp-packages @ $PSP_PACKAGES_COMMIT"

info "Resolving build order for: $PACKAGES"
BUILD_ORDER="$(resolve_build_order "$PKG_REPO_DIR" "$PACKAGES")"
info "Final build order ($(echo "$BUILD_ORDER" | wc -w) packages):"
info "  $BUILD_ORDER"

STAGE_ROOT="$WORK_DIR/stage"
rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE_ROOT"

BUILD_ROOT="$WORK_DIR/builds"
mkdir -p "$BUILD_ROOT"

for pkg in $BUILD_ORDER; do
    build_one_package "$pkg" "$PKG_REPO_DIR" "$BUILD_ROOT" "$STAGE_ROOT"
done

generate_manifest "$STAGE_ROOT" "$PKG_REPO_DIR" "$BUILD_ORDER" "$PSP_PACKAGES_COMMIT"

# Final zip
GCC_VERSION="$(psp-gcc --version | head -1 | awk '{print $NF}')"
ZIP_NAME="pspdev-win-libraries-${GCC_VERSION}-${BUNDLE_VERSION}.zip"
ZIP_PATH="$OUTPUT_DIR/$ZIP_NAME"
rm -f "$ZIP_PATH"
(cd "$STAGE_ROOT" && zip -qr "$ZIP_PATH" .)

if [ "$KEEP_WORK" -eq 0 ]; then
    rm -rf "$BUILD_ROOT"
fi

ZIP_SIZE="$(du -h "$ZIP_PATH" | awk '{print $1}')"
echo
info "===================================================================="
info "Bundle built: $ZIP_PATH ($ZIP_SIZE)"
info "  $(echo "$BUILD_ORDER" | wc -w) libraries"
info "  GCC $GCC_VERSION"
info "  psp-packages @ $PSP_PACKAGES_COMMIT"
info "  manifest:  staged at libraries.json inside the zip"
info "===================================================================="
