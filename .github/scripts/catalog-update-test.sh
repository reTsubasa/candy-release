#!/bin/sh

set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
updater=$root/.github/scripts/catalog-update.sh
temporary=$(mktemp -d "${TMPDIR:-/tmp}/candy-catalog-update.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

cat > "$temporary/catalog.json" <<'EOF'
{
  "schema_version": 1,
  "sequence": 29,
  "channel": "stable",
  "published_at": "2026-08-11T08:23:38Z",
  "runtime": {"latest":"v0_4_0_r23","releases":{}},
  "core": {"latest":"v0_3_9","releases":{"v0_3_9":{"version":"0.3.9"}}},
  "core_modules": {
    "latest": "v0_3_10",
    "releases": {
      "v0_3_10": {
        "version":"0.3.10",
        "targets":{"linux_glibc_x86_64":{"url":"https://example.invalid/legacy-module"}}
      }
    }
  }
}
EOF

legacy_modules=$(jq -cS .core_modules.releases "$temporary/catalog.json")

printf '%s\n' '{"version":"0.3.9","targets":{}}' > "$temporary/entry.json"
"$updater" "$temporary/catalog.json" "$temporary/entry.json" core v0_3_9 \
	2026-08-12T00:00:00Z "$temporary/legacy-next.json"
jq -e '
  .sequence == 30 and .core.latest == "v0_3_9" and
  .core_modules.latest == "v0_3_10"
' "$temporary/legacy-next.json" >/dev/null
[ "$(jq -cS .core_modules.releases "$temporary/legacy-next.json")" = "$legacy_modules" ]

cat > "$temporary/entry.json" <<'EOF'
{
  "version":"0.3.10",
  "targets":{"linux_musl_x86_64":{"url":"https://example.invalid/data-plane"}},
  "abi_profiles": {
    "cloud_control_linux_glibc_x86_64":{"artifact_kind":"shared-library","url":"https://example.invalid/canonical-module"}
  }
}
EOF
"$updater" "$temporary/catalog.json" "$temporary/entry.json" core v0_3_10 \
	2026-08-12T00:00:01Z "$temporary/unified-next.json"
jq -e '
  .sequence == 30 and .core.latest == "v0_3_10" and
  .core.releases.v0_3_10.abi_profiles.cloud_control_linux_glibc_x86_64.artifact_kind == "shared-library" and
  .core_modules.latest == null
' "$temporary/unified-next.json" >/dev/null
[ "$(jq -cS .core_modules.releases "$temporary/unified-next.json")" = "$legacy_modules" ]

printf '%s\n' '{"version":"0.4.1","display_version":"0.4.1-r1"}' > "$temporary/entry.json"
"$updater" "$temporary/catalog.json" "$temporary/entry.json" runtime v0_4_1_r1 \
	2026-08-12T00:00:02Z "$temporary/runtime-next.json"
jq -e '.runtime.latest == "v0_4_1_r1" and .core_modules.latest == "v0_3_10"' \
	"$temporary/runtime-next.json" >/dev/null
[ "$(jq -cS .core_modules.releases "$temporary/runtime-next.json")" = "$legacy_modules" ]

if "$updater" "$temporary/catalog.json" "$temporary/entry.json" core_modules v0_4_1 \
	2026-08-12T00:00:03Z "$temporary/rejected.json" >/dev/null 2>&1; then
	printf '%s\n' 'legacy core_modules family accepted a new publication' >&2
	exit 1
fi

printf '%s\n' 'catalog update tests passed'
