# Siri Remote 后端集成 — 测试手册

> 适用分支：`self-contained-base`（v1.8.5 时代基线 + Siri Remote 集成改动）
> 版本：1.3（2026-09-03）
> 说明：本手册覆盖 Siri Remote 后端的自动化验证边界与真机验收用例。
> **真机用例尚未执行**——需要第三代 Apple TV Siri Remote（USB-C）硬件。

## 功能范围

- 设置页"连接设备"选择：Apple Siri Remote（第三代·USB-C）/ 小米蓝牙遥控器 2 Pro
- Siri Remote 按键 → 统一事件 → 现有单击/双击/长按/快捷键/打开 App 全部可用
- Siri Remote 语音键 → Opus 解码 → 48 kHz → Fn 点按/虚拟麦克风共用会话链路
- 原生捕获和内置降级同时写入参考项目兼容的 POSIX 共享内存环；未安装系统 HAL 时仍使用现有
  `VirtualAudioOutput`，不会自动修改系统默认输入设备。
- Siri Remote 专用平铺映射页（语音键固定，其他按键均支持单击/双击/长按）
- 小米遥控器功能零回归（链路不共享改动）

## 测试前准备

1. 构建：`cd remote-mic-app && swift build`（需 macOS 15+）
2. 配对 Siri Remote：系统设置 → 蓝牙 → 连接 Siri Remote（三代 USB-C 需 USB-C 线先配对）
3. 授予 App 输入监控与辅助功能权限
4. 准备语音目标：Codex / Typeless / 豆包任意一个，音频输入选虚拟麦克风

## 自动化验证（已通过）

| 用例 | 命令 | 结果 |
|---|---|---|
| 全部单元测试 | `swift test` | ✅ 301/301 通过 |
| 构建 | `swift build` | ✅ 0 error |

新增自动化覆盖：
- `SiriRemoteBackendTests`：usage→按键映射表（Consumer/Generic/Button/Vendor/Telephony）、忽略 nextTrack/prevTrack
- `SiriRemoteAudioReportParser`：99-byte 布局、0xFF 前缀剥离、零长度释放哨兵、全零包忽略、超长包拒绝、1B 35 旧封装
- `RemoteButton` 扩展兼容：Codable rawValue 不变，历史持久化数据可读
- 后端运行策略：重启后恢复已持久化的 Siri Remote 选择
- HID 生命周期：Siri/Consumer 系统关键集合使用共享打开、断开释放按键、注册表失效自动重启发现
- 音频生命周期：Siri 连接/语音保持输出就绪，16 kHz ↔ 48 kHz 双向切换，48 kHz Fn 预滚不降采样
- 电量：HID 属性解析、标准 BLE Battery Service（180F/2A19）设备名筛选
- 本地化：语义 key 完整、无受限技术术语

## 真机验收用例

### U3-Native 原生 macOS 语音捕获

该路径用于 macOS 不转发 Direct HID `0xFA` 音频报告的机器。它不会把遥控器注册成标准
Bluetooth Audio，而是读取系统 HCI 抓包中的 GATT 语音通知，再复用 App 当前的 Opus 和虚拟
音频输出；如果 PacketLogger、管理员权限或 HCI 捕获不可用，App 会自动保留 Direct HID
路径，不会阻断普通按键和已可达的语音输入。

测试前准备：

1. 从 Apple Additional Tools 安装 `PacketLogger.app`，确认其内置
   `Contents/Resources/packetlogger` 可执行。
2. 启动 RemoteMic，选择 Apple Siri Remote；在连接面板点击“启用原生捕获”，按系统提示
   授权。该操作会重启 `bluetoothd` 并短暂断开蓝牙设备；首次启动捕获进程时，App 还会
   请求一次管理员授权以启动 PacketLogger。若 App 无法启动，可在终端执行
   `scripts/enable-siri-remote-native-mic.sh enable` 作为诊断回退。
3. 首次使用会请求麦克风权限；允许后，设置页应显示“内置麦克风降级已运行”。它只在遥控器
   语音空闲时向已选择的虚拟麦克风送入内置麦克风，不修改系统默认输入。
4. 目标 App 选择 RemoteMic 虚拟麦克风。若使用豆包等只识别兼容设备的工具，在“语音输入与兼容”中
   可直接安装或卸载 `MiRemoteV 2ch`；安装前会拒绝覆盖已有驱动，卸载前会核对 Bundle ID。
5. 设置页必须显示 PacketLogger 可用性；缺少时可以直接打开中英文原生语音设置说明。关闭设置后重新
   打开页面，状态应重新探测，不能继续显示过期的“可用”。

操作与预期：

1. 保持 RemoteMic 运行，按住 Siri 键说话 3 秒后松开。
2. 预期日志包含 `native mic capture started`，随后语音会话停止时
   `samples` 大于 0，目标 App 能收到连续语音。
3. 松开 Siri 后，预期虚拟麦克风切回内置麦克风；若设置页显示麦克风权限不足或日志出现
   `builtin fallback unavailable`，判定降级失败，但不能判定 Direct HID 按键失败。
   如果按住 Siri 后 350 ms 内仍没有任何遥控器 PCM，日志应出现 `voice fallback_started`，
   会话继续使用内置麦克风；遥控器 PCM 恢复后应出现 `voice fallback_replaced` 并立即切回遥控器。
4. 失败判定：日志出现 `packetlogger_not_found`、`packetlogger_start_failed`，或语音会话
   `samples=0`。此时保留日志和 macOS 版本，不要反复修改 `0xAF` report ID。
5. 完成测试后执行 `scripts/enable-siri-remote-native-mic.sh disable`，确认蓝牙设备和小米
   语音链路恢复；该脚本只删除 `HCITraces` 键，不修改其他蓝牙偏好。

