#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
verifier=$root/.github/scripts/verify-linux-runtime-bundle.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/candy-linux-runtime-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
	printf '%s\n' "verify-linux-runtime-bundle-test: $*" >&2
	exit 1
}

stage=$tmp/stage
mkdir -p "$stage/usr/local/bin" "$stage/usr/local/libexec" "$stage/install" \
	"$stage/etc/candy" "$stage/systemd" "$tmp/bin"

cat >"$stage/usr/local/bin/candy-server" <<'EOF'
#!/bin/sh
"$sdwan_runtime" fail-open "reconnect failed; Candy-owned network state removed"
exec "$sdwan_agent"
exec "$core_binary" server "$@"
EOF
for executable in candy-core-manager; do
	printf '#!/bin/sh\nexit 0\n' >"$stage/usr/local/bin/$executable"
done
for executable in serverd-linux candy-sdwan-runtime candy-sdwan-agent candy-netd candy-cloud-enroll candy-cloud-sync candy-server-health-check; do
	printf '#!/bin/sh\nexit 0\n' >"$stage/usr/local/libexec/$executable"
done
for executable in install-candy-server.sh upgrade-candy-server.sh; do
	printf '#!/bin/sh\nexit 0\n' >"$stage/install/$executable"
done
chmod 0755 "$stage/usr/local/bin/"* "$stage/usr/local/libexec/"* "$stage/install/"*

printf '%s\n' 'server example' >"$stage/etc/candy/server.toml.example"
cat >"$stage/systemd/candy-server.service" <<'EOF'
[Service]
User=candy
Group=candy
NoNewPrivileges=yes
CapabilityBoundingSet=
ExecStart=/opt/candy/current/candy-server --config /etc/candy/server.toml
EOF
cat >"$stage/systemd/candy-netd.service" <<'EOF'
[Service]
ExecStart=/usr/local/libexec/candy-netd --allowed-user candy --allowed-group candy
ExecStopPost=+/usr/local/libexec/candy-netd --recover --journal /var/lib/candy/netd.journal
EOF
cat >"$stage/systemd/candy-cloud-sync.service" <<'EOF'
[Service]
ExecStart=/usr/local/libexec/candy-cloud-sync --server-config /etc/candy/server.toml sync-once
ExecStartPost=+/usr/local/libexec/candy-sdwan-runtime reconcile candy-server.service
EOF
printf '%s\n' '[Timer]' 'OnUnitActiveSec=30s' >"$stage/systemd/candy-cloud-sync.timer"
printf '%s\n' 'd /var/lib/candy 0711 root root -' >"$stage/systemd/candy.tmpfiles"
printf '%s\n' 0.4.0 >"$stage/VERSION"

cat >"$tmp/bin/readelf" <<'EOF'
#!/bin/sh
printf '%s\n' '  Machine:                           Advanced Micro Devices X86-64'
EOF
chmod 0755 "$tmp/bin/readelf"

valid=$tmp/valid.tar.gz
COPYFILE_DISABLE=1 tar --no-xattrs -C "$stage" -czf "$valid" .
PATH="$tmp/bin:$PATH" "$verifier" 0.4.0 x86_64 "$valid" >/dev/null ||
	fail "valid integrated server bundle was rejected"

cp -R "$stage" "$tmp/duplicate"
printf '%s\n' '[Service]' >"$tmp/duplicate/systemd/candy-sdwan.service"
tar --no-xattrs -C "$tmp/duplicate" -czf "$tmp/duplicate.tar.gz" .
if PATH="$tmp/bin:$PATH" "$verifier" 0.4.0 x86_64 "$tmp/duplicate.tar.gz" >/dev/null 2>&1; then
	fail "duplicate server SD-WAN service was accepted"
fi

cp -R "$stage" "$tmp/no-fail-open"
sed '/reconnect failed; Candy-owned network state removed/d' \
	"$tmp/no-fail-open/usr/local/bin/candy-server" >"$tmp/no-fail-open/usr/local/bin/candy-server.next"
mv "$tmp/no-fail-open/usr/local/bin/candy-server.next" "$tmp/no-fail-open/usr/local/bin/candy-server"
chmod 0755 "$tmp/no-fail-open/usr/local/bin/candy-server"
tar --no-xattrs -C "$tmp/no-fail-open" -czf "$tmp/no-fail-open.tar.gz" .
if PATH="$tmp/bin:$PATH" "$verifier" 0.4.0 x86_64 "$tmp/no-fail-open.tar.gz" >/dev/null 2>&1; then
	fail "bundle without reconnect fail-open was accepted"
fi

if PATH="$tmp/bin:$PATH" "$verifier" 0.4.0 aarch64 "$valid" >/dev/null 2>&1; then
	fail "bundle with the wrong ELF architecture was accepted"
fi

printf '%s\n' "Linux Runtime bundle verifier tests passed"
