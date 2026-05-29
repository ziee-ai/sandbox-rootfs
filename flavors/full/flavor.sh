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
  gnupg lsb-release apt-transport-https
  r-base r-base-dev
  bubblewrap rsync
"

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

  # R tidyverse. `Ncpus=detectCores()` halves install time vs serial.
  Rscript -e "install.packages(c('ggplot2','dplyr','tidyr','readr','stringr','lubridate','purrr','tibble','jsonlite','httr','data.table','caret','forecast'), repos='https://cloud.r-project.org', Ncpus=parallel::detectCores())"

  # Node 22 + ts-node from NodeSource (Canonical's noble repo only
  # ships node 18; the LLM frequently asks for >=20).
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y --no-install-recommends nodejs
  npm install -g typescript ts-node
}
