# sandbox-rootfs

Build inputs for the **ziee code sandbox rootfs** — the Ubuntu-based
filesystem mounted inside `bwrap` for code execution and stdio MCP
isolation in [`ziee-chat`](https://github.com/phibya/ziee-chat).

Standalone repo so the rootfs ships out-of-band from `ziee-chat` server
releases. Artifacts (`.squashfs` + `.tar.zst` + `sha256` / `zsync` /
`cosign` sidecars) are published to **GitHub Releases on this repo**
via the `release.yml` workflow on tag push.

## Quick start (dev)

```bash
# Build the full (~1.6 GB compressed) flavor as a squashfs (Linux/macOS).
./build.sh --flavor full

# Or the minimal (~150 MB) flavor for fast iteration on bwrap/cgroup/
# seccomp mechanics that don't need numpy/torch:
./build.sh --flavor minimal

# Same content, repackaged as `.tar.zst` for Windows `wsl --import`:
./build.sh --flavor full --package tar
```

Output lands in `.cache/` (gitignored), version-less by default. Pass
`--version 0.0.1-test` to bake a `.ziee-sandbox-rootfs-version`
sentinel into the rootfs for local end-to-end testing — CI does this
automatically using the release tag.

You need `systemd-container` (for `systemd-nspawn`), `squashfs-tools`,
`zstd`, plus standard `curl` / `tar` / `sha256sum` on the host:

```bash
sudo apt install systemd-container squashfs-tools zstd curl tar coreutils
```

`systemd-nspawn` is Linux-only. To iterate on Mac/Windows, run the build
inside a Linux container:

```bash
docker run --rm --privileged -v $PWD:/work -w /work ubuntu:24.04 \
  bash -c 'apt-get update && apt-get install -y systemd-container squashfs-tools zstd curl && ./build.sh --flavor minimal'
```

## Versioning

Semver, tracked entirely by the **GitHub release tag** (e.g. `v0.1.0`,
matching the convention used by `ziee-ai/llama.cpp` and
`ziee-ai/mistral.rs`). The release tag IS the version — no `compat.toml`,
no schema-vs-revision split, no yank list.

The `ziee-chat` server discovers versions live via the GitHub Releases
API, downloads the artifact for the current pin (verified by `sha256`
+ keyless cosign), and lets the admin swap pins via the
`/settings/sandbox` page. Patch / minor bumps preserve every
conversation's workspace; major bumps wipe install-cache subdirs
(`.local`, `.cache`, `.npm`, …) so ABI-incompatible wheels and
node-native modules get reinstalled cleanly.

## Layout

```
.
├── README.md              # this file
├── build.sh               # ubuntu-base + apt + systemd-nspawn driver; outputs .squashfs or .tar.zst
├── flavors/               # one self-contained recipe per flavor
│   └── <flavor>/flavor.sh
└── .github/workflows/release.yml   # tag-triggered build + sign + publish
```

**Adding a flavor** = drop in `flavors/<name>/flavor.sh` (set
`APT_SNAPSHOT`, `APT_PACKAGES`, and an optional `provision()` function
for pip/R/npm/etc.); no `build.sh` edits. Also add the flavor to the
CI matrix (`.github/workflows/release.yml`) and to the consumer's
`KNOWN_FLAVORS` (in ziee-chat
`src-app/server/src/modules/code_sandbox/types.rs`).

## Artifacts per release

Each tag produces **8 artifacts** (2 arches × 2 flavors × 2 packagings),
plus `sha256` / `zsync` / `cosign` sidecars. `aarch64` builds natively
on GitHub's arm64 Linux runner (`ubuntu-24.04-arm`):

| Artifact | Host backend |
|---|---|
| `ziee-sandbox-rootfs-x86_64-minimal.squashfs`  | Linux x64 (`squashfuse`), macOS Intel (libkrun) |
| `ziee-sandbox-rootfs-x86_64-minimal.tar.zst`   | Windows x64 (`wsl --import`) |
| `ziee-sandbox-rootfs-x86_64-full.squashfs`     | Linux x64, macOS Intel |
| `ziee-sandbox-rootfs-x86_64-full.tar.zst`      | Windows x64 |
| `ziee-sandbox-rootfs-aarch64-minimal.squashfs` | Linux arm64, macOS Apple Silicon (libkrun) |
| `ziee-sandbox-rootfs-aarch64-minimal.tar.zst`  | Windows arm64 (`wsl --import`) |
| `ziee-sandbox-rootfs-aarch64-full.squashfs`    | Linux arm64, macOS Apple Silicon |
| `ziee-sandbox-rootfs-aarch64-full.tar.zst`     | Windows arm64 |

Same ubuntu-base + apt-snapshot drives both packagings, so the rootfs
content is semantically identical — only the container format differs.

## Bootstrap (one-time, before any release exists)

```bash
./build.sh --flavor minimal --package squashfs --version 0.1.0
./build.sh --flavor minimal --package tar      --version 0.1.0
./build.sh --flavor full    --package squashfs --version 0.1.0
./build.sh --flavor full    --package tar      --version 0.1.0

gh release create v0.1.0 \
  --title "sandbox-rootfs v0.1.0" \
  --notes "Initial release." \
  .cache/ziee-sandbox-rootfs-*-minimal.squashfs \
  .cache/ziee-sandbox-rootfs-*-minimal.tar.zst \
  .cache/ziee-sandbox-rootfs-*-full.squashfs \
  .cache/ziee-sandbox-rootfs-*-full.tar.zst
```

After that, push a `v*` semver tag and the workflow does the rest
(build, repro check, size check, sha256, zsync, cosign, upload).

## Verifying an artifact

```bash
gh release download v0.1.0 --pattern '*-x86_64-minimal.squashfs'

# sha256
sha256sum -c ziee-sandbox-rootfs-x86_64-minimal.squashfs.sha256

# cosign (keyless OIDC, tied to this workflow's identity)
cosign verify-blob \
  --bundle ziee-sandbox-rootfs-x86_64-minimal.squashfs.cosign.bundle \
  --certificate-identity-regexp \
    '^https://github\.com/ziee-ai/sandbox-rootfs/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
  --certificate-oidc-issuer \
    https://token.actions.githubusercontent.com \
  ziee-sandbox-rootfs-x86_64-minimal.squashfs
```

## Threat model

The sandbox protects against prompt-injection-induced exfiltration,
accidental destructive commands, and host filesystem pollution. It
does NOT protect against Linux kernel 0-days. For multi-tenant SaaS
execution, escalate to gVisor or Firecracker.
