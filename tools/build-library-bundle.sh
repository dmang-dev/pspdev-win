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

err() { echo "[bundle] ERROR: $*" >&2; }
info() { echo "[bundle] $*"; }

preflight() {
    if [ -z "${PSPDEV:-}" ]; then
        err "PSPDEV not set in the environment"
        exit 1
    fi
    if [ ! -d "$PSPDEV" ]; then
        err "PSPDEV=$PSPDEV is not a directory"
        exit 1
    fi
    local missing=()
    for tool in psp-gcc psp-pkg-config cmake make curl sha256sum tar unzip zip git python3; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing required tools: ${missing[*]}"
        exit 1
    fi
    info "Preflight OK"
    info "  PSPDEV         = $PSPDEV"
    info "  psp-gcc        = $(command -v psp-gcc)"
    info "  bundle version = $BUNDLE_VERSION"
}

# === psp-packages checkout ===

prepare_psp_packages() {
    local pkg_repo_dir="$1"
    if [ ! -d "$pkg_repo_dir/.git" ]; then
        info "Cloning psp-packages → $pkg_repo_dir"
        git clone "$PSP_PACKAGES_REPO" "$pkg_repo_dir"
    else
        info "Updating psp-packages in $pkg_repo_dir"
        git -C "$pkg_repo_dir" fetch --tags origin
    fi
    info "Checking out $PSP_PACKAGES_REF"
    git -C "$pkg_repo_dir" checkout --quiet "$PSP_PACKAGES_REF"
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

# Fetch one entry from a PSPBUILD source=() array. URLs are downloaded with
# curl; bare filenames are copied from the PSPBUILD directory.
fetch_source() {
    local url="$1"
    local expected_sha="$2"
    local dest_dir="$3"
    local pkg_src_dir="$4"

    local filename
    if [[ "$url" =~ ^(http|https|ftp):// ]]; then
        # Strip any trailing query/fragment for the saved filename.
        filename="$(basename "${url%%[\?#]*}")"
        if [ ! -f "$dest_dir/$filename" ]; then
            info "  fetching $url"
            curl -fsSL --retry 3 -o "$dest_dir/$filename.part" "$url"
            mv "$dest_dir/$filename.part" "$dest_dir/$filename"
        fi
    else
        # Local file in the PSPBUILD directory.
        filename="$url"
        cp "$pkg_src_dir/$filename" "$dest_dir/$filename"
    fi

    if [ "$expected_sha" != "SKIP" ]; then
        local actual
        actual="$(sha256sum "$dest_dir/$filename" | awk '{print $1}')"
        if [ "$actual" != "$expected_sha" ]; then
            err "sha256 mismatch for $filename"
            err "  expected $expected_sha"
            err "  got      $actual"
            exit 1
        fi
    fi

    echo "$dest_dir/$filename"
}

extract_source() {
    local archive="$1"
    local dest_dir="$2"
    case "$archive" in
        *.tar.gz|*.tgz)  tar -xzf "$archive" -C "$dest_dir" ;;
        *.tar.xz)        tar -xJf "$archive" -C "$dest_dir" ;;
        *.tar.bz2)       tar -xjf "$archive" -C "$dest_dir" ;;
        *.tar)           tar  -xf "$archive" -C "$dest_dir" ;;
        *.zip)           unzip -q "$archive" -d "$dest_dir" ;;
        *) cp "$archive" "$dest_dir/" ;;  # patch / sample / cmake snippet
    esac
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
    rm -rf "$pkg_work"
    mkdir -p "$pkg_work/src" "$pkg_work/pkg" "$pkg_work/download"

    # Run the PSPBUILD in a subshell so its vars/functions don't pollute us.
    (
        # makepkg-style env that PSPBUILDs expect.
        export srcdir="$pkg_work/src"
        export pkgdir="$pkg_work/pkg"
        export startdir="$pkg_src_dir"
        export XTRA_OPTS=()
        export MAKEFLAGS="${MAKEFLAGS:--j$(nproc 2>/dev/null || echo 2)}"

        # PSPBUILDs assume their own cwd is the package dir while building.
        cd "$pkg_src_dir"

        # `set -u` would break PSPBUILDs that reference optional/unset vars;
        # keep errexit only inside the build itself.
        set +u
        # shellcheck disable=SC1091
        source ./PSPBUILD
        set -u

        # Walk source[] / sha256sums[] in parallel.
        local i=0
        for src_url in "${source[@]}"; do
            local sha="SKIP"
            if [ "${#sha256sums[@]}" -gt "$i" ]; then
                sha="${sha256sums[$i]}"
            fi
            local fetched
            fetched="$(fetch_source "$src_url" "$sha" "$pkg_work/download" "$pkg_src_dir")"
            extract_source "$fetched" "$srcdir"
            i=$((i + 1))
        done

        cd "$srcdir"

        if declare -F prepare >/dev/null; then
            info "  prepare()"
            set +u; prepare; set -u
        fi

        info "  build()"
        set +u; build; set -u

        info "  package()"
        set +u; package; set -u
    )

    # Merge the package's $pkgdir/psp/ tree into the bundle staging area.
    if [ -d "$pkg_work/pkg/psp" ]; then
        mkdir -p "$stage_root/psp"
        cp -a "$pkg_work/pkg/psp/." "$stage_root/psp/"
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
