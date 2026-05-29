# Recipe for the "minimal" rootfs flavor. Sourced by build.sh.
#
# Pure-apt: shell + coreutils + curl + jq + git + python3 interpreter.
# No `provision` function → build.sh skips the chroot layer entirely.

# snapshot.ubuntu.com date for reproducible apt installs. Bump deliberately;
# CI's reproducibility check will catch silent drift.
APT_SNAPSHOT="20250115T000000Z"

# Whitespace/newline separated; build.sh collapses to mmdebstrap's comma list.
#
# bubblewrap + rsync are required by the WSL2 backend's `provision_distro`
# (src-app/server/src/modules/code_sandbox/backend/wsl2.rs). Baked in here
# so the runtime `apt-get install` step short-circuits via the `command -v`
# check — no network round-trip on first execute_command, no attack surface
# during install. Same packages also useful on Linux/Mac (rsync is the MED-1
# workspace-sync tool; bwrap inside the rootfs is the LCD execution shim).
APT_PACKAGES="
  bash coreutils util-linux ca-certificates curl wget bzip2 xz-utils unzip
  locales tzdata python3 python3-pip python3-venv
  bubblewrap rsync
"
