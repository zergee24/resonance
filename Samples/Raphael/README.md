# 拉斐尔真实曲线 sample

`Artipical_Raphael_HBB_R.csv` 来自 HBB（Hawaii Bad Boy）公开频响数据库中的 `Artipical Raphael` 右声道文件。它包含 480 个原始频率、电平数值点，范围为 19.5 Hz–20,000 Hz；不是模拟数据。

- [原始 AudioTools 文件](https://hbb.squig.link/data/Artipical%20Raphael%20R.txt)
- [HBB 数据库](https://hbb.squig.link/)
- [数据库型号索引](https://hbb.squig.link/data/phone_book.json)
- 提取日期：2026-09-24。仅保留数值行，转换为 `Frequency,dB` CSV；移除了设备标识、时间和其他导出元数据。没有平滑、归一化、插值或补点。
- 原始文件 SHA-256：`8a8309a203cadeb8f2b6e15526a3b9c883186a7dc8b0f298b0538991266ff160`。

在应用中点击“使用拉斐尔示例”，即可加载此曲线和“平直参考（计算基线）”，随后导入音频或选择已有录音计算 D。也可以在资料库单独导入此 CSV，并选择自己的参考曲线。

原始 dB 数值是未归一化测量电平；计算时会拟合全局电平。平直参考方便观察频响起伏，不代表理想听感。当前来源未注明耦合器、耳套、插入深度和校准信息，结果按估计展示；更换参考会改变结果。

这里只有右声道，没有生成左声道或 20 kHz 以上曲线；扩展频段应显示缺少数据。数据来源归属 HBB，本项目不将第三方测量数据声明为自行测量或重新授予许可。
