[English](./CHANGELOG.md) | 简体中文

# 更新日志

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)。

## 27.1.1

### 新增

- 识别 Quectel EC21 的 USB 身份 `2c7c:0121`，支持通过 AT 通道管理。贡献者已在 EC21-EUX 上验证基础 AT 查询。语音、eUICC、VoWiFi 和 USB 联网尚未在 EC21 上验证。

### 修复

- 网络状态、服务操作、DHCP 恢复与流量采样均按当前物理 USB 模块匹配。
- EC21 的 USB 身份和接口设置为只读，模块配置预设显示为不可用。
- 打包版本默认读取应用源码 plist，发布归档名称和 IMS User-Agent 使用打包后的应用版本。

## 27.1

本节仅记录当前源码树相对远端 `main` 基线的最终净变化。

### Added

- 新增原生关于面板的版权与鸣谢内容：本地化的 `NSHumanReadableCopyright` 版权行与本地化 `Credits.html`（含可点击的 GitHub 仓库链接和 GNU AGPL v3 许可证链接），由 `package_swiftui.sh` 与 `Tools/ec25.swift` 两条打包路径一并打入应用。

### Changed

- 源码版本升至 27.1，覆盖应用 Info.plist、打包默认值、IMS `User-Agent` 与 README 徽章。
- 打包脚本改为自动定位 Xcode（`DEVELOPER_DIR`、`/Applications` 标准安装、`xcode-select`、已挂载卷），不再写死安装路径。
- 重构 coordinator 状态广播，`PresentationSnapshot` 成为设备选择与通话呈现的去重唯一通道，移除冗余 `objectWillChange`。
- 将短信会话分组与未读统计移出视图 body 热路径，交给基于指纹去重的 `SMSConversationProjectionModel` 并收窄观察范围。
- 删除确认改为按条目作用域的确认对话框；导出（改用 `WritableDocument`）、铃声导入与录音文件缺失均补充明确错误反馈。
- 联系人与通话记录搜索改用本地化自然语言比较；重复脉冲效果、纯图标按钮与侧栏来电卡片接入 Reduce Motion 与 VoiceOver 可达行为。

### Fixed

- 移除集合渲染中的 `Array(enumerated())` 拷贝，以及 `PresentationModels` 非隔离默认值引用主 actor 隔离静态属性的问题。

### Tests

- 新增 coordinator 快照发射测试（选中单次发射、来电上报、无关变更被过滤）与短信会话投影测试（分组、排序、未读计数、变更去重）。

## 27.0

本节仅记录当前源码树相对远端 `main` 基线的最终净变化。

### 新增

- 增加 `ModemSessionCoordinator`，为每个物理模块维护一个长期存在、按 IMEI 建立索引的 `ModemStore`，并支持明确选择、备注、绑定/解绑、删除保留记录、按 SIM 隔离内容和按模块路由通知。
- 在 `2c7c:0125` 之外支持第一代 DJI USB 身份 `2ca3:4006`，并增加用户确认后执行的“仅切换身份”配置流程，包括备份、重启、验证和回滚。
- 增加连续 AT 读取器、行分帧、prompt 处理、响应收集、非请求事件分类和事件总线，使模块事件与指令 transaction 安全共用一条 USB 输入流。
- 增加 PDU 短信及文本模式回退、GSM 7-bit/UCS2 解码、长短信拼接、二进制分类、验证码提取、富文本链接、通知路由，以及带 iCloud Drive 备份支持的 schema v3 逻辑/传输归档修复。
- 增加确定性的通话状态和来电身份处理、通讯录匹配、通话记录、DTMF 按键音、SIM 电话簿能力探测、原生通话界面、CoreAudio/AudioUnit 双向音频、有界重采样、建链前检查、录音、铃声导入和仅直连宿主可用的系统音频输入。
- 增加可选 QDC507 语音运行时路径：仅在用户同意后下载固定 MaVo 提交，核验字节数与 SHA-256，缓存到本地，并将部署绑定到同一物理模块；root、Linux `3.18.44`、身份、所有权和 active 路由检查均为执行门槛。
- 增加 GNSS 数据源回退与 USB NMEA、网卡和路由诊断、流量历史、恢复策略、诊断快照、日期时间偏好、外观选择，以及用于 IKE 和网络服务操作的已校验 system-helper 协议。
- 增加远程协议 v2 的模块事件、USB NMEA 转发、有界 8 kHz 双向音频帧，以及确认修改 USB 身份并重启后的直连宿主会话修复。
- 增加按 EID 与 ICCID 保存的本地 eUICC Profile 标签、号码和标记；这些值不会写入卡片。

### 调整

- 将展示层重组为固定 `640×700 pt` 的原生菜单栏弹窗和固定 `993×827 pt` 的独立窗口，使用不可拖动的 `216 pt` 侧边栏、独立导航状态、原生 `tabBarOnly` 分类、公共页面组件，并始终保留九个主功能区。
- 将短信界面重组为 Messages 风格会话工作区，使用 safe-area bar、限制气泡宽度、链接、验证码复制操作，并把管理操作移入设置。
- 将概览、电话、GNSS、网络、eSTK、VoWiFi、终端和设置重组为公共参数网格、页面内搜索、本地化空状态、一致滚动以及系统语义色彩和字体。
- 将特权 IKE 与网络服务操作迁移到新的 SMAppService system helper，同时保留旧版 IKE helper 作为迁移回退和回滚路径。
- 将模块配置备份和验证扩展到 schema v3 的 IMS、`volte_disable` 和完整 USB 组合；QDC507 方案保留 VID/PID 与其他功能，只启用所需的 ADB/UAC 接口。
- 将源码和打包默认值统一到 27.0，并仅面向 Apple Silicon `arm64`。打包流程现在会构建两个 helper 和 patched lpac，清理扩展属性，应用 ad hoc 签名并执行深度 bundle 校验。

### 修复

- 防止非请求的通话、短信、SIM、重启和断连行被误当作指令响应，并保护非应用 bundle 中的通知中心访问。
- 增加 call epoch 与用户接听门控，避免过期异步结果和含义不明确的 `CLCC` 状态激活、终止或覆盖另一通电话。
- 移除通话音频必须使用单一采样率的假设，增加 endpoint 有界恢复，排除模块采集端点作为实体麦克风回退，并要求标准模式拨号/接听前通过 `AT+QPCMV=1,2` 验证音频路由。
- 根据 transport 证据重建旧归档和云端短信投影，将不完整或证据不足的记录留在可见逻辑层之外，并使删除 tombstone 在合并中优先。
- 远程发生身份变化并重启后，在客户端继续工作前恢复直连宿主的完整模块会话和事件订阅。

### 验证边界

- 源码树包含聚焦自动化覆盖以及打包时的 bundle/签名检查；这些检查在执行时验证代码路径和生成结构，不代表真实设备行为已确认。
- 多模块硬件路由、EC25/Baiwang 通话音频、可选 QDC507 下载/部署路径、运营商通话、USB NMEA、模块配置变更、eUICC 操作、双 Mac 远程媒体和运营商 VoWiFi/IMS 仍需当前硬件与网络验收。
- 本地包使用 ad hoc 签名且未公证；SMAppService 的注册、批准、升级和卸载必须在正确签名的分发构建上验收。
