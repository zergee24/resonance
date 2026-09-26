# 扩展高频与 MEMS：对共鸣匹配算法的研究结论

本文只讨论两个问题：

1. 现有的 PCM 频谱和耳机频响，怎样把 10–20 kHz 以及 20 kHz 以上的信息用于匹配。
2. “MEMS 单元有更好的超高频能力”这类说法，哪些部分能由数据支持，哪些部分不能。

结论先行：10–20 kHz 应继续作为独立的可计算、可排序频段；20 kHz 以上应作为独立的“扩展频段证据”，按实际采样率、测量上限和能量可信度分段展示。扩展频段可以影响用户的解释和可选偏好，但默认不并入 D 或 Dhigh，也不能把曲线延伸到输入没有覆盖的频率。当前数据只能说明“某个播放链和夹具在某个频段输出了什么”，不能单凭频响证明超声可听、瞬态更快、MEMS 更好或某首歌一定更适合某种单元。

## 1. 证据能支持什么

### 1.1 10–20 kHz 是有意义但不稳定的 EHF 区域

扩展高频（extended high frequency, EHF）通常指 8 kHz 以上的听力测试频段。ISO 389-5 为特定耳机的空气传导纯音校准规定了 8–16 kHz 的参考等效阈声压级，说明这一区域可以做标准化测量，但这不是把普通消费耳机曲线直接转换成个人耳膜声压的许可。[ISO 389-5:2006](https://www.iso.org/standard/40535.html)

对健康人群的研究显示，EHF 阈值会随频率和年龄明显变化。18–64 岁人群的研究在 9–16 kHz 观察到随年龄上升而阈值恶化、可响应比例下降；研究还指出 ISO 7029 的常规参考只覆盖到 12.5 kHz。[Škerková 等，2023，PubMed](https://pubmed.ncbi.nlm.nih.gov/35763083/)

EHF 听力不是普通听力图的简单延长。Lough 和 Plack 的综述展示了两个在 8 kHz 以下阈值相近、但 16 kHz 阈值差异很大的听者，并指出耳道驻波、插入深度和校准会显著影响 EHF 结果。[Lough & Plack，2022，开放稿](https://eprints.lancs.ac.uk/id/eprint/166390/1/Lough_Plack_2022_EHF_JASA.pdf)

这对共鸣的含义是：10–20 kHz 有资格成为独立特征，但不能用一个“人类平均高频听力”把个体差异抹平。频响匹配结果应保留测量来源、有效频段、能量占比和不确定性，而不是把高频曲线上的每个小峰都当作确定的听感结论。

### 1.2 高频偏好可以研究，但它是偏好模型，不是听觉阈值模型

Miller 和 Downey 针对插入式耳机做了 10 kHz 以上的盲听偏好测试，并提出了更高频的目标响应；论文报告，偏好还会受到听者高频听阈影响，存在年龄相关听力下降的听者更偏好额外高频能量的情况。[Miller & Downey，2023，AES 开放稿](https://www.aes.org/e-lib/download.cfm/22242.pdf?ID=22242)，[DOI 10.17743/jaes.2022.0094](https://doi.org/10.17743/jaes.2022.0094)

这项证据支持共鸣保留“高频偏好”这个产品方向，但不支持把它变成统一加分项：

- 偏好研究的对象是听者在控制条件下对不同响应的评价，不是“高频越多越好”。
- 研究使用了高频性能较好的测量夹具和插入式耳机，不能直接推广到所有耳机、所有密封和所有测量曲线。
- 用户自己的高频听阈未知时，10–20 kHz 只能给出“歌曲在该段有多少内容、耳机在该段如何改变它”的声学说明。

另有研究发现，EHF 听力与噪声中语音识别有关，但这不等于 EHF 对所有音乐都具有同样的主观权重。[Motlagh Zadeh 等，2019，PubMed](https://pubmed.ncbi.nlm.nih.gov/31685611/)

因此，产品上可以把 10–20 kHz 命名为“扩展高频偏好/适配证据”，不要把它命名成“清晰度”“空气感质量”或人耳听感分数。

### 1.3 20 kHz 以上存在少数实验性检测结果，但不能据此宣称超声可听

Ashihara 等使用 2AFC 和自适应程序测量 2–28 kHz 的纯音阈值。15 名听者中，只有部分人在 24 kHz 得到阈值，而且阈值可高于 88 dB SPL；26 kHz 及以上并非所有人都能得到阈值。加入 20 kHz 低通噪声后，20 kHz 以上结果只变化几 dB，研究者用它检查了低频子谐波伪迹。[Ashihara 等，2006，DOI 10.1250/ast.27.12](https://doi.org/10.1250/ast.27.12)

这项结果的正确解释是：在特殊设备、很高声压和少数听者条件下，20 kHz 以上可以出现可检测现象；它不是日常音乐播放中“超声普遍可听”的证明，也不是 MEMS 单元优越性的证明。共鸣应把 20 kHz 以上显示为扩展证据，不输出“超声听感”“脑效应”或“更高频因此更好”的结论。

需要把空气传导和骨传导实验分开。骨传导超声研究回答的是另一种刺激路径，不能拿来证明普通耳机通过空气传导播放的 20 kHz 以上音乐成分可被普通听者听见。

## 2. 测量夹具和数据来源的边界

### 2.1 10 kHz 以上不能默认把 60318-4 当成人耳模型

IEC 60318-4 的官方说明明确写出：它用于插入式耳机的主要频段是 100 Hz–10 kHz；10 kHz 以上不再模拟人耳，但可以作为声学耦合器使用到 16 kHz。官方还提醒，耳道泄漏没有被模拟，真实耳朵之间存在较大差异。[IEC 60318-4:2010](https://webstore.iec.ch/en/publication/1445)

IEC 60318-8 是为高频测量设计的已知声学阻抗耦合器，官方范围到 16 kHz，目标是让扩展高频助听器和耳机测量具备较低的不确定性，但它也明确“不模拟人耳”。[IEC 60318-8:2022](https://webstore.iec.ch/en/publication/60602)

实际夹具配置会改变结论。一个针对 125 Hz–20 kHz 校准的研究发现，仅改变耳模拟器的麦克风配置就可能造成最多 6 dB 的响应差异，去掉保护网还会在高频产生约 15 dB 的凹陷。[Prendergast 等，2016，PubMed](https://pubmed.ncbi.nlm.nih.gov/27686113/)

个体耳道也会造成更大的差异。关于耳膜声压估计的研究报告，使用平均耳模拟器代替个体耳道时，误差可达到 15 dB。[Hudde 等，1999，PubMed](https://pubmed.ncbi.nlm.nih.gov/10530022/)

### 2.2 20 kHz 以上必须记录“夹具能力”，不能只看曲线末端

商业高频夹具可以提供更宽的可重复测量范围，但这属于具体产品和具体校准链的属性，不是所有 711/IEC 60318-4 曲线的共同属性：

- GRAS RA0401/02 的官方资料将有效范围扩展到 20 kHz，并说明传统 60318-4 在约 13.5 kHz 存在高 Q 共振；[GRAS 43AC-S4 / RA0401](https://www.grasacoustics.com/products/product/789-43ac-s4)
- GRAS RA0403/04 的官方资料给出 10–20 kHz ±2.2 dB、20–50 kHz ±3.2 dB 的转移阻抗容差，并明确它是与 IEC 60318-4 兼容的高频版本，不等于标准 60318-4 本身已经覆盖 50 kHz；[GRAS RA0403/04](https://www.grasacoustics.com/products/ear-simulator/product/804-ra0403)
- Brüel & Kjær Type 5128 的产品资料给出到 20 kHz 的左右耳跟踪指标优于 ±3 dB，并以 ITU-T P.58、IEC 60318-7 等为依据；[Type 5128 产品资料](https://www.bksv.com/-/media/literature/Product-Data/bp2573.ashx)

因此，耳机曲线导入时至少应保留以下元数据：测量夹具或耳模拟器、校准/补偿方式、有效上限、左右声道、插入/密封条件、平滑方式、来源链接和原始文件。没有这些字段时，曲线仍可以参与声学计算，但 10 kHz 以上尤其是 20 kHz 以上应标记为“来源不确定”，不能用小于测量不确定度的差异做强排序。

## 3. MEMS 能从频响推导什么，不能推导什么

### 可以推导

在同一夹具、同一校准和相近声压条件下，MEMS 耳机的频响可以支持：

- 是否在 10–20 kHz 有实际输出，输出是否持续到曲线有效上限；
- 10–20 kHz 的斜率、峰谷、带宽和相对参考偏差；
- 20 kHz 以上是否存在测量链能确认的扩展输出；
- 某首歌在这些频段是否有实际 PCM 能量，耳机响应是否会对这些能量产生较大相对改变。

厂商资料可以作为能力线索，但不能替代同一测量体系下的实测。例如 xMEMS 官方把 Cowell 标为 20 Hz–20 kHz，把 Montara Plus 标为 20 Hz–大于 40 kHz，并另列使用超声调制/解调原理的 Cypress。这些是产品规格和架构说明，不是共鸣可直接使用的听感或跨夹具比较结果。[xMEMS 产品页](https://xmems.com/memsspeakers/)

### 不能由频响单独推导

仅有幅度频响，不能可靠推导：

- “MEMS 瞬态更快”“解析力更高”“空气感更好”；
- 低失真、相位一致性、群延迟、瞬态恢复或空间指向性；
- 20 kHz 以上信号对某个用户可听；
- 单元架构本身优于动圈、平衡电枢或其他 MEMS 架构。

这些结论需要独立的失真、相位/群延迟、脉冲响应、最大声压、指向性、密封/负载和听者盲听数据。MEMS 资料也会展示结构共振而不等于可用音频带宽；例如 MEMS 研究会分别报告机械共振和 20 kHz 内的声压响应。共鸣应把“MEMS”保存为设备描述字段，默认不加入匹配分数或奖励。

## 4. 在现有 PCM + 频响输入上可直接实施的算法

### 4.1 先把三个范围分开

每次匹配都应同时维护三个范围：

1. **数学可表示范围**：PCM 的 Nyquist 上限 `sampleRate / 2`。
2. **实际共同测量范围**：PCM、耳机曲线和参考曲线的有效交集，并受曲线声明上限、夹具能力和补偿方式限制。
3. **有内容范围**：歌曲在目标频段实际存在的有效能量，不能因为没有能量就把频段外推为零。

Apple 对 Core Audio 的定义把采样率明确为每秒采样帧数；AES5 将 48 kHz 作为专业 PCM 的推荐采样率，并承认 96 kHz 适用于需要更高带宽或更宽松抗混叠滤波的场景。[Apple Core Audio](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/WhatisCoreAudio/WhatisCoreAudio.html)，[AES5-2018](https://aes.org/publications/standards-store/?id=14)

在不对抗混叠滤波器做额外假设的情况下，产品可按下表解释 PCM 上限：

| PCM 采样率 | 数学 Nyquist 上限 | 可以检查的扩展区域 | 默认解释 |
| --- | ---: | --- | --- |
| 44.1 kHz | 22.05 kHz | 20–22.05 kHz | 只能看到很窄的 20 kHz 以上尾段 |
| 48 kHz | 24 kHz | 20–24 kHz | 可显示 20–24 kHz，不能谈更高段 |
| 96 kHz | 48 kHz | 20–48 kHz | 可分成多个扩展证据段 |
| 192 kHz | 96 kHz | 20–96 kHz | 仍需确认录音链和耳机曲线真正覆盖 |

数学 Nyquist 不能证明录音里有真实的高频信息。抗混叠滤波器、编码器、播放器重采样和录音设备的带宽都可能更早截止。`frequencyValidity = mathematicalNyquist` 时，结果只能说“PCM 可表示到这里”；只有有测量链证据时才应使用 `measuredContent` 或 `chainValidated`。

### 4.2 计算分辨率和产品展示分辨率分离

计算继续使用 FFT 原始频率网格和曲线的对数插值，插值只发生在曲线真实测量范围内，不外推。当前产品展示可以保持：

- 20–200 Hz
- 200 Hz–2 kHz
- 2–10 kHz
- 10–20 kHz

20 kHz 以上单列扩展证据段。建议沿用现有的 1/3 倍频程式扩展边界：20–25、25–31.5、31.5–40、40–50、50–63、63–80、80–100 kHz；每个 nominal band 都显示实际交集。比如 48 kHz PCM 只显示实际 20–24 kHz 的部分覆盖，24–25 kHz 以上标为超出输入范围，而不是显示为零。

展示分区不能替代 FFT 分辨率。现有分析器按约 0.18 秒窗口选择二次幂帧长，在 44.1/48 kHz 下通常约为 8192 点，频率 bin 约 5–6 Hz；这足以支持 10–20 kHz 的细频率加权，但不应把单个 5 Hz bin 的尖峰当作可重复的听感事件。对于 20 kHz 以上，应优先看跨帧的稳健统计量，而不是单帧最大值。

### 4.3 保留全曲特征，同时降低弱能量误导

歌曲侧对每个频率 bin 或细网格保存全曲统计：中位能量、较高分位数（例如 P90）、有效帧占比和相对全频能量。高频分析至少输出：

```text
bandEnergyShare
validFrameRatio
inputUpperHz
sourceNoiseFloor / estimatedFloor（如可取得）
```

弱能量不要把整首歌判为不可评估，也不要将低于噪声底的数值硬解释成“没有高频”。建议使用三种状态：

- `evaluated`：共同频段、分辨率和有效能量都足够；
- `lowEnergy`：仍显示频谱/相对偏差，但明确该段对全曲结论权重很小；
- `unsupported`：输入、曲线或测量链没有覆盖，不能计算。

`lowEnergy` 仍可以给出 D、C 和频段说明；`Dhigh` 或扩展频段可为 `nil`/“弱证据”，但不能让整个歌曲的 20 Hz–20 kHz 结果消失。只有 `unsupported` 才不产生该段数值。这样既遵守“不能外推”，也避免小高频能量直接抹掉对用户有用的粗略答案。

### 4.4 匹配指标的分层

建议保持现有指标职责：

- `D`：20 Hz–20 kHz 的参考偏差，作为主排序指标；
- `Dhigh`：10–20 kHz 的独立偏差，单独显示和可选排序；
- `C`：歌曲谱形变化，描述耳机曲线对歌曲能量分布的改变；
- `Dext`（后续可选）：20 kHz 以上的扩展证据，只在 PCM、曲线和参考均有有效共同数据时计算。

默认不把 `Dext` 加回 `D` 或 `Dhigh`，也不因扩展频段更长而自动加分。只有用户主动打开“把扩展频段作为排序因素”，才允许以低权重、带证据状态的辅助排序参与，并且必须显示实际覆盖范围和测量可信度。

一个适合当前内核的扩展形式是：对每个频率 bin 使用歌曲能量作为权重，对 `headphoneCurve - reference` 做带内加权平均和稳健离散度；同时以 `validFrameRatio`、`bandEnergyShare` 和曲线/录音上限生成证据状态。这样不会把语义标签引入算法，也不会把“MEMS”品牌或单元类型变成隐含先验。

## 5. 对产品文案和结果页的约束

可以说：

- “该歌曲在 10–20 kHz 有较高/较低的实际能量占比”；
- “该耳机曲线在共同测量范围内相对参考有某种偏差”；
- “20–24 kHz 有可计算的扩展内容，但证据来自数学/测量范围，不能等同于可听度”；
- “本结果受夹具、密封、录音链、年龄和个体高频听阈影响”。

不应说：

- “20 kHz 以上人耳能听见”；
- “MEMS 的超高频一定更有优势”；
- “扩展频段越多，音质越好”；
- “曲线在 20 kHz 以上的尖峰就是空气感/解析力”；
- “录音有 Nyquist 到 48 kHz，所以歌曲真实包含 48 kHz 内容”。

## 6. 落地优先级

在现有 PCM、频响、细网格和 `FrequencyBand.expanded` 基础上，最小可行顺序是：

1. 为每个频段补齐 `inputUpperHz`、`validFrameRatio`、`bandEnergyShare` 和测量来源状态；
2. 保持 10–20 kHz 的 `Dhigh` 独立计算，改为显示“弱能量但仍有估计”，而不是阻塞整个结果；
3. 将 20 kHz 以上作为 `Dext/evidence` 旁路，按真实 Nyquist 和曲线范围做部分覆盖；
4. 在耳机资料中增加夹具/补偿/有效上限字段，对未知测量条件降低证据等级；
5. 最后才做用户可选的高频偏好排序，并通过盲听反馈校准权重；不把 MEMS 标签直接写入公式。

这条路径保留了超高频研究价值，也让产品在没有充分证据时仍能给出有限但诚实的结果。

## 参考资料

- [ISO 389-5:2006 — 8–16 kHz 听力计参考阈值](https://www.iso.org/standard/40535.html)
- [IEC 60318-4:2010 — 60318-4 耳模拟器频率范围与限制](https://webstore.iec.ch/en/publication/1445)
- [IEC 60318-8:2022 — 扩展高频声学耦合器](https://webstore.iec.ch/en/publication/60602)
- [Škerková et al., Extended high-frequency audiometry: hearing thresholds in adults](https://pubmed.ncbi.nlm.nih.gov/35763083/)
- [Motlagh Zadeh et al., Extended high-frequency hearing enhances speech perception in noise](https://pubmed.ncbi.nlm.nih.gov/31685611/)
- [Lough & Plack, Extended high-frequency audiometry in research and clinical practice](https://eprints.lancs.ac.uk/id/eprint/166390/1/Lough_Plack_2022_EHF_JASA.pdf)
- [Ashihara et al., Hearing threshold for pure tones above 20 kHz](https://doi.org/10.1250/ast.27.12)
- [Miller & Downey, Listener Preferences for High-Frequency Response of Insert Headphones](https://doi.org/10.17743/jaes.2022.0094) · [开放 PDF](https://www.aes.org/e-lib/download.cfm/22242.pdf?ID=22242)
- [Prendergast et al., Practical considerations for ear simulators in the extended high-frequency region](https://pubmed.ncbi.nlm.nih.gov/27686113/)
- [Methods for estimating the sound pressure at the eardrum](https://pubmed.ncbi.nlm.nih.gov/10530022/)
- [GRAS RA0403/04 Hi-Res Ear Simulator](https://www.grasacoustics.com/products/ear-simulator/product/804-ra0403)
- [Brüel & Kjær Type 5128 产品资料](https://www.bksv.com/-/media/literature/Product-Data/bp2573.ashx)
- [Apple Core Audio 对 PCM 与采样率的说明](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/WhatisCoreAudio/WhatisCoreAudio.html)
- [AES5-2018 — PCM 采样频率建议](https://aes.org/publications/standards-store/?id=14)
- [xMEMS 官方 MEMS 微型扬声器规格页](https://xmems.com/memsspeakers/)
- [Infineon IM72D128V01 MEMS 麦克风数据手册](https://www.infineon.com/assets/row/public/documents/24/49/infineon-im72d128-datasheet-en.pdf)
