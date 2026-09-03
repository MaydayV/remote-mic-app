# Native Siri Remote voice setup

Apple exposes the Siri Remote buttons to macOS, but its GATT microphone stream is hidden from
ordinary HID clients. Remote Mic can use Apple's PacketLogger to observe that stream without
changing the Bluetooth pairing.

1. Install Apple's Additional Tools for Xcode and make sure
   `PacketLogger.app/Contents/Resources/packetlogger` is present.
2. In Remote Mic, select **Apple Siri Remote**, then choose **Enable native capture**.
3. Approve the administrator prompt. macOS briefly restarts `bluetoothd`; other Bluetooth devices
   may reconnect afterward.
4. Approve microphone access when requested. While Siri is idle, the selected virtual microphone
   receives the Mac's built-in microphone as a local fallback. Holding Siri switches to the
   decoded remote stream; releasing Siri returns to the fallback.

The HCI preference is opt-in and reversible. Disable native capture in the same Settings card when
you no longer need it. If PacketLogger is missing, button mapping can still work, but remote voice
capture cannot start until Additional Tools is installed.

This path uses undocumented macOS Bluetooth tracing and must be rechecked after macOS upgrades.
