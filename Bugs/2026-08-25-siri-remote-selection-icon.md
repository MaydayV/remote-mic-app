# Apple Siri Remote 选择卡片显示图标而非真实图片

- 时间：2026-08-25
- 状态：已修复，等待设置页真机视觉验收
- 影响范围：设置 → 连接 → 连接设备 → Apple Siri Remote 选择卡片
- 根因：设置页选择卡片只渲染 `apple.logo` SF Symbol；Onboarding 已有真实遥控器图片资源但没有复用。

## 修复

设置页 Siri Remote 卡片现在加载 `Resources/SiriRemote-photo.png`，图片资源缺失时才回退到原有图标；小米遥控器卡片和连接逻辑不变。

## 验证

- `xcrun swift test`：253 项、21 个 Suite 通过
- `./scripts/test.sh`：42/42 通过

自动化验证资源接线和图标兜底；仍需在 macOS 设置页浅色/深色模式下确认图片比例、选中态和小窗口布局。
