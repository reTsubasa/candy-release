#!/bin/sh

set -eu

fail() {
	printf '%s\n' "catalog-update: $*" >&2
	exit 1
}

[ "$#" -eq 6 ] || fail "usage: $0 CATALOG ENTRY KIND KEY PUBLISHED_AT OUTPUT"

catalog=$1
entry=$2
kind=$3
release_key=$4
published_at=$5
output=$6

case "$kind" in
	runtime|core) ;;
	*) fail "unsupported release kind: $kind" ;;
esac

jq -e '.schema_version == 1 and .channel == "stable" and (.sequence | type == "number")' "$catalog" >/dev/null \
	|| fail "invalid stable catalog"
jq -e . "$entry" >/dev/null || fail "invalid release entry"

jq \
	--arg kind "$kind" \
	--arg key "$release_key" \
	--arg published_at "$published_at" \
	--slurpfile entry "$entry" '
  .sequence += 1 |
  .published_at = $published_at |
  .[$kind].releases[$key] = $entry[0] |
  .[$kind].latest = $key |
  if $kind == "core" and ($entry[0].artifact_roles.cloud_abi? != null) then
    .core_modules = ((.core_modules // {latest:null,releases:{}}) | .latest = null)
  else
    .
  end
' "$catalog" > "$output"

jq -e . "$output" >/dev/null || fail "updated catalog is invalid"
