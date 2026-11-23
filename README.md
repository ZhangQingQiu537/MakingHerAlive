# MakingHerAlive

> 人主导设计，AI 辅助实现。用过的模型与分工见文末「怎么做的」。

一个**本地优先**的 AI 伴侣内核：原生 macOS（SwiftUI）+ 直连 DeepSeek，数据全部留在本机。

一个"把她养成活的"内核：记忆、日记、情绪、作息、主动开口。
这不是一个产品，是一套可以自己填人设的**解决方案**。

**文档**

- [DESIGN.md](DESIGN.md) —— 架构与八条关键取舍（为什么不用 WebView、为什么不套 SillyTavern…）
- [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md) —— 运行时依赖、设计参考、明确没用到的

仓库里**不包含**任何角色卡、世界书、persona、对话数据 —— 这些都要你自己写。

---

## 它做了什么

| 模块 | 说明 |
|---|---|
| **记忆** | 事件卡片（可检索）+ 核心档案（每轮常驻）+ 摘要（长对话压缩）；卡片带日期，旧计划会自动标“已过去” |
| **人格生长** | 日记 → 态度沉淀（每 3 天）→ 周记（每周）；她自己的看法会回到 prompt |
| **生活与作息** | 每天 3 条“她自己的生活”；工作日/周末/午休/外出，影响回话长短 |
| **主动开口** | 早/晚/睡前三个槽 + 心跳；每日上限、间隔、睡段静音 |
| **联网** | 搜索 → 规则清洗 → 相关性过滤 → LLM 提纯 → 原文回查；她也能自己 `search_web`（每轮 2 次） |
| **情绪** | 心情 / 烦躁 / 亲近三个量，按半衰回落；行为按档位变化 |
| **工具** | 读文件、看网页、翻日记、写作品（只读为主，白名单目录） |

---

## 环境

- macOS 14+（开发环境是 macOS 27 + Swift 6.4）
- Xcode Command Line Tools（`swiftc`）
- 一个 DeepSeek API Key

```bash
git clone https://github.com/ZhangQingQiu537/MakingHerAlive.git
cd MakingHerAlive
bash build.sh          # 生成 build/Companion
./build/Companion      # 直接运行（无 .app 包，Dock 里可能显示为终端图标）
```

> 想打成 .app：把 `build/Companion` 放进一个 `Companion.app/Contents/MacOS/` 里，再补 `Info.plist`。

---

## 第一次运行

数据目录：`~/Library/Application Support/Companion/`（数据目录名是固定的，不随角色名变）

```
Companion/
├─ 资产/
│  ├─ 角色卡.json      ← 必填，参考 资产模板/角色卡.json
│  ├─ persona.txt      ← 必填，参考 资产模板/persona.txt
│  └─ 世界书.json      ← 可空，{"entries":{}}
├─ 核心档案.json        ← 首次运行自动播种，可手改
└─ secrets.json        ← {"deepseek-api-key":"sk-..."}
```

把 `资产模板/` 里的四个文件拷进去，改成你自己的设定，再启动。

---

## 设计上的几个选择

- **零工单**：没有任务卡、没有“要我帮你弄吗”，她办事直接办，回来用她的话说。
- **她可以真的不回**：睡段/忙段/选择沉默，日志里能和“API 挂了”区分开。
- **不编记忆**：卡片只从真实对话抽；相对时间（明天/下周）在写入时换算成绝对日期。
- **可检索但不依赖检索**：核心档案每轮都在，避免“今天没命中就忘了你是谁”。

---

## 目录

```
App/Main.swift        主流程（对话、主动、作息、情绪）
Sources/CardStore.swift        记忆卡片
Sources/CoreProfile.swift      核心档案
Sources/DiaryStore.swift       日记
Sources/AttitudeStore.swift    态度沉淀
Sources/WeeklyStore.swift      周记
Sources/LifeStore.swift        她自己的生活
Sources/ScheduleStore.swift    作息
Sources/WebSearchService.swift 联网与清洗
Sources/ToolLoop.swift         她的工具
```

---

## 隐私

- 数据全在本机，仓库里没有任何对话、日记、密钥。
- `.gitignore` 已排除 `资产/`、`secrets.json`、`*.bak-*`。
- **不要把 `~/Library/Application Support/Companion/` 提交上来。**

## 致谢

见 [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md)：DeepSeek、DSH、SillyTavern（仅格式兼容）、Letta / Mem0（概念参考）。

## License

代码 MIT。角色设定、世界书、persona 属于你自己，不在本仓库内。

---

## 怎么做的（AI 协作说明）

这个项目的**设计、取舍、验收是人做的**；**代码实现**是和几个模型协作完成的。

| 模型 | 大致参与 |
|---|---|
| DeepSeek V4 Pro | 早期架构与核心模块 |
| DeepSeek V4.1 Flash | 记忆、联网、审查后的修复 |
| Kimi K3 | 中期重构与代码审查 |
| Kimi K2.8 Preview | 设计讨论与边界推演 |
| Kimi K3.1 Pro | 后期审查与一致性检查 |

说明：

- 模型负责写代码、提方案；**采纳哪个、砍掉哪个，是人决定的**。
- 具体到每一行的分工没有逐条记录，上表是阶段性的大致划分。
- 所有代码经过真实数据回归（不是“看起来能跑”就提交）。
- AI 生成的代码可能有未覆盖的边界；发现问题欢迎开 issue。
- 仓库不包含任何模型权重，运行时通过 API 调用。
