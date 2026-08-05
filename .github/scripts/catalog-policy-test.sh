#!/bin/sh

set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
policy=$root/.github/scripts/catalog-policy.sh
temporary=$(mktemp -d "${TMPDIR:-/tmp}/candy-catalog-policy.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

cat > "$temporary/catalog.json" <<'EOF'
{
  "schema_version": 1,
  "sequence": 4,
  "channel": "stable",
  "runtime": {
    "latest": "v0_4_0_r2",
    "releases": {
      "v0_3_2_r7": {"version":"0.3.2","revision":7,"display_version":"0.3.2-r7","release_assets":[{"name":"BUILD-INFO","sha256":"historical","size":10}]},
      "v0_4_0_r2": {"version":"0.4.0","revision":2,"display_version":"0.4.0-r2","release_assets":[{"name":"BUILD-INFO","sha256":"latest","size":10}]}
    }
  },
  "core": {
    "latest": "v0_3_4",
    "releases": {
      "v0_3_2": {"version":"0.3.2","release_assets":[{"name":"core-release-metadata.json","sha256":"historical","size":10}]},
      "v0_3_4": {"version":"0.3.4","release_assets":[{"name":"core-release-metadata.json","sha256":"latest","size":10}]}
    }
  }
}
EOF

assert_output() {
	expected=$1
	shift
	actual=$($policy "$temporary/catalog.json" "$temporary/entry.json" "$@")
	[ "$actual" = "$expected" ] || {
		printf 'expected %s, got %s\n' "$expected" "$actual" >&2
		exit 1
	}
}

assert_rejected() {
	if $policy "$temporary/catalog.json" "$temporary/entry.json" "$@" >/dev/null 2>&1; then
		printf 'expected rejection for %s/%s\n' "$1" "$2" >&2
		exit 1
	fi
}

printf '%s\n' '{"version":"0.3.2","revision":7,"display_version":"0.3.2-r7","release_assets":[{"name":"BUILD-INFO","sha256":"historical","size":10}]}' > "$temporary/entry.json"
assert_output unchanged runtime v0_3_2_r7 0.3.2-r7

printf '%s\n' '{"version":"0.3.2","revision":7,"display_version":"0.3.2-r7","release_assets":[{"name":"BUILD-INFO","sha256":"changed","size":10}]}' > "$temporary/entry.json"
assert_rejected runtime v0_3_2_r7 0.3.2-r7

printf '%s\n' '{"version":"0.4.0","revision":2,"display_version":"0.4.0-r2","release_assets":[{"name":"BUILD-INFO","sha256":"changed","size":10}]}' > "$temporary/entry.json"
assert_output replace-latest runtime v0_4_0_r2 0.4.0-r2

printf '%s\n' '{"version":"0.4.0","revision":2,"display_version":"0.4.0-r2","release_assets":[{"name":"BUILD-INFO","sha256":"latest","size":10}]}' > "$temporary/entry.json"
assert_output unchanged runtime v0_4_0_r2 0.4.0-r2

printf '%s\n' '{"version":"0.4.1","revision":1,"display_version":"0.4.1-r1","sha256":"new"}' > "$temporary/entry.json"
assert_output new runtime v0_4_1_r1 0.4.1-r1

printf '%s\n' '{"version":"0.3.9","revision":9,"display_version":"0.3.9-r9","sha256":"old"}' > "$temporary/entry.json"
assert_rejected runtime v0_3_9_r9 0.3.9-r9

printf '%s\n' '{"version":"0.3.2","release_assets":[{"name":"core-release-metadata.json","sha256":"changed","size":10}]}' > "$temporary/entry.json"
assert_rejected core v0_3_2 0.3.2

printf '%s\n' '{"version":"0.3.4","release_assets":[{"name":"core-release-metadata.json","sha256":"changed","size":10}]}' > "$temporary/entry.json"
assert_output replace-latest core v0_3_4 0.3.4

printf '%s\n' '{"version":"0.3.5","sha256":"new"}' > "$temporary/entry.json"
assert_output new core v0_3_5 0.3.5

printf '%s\n' 'catalog policy tests passed'
