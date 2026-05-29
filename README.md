# sandbox-rootfs

Build inputs for the **ziee code sandbox rootfs** — the Ubuntu-based
filesystem mounted inside `bwrap` for code execution.

Standalone repo so the rootfs ships out-of-band from `ziee-chat` server
releases. Artifacts (`.squashfs` + `.tar.zst` + sha256/zsync/cosign
sidecars) are published to **GitHub Releases on this repo** via the
`release.yml` workflow on tag push.

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

Output lands in `.cache/` (gitignored).

You need `bubblewrap`, `squashfuse`, `squashfs-tools`, `zstd`, and
`mmdebstrap` on the host:

```bash
sudo apt install bubblewrap squashfuse squashfs-tools zstd mmdebstrap
```

`mmdebstrap` is Linux-only. To iterate on Mac/Windows, run the build
inside a Linux container (`docker run --rm -v $PWD:/work -w /work
ubuntu:24.04 bash -c 'apt-get update && apt-get install -y mmdebstrap
squashfs-tools zstd && ./build.sh --flavor minimal'`).

## Versioning

Two coordinates:

| Coord | Meaning | Bumps when |
|---|---|---|
| `schema` | ABI break | Python major changes, binary paths the server expects move, layout changes |
| `revision` | Rebuild | Security patches, pin bumps within the same schema |

The ziee-chat server binary embeds `SANDBOX_ROOTFS_SCHEMA_VERSION`. At
boot it reads the rootfs's `.ziee-sandbox-rootfs-schema` (a single
integer) and refuses to enable on mismatch. Revisions matching the
schema are always accepted.

Release tag format: `sandbox-rootfs-v1.r3-x86_64`.

## Layout

```
.
├── README.md              # this file
├── RELEASE-RUNBOOK.md     # bootstrap + ongoing release flow
├── MACOS-RUNBOOK.md       # macOS-specific notes (libkrun, etc.)
├── build.sh               # generic mmdebstrap driver; outputs .squashfs or .tar.zst
├── compat.toml            # schema ↔ server-version matrix (ziee-chat include_str!s)
├── yanks.toml             # yanked revisions (PEP 592 pattern)
├── flavors/               # one self-contained recipe per flavor per schema
│   └── <flavor>/v<schema>/flavor.sh
└── .github/workflows/release.yml   # tag-triggered build + sign + publish
```

**Adding a flavor** = drop in `flavors/<name>/v<schema>/flavor.sh` (set
`APT_SNAPSHOT`, `APT_PACKAGES`, and an optional `provision()` function for
pip/R/npm/etc.); no `build.sh` edits. Also add the flavor to the CI
matrix (`.github/workflows/release.yml`) and to the consumer's
`KNOWN_FLAVORS` (in ziee-chat `src-app/server/src/modules/code_sandbox/types.rs`).

## Artifacts per release

Each tag produces **4 artifacts** (2 flavors × 2 packagings), plus
sha256 / zsync / cosign sidecars:

| Artifact | Host backend |
|---|---|
| `ziee-sandbox-rootfs-v{S}.{R}-{arch}-minimal.squashfs` | Linux (`squashfuse`), macOS (libkrun) |
| `ziee-sandbox-rootfs-v{S}.{R}-{arch}-minimal.tar.zst` | Windows (`wsl --import`) |
| `ziee-sandbox-rootfs-v{S}.{R}-{arch}-full.squashfs` | Linux, macOS |
| `ziee-sandbox-rootfs-v{S}.{R}-{arch}-full.tar.zst` | Windows |

Same `mmdebstrap` snapshot drives both packagings, so the rootfs
content is semantically identical — only the container format differs.

## Bootstrap (one-time, before any release exists)

```bash
./build.sh --flavor minimal
./build.sh --flavor minimal --package tar
./build.sh --flavor full
./build.sh --flavor full --package tar

gh release create sandbox-rootfs-v1.r0-x86_64 \
  --title "sandbox-rootfs v1.r0 (x86_64)" \
  --notes "Initial release. See compat.toml." \
  .cache/ziee-sandbox-rootfs-v1.r0-x86_64-*.squashfs \
  .cache/ziee-sandbox-rootfs-v1.r0-x86_64-*.tar.zst
```

After that, push a `sandbox-rootfs-v*` tag and the workflow does the
rest (build, repro check, size check, sha256, zsync, cosign, upload).

## Threat model

The sandbox protects against prompt-injection-induced exfiltration,
accidental destructive commands, and host filesystem pollution. It
does NOT protect against Linux kernel 0-days. For multi-tenant SaaS
execution, escalate to gVisor or Firecracker.

## Cross-references

- [`RELEASE-RUNBOOK.md`](./RELEASE-RUNBOOK.md) — bootstrap script +
  ongoing release flow, schema bumps, yanks, troubleshooting.
- [`MACOS-RUNBOOK.md`](./MACOS-RUNBOOK.md) — macOS / libkrun
  packaging notes.
- The consumer (ziee-chat server) embeds `compat.toml` via
  `include_str!` from this repo.
