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

## Release tags and asset names

Runtime and Core versions are independent.

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
```

Runtime releases are produced by `candy-runtime` GitHub Actions. Core releases
are built, stripped, signed, and uploaded locally from the private
`candy-core` repository. Uploading an asset never publishes it to clients by
itself: clients only discover releases referenced by the signed stable catalog.

Release tags and assets are immutable. A changed Runtime package increments
the package revision even when the Runtime version is unchanged. A changed
Core binary increments the Core version; an existing Core tag must never be
rebuilt in place.

## Version and target model

The three version lines are independent:

- Runtime uses SemVer plus an OpenWrt package revision, for example `0.4.0-r2`.
- Core uses its own SemVer, for example `0.3.4`.
- The catalog uses a monotonically increasing integer `sequence`.

Runtime target keys identify the exact OpenWrt release and package
architecture, for example `openwrt_25_12_4_x86_64`. Core target keys identify
the operating system, libc and CPU architecture, for example
`linux_musl_x86_64`. Compatibility is explicit; clients do not select a
nearest release or fall back across architectures.

## Catalog contract

`channels/stable.json` uses schema version 1 and a monotonically increasing
`sequence`. Runtime releases are keyed as `v<version>_r<revision>` and Core
releases as `v<version>`, with punctuation replaced by underscores. Target keys
are explicit so a client never guesses ABI compatibility.

The OpenWrt client downloads `stable.json` and `stable.json.sig`, verifies them
with `keys/catalog-release.pub`, rejects a sequence lower than the last accepted
catalog, then selects only its exact OpenWrt release and architecture. Runtime
APK hashes come from the signed catalog. Core additionally verifies its signed
bundle manifest with `keys/core-release.pub` before installation.

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
2. Publish immutable assets to a matching GitHub Release in this repository.
3. Verify every asset size and SHA-256 from GitHub, not only from the build
   workspace.
4. Add the release and exact targets to `channels/stable.json`, update `latest`,
   increment `sequence`, and set `published_at`.
5. Sign the exact catalog bytes with the offline catalog key, verify the
   signature, then commit and push the catalog and signature together.

The Runtime Action and the local Core publisher stop after step 2. They never
modify the catalog. At least the current and previous published Runtime and
Core assets should be retained for rollback. Any asset referenced by a signed
catalog must not be deleted.
