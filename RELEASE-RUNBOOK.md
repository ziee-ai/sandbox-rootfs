# Sandbox rootfs release runbook

This runbook covers (a) the **bootstrap** — cutting the first release tag
manually — and (b) the **ongoing release flow** for revision bumps and
schema changes. After the bootstrap, every release is a single
`git push origin sandbox-rootfs-vN.rM-arch` away.

## Bootstrap (one-time)

```bash
./scripts/bootstrap-first-rootfs-release.sh
```

What it does:

1. Builds both `minimal` and `full` flavors via
   `src-app/sandbox-rootfs/build.sh --flavor <flavor>`.
2. Computes sha256 for each artifact.
3. Cosign-signs each artifact (skip with a warning if `cosign` isn't
   installed).
4. Creates a GitHub release tagged `sandbox-rootfs-v{schema}.{revision}-{arch}`
   (defaults: `v1.r0-x86_64`).
5. Updates `src-app/server/src/modules/code_sandbox/known_revisions.toml`
   with the (schema, revision, arch, flavor, sha256) tuples. The server
   binary embeds this file via `include_str!`; the server's runtime
   auto-fetch verifies downloads against it before mounting.

After the script finishes, **commit the updated `known_revisions.toml`**
and push. The change is what lets the server's auto-fetch resolve the
new revision for end users.

### Override defaults

```bash
SCHEMA=1 REVISION=r1 ARCH=x86_64 \
  ./scripts/bootstrap-first-rootfs-release.sh
```

Use `--dry-run` to see what would happen without actually creating the
release or modifying `known_revisions.toml`.

## Ongoing releases

CI is build-and-publish-only. All CI lives in the single
`.github/workflows/code_sandbox.yml` workflow (two jobs:
`release` + `update-known-revisions`). The release flow:

1. **Patch:** Pin updates / security backports stay on the same schema
   but bump the revision (e.g. `v1.r0` → `v1.r1`). Edit the flavor's recipe
   `src-app/sandbox-rootfs/flavors/<flavor>/v<schema>/flavor.sh` (bump
   `APT_SNAPSHOT` and/or the pip/R/npm versions in `provision`) and
   open a PR. Run `just check-release-ready` locally — it builds the
   rootfs twice and asserts byte-for-byte reproducibility (the same
   check CI runs). Get the PR reviewed + merged on the strength of
   the local run.
2. **Tag:** When ready to publish, push a tag matching
   `sandbox-rootfs-v{schema}.{revision}-{arch}`:
   ```bash
   git tag sandbox-rootfs-v1.r1-x86_64
   git push origin sandbox-rootfs-v1.r1-x86_64
   ```
3. **CI publishes:** The `release` job (matrix: minimal + full) builds
   both flavors, reproducibility-checks (build twice, diff sha256),
   size-sanity-checks, cosign-signs (keyless GitHub OIDC), and uploads
   `.squashfs` + `.sha256` + `.zsync` + `.cosign.bundle` to the GitHub
   Release.
   - **Windows tarball (Plan 1 §4):** the same job also runs
     `build.sh --package tar` for each flavor (re-tars the *identical*
     staged tree → `.tar.zst`; same schema, same contents, different
     packaging for `wsl --import`), reproducibility-checks it, cosign-signs
     it, and uploads `.tar.zst` + `.tar.zst.sha256` + `.tar.zst.cosign.bundle`
     alongside the squashfs. The runtime's `runtime_fetch::RootfsFormat`
     selects squashfs (Linux/macOS) vs tar.zst (Windows) by host OS; the
     asset name + cosign identity are packaging-agnostic.
4. **Auto-PR:** The follow-on `update-known-revisions` job parses the
   tag, takes the sha256 outputs from the matrix release job, and
   opens a PR against `main` appending the new (schema, revision,
   sha256, signed=true) tuples to
   `src-app/server/src/modules/code_sandbox/known_revisions.toml`.
   It also writes `sha256_tar_zst` (the `.tar.zst` digest) onto each
   row so Windows hosts can verify+fetch the tarball. Reviewer merges
   to make the new revision resolvable by the server's runtime auto-fetch.

