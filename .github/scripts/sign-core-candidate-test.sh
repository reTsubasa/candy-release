#!/usr/bin/env bash

set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
signer=$root/.github/scripts/sign-core-candidate.sh
temporary=$(mktemp -d "${TMPDIR:-/tmp}/candy-core-candidate-sign.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
candidate=$temporary/candidate
output=$temporary/output
mkdir -p "$temporary/bin" "$candidate"

cat > "$temporary/bin/usign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode=
manifest=
signature=
key=
while [[ $# -gt 0 ]]; do
  case "$1" in
    -F|-S|-V) mode=$1 ;;
    -m) shift; manifest=$1 ;;
    -x) shift; signature=$1 ;;
    -p|-s) shift; key=$1 ;;
    *) exit 2 ;;
  esac
  shift
done
case "$mode" in
  -F) cat "$key" ;;
  -S) printf 'fixture-signature:%s\n' "$(sha256sum "$manifest" | awk '{print $1}')" > "$signature" ;;
  -V) [[ "$(cat "$signature")" == "fixture-signature:$(sha256sum "$manifest" | awk '{print $1}')" ]] ;;
  *) exit 2 ;;
esac
EOF
chmod 0755 "$temporary/bin/usign"
printf '%s\n' d78de22abfca5b57 > "$temporary/core-release.pub"
printf '%s\n' d78de22abfca5b57 > "$temporary/core-release.sec"
chmod 0600 "$temporary/core-release.sec"

version=0.3.26
commit=1234567890abcdef1234567890abcdef12345678
: > "$temporary/targets.jsonl"
: > "$temporary/cloud.jsonl"

record() {
  local path=$1 component=$2 target=$3 role=${4:-}
  jq -nc --arg name "$(basename "$path")" --arg component "$component" --arg target "$target" \
    --arg role "$role" --arg sha256 "$(sha256sum "$path" | awk '{print $1}')" \
    --argjson size_bytes "$(wc -c < "$path" | tr -d ' ')" '
      {name:$name,component:$component,target:$target,sha256:$sha256,size_bytes:$size_bytes} +
      (if $role == "" then {} else {role:$role} end)
    '
}

for target in x86_64-unknown-linux-musl armv7-unknown-linux-musleabihf aarch64-unknown-linux-musl; do
  case "$target" in
    x86_64-unknown-linux-musl) arch=x86_64 ;;
    armv7-unknown-linux-musleabihf) arch=armv7 ;;
    aarch64-unknown-linux-musl) arch=aarch64 ;;
  esac
  base="candy-core-$version-$target"
  stage="$temporary/stage-$target"
  mkdir "$stage"
  printf '#!/bin/sh\nprintf "fixture core\\n"\n' > "$stage/candy-core"
  chmod 0755 "$stage/candy-core"
  binary_sha=$(sha256sum "$stage/candy-core" | awk '{print $1}')
  jq -n --arg version "$version" --arg target "$target" --arg arch "$arch" --arg sha "$binary_sha" '{
    schema_version:1,
    process_api_version:1,
    core:{schema_version:1,core_api_version:1,process_api_version:1,core_version:$version,target_arch:$arch,target_os:"linux",roles:["client","server"],protocol_version:{major:0,minor:3},features:[]},
    artifact:{target:$target,target_os:"linux",target_arch:$arch,libc:"musl",executable:"candy-core",executable_sha256:$sha}
  }' > "$stage/manifest.json"
  printf '%s\n' UNSIGNED-LOCAL-BUILD > "$stage/manifest.sig"
  cp "$stage/manifest.json" "$candidate/$base.manifest.json"
  tar -czf "$candidate/$base.tar.gz" -C "$stage" candy-core manifest.json manifest.sig
  printf '%s  %s\n' "$(sha256sum "$candidate/$base.tar.gz" | awk '{print $1}')" "$base.tar.gz" > "$candidate/$base.tar.gz.sha256"
  bundle=$(record "$candidate/$base.tar.gz" core-bundle "$target")
  checksum=$(record "$candidate/$base.tar.gz.sha256" bundle-checksum "$target")
  manifest=$(record "$candidate/$base.manifest.json" core-manifest "$target")
  jq -nc --arg target "$target" --arg arch "$arch" --argjson bundle "$bundle" --argjson checksum "$checksum" --argjson manifest "$manifest" \
    '{rust_target:$target,os:"linux",architecture:$arch,libc:"musl",artifacts:[$bundle,$checksum,$manifest]}' >> "$temporary/targets.jsonl"
done

