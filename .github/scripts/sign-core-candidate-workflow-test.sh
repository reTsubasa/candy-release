#!/bin/sh

set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
workflow=$root/.github/workflows/sign-core-candidate.yml

contains() {
  grep -F "$1" "$workflow" >/dev/null || {
    printf '%s\n' "sign-core-candidate workflow is missing: $1" >&2
    exit 1
  }
}

contains 'types: [candy-core-candidate-ready]'
contains 'CANDY_CORE_SIGNING_KEY: ${{ secrets.CANDY_CORE_SIGNING_KEY }}'
contains 'sign-core-candidate.sh'
contains 'incoming-core-v$version'
contains 'candy-artifact-ready'
contains 'keys/core-release.pub'
contains 'umask 077'
contains 'printf '\''%s\n'\'' "$CANDY_CORE_SIGNING_KEY"'
secret_line=$(grep -nF 'CANDY_CORE_SIGNING_KEY: ${{ secrets.CANDY_CORE_SIGNING_KEY }}' "$workflow" | cut -d: -f1)
sign_step_line=$(grep -nF -- '- name: Download and sign unsigned candidate' "$workflow" | cut -d: -f1)
[ "$secret_line" -gt "$sign_step_line" ] || {
  printf '%s\n' 'Core signing secret is not scoped to the signing step' >&2
  exit 1
}
if grep -Eq '(echo|cat|gh).*\$CANDY_CORE_SIGNING_KEY' "$workflow"; then
  printf '%s\n' 'signing workflow exposes the Core signing secret' >&2
  exit 1
fi

printf '%s\n' 'Core candidate signing workflow tests passed'
