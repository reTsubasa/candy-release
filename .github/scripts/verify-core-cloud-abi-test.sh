#!/bin/sh

set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
verifier=$root/.github/scripts/verify-core-cloud-abi.sh
temporary=$(mktemp -d "${TMPDIR:-/tmp}/candy-core-cloud-abi.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

mkdir -p "$temporary/bin" "$temporary/stage" "$temporary/extract"
printf '%s\n' module-payload > "$temporary/stage/libcandy_core_cloud.so"
chmod 0555 "$temporary/stage/libcandy_core_cloud.so"
module_sha=$(sha256sum "$temporary/stage/libcandy_core_cloud.so" | awk '{print $1}')
module_size=$(wc -c < "$temporary/stage/libcandy_core_cloud.so" | tr -d ' ')

jq -n --arg sha "$module_sha" --argjson size "$module_size" '{
  schema_version:1,
  release_kind:"candy-core",
  source:{repository:"reTsubasa/candy-core",commit:"e45eb313145a4c2a46844c6293e44c98c6b81ad0"},
  module:{version:"0.3.10",abi_version:1,library:"libcandy_core_cloud.so",wire_protocol:"0.3",build_request_schema:"candy-core-cloud-build-v1"},
  artifact:{kind:"shared-library",name:"libcandy_core_cloud.so",sha256:$sha,size_bytes:$size,target:"x86_64-unknown-linux-gnu",target_os:"linux",target_arch:"x86_64",libc:"glibc"}
}' > "$temporary/stage/manifest.json"
cp "$temporary/stage/manifest.json" "$temporary/module.manifest.json"
printf '%s\n' SIGNED > "$temporary/stage/manifest.sig"
printf '%s\n' public-key > "$temporary/core-release.pub"

cat > "$temporary/bin/usign" <<'EOF'
#!/bin/sh
set -eu
if [ "$1" = -F ]; then
  printf '%s\n' d78de22abfca5b57
  exit 0
fi
signature=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -x) signature=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ "$(cat "$signature")" = SIGNED ]
EOF

cat > "$temporary/bin/readelf" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
  -h)
    cat <<OUT
  Class:                             ELF64
  Data:                              2's complement, little endian
  Type:                              DYN (Shared object file)
  Machine:                           ${FAKE_MACHINE:-Advanced Micro Devices X86-64}
OUT
    ;;
  -d)
    cat <<OUT
 0x0000000000000001 (NEEDED)             Shared library: [libgcc_s.so.1]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
${FAKE_LOADER:+ 0x0000000000000001 (NEEDED)             Shared library: [$FAKE_LOADER]}
OUT
    ;;
  --dyn-syms)
    cat <<OUT
  1: 0 0 FUNC GLOBAL DEFAULT 10 candy_core_cloud_abi_version
  2: 0 0 FUNC GLOBAL DEFAULT 10 candy_core_cloud_assemble
  3: 0 0 FUNC GLOBAL DEFAULT 10 candy_core_cloud_canonicalize
  4: 0 0 FUNC GLOBAL DEFAULT 10 candy_core_cloud_capabilities
  5: 0 0 FUNC GLOBAL DEFAULT 10 candy_core_cloud_prepare
  6: 0 0 FUNC GLOBAL DEFAULT 10 candy_core_cloud_route_content_hash
  7: 0 0 FUNC GLOBAL DEFAULT 10 candy_core_cloud_validate
${FAKE_EXTRA_EXPORT:+  8: 0 0 FUNC GLOBAL DEFAULT 10 unexpected_export}
OUT
    ;;
  *) exit 2 ;;
esac
EOF
chmod 0755 "$temporary/bin/usign" "$temporary/bin/readelf"

build_bundle() {
	tar -czf "$temporary/module.tar.gz" -C "$temporary/stage" libcandy_core_cloud.so manifest.json manifest.sig
	sha256sum "$temporary/module.tar.gz" | sed 's#  .*#  module.tar.gz#' > "$temporary/module.tar.gz.sha256"
}

verify() {
	target=${1:-x86_64-unknown-linux-gnu}
	PATH="$temporary/bin:$PATH" "$verifier" 0.3.10 "$target" \
		"$temporary/module.tar.gz" "$temporary/module.tar.gz.sha256" \
		"$temporary/module.manifest.json" "$temporary/core-release.pub" "$temporary/extract"
}

expect_rejected() {
	label=$1
	shift
	if "$@" >"$temporary/rejected.out" 2>&1; then
		printf 'invalid module was accepted: %s\n' "$label" >&2
		exit 1
	fi
}

build_bundle
FAKE_LOADER=ld-linux-x86-64.so.2
export FAKE_LOADER
verify >/dev/null

cp "$temporary/stage/manifest.json" "$temporary/x86-manifest.json"
jq '.artifact.target = "aarch64-unknown-linux-gnu" | .artifact.target_arch = "aarch64"' \
	"$temporary/x86-manifest.json" > "$temporary/stage/manifest.json"
cp "$temporary/stage/manifest.json" "$temporary/module.manifest.json"
build_bundle
unset FAKE_LOADER
FAKE_MACHINE=AArch64
export FAKE_MACHINE
verify aarch64-unknown-linux-gnu >/dev/null
unset FAKE_MACHINE
FAKE_LOADER=ld-linux-x86-64.so.2
export FAKE_LOADER
cp "$temporary/x86-manifest.json" "$temporary/stage/manifest.json"
cp "$temporary/stage/manifest.json" "$temporary/module.manifest.json"
build_bundle

printf '%s\n' extra > "$temporary/stage/extra"
tar -czf "$temporary/module.tar.gz" -C "$temporary/stage" libcandy_core_cloud.so manifest.json manifest.sig extra
sha256sum "$temporary/module.tar.gz" | sed 's#  .*#  module.tar.gz#' > "$temporary/module.tar.gz.sha256"
expect_rejected unexpected-member verify
rm "$temporary/stage/extra"

printf '%s\n' UNSIGNED-LOCAL-BUILD > "$temporary/stage/manifest.sig"
build_bundle
expect_rejected unsigned-bundle verify
printf '%s\n' SIGNED > "$temporary/stage/manifest.sig"
build_bundle

FAKE_EXTRA_EXPORT=1
export FAKE_EXTRA_EXPORT
expect_rejected unexpected-export verify
unset FAKE_EXTRA_EXPORT

jq '.artifact.kind = "executable"' "$temporary/stage/manifest.json" > "$temporary/bad-manifest.json"
mv "$temporary/bad-manifest.json" "$temporary/stage/manifest.json"
cp "$temporary/stage/manifest.json" "$temporary/module.manifest.json"
build_bundle
expect_rejected wrong-artifact-kind verify

printf '%s\n' 'Core Cloud ABI verifier tests passed'
