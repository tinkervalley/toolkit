#!/bin/sh

set -eu

NSMB_CONF="/etc/nsmb.conf"
TMP_FILE="$(mktemp)"
BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S)"

cat <<'EOF'
This script updates /etc/nsmb.conf with common SMB performance settings.
It disables SMB signing, which can improve speed but reduces security.
Only use this on trusted networks and trusted SMB servers.
EOF

printf 'Continue? [y/N]: '
read -r answer

case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
  y|yes)
    ;;
  *)
    echo "Canceled."
    exit 0
    ;;
esac

cat > "$TMP_FILE" <<'EOF'
[default]
signing_required=no
streams=yes
soft=yes
protocol_vers_map=6
EOF

if [ -f "$NSMB_CONF" ]; then
  sudo cp "$NSMB_CONF" "${NSMB_CONF}.backup-${BACKUP_SUFFIX}"
fi

sudo install -m 644 "$TMP_FILE" "$NSMB_CONF"
rm -f "$TMP_FILE"

cat <<'EOF'
Updated /etc/nsmb.conf.
Disconnect and reconnect SMB shares, or reboot, for the new settings to take effect.
EOF
