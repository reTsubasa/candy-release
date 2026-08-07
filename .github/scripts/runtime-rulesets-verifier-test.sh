#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
verifier=$root/.github/scripts/verify-runtime-rulesets.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/candy-release-rulesets-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
	printf '%s\n' "runtime-rulesets-verifier-test: $*" >&2
	exit 1
}

write_fixture() {
	directory=$1
	mkdir -p "$directory"
	printf '%s\n' '1.0.1.0/24' '2409:8000::/20' > "$directory/cn-ip.cidr"
	printf '%s\n' 'blocked.example' 'foreign.example' > "$directory/gfwlist.domains"
	printf '%s\n' 'reviewed fixture' > "$directory/PROVENANCE.md"
	cidr_sha=$(sha256sum "$directory/cn-ip.cidr" | awk '{print $1}')
	domain_sha=$(sha256sum "$directory/gfwlist.domains" | awk '{print $1}')
	printf '%s  %s\n' "$cidr_sha" cn-ip.cidr "$domain_sha" gfwlist.domains > "$directory/SHA256SUMS"
	jq -n \
		--arg cidr_sha "$cidr_sha" \
		--arg domain_sha "$domain_sha" \
		'{
			schema_version: 1,
			generated_at: "2026-08-07",
			providers: {
				cn_ip: {
					source_url: "https://example.test/cn-ip.cidr",
					source_sha256: $cidr_sha,
					installed_sha256: $cidr_sha,
					entries: {total: 2, ipv4: 1, ipv6: 1}
				},
				gfwlist: {
					source_url: "https://example.test/gfwlist.txt",
					source_sha256: $domain_sha,
					installed_sha256: $domain_sha,
					entries: {total: 2}
				}
			}
		}' > "$directory/manifest.json"
}

valid=$tmp/valid
write_fixture "$valid"
"$verifier" "$valid" >/dev/null || fail "valid manifest-bound fixture was rejected"

tampered=$tmp/tampered
cp -R "$valid" "$tampered"
printf '%s\n' 'replacement.example' >> "$tampered/gfwlist.domains"
if "$verifier" "$tampered" >/dev/null 2>&1; then
	fail "tampered provider passed digest validation"
fi

wrong_count=$tmp/wrong-count
cp -R "$valid" "$wrong_count"
jq '.providers.cn_ip.entries.total = 3' "$wrong_count/manifest.json" > "$wrong_count/manifest.next"
mv "$wrong_count/manifest.next" "$wrong_count/manifest.json"
if "$verifier" "$wrong_count" >/dev/null 2>&1; then
	fail "manifest count mismatch was accepted"
fi

missing_manifest=$tmp/missing-manifest
cp -R "$valid" "$missing_manifest"
rm "$missing_manifest/manifest.json"
if "$verifier" "$missing_manifest" >/dev/null 2>&1; then
	fail "missing manifest was accepted"
fi

malformed_cidr=$tmp/malformed-cidr
cp -R "$valid" "$malformed_cidr"
printf '%s\n' '1.0.1.0/24' '2409:::1/20' > "$malformed_cidr/cn-ip.cidr"
cidr_sha=$(sha256sum "$malformed_cidr/cn-ip.cidr" | awk '{print $1}')
jq --arg sha "$cidr_sha" '.providers.cn_ip.installed_sha256 = $sha' \
	"$malformed_cidr/manifest.json" > "$malformed_cidr/manifest.next"
mv "$malformed_cidr/manifest.next" "$malformed_cidr/manifest.json"
domain_sha=$(sha256sum "$malformed_cidr/gfwlist.domains" | awk '{print $1}')
printf '%s  %s\n' "$cidr_sha" cn-ip.cidr "$domain_sha" gfwlist.domains > "$malformed_cidr/SHA256SUMS"
if "$verifier" "$malformed_cidr" >/dev/null 2>&1; then
	fail "semantically invalid IPv6 CIDR was accepted"
fi

printf '%s\n' "Runtime ruleset verifier tests passed"
