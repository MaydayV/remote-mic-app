# 手机 App 连接、手机遥控与内测功能移除验证

适用范围：当前 Mac 版本及其发布构建。

## 测试前准备

- 使用本分支构建的 App，保留实体蓝牙遥控器或 Siri Remote 的测试条件。
- 不需要 iPhone、手机网页版、邀请码、WSS Relay 或内测服务配置。

## 验证步骤

1. 打开“连接”设置页。
   - 预期：只显示实体遥控器、Siri Remote、语音输出和音频设备相关内容；不显示手机连接、网页版、二维码、邀请码、受信任手机或 TestFlight 入口。
2. 检查构建产物的 `Contents/Info.plist`。
   - 预期：不存在 `NSLocalNetworkUsageDescription`、`NSBonjourServices`、`RemoteWebRelayURL` 或 `EarlyAccessServiceURL`。
3. 使用实体蓝牙遥控器或 Siri Remote 完成连接、普通按键、语音音频输出和输入法回写回归。
   - 预期：原有实体遥控器功能不受影响。
4. 执行 `swift test`、项目边界检查和 App 构建校验。
   - 失败判定：出现手机/网页版类型的 Swift 引用、发布脚本仍要求手机服务配置，或构建失败。

## 验证边界

- 自动化测试可以确认模块、界面文案、发布配置和构建产物字段已移除。
- 真实蓝牙遥控器、Siri Remote、虚拟音频设备和第三方输入法仍需要在用户机器上进行现场验收。
- 本次不再验证手机 App 连接、手机遥控、手机网页版、内测服务或其旧客户端兼容性。
