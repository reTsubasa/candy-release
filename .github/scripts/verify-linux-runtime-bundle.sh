#!/bin/sh
set -eu

fail() {
	printf '%s\n' "verify-linux-runtime-bundle: $*" >&2
	exit 1
}

[ "$#" -eq 3 ] || fail "usage: $0 VERSION ARCHITECTURE BUNDLE"
version=$1
architecture=$2
bundle=$3

case "$version" in
	''|*[!0-9.]*|.*|*.|*..*) fail "invalid Runtime version: $version" ;;
esac
case "$architecture" in
	x86_64) expected_machine='X86-64' ;;
	aarch64) expected_machine='AArch64' ;;
	*) fail "unsupported Linux Runtime architecture: $architecture" ;;
esac

[ -f "$bundle" ] && [ ! -L "$bundle" ] || fail "bundle is not a regular file: $bundle"
command -v readelf >/dev/null 2>&1 || fail "readelf is required"

listing=$(tar -tzf "$bundle") || fail "cannot list bundle: $bundle"
[ "$(printf '%s\n' "$listing" | wc -l | tr -d ' ')" -le 100 ] ||
	fail "bundle contains too many entries: $bundle"
if printf '%s\n' "$listing" | sed 's#^\./##' | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
	fail "bundle contains an unsafe path: $bundle"
fi

extract_root=$(mktemp -d "${TMPDIR:-/tmp}/candy-linux-runtime.XXXXXX")
trap 'rm -rf "$extract_root"' EXIT HUP INT TERM
tar -xzf "$bundle" -C "$extract_root" --no-same-owner --no-same-permissions ||
	fail "cannot extract bundle: $bundle"
if find "$extract_root" -type l -print | grep -q .; then
	fail "bundle contains a symbolic link: $bundle"
fi

for executable in \
	usr/local/bin/candy-server \
	usr/local/bin/candy-core-manager \
	usr/local/libexec/serverd-linux \
	usr/local/libexec/candy-sdwan-runtime \
	usr/local/libexec/candy-sdwan-agent \
	usr/local/libexec/candy-netd \
	usr/local/libexec/candy-cloud-enroll \
	usr/local/libexec/candy-cloud-sync \
	usr/local/libexec/candy-server-health-check \
	install/install-candy-server.sh \
	install/upgrade-candy-server.sh; do
	[ -f "$extract_root/$executable" ] && [ ! -L "$extract_root/$executable" ] && [ -x "$extract_root/$executable" ] ||
		fail "bundle is missing executable $executable: $bundle"
done

for required in \
	etc/candy/server.toml.example \
	systemd/candy-server.service \
	systemd/candy-netd.service \
	systemd/candy-cloud-sync.service \
	systemd/candy-cloud-sync.timer \
	systemd/candy.tmpfiles \
	VERSION; do
	[ -f "$extract_root/$required" ] && [ ! -L "$extract_root/$required" ] && [ -s "$extract_root/$required" ] ||
		fail "bundle is missing $required: $bundle"
done

[ ! -e "$extract_root/systemd/candy-sdwan.service" ] ||
	fail "server bundle must not contain a second SD-WAN service: $bundle"
[ "$(tr -d '\r\n' <"$extract_root/VERSION")" = "$version" ] ||
	fail "bundle version does not match $version: $bundle"
if find "$extract_root" -type f \( -name candy-core -o -name 'libcandy_core*' \) -print | grep -q .; then
	fail "bundle contains a forbidden Core artifact: $bundle"
fi

for elf in candy-netd candy-sdwan-agent candy-cloud-enroll candy-cloud-sync; do
	machine=$(readelf -h "$extract_root/usr/local/libexec/$elf" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')
	case "$machine" in
		*"$expected_machine"*) ;;
		*) fail "$elf has the wrong ELF architecture for $architecture: ${machine:-unknown}" ;;
	esac
done

server_command=$extract_root/usr/local/bin/candy-server
server_unit=$extract_root/systemd/candy-server.service
netd_unit=$extract_root/systemd/candy-netd.service
sync_unit=$extract_root/systemd/candy-cloud-sync.service

grep -Fq 'exec "$sdwan_agent"' "$server_command" ||
	fail "candy-server does not activate the authenticated SD-WAN agent"
grep -Fq 'exec "$core_binary" server "$@"' "$server_command" ||
	fail "candy-server has no ordinary-service fallback"
grep -Fq 'fail-open "reconnect failed; Candy-owned network state removed"' "$server_command" ||
	fail "candy-server has no reconnect fail-open path"
grep -Fq 'ExecStart=/opt/candy/current/candy-server --config /etc/candy/server.toml' "$server_unit" ||
	fail "candy-server.service does not use the product command"
grep -Fq 'User=candy' "$server_unit" && grep -Fq 'Group=candy' "$server_unit" ||
	fail "candy-server.service does not use the unprivileged service identity"
grep -Fq 'NoNewPrivileges=yes' "$server_unit" ||
	fail "candy-server.service does not enforce NoNewPrivileges"
grep -Fxq 'CapabilityBoundingSet=' "$server_unit" ||
	fail "candy-server.service retains Linux capabilities"
grep -Fq -- '--allowed-user candy --allowed-group candy' "$netd_unit" ||
	fail "candy-netd.service is not scoped to the server identity"
grep -Fq 'ExecStopPost=+/usr/local/libexec/candy-netd --recover' "$netd_unit" ||
	fail "candy-netd.service has no orphan recovery hook"
grep -Fq -- '--server-config /etc/candy/server.toml' "$sync_unit" ||
	fail "candy-cloud-sync.service does not request server activation"
grep -Fq 'ExecStartPost=+/usr/local/libexec/candy-sdwan-runtime reconcile candy-server.service' "$sync_unit" ||
	fail "Cloud synchronization does not reconcile the integrated server lifecycle"

printf '%s\n' "Verified Linux Runtime bundle $architecture for Runtime $version"
