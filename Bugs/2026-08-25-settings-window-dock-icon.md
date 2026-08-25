# 关闭设置窗口后 Dock 图标未隐藏

- 时间：2026-08-25
- 状态：已修复，等待 macOS 真机窗口生命周期验收与下一版本发布
- 影响范围：macOS 菜单栏常驻模式、设置窗口关闭与重新打开
- 根因：窗口关闭前后没有根据窗口状态重新计算 App activation policy。

## 修复

设置窗口打开时使用 `.regular`，保证窗口可见并显示 Dock 图标；设置窗口关闭后，如果用户关闭了“显示 Dock 图标”，恢复 `.accessory`，保留菜单栏状态但隐藏 Dock 图标。用户明确开启“显示 Dock 图标”时仍保持 `.regular`。

## 自动化验证

- `xcrun swift test`
- `./scripts/test.sh`

自动化只验证策略计算和窗口代理接线；仍需在 macOS 真机上分别测试关闭窗口、Command-W、重新打开设置、Command-Q 和“显示 Dock 图标”开关。
