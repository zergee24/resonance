# 耳机频响 × 歌曲选曲：2006–2026 原始研究与最小算法改进

日期：2026-09-29  
用途：为“共鸣”本地耳机—歌曲匹配模型判断哪些研究可以转成可复算的工程证据，哪些不能转成“喜欢概率”。  
研究范围：耳机目标曲线、节目材料依赖、时间/频带加权、听者差异、个性化反馈，以及测量夹具和虚拟耳机方法。优先采用 AES、JAES、JASA、PLOS ONE、作者公开全文或作者公开材料。

交付口径：现状审计以基线 `b87a597` 为参照；本轮源码已经加入独立谱内/跨帧参数诊断，但本轮没有部署主 App。下面区分已有能力、本轮实现和后续研究；代码验证结果以 [TESTING.md](../../TESTING.md) 的对应版本记录为准。Classic 左右 FR 抵消修复来自代码审计，不能当作文献直接导出的主观音质提升。

## 先给结论

基线模型已经具备：真实 PCM 的逐帧 PSD、线性功率积分、Glasberg–Moore ERB 几何分带、谱内与跨帧都使用默认 `alpha=0.3` 的压缩（可记为 `(alphaSpectrum=0.3, temporalActivity=0.3)`）、每条参考一个全局电平偏移、整体 RMS、10–20 kHz 独立偏差、压缩帧能量加权 P90，以及多参考逐条计算后取整体偏差最小的参考。本轮源码已在同一中间数据上加入独立参数情景和诊断输出，仍明确不把结果称为 ISO 响度、phon、sone 或喜欢概率。

本次检索未找到可直接验证“把歌曲 PSD 乘一组固定频率权重，就能预测某个用户会喜欢哪首歌”的研究证据。这不是穷尽式系统综述。可据此采取的最小精进是把当前结果拆成三个可核验层次：

1. **声学暴露**：这首实际录音的能量在某条耳机曲线上被怎样改变。
2. **参考条件下的偏离**：在指定目标、测量体系和共同频段内偏离多少。
3. **用户偏好证据**：同一用户在响度尽量匹配的实际或虚拟 A/B 试听中选择了什么。

第三层没有标签时必须留空；不能由两条被喜欢的耳机曲线、人口平均目标或论文相关系数代替。

最小改进建议如下：

- **保留参考条件**：把 `stereo`、`spatial/BRIR`、人口目标和用户目标作为不同参考档案。`bestReferenceID` 可以继续作为方便用户的最低偏离结果，但必须同时保留每条完整结果、参考条件和与次优参考的差值，不能把不同参考逐频拼成“最佳目标”。
- **后续增加内容稳健性**：在整曲分数旁计算分段/窗口分数、频带覆盖、有效帧比例和排名稳定性。节目研究显示，节目未必产生显著的总体主效应，但会显著改变区分度和可靠性；单一整曲均谱不足以证明稳定的听感结论。本轮尚未实现分段或 top-k 排名稳定性。
- **后续增加局部峰证据**：宏观 RMS/SD/斜率可能漏掉窄带、中等 Q 的共振。当前只保留相关回归测试/研究证据，不新增局部峰总分；未来若有测量重复性，再把局部峰、带内离散度作为独立诊断，不直接加进一个未经试听校准的总分。
- **拆开谱内与跨帧参数**：`alpha=0.3` 继续作为现有默认工程参数；另行报告跨帧活动/时间聚合敏感性，至少比较旧默认与一个明确的时间权重实验情景。Oberfeld 等的 1.02 s 噪声实验不能直接变成全曲歌单权重。
- **建立低维用户反馈入口**：先用相同歌曲、固定顺序随机化、尽量匹配响度的 A/B 或低频/高频两个旋钮，学习用户相对人口目标的低维偏移；在没有反馈前不输出个人喜欢概率。
- **把高频单独处理**：10–20 kHz 可作为独立证据；高频偏好受听阈、耳机插入和高频夹具影响，不能把一个插入式耳机目标推广到所有耳机。20 kHz 以上继续是扩展证据旁路。

这份研究不会改动主 App、采集流程、数据库、音频或歌单，也没有部署到主 App。文中“建议”是研究输入，不代表代码已经实现。

## 当前实现与研究问题的边界

当前实现的数学对象是相对频谱交互。对耳机响应 (H_h(f))、参考响应 (R_r(f)) 和歌曲 PSD (P(f,t))，它在共同频段内形成

\[
\Delta_{h,r}(f)=H_h(f)-R_r(f)
\]

并以歌曲实际能量做频带和帧权重，拟合一个跨整段的全局偏移 (g)，再报告参考偏差和局部误差。它回答的是“这段录音在该耳机上相对该参考的谱形偏离”，不是“用户会不会喜欢”。

当前的 `alpha=0.3` 是压缩极端能量的工程参数；P90 是压缩帧能量加权的尾部证据。它们都没有经过本产品的受控试听校准。没有耳膜 SPL、播放链校准、佩戴/密封记录和测量夹具统一时，不能接入 ISO 226 等响度曲线后把输出称为人耳响度。

## 关键原始研究

下表先给出研究对象和可转用边界；随后按研究逐项展开。`摘要级` 表示本轮只使用官方摘要/作者摘要页，未把未读全文中的数字补成结论；`全文` 表示本轮取得并阅读公开全文或开放期刊全文；`作者材料` 表示用于补充实验条件的作者/机构公开白皮书，不把它当作论文同行评议结果。

