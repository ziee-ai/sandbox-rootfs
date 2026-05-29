#!/usr/bin/env bash
# Build a ziee sandbox rootfs squashfs (or tar.zst for WSL).
#
# Defaults:
#   --flavor  full
#   --arch    x86_64  (from `uname -m`; override for cross-build)
#   --package squashfs   (squashfs = Linux/macOS; tar = Windows wsl --import → .tar.zst)
#   --version <empty>    (CI passes the release tag minus the leading `v`; dev runs leave empty)
#   --output  .cache/ziee-sandbox-rootfs-{arch}-{flavor}.{squashfs|tar.zst}
#
# Versioning is owned by the GitHub release tag (semver: `v0.1.0`). When
# --version is set, the value is written into `/.ziee-sandbox-rootfs-version`
# inside the rootfs as a debug breadcrumb. The server identifies the rootfs
# by the DB row that recorded the download — the in-rootfs sentinel is not
# load-bearing for mount decisions.
#
# Backend: mmdebstrap (reproducible-by-design, no daemon). Install it with
#   apt install mmdebstrap squashfs-tools
#
# Reproducibility:
#   SOURCE_DATE_EPOCH is exported (default: today's commit timestamp)
#   so the squashfs hash is stable across CI runs.

set -euo pipefail

# --------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------

FLAVOR="full"
VERSION=""
ARCH="$(uname -m)"
OUTPUT=""
PACKAGE="squashfs"   # squashfs (Linux/macOS) | tar (Windows wsl --import)

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

if ! command -v mmdebstrap >/dev/null; then
  echo "build.sh: mmdebstrap not found in PATH" >&2
  echo "  apt install mmdebstrap squashfs-tools" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

# --------------------------------------------------------------------
# Resolve + source the flavor recipe: flavors/<flavor>/flavor.sh
# Each recipe is self-contained: APT_SNAPSHOT, APT_PACKAGES, and an
# optional provision() function. Adding a flavor = drop in a new dir.
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
: "${APT_SNAPSHOT:?recipe $RECIPE must set APT_SNAPSHOT}"
: "${APT_PACKAGES:?recipe $RECIPE must set APT_PACKAGES}"

if [[ "$PACKAGE" == "tar" ]]; then EXT="tar.zst"; else EXT="squashfs"; fi

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="$REPO_ROOT/.cache/ziee-sandbox-rootfs-${ARCH}-${FLAVOR}.${EXT}"
fi

mkdir -p "$(dirname "$OUTPUT")"

# --------------------------------------------------------------------
# Reproducibility env
# --------------------------------------------------------------------

if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  # Use the last commit timestamp of the rootfs build tree as a
  # reasonable, stable default.
  SOURCE_DATE_EPOCH="$(git -C "$REPO_ROOT" log -1 --format=%ct -- "$SCRIPT_DIR" 2>/dev/null || date -u +%s)"
fi
export SOURCE_DATE_EPOCH

# --------------------------------------------------------------------
# Common: packaging-tool check
# --------------------------------------------------------------------

if [[ "$PACKAGE" == "squashfs" ]]; then
  if ! command -v mksquashfs >/dev/null; then
    echo "build.sh: mksquashfs not found in PATH; apt install squashfs-tools" >&2
    exit 1
  fi
else
  if ! command -v zstd >/dev/null; then
    echo "build.sh: zstd not found in PATH; apt install zstd" >&2
    exit 1
  fi
fi

STAGE_DIR="$(dirname "$OUTPUT")/.stage-${FLAVOR}"
# Cleanup needs sudo on platforms where mmdebstrap ran in root mode
# (the stage dir then contains root-owned files like /var/log/wtmp,
# /boot, /var/cache/ldconfig that a plain `rm -rf` can't remove).
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
# Build: mmdebstrap bootstrap → chroot installs
# --------------------------------------------------------------------

