# macOS 发布分支规范

## 分支职责

- 功能、修复和用户可见文案先通过 Pull Request 合入 `main`。
- macOS 预览候选使用一次性的 `release/pre-vX.Y.Z` 分支。
- 候选分支必须从最新 `origin/main` 创建，只允许包含版本号、Build、对应版本历史和测试手册目标版本等发布元数据。
- 不得在候选分支直接开发功能、合入其他开发分支或混入尚未验收的工作树内容。
- 每个版本只使用一个候选分支；失败候选保持 Tag 和 Release 不变，修复后递增版本与 Build，并创建新的候选分支。
- 候选分支在正式晋升完成前必须保留在远端，供来源校验、自动合并和 Release 守卫使用。

## 预览候选流程

1. 将计划发布的功能通过 PR 合入 `main`，等待 macOS CI 通过。
2. 从最新 `origin/main` 创建 `release/pre-vX.Y.Z`。
3. 只修改 `Resources/Info.plist`、中英文 `ReleaseHistory.md`，以及确有必要的 `Testing/*.md` 目标版本。
4. Push 候选分支。GitHub Actions 自动执行分支来源校验、Swift Testing、Self Test、Release 编译和临时 App 打包。
5. 预览候选 CI 成功后，受保护的 `mac-release` 环境会自动创建匹配 Tag，使用 readonly Match、随机密码隔离 Keychain、独立 P8 凭据仓库和 Sparkle 私钥完成签名、公证，并自动创建 GitHub Pre-release。
6. 发布说明从该版本的中英文 `ReleaseHistory.md` 自动提取，GitHub Release 同时包含中文和英文更新内容；缺少任一语言的版本条目会阻止发布。
7. Tag、远端候选分支和发布资产必须解析到同一个提交。GitHub Release 必须保持 Pre-release，稳定 `latest` 不得变化。
8. 发布脚本会重新下载全部公开资产并逐字节复核；使用公开稳定版执行固定候选 appcast 的真实 Sparkle 更新。

GitHub 自动生成的 CI App 只用于验证打包结构，不是公开安装包。自动签名发布依赖 `mac-release` Environment 中已有的受保护凭据，以及 `MaydayV/remotemic-notary-secrets` 和 `MaydayV/apple-signing-match` 两个私有仓库；凭据缺失时工作流会失败且不会生成可下载的公开安装包。

## main 自动发布

- 每次提交进入 `main` 后，`mac-release-package.yml` 会自动启动签名发布工作流；普通 `macOS CI` 仍负责独立的测试和双架构 Release 编译门禁。
- 自动流程从 GitHub 最新正式 Release 推导下一个补丁版本，并使用 GitHub Actions Run Number 生成递增 Build；不会改写仓库中的版本文件或提交机器人版本提交。
- 工作流在临时工作区生成中英文 Release Notes，内容来自当前提交说明和提交短 SHA；随后执行 Apple Silicon、Intel、测试、公证、Sparkle 签名、DMG/PKG/ZIP 校验，并创建正式 GitHub Release。
- 自动 Release 使用 `vX.Y.Z` Tag 并标记为 Stable/Latest，因此客户端内置的稳定 Sparkle feed 可以发现并提示更新。默认下载地址使用本仓库 GitHub Release；只有设置 `RELEASE_DOWNLOAD_PREFIX` 时才启用外部 CDN 校验。自动发布不是 Pre-release，也不依赖手机 App 或内测入口。
- 自动发布仍依赖受保护的 `mac-release` Environment、Developer ID 证书、公证 API、Sparkle 私钥，以及 `MaydayV/remotemic-notary-secrets` 和 `MaydayV/apple-signing-match`；任一凭据缺失时流程失败且不会发布半成品。

## 正式晋升

- 只有用户明确指定具体版本并要求正式发布时才允许晋升。
- 先通过 PR 将原候选提交合入 `main`，保留原 Tag 和原资产，不重新构建。
- 晋升前必须证明 Tag 提交已包含在 `origin/main`，并复核 `candidate-provenance.json` 中的分支、提交和资产摘要。
- 正式晋升只修改现有 GitHub Release 的分类和 `latest` 状态，不替换任何候选资产。
- GitHub 页面上的人工“设为正式版”只视为晋升请求；Release 守卫会先恢复为 Pre-release，校验候选来源，创建或复用候选分支到 `main` 的 PR、显式调度必需 CI 并启用 Auto-merge。CI 成功后，受保护的晋升工作流确认带授权标签的 PR 已合入 `main`，再只晋升原 Tag 和原资产。
- 晋升脚本从候选的 `candidate-provenance.json` 读取版本和 Build，不依赖 `main` 当时的 `Info.plist`；因此后续开发已经提高版本号时，仍可安全晋升较早的已验收候选。

## Release Notes

- 只记录普通用户能够看到或受益的功能、体验、兼容性和可靠性变化。
- 不写提交标题、哈希、CI、文档维护、测试数量、签名、公证、分支规范或发布流程。
- 已撤回、删除或从未公开的版本不进入 App 内版本历史。