自动化边界：`.pklg` 记录拆分、ACL/L2CAP 重组、ATT 语音帧校验、帧序号去重、降级时序和
共享内存 ABI 由 `SiriRemoteNativeMicCaptureTests` 覆盖；PacketLogger、真实蓝牙设备、管理员
权限、系统 HAL 与目标 App 收音仍必须在真实 macOS 环境验收。

### U1 连接与选择
1. 打开设置 → 连接设备，选择 Apple Siri Remote
2. 预期：卡片高亮选中；卡片内显示连接状态（绿点"已连接"或灰点"未连接"）；下方显示使用提示
3. 已配对且开启的遥控器应显示"已连接"，随后显示真实电量百分比（优先 HID 属性，缺失时读取标准 BLE Battery Service）
4. 失败判定：Siri Remote 不在蓝牙设备列表或选择后无响应；已连接时电量长期显示"—"

### U2 按键映射（逐一验证）
先进入设置 → 按键映射，确认显示 Siri Remote 平铺按键卡片；除 Siri 语音键外，每个键应能直接配置单击、双击和长按。

| 遥控器按键 | 预期事件 |
|---|---|
| Clickpad 上/下/左/右 | 方向键 |
| Clickpad 中心按下 | OK/回车 |
| 菜单/返回 | 返回（Delete） |
| 播放/暂停 | 播放/暂停媒体 |
| 音量+/- | 音量调整 |
| 静音 | 静音 |
| Siri 键（短按） | 无按键动作（语音链路） |
| 电源 | Esc |

每个键分别验证：单击、双击、长按（若已配置）三种触发。
失败判定：任一按键事件未送达目标 App，或映射到错误动作。

### U3 语音输入
1. 设置页选择 Siri Remote；目标 App 音频输入选虚拟麦克风
2. 按住 Siri 键说话 3 秒，松开
3. 预期：目标 App 出现 48 kHz 语音输入文本
4. 失败判定：
   - 无文本 → 检查日志 `SIRI REMOTE`（0xAF 写入失败？）
   - 文本乱码/断续 → 检查 Opus 解码（采样率/帧边界）

### U4 小米遥控器回归
1. 切换回"小米蓝牙遥控器 2 Pro"
2. 逐一验证：蓝牙连接、语音（RC003 普通路径）、按键映射、统计
3. 失败判定：任何一项行为与基线（self-contained-base 未改版）不一致

### U5 双后端共存
1. 保持小米后端选中，同时按住 Siri Remote 按键
2. 预期：Siri Remote 按键不响应（未选择时不启动 Siri 后端）；小米功能正常
3. 选择 Siri Remote 后重复：Siri 响应；小米仍保持连接，但其语音流会被拒绝，避免 16 kHz/48 kHz 会话相互污染
4. 切回小米后立即重试语音与按键，预期恢复正常

## 已知风险与边界

- **Direct HID 音频路径可行性（最高风险）**：VibeRemote 真机记录以及 2026 年仍在维护的同类工具都表明，
  macOS 可能不向普通 App 转发 0xFA 音频报告；0xAF 写入成功不等于音频可达。若 U3 失败且日志显示无 0xFA 报告：
  1. 确认 0xAF 写入结果（日志 `SIRI REMOTE 0xAF`）
  2. 用 Apple Additional Tools 中独立安装的 PacketLogger 做诊断；App 设置页也可显式启用/关闭
     HCI 捕获，首次启动 PacketLogger 会请求管理员授权。
  3. 若原生捕获失败，继续使用 Direct HID；只有检测到原生音频帧后才抑制重复的 Direct HID 音频。
- 触摸板手势：未实现（macOS 无法获取触摸坐标），接口已预留
- 电量显示：已实现 HID `BatteryLevel`/`BatteryPercent` 快速路径与 CoreBluetooth 标准 Battery Service（180F/2A19）兜底；不会断开系统已持有的 BLE HID 链路，5 分钟刷新一次。实际取值待真机确认
- Watch 功能：不在本基线（源码位于不可访问的私有仓库）

## 2026-08-20 文档核对依据

- Apple IOHID 文档：`kIOHIDOptionsTypeSeizeDevice` 会阻止系统及其他客户端接收事件，因此 Siri/Consumer 系统关键集合必须共享打开
- Apple IOHID 文档：异步设备发现需要把 manager 调度到 RunLoop；实现同时保存 registry entry ID，用于发现 HID 代理失效但 removal 未送达的情况
- Apple CoreBluetooth 文档：已连接设备使用 `retrieveConnectedPeripherals(withServices:)`，电量特征使用 `readValue(for:)`
- Apple AVFAudio 文档：采样格式转换由 `AVAudioConverter`/对应缓冲区完成；本 App 在后端采样率变化时显式重建输出链路

参考链接：
- https://developer.apple.com/documentation/iokit/kiohidoptionstypeseizedevice
- https://developer.apple.com/documentation/iokit/iohidmanagerschedulewithrunloop
- https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/retrieveconnectedperipherals(withservices:)
- https://developer.apple.com/documentation/corebluetooth/cbperipheral/readvalue(for:)
- https://developer.apple.com/documentation/avfaudio/avaudioconverter

## 日志收集

- 运行日志：`~/Library/Logs/`（AppLogger 输出，搜 `SIRI REMOTE`、`BACKEND`、`OPUS`）
- 提交日志时附带：Siri Remote 是否配对、0xAF 写入结果、0xFA 报告计数、解码成功率

## 验证边界声明

- 自动化测试仅证明解析/映射/构建正确；**不证明真机 HID 事件与音频可达**
- U1-U5 全部待真实 Siri Remote 硬件验收，完成前不得宣称"已支持 Siri Remote"
