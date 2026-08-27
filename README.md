# Candy Release

This repository is the binary distribution boundary for Candy. It contains no
Runtime or Core source code and no build scripts.

## Git layout

```text
channels/
  stable.json       Signed update catalog consumed by clients
  stable.json.sig   usign signature over stable.json
keys/
  catalog-release.pub  Trust anchor for update catalogs
  core-release.pub     Trust anchor for Core bundle manifests
```

GitHub Release assets hold all binaries. Git history only holds small signed
catalog data, public keys, checksums, and documentation.

The stable catalog has two fixed HTTPS endpoints:

```text
https://raw.githubusercontent.com/reTsubasa/candy-release/main/channels/stable.json
https://raw.githubusercontent.com/reTsubasa/candy-release/main/channels/stable.json.sig
```

<!-- stable-status:start -->
## Current stable channel

- Runtime: `0.4.0-r78`
- Core: `0.3.25`
- Catalog sequence: `105`
- Published at: `2026-08-27T01:27:18Z`
<!-- stable-status:end -->

## Release tags and asset names

Runtime and Core are the two canonical product Release families. Each Core
version has one `core-v<version>` Release containing all supported artifact
roles from the same Core source commit.

```text
runtime-v<runtime-version>-r<package-revision>
  candy-client-<runtime-version>-r<package-revision>.apk
  luci-app-candy-<runtime-version>-r<package-revision>.apk
  BUILD-INFO
  SHA256SUMS
  runtime-release-metadata.json

core-v<core-version>
  candy-core-<core-version>-<rust-target>.tar.gz
  candy-core-<core-version>-<rust-target>.tar.gz.sha256
  candy-core-<core-version>-<rust-target>.manifest.json
  core-release-metadata.json
  candy-core-<core-version>-cloud-abi-x86_64-unknown-linux-gnu.tar.gz
  candy-core-<core-version>-cloud-abi-x86_64-unknown-linux-gnu.tar.gz.sha256
  candy-core-<core-version>-cloud-abi-x86_64-unknown-linux-gnu.manifest.json
  core-cloud-abi-release-metadata.json
```

The already published `core-cloud-module-v0.3.10` Release remains available as
a compatibility source for its original URLs and hashes. It is a legacy
Release, is not a canonical product version, and no later Core Cloud ABI module
may be published under that tag family.

The `core-v0.3.10` migration draft therefore contains 11 assets: six signed
data-plane assets, three signed Cloud ABI payload assets, and two metadata
files. Both metadata files use `release_kind: candy-core`, the same
`core-v0.3.10` tag, and the same source commit.

Runtime releases are produced by `candy-runtime` GitHub Actions. Core releases
are built and stripped locally in the private `candy-core` repository, then
uploaded here as an unsigned, immutable
`candidate-core-v<version>-<commit12>` draft. The protected
`sign-core-candidate` Action validates and signs that candidate before creating
the `incoming-core-v<version>` draft. Runtime publishers upload directly to an
`incoming-<release-tag>` draft. Both paths then dispatch this repository's
`finalize-release` Action. That Action validates
the complete asset set, publishes the Release, updates this status block and
signs the stable catalog. Uploading an asset never publishes it to clients by
itself: clients only discover releases referenced by the signed stable catalog.

Published versions which are not the current `latest` are immutable. The
current `latest` version may be republished in place; the central Action then
replaces its assets, updates the catalog hashes, increments `sequence`, and
signs the new catalog. A changed Runtime package should normally increment the
package revision, and a changed Core binary should normally increment the Core
version, so latest replacement remains an explicit recovery path rather than
the routine release process. Immutability covers every allowlisted Release
asset, including metadata, manifests and checksum files, not only the Runtime
APKs or Core bundle.

## Version and target model

The product version lines are independent:

- Runtime uses SemVer plus an OpenWrt package revision, for example `0.4.0-r2`.
- Core uses its own SemVer, for example `0.3.4`.
- The catalog uses a monotonically increasing integer `sequence`.

Runtime target keys identify the exact OpenWrt release and package
architecture, for example `openwrt_25_12_4_x86_64`. Core target keys identify
the operating system, libc and CPU architecture, for example
`linux_musl_x86_64`. Compatibility is explicit; clients do not select a
nearest release or fall back across architectures.

Core currently has two artifact roles. `data_plane` contains the full
`candy-core` executables for OpenWrt and server deployments. `cloud_abi`
contains `libcandy_core_cloud.so` for a Cloud glibc process; it is a shared
library and not a `candy-core` executable. Its signed manifest binds module ABI
version 1, wire protocol `0.3`, build request schema
`candy-core-cloud-build-v1`, target, libc, file size and SHA-256.

