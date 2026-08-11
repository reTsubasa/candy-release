#!/bin/sh

set -eu
export LC_ALL=C

fail() {
	printf '%s\n' "verify-core-cloud-abi: $*" >&2
	exit 1
}

file_sha() {
	sha256sum "$1" | awk '{ print tolower($1) }'
}

file_size() {
	wc -c < "$1" | tr -d ' '
}

[ "$#" -eq 7 ] || fail "usage: $0 VERSION TARGET BUNDLE CHECKSUM MANIFEST PUBLIC_KEY EXTRACT_ROOT"

version=$1
target=$2
bundle=$3
checksum=$4
manifest=$5
public_key=$6
extract_root=$7

for command in jq sha256sum tar usign readelf; do
	command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
done

case "$target" in
	x86_64-unknown-linux-gnu) expected_arch=x86_64 ;;
	*) fail "unsupported Cloud ABI target: $target" ;;
esac

for path in "$bundle" "$checksum" "$manifest" "$public_key"; do
	[ -f "$path" ] && [ ! -L "$path" ] && [ -s "$path" ] || fail "invalid input file: $path"
done

if ! awk 'NF { count += 1; if (NF != 2) invalid = 1 } END { exit (count == 1 && !invalid) ? 0 : 1 }' "$checksum"; then
	fail "invalid bundle checksum format: $checksum"
fi
checksum_sha=$(awk 'NR == 1 { print tolower($1) }' "$checksum")
checksum_name=$(awk 'NR == 1 { print $2 }' "$checksum")
printf '%s' "$checksum_sha" | grep -Eq '^[0-9a-f]{64}$' || fail "invalid bundle checksum digest"
[ "$checksum_name" = "$(basename "$bundle")" ] || fail "checksum names the wrong bundle"
[ "$(file_sha "$bundle")" = "$checksum_sha" ] || fail "bundle checksum mismatch"

listing=$(tar -tzf "$bundle") || fail "cannot list bundle"
[ "$listing" = 'libcandy_core_cloud.so
manifest.json
manifest.sig' ] || fail "bundle must contain only libcandy_core_cloud.so, manifest.json, and manifest.sig"

extract_dir=$extract_root/$target
rm -rf "$extract_dir"
mkdir -p "$extract_dir"
chmod 0700 "$extract_dir"
tar -xzf "$bundle" -C "$extract_dir" --no-same-owner --no-same-permissions || fail "cannot extract bundle"

for name in libcandy_core_cloud.so manifest.json manifest.sig; do
	path=$extract_dir/$name
	[ -f "$path" ] && [ ! -L "$path" ] && [ -s "$path" ] || fail "invalid bundled artifact: $name"
done

library=$extract_dir/libcandy_core_cloud.so
inner_manifest=$extract_dir/manifest.json
inner_signature=$extract_dir/manifest.sig
[ "$(file_size "$library")" -le 134217728 ] || fail "shared module is too large"
[ "$(file_size "$inner_manifest")" -le 1048576 ] || fail "manifest is too large"
[ "$(file_size "$inner_signature")" -le 65536 ] || fail "manifest signature is too large"
cmp "$manifest" "$inner_manifest" >/dev/null || fail "detached and bundled manifests differ"
! grep -Fq 'UNSIGNED-LOCAL-BUILD' "$inner_signature" || fail "unsigned local bundle is not publishable"
[ "$(usign -F -p "$public_key")" = d78de22abfca5b57 ] || fail "unexpected Core release public key"
usign -V -p "$public_key" -m "$inner_manifest" -x "$inner_signature" >/dev/null 2>&1 ||
	fail "manifest signature is invalid"

jq -e \
	--arg version "$version" \
	--arg target "$target" \
	--arg arch "$expected_arch" '
  (keys | sort) == ["artifact","module","release_kind","schema_version","source"] and
  .schema_version == 1 and
  .release_kind == "candy-core" and
  (.source | keys | sort) == ["commit","repository"] and
  .source.repository == "reTsubasa/candy-core" and
  (.source.commit | type == "string" and test("^[0-9a-f]{40,64}$")) and
  (.module | keys | sort) == ["abi_version","build_request_schema","library","version","wire_protocol"] and
  .module.version == $version and
  .module.abi_version == 1 and
  .module.library == "libcandy_core_cloud.so" and
  .module.wire_protocol == "0.3" and
  .module.build_request_schema == "candy-core-cloud-build-v1" and
  (.artifact | keys | sort) == ["kind","libc","name","sha256","size_bytes","target","target_arch","target_os"] and
  .artifact.kind == "shared-library" and
  .artifact.name == "libcandy_core_cloud.so" and
  (.artifact.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.artifact.size_bytes | type == "number" and floor == . and . > 0) and
  .artifact.target == $target and
  .artifact.target_os == "linux" and
  .artifact.target_arch == $arch and
  .artifact.libc == "glibc"
' "$inner_manifest" >/dev/null || fail "manifest contract mismatch"

[ "$(file_sha "$library")" = "$(jq -er '.artifact.sha256' "$inner_manifest")" ] || fail "shared module SHA-256 mismatch"
[ "$(file_size "$library")" = "$(jq -er '.artifact.size_bytes' "$inner_manifest")" ] || fail "shared module size mismatch"
[ -x "$library" ] || fail "shared module mode is not executable"

elf_header=$(readelf -h "$library") || fail "cannot inspect ELF header"
printf '%s\n' "$elf_header" | grep -Fq 'Class:                             ELF64' || fail "shared module is not ELF64"
printf '%s\n' "$elf_header" | grep -Fq "Data:                              2's complement, little endian" || fail "shared module byte order is invalid"
printf '%s\n' "$elf_header" | grep -Fq 'Type:                              DYN (Shared object file)' || fail "artifact is not an ELF shared object"
printf '%s\n' "$elf_header" | grep -Fq 'Machine:                           Advanced Micro Devices X86-64' || fail "shared module architecture mismatch"

dynamic=$(readelf -d "$library") || fail "cannot inspect ELF dynamic section"
! printf '%s\n' "$dynamic" | grep -Eq '\((RPATH|RUNPATH)\)' || fail "shared module must not contain RPATH or RUNPATH"
needed=$(printf '%s\n' "$dynamic" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | sort)
expected_needed=$(printf '%s\n' ld-linux-x86-64.so.2 libc.so.6 libgcc_s.so.1 | sort)
[ "$needed" = "$expected_needed" ] || fail "shared module dependency allowlist mismatch"

exports=$(readelf --dyn-syms --wide "$library" |
	awk '$5 == "GLOBAL" && $7 != "UND" { print $8 }' | sort -u)
expected_exports=$(printf '%s\n' \
	candy_core_cloud_abi_version \
	candy_core_cloud_assemble \
	candy_core_cloud_canonicalize \
	candy_core_cloud_capabilities \
	candy_core_cloud_prepare \
	candy_core_cloud_route_content_hash \
	candy_core_cloud_validate | sort)
[ "$exports" = "$expected_exports" ] || fail "shared module ABI export allowlist mismatch"

printf '%s\n' "verified Candy Core Cloud ABI $version for $target"
