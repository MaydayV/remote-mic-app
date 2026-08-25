# GitHub 发布时 productsign 超时

## 复现

- 运行：GitHub Actions `macOS Signed Release Packages`，Run `32714367365`。
- 触发提交：`c9a6ec1`。
- 前置 Swift 测试、Self Test、证书导入、App 和驱动构建均通过。
- 生成两个未签名安装包后，流程长时间没有新日志，最终达到 180 分钟任务上限并被取消。

## 日志结论

最后有效日志是 `pkgbuild` 生成 `Install Remote Mic-unsigned.pkg` 和 `Uninstall Remote Mic-unsigned.pkg`；没有出现 `notarytool submit` 输出。任务清理阶段终止了残留的 `productsign` 进程，因此故障发生在安装包签名阶段，不是公证或 GitHub Release 上传阶段。

## 根因

隔离发布 Keychain 导入证书时没有把 `/usr/bin/productsign` 加入可信工具列表，安装包签名脚本也没有显式传入临时 Keychain，导致无界面 CI 环境中的 `productsign` 无响应。原脚本没有单次签名超时，最终只能等待整个 180 分钟任务超时。

## 修复

- 发布凭据仓库将 `productsign` 加入 P12 导入的可信工具列表，并导出临时 Keychain 路径。
- 安装包签名脚本显式使用该 Keychain。
- 每个 `productsign` 调用增加默认 900 秒超时，超时会终止签名并让任务失败，避免再次占满整个 Runner。
- 增加静态回归测试，检查 Keychain 参数、超时和两个安装包签名路径。

## 验证边界

- 本地已通过 `zsh -n`、`git diff --check` 和 `swift test --filter BuildSigningTests`。
- 尚未完成新的 GitHub macOS Runner 签名、公证、Release 上传和真实安装验收；需要以修复后的 Actions Run 结果为准。

## 后续发布校验问题

第一次修复后的 Run 已成功完成双架构签名、公证、装订和 Gatekeeper 验证，并创建了 `v1.8.11` Release。随后发布脚本对旧的 `download.sayall.app` 外部 CDN 执行校验，但该域名没有同步本仓库资产，返回 404，导致工作流在 Release 已上传资产后失败。现已将本仓库默认 appcast 和下载地址改为 GitHub Release；外部 CDN 仅在显式设置 `RELEASE_DOWNLOAD_PREFIX` 时校验。
