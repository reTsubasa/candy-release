#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

fail() {
  printf '%s\n' "sign-core-candidate: $*" >&2
  exit 1
}

file_sha() {
  sha256sum "$1" | awk '{ print tolower($1) }'
}

file_size() {
  wc -c < "$1" | tr -d ' '
}

require_file() {
  local path=$1 maximum=$2 size
  [[ -f "$path" && ! -L "$path" ]] || fail "missing regular file: $path"
  size=$(file_size "$path")
  [[ "$size" -gt 0 && "$size" -le "$maximum" ]] || fail "invalid file size: $path"
}

[[ $# -eq 5 ]] || fail "usage: $0 CANDIDATE_TAG CANDIDATE_DIR OUTPUT_DIR SECRET_KEY PUBLIC_KEY"

candidate_tag=$1
candidate_dir=$2
output_dir=$3
secret_key=$4
public_key=$5

for command in cmp find jq sha256sum tar usign; do
  command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
done
[[ -d "$candidate_dir" && ! -L "$candidate_dir" ]] || fail "candidate directory is invalid"
require_file "$secret_key" 65536
require_file "$public_key" 65536
[[ "$(usign -F -p "$public_key")" == d78de22abfca5b57 ]] || fail "unexpected Core release public key"
[[ "$(usign -F -s "$secret_key")" == "$(usign -F -p "$public_key")" ]] ||
  fail "Core signing key does not match the checked-in public key"

metadata="$candidate_dir/core-candidate-metadata.json"
require_file "$metadata" 1048576
version=$(jq -er '.core.version' "$metadata")
source_commit=$(jq -er '.source.commit' "$metadata")
commit12=${source_commit:0:12}
[[ "$candidate_tag" == "candidate-core-v$version-$commit12" ]] || fail "candidate tag does not match metadata"
[[ "$candidate_tag" =~ ^candidate-core-v[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{12}$ ]] || fail "invalid candidate tag"

jq -e --arg version "$version" --arg commit "$source_commit" '
  (keys | sort) == ["artifacts","cloud_abi","core","release_kind","schema_version","source","targets","unsigned"] and
  .schema_version == 3 and .release_kind == "candy-core-unsigned-candidate" and .unsigned == true and
  .source == {repository:"reTsubasa/candy-core",commit:$commit} and
  .core == {version:$version} and
  ($version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
  ($commit | test("^[0-9a-f]{40,64}$")) and
  ([.targets[].rust_target] | sort) == ["aarch64-unknown-linux-musl","armv7-unknown-linux-musleabihf","x86_64-unknown-linux-musl"] and
  ([.cloud_abi[].rust_target] | sort) == ["aarch64-unknown-linux-gnu","x86_64-unknown-linux-gnu"] and
  (.targets | length) == 3 and (.cloud_abi | length) == 2 and (.artifacts | length) == 15 and
  all(.targets[];
    (. | keys | sort) == ["architecture","artifacts","libc","os","rust_target"] and
    .os == "linux" and .libc == "musl" and (.artifacts | length) == 3) and
  all(.cloud_abi[];
    (. | keys | sort) == ["architecture","artifacts","libc","os","role","rust_target"] and
    .os == "linux" and .libc == "glibc" and .role == "cloud-abi" and (.artifacts | length) == 3) and
  all(.artifacts[];
    (.name | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
    (.sha256 | test("^[0-9a-f]{64}$")) and
    (.size_bytes | type == "number" and floor == . and . > 0)) and
  ([.artifacts[].name] | unique | length) == 15
' "$metadata" >/dev/null || fail "candidate metadata contract mismatch"

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/candy-core-sign.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
jq -S '[.targets[].artifacts[], .cloud_abi[].artifacts[]] | sort_by(.name)' "$metadata" > "$work/nested-artifacts.json"
jq -S '.artifacts | sort_by(.name)' "$metadata" > "$work/global-artifacts.json"
cmp "$work/nested-artifacts.json" "$work/global-artifacts.json" >/dev/null || fail "candidate artifact indexes disagree"

: > "$work/expected-assets"
jq -r '.artifacts[].name' "$metadata" | sort > "$work/expected-assets"
printf '%s\n' core-candidate-metadata.json >> "$work/expected-assets"
sort -o "$work/expected-assets" "$work/expected-assets"
find "$candidate_dir" -mindepth 1 -maxdepth 1 -type f -exec basename {} \; | sort > "$work/actual-assets"
cmp "$work/expected-assets" "$work/actual-assets" >/dev/null || fail "unexpected candidate asset set"
[[ -z "$(find "$candidate_dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]] || fail "candidate contains a non-file asset"

while IFS=$'\t' read -r name expected_sha expected_size; do
  path="$candidate_dir/$name"
  require_file "$path" 134217728
  [[ "$(file_sha "$path")" == "$expected_sha" ]] || fail "candidate SHA mismatch: $name"
  [[ "$(file_size "$path")" == "$expected_size" ]] || fail "candidate size mismatch: $name"
done < <(jq -r '.artifacts[] | [.name,.sha256,.size_bytes] | @tsv' "$metadata")

mkdir -p "$output_dir"
[[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "output directory must be empty"
: > "$work/core-targets.jsonl"
: > "$work/core-artifacts.jsonl"
: > "$work/cloud-targets.jsonl"
: > "$work/cloud-artifacts.jsonl"

sign_manifest() {
  local manifest=$1 signature=$2
  usign -S -s "$secret_key" -m "$manifest" -x "$signature"
  require_file "$signature" 65536
  ! grep -Fqx 'UNSIGNED-LOCAL-BUILD' "$signature" || fail "signer produced an unsigned placeholder"
  usign -V -p "$public_key" -m "$manifest" -x "$signature" >/dev/null 2>&1 ||
    fail "new Core manifest signature is invalid"
}

record_artifact() {
  local path=$1 component=$2 destination=$3
  jq -nc --arg name "$(basename "$path")" --arg component "$component" \
    --arg sha256 "$(file_sha "$path")" --argjson size_bytes "$(file_size "$path")" \
    '{name:$name,component:$component,sha256:$sha256,size_bytes:$size_bytes}' >> "$destination"
}

for target in x86_64-unknown-linux-musl armv7-unknown-linux-musleabihf aarch64-unknown-linux-musl; do
  case "$target" in
    x86_64-unknown-linux-musl) expected_arch=x86_64 ;;
    armv7-unknown-linux-musleabihf) expected_arch=armv7 ;;
    aarch64-unknown-linux-musl) expected_arch=aarch64 ;;
  esac
  base="candy-core-$version-$target"
  bundle="$candidate_dir/$base.tar.gz"
  checksum="$candidate_dir/$base.tar.gz.sha256"
  manifest="$candidate_dir/$base.manifest.json"
  for path in "$bundle" "$checksum" "$manifest"; do require_file "$path" 134217728; done
  [[ "$(tar -tzf "$bundle")" == $'candy-core\nmanifest.json\nmanifest.sig' ]] || fail "invalid Core bundle contents: $base"
  extract="$work/$target"
  mkdir -m 0700 "$extract"
  tar -xzf "$bundle" -C "$extract"
  require_file "$extract/candy-core" 134217728
  require_file "$extract/manifest.json" 1048576
  require_file "$extract/manifest.sig" 65536
  cmp "$manifest" "$extract/manifest.json" >/dev/null || fail "detached Core manifest differs: $target"
  [[ "$(cat "$extract/manifest.sig")" == UNSIGNED-LOCAL-BUILD ]] || fail "candidate Core signature is not the unsigned placeholder: $target"
  [[ -x "$extract/candy-core" && ! -L "$extract/candy-core" ]] || fail "candidate Core executable is invalid: $target"
  jq -e --arg version "$version" --arg target "$target" --arg arch "$expected_arch" '
    .schema_version == 1 and .process_api_version == .core.process_api_version and
    .core.core_version == $version and .artifact.target == $target and
    .artifact.target_os == "linux" and .artifact.target_arch == $arch and .artifact.libc == "musl" and
    .artifact.executable == "candy-core" and (.artifact.executable_sha256 | test("^[0-9a-f]{64}$"))
  ' "$manifest" >/dev/null || fail "Core manifest contract mismatch: $target"
  [[ "$(file_sha "$extract/candy-core")" == "$(jq -er '.artifact.executable_sha256' "$manifest")" ]] ||
    fail "Core executable SHA mismatch: $target"
  sign_manifest "$extract/manifest.json" "$extract/manifest.sig"
  output_bundle="$output_dir/$base.tar.gz"
  output_checksum="$output_dir/$base.tar.gz.sha256"
  cp "$manifest" "$output_dir/$base.manifest.json"
  tar -czf "$output_bundle" -C "$extract" candy-core manifest.json manifest.sig
  printf '%s  %s\n' "$(file_sha "$output_bundle")" "$(basename "$output_bundle")" > "$output_checksum"
  jq -c --arg target "$target" '.targets[] | select(.rust_target == $target) | del(.artifacts)' "$metadata" >> "$work/core-targets.jsonl"
  record_artifact "$output_bundle" core-bundle "$work/core-artifacts.jsonl"
  record_artifact "$output_checksum" bundle-checksum "$work/core-artifacts.jsonl"
  record_artifact "$output_dir/$base.manifest.json" core-manifest "$work/core-artifacts.jsonl"
done

for target in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
  case "$target" in
    x86_64-unknown-linux-gnu) expected_arch=x86_64 ;;
    aarch64-unknown-linux-gnu) expected_arch=aarch64 ;;
  esac
  base="candy-core-$version-cloud-abi-$target"
  bundle="$candidate_dir/$base.tar.gz"
  checksum="$candidate_dir/$base.tar.gz.sha256"
  manifest="$candidate_dir/$base.manifest.json"
  for path in "$bundle" "$checksum" "$manifest"; do require_file "$path" 134217728; done
  [[ "$(tar -tzf "$bundle")" == $'libcandy_core_cloud.so\nmanifest.json\nmanifest.sig' ]] || fail "invalid Cloud ABI bundle contents: $base"
  extract="$work/cloud-$target"
  mkdir -m 0700 "$extract"
  tar -xzf "$bundle" -C "$extract"
  require_file "$extract/libcandy_core_cloud.so" 134217728
  require_file "$extract/manifest.json" 1048576
  require_file "$extract/manifest.sig" 65536
  cmp "$manifest" "$extract/manifest.json" >/dev/null || fail "detached Cloud ABI manifest differs: $target"
  [[ "$(cat "$extract/manifest.sig")" == UNSIGNED-LOCAL-BUILD ]] || fail "candidate Cloud ABI signature is not the unsigned placeholder: $target"
  [[ -x "$extract/libcandy_core_cloud.so" && ! -L "$extract/libcandy_core_cloud.so" ]] || fail "candidate Cloud ABI library is invalid: $target"
  jq -e --arg version "$version" --arg commit "$source_commit" --arg target "$target" --arg arch "$expected_arch" '
    .schema_version == 1 and .release_kind == "candy-core" and
    .source == {repository:"reTsubasa/candy-core",commit:$commit} and
    .module.version == $version and .module.abi_version == 1 and
    .module.library == "libcandy_core_cloud.so" and .module.wire_protocol == "0.3" and
    .module.build_request_schema == "candy-core-cloud-build-v1" and
    .artifact.kind == "shared-library" and .artifact.name == "libcandy_core_cloud.so" and
    .artifact.target == $target and .artifact.target_os == "linux" and
    .artifact.target_arch == $arch and .artifact.libc == "glibc"
  ' "$manifest" >/dev/null || fail "Cloud ABI manifest contract mismatch: $target"
  [[ "$(file_sha "$extract/libcandy_core_cloud.so")" == "$(jq -er '.artifact.sha256' "$manifest")" ]] ||
    fail "Cloud ABI library SHA mismatch: $target"
  [[ "$(file_size "$extract/libcandy_core_cloud.so")" == "$(jq -er '.artifact.size_bytes' "$manifest")" ]] ||
    fail "Cloud ABI library size mismatch: $target"
  sign_manifest "$extract/manifest.json" "$extract/manifest.sig"
  output_bundle="$output_dir/$base.tar.gz"
  output_checksum="$output_dir/$base.tar.gz.sha256"
  cp "$manifest" "$output_dir/$base.manifest.json"
  tar -czf "$output_bundle" -C "$extract" libcandy_core_cloud.so manifest.json manifest.sig
  printf '%s  %s\n' "$(file_sha "$output_bundle")" "$(basename "$output_bundle")" > "$output_checksum"
  jq -c --arg target "$target" '.cloud_abi[] | select(.rust_target == $target) | del(.artifacts)' "$metadata" >> "$work/cloud-targets.jsonl"
  record_artifact "$output_bundle" cloud-abi-bundle "$work/cloud-artifacts.jsonl"
  record_artifact "$output_checksum" bundle-checksum "$work/cloud-artifacts.jsonl"
  record_artifact "$output_dir/$base.manifest.json" cloud-abi-manifest "$work/cloud-artifacts.jsonl"
done

reference="$output_dir/candy-core-$version-x86_64-unknown-linux-musl.manifest.json"
jq -n \
  --arg tag "core-v$version" --arg version "$version" --arg commit "$source_commit" \
  --argjson core_api "$(jq -er '.core.core_api_version' "$reference")" \
  --argjson process_api "$(jq -er '.core.process_api_version' "$reference")" \
  --arg protocol "$(jq -er '.core.protocol_version | "\(.major).\(.minor)"' "$reference")" \
  --slurpfile targets "$work/core-targets.jsonl" --slurpfile artifacts "$work/core-artifacts.jsonl" '
  {schema_version:2,release_kind:"candy-core",release_tag:$tag,
   core:{version:$version,core_api_version:$core_api,process_api_version:$process_api,protocol_version:$protocol},
   source:{repository:"reTsubasa/candy-core",commit:$commit},targets:$targets,artifacts:$artifacts,
   signature:{format:"usign",embedded_path:"manifest.sig",verified:true}}
' > "$output_dir/core-release-metadata.json"

cloud_reference="$output_dir/candy-core-$version-cloud-abi-x86_64-unknown-linux-gnu.manifest.json"
jq -n \
  --arg tag "core-v$version" --arg version "$version" --arg commit "$source_commit" \
  --argjson abi "$(jq -er '.module.abi_version' "$cloud_reference")" \
  --arg wire "$(jq -er '.module.wire_protocol' "$cloud_reference")" \
  --arg schema "$(jq -er '.module.build_request_schema' "$cloud_reference")" \
  --slurpfile targets "$work/cloud-targets.jsonl" --slurpfile artifacts "$work/cloud-artifacts.jsonl" '
  {schema_version:2,release_kind:"candy-core",release_tag:$tag,
   source:{repository:"reTsubasa/candy-core",commit:$commit},
   module:{version:$version,abi_version:$abi,wire_protocol:$wire,build_request_schema:$schema},
   targets:$targets,artifacts:$artifacts,
   signature:{format:"usign",embedded_path:"manifest.sig",verified:true}}
' > "$output_dir/core-cloud-abi-release-metadata.json"

[[ "$(find "$output_dir" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" == 17 ]] || fail "signed Core release must contain exactly 17 assets"
[[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]] || fail "signed Core output contains a non-file asset"
printf '%s\n' "Signed $candidate_tag as incoming-core-v$version"
