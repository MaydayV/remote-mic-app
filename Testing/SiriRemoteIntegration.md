# Siri Remote 后端集成 — 测试手册

> 适用分支：`self-contained-base`（v1.8.5 时代基线 + Siri Remote 集成改动）
> 版本：1.0（2026-08-19）
> 说明：本手册覆盖 Siri Remote 后端的自动化验证边界与真机验收用例。
> **真机用例尚未执行**——需要第三代 Apple TV Siri Remote（USB-C）硬件。

## 功能范围

- 设置页"连接设备"选择：Apple Siri Remote（第三代·USB-C）/ 小米蓝牙遥控器 2 Pro
- Siri Remote 按键 → 统一事件 → 现有单击/双击/长按/快捷键/打开 App 全部可用
- Siri Remote 语音键 → Opus 解码 → 48 kHz → 虚拟麦克风
- 小米遥控器功能零回归（链路不共享改动）

## 测试前准备

1. 构建：`cd remote-mic-app && swift build`（需 macOS 15+）
2. 配对 Siri Remote：系统设置 → 蓝牙 → 连接 Siri Remote（三代 USB-C 需 USB-C 线先配对）
3. 授予 App 输入监控与辅助功能权限
4. 准备语音目标：Codex / Typeless / 豆包任意一个，音频输入选虚拟麦克风

## 自动化验证（已通过）

| 用例 | 命令 | 结果 |
|---|---|---|
| 全部单元测试 | `swift test` | ✅ 233/233 通过 |
| 构建 | `swift build` | ✅ 0 error |

新增自动化覆盖：
- `SiriRemoteBackendTests`：usage→按键映射表（Consumer/Generic/Button/Vendor/Telephony）、忽略 nextTrack/prevTrack
- `SiriRemoteAudioReportParser`：99-byte 布局、0xFF 前缀剥离、零长度释放哨兵、全零包忽略、超长包拒绝、1B 35 旧封装
- `RemoteButton` 扩展兼容：Codable rawValue 不变，历史持久化数据可读
- 本地化：语义 key 完整、无受限技术术语

## 真机验收用例

### U1 连接与选择
1. 打开设置 → 连接设备，选择 Apple Siri Remote
2. 预期：卡片高亮选中；卡片内显示连接状态（绿点"已连接"或灰点"未连接"）；下方显示使用提示
3. 已配对且开启的遥控器应显示"已连接"，随后提示框显示真实电量百分比（HID `BatteryLevel` 属性）
4. 失败判定：Siri Remote 不在蓝牙设备列表或选择后无响应；已连接时电量长期显示"—"

### U2 按键映射（逐一验证）
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
3. 选择 Siri Remote 后重复：Siri 响应、小米仍可工作（链路互不干扰）

## 已知风险与边界

- **Direct HID 音频路径可行性（最高风险）**：VibeRemote 文档记载 macOS 对第三方 App
  隐藏 GATT HID 服务（0x1812），IOHID 可能不转发 0xFA 音频报告——0xAF 写入本身成功，
  但音频交付可能被系统阻断。若 U3 失败且日志显示无 0xFA 报告：
  1. 确认 0xAF 写入结果（日志 `SIRI REMOTE 0xAF`）
  2. 计划 B：PacketLogger 引擎（需特权 daemon，尚未实现）
- 触摸板手势：未实现（macOS 无法获取触摸坐标），接口已预留
- 电量显示：已实现 HID `BatteryLevel`/`BatteryPercent` 属性读取（连接后立即读取，2 秒延迟重试一次；断开自动清空）；实际取值与刷新时机待真机确认
- Watch 功能：不在本基线（源码位于不可访问的私有仓库）

## 日志收集

- 运行日志：`~/Library/Logs/`（AppLogger 输出，搜 `SIRI REMOTE`、`BACKEND`、`OPUS`）
- 提交日志时附带：Siri Remote 是否配对、0xAF 写入结果、0xFA 报告计数、解码成功率

## 验证边界声明

- 自动化测试仅证明解析/映射/构建正确；**不证明真机 HID 事件与音频可达**
- U1-U5 全部待真实 Siri Remote 硬件验收，完成前不得宣称"已支持 Siri Remote"
