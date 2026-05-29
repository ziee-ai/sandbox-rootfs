# Recipe for the "full" rootfs flavor (schema 1). Sourced by build.sh.
#
# minimal + build toolchain + the Python/R/Node data-science stack. The apt
# layer is declarative; the pip/R/Node steps (which need a torch CPU index and
# the NodeSource repo) live in the `provision` function, run in the chroot
# after bootstrap.

DESCRIPTION="minimal + numpy + pandas + torch + R 4.4 + tidyverse + Node 22 + ts-node."
APPROX_SIZE_MB=853

# snapshot.ubuntu.com date for reproducible apt installs. Bump deliberately;
# CI's reproducibility check will catch silent drift.
APT_SNAPSHOT="20250115T000000Z"

# Whitespace/newline separated; build.sh collapses to mmdebstrap's comma list.
#
# bubblewrap + rsync are required by the WSL2 backend's `provision_distro`
# (src-app/server/src/modules/code_sandbox/backend/wsl2.rs). Baked in here
# so the runtime `apt-get install` step short-circuits via the `command -v`
# check. Same packages also useful on Linux/Mac.
APT_PACKAGES="
  bash coreutils util-linux ca-certificates curl wget bzip2 xz-utils unzip
  locales tzdata python3 python3-pip python3-venv
  build-essential gfortran git git-lfs libffi-dev libssl-dev zlib1g-dev
  vim jq ripgrep fd-find tree net-tools dnsutils iputils-ping
  gnupg lsb-release apt-transport-https r-base r-base-dev
  bubblewrap rsync
"

# Post-bootstrap provisioning. Runs inside the chroot (systemd-nspawn) with
# /etc/resolv.conf bound so pip/CRAN/npm can resolve. build.sh ships this
# function into the chroot verbatim via `declare -f`.
provision() {
  pip3 install --no-cache-dir --break-system-packages \
    numpy pandas matplotlib scipy scikit-learn \
    seaborn plotly statsmodels sympy \
    requests httpx beautifulsoup4 \
    ipython jupyter pillow openpyxl xlrd pyarrow
  pip3 install --no-cache-dir --break-system-packages \
    torch torchvision --extra-index-url https://download.pytorch.org/whl/cpu

  Rscript -e "install.packages(c('ggplot2','dplyr','tidyr','readr','stringr','lubridate','purrr','tibble','jsonlite','httr','data.table','caret','forecast'), repos='https://cloud.r-project.org', Ncpus=parallel::detectCores())"

  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y --no-install-recommends nodejs
  npm install -g typescript ts-node
}
