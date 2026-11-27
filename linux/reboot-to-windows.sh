#!/usr/bin/env bash
# Ubuntu -> Windows: one-time reboot into Windows Boot Manager via UEFI BootNext.
# Usage: reboot-to-windows.sh [pattern]   (default pattern: "Windows Boot Manager")
set -euo pipefail

if [[ $EUID -ne 0 ]]; then exec sudo -- "$0" "$@"; fi

command -v efibootmgr >/dev/null || { echo "Install efibootmgr: sudo apt install efibootmgr" >&2; exit 1; }

PATTERN="${1:-Windows Boot Manager}"
entry=$(efibootmgr | grep -E '^Boot[0-9A-Fa-f]{4}\*?' | grep -i -- "$PATTERN" | head -n1 \
        | sed -E 's/^Boot([0-9A-Fa-f]{4}).*/\1/' || true)

if [[ -z "$entry" ]]; then
    echo "No UEFI entry matching '$PATTERN'. Available entries:" >&2
    efibootmgr >&2
    exit 1
fi

efibootmgr --bootnext "$entry" >/dev/null
echo "Next boot (once only): Boot$entry ($PATTERN). Rebooting..."
systemctl reboot
