# Recipe for the "full" rootfs flavor. Sourced by build.sh.
#
# minimal + build toolchain + the Python/R/Node data-science stack.
# The apt layer is declarative; the pip/R/Node steps (which need a
# torch CPU index + the NodeSource repo) live in the `provision`
# function, run in the chroot after the apt layer.

# --------------------------------------------------------------------
# Pinned Ubuntu base — same shas as the minimal flavor.
# --------------------------------------------------------------------
UBUNTU_BASE_VERSION="24.04.4"
UBUNTU_BASE_SHA256_AMD64="c1e67ef7b17a6300e136118bd1dc04725009cb376c1aad10abcf8cd453628d58"
UBUNTU_BASE_SHA256_ARM64="04207713ece899c3740823d33690441ad3a7f0ded1101aca744e2b0f37ac7ff2"

# --------------------------------------------------------------------
# Pinned apt snapshot
# --------------------------------------------------------------------
APT_SNAPSHOT="20260101T000000Z"

# --------------------------------------------------------------------
# Layered apt packages
# --------------------------------------------------------------------
# Adds the build toolchain + native libs needed for the pip/R wheel
# builds in `provision`. bubblewrap + rsync needed by the WSL2 backend
# (see minimal recipe for the explanation).
APT_PACKAGES="
  ca-certificates
  curl wget bzip2 xz-utils unzip
  locales tzdata
  python3 python3-pip python3-venv python3-dev python-is-python3
  build-essential gfortran pkg-config
  libffi-dev libssl-dev zlib1g-dev
  jq git git-lfs
  vim ripgrep fd-find tree net-tools dnsutils iputils-ping
  gnupg lsb-release
  r-base r-base-dev
  bubblewrap rsync
"
# Audit D7: dropped `apt-transport-https` — since apt 1.5 (Ubuntu
# 18.04+) the https transport is built into apt itself, so the
# transitional package is a no-op (it'd just install dependencies
# already pulled in by curl/ca-certificates). Removing it shaves
# build time + reduces the determinism-failure surface.

# Post-apt provisioning. Runs inside the chroot via systemd-nspawn
# with /etc/resolv.conf bound so pip/CRAN/npm can resolve. build.sh
# ships this function in verbatim via `declare -f`.
provision() {
  # Map bare `pip` to pip3 so the LLM can run `pip install` directly
  # without the `pip3` reflex. `python-is-python3` (apt above)
  # handles `python` → `python3`.
  if [[ ! -e /usr/local/bin/pip ]]; then
    ln -sf /usr/bin/pip3 /usr/local/bin/pip
  fi

  # Python data-science stack (CPU-only torch — full GPU stack would
  # blow past the GitHub Releases 2 GiB per-asset cap).
  pip3 install --no-cache-dir --break-system-packages \
    numpy pandas matplotlib scipy scikit-learn \
    seaborn plotly statsmodels sympy \
    requests httpx beautifulsoup4 \
    ipython jupyter pillow openpyxl xlrd pyarrow
  pip3 install --no-cache-dir --break-system-packages \
    torch torchvision --extra-index-url https://download.pytorch.org/whl/cpu

  # R tidyverse.
  #
  # Audit D6: hard-pin `Ncpus=2` so the package-install order is
  # stable across build hosts. With `detectCores()` the order +
  # interleaving of compile output depend on the runner's vCPU
  # count — fine for a single host, but bit-determinism across
  # operator rebuilds + CI requires a fixed value. 2 keeps install
  # time bounded (~halves the serial cost) without re-introducing
  # the wider parallelism's non-determinism.
  Rscript -e "install.packages(c('ggplot2','dplyr','tidyr','readr','stringr','lubridate','purrr','tibble','jsonlite','httr','data.table','caret','forecast'), repos='https://cloud.r-project.org', Ncpus=2)"

  # Node 22 + ts-node from NodeSource (Canonical's noble repo only
  # ships node 18; the LLM frequently asks for >=20).
  #
  # Audit S2: install via the NodeSource apt repo + GPG-verified deb,
  # NOT `curl https://deb.nodesource.com/setup_22.x | bash -`. The
  # curl|bash path runs a dynamically-generated remote script with no
  # signature check; a compromise of NodeSource's CDN would inject
  # arbitrary code into the rootfs. The apt-repo path verifies the
  # .deb against a fixed signing key pinned in `/etc/apt/keyrings/`.
  mkdir -p /etc/apt/keyrings
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
    https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  chmod 0644 /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get -o Acquire::Retries=10 -o Acquire::http::Timeout=60 -qq update
  apt-get -o Acquire::Retries=10 -o Acquire::http::Timeout=60 \
    -y --no-install-recommends install nodejs
  npm install -g typescript ts-node
}