## Catalog contract

`channels/stable.json` uses schema version 1 and a monotonically increasing
`sequence`. Runtime releases are keyed as `v<version>_r<revision>` and Core
releases as `v<version>`, with punctuation replaced by underscores. The
canonical catalog families are `runtime` and `core`. New Core entries retain
the top-level `targets` object consumed by existing OpenWrt clients and also
publish the full data-plane `targets` plus explicit `abi_profiles` for the
Cloud control ABI. Target keys are explicit so a consumer never guesses ABI
compatibility.

The `core_modules.releases.v0_3_10` catalog record is retained without changing
its values for legacy compatibility. Finalizing the unified `core-v0.3.10`
Release clears only `core_modules.latest`; it does not delete or replace that
historical entry or the old GitHub Release.

The OpenWrt client downloads `stable.json` and `stable.json.sig`, verifies them
with `keys/catalog-release.pub`, rejects a sequence lower than the last accepted
catalog, then selects only its exact OpenWrt release and architecture. Runtime
APK hashes come from the signed catalog. Core executables and Core Cloud
modules additionally verify their signed bundle manifest with
`keys/core-release.pub` before installation. The Cloud module bundle contains
exactly `libcandy_core_cloud.so`, `manifest.json`, and `manifest.sig`; the
finalizer rejects extra members, unsigned placeholders, unexpected ELF
dependencies or exports, and any RPATH/RUNPATH.

Update checks and installations are manual. There is no background update
service.

The client caches the last accepted catalog atomically below
`/var/lib/candy/update`. A manual check does not install anything. A Runtime
update downloads both APKs and preserves the current pair for rollback, stops
the service for the package transaction, restores `/etc/config/candy`, and
rolls back if the post-update health check fails. A Core update only downloads
and installs a verified version; activation remains a separate explicit action
on the Core page.

## Publishing order

1. Build and test in the owning repository.
2. Runtime uploads the exact allowlisted assets to an
   `incoming-<release-tag>` draft. Core uploads one complete unsigned candidate
   to `candidate-core-v<version>-<commit12>` and dispatches
   `candy-core-candidate-ready` with only `candidate_tag`.
3. The protected Core signing Action validates all candidate hashes and sizes,
   signs each manifest with `CANDY_CORE_SIGNING_KEY`, verifies the signatures,
   creates `incoming-core-v<version>`, then dispatches `candy-artifact-ready`.
4. The central Action downloads the draft, verifies the complete asset set,
   metadata, sizes and SHA-256 values. Core also requires its independent
   manifest signature.
5. The Action compares the complete incoming asset manifest with both the
   signed catalog entry and the existing formal Release. An identical replay
   exits before touching the formal Release.
6. For an accepted latest replacement, the Action prepares the signed catalog
   and local Git commit, backs up the formal assets, and stages the formal tag
   on that catalog commit before creating a new Release. Existing Releases
   update their tag only after the replacement assets have been verified. The
   Action then remotely verifies the exact asset set and pushes the catalog
   commit. A failed upload, verification, tag update or Git push restores the
   previous formal assets and tag (or deletes the new tag).
7. After the signed catalog is committed, the incoming draft is deleted.

For Core, the dispatch `release_kind` is always `core` and the incoming tag is
always `incoming-core-v<version>`. A new Core version must include both
`core-release-metadata.json` and `core-cloud-abi-release-metadata.json` plus
all assets named by them. The Cloud ABI metadata uses the same `candy-core`
release kind and canonical `core-v<version>` tag. Its three artifact components
are `cloud-abi-bundle`, `bundle-checksum`, and `cloud-abi-manifest`.

Executable-only drafts remain accepted solely to support an emergency exact
replacement of a pre-migration Core catalog entry. They cannot introduce a new
Core version.

A different hash for an existing non-latest version is rejected before the
final Release is touched. A different hash for the current latest version is
accepted and recorded as a new catalog sequence.

The catalog signing key is held only as the protected
`CANDY_CATALOG_SIGNING_KEY` Actions secret. The independent Core manifest key
is held only as the `candy-release` repository secret
`CANDY_CORE_SIGNING_KEY`; `candy-core` receives neither private key. Private
keys must never be committed to Git, attached to a Release, printed to logs,
or cached. The protected workflow signs only after validating a complete
unsigned candidate bound to its exact Core source commit. At least the current and
previous published Runtime and Core assets should be retained for rollback.
Any asset referenced by a signed catalog must not be deleted.
