# main 自动编译与发布验证手册

## 适用范围

- 工作流：`.github/workflows/mac-release-package.yml`
- 触发条件：提交推送到 `main`
- 发布类型：GitHub Stable/Latest Release，包含 Apple Silicon 与 Intel 安装包

## 测试前准备

1. 确认目标提交已经推送到 `MaydayV/remote-mic-app` 的 `main`。
2. 确认 `mac-release` Environment 已配置 Developer ID 签名、公证、Sparkle 和两个只读凭据仓库的部署密钥。
3. 记录提交 SHA、Actions Run ID、生成的版本号和 Build；不要在仓库提交自动生成的版本号或 Release Notes。

## 操作步骤

1. 推送一个包含普通用户可见变更的提交到 `main`。
2. 在 GitHub Actions 中打开 `macOS Signed Release Packages`，确认事件为 `push`，且 Checkout SHA 等于提交 SHA。
3. 确认 `prepare-main-auto-release.sh` 根据当前正式 Release 生成下一个补丁版本、递增 Build，并生成中英文 Release Notes。
4. 等待 Apple Silicon 与 Intel 测试、公证、Sparkle appcast 生成和资产校验全部完成。
5. 打开 GitHub Releases，确认新增的 `vX.Y.Z` 为 Stable/Latest，并包含按 AppleSilicon/Intel 和 Installer/Uninstaller 区分命名的 DMG、PKG、ZIP、两个 appcast 和校验文件；更新说明显示在 Release 正文中，不再单独展示 `.txt` 资产。
6. 在已安装的旧版 Remote Mic 中点击“检查更新”，确认客户端发现新版本，并完成 Sparkle 下载、安装和重启。

## 预期结果

- 工作流只发布当前 `main` 提交对应的安装包；Tag、Release 和制品指向同一提交。
- 版本号高于上一个正式 Release，Build 为数字且高于旧版本。
- Release Notes 至少包含当前提交的用户可见变更说明，中英文文件均存在。
- GitHub Release 为正式版，稳定 `latest` feed 已切换；客户端不需要打开预发布或内测开关。

## 失败判定

- `main` 推送没有触发签名发布工作流。
- 工作流只执行 `swift build`，没有生成并上传 DMG/PKG/ZIP。
- 版本号、Build、Tag 或 appcast 不一致，或 Release 被标记为 Pre-release。
- 签名、公证、Sparkle 签名、GitHub Release 下载、安装包校验或旧版更新任一步失败；只有配置外部 `RELEASE_DOWNLOAD_PREFIX` 时才额外执行 CDN 下载校验。
- 凭据缺失时仍创建了不完整 Release。

## 稳定回归

- `macOS CI` 的 Swift 测试、核心语音旅程、Self Test 和 Apple Silicon/Intel 编译继续通过。
- 发布 App 的稳定 `SUFeedURL`、Sparkle 公钥、签名和公证校验保持有效。
- 更新后 App 能启动、退出、再次启动，权限和用户设置不因更新新增授权要求。

## 日志与验证边界

- Actions 日志重点检查版本准备、签名、公证、`publish-release.sh auto` 和资产摘要。
- 自动化可以验证工作流、制品、签名、公证和 GitHub Release；真实 Mac 上的蓝牙、输入法、Sparkle UI 和权限恢复仍需现场验收。
