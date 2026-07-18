#!/usr/bin/env bash
set -euo pipefail
HOST=$1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SSHKEY=$(cat ~/.ssh/id_ed25519.pub)
WORK=$(mktemp -d)
sed -e "s|__HOST__|$HOST|g" -e "s|__SSHKEY__|$SSHKEY|" \
  "$ROOT/cloud-init/user-data.tmpl" > "$WORK/user-data"
cp "$ROOT/cloud-init/network-config.tmpl" "$WORK/network-config"
printf "instance-id: %s\nlocal-hostname: %s\n" "$HOST" "$HOST" > "$WORK/meta-data"
genisoimage -quiet -output "$ROOT/images/${HOST}-seed.iso" \
  -volid cidata -joliet -rock \
  "$WORK/user-data" "$WORK/meta-data" "$WORK/network-config"
rm -rf "$WORK"
echo "wrote $ROOT/images/${HOST}-seed.iso"