| 年月 | 研究 | 对象与条件 | 实际结论 | 对算法可转用 | 证据状态 |
|---|---|---|---|---|---|
| 2013-05 | Olive, Welti & McMullin, *Listener Preferences for Different Headphone Target Response Curves*, AES 134, Paper 8867 | 两个双盲测试；训练听者；8 条目标曲线；2 个耳机型号；面向立体声录音 | 两个耳机上，基于校准房间扬声器响应的新目标最受偏好 | stereo 参考目标可作为独立档案；不能把总体目标直接当歌曲偏好 | 摘要级 |
| 2015-10 | Olive & Welti, *Factors That Influence Listeners’ Preferred Bass and Treble Levels in Headphones*, AES 139, Paper 9382 | 249 名听者；3 个 stereo 音乐节目；每人重复 5 次 bass/treble 调整；不同年龄、性别、经验与国籍 | 节目、年龄、性别、听音经验都会改变偏好的低/高频平衡；年轻、经验少者平均偏好更多 bass/treble | 用于建立用户校准和人口差异字段；不能用平均差异给每首歌加权 | 摘要级 |
| 2016-08 | Olive, Welti & Khonsaripour, *The Preferred Low Frequency Response of In-Ear Headphones*, AES Headphone Technology, Paper 6-1 | 10 名训练听者；3 个音乐节目；调整二阶低架滤波器；比较响度归一化和漏声控制 | 低频偏好会受节目、响度归一化、漏声和测试方法影响 | 低频结果必须记录电平/密封状态；节目影响应作为稳健性证据而非固定喜好权重 | 摘要级，公开摘要含条件 |
| 2016-09 | Welti, Olive & Khonsaripour, *Validation of a Virtual In-Ear Headphone Listening Test Method*, AES 141, Paper 9658 | 10 名训练听者；12 个 IE；比较真实耳机与虚拟化、双耳录制后在复现耳机上的结果 | 虚拟化耳机的整体音质评分与真实耳机相近 | 可用虚拟耳机降低 A/B 反馈的硬件成本，但需要先验证代表性和泄漏/佩戴控制 | 摘要级 |
| 2017-05 | Olive, Welti & Khonsaripour, *The Influence of Program Material on Sound Quality Ratings of In-Ear Headphones*, AES 142, Paper 9778 | 10 名训练听者；8 个 IE；10 个音乐节目；双盲虚拟耳机；监测并消除漏声 | 耳机是主要效应；节目总体主效应/交互不显著，但节目区分度和可靠性不同，关键因素为频谱带宽和熟悉度；低频内容会改变对低频偏差耳机的评价 | 增加频带覆盖、有效帧、分段排名稳定性和熟悉度记录；不要把 genre 变成隐藏权重 | 摘要级 |
| 2017-10 | Olive, Welti & Khonsaripour, *A Statistical Model… In-Ear Headphones*, AES 143, Papers 9840/9878 | 71 名训练和非训练听者；30 个 IE；100 分偏好尺度；隐藏高参考、低锚点；虚拟耳机；漏声控制 | 目标偏差越大，平均偏好越低；Part 2 报告基于目标偏差大小、标准差和斜率的回归模型，摘要给出 (r=0.91) | 支持“参考偏离”作为描述指标；不能把 headphone-level 回归系数移植成 song-level 喜欢概率 | 摘要级 |
| 2018-05 | Olive, Welti & Khonsaripour, *A Statistical Model… Around-Ear and On-Ear Headphones*, AES 144, Paper 9919 | 130 名听者（28 trained、102 untrained）；31 个 AE/OE；5 个测试、3 个节目、2 次观察；虚拟耳机；相对电平按 BS.1770，平均约 85 dB C；至约 12 kHz 匹配约 ±1 dB | Harman AE/OE 目标总体受偏好；SD/绝对斜率模型可预测部分静态耳机评分，但两个中 Q 窄共振成为离群点 | 增加窄带局部峰与不确定性诊断；保留现有 RMS/P90，不移植其偏好分数和系数 | 全文（AES advance manuscript，正文注明完整稿未同行评议） |
| 2019-03 | Olive, Welti & Khonsaripour, *Segmentation of Listeners Based on Their Preferred Headphone Sound Quality Profiles*, AES 146, Paper 10156 | 重分析 IE 与 AE/OE 受控试听数据；训练与非训练听者；cluster analysis | 平均上两组都偏好接近 Harman 的曲线，但存在不同听者类别，并探索年龄、性别、经验与声学因素 | 人口目标只能作为先验；需要用户 A/B 标签或分群，不应由两个喜欢的耳机反推完整目标 | 摘要级 |
| 2019-10 | Welti et al., *A Comparison of Test Methodologies to Personalize Headphone Sound Quality*, AES 147, Paper 10247 | 比较 4 种个性化测试；都让听者调整 bass/treble shelf；评价速度、准确度和易用性 | 个性化测试存在明确的速度—准确度—易用性权衡 | 可作为移动端短反馈的设计依据；不提供歌曲偏好模型或全频目标 | 摘要级 |
| 2020-08 / 2022-04 | Engel et al., *Listener-Preferred… Stereo and Spatial Audio* / *On the Differences…*，AES AVAR 2020、JAES 70(4) | 3 个测试；每个超过 20 名听者；7 个目标响应；2 个耳机；2 个重放带宽；空间内容用个体 BRIR 渲染 | spatial/BRIR 内容偏好 flat；stereo 内容偏好 Harman；个体 EQ 时效应更强；耳机和重放带宽影响不显著 | 参考曲线必须绑定内容渲染条件；保留每条 reference-conditioned 结果，不能无条件 min | JAES 摘要级，开放论文页可核对 |
| 2012-11 | Oberfeld et al., *Spectro-Temporal Weighting of Loudness*, PLOS ONE 7(11), e50184 | 10 名正常听力听者（两实验室各 5）；1,020 ms 噪声；3 个 3-Bark 噪声带；100 ms 级别随机变化；三带频谱和时间权重分开及联合测量 | 前 300 ms 对总体响度影响更大；最低频带权重更高；谱和时间权重在该实验中可分离，时间权重跨频带相近 | 只支持把谱内压缩与跨帧活动指数拆开做敏感性分析；不支持把实验权重直接用于全曲歌单排序 | 全文（开放期刊） |
| 2023-02 / 2023-10 | Wang et al., *Personalized Audio Quality Preference Prediction*，arXiv 2302.08130；Miller & Downey, *Listener Preferences for High-Frequency Response of Insert Headphones*，JAES 71(10) | Wang：7 首 10–15 s 片段、5 手机、2 音量；31 名受试者，清洗后 23、2,000 对标签。Miller：插入式耳机 10 kHz 以上盲听目标，按听阈分组；作者白皮书补充定制高频耳机、RA0401、约 80 dB SPL、4 首典型流行歌曲 | Wang：加入年龄、性别、耳机规格只将准确率从 77.56% 提到 78.04%。Miller：偏好高频能量高于旧目标，年龄相关听力下降者偏好更多高频 | 记录听者、设备、音量和听阈上下文；高频独立证据，不加入普适奖励；不把模型准确率当本项目可信度 | Wang 全文预印本；Miller JAES 摘要 + 作者材料 |

## 逐项研究记录

### 1. 目标曲线：2013 AES 目标响应比较

