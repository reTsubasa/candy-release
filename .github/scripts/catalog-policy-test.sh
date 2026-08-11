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
  },
  "core_modules": {
    "latest": "v0_3_10",
    "releases": {
      "v0_3_10": {"version":"0.3.10","release_assets":[{"name":"core-cloud-module-release-metadata.json","sha256":"latest","size":10}]}
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

printf '%s\n' '{"version":"0.3.10","release_assets":[{"name":"core-cloud-module-release-metadata.json","sha256":"latest","size":10}]}' > "$temporary/entry.json"
assert_output unchanged core_modules v0_3_10 0.3.10

printf '%s\n' '{"version":"0.3.10","release_assets":[{"name":"core-cloud-module-release-metadata.json","sha256":"changed","size":10}]}' > "$temporary/entry.json"
assert_output replace-latest core_modules v0_3_10 0.3.10

printf '%s\n' '{"version":"0.3.11","sha256":"new"}' > "$temporary/entry.json"
assert_output new core_modules v0_3_11 0.3.11

printf '%s\n' '{"version":"0.3.9","sha256":"old"}' > "$temporary/entry.json"
assert_rejected core_modules v0_3_9 0.3.9

workflow=$root/.github/workflows/finalize-release.yml
assert_workflow_contains() {
	grep -F "$1" "$workflow" >/dev/null || {
		printf 'workflow is missing required transaction guard: %s\n' "$1" >&2
		exit 1
	}
}
assert_workflow_before() {
	first=$(grep -nF "$1" "$workflow" | head -1 | cut -d: -f1 || true)
	second=$(grep -nF "$2" "$workflow" | head -1 | cut -d: -f1 || true)
	[ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ] || {
		printf 'workflow transaction order is invalid: %s must precede %s\n' "$1" "$2" >&2
		exit 1
	}
}
assert_workflow_contains 'catalog_commit=$(git rev-parse HEAD)'
assert_workflow_contains 'tag_ref="refs/tags/$RELEASE_TAG"'
assert_workflow_contains 'push_release_tag()'
assert_workflow_contains 'push_catalog_commit()'
assert_workflow_contains 'observed=$(remote_ref_commit refs/heads/main)'
assert_workflow_contains 'test "$observed" = "$catalog_commit"'
assert_workflow_contains 'gh release create "$RELEASE_TAG" --verify-tag'
assert_workflow_contains 'git push --force origin "$commit:$tag_ref"'
assert_workflow_contains 'git push --force origin "$remote_tag_object:$tag_ref"'
assert_workflow_contains 'git push origin ":$tag_ref"'
assert_workflow_contains 'tag exists without a formal Release; refusing to reuse it'
assert_workflow_contains 'uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6'
assert_workflow_contains 'verify_core_bundle()'
assert_workflow_contains 'Core executable SHA-256 mismatch'
assert_workflow_contains 'test -x "$extract_dir/candy-core"'
assert_workflow_contains '($protocol.major | floor) == $protocol.major'
assert_workflow_contains '.artifact.target_arch == $arch'
assert_workflow_contains 'Core release metadata disagrees with signed manifests'
assert_workflow_contains 'verify-core-cloud-module.sh'
assert_workflow_contains 'core-cloud-module-release-metadata.json'
assert_workflow_contains 'artifact_kind:"shared-module"'
assert_workflow_contains 'echo "catalog_kind=core_modules"'
assert_workflow_contains 'Core Cloud module metadata disagrees with signed manifest'
assert_workflow_contains 'catalog_before_commit=$(git rev-parse HEAD)'
assert_workflow_contains 'catalog_pushed=0'
assert_workflow_contains 'rollback verification failed; manual reconciliation required'
assert_workflow_contains 'rollback_catalog=$(remote_ref_commit refs/heads/main)'
assert_workflow_contains 'rollback_tag_object=$(remote_ref_commit "$tag_ref")'
assert_workflow_contains 'rollback_tag_commit=$(remote_ref_commit "$tag_ref^{}")'
assert_workflow_contains 'test "$rollback_tag_object" = "$remote_tag_object"'
assert_workflow_contains 'cmp -s rollback-assets.json published-assets.json'
assert_workflow_contains 'release_is_absent()'
assert_workflow_contains 'test "$status" = 404'
assert_workflow_before 'push_release_tag "$catalog_commit"' 'gh release create "$RELEASE_TAG" --verify-tag'
assert_workflow_before 'gh release edit "$RELEASE_TAG" --draft=false' 'push_release_tag "$catalog_commit" 1'
assert_workflow_before 'push_release_tag "$catalog_commit" 1' 'if push_catalog_commit; then'

printf '%s\n' 'catalog policy tests passed'