for target in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
  case "$target" in
    x86_64-unknown-linux-gnu) arch=x86_64 ;;
    aarch64-unknown-linux-gnu) arch=aarch64 ;;
  esac
  base="candy-core-$version-cloud-abi-$target"
  stage="$temporary/stage-cloud-$target"
  mkdir "$stage"
  printf '%s\n' 'fixture cloud module' > "$stage/libcandy_core_cloud.so"
  chmod 0555 "$stage/libcandy_core_cloud.so"
  module_sha=$(sha256sum "$stage/libcandy_core_cloud.so" | awk '{print $1}')
  module_size=$(wc -c < "$stage/libcandy_core_cloud.so" | tr -d ' ')
  jq -n --arg version "$version" --arg commit "$commit" --arg target "$target" --arg arch "$arch" \
    --arg sha "$module_sha" --argjson size "$module_size" '{
      schema_version:1,release_kind:"candy-core",source:{repository:"reTsubasa/candy-core",commit:$commit},
      module:{version:$version,abi_version:1,library:"libcandy_core_cloud.so",wire_protocol:"0.3",build_request_schema:"candy-core-cloud-build-v1"},
      artifact:{kind:"shared-library",name:"libcandy_core_cloud.so",sha256:$sha,size_bytes:$size,target:$target,target_os:"linux",target_arch:$arch,libc:"glibc"}
    }' > "$stage/manifest.json"
  printf '%s\n' UNSIGNED-LOCAL-BUILD > "$stage/manifest.sig"
  cp "$stage/manifest.json" "$candidate/$base.manifest.json"
  tar -czf "$candidate/$base.tar.gz" -C "$stage" libcandy_core_cloud.so manifest.json manifest.sig
  printf '%s  %s\n' "$(sha256sum "$candidate/$base.tar.gz" | awk '{print $1}')" "$base.tar.gz" > "$candidate/$base.tar.gz.sha256"
  bundle=$(record "$candidate/$base.tar.gz" cloud-abi-bundle "$target" cloud-abi)
  checksum=$(record "$candidate/$base.tar.gz.sha256" bundle-checksum "$target" cloud-abi)
  manifest=$(record "$candidate/$base.manifest.json" cloud-abi-manifest "$target" cloud-abi)
  jq -nc --arg target "$target" --arg arch "$arch" --argjson bundle "$bundle" --argjson checksum "$checksum" --argjson manifest "$manifest" \
    '{rust_target:$target,os:"linux",architecture:$arch,libc:"glibc",role:"cloud-abi",artifacts:[$bundle,$checksum,$manifest]}' >> "$temporary/cloud.jsonl"
done

jq -n --arg commit "$commit" --arg version "$version" \
  --slurpfile targets "$temporary/targets.jsonl" --slurpfile cloud "$temporary/cloud.jsonl" '{
    schema_version:3,release_kind:"candy-core-unsigned-candidate",
    source:{repository:"reTsubasa/candy-core",commit:$commit},core:{version:$version},
    targets:$targets,cloud_abi:$cloud,
    artifacts:([$targets[].artifacts[]] + [$cloud[].artifacts[]]),unsigned:true
  }' > "$candidate/core-candidate-metadata.json"

PATH="$temporary/bin:$PATH" "$signer" "candidate-core-v$version-${commit:0:12}" \
  "$candidate" "$output" "$temporary/core-release.sec" "$temporary/core-release.pub" >/dev/null
[[ "$(find "$output" -maxdepth 1 -type f | wc -l | tr -d ' ')" == 17 ]]
jq -e --arg version "$version" --arg commit "$commit" '
  .schema_version == 2 and .release_tag == "core-v" + $version and
  .source.commit == $commit and (.targets | length) == 3 and (.artifacts | length) == 9 and
  .signature.verified == true
' "$output/core-release-metadata.json" >/dev/null
jq -e '(.targets | length) == 2 and (.artifacts | length) == 6 and .signature.verified == true' \
  "$output/core-cloud-abi-release-metadata.json" >/dev/null
extract="$temporary/signed"
mkdir "$extract"
tar -xzf "$output/candy-core-$version-x86_64-unknown-linux-musl.tar.gz" -C "$extract"
grep -Fq 'fixture-signature:' "$extract/manifest.sig"

expect_rejected() {
  local label=$1
  shift
  if "$@" >"$temporary/$label.out" 2>&1; then
    printf '%s\n' "invalid Core candidate was accepted: $label" >&2
    exit 1
  fi
}

expect_rejected wrong-tag env PATH="$temporary/bin:$PATH" "$signer" \
  "candidate-core-v$version-ffffffffffff" "$candidate" "$temporary/wrong-tag" \
  "$temporary/core-release.sec" "$temporary/core-release.pub"
printf '%s\n' extra > "$candidate/unexpected"
expect_rejected extra-asset env PATH="$temporary/bin:$PATH" "$signer" \
  "candidate-core-v$version-${commit:0:12}" "$candidate" "$temporary/extra" \
  "$temporary/core-release.sec" "$temporary/core-release.pub"
rm "$candidate/unexpected"
printf '%s\n' tampered >> "$candidate/candy-core-$version-x86_64-unknown-linux-musl.manifest.json"
expect_rejected tampered env PATH="$temporary/bin:$PATH" "$signer" \
  "candidate-core-v$version-${commit:0:12}" "$candidate" "$temporary/tampered" \
  "$temporary/core-release.sec" "$temporary/core-release.pub"

printf '%s\n' 'Core candidate signer tests passed'
