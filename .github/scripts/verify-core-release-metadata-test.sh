#!/bin/sh

set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
verifier=$root/.github/scripts/verify-core-release-metadata.sh
temporary=$(mktemp -d "${TMPDIR:-/tmp}/candy-core-metadata.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

jq -n '{
  schema_version: 2,
  core: {
    version: "0.3.14",
    core_api_version: 1,
    process_api_version: 1,
    protocol_version: "0.3"
  }
}' > "$temporary/metadata.json"

jq -n '{
  schema_version: 1,
  process_api_version: 1,
  core: {
    core_version: "0.3.14",
    core_api_version: 1,
    process_api_version: 1,
    protocol_version: {major: 0, minor: 3}
  }
}' > "$temporary/manifest.json"

"$verifier" 0.3.14 "$temporary/metadata.json" "$temporary/manifest.json"

expect_rejected() {
  label=$1
  shift
  if "$@" >"$temporary/rejected.out" 2>&1; then
    printf 'invalid Core release metadata was accepted: %s\n' "$label" >&2
    exit 1
  fi
}

jq '.core.version as $version | del(.core.version) | .core.core_version = $version' \
  "$temporary/metadata.json" > "$temporary/legacy-field.json"
expect_rejected legacy-version-field \
  "$verifier" 0.3.14 "$temporary/legacy-field.json" "$temporary/manifest.json"

jq '.core.protocol_version = "0.4"' \
  "$temporary/metadata.json" > "$temporary/wrong-protocol.json"
expect_rejected wrong-protocol \
  "$verifier" 0.3.14 "$temporary/wrong-protocol.json" "$temporary/manifest.json"

jq '.core.process_api_version = 2' \
  "$temporary/metadata.json" > "$temporary/wrong-process-api.json"
expect_rejected wrong-process-api \
  "$verifier" 0.3.14 "$temporary/wrong-process-api.json" "$temporary/manifest.json"

printf '%s\n' 'Core release metadata verifier tests passed'