## Schema bumps

A schema bump is an **ABI-breaking** rootfs change (e.g. Python major
version bump, layout change, binary path move). Schema bumps require:

1. Bump the const in two places:
   - `src-app/server/src/modules/code_sandbox/mod.rs`:
     `SANDBOX_ROOTFS_SCHEMA_VERSION`
   - `src-app/sandbox-rootfs/compat.toml`: `current_schema`
2. Update `compat.toml`'s `[[schemas]]` table with the new entry's
   `ziee_server_min` / `ziee_server_max` range.
3. Add the new schema's recipes: `flavors/<flavor>/v<new-schema>/flavor.sh`
   for each flavor (start by copying the previous schema's recipe). The old
   `v<schema>/` recipes stay in-tree so still-supported old-schema revisions
   remain rebuildable.
4. Cut a new release with the new schema (`SCHEMA=2 REVISION=r0
   ./scripts/bootstrap-first-rootfs-release.sh`).
5. Existing servers boot-probe their installed rootfs's
   `.ziee-sandbox-rootfs-schema` sentinel against the binary's
   `SANDBOX_ROOTFS_SCHEMA_VERSION`. A mismatch refuses to register the
   sandbox MCP row and logs the upgrade command.

## Yanks

If a published revision turns out to be broken (security CVE, broken
package), add it to `src-app/sandbox-rootfs/yanks.toml` and commit.
The server's auto-fetch then skips yanked revisions
when resolving "latest". Operators who pinned an exact revision continue
working — yanks don't delete artifacts.

```toml
# src-app/sandbox-rootfs/yanks.toml
[[yanked]]
schema = 1
revision = "r2"
reason = "CVE-2026-XXXX in openssl"
yanked_at = "2026-06-15"
```

## Troubleshooting

### `gh release create` fails with "tag already exists"

The release was previously cut (or partially). Delete and re-run:

```bash
gh release delete sandbox-rootfs-v1.r0-x86_64 --yes --cleanup-tag
./scripts/bootstrap-first-rootfs-release.sh
```

### `cosign sign-blob` fails

Cosign needs network access to talk to the Sigstore Fulcio +
Rekor services. Confirm `cosign verify-blob` works against a known
good artifact first. As a fallback, omit cosign (the script warns
and proceeds without a `.cosign.bundle`). Operators who want sig
verification can install the bundle later.

### mmdebstrap fails with "/etc/subuid is empty: invalid idmap"

Without a subuid range, mmdebstrap can't operate in unprivileged
mode. `build.sh` auto-detects this and switches to `--mode=root`
via sudo. Confirm passwordless sudo works:

```bash
sudo -n true && echo "sudo ok" || echo "configure passwordless sudo first"
```

### The bootstrap script reports cosign missing but proceeds

That's intentional — cosign is a nice-to-have, not a blocker. The
release will exist but lack the `.cosign.bundle` file, which means
the server's auto-fetch will fall back to sha256-only verification.
Install cosign and re-run later to add signatures:

```bash
cosign sign-blob --bundle <bundle.cosign.bundle> <squashfs>
gh release upload sandbox-rootfs-v1.r0-x86_64 <bundle.cosign.bundle>
```

## Verification

After a release, verify the contract end-to-end:

```bash
# Operator path
mkdir -p /tmp/rootfs-verify
gh release download sandbox-rootfs-v1.r0-x86_64 \
    --pattern '*-x86_64-minimal.squashfs' \
    --dir /tmp/rootfs-verify
gh release download sandbox-rootfs-v1.r0-x86_64 \
    --pattern '*-x86_64-minimal.squashfs.sha256' \
    --dir /tmp/rootfs-verify
( cd /tmp/rootfs-verify && sha256sum -c *.sha256 )

# Server path (after the auto-PR merge): no CLI step — boot the server
# with code_sandbox.enabled and trigger any execute_command. The runtime
# auto-fetches (sha256 + sigstore verify) and mounts the matching rootfs;
# the hardening log should show pid_ns/cgroup/seccomp.
```
