# 耳机偏好、听觉模型与本地匹配算法研究

日期：2026-09-26
用途：为“共鸣”本地耳机—歌曲匹配模型确定可引用的科学边界。
范围：耳机目标曲线、等响度、临界带与 Bark、ERB/听觉滤波器、响度与掩蔽、Toole/Olive 偏好研究，以及在没有声压校准的 PCM + 耳机频响工具中的可落地部分。

## 0.3.0 实际采用

研究结论与当前实现需要分开看。0.3.0 实际采用的是：

- **ERB 连续几何分段**：20 Hz–10 kHz 使用 Glasberg–Moore ERB 宽度建立连续频带，10–20 kHz 使用较宽的工程带；这是按 ERB 宽度组织证据，不是完整的 auditory filter 或 ISO 响度实现。
- **逐带功率响应差**：在实际 FFT cell 与频带的重叠范围内积分 PSD，应用耳机相对参考的功率响应，得到每带的能量和 dB 偏差。
- **默认压缩**：每帧、每带的归一化能量使用默认 \(\alpha=0.3\) 的幂压缩；这是工程启发式，不是 sone、等响度或听阈模型。
- **谱带与时间归一**：主排名使用 20 Hz–20 kHz 共同范围；帧能量和帧内频带能量分别归一，结果保留真实 PSD、频带贡献和时间位置。
- **单一 global \(g\)**：每条参考曲线单独拟合一个整体电平偏移，RMS 偏差、10–20 kHz 指标和帧统计复用同一个 \(g\)。
- **高频独立**：10–20 kHz 单独输出；20 kHz 以上只作为扩展明细旁路，不参与最佳参考选择，也不自动解释为可听收益。
- **压缩帧能量加权 P90**：P90 使用压缩后的帧能量权重；`worst frame` 只是模型误差最大的时间片，不能解释为可听性、刺耳度或用户不适。
- **整条参考选择**：多条参考曲线逐条计算，`bestReferenceID` 取整体偏差最小的一条，不逐频拼接参考曲线。

研究阶段提出但 0.3.0 尚未实现的内容包括 log/median 聚合、独立的活动占用指标、基于用户 A/B 试听的偏好学习，以及 ISO 226/ISO 532 的 SPL 感知模型。它们是后续探索建议，不能当作当前产品已经具备的行为或证据。

## 结论先行

当前研究足以支持三个层次的结果：

1. **频谱变化证据**：给定实测耳机曲线、参考曲线和真实录音，可以计算歌曲在各听觉频带内受到的相对增强或削弱，以及这些变化出现在哪些时间片。
2. **参考偏离结果**：可以计算歌曲实际能量加权后的耳机响应与某个明确参考之间的谱形偏离。它回答“这首录音在这副耳机上偏离该参考多少”，不回答“用户一定更喜欢”。
3. **个体偏好模型**：只有在同一用户的受控、响度匹配试听数据积累后，才可以学习“这个用户在这些录音上更喜欢哪种变化”。人口平均目标曲线可以作为一个参考档案，不能替代用户档案。