Olive、Welti 与 McMullin 于 2013 年 5 月发表 AES 134 Paper 8867。官方摘要写明，研究针对**立体声录音**做两个双盲试听，让训练听者在两个耳机型号上评价 8 条目标响应。候选包括 ISO 11904-2 的 diffuse-field/free-field、Lorho 修改的 diffuse-field、未均衡耳机，以及基于参考房间校准扬声器测量的新目标。两个耳机上，新目标都最受偏好。[AES 原始条目](https://aes.org/publications/elibrary-page/?id=16768)

这项研究能支持“人口级 stereo 参考档案有实验来源”，不能支持“所有歌曲都应向同一目标靠拢”。摘要没有提供本轮所需的完整样本数、每首节目长度、绝对电平和听者人口结构；这些字段在本文中明确记为未知。实验终点是耳机目标的总体偏好，而不是针对歌曲的耳机—歌曲配对。

对共鸣的直接用法是：把 `stereo_population_target` 作为一条带来源的参考，并保留 `flat`、用户目标和其他目标为不同档案。`D` 越小只能解释为“相对该目标更接近”；不能把它显示成“歌曲喜欢分”。

### 2. 人口差异：2015 年 249 名听者的 bass/treble 调整

Olive 与 Welti 于 2015 年 10 月发表 AES 139 Paper 9382。249 名听者用方法调整，把耳机在耳膜参考点（DRP）处的相对 bass 和 treble 调到个人偏好；起始响应被均衡到参考房间中平稳扬声器的响应。每人对 3 个 stereo 音乐节目重复 5 次；样本包含不同年龄、性别、听音经验和国籍。官方摘要报告：节目、年龄、性别和先前听音经验都会影响偏好的 bass/treble；年轻、经验少者平均偏好更多 bass 和 treble，女性平均偏好少于男性。[AES 原始条目](https://secure.aes.org/forum/pubs/conventions/?elib=17940)

它对本模型最关键的不是某个平均 dB 数，而是偏好分布本身。一个人口平均目标可以作为起点，但不能当作用户目标。方法调整也只覆盖两个低维 shelf 参数，不能证明用户偏好的窄带峰、耳增益、声场或空间重放偏好已被解释。

可转用：用户校准应先学习低维 residual（例如低频 shelf、高频 shelf 或总体倾斜），并保存年龄/听音经验等上下文作为解释字段；没有用户试听标签时，不进行人口差异补偿。不可转用：不能把“年轻人平均多 bass”写成对某首歌的固定频率加权。

### 3. 低频、响度与密封：2016 年 IE 低频目标研究

Olive、Welti 与 Khonsaripour 于 2016 年 8 月在 AES International Conference on Headphone Technology 发表 Paper 6-1。10 名训练听者调整应用于高质量 IE 的二阶低架滤波器，任务覆盖 bass 增益和转折频率；使用 3 个音乐节目，并比较有无响度归一化与漏声控制。[AES 原始条目](https://aes2.org/publications/elibrary-page/?id=18369)

官方摘要明确把节目、个体差异、响度归一化和漏声作为影响低频偏好的因素。公开全文摘要/作者稿的实验描述显示，测试方法会改变偏好设置，节目对 preferred level 的影响比对 frequency 更明显。研究对象是 IE 的低频目标，不能外推到所有耳机或整首歌曲的总体偏好。

可转用：低频偏差结果必须携带 `levelMatched`、`leakageControlled`、耳机类型和测量条件；不同夹具/佩戴之间只能作相对估计。不可转用：把当前 PCM 电平或全局 `g` 当成耳膜 SPL，再把低频能量直接映射为“更讨喜”。

### 4. 虚拟耳机方法：2016 年真实/虚拟 IE 验证

Welti、Olive 与 Khonsaripour 于 2016 年 9 月发表 AES 141 Paper 9658。10 名训练听者评价 12 个 IE 的真实版本，以及用双耳录制并在一副复现耳机上重放的虚拟版本。官方摘要报告，虚拟耳机产生的总体音质评分与真实耳机相近。[AES 原始条目](https://secure.aes.org/forum/pubs/conventions/?elib=18462)

这项结果只验证了在该测试链路、该听者群体和 IE 对象上，虚拟化方法可以近似真实比较；它没有验证歌曲推荐，也没有保证任何频响曲线、佩戴或漏声都能被同样准确地虚拟。可转用：未来做用户 A/B 时，可以考虑在同一复现耳机上切换曲线以降低硬件成本，但应先做本地复现验证；不可转用：把“虚拟等效”当作未经试听校准的频响—喜好模型。

### 5. 节目材料：2017 年 10 个音乐节目的 IE 研究

Olive、Welti 与 Khonsaripour 于 2017 年 5 月发表 AES 142 Paper 9778。10 名训练听者评价 8 个 IE，使用 10 个音乐节目；采用虚拟耳机方法，双盲呈现，并监测/消除耳机漏声。官方摘要报告，耳机是声音质量评分的主要效应，节目总体主效应和交互不显著；但不同节目在区分度和可靠性上不同，关键因素是节目频谱带宽与听者熟悉度。含有多少 bass 也会影响对 bass 过多或不足耳机的评价。[AES 原始条目](https://aes.org/publications/elibrary-page/?id=18654)

这里的“节目主效应不显著”不能被解读成“歌曲不重要”。它说明在该测试和目标问题下，不同节目没有系统性地整体抬高或压低所有耳机评分；同时，节目仍然改变了测试是否能区分耳机、结果是否可靠。对歌单算法，最稳妥的转译是**内容覆盖与稳定性指标**：

- 记录每个频带的 `bandEnergyShare`、`validFrameRatio` 和共同频段状态；
- 把歌曲切成多个有内容的片段，分别计算 D/C/Dhigh；
- 报告片段排名的稳定性和分数离散度；
- A/B 验证集需要多种频谱带宽，不能只用一首熟悉歌曲；
- 熟悉度影响评分时，应作为试听实验的协变量记录，而不是写进频率权重。

不可转用：把“流行、摇滚、人声”等 genre 作为隐藏先验，或者因为一首歌低频能量高就自动提高低频耳机的喜好分。

### 6. IE 静态耳机偏好模型：2017 AES 143

Olive、Welti 与 Khonsaripour 在 AES 143（2017 年 10 月）发表两篇配套论文：Part 1 Paper 9840 和 Part 2 Paper 9878。Part 1 的官方摘要写明，30 个 IE、71 名训练与非训练听者、100 分偏好尺度、隐藏高参考和低锚点，使用虚拟耳机匹配测量到的幅度响应并监测漏声；训练和非训练听者都偏好新的 IE 目标，偏离越大总体越不受偏好。Part 2 的摘要报告用目标偏差的大小、标准差和斜率建立线性回归，摘要给出 (r=0.91)。[Part 1 AES](https://secure.aes.org/forum/pubs/conventions/?elib=19237) · [Part 2 AES](https://secure.aes.org/forum/pubs/conventions/?elib=19275)

这两篇论文支持一个窄范围命题：在受控电平、受控 IE 佩戴和选定节目下，静态耳机频响相对目标的宏观偏差与总体耳机偏好存在关系。它们没有证明同一关系可预测“哪首录音在某耳机上更喜欢”。

可转用：保留 `D` 作为参考偏离；把耳机频响的宏观倾斜和离散度当作解释证据。不可转用：不移植线性回归系数、(r) 或 100 分量表作为本地歌单的喜欢概率；不同测量夹具、耳机类别、节目和用户都会改变外推条件。

### 7. 窄带共振是宏观模型的盲区：2018 AES 144 AE/OE 全文

Olive、Welti 与 Khonsaripour 于 2018 年 5 月发表 AES 144 Paper 9919。本文本轮取得并阅读了公开的 AES advance manuscript；稿件首页明确说明完整稿未经过同行评议，因此把它作为受控实验报告，不把其模型当作外部标准。

实验包含 130 名 Harman 员工听者（28 trained、102 untrained）、31 个 AE/OE 型号、18 个制造商，价格约 $60–$4,000，开放/封闭、动圈/平板、无线和 ANC 型号都有。5 个测试每个包含 3 个节目和 2 次观察；每次用 8 个虚拟耳机（含高锚点和低锚点），共 31,200 个评分。相对电平按 ITU-R BS.1770-4 匹配，绝对电平约为 85 dB slow C-weighted 等效扩散场；复现曲线到约 12 kHz 做到约 ±1 dB，作者在更高频率没有激进均衡。目标曲线在综合结果中被偏好，训练听者约束更强，节目和性别效应较小但存在交互。

论文用响应偏差的标准差（SD）和绝对斜率（AS）建立模型，报告全模型 (r=0.86)、RMSE 约 6.7 个偏好分。两个离群耳机有 1–2 个中 Q 窄带共振，作者明确指出 SD/AS 在宽频带平均误差时低估了这类局部峰。论文也列出局限：没有模拟非线性或 excess phase，没有噪声环境和漏声影响，结果来自虚拟方法而非各种真实佩戴。

对共鸣的直接动作是增加独立的 `localResonanceEvidence`：例如在有足够曲线重复性和频率分辨率时，报告局部峰幅度、带宽、持续占用和对 D 的贡献；曲线测量不确定时把它降为不确定证据。不要把窄峰证据直接乘进一个总分，也不要用这篇论文的 headphone-level 系数预测歌曲喜欢概率。[AES 原始条目](https://aes.org/publications/elibrary-page/?id=19436) · [公开稿镜像（供全文核对）](https://www.docdroid.net/file/download/enYZsTS/a-statistical-model-that-predicts-listeners-preference-ratings-of-around-ear-and-on-ear-headphones-pdf.pdf)

### 8. 听者分群：2019 AES 146

Olive、Welti 与 Khonsaripour 于 2019 年 3 月发表 AES 146 Paper 10156。论文重分析前述 IE 与 AE/OE 受控测试，覆盖训练和非训练听者；官方摘要说明两组平均上都偏好接近 Harman 目标的曲线，但研究进一步用 cluster analysis 找到相似评分的听者类别，并探索年龄、性别、听音经验和声学因素。[AES 原始条目](https://secure.aes.org/forum/pubs/conventions/?elib=20289)

摘要没有给出本轮需要的合并样本数、聚类数和每一类的稳定性，因此不把类别比例写入模型。它的可转用结论是“群体平均不等于所有人”：用户目标应由同一用户的受控标签逐渐学习，且需要收缩到人口目标以避免少量试听过拟合。不可转用：用两个被喜欢的耳机（例如 HE1 与 Alter Ego）插值成一条完整个人曲线；两个样本最多证明两个偏好观测点。

### 9. 个性化反馈的测试方法：2019 AES 147

Welti、Khonsaripour、Olive 与 Pye 于 2019 年 10 月发表 AES 147 Paper 10247。官方摘要说明，研究比较四种收集听者主观 EQ 偏好的方法，目标是为移动端个性化选择在速度、准确度和易用性之间更合适的方法；四种方法都让受试者设置 bass/treble shelving filter。[AES 原始条目](https://aes.org/publications/elibrary-page/?id=20620)

AES 摘要和大会报告没有公开本轮所需的完整样本、测试时长和统计数值，本文只把它作为交互方法证据。它支持先做低维、快速、可回放的反馈，不支持直接训练全频、跨歌曲的偏好模型。对于本地工具，最小反馈协议应保存：歌曲/版本、耳机 A/B、相对电平是否匹配、播放 EQ/空间效果状态、用户选择、是否重听，以及反馈前后曲线档案。

### 10. 内容类型改变目标：2020/2022 Engel 等

Engel、Alon、Scheumann、Crukley 与 Mehra 的研究先在 2020 年 AES AVAR 公开，后以 JAES 70(4)（2022 年 4 月，DOI `10.17743/JAES.2022.0005`）发表。官方摘要报告三个试听测试，每个超过 20 名听者，比较 7 条目标响应、2 个耳机和 2 个重放带宽；空间版本把相同立体声内容与实测、个体 BRIR 卷积，另有 stereo 条件。空间内容偏好 flat，stereo 内容偏好 Harman；个体化 EQ 时差异更强，耳机和重放带宽对该效应没有显著影响。[JAES 原始条目](https://secure.aes.org/forum/pubs/journal/?elib=21564) · [开放 AES 论文页](https://www.aes.org/e-lib/download.cfm/21564.pdf?ID=21564)

这项研究直接约束“多参考取最小值”：如果内容类型不同，最小值可能只是把不同问题混在一起。共鸣应保存 `contentCondition`；普通 stereo 歌曲可以使用 stereo 目标，空间/BRIR 歌曲必须另算或暂不混排。若产品暂时只处理 stereo，应在结果页明确这一条件，而不是暗示 Harman/flat 适用于所有渲染。

### 11. 时间与频带权重：2012 PLOS ONE Oberfeld 等

Oberfeld、Heeren、Rennies 与 Verhey 于 2012 年 11 月 28 日在 PLOS ONE 发表开放论文。研究在 Mainz 和 Oldenburg 各 5 名正常听力听者，共 10 人；使用经校准的 Sennheiser HDA 200，刺激是总有效时长约 1,000 ms（含重叠后 1,020 ms）的三组噪声带：低频约 200–510 Hz、中频约 1,080–1,720 Hz、高频约 3,150–5,300 Hz，各带 3 Bark 宽，每 100 ms 施加独立随机电平变化。通过单带、宽带和三带联合条件估计谱权重与时间权重。[PLOS ONE 全文](https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0050184)

实际结论是：前 300 ms 对总体响度的影响比后续片段更强；最低频带贡献显著高于更高频带；时间权重在三条频带间没有显著不同；单独测得的谱权重与时间权重和联合条件相近，作者据此认为在该实验条件下二者可以分离。研究的是短时、校准 SPL 的随机噪声识别任务，不能直接当成音乐、整曲或用户喜欢程度模型。

对共鸣最小可转用方式是把两个工程参数分开：

- `alphaSpectrum`：现有频带内能量压缩，默认继续为 0.3；
- `temporalActivity`：跨帧的内容占用/活动权重，新增为旁路敏感性分析而非默认喜好权重。

本轮源码已实现以下独立情景诊断：基准 `(0.3,0.3)`、`(0.2,0.3)`、`(0.5,0.3)`、`(0.3,0)`、`(0.3,1)`；每次只改变一个参数，输出每条参考的情景分数和最佳参考是否翻转。本轮尚未实现分段/top-k 稳定性。这里的 `.2/.5/0/1` 都是工程探针，不是从文献推导的最优值，也不是人耳幂律。不能把“前 300 ms 更重”直接应用到整首歌开头，不能把低频在噪声实验中的权重变成歌曲低频奖励，也不能把变化解释成听感置信区间。

### 12. 高频和听阈：2023 Miller & Downey

Miller 与 Downey 于 2023 年 10 月在 JAES 71(10), pp. 707–718 发表《Listener Preferences for High-Frequency Response of Insert Headphones》，DOI `10.17743/jaes.2022.0094`。论文摘要写明，研究用盲听目标研究插入式耳机 10 kHz 以上的偏好；相较于此前流行目标，听者偏好显著更多的高频能量，而且偏好受听阈影响，年龄相关高频听力损失的听者更偏好额外高频增益。[AES 原始条目](https://aes2.org/publications/elibrary-page/?id=22242) · [DOI](https://doi.org/10.17743/jaes.2022.0094)

论文摘要没有列出完整样本数。本轮作为作者公开补充材料读取了 Knowles 的白皮书：作者报告约 70 名听者，使用带 7 mm 动圈低音单元和 Knowles WBFK 高音单元的定制 IE，配 RA0401 阻尼耳模拟器及漏声检查 MEMS 麦克风；测量每个人的高频听阈，目标试听约 80 dB SPL，选取 4 首频谱接近 Billboard Hot 100 近 20 年平均、含人声和镲片的歌曲。白皮书是作者/厂商材料，实验条件可用于理解论文，不替代 JAES 论文的审稿证据。[Knowles 作者公开白皮书](https://www.knowles.com/docs/default-source/default-document-library/preferred-response-white-paper-v012624.pdf)

这项研究支持把 10–20 kHz 作为独立证据，并在用户层面记录高频听阈或用 A/B 反馈校准；不支持把高频增益加入所有歌曲和所有耳机的统一奖励。IE 深插、耳模拟器、高频驱动和歌曲选择都限制了外推；20 kHz 以上仍不应外推为普遍可听或更好。

### 13. 设备/听者信息的个性化预测：2023 Wang 等

Wang、Lin、Hsu 与 Jang 的 arXiv 预印本发表于 2023 年 2 月 16 日。研究用 7 个来自英语、普通话、日语和韩语流行歌曲的 10–15 s 片段，通过 5 部手机、每部两个音量录制；31 名受试者完成两两选择，清洗设备规格缺失和无偏好答案后剩 23 名受试者、2,000 对标签。模型用 Siamese 网络比较同一片段在不同设备上的质量，并加入年龄、性别、耳机/耳塞阻抗、频响上下限和灵敏度；加入完整主体信息后准确率从 77.56% 提高到 78.04%。[arXiv 全文](https://arxiv.org/abs/2302.08130)

它不是耳机频响目标曲线论文，也不是歌曲推荐验证；年龄样本集中、耳机规格来自互联网、手机录音和实际个人耳机链路与共鸣不同。因此可转用的只有数据设计：用户标签必须同时记录听者、耳机/设备、音量和内容上下文；不可转用其准确率作为共鸣的模型可信度或“喜欢概率”。

## 2024–2026 的检索更新与研究成熟度

本轮检索截止 2026-09-29；没有把“每一年都有同等数量的直接研究”当作事实。2024–2026 的直接相关证据主要集中在个体耳道/密封测量、空间音频目标和动态评价，尚未出现一条经过跨设备、跨曲目、跨听者验证的通用“耳机频响 × 歌曲喜好”模型。

### 2024：个体耳道与密封测量继续成为瓶颈

Bezzola、Celestinos 与 Souza-Blanes 于 2024 年 6 月发表 AES 156 Express Paper 239《Personalized Equalization of Sound Pressure at Eardrum With Insert Earbuds》。官方摘要指出，耳道几何差异会使真实耳膜压力与耳模拟器目标相差数 dB，耳塞密封尤其影响低频；论文用耳塞端近场麦克风估计近场到耳膜的个体传递函数，并在听音测试中比较个体 EQ、假人/耳模拟器 EQ 和未均衡默认声，个体 EQ 平均偏好达到统计显著。[AES 原始条目](https://aes.org/publications/elibrary-page/?id=22585)

摘要没有公开样本数、曲目清单和完整统计量，因此不补这些数字。可转用结论是：跨测量夹具的 FR 差异不能当作用户耳膜差异的直接代理；如果没有个体耳道/密封测量，结果应保持“参考偏离”语义。不可转用结论是：不能把这项个体 EQ 的偏好结果直接加进 PCM 歌曲排序。

### 2025：空间音频目标仍在实验与方法讨论阶段

Mülleder、Meyer-Kahlen 与 Frank 于 2025 年 5 月发表 AES 158 Express Paper 352《Towards a Headphone Target Curve for Spatial Audio》。官方摘要说明，论文重新讨论 Harman 曲线源自特定房间扬声器响应这一事实，质疑同一目标是否适用于空间音频；随后比较不同目标在 spatial 与 stereo 条件下的偏好。[AES 原始条目](https://aes.org/publications/elibrary-page/?id=22903)

这是 Express Paper；公开摘要没有提供完整样本、目标数量、带宽或统计结果。本轮只把它作为“空间目标仍需单独验证”的成熟度证据，不把它作为新通用目标，也不改变当前 stereo 路径。

### 2026：动态内容的总体分数可能掩盖局部变化

Porysek Moreta 等于 2026 年 4 月在 JAES 发表《Continuous and Overall Evaluation of Spatial Audio Reproduction Systems With Spatially Dynamic Content》。研究比较连续评价与总体评价，在 stereo 和 3D surround 两个系统上对 basic audio quality 与 surrounding 两个属性评分；官方摘要报告，系统、空间变化和节目都会影响评分，评价方式本身也会影响结果，连续评价能捕获总体评价丢失的时间变化。[AES 原始条目](https://aes.org/publications/elibrary-page/?id=23134)

该研究不是耳机频响目标研究，也没有证明连续评价更接近“喜欢歌曲”。它支持当前的最小工程方向：整曲 D/P90 旁边保存分段或活动窗口证据；如果片段排名翻转，直接展示跨度和翻转，不把它硬贴成“可靠/不可靠”二元标签。

截至本次检索，2024–2026 的证据进一步加强了两条边界：测量个体化需要真实耳道/密封信息，节目/空间动态需要时间分段；它们都没有授权在无 SPL、无用户试听标签的情况下添加固定频率喜好权重。

## 并行 scout 补充：听觉滤波、拟合变化与标准边界

下面几项由并行 `hearing_model_research` / `measurement_uncertainty_research` scout 提供。本轮只核对公开摘要、官方条目或开放全文链接，未把它们当作本轮逐页全文复核的核心研究；因此在此集中写出“可借鉴的边界”，不把未核验的统计细节带入代码或用户文案。

| 年月 | 原始来源与已核对条件 | 可用于本项目的边界 | 阅读层级 |
|---|---|---|---|
| 2006-01 | Oxenham & Simonson, *Level dependence of auditory filters in nonsimultaneous masking as a function of frequency*, JASA 119, 444–453, DOI [10.1121/1.2141359](https://doi.org/10.1121/1.2141359)；1、2、4、6 kHz，10–35 dB SL，缺口噪声掩蔽；开放 PMC [全文入口](https://pmc.ncbi.nlm.nih.gov/articles/PMC1752201/) | ERB/听觉滤波器带宽依赖信号电平和中心频率；固定 ERB 几何可作为频带组织，不应直接当成无 SPL 的听觉权重或 loudness 模型 | scout 摘要/开放稿入口，本轮未逐页复核 |
| 2011-07 | Valente, Joshi & Jesteadt, *Temporal integration of loudness measured using categorical loudness scaling and matching procedures*, JASA Express Letters 130, EL32–EL37, DOI [10.1121/1.3599022](https://doi.org/10.1121/1.3599022)；4 名受试者，1 kHz、5/200 ms | 短时刺激的响度整合与全曲音乐时序不是同一个对象；不能把极短刺激实验的时间权重直接替换当前整曲权重 | scout 官方摘要 |
| 2011-10 | Völk & Fastl, *Locating the Missing 6 dB by Loudness Calibration of Binaural Synthesis*, AES 131 Paper 8488；讨论不同耳机/均衡和耳机—扬声器同响比较 [AES](https://secure.aes.org/forum/pubs/conventions/?elib=16014) | “同样数字电平/同样声压就同样响”需要呈现方式、耳机传递函数和参考场景；当前无耳膜 SPL 时保留相对谱语义 | scout 摘要；作者公开稿可查，本轮未全文复核 |
| 2014-05 | Völk, *Inter- and Intra-Individual Variability in the Blocked Auditory Canal Transfer Functions of Three Circum-Aural Headphones*, JAES 62, 315–323, DOI [10.17743/jaes.2014.0021](https://doi.org/10.17743/jaes.2014.0021)；3 个耳机 specimen；摘要报告 6 kHz 以上个体/重复放置变化可达约 10 dB、群延迟约 0.5 ms [AES](https://aes.org/publications/elibrary-page/?id=17242) | 10 kHz 以上的曲线细差异必须有夹具、佩戴和重复性元数据；小于测量跨度的差异不应强排序 | scout 官方摘要 |
| 2015-06 | Paquier & Koehl, *Discriminability of the placement of supra-aural and circumaural headphones*, Applied Acoustics 93, 130–139, DOI [10.1016/j.apacoust.2015.01.023](https://doi.org/10.1016/j.apacoust.2015.01.023)；4 个耳机模型、每个 8 次真实放置；粉红噪声和两段音乐；专家/非专家 3I3AFC | 放置导致的频谱变化在多数条件下可听；应把“不同测量夹具/放置”的跨度作为诊断，不能把一次 FR 当作用户耳边固定响应 | scout 官方摘要/开放检索页 |
| 2016-04 | Paquier, Koehl & Jantzem, *Effect of headphone position on absolute threshold measurements*, Applied Acoustics 105, 179–185, DOI [10.1016/j.apacoust.2015.12.003](https://doi.org/10.1016/j.apacoust.2015.12.003)；HD600 与 TDH39，125 Hz–14 kHz，多次放置/不放置 | 整体结果不支持简单断言“高频必然更不可靠”；模型、频率和受试者会改变放置效应。应报告实际跨度和最佳参考是否翻转，不硬贴可靠/不可靠标签 | scout 官方摘要 |
| 2021 | Nordby, Stegenborg-Andersen & Zacharov, *Predicting Audio Quality for different assessor types using machine learning*, AES Paper 10494；22 个不同质量/特征的耳机；正常听力与轻/中度听力损失听者组 | 听力损失组内评分可一致，但不同听力群体对设备的评价和排序会系统变化；不能把正常听力人口目标直接代替听阈未知用户 | scout 官方 AES 摘要 [AES](https://aes.org/publications/elibrary-page/?id=21087) |
| 2017/2023 | [ISO 532-1:2017](https://www.iso.org/standard/63077.html)、[ISO 532-2:2017](https://www.iso.org/standard/63078.html) 和 [ITU-R BS.1770-5:2023](https://www.itu.int/rec/R-REC-BS.1770-5-202311-I) | ISO 响度方法要求相应输入校准；BS.1770 的 LKFS 是数字满刻度基准，不是耳边 SPL。它们不能直接提供当前歌曲匹配的个人偏好标签 | 标准官方页面和公开预览；不作为本轮经验样本 |

共同可行动结论是：如果 `referenceSpread`、曲线重测跨度或放置差异与当前情景差值接近，只显示跨度、最佳参考是否翻转和“结果对测量/参数敏感”；不要自行把某个比值命名为可靠性阈值。本轮不新增总分，也不把这些 scout 研究的统计结果转成用户置信度。

## 研究之间的共同结论

### 目标曲线是条件化的参考，不是自然常数

2013 的 stereo 目标比较、2015 的人口差异、2019 的听者分群和 2022 的 stereo/spatial 对比共同说明：目标曲线的含义至少包含三层：

| 目标层 | 能回答 | 不能回答 |
|---|---|---|
| 测量/坐标参考 | 曲线在某个测量体系下如何比较 | 它是唯一正确的听感 |
| 人口平均偏好 | 一组条件下总体偏好哪类响应 | 每位用户、每首歌都应靠近它 |
| 用户目标 | 此用户在同一链路和内容下实际选择什么 | 少量喜欢耳机足以重建全频目标 |

因此 `HE1`、`Alter Ego` 可以保留为两个完整的用户选择参考样本，但不能在没有 A/B 数据时合成为一个“个人目标”。多参考 `min` 只能表示“在当前候选参考集合中，最接近哪条完整参考”；它不等于用户已验证的偏好。

### 节目材料不等于语义标签

2017 IE 节目研究没有找到显著的节目总体主效应，却找到频谱带宽、低频内容、熟悉度对区分度/可靠性的影响。最稳妥的产品化方式是让歌曲的真实内容决定其**证据是否充分**，而不是让“摇滚”“女声”“古典”等文本标签进入频率权重。若未来收集试听标签，节目标签可以作为分析协变量，但不应成为未经校准的隐含偏好先验。

### 静态 FR 模型不能替代歌曲—耳机试听

2017/2018 的 Harman 论文在受控电平、受控曲线、虚拟耳机和有限节目下预测的是**耳机总体偏好**。它们可以支持当前 `D` 作为相对参考偏离，但不支持以下迁移：

- 把 (r=0.91) 或 (r=0.86) 写成歌曲匹配准确率；
- 把 100 分耳机偏好刻度变成歌单分数；
- 把 `SD`/`AS` 线性系数直接乘到每首歌 PSD；
- 忽略窄带共振、漏声、噪声、佩戴、非线性和超额相位。

### 时间权重是实验情景，不是当前默认响度模型

Oberfeld 2012 的 1.02 s 噪声实验说明人类的总体响度判断可以对时间和频带不等权，但研究刺激并非歌曲，且有明确 SPL、听阈匹配和校准耳机。它适合用来设计离线敏感性分析，不适合在当前无 SPL 的工程分数上加入“人耳修正”。

## 对当前模型的最小改进规格与本轮实现边界

### A. 参考条件化而不是无条件最小值

保留现有逐参考计算。新增或补充结果元数据：

```text
referenceID
referenceKind = flat | stereo_population | spatial_flat | user | custom
contentCondition = stereo | spatial_brir | unknown
overallDeviationDB
highFrequencyDeviationDB
referenceRankMarginDB
```

`bestReferenceID` 仍可以用于界面排序，但当 `contentCondition=unknown` 或参考类型不可比较时，应显示“参考条件未知”，不要把 min 解释为用户偏好。后续如果接入 spatial/BRIR 音频，再单独计算 spatial 目标；当前普通 stereo 歌曲不需要为了未来条件修改现有分数。

### B. 分段稳健性旁路

不改变当前整曲 D/C/Dhigh 的默认排序，增加以下只读特征：

```text
segmentCount
segmentValidFrameRatio
segmentBandEnergyShare
segmentDeviationDB
rankStability  // 例如 top-k 一致率或 Kendall 相关，不写成置信区间
segmentSpreadDB
```

分段应避开纯静音，并保留“按已采片段估计”。如果只有一段有效录音，不生成伪造的稳定性结论；如果不同片段给出相反耳机排序，结果页标注“内容依赖/排序不稳定”，而不是继续给出单一“最适合”。

### C. 局部峰与测量不确定性分离

在现有 ERB 功率积分和全局 (g) 之外，记录：

```text
localPeakDeviationDB
localPeakBandWidth
localPeakOccupancy
curveMeasurementProvenance
curveUpperHz
fixtureOrCompensation
```

窄带峰只有在曲线来源、夹具和频率分辨率足够时才进入 `evaluated`；否则标为 `uncertain`/`insufficientResolution`。它是解释和风险证据，暂不与总体 D 以任意权重相加。

### D. 谱内压缩与跨帧活动分离（本轮源码已实现）

当前默认 `(alphaSpectrum=0.3, temporalActivity=0.3)` 作为可复现的历史默认保留；基线实现复用同一个压缩指数，本轮拆成独立参数。附加诊断分别改变：

1. `alphaSpectrum`：频带相对能量的压缩；
2. `temporalActivity`：帧的活动/持续占用权重。

本轮源码已实现以下独立情景诊断：基准 `(0.3,0.3)`、`(0.2,0.3)`、`(0.5,0.3)`、`(0.3,0)`、`(0.3,1)`；每次只改变一个参数，输出每条参考的情景分数和最佳参考是否翻转。本轮尚未实现分段/top-k 稳定性。这里的 `.2/.5/0/1` 都是工程探针，不是从文献推导的最优值，也不是人耳幂律。不要把这种结果称为听感置信区间或好听提升，也不要使用 Oberfeld 的短噪声时间权重作为全曲默认。

### E. 用户反馈优先于复杂模型

最小可验证反馈协议：

1. 选同一歌曲和同一片段，比较耳机 A/B 或两条 EQ 变化；
2. 随机化 A/B 顺序，记录用户是否重听；
3. 尽量用同一链路匹配播放电平；无法确认则保存 `levelMatch=unknown`；
4. 记录播放器 EQ、空间效果、耳机佩戴、环境噪声是否未知；
5. 先学习低频 shelf、高频 shelf、总体倾斜等低维 residual，向人口目标收缩；
6. 至少经过跨歌曲和跨片段复测后，才允许显示“更符合你的已记录偏好”，而不是概率百分数。

短期不需要训练神经网络。2019 AES 的个性化测试研究和 2023 Wang 预印本都表明，测试方法、用户/设备上下文和标签设计本身是前置问题；模型复杂度不是证据缺口的替代品。

本轮范围到此收束：A（参考条件）、B（分段稳健性）、C（局部峰/测量不确定性）和 E（用户 A/B）是后续研究方向；本轮源码只实现 D 的独立参数情景诊断，未把这些方向扩成新的总分或用户模型。

## 可以说与不能说

| 文案/结果 | 当前是否成立 | 需要的限定 |
|---|---|---|
| “这段录音在该耳机上相对目标增强/削弱了哪些频带” | 可以 | 有真实 PSD、有效曲线和共同频段；说明使用相对功率计算 |
| “这首歌在该耳机上更接近某条 stereo 参考” | 可以 | 写出参考、共同范围、测量来源和分段稳定性 |
| “该耳机最适合这首歌” | 不应作为已验证事实 | 需要用户标签、响度匹配、片段复测和内容条件 |
| “某 genre 天生适合某耳机” | 不成立 | 需要多首歌曲和受控试听；语义标签不进入当前声学公式 |
| “用了 ERB/alpha/P90，就等于做了人耳响度建模” | 不成立 | 当前是相对频谱工程 proxy，无 SPL、听阈和完整响度模型 |
| “高频延伸越多越好” | 不成立 | 受听阈、插入、夹具、录音带宽和内容影响；20 kHz 以上独立旁路 |
| “论文的 (r) 就是歌单预测准确率” | 不成立 | 论文预测的是受控测试中的静态耳机总体偏好 |
| “两个喜欢的耳机可以反推出完整个人目标” | 不成立 | 至少需要同一用户、多片段、响度尽量匹配的 A/B 反馈 |

## 当前输入能支持什么、待听测什么、无法由输入推断什么

| 结论层 | 当前真实 PCM + FR 输入能否支持 | 研究/实现状态 |
|---|---|---|
| 共同频段内的相对频带增强/削弱 | 支持，保留曲线有效范围、PSD、声道和覆盖状态 | 已有实现；是描述性声学证据 |
| 指定参考下的 D、Dhigh、P90、最差时间片 | 支持，前提是有共同频段和非静音内容 | 已有实现；不是响度或喜欢概率 |
| 多参考各自完整结果与最低偏离 | 支持 | 已有实现；应继续保留参考 ID 和条件 |
| 20 kHz 以上的实际扩展证据 | 部分支持 | 已有旁路；不进入主排序，不外推可听收益 |
| 分段/窗口排名稳定性 | 当前输入可计算，但需要新增独立诊断 | 待实现；研究支持保留局部变化 |
| `alphaSpectrum=.2/.3/.5` 与 `temporalActivity=0/1` 情景敏感性 | 当前频带/响应中间数据足以计算 | 本轮源码已实现；验证见 [TESTING.md](../../TESTING.md)，不叫置信区间 |
| 局部窄带峰、曲线来源与夹具不确定性 | 可部分计算；测量元数据缺失时只能标不确定 | 待补元数据和独立证据，不直接改总分 |
| ISO 226/532 的 phon/sone/标准 loudness | 不支持 | 缺耳膜 SPL、校准和完整适用条件 |
| 用户个人喜欢概率或跨歌曲偏好 | 不支持 | 需要同一用户的响度尽量匹配 A/B 标签；研究尚未验证当前模型可直接预测 |
| stereo 与 spatial 的统一参考 | 不支持 | 目标应按内容条件分层；spatial 研究仍在发展 |
| 由 HE1 + Alter Ego 两条曲线重建个人目标 | 不支持 | 只能作为偏好样本，不能补全用户曲线 |

本轮没有更新或重启主 App。Classic 左右 FR 抵消修复属于同轮代码审计成果；双声道独立曲线的旧结果不能直接作为新模型结果，验证时须区分新旧模型。没有重算用户的完整曲库或改动既有歌单。

## 证据等级与阅读限制

- **强**：开放同行评议论文或官方 AES/JAES 原始条目能直接支持研究对象和结论。包括 Oberfeld 2012、Engel 2022、Miller & Downey 2023、AES 官方摘要。
- **中强**：受控 AES 论文摘要或作者 advance manuscript；能支持研究设计与方向，但不能补摘要未给出的样本和统计。包括 2015、2016、2017、2019 AES 系列。
- **方法参考**：作者公开白皮书、预印本；可用来设计后续实验，不能替代同行评议结论。包括 Knowles 白皮书和 Wang et al. 2023 arXiv。

本轮没有把未读取全文的论文数字补进表格；具体缺失均以“摘要级”标记。尤其 2013/2015/2016/2017/2019 AES 会议论文部分页面只公开摘要或摘要级检索结果，不能据此推导未公开的 p 值、效应量、样本分层或完整曲线数值。

## 参考资料（2006–2026）

1. Olive, S.; Welti, T.; McMullin, E. (2013-05). *Listener Preferences for Different Headphone Target Response Curves*. AES Convention 134, Paper 8867. [AES](https://aes.org/publications/elibrary-page/?id=16768)
2. Olive, S.; Welti, T. (2015-10). *Factors That Influence Listeners’ Preferred Bass and Treble Levels in Headphones*. AES Convention 139, Paper 9382. [AES](https://secure.aes.org/forum/pubs/conventions/?elib=17940)
3. Olive, S.; Welti, T.; Khonsaripour, O. (2016-08). *The Preferred Low Frequency Response of In-Ear Headphones*. AES International Conference on Headphone Technology, Paper 6-1. [AES](https://aes2.org/publications/elibrary-page/?id=18369)
4. Welti, T.; Olive, S.; Khonsaripour, O. (2016-09). *Validation of a Virtual In-Ear Headphone Listening Test Method*. AES Convention 141, Paper 9658. [AES](https://secure.aes.org/forum/pubs/conventions/?elib=18462)
5. Olive, S.; Welti, T.; Khonsaripour, O. (2017-05). *The Influence of Program Material on Sound Quality Ratings of In-Ear Headphones*. AES Convention 142, Paper 9778. [AES](https://aes.org/publications/elibrary-page/?id=18654)
6. Olive, S.; Welti, T.; Khonsaripour, O. (2017-10). *A Statistical Model that Predicts Listeners’ Preference Ratings of In-Ear Headphones: Part 1*. AES Convention 143, Paper 9840. [AES](https://secure.aes.org/forum/pubs/conventions/?elib=19237)
7. Olive, S.; Welti, T.; Khonsaripour, O. (2017-10). *A Statistical Model that Predicts Listeners’ Preference Ratings of In-Ear Headphones: Part 2*. AES Convention 143, Paper 9878. [AES](https://secure.aes.org/forum/pubs/conventions/?elib=19275)
8. Olive, S.; Welti, T.; Khonsaripour, O. (2018-05). *A Statistical Model that Predicts Listeners’ Preference Ratings of Around-Ear and On-Ear Headphones*. AES Convention 144, Paper 9919. [AES](https://aes.org/publications/elibrary-page/?id=19436) · [公开稿](https://www.docdroid.net/file/download/enYZsTS/a-statistical-model-that-predicts-listeners-preference-ratings-of-around-ear-and-on-ear-headphones-pdf.pdf)
9. Olive, S.; Welti, T.; Khonsaripour, O. (2019-03). *Segmentation of Listeners Based on Their Preferred Headphone Sound Quality Profiles*. AES Convention 146, Paper 10156. [AES](https://secure.aes.org/forum/pubs/conventions/?elib=20289)
10. Welti, T.; Khonsaripour, O.; Olive, S.; Pye, D. (2019-10). *A Comparison of Test Methodologies to Personalize Headphone Sound Quality*. AES Convention 147, Paper 10247. [AES](https://aes.org/publications/elibrary-page/?id=20620)
11. Engel, I.; Alon, D. L.; Scheumann, K.; Crukley, J.; Mehra, R. (2022-04). *On the Differences in Preferred Headphone Response for Spatial and Stereo Content*. JAES 70(4), 271–283. DOI [10.17743/JAES.2022.0005](https://doi.org/10.17743/JAES.2022.0005) · [AES](https://secure.aes.org/forum/pubs/journal/?elib=21564)
12. Oberfeld, D.; Heeren, W.; Rennies, J.; Verhey, J. (2012-11-28). *Spectro-Temporal Weighting of Loudness*. PLOS ONE 7(11):e50184. DOI [10.1371/journal.pone.0050184](https://doi.org/10.1371/journal.pone.0050184) · [全文](https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0050184)
13. Miller, T.; Downey, C. (2023-10). *Listener Preferences for High-Frequency Response of Insert Headphones*. JAES 71(10), 707–718. DOI [10.17743/jaes.2022.0094](https://doi.org/10.17743/jaes.2022.0094) · [AES](https://aes2.org/publications/elibrary-page/?id=22242) · [作者公开材料](https://www.knowles.com/docs/default-source/default-document-library/preferred-response-white-paper-v012624.pdf)
14. Wang, C.-C.; Lin, Y.-C.; Hsu, Y.-T.; Jang, J.-S. R. (2023-02-16). *Personalized Audio Quality Preference Prediction*. arXiv:2302.08130. [全文](https://arxiv.org/abs/2302.08130)
15. Bezzola, A.; Celestinos, A.; Souza-Blanes, E. (2024-06). *Personalized Equalization of Sound Pressure at Eardrum With Insert Earbuds*. AES Convention 156, Paper 239. [AES](https://aes.org/publications/elibrary-page/?id=22585)
16. Mülleder, A.; Meyer-Kahlen, N.; Frank, M. (2025-05). *Towards a Headphone Target Curve for Spatial Audio*. AES Convention 158, Express Paper 352. [AES](https://aes.org/publications/elibrary-page/?id=22903)
17. Porysek Moreta, P. N.; Bech, S.; Francombe, J.; Østergaard, J.; van de Par, S. (2026-04). *Continuous and Overall Evaluation of Spatial Audio Reproduction Systems With Spatially Dynamic Content*. JAES 74(4), 199–211. [AES](https://aes.org/publications/elibrary-page/?id=23134)
18. Oxenham, A. J.; Simonson, A. M. (2006-01). *Level dependence of auditory filters in nonsimultaneous masking as a function of frequency*. JASA 119, 444–453. DOI [10.1121/1.2141359](https://doi.org/10.1121/1.2141359) · [PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC1752201/)
19. Valente, D. L.; Joshi, S. N.; Jesteadt, W. (2011-07). *Temporal integration of loudness measured using categorical loudness scaling and matching procedures*. JASA Express Letters 130, EL32–EL37. DOI [10.1121/1.3599022](https://doi.org/10.1121/1.3599022)
20. Völk, F.; Fastl, H. (2011-10). *Locating the Missing 6 dB by Loudness Calibration of Binaural Synthesis*. AES 131, Paper 8488. [AES](https://secure.aes.org/forum/pubs/conventions/?elib=16014)
21. Völk, F. (2014-05). *Inter- and Intra-Individual Variability in the Blocked Auditory Canal Transfer Functions of Three Circum-Aural Headphones*. JAES 62, 315–323. DOI [10.17743/jaes.2014.0021](https://doi.org/10.17743/jaes.2014.0021) · [AES](https://aes.org/publications/elibrary-page/?id=17242)
22. Paquier, M.; Koehl, V. (2015-06). *Discriminability of the placement of supra-aural and circumaural headphones*. Applied Acoustics 93, 130–139. DOI [10.1016/j.apacoust.2015.01.023](https://doi.org/10.1016/j.apacoust.2015.01.023)
23. Paquier, M.; Koehl, V.; Jantzem, B. (2016-04). *Effect of headphone position on absolute threshold measurements*. Applied Acoustics 105, 179–185. DOI [10.1016/j.apacoust.2015.12.003](https://doi.org/10.1016/j.apacoust.2015.12.003)
24. Nordby, J.; Stegenborg-Andersen, T.; Zacharov, N. (2021). *Predicting Audio Quality for different assessor types using machine learning*. AES Paper 10494. [AES](https://aes.org/publications/elibrary-page/?id=21087)
25. ISO 532-1:2017, *Methods for calculating loudness — Part 1: Zwicker method*. [ISO](https://www.iso.org/standard/63077.html)
26. ISO 532-2:2017, *Methods for calculating loudness — Part 2: Moore-Glasberg method*. [ISO](https://www.iso.org/standard/63078.html)
27. ITU-R BS.1770-5:2023, *Algorithms to measure audio programme loudness and true-peak audio level*. [ITU](https://www.itu.int/rec/R-REC-BS.1770-5-202311-I)

## 与已有研究文档的关系

本文件只新增 2006–2026 年原始研究与“如何限制歌曲匹配外推”的决策。ERB、ISO 226/532、Harman 目标的历史边界、扩展高频夹具和 20 kHz 以上旁路已在 [headphone-preference.md](headphone-preference.md) 与 [extended-high-frequency.md](extended-high-frequency.md) 中详细记录；本文件不把那些既有工程说明重复包装成新的实验发现。
