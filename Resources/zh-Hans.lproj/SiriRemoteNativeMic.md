# 原生 Siri Remote 语音设置

macOS 会提供 Siri Remote 的按键，但通常不会把 GATT 麦克风流交给普通 HID 客户端。Remote Mic
可以使用 Apple 的 PacketLogger 旁路观察这条流，不会修改蓝牙配对关系。

1. 安装 Apple Additional Tools for Xcode，并确认存在
   `PacketLogger.app/Contents/Resources/packetlogger`。
2. 在 Remote Mic 中选择 **Apple Siri Remote**，点击 **启用原生捕获**。
3. 在管理员授权提示中确认。macOS 会短暂重启 `bluetoothd`，其他蓝牙设备可能随后重新连接。
4. 按提示允许麦克风权限。Siri 空闲时，所选虚拟麦克风会接收 Mac 内置麦克风作为本地降级；
   按住 Siri 键后切换为解码后的遥控器语音，松开后回到降级输入。

HCI 设置是可选且可逆的；不再使用时可在同一个设置卡中关闭。未安装 PacketLogger 时，按键映射
仍可工作，但遥控器语音捕获无法启动，需先安装 Additional Tools。

该路径依赖 macOS 未公开的蓝牙跟踪行为，升级 macOS 后应重新验证。
