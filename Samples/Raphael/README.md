# 拉斐尔真实曲线 sample

`Artipical_Raphael_HBB_R.csv` 来自 HBB（Hawaii Bad Boy）公开频响数据库中的 `Artipical Raphael` 右声道文件。它包含 480 个原始频率、电平数值点，范围为 19.5 Hz–20,000 Hz；不是模拟数据。

- [原始 AudioTools 文件](https://hbb.squig.link/data/Artipical%20Raphael%20R.txt)
- [HBB 数据库](https://hbb.squig.link/)
- [数据库型号索引](https://hbb.squig.link/data/phone_book.json)
- 提取日期：2026-09-24。仅保留数值行，转换为 `Frequency,dB` CSV；移除了设备标识、时间和其他导出元数据。没有平滑、归一化、插值或补点。
- 原始文件 SHA-256：`8a8309a203cadeb8f2b6e15526a3b9c883186a7dc8b0f298b0538991266ff160`。

在应用的“我的声学资料库”导入此 CSV，名称可填 `Artipical Raphael · HBB · R`，来源填写上述原始文件 URL，测量体系保留为 `unknown`。仅在确实拥有这副耳机时勾选“我拥有”。

原始 dB 数值是未归一化测量电平，不是耳机相对增益。本 sample 没有可核验的耦合器、耳套、插入深度、校准和兼容参考信息，不能仅凭填入相同体系名称参与比较。它适合验证曲线导入与查看；实际匹配排名仍需补充可比测量和兼容参考。

这里只有右声道，没有生成左声道或 20 kHz 以上曲线；扩展频段应显示缺少数据。数据来源归属 HBB，本项目不将第三方测量数据声明为自行测量或重新授予许可。
