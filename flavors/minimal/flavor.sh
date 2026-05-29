# Recipe for the "minimal" rootfs flavor. Sourced by build.sh.
#
# Starts from Canonical's pre-built `ubuntu-base-24.04.x-base-amd64.tar.gz`
# (~30 MB; sha-pinned below). That tarball already includes bash,
# coreutils, util-linux, apt, dpkg, libc6, libssl, ca-certificates,
# perl-base, etc — so this recipe only layers the LLM-facing tools.
#
# Output: ~57 MB squashfs. Build time: ~60-90 s end-to-end (vs ~10 min
# under the old mmdebstrap bootstrap).

# --------------------------------------------------------------------
# Pinned Ubuntu base
# --------------------------------------------------------------------
# Source: https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/SHA256SUMS
# Bump deliberately; the CI workflow's `size sanity check` will catch
# silent drift in resulting flavor size.
UBUNTU_BASE_VERSION="24.04.4"
UBUNTU_BASE_SHA256_AMD64="c1e67ef7b17a6300e136118bd1dc04725009cb376c1aad10abcf8cd453628d58"
UBUNTU_BASE_SHA256_ARM64="04207713ece899c3740823d33690441ad3a7f0ded1101aca744e2b0f37ac7ff2"

# --------------------------------------------------------------------
# Pinned apt snapshot for layered packages
# --------------------------------------------------------------------
# snapshot.ubuntu.com date for the .debs we install on top of
# ubuntu-base. Bumping the date implicitly bumps every layered .deb to
# whatever was current at that snapshot. Keep aligned with the
# UBUNTU_BASE_VERSION release date so the base + layer agree on
# library ABI versions.
APT_SNAPSHOT="20260101T000000Z"

# --------------------------------------------------------------------
# Layered packages
# --------------------------------------------------------------------
# Everything the LLM-facing minimal sandbox needs beyond ubuntu-base.
# bubblewrap + rsync are also required by the WSL2 backend's
# `provision_distro` (src-app/server/src/modules/code_sandbox/backend/wsl2.rs),
# so baking them in here short-circuits the runtime apt-get install on
# first execute_command — no network round-trip, no attack surface.
APT_PACKAGES="
  ca-certificates
  curl wget bzip2 xz-utils unzip
  locales tzdata
  python3 python3-pip python3-venv python-is-python3
  jq git
  bubblewrap rsync
"

# Map the bare `pip` and `pip3-cmd` shims so the LLM can run `pip
# install` directly (it almost always does — `pip3` is a reflex only a
# minority of Python users have). `python-is-python3` handles `python`
# → `python3`. We do `pip` ourselves because Debian doesn't ship a
# `pip-is-pip3` companion package.
provision() {
  if [[ ! -e /usr/local/bin/pip ]]; then
    ln -sf /usr/bin/pip3 /usr/local/bin/pip
  fi
}

# No provision() function for minimal — `apt install --no-install-recommends`
# above gives us everything we need without a chroot pip/R/npm step.
