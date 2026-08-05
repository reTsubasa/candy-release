#!/bin/sh

set -eu

fail() {
	printf '%s\n' "catalog-policy: $*" >&2
	exit 1
}

version_gt() {
	awk -v left="$1" -v right="$2" '
		BEGIN {
			gsub(/-r/, ".", left)
			gsub(/-r/, ".", right)
			if (left !~ /^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$/ ||
			    right !~ /^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$/) exit 2
			left_count = split(left, left_parts, ".")
			right_count = split(right, right_parts, ".")
			count = left_count > right_count ? left_count : right_count
			for (part = 1; part <= count; part++) {
				left_value = left_parts[part] + 0
				right_value = right_parts[part] + 0
				if (left_value > right_value) exit 0
				if (left_value < right_value) exit 1
			}
			exit 1
	}'
}

[ "$#" -eq 5 ] || fail "usage: $0 CATALOG ENTRY KIND KEY VERSION"

catalog=$1
entry=$2
kind=$3
release_key=$4
release_version=$5

case "$kind" in
	runtime|core) ;;
	*) fail "unsupported release kind: $kind" ;;
esac

jq -e '.schema_version == 1 and .channel == "stable"' "$catalog" >/dev/null \
	|| fail "invalid stable catalog"
jq -e . "$entry" >/dev/null || fail "invalid release entry"

current=$(jq -cS --arg kind "$kind" --arg key "$release_key" \
	'.[$kind].releases[$key] // null' "$catalog")
desired=$(jq -cS . "$entry")
latest_key=$(jq -r --arg kind "$kind" '.[$kind].latest // empty' "$catalog")

if [ "$current" = null ]; then
	if [ -n "$latest_key" ]; then
		if [ "$kind" = runtime ]; then
			latest_version=$(jq -er --arg key "$latest_key" \
				'.runtime.releases[$key].display_version' "$catalog")
		else
			latest_version=$(jq -er --arg key "$latest_key" \
				'.core.releases[$key].version' "$catalog")
		fi
		version_gt "$release_version" "$latest_version" \
			|| fail "release would move stable backward"
	fi
	printf '%s\n' new
elif [ "$current" = "$desired" ]; then
	printf '%s\n' unchanged
elif [ "$latest_key" = "$release_key" ]; then
	printf '%s\n' replace-latest
else
	fail "non-latest catalog entry $kind/$release_key is immutable"
fi
