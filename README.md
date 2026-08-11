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

- Runtime: `0.4.0-r23`
- Core: `0.3.9`
- Core Cloud module: `0.3.10`
- Catalog sequence: `29`
- Published at: `2026-08-11T08:23:38Z`
<!-- stable-status:end -->

## Release tags and asset names

Runtime, executable Core, and Core Cloud module releases are independent
artifact families. The module version identifies the Core source version that
defines its ABI implementation.

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

core-cloud-module-v<core-version>
  candy-core-cloud-module-<core-version>-x86_64-unknown-linux-gnu.tar.gz
  candy-core-cloud-module-<core-version>-x86_64-unknown-linux-gnu.tar.gz.sha256
  candy-core-cloud-module-<core-version>-x86_64-unknown-linux-gnu.manifest.json
  core-cloud-module-release-metadata.json
```

Runtime releases are produced by `candy-runtime` GitHub Actions. Core releases
are built, stripped, signed, and uploaded locally from the private
`candy-core` repository. Both publishers upload only to an
`incoming-<release-tag>` draft Release and
then dispatch this repository's `finalize-release` Action. That Action validates
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

The release version lines are independent:

- Runtime uses SemVer plus an OpenWrt package revision, for example `0.4.0-r2`.
- Core uses its own SemVer, for example `0.3.4`.
- The Core Cloud module uses the Core source SemVer and its own release family.
- The catalog uses a monotonically increasing integer `sequence`.

Runtime target keys identify the exact OpenWrt release and package
architecture, for example `openwrt_25_12_4_x86_64`. Core target keys identify
the operating system, libc and CPU architecture, for example
`linux_musl_x86_64`. Compatibility is explicit; clients do not select a
nearest release or fall back across architectures.

The Core Cloud module is a separate artifact family. Its initial target is
`x86_64-unknown-linux-gnu`, represented in the catalog as
`linux_glibc_x86_64`. It is a shared library named
`libcandy_core_cloud.so`, not a `candy-core` executable. The signed manifest
binds module ABI version 1, wire protocol `0.3`, build request schema
`candy-core-cloud-build-v1`, target, libc, file size and SHA-256.

## Catalog contract

`channels/stable.json` uses schema version 1 and a monotonically increasing
`sequence`. Runtime releases are keyed as `v<version>_r<revision>` and Core
and Core Cloud module releases as `v<version>`, with punctuation replaced by
underscores. The three catalog families are `runtime`, `core`, and
`core_modules`. Target keys are explicit so a client never guesses ABI
compatibility.

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
2. Upload the exact allowlisted assets to an `incoming-<release-tag>` draft
   Release in this repository.
3. Dispatch `candy-artifact-ready` with only `release_kind` and `staging_tag`.
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

For a Cloud module, the dispatch `release_kind` is `core-cloud-module`, the
incoming tag is `incoming-core-cloud-module-v<version>`, and
`core-cloud-module-release-metadata.json` uses release kind
`candy-core-cloud-module`. Its three artifact components are
`cloud-module-bundle`, `bundle-checksum`, and `cloud-module-manifest`.

A different hash for an existing non-latest version is rejected before the
final Release is touched. A different hash for the current latest version is
accepted and recorded as a new catalog sequence.

The catalog signing key is held only as the protected
`CANDY_CATALOG_SIGNING_KEY` Actions secret. The Core manifest signing key is
held either by the offline Core release machine or by the private
`candy-core` repository's protected `core-release-signing` Environment. It must never
be committed to Git, attached to a Release, printed to logs, or cached. The
protected workflow signs only after an isolated job reproduces an unsigned
candidate from the exact protected-main commit. At least the current and
previous published Runtime and Core assets should be retained for rollback.
Any asset referenced by a signed catalog must not be deleted.
