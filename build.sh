#!/usr/bin/env bash
# Build a ziee sandbox rootfs squashfs (or tar.zst for WSL2 import).
#
# Defaults:
#   --flavor  full
#   --arch    x86_64  (from `uname -m`; override for cross-build)
#   --package squashfs   (squashfs = Linux/macOS; tar = Windows wsl --import → .tar.zst)
#   --version <empty>    (CI passes the release tag minus the leading `v`)
#   --output  .cache/ziee-sandbox-rootfs-{arch}-{flavor}.{squashfs|tar.zst}
#
# Approach: download Canonical's pre-built `ubuntu-base` tarball
# (`https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/`,
# ~30 MB amd64), sha-pin it via the flavor recipe, layer the flavor's
# extra packages on top via a single `apt install` pass inside a
# `systemd-nspawn` chroot, normalize timestamps/log files/caches,
# pack as squashfs or tar.zst with reproducible flags.
#
# Why no two-pass reproducibility check anymore:
# the build is now byte-deterministic *by construction*. The two
# nondeterminism sources we previously fought were (1) snapshot.ubuntu.com
# 503s mid-bootstrap (we'd get a partial rootfs that still packed
# successfully under the `|| true` swallow) and (2) mmdebstrap's
# nondeterministic dpkg-trigger order. Switching the base to a
# sha-pinned tarball removes (1); doing a single apt-install pass
# + aggressive normalization removes (2). If a future change
# re-introduces nondeterminism, it'll surface as `gh release view`
# showing a different sha than what an operator gets locally — far
# more visible than a CI step we'd otherwise be tempted to `|| true`
# past.
#
# Reproducibility:
#   SOURCE_DATE_EPOCH is exported (default: last commit timestamp)
#   and applied to: (a) `find ... -exec touch -h -d @epoch` over the
#   whole stage tree post-install, (b) `mksquashfs -all-time/-mkfs-time`,
#   (c) `tar --mtime=@epoch --sort=name --numeric-owner`.

set -euo pipefail

# --------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------

FLAVOR="full"
VERSION=""
ARCH="$(uname -m)"
OUTPUT=""
PACKAGE="squashfs"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flavor)    FLAVOR="$2";    shift 2 ;;
    --version)   VERSION="$2";   shift 2 ;;
    --arch)      ARCH="$2";      shift 2 ;;
    --output)    OUTPUT="$2";    shift 2 ;;
    --package)   PACKAGE="$2";   shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$PACKAGE" in
  squashfs|tar) ;;
  *) echo "build.sh: --package must be 'squashfs' or 'tar' (got '$PACKAGE')" >&2; exit 2 ;;
esac

# Map our arch names to Canonical's
case "$ARCH" in
  x86_64)  UBUNTU_ARCH="amd64" ;;
  aarch64) UBUNTU_ARCH="arm64" ;;
  *) echo "build.sh: unsupported --arch '$ARCH' (need x86_64 or aarch64)" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

# --------------------------------------------------------------------
# Source the flavor recipe: flavors/<flavor>/flavor.sh
# Required vars:
#   UBUNTU_BASE_VERSION       (e.g. "24.04.4")
#   UBUNTU_BASE_SHA256_AMD64  (sha256 of ubuntu-base-${UBUNTU_BASE_VERSION}-base-amd64.tar.gz)
#   UBUNTU_BASE_SHA256_ARM64  (same, for arm64; ignored on amd64 builds)
#   APT_SNAPSHOT              (snapshot.ubuntu.com date for the layered packages)
#   APT_PACKAGES              (whitespace-separated list of extra packages)
# Optional:
#   provision()               (bash function — runs in a chroot for pip/R/npm steps)
# --------------------------------------------------------------------

