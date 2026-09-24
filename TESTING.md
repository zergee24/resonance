# 本机验证记录 · 0.2.0

日期：2026-09-25。macOS 26.6.2，Apple Silicon，Swift 6.3.3，部署目标 macOS 14.2。

## 已跑通的真实数据链

使用已保存在本机的真实播放器录音（27.648 秒、48 kHz、双声道），重新分析全部 PCM，得到 645 个频谱帧。耳机为仓库内 HBB 拉斐尔右声道 480 点 sample，参考为明确标注的 0 dB 平直计算基线。

| 结果 | 实测值 |
| --- | --- |
| 参考偏差 D | 3.1776 dB |
| 10–20 kHz 偏差 Dhigh | 3.7419 dB |
| 谱形变化 C | 0.071777 |
| 歌曲 10–20 kHz 能量占比 | 0.07237% |
| 实际计算范围 | 20 Hz–20 kHz |

录音有历史丢帧记录，验证明确使用 partial + gaps + 未确认身份输入。结果正常返回估计值，并说明已采时长与缺口；没有把缺口补成静音，没有把片段认定为完整歌曲。平直参考不代表理想听感，以上数字仍需要用户试听判断用途。

本机证据为 `test-output/verification/real-raphael-result.txt`。录音、频谱和本机诊断日志不随公开仓库分发。

## Process Tap 启动与落盘

旧配置启用了 `kAudioAggregateDeviceTapAutoStartKey=1`。本机 Apple SDK 的 `AudioHardware.h` 注释明确说明，这会让 `AudioDeviceStart` 等待 tap 首次收到音频；与旧阻塞样本一致。0.2.0 移除此配置，保留后台启动、取消清理与 SPSC 缓冲。

- 独立真实设备诊断：合成播放进程连续三次 start 为 61/64/67 ms，并收到非零音频；空闲网易云进程为 45 ms，收到静音回调。
- 生产调用链 `AudioCapture.start → IOProc → ring → CAF → stop` 连续多次完成。精简后的 `zsh scripts/verify-process-tap.sh` 最后一次为 96,256 帧、188 callbacks、0 dropped，CAF 774,144 bytes，非零音频检查通过。
- 该脚本播放合成音测试真实硬件路径；这不是网易云整曲自动采集验收。

## 自动验证与构建

- `scripts/verify-core.sh`：真实曲线导入、log-Hz 插值、不外推、声道保留、PSD、D/Dhigh/C、频率单元积分、扩展频段通过；新增任意参考、partial/unknown/gaps 可计算、相同 PSD 的缺口不改变 D、非有限数据拒绝断言通过。
- 同一核心脚本的 60 秒音频包含前、中、后三段不同频率，分析到最后一秒，三段均贡献能量，没有 30 秒截断。
- `scripts/verify-listening.sh`：21 项关键行为通过，包括默认开启、关闭持久化、重复轮询、暂停/切歌、跳播、显式重试和禁用后不重启。
- `zsh scripts/verify-capture.sh`：20 万帧顺序一致、零丢帧，受控溢出计数 4096 正确。
- `zsh scripts/verify-capture-cancellation.sh`：取消/完成先后与超时竞态通过。
- XCTest 在当前 Command Line Tools 环境缺少模块，使用上述原生 Swift probes；不将未运行的 XCTest 描述为通过。

Release 构建与 `codesign --verify --deep --strict` 通过。0.2.0 可执行文件 SHA-256：`16ea98d97c6981f8af495c648e53375dafb87a0bf7fb54f1dfe7e9c8013f55b2`。安装包包含同一可执行文件、使用说明、验证记录和曲线 sample。

## 界面与尚未验证的部分

- 本轮 Mac 锁屏，界面工具要求用户手动解锁；未进行 0.2.0 的按钮点击验收。
- 尚未完成辅助功能授权后的网易云身份识别、连续整曲采集与切歌联动端到端验收。采集始终显示实际已录时长，播放器观察不充当精确音频边界。
- 0.1.1 曾实测自动积累默认开启、关闭后重启仍关闭；本轮保留同一偏好键，并以策略 probe 回归。
- 既往网页读取曾取得毁 HiFi 957 个真实频响点及网易云公开歌单 10 条 ID/标题/顺序；本轮未改动两个读取脚本。
- 0.2.0 已移除未跑通的网易云写入功能；本地 JSON 导出保留。

应用使用本机临时签名，未公证。原始用户资料和历史导出 journal 保留在本地，本轮未清除。