Fletcher–Munson、ISO 226、Zwicker 和 Moore–Glasberg 的模型描述的是在特定声压、声场、听者和刺激条件下的听觉响应；它们不能把未经声压校准的数字 PCM 直接变成 phon、sone、听阈或“可听性概率”。[ISO 226:2023](https://www.iso.org/standard/83117.html) 明确规定了纯连续音、声压测量位置、正前方双耳听音和正常听力年轻听者等条件；这已经说明它不是一条脱离条件的“人耳 EQ 曲线”。

对本工具最稳妥的表述是“基于听觉带宽的相对频谱交互”和“参考曲线偏离”，而不是“科学证明的 HiFi 最佳歌单”。“特攻”可以表示耳机特征在录音中被充分激发；“最佳适配”只能表示相对某个参考或某个用户档案的结果。

## 证据强弱与历史脉络

### 1. Fletcher–Munson：等响度首先是声压问题

Fletcher 与 Munson 1933 年的原始工作通过纯音和复杂音的听感实验建立了响度计算与频率、强度的关系；原文把它作为“由声音成分的强度和频率估计稳态声音响度”的经验模型，而不是固定的频率偏好曲线。[原始论文记录与 AIP PDF](https://pubs.aip.org/asa/article-pdf/5/2/82/11624843/82_1_online.pdf)、[DOI 10.1121/1.1915637](https://doi.org/10.1121/1.1915637)

现代的 ISO 226:2023 是正常等响度级轮廓标准，规定输入是纯连续音，并以声压级和频率给出等响组合；数据覆盖 20 Hz–12.5 kHz 的优选三分之一倍频程点。[ISO 226:2023](https://www.iso.org/standard/83117.html)

因此在本地工具中：

- 可以把“未知声压”作为一个显式限制，保留每帧总能量归一化后的**相对频谱形状**。
- 不能在没有耳机端或耳道 SPL 校准时套用某条等响度曲线，然后说某段频率“在人耳上更响”或“更容易听见”。
- 不能把播放系统的数字峰值、LUFS 或 PCM 电平当成耳膜声压；它们可用于数字信号内部的相对比较，但不是 ISO 226 的输入条件。

### 2. Zwicker、临界带与 Bark：频率不应等宽处理

Zwicker、Flottorp 与 Stevens 1957 年的临界带实验显示，纯音间隔或噪声带宽在达到临界带宽以前，响度随频率成分扩展的变化很小；超过临界带后，能量扩展才明显影响响度。[原始论文 PDF](https://www.ee.columbia.edu/~dpwe/e6820/papers/ZwicFS57-crband.pdf)、[DOI 10.1121/1.1908963](https://doi.org/10.1121/1.1908963)

Zwicker 1961 年将可听频段划分为临界带，形成后来常称的 Bark 频率组织方式。[DOI 10.1121/1.1908630](https://doi.org/10.1121/1.1908630)

这类结果支持一个重要工程方向：将线性 FFT bin 或固定 30 段展示频带，另汇总到随频率变化的听觉带宽中，避免低频和高频用同样的 Hz 宽度被赋予同样的听觉意义。它支持“如何聚合频率证据”，不支持把每个 Bark 带设成一个主观偏好权重。

### 3. Moore–Glasberg：ERB 与听觉滤波器描述频率选择性

Moore 与 Glasberg 1987 年用听觉滤波器和 excitation pattern 描述频率选择性与掩蔽；模型把滤波器视为频率选择性的加权函数，并用掩蔽实验推导滤波器形状。[原始论文](https://www.sciencedirect.com/science/article/pii/0378595587900505)

Glasberg 与 Moore 1990 年通过不对称缺口噪声实验改进了滤波器形状的推导。[PubMed 原始记录](https://pubmed.ncbi.nlm.nih.gov/2228789/)、[DOI 10.1016/0378-5955(90)90170-T](https://doi.org/10.1016/0378-5955(90)90170-T)

常用的 ERB 近似为：

\[
\mathrm{ERB}(f)=24.7\left(4.37\frac{f}{1000}+1\right)\ \mathrm{Hz}
\]

这个公式适合用作**听觉频带的几何组织**和跨频率平滑尺度。它不是一个在任意播放声压下都成立的听阈函数；原始滤波器和 excitation pattern 研究涉及电平、刺激类型、掩蔽方式以及正常听力条件。

掩蔽模型也不等于“某段频率有能量，所以一定听不见另一段”。听觉滤波器的形状、压缩、非线性和信号时间关系都会改变结果；模型论文自己也报告过对不同掩蔽条件的系统偏差。[Using an excitation-pattern model to predict auditory masking](https://www.sciencedirect.com/science/article/pii/0378595594900078)

### 4. Zwicker 与 Moore–Glasberg 响度模型：可以计算，但输入条件必须写清楚

ISO 532-1:2017 规定了 Zwicker 方法，包含稳态和时间变化声音的响度估计；它以 specific loudness pattern 为中间表示，允许单通道或多通道测量输入。[ISO 532-1:2017](https://www.iso.org/standard/63077.html)

ISO 532-3:2023 规定了 Moore–Glasberg–Schlittenlacher 方法，适用于稳态与时间变化声音，并明确列出耳机输入时可以使用送到耳机的电信号；它也说明整段超过 5 秒的时间变化信号用一个整体数值表示不在该标准的适用范围内。[ISO 532-3:2023](https://www.iso.org/standard/69856.html)

Glasberg 与 Moore 2002 年的时间变化响度模型给出了具体的模型发展基础。[AES 原始条目](https://aes.org/publications/elibrary-page/?id=11081)

本工具目前可以借鉴这些模型的结构：分频、频带内能量、时间变化、压缩和跨带汇总；但若没有声压校准，就只能把输出叫作“相对听觉带宽特征”或“level-free proxy”，不能叫作标准 loudness、phon 或 sone。若日后拥有耳机端电信号和可追溯的耳机/耳模拟器校准，可以把 ISO 532-3 作为独立的响度分析模块；它仍不直接给出“用户喜欢哪首歌”。

### 5. Toole：受控听音显示偏好与测量有关，但不是任意设备的歌单偏好

Toole 1985 年的受控扬声器听音研究报告了可靠、可重复的音质评分，同时指出听者之间会因听力阈值和年龄而不同，某些产品会因为具有鲜明特征而产生不同的评价。[AES 原始条目](https://secure.aes.org/forum/pubs/journal/?elib=4465)

这条历史线的关键不是“平直永远最好”，而是：听音条件、听者群体、声道/空间呈现、节目材料和测试设计都会影响偏好。扬声器的房间响应、直接声与反射声也不能直接复制到耳机上。

### 6. Olive、Welti 与 Harman 目标曲线：强证据是“总体偏好”，不是“每首歌的特攻”

Olive 与 Welti 2012 年对六副环绕耳机做双盲测试，摘要报告总体偏好与更中性的频谱平衡、较低的染色和更平滑的幅频响应有关；同时指出当时的 IEC diffuse-field 校准并非实现最高总体音质的唯一目标。[AES 原始条目](https://secure.aes.org/forum/pubs/conventions/?elib=16486)

Olive、Welti 与 McMullin 2013 年测试了多种耳机目标响应。摘要称，基于经过校准的房间扬声器测量得到的目标曲线在两副耳机上最受偏好。[AES 原始条目](https://aes.org/publications/elibrary-page/?id=16768)

后续工作继续显示目标曲线与总体偏好的统计关系，但也观察到人口和条件差异：2015 年 249 位听者对低频和高频进行调节时，节目、年龄、性别和听音经验都会影响偏好的低高频平衡。[AES 原始条目](https://secure.aes.org/forum/pubs/conventions/?elib=17940)

2019 年的听者分群重分析更明确地说明：平均群体可以偏好接近 Harman 目标的响应，但不同听者可能形成不同的偏好类别。[AES 原始条目](https://secure.aes.org/forum/pubs/conventions/?elib=20289)

因此目标曲线应在产品中作为**可追溯的参考档案**，而不是自然法则。平直、Harman、自由场、扩散场和用户自定义参考应保持为不同档案；把它们平均成一条新曲线会丢失问题本身。

## 对“目标曲线”的具体判断

目标曲线有三种不同含义，不能混写：

| 类型 | 它回答的问题 | 能否用于 V1 | 不应声称 |
|---|---|---|---|
| 测量/坐标参考 | 这条耳机曲线与哪些条件下的响应可比 | 可以，必须记录来源、耦合器和补偿 | 它是唯一正确的听音偏好 |
| 人口平均偏好目标 | 一组听者在某种实验条件下总体更偏好的响应 | 可以作为独立档案 | 每个人、每首歌都应趋向它 |
| 用户目标 | 这个用户在同一系统中实际偏好什么 | 需要个人试听数据 | 用两个喜欢的型号反推出完整曲线 |

耳机近耳测量本身也依赖测量系统。ISO 11904-2:2021 描述了用带耳模拟器和麦克风的人工头测量近耳声源，并将结果转换为自由场或扩散场相关声压级；标准还对适用频率范围和测量不确定性作出条件说明。[ISO 11904-2:2021](https://www.iso.org/standard/81332.html)

这意味着不同来源的裸图不能简单平移后混排。尤其高频的插入深度、耳模拟器、佩戴和重复性会改变曲线形状；超过某个图表范围也不能自动成为可听或可比较的证据。

## 在“没有 SPL 校准”的本地工具中，哪些可以落地

### A. 音量不变的相对表示

设音频每声道的 PSD 为 \(P_c(f,t)\)，耳机相对参考的响应偏差为：

\[
d_h(f)=H_h(f)-T_r(f)\quad\mathrm{dB}
\]

把频率投影到听觉带 \(B_k(f)\) 后，计算：

\[
E_{c,k,t}=\int B_k(f)P_c(f,t)\,df
\]

再用同一帧内的相对分布：

\[
p_{c,k,t}=\frac{E_{c,k,t}}{\sum_{c,k}E_{c,k,t}+\epsilon}
\]

整体增益会在归一化时消失，因此这部分可以在没有 SPL 的 PCM 上实现。输出应称为“相对频谱交互”，保留原始电平、采样率、声道、处理状态和覆盖范围作为限制信息。

### B. 从固定 30 段升级为 ERB/Bark 辅助视图

建议保留当前约三分之一倍频程明细作为工程可读视图，同时增加一套 ERB-rate 或 Bark-rate 汇总：

- 对数频率上按 ERB 中心点建立滤波器组；频率区间边界由 ERB 变换给出。
- 以 PSD 功率积分计算带能量，不能把 dB 直接平均。
- 记录实际频带上下限、FFT 分辨率和曲线有效区间。
- 带宽只决定频率证据如何聚合，不给每个带硬编码“悦耳权重”。
- 低于真实 FFT 分辨率的频带继续显示为证据不足，不能靠插值制造听觉细节。

这能让低频窄带和高频宽带在更接近听觉滤波器的坐标中比较，但它仍只是频率聚合，不等于完整的响度或掩蔽模型。

### C. 压缩能量权重：做稳健排序，不伪装成响度

整首歌的低频或母带电平可能让原始能量支配所有结果。V1 可以使用**曲目内部的相对压缩**：

\[
\tilde E_{k,t}=\log\left(1+\frac{E_{k,t}}{\operatorname{median}_{t,k}(E_{k,t})+\epsilon}\right)
\]

再用 \(\tilde E\) 作为帧和频带的稳健权重，或直接使用曲目内分位数排名。它的目的只是减少极端能量对排序的支配；由于基准是曲目内部的 PCM 值，不能解释成 sone、等响或听阈。模型参数和未压缩结果应同时保存，以便做敏感性检查。

### D. 逐帧、持续占用与瞬态占用分开

不要只用整曲均谱。对每个听觉带至少保留三类证据：

1. **持续占用**：带能量超过曲目内基线的帧比例。
2. **能量分布**：帧内相对能量的中位数、上分位数和变化范围。
3. **瞬态占用**：谱通量、局部峰值与上升沿所在时间片。

这三者应作为独立证据展示；默认排序可以用一个预先固定、无用户隐藏权重的稳健汇总，但不要把瞬态、持续能量、掩蔽和“解析力”混成一个未经听音验证的百分制。对歌单的最小结果可以是：主排序分、持续占用、瞬态证据、参考偏差、数据覆盖和限制。

### E. “特色暴露”和“目标适配”分成两条轴

当前可复算的两个指标可以保留，但应重新命名：

- **特色暴露 C**：输入分布 \(p\) 与响应变换后分布 \(q\) 的逐帧 JS 距离；C 高说明耳机改变了歌曲的频谱分布更多，增强和削弱都计入，不代表收益。
- **参考偏差 D**：以歌曲实际能量为权重、去除一个整体增益后的 \(d_h\) 残差。D 低表示更接近所选参考的谱形，不代表用户一定喜欢。
- **高频参考偏差 D_high**：只在 10–20 kHz 有足够有效内容时计算，并复用全频整体增益；缺乏有效内容时应显示不可用，不用数值噪声排序。

“根据耳机找歌—特色探索”可以按 C 降序；“综合适配”可以按 D 或相对于拥有耳机集合的 D 差值；两种排序名称必须把含义写在界面上。不要把 C 和 D 通过任意权重合成单一“HiFi 分数”。

### F. 多参考、多用户，不平均成一条目标

建议保存一个参考向量，而不是一个均值目标：

\[
\mathbf D(s,h)=\left(D_{\mathrm{flat}},D_{\mathrm{population}},D_{\mathrm{user}},D_{\mathrm{custom}}\right)
\]

其中：

- `flat` 表示计算基线，用于观察染色；
- `population` 可以选择某个有来源的公开目标；
- `user` 由用户自己的成对试听反馈学习；
- `custom` 由用户明确选择的一条曲线构成。

没有用户反馈时，不要用 `HE1` 和 `Alter Ego` 两个喜欢的型号推导一条用户目标曲线。它们可以作为用户偏好采样的起点：对同一录音、同一佩戴、尽可能匹配响度后记录 A/B 选择，再逐步学习用户对低频、耳增益、上高频和染色的偏好方向。两个型号的喜好只能证明两个偏好样本，不能证明完整频响目标。

### G. ERB 功率积分与稳健聚合的具体建议

若进入下一版实现，频带内应按功率域计算，而不是对采样点的 dB 值做平均：

\[
E_{k,t}=\int_{B_k}P(f,t)\,df,
\qquad
E'_{k,t}=\int_{B_k}P(f,t)10^{d_h(f)/10}\,df
\]

这里的 \(d_h(f)\) 是耳机相对参考的 dB 偏差；应使用 FFT 单元与 ERB 带的实际重叠宽度积分。若先平均 dB 再指数化，会在曲线起伏较大时得到不同的、难以解释的结果。

在没有 SPL 时，可以把每帧带能量归一化后使用固定的压缩权重：

\[
w_{k,t}=\frac{p_{k,t}^{\alpha}}{\sum_j p_{j,t}^{\alpha}},\qquad \alpha=0.3
\]

`α=0.3` 是抑制极端频带支配的工程启发式，不是 sone、等响度或人耳幂律的估计；实现应同时保存未压缩结果，并至少用 `α=0.2/0.5` 做离线敏感性比较。不要在没有试听数据时给不同频带再乘一组隐藏常数。

对每帧误差 \(e_t\) 同时输出：

- 压缩能量加权 RMS，表示整体参考偏离；
- 活动帧 P90，表示局部峰值或某些乐段是否出现明显偏离；
- 活动占用比例，表示该偏离是否持续存在。

P90 应只在有内容的帧上计算，且记录活动帧规则；它是风险/证据维度，不应与 RMS 用任意权重合成一个伪精确分数。

多参考时逐参考计算完整结果。若产品必须给出“参考集合中的最低偏离”，只能取完整结果中的最小值并保留获胜参考、另一参考的数值和比较条件；不能逐频选择不同参考的最佳部分后拼成一条新目标曲线。

## 哪些内容当前不能声称

| 想说的结论 | 当前是否可说 | 原因 |
|---|---|---|
| “这首歌在该耳机上会被提升/削弱哪些频段” | 可以，有限度 | 需要真实 PCM、有效耳机曲线、明确参考和相对 PSD；这是线性频谱计算 |
| “这副耳机最适合这首歌” | 不能作为已验证事实 | 需要用户偏好、响度匹配和受控听音；D 只代表参考偏差 |
| “这副耳机对摇滚/女声特攻” | 不能从语义或单一频响推出 | 需要多首真实录音的时频证据和用户听感验证 |
| “高频延伸到 30/40 kHz 更好” | 不能 | 采样率、耦合器、测量带宽和听者可听性都没有被当前工具证明 |
| “用了 ISO 226，所以已经修正了人耳响度” | 不能 | 没有耳膜 SPL、呈现条件和年龄/听力条件；ISO 226 只覆盖特定纯音条件 |
| “掩蔽导致某乐器听不见” | 不能仅靠当前 FR | 需要听觉滤波器、声压、电平依赖、时间关系与刺激条件；当前没有乐器源分离或校准 |
| “分数已经是科学百分制” | 不能 | 目前是可复算的工程模型；没有经过该产品目标数据集的偏好校准 |

## 建议的下一版最小模型

保持当前真实 PCM + FR 数据链路，按下面顺序增量升级：

1. **输入层**：统一记录曲线测量体系、参考版本、音频采样率/声道/处理状态、覆盖和是否可确认完整。未知值继续是 unknown，不补零。
2. **频率层**：继续计算线性 PSD；并行汇总三分之一倍频程和 ERB-rate 两套频带。C/D 的计算版本固定使用一套，另一套作为解释证据，避免展示分辨率改变排序。
3. **能量层**：每帧使用相对能量分布；同时保存原始功率和曲目内部压缩权重。对极端帧使用中位数/上分位数聚合，不使用未经验证的固定频率权重。
4. **时间层**：保存持续占用、谱通量和局部峰值时间。主分数只说明频谱交互；瞬态与持续证据分开展示。
5. **结果层**：默认输出 C、D、D_high、覆盖状态、参考名称、ERB/Bark 频带证据，不合成伪精确总分；比较拥有耳机时保留并列和不可评估状态。
6. **偏好层**：在用户实际听过同一录音的耳机 A/B 选择后，学习用户参考向量或低维偏好修正；先做成对排序和可回放证据，不直接训练一个跨用户“喜欢概率”。
7. **声压层**：只有接入经过校准的耳机端/耳模拟器测量后，才新增 ISO 226、ISO 532-1 或 ISO 532-3 对应的响度分析；在此之前把所有相关结果标为“未做 SPL 感知建模”。

## 资料与证据等级

以下按本文件使用方式分级：

- **强**：国际标准或原始实验直接规定了测量条件/算法范围。包括 [ISO 226:2023](https://www.iso.org/standard/83117.html)、[ISO 532-1:2017](https://www.iso.org/standard/63077.html)、[ISO 532-3:2023](https://www.iso.org/standard/69856.html)、[ISO 11904-2:2021](https://www.iso.org/standard/81332.html)、Fletcher–Munson 原始论文和 Zwicker 临界带实验。
- **中强**：同行评议的受控听音研究，能支持总体偏好和人口差异，但实验条件不能直接扩展为每首歌曲的偏好。包括 [Toole 1985](https://secure.aes.org/forum/pubs/journal/?elib=4465)、[Olive/Welti 2012](https://secure.aes.org/forum/pubs/conventions/?elib=16486)、[Olive/Welti/McMullin 2013](https://aes.org/publications/elibrary-page/?id=16768)、[Olive/Welti 2015](https://secure.aes.org/forum/pubs/conventions/?elib=17940)、[Olive/Welti/Khonsaripour 2019](https://secure.aes.org/forum/pubs/conventions/?elib=20289)。
- **中**：听觉滤波器、ERB、掩蔽和时间变化响度模型，能够支持频带组织和相对特征，但需要注意电平依赖和适用条件。包括 [Moore/Glasberg 1987](https://www.sciencedirect.com/science/article/pii/0378595587900505)、[Glasberg/Moore 1990](https://pubmed.ncbi.nlm.nih.gov/2228789/)、[Glasberg/Moore 2002](https://aes.org/publications/elibrary-page/?id=11081)。
- **弱到待验证**：把上述听觉/偏好研究直接变成“某副耳机对某首歌特攻”的推荐。当前没有足够的用户—歌曲—耳机受控试听数据，不能把它写成公认 HiFi 科学标准。

## 参考资料

1. Fletcher, H.; Munson, W. A. “Loudness, Its Definition, Measurement and Calculation”, 1933. [AIP PDF](https://pubs.aip.org/asa/article-pdf/5/2/82/11624843/82_1_online.pdf) · [DOI](https://doi.org/10.1121/1.1915637)
2. ISO 226:2023, *Acoustics — Normal equal-loudness-level contours*. [ISO](https://www.iso.org/standard/83117.html)
3. Zwicker, E.; Flottorp, G.; Stevens, S. S. “Critical Band Width in Loudness Summation”, 1957. [PDF](https://www.ee.columbia.edu/~dpwe/e6820/papers/ZwicFS57-crband.pdf) · [DOI](https://doi.org/10.1121/1.1908963)
4. Zwicker, E. “Subdivision of the Audible Frequency Range into Critical Bands”, 1961. [DOI](https://doi.org/10.1121/1.1908630)
5. Moore, B. C. J.; Glasberg, B. R. “Formulae describing frequency selectivity as a function of frequency and level, and their use in calculating excitation patterns”, 1987. [ScienceDirect](https://www.sciencedirect.com/science/article/pii/0378595587900505)
6. Glasberg, B. R.; Moore, B. C. J. “Derivation of auditory filter shapes from notched-noise data”, 1990. [PubMed](https://pubmed.ncbi.nlm.nih.gov/2228789/) · [DOI](https://doi.org/10.1016/0378-5955(90)90170-T)
7. Glasberg, B. R.; Moore, B. C. J. “A Model of Loudness Applicable to Time-Varying Sounds”, 2002. [AES](https://aes.org/publications/elibrary-page/?id=11081)
8. ISO 532-1:2017, *Methods for calculating loudness — Part 1: Zwicker method*. [ISO](https://www.iso.org/standard/63077.html)
9. ISO 532-3:2023, *Methods for calculating loudness — Part 3: Moore-Glasberg-Schlittenlacher method*. [ISO](https://www.iso.org/standard/69856.html)
10. Toole, F. E. “Subjective Measurements of Loudspeaker Sound Quality and Listener Performance”, 1985. [AES](https://secure.aes.org/forum/pubs/journal/?elib=4465)
11. Olive, S.; Welti, T. “The Relationship between Perception and Measurement of Headphone Sound Quality”, 2012. [AES](https://secure.aes.org/forum/pubs/conventions/?elib=16486)
12. Olive, S.; Welti, T.; McMullin, E. “Listener Preferences for Different Headphone Target Response Curves”, 2013. [AES](https://aes.org/publications/elibrary-page/?id=16768)
13. Olive, S.; Welti, T. “Factors That Influence Listeners’ Preferred Bass and Treble Levels in Headphones”, 2015. [AES](https://secure.aes.org/forum/pubs/conventions/?elib=17940)
14. McMullin, E. “A Study of Listener Bass and Loudness Preferences over Loudspeakers and Headphones”, 2017. [AES](https://secure.aes.org/forum/pubs/conventions/?elib=19252)
15. Olive, S.; Welti, T.; Khonsaripour, O. “Segmentation of Listeners Based on Their Preferred Headphone Sound Quality Profiles”, 2019. [AES](https://secure.aes.org/forum/pubs/conventions/?elib=20289)
16. ISO 11904-2:2021, *Determination of sound immission from sound sources placed close to the ear — Technique using a manikin*. [ISO](https://www.iso.org/standard/81332.html)
17. ITU-R BS.1770-5:2023, *Algorithms to measure audio programme loudness and true-peak audio level*. [ITU](https://www.itu.int/rec/R-REC-BS.1770-5-202311-I)