RECIPE="$SCRIPT_DIR/flavors/$FLAVOR/flavor.sh"
if [[ ! -f "$RECIPE" ]]; then
  echo "build.sh: no recipe at $RECIPE" >&2
  echo "  available flavors:" >&2
  for f in "$SCRIPT_DIR"/flavors/*/flavor.sh; do
    [[ -f "$f" ]] && echo "    - $(basename "$(dirname "$f")")" >&2
  done
  exit 1
fi
# shellcheck source=/dev/null
source "$RECIPE"
: "${UBUNTU_BASE_VERSION:?recipe $RECIPE must set UBUNTU_BASE_VERSION (e.g. \"24.04.4\")}"
: "${APT_SNAPSHOT:?recipe $RECIPE must set APT_SNAPSHOT}"
: "${APT_PACKAGES:?recipe $RECIPE must set APT_PACKAGES}"

case "$UBUNTU_ARCH" in
  amd64) UBUNTU_BASE_SHA256="${UBUNTU_BASE_SHA256_AMD64:?recipe must set UBUNTU_BASE_SHA256_AMD64}" ;;
  arm64) UBUNTU_BASE_SHA256="${UBUNTU_BASE_SHA256_ARM64:?recipe must set UBUNTU_BASE_SHA256_ARM64}" ;;
esac

if [[ "$PACKAGE" == "tar" ]]; then EXT="tar.zst"; else EXT="squashfs"; fi

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="$REPO_ROOT/.cache/ziee-sandbox-rootfs-${ARCH}-${FLAVOR}.${EXT}"
fi

mkdir -p "$(dirname "$OUTPUT")"

# --------------------------------------------------------------------
# Reproducibility env
# --------------------------------------------------------------------

if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  SOURCE_DATE_EPOCH="$(git -C "$REPO_ROOT" log -1 --format=%ct 2>/dev/null || date -u +%s)"
fi
export SOURCE_DATE_EPOCH

# --------------------------------------------------------------------
# Tool checks
# --------------------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null \
    || { echo "build.sh: '$1' not found in PATH ($2)" >&2; exit 1; }
}
require_cmd tar              "apt install tar"
require_cmd curl             "apt install curl"
require_cmd sha256sum        "apt install coreutils"
require_cmd systemd-nspawn   "apt install systemd-container"
if [[ "$PACKAGE" == "squashfs" ]]; then
  require_cmd mksquashfs     "apt install squashfs-tools"
else
  require_cmd zstd           "apt install zstd"
fi

# --------------------------------------------------------------------
# Download + verify the pinned Ubuntu base tarball (cached locally
# so repeat builds skip the network on hit). Single small download
# (~30 MB amd64) — replaces the multi-hundred-MB mmdebstrap bootstrap
# that hit snapshot.ubuntu.com hundreds of times.
# --------------------------------------------------------------------

UBUNTU_BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-${UBUNTU_BASE_VERSION}-base-${UBUNTU_ARCH}.tar.gz"
BASE_CACHE="$REPO_ROOT/.cache/ubuntu-base-${UBUNTU_BASE_VERSION}-${UBUNTU_ARCH}.tar.gz"
mkdir -p "$(dirname "$BASE_CACHE")"

if [[ -f "$BASE_CACHE" ]] && echo "$UBUNTU_BASE_SHA256  $BASE_CACHE" | sha256sum -c --quiet 2>/dev/null; then
  echo "==> ubuntu-base ${UBUNTU_BASE_VERSION} (${UBUNTU_ARCH}): cache hit"
else
  echo "==> downloading ubuntu-base ${UBUNTU_BASE_VERSION} (${UBUNTU_ARCH})"
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors "$UBUNTU_BASE_URL" -o "${BASE_CACHE}.tmp"
  echo "$UBUNTU_BASE_SHA256  ${BASE_CACHE}.tmp" | sha256sum -c
  mv "${BASE_CACHE}.tmp" "$BASE_CACHE"
fi

# --------------------------------------------------------------------
# Stage dir setup
# --------------------------------------------------------------------

STAGE_DIR="$(dirname "$OUTPUT")/.stage-${FLAVOR}"
cleanup_stage() {
  if [[ -d "$STAGE_DIR" ]]; then
    if command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
      sudo rm -rf "$STAGE_DIR" 2>/dev/null || rm -rf "$STAGE_DIR" 2>/dev/null
    else
      rm -rf "$STAGE_DIR" 2>/dev/null
    fi
  fi
}
cleanup_stage
mkdir -p "$STAGE_DIR"
trap cleanup_stage EXIT

# --------------------------------------------------------------------
# Helper: run a sudo command iff we're not already root.
# systemd-nspawn requires root; tar -x with --preserve-permissions
# needs root to preserve ownership.
# --------------------------------------------------------------------

run_as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
    sudo -E "$@"
  else
    echo "build.sh: need root (or passwordless sudo) for: $*" >&2
    exit 1
  fi
}

# --------------------------------------------------------------------
# 1. Extract the base tarball into the stage dir
# --------------------------------------------------------------------

echo "==> extracting ubuntu-base"
run_as_root tar --numeric-owner -xf "$BASE_CACHE" -C "$STAGE_DIR"

# --------------------------------------------------------------------
# 2. Layer flavor packages via apt (single pass).
#    Pin the apt mirror to a snapshot.ubuntu.com date so the .debs are
#    deterministic across runs. Acquire::Retries+Timeout makes the
#    layer resilient to snapshot.ubuntu.com's frequent 503s (it goes
#    flaky at unpredictable times — `Acquire::Retries=10` is the same
#    knob `apt update`/`apt install` documents).
# --------------------------------------------------------------------

pkgs="$(echo "$APT_PACKAGES" | tr -s '[:space:]' ' ')"

echo "==> apt install (snapshot=$APT_SNAPSHOT)"
# Default to snapshot.ubuntu.com (deterministic by date pin). Allow
# `APT_MIRROR` env override so local dev runs can hit a fast live
# mirror (e.g. `http://archive.ubuntu.com/ubuntu`) at the cost of
# reproducibility. CI leaves the env unset → reproducible build.
# Include the three pockets ubuntu-base built against — without
# `noble-updates`/`noble-security` we hit unsatisfiable dependencies
# when the base ships a security-updated `libbz2-1.0` / `perl-base` /
# etc. that only the -security pocket carries at the pinned date.
if [[ -n "${APT_MIRROR:-}" ]]; then
  mirror_base="$APT_MIRROR"
  trust="[trusted=yes]"
  echo "==> apt mirror: $APT_MIRROR (override; non-reproducible)"
else
  mirror_base="https://snapshot.ubuntu.com/ubuntu/${APT_SNAPSHOT}"
  trust="[trusted=yes]"
fi
{
  echo "deb $trust $mirror_base noble main universe"
  echo "deb $trust $mirror_base noble-updates main universe"
  echo "deb $trust $mirror_base noble-security main universe"
} | run_as_root tee "$STAGE_DIR/etc/apt/sources.list" >/dev/null
run_as_root rm -f "$STAGE_DIR/etc/apt/sources.list.d/"*.sources 2>/dev/null || true

# ubuntu-base 24.04.x does NOT ship ca-certificates — apt would fail
# the TLS handshake to snapshot.ubuntu.com. Pre-stage the host's CA
# bundle so the FIRST apt-install call works; the bundle gets
# OVERWRITTEN later when apt installs its own `ca-certificates`
# package (post-install hook regenerates the bundle from the chroot's
# /usr/share/ca-certificates/). Path mirrors Debian's standard layout.
if [[ ! -f "$STAGE_DIR/etc/ssl/certs/ca-certificates.crt" ]] \
   && [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then
  run_as_root install -D -m 0644 \
    /etc/ssl/certs/ca-certificates.crt \
    "$STAGE_DIR/etc/ssl/certs/ca-certificates.crt"
fi

# Pre-seed tzdata so its post-install hook doesn't try to prompt for
# a timezone from a non-existent stdin (which hangs nspawn until the
# wall-clock timeout — 14 min in our test runs). UTC keeps the rootfs
# locale-neutral; the LLM can override per-process via $TZ at runtime.
run_as_root mkdir -p "$STAGE_DIR/etc"
echo "Etc/UTC" | run_as_root tee "$STAGE_DIR/etc/timezone" >/dev/null

run_as_root systemd-nspawn --quiet --register=no --keep-unit \
  --timezone=off --resolv-conf=off -D "$STAGE_DIR" \
  --bind-ro=/etc/resolv.conf \
  --setenv=DEBIAN_FRONTEND=noninteractive \
  --setenv=TZ=Etc/UTC \
  --setenv=DEBCONF_NONINTERACTIVE_SEEN=true \
  /bin/bash -c "
    set -euo pipefail
    # Pre-seed tzdata's debconf answers so dpkg-reconfigure runs
    # silently. apt's post-install of tzdata otherwise waits on
    # tty input for the area + city selection.
    echo 'tzdata tzdata/Areas select Etc' | debconf-set-selections 2>/dev/null || true
    echo 'tzdata tzdata/Zones/Etc select UTC' | debconf-set-selections 2>/dev/null || true
    apt-get -o Acquire::Retries=10 -o Acquire::http::Timeout=60 -qq update
    apt-get -o Acquire::Retries=10 -o Acquire::http::Timeout=60 \
            -y --no-install-recommends install $pkgs
  "

# --------------------------------------------------------------------
# 3. Optional flavor provision (pip/R/npm — full only).
#    The recipe's `provision` function is shipped in verbatim via
#    `declare -f` (no quoting-hell).
# --------------------------------------------------------------------

if declare -f provision >/dev/null; then
  echo "==> chroot provision (recipe provision function)"
  # Write to host /tmp + bind-mount into the chroot. Writing under
  # $STAGE_DIR/tmp/ left the file invisible to the SECOND nspawn
  # (suspect: nspawn's propagate-dir cleanup interferes between
  # consecutive calls on the same stage). Bind-mount sidesteps it.
  prov_host="$(mktemp /tmp/ziee-provision.XXXXXX.sh)"
  {
    echo "set -euo pipefail"
    echo "export DEBIAN_FRONTEND=noninteractive"
    echo "export TZ=Etc/UTC"
    declare -f provision
    echo "provision"
  } > "$prov_host"
  run_as_root systemd-nspawn --quiet --register=no --keep-unit \
    --timezone=off --resolv-conf=off -D "$STAGE_DIR" \
    --bind-ro=/etc/resolv.conf \
    --bind-ro="$prov_host":/ziee-provision.sh \
    /bin/bash /ziee-provision.sh 2>&1 | tail -30
  rm -f "$prov_host"
fi

# --------------------------------------------------------------------
# 4. Normalize for byte-reproducible output:
#    - sweep apt caches, log files, /tmp, bash history
#    - sentinels (version + 1.1.1.1+8.8.8.8 resolv.conf)
#    - strip setuid (defense in depth)
#    - set all mtimes to SOURCE_DATE_EPOCH
# --------------------------------------------------------------------

echo "==> normalizing"
run_as_root rm -rf \
    "$STAGE_DIR/var/cache/apt/archives/"*.deb \
    "$STAGE_DIR/var/cache/apt/archives/partial" \
    "$STAGE_DIR/var/cache/apt/pkgcache.bin" \
    "$STAGE_DIR/var/cache/apt/srcpkgcache.bin" \
    "$STAGE_DIR/var/cache/ldconfig/aux-cache" \
    "$STAGE_DIR/var/lib/apt/lists/"* \
    "$STAGE_DIR/var/log/apt" \
    "$STAGE_DIR/var/log/"*.log \
    "$STAGE_DIR/var/log/dpkg.log" \
    "$STAGE_DIR/var/log/alternatives.log" \
    "$STAGE_DIR/var/log/btmp" "$STAGE_DIR/var/log/wtmp" "$STAGE_DIR/var/log/lastlog" \
    "$STAGE_DIR/var/lib/dpkg/info/"*.md5sums.tmp \
    "$STAGE_DIR/etc/ld.so.cache" \
    "$STAGE_DIR/tmp/"* \
    "$STAGE_DIR/root/.bash_history" \
  2>/dev/null || true

# Version sentinel (empty on dev builds; CI sets it to the release
# tag minus the leading `v`).
echo "$VERSION" | run_as_root tee "$STAGE_DIR/.ziee-sandbox-rootfs-version" >/dev/null

# /etc/resolv.conf — required for any sandbox tool that does DNS.
# mmdebstrap (and ubuntu-base) leaves this whatever the build host had
# at build time (or empty). On the Linux native sandbox path the
# host's /etc/resolv.conf is bound in by `build_hardening_prefix`, but
# the macOS / WSL2 VM paths route through libkrun's TSI — which
# transparently forwards any AF_INET UDP send to the host, so a
# baked-in public-resolver line works regardless of the actual VM
# network state. Without this, pip / uvx / npx / mcp-server-fetch
# inside the VM sandbox fails with EAI_AGAIN.
run_as_root rm -f "$STAGE_DIR/etc/resolv.conf"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' \
  | run_as_root tee "$STAGE_DIR/etc/resolv.conf" >/dev/null

# Strip setuid bits (defense in depth).
run_as_root find "$STAGE_DIR" -xdev \( -perm /u+s -o -perm /g+s \) -type f \
    -exec chmod u-s,g-s {} \; 2>/dev/null || true

# Set every file/dir/symlink mtime to SOURCE_DATE_EPOCH so the packed
# archive is bit-deterministic across runs. `-h` operates on the
# symlink itself rather than its target.
run_as_root find "$STAGE_DIR" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} + 2>/dev/null || true

# --------------------------------------------------------------------
# 5. Pack
# --------------------------------------------------------------------

if [[ "$PACKAGE" == "squashfs" ]]; then
  echo "==> mksquashfs ($OUTPUT)"
  rm -f "$OUTPUT"
  # squashfs-tools >=4.6 errors if BOTH the SOURCE_DATE_EPOCH env var
  # AND the explicit -all-time/-mkfs-time flags are set. Unset the env
  # var only for this invocation; we still pass the value via flags so
  # the output is bit-reproducible.
  sde="$SOURCE_DATE_EPOCH"
  run_as_root env -u SOURCE_DATE_EPOCH \
    mksquashfs "$STAGE_DIR" "$OUTPUT" \
      -comp zstd -Xcompression-level 19 \
      -no-xattrs \
      -all-time "$sde" \
      -mkfs-time "$sde" \
      -force-uid 0 -force-gid 0 \
      -noappend -no-progress \
      -quiet
  # mksquashfs writes the output as root; chown back to the caller so
  # post-build steps (sha256, cosign sign) don't need sudo.
  if [[ "$EUID" -ne 0 ]]; then
    run_as_root chown "$(id -u):$(id -g)" "$OUTPUT"
  fi
else
  # Reproducible `.tar.zst` for Windows `wsl --import` (which can't
  # consume a squashfs). Built from the SAME staged tree as the
  # squashfs — same content, different packaging. Determinism: sorted
  # names, fixed mtime, GNU format (no per-file pax atime/ctime
  # headers), numeric ownership preserved. zstd is single-threaded
  # (`-T1`); `-T0` would interleave nondeterministically.
  echo "==> tar.zst ($OUTPUT)"
  rm -f "$OUTPUT"
  run_as_root tar \
      --format=gnu \
      --sort=name \
      --numeric-owner --owner=0 --group=0 \
      --mtime="@$SOURCE_DATE_EPOCH" \
      -C "$STAGE_DIR" -cf - . \
    | zstd -q -19 -T1 -o "$OUTPUT"
fi

size_h="$(du -h "$OUTPUT" | cut -f1)"
sha="$(sha256sum "$OUTPUT" | cut -d' ' -f1)"
echo "==> done: $OUTPUT ($size_h, sha256=$sha)"
