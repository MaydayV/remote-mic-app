#!/bin/zsh

# Enable/disable the reversible macOS HCI trace settings used by the native
# Siri Remote microphone path.  This is deliberately an explicit user action:
# writing /Library/Preferences and restarting bluetoothd require administrator
# approval and briefly disconnect every Bluetooth device.

set -euo pipefail

debug_domain="/Library/Preferences/com.apple.MobileBluetooth.debug"
defaults_bin="/usr/bin/defaults"

usage() {
    echo "Usage: $0 enable|disable|status" >&2
}

case "${1:-}" in
    enable)
        sudo "$defaults_bin" write "$debug_domain" HCITraces -dict \
            HCISkipAuth -bool true \
            HCILiveTraces -bool true \
            HCIFileTraces -bool true \
            StackDebugEnabled -bool true \
            RawAudioTrace -bool true \
            HIDTrace -bool true
        echo "HCI trace settings enabled. Restarting bluetoothd..."
        sudo /usr/bin/killall -30 bluetoothd || true
        echo "Native Siri Remote capture is ready; start RemoteMic and hold Siri."
        ;;
    disable)
        sudo "$defaults_bin" delete "$debug_domain" HCITraces 2>/dev/null || true
        echo "HCI trace settings disabled. Restarting bluetoothd..."
        sudo /usr/bin/killall -30 bluetoothd || true
        ;;
    status)
        "$defaults_bin" read "$debug_domain" HCITraces 2>/dev/null || \
            echo "HCI trace settings are not configured."
        ;;
    *)
        usage
        exit 2
        ;;
esac
