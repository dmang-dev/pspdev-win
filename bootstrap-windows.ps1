#requires -Version 5.1
<#
.SYNOPSIS
    Bootstrap the pspdev Windows port: locate or install MSYS2, set PSPDEV,
    and hand off to bash to run prepare.sh + build-all.sh.

.DESCRIPTION
    This is the Windows entry point for the pspdev-win port. It:
      1. Locates an MSYS2 install (prefers a standalone C:\msys64, falls back
         to the devkitPro-bundled MSYS2 at C:\devkitPro\msys2).
      2. Clones the patched pspdev fork (windows-port branch) next to this
         script if it isn't already there.
      3. Ensures PSPDEV is set to a sane absolute path with no spaces.
      4. Launches MSYS2 bash to run build-msys2.sh, which drives prepare.sh
         then build-all.sh inside the pspdev clone.

.PARAMETER PspDev
    Where the built toolchain will be installed. Must be absolute and contain
    no spaces or non-Latin characters. Defaults to <repo>\install.

.PARAMETER Msys2Root
    Override MSYS2 detection. Defaults to auto-detect.

.PARAMETER PspdevRepo
    Git URL of the patched pspdev fork to clone when no pspdev/ dir exists.
    Defaults to https://github.com/dmang-dev/pspdev.git.

.PARAMETER PspdevBranch
    Branch of PspdevRepo to check out. Defaults to windows-port.

.PARAMETER PrepareOnly
    Run only prepare.sh (install host deps) and exit. Useful for first-time
    setup so you can see dependency-install errors in isolation.

.PARAMETER Resume
    Skip the expensive core cross-toolchain rebuild (binutils/gcc/newlib/
    gcc-stage2) and resume from psptoolchain-extra onward. Use this when a
    full build already got the allegrex toolchain installed but failed in a
    later stage (psptoolchain-extra, pspsdk, psp-packages, ...).

.PARAMETER LocalPackageBuild
    Build psp-packages from source instead of skipping (see pspdev README).
    Off by default on Windows because psp-pacman is not yet buildable here.

.EXAMPLE
    .\bootstrap-windows.ps1 -PrepareOnly
    .\bootstrap-windows.ps1
    .\bootstrap-windows.ps1 -Resume
#>

[CmdletBinding()]
param(
    [string]$PspDev = (Join-Path $PSScriptRoot "install"),
    [string]$Msys2Root,
    [string]$PspdevRepo = "https://github.com/dmang-dev/pspdev.git",
    [string]$PspdevBranch = "windows-port",
    [switch]$PrepareOnly,
    [switch]$Resume,
    [switch]$LocalPackageBuild
)

$ErrorActionPreference = "Stop"

function Find-Msys2Root {
    param([string]$Override)
    if ($Override) {
        if (Test-Path (Join-Path $Override "usr\bin\bash.exe")) { return $Override }
        throw "Msys2Root '$Override' does not contain usr\bin\bash.exe"
    }
    $candidates = @("C:\msys64", "C:\msys2", "C:\devkitPro\msys2")
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "usr\bin\bash.exe")) { return $c }
    }
    throw "No MSYS2 install found. Install MSYS2 from https://www.msys2.org/ or pass -Msys2Root <path>."
}

function Assert-PspDevPath {
    param([string]$Path)
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw "PSPDEV must be an absolute path; got '$Path'"
    }
    if ($Path -match '\s') {
        throw "PSPDEV must not contain spaces; got '$Path'"
    }
    if ($Path -match '[^\x00-\x7F]') {
        throw "PSPDEV must use only Latin characters; got '$Path'"
    }
}

function Convert-WindowsPathToMsys {
    param([string]$WinPath)
    # C:\foo\bar -> /c/foo/bar
    $drive = $WinPath.Substring(0, 1).ToLower()
    $rest  = $WinPath.Substring(2) -replace '\\', '/'
    return "/$drive$rest"
}

Assert-PspDevPath $PspDev

$msys2 = Find-Msys2Root -Override $Msys2Root
Write-Host "[bootstrap] MSYS2 root: $msys2"
Write-Host "[bootstrap] PSPDEV:     $PspDev"

# This script lives at the repo root; the patched pspdev clone goes next to it.
$workspace = $PSScriptRoot
$pspdevDir = Join-Path $workspace "pspdev"
if (-not (Test-Path (Join-Path $pspdevDir "build-all.sh"))) {
    Write-Host "[bootstrap] No pspdev clone found; cloning $PspdevRepo ($PspdevBranch)"
    & git clone --branch $PspdevBranch --single-branch $PspdevRepo $pspdevDir
    if ($LASTEXITCODE -ne 0) {
        throw "git clone of $PspdevRepo ($PspdevBranch) failed"
    }
} else {
    Write-Host "[bootstrap] Using existing pspdev clone at $pspdevDir"
}

# Ensure the install dir exists and is writable
New-Item -ItemType Directory -Force -Path $PspDev | Out-Null

$bash = Join-Path $msys2 "usr\bin\bash.exe"
$buildDriverMsys = Convert-WindowsPathToMsys (Join-Path $workspace "build-msys2.sh")
$pspdevMsys = Convert-WindowsPathToMsys $PspDev
$repoMsys = Convert-WindowsPathToMsys $pspdevDir

# Args passed through to build-msys2.sh as env vars
$env:PSPDEV = $pspdevMsys
$env:PSPDEV_REPO = $repoMsys
$env:PSPDEV_WIN_PREPARE_ONLY = if ($PrepareOnly) { "1" } else { "0" }
$env:PSPDEV_WIN_RESUME = if ($Resume) { "1" } else { "0" }
$env:LOCAL_PACKAGE_BUILD = if ($LocalPackageBuild) { "1" } else { "" }
# Switch MSYS2 to MSYS shell (POSIX) explicitly so paths and namespacing match
# what the upstream build scripts expect.
$env:MSYSTEM = "MSYS"
$env:CHERE_INVOKING = "1"

Write-Host "[bootstrap] Launching: $bash -lc $buildDriverMsys"
& $bash -lc "$buildDriverMsys"
$exit = $LASTEXITCODE
if ($exit -ne 0) {
    Write-Host "[bootstrap] Build driver exited with code $exit" -ForegroundColor Red
    exit $exit
}
Write-Host "[bootstrap] Done." -ForegroundColor Green
