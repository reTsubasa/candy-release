#!/bin/sh

set -eu

version=${1:?Core version is required}
metadata=${2:?Core release metadata is required}
manifest=${3:?Signed Core manifest is required}

process_api=$(jq -er '.process_api_version' "$manifest")
core_api=$(jq -er '.core.core_api_version' "$manifest")
protocol=$(jq -er '.core.protocol_version | "\(.major).\(.minor)"' "$manifest")

jq -e --arg version "$version" \
  --argjson process_api "$process_api" \
  --argjson core_api "$core_api" \
  --arg protocol "$protocol" '
    .core.version == $version and
    .core.process_api_version == $process_api and
    .core.core_api_version == $core_api and
    .core.protocol_version == $protocol
  ' "$metadata" >/dev/null