build_mmdebstrap() {
  echo "==> mmdebstrap (flavor=$FLAVOR arch=$ARCH version=${VERSION:-dev})"
  local mirror="http://snapshot.ubuntu.com/ubuntu/${APT_SNAPSHOT}"
  # Collapse the recipe's whitespace/newline package list to a comma list.
  local pkgs
  pkgs="$(echo "$APT_PACKAGES" | tr -s '[:space:]' ',' | sed 's/^,//; s/,$//')"

  # mmdebstrap does the bootstrap directly into the staging dir.
  # Mode selection:
  #   - root (preferred): we have sudo and a proper subuid map, OR we're
  #     running as root. Cleanest and most accurate file ownership.
  #   - fakechroot: unprivileged fallback when subuid is empty (common on
  #     personal workstations). Requires `fakechroot fakeroot` installed.
  local mode="fakechroot"
  if [[ "$EUID" -eq 0 ]] || (command -v sudo >/dev/null && sudo -n true 2>/dev/null); then
    mode="root"
  fi
  echo "    (mmdebstrap mode=$mode)"
  local mmd=(mmdebstrap
    --variant=minbase
    --mode="$mode"
    --components=main,universe
    --include="$pkgs"
    noble
    "$STAGE_DIR"
    "$mirror")
  if [[ "$mode" == "root" && "$EUID" -ne 0 ]]; then
    sudo -E "${mmd[@]}" 2>&1 | grep -vE "^I:" || true
  else
    "${mmd[@]}" 2>&1 | grep -vE "^I:" || true
  fi

  # Post-bootstrap provisioning, if the recipe defines it (pip/R/Node etc.
  # — mmdebstrap can't reach PyPI/CRAN/npm directly). Runs inside the chroot
  # via systemd-nspawn with /etc/resolv.conf bound. The recipe's `provision`
  # function is shipped in verbatim via `declare -f` (no quoting-hell).
  if declare -f provision >/dev/null; then
    echo "==> chroot provision (recipe provision function)"
    local prov="$STAGE_DIR/tmp/ziee-provision.sh"
    { echo "set -euo pipefail"; declare -f provision; echo "provision"; } \
      | sudo tee "$prov" >/dev/null
    sudo systemd-nspawn --quiet -D "$STAGE_DIR" \
      --bind-ro=/etc/resolv.conf \
      /bin/bash /tmp/ziee-provision.sh 2>&1 | tail -30
    sudo rm -f "$prov"
  fi

  # Write the version sentinel (empty on dev builds; CI sets it to the
  # release tag minus the leading `v`). The server reads this only as
  # a debug breadcrumb — the DB row is the source of truth.
  echo "$VERSION" | sudo tee "$STAGE_DIR/.ziee-sandbox-rootfs-version" >/dev/null

  # /etc/resolv.conf — required for any sandbox tool that does DNS.
  # mmdebstrap leaves /etc/resolv.conf whatever the host had at build
  # time (or empty/symlink to systemd-resolved that doesn't exist
  # inside the sandbox). On the Linux native sandbox path the host's
  # /etc/resolv.conf is bound in by `build_hardening_prefix`, but the
  # macOS / WSL2 VM paths route through libkrun's TSI — which
  # transparently forwards any AF_INET UDP send to the host, so a
  # baked-in public-resolver line works regardless of the actual VM
  # network state. Without this, pip / uvx / npx / mcp-server-fetch
  # inside the VM sandbox fails with EAI_AGAIN (`Errno -3 / Try
  # again`). 1.1.1.1 (Cloudflare) + 8.8.8.8 (Google) chosen for being
  # the lowest-latency widely-accessible public resolvers; can be
  # overridden by binding a different /etc/resolv.conf at runtime.
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' \
    | sudo tee "$STAGE_DIR/etc/resolv.conf" >/dev/null

  # Strip setuid bits (defense in depth).
  sudo find "$STAGE_DIR" -xdev \( -perm /u+s -o -perm /g+s \) -type f \
    -exec chmod u-s,g-s {} \; 2>/dev/null || true
}

# --------------------------------------------------------------------
# Build + finalize
# --------------------------------------------------------------------

# Run `$@` as root iff the stage dir is root-owned (mmdebstrap root mode)
# and we aren't already root — so the packager can read every file and
# preserve numeric ownership. Mirrors the cleanup_stage sudo logic.
maybe_sudo() {
  if [[ "$EUID" -ne 0 ]] \
     && [[ "$(stat -c %u "$STAGE_DIR" 2>/dev/null || echo 0)" == "0" ]] \
     && command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
    sudo -E "$@"
  else
    "$@"
  fi
}

package_squashfs() {
  echo "==> mksquashfs ($OUTPUT)"
  rm -f "$OUTPUT"
  # squashfs-tools >=4.6 errors if BOTH the SOURCE_DATE_EPOCH env var AND
  # the explicit -all-time/-mkfs-time flags are set. Unset the env var
  # only for this invocation; we still pass the value via flags so the
  # output is bit-reproducible.
  local sde="$SOURCE_DATE_EPOCH"
  env -u SOURCE_DATE_EPOCH \
  mksquashfs "$STAGE_DIR" "$OUTPUT" \
    -comp zstd -Xcompression-level 19 \
    -no-xattrs \
    -all-time "$sde" \
    -mkfs-time "$sde" \
    -noappend -no-progress \
    -quiet
}

# Reproducible `.tar.zst` for Windows `wsl --import` (which can't consume a
# squashfs). Built from the SAME staged tree as the squashfs — same content,
# different packaging. Determinism: sorted names, fixed mtime
# (SOURCE_DATE_EPOCH), GNU format (no per-file pax atime/ctime headers),
# numeric ownership preserved. zstd is run single-threaded (`-T0` would
# interleave nondeterministically) at the highest level.
package_tar() {
  echo "==> tar.zst ($OUTPUT)"
  rm -f "$OUTPUT"
  # Only the read side (tar) may need root; zstd writes OUTPUT into our
  # own cache dir, so it stays unprivileged and the file is owned by us.
  maybe_sudo tar \
    --format=gnu \
    --sort=name \
    --numeric-owner \
    --mtime="@$SOURCE_DATE_EPOCH" \
    -C "$STAGE_DIR" -cf - . \
    | zstd -q -19 -T1 -o "$OUTPUT"
}

build_mmdebstrap

if [[ "$PACKAGE" == "tar" ]]; then
  package_tar
else
  package_squashfs
fi

size_h="$(du -h "$OUTPUT" | cut -f1)"
sha="$(sha256sum "$OUTPUT" | cut -d' ' -f1)"
echo "==> done: $OUTPUT ($size_h, sha256=$sha)"
