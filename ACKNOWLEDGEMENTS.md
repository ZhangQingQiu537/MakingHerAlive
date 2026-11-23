# 致谢与出处

这个仓库里的 **Swift 代码全部是自己写的**，没有拷贝任何第三方源码。
下面这些项目/服务影响了设计，或在运行时被调用，按影响程度列出。

## 运行时依赖（可选）

| 项目 | 用途 | 说明 |
|---|---|---|
| [DeepSeek API](https://api-docs.deepseek.com/) | 对话与思考模型 | 必需；Key 由使用者自己填，不在仓库里 |
| [@deepseek-ai/dsh](https://www.npmjs.com/package/@deepseek-ai/dsh) | 可选：重活子进程（`run_task`） | 不随仓库分发；路径用 `DSH_PATH` / `DSH_NODE_BIN` / `DSH_NODE_PATH` 指定，未安装则整块功能不可用。其许可证归 DeepSeek 所有 |
| 火山引擎方舟（ARK） | 可选：TTS / 文生图 | 外部服务，需自己的 Key；不在仓库内 |
| SillyTavern / TavernAI | **仅格式兼容**：读取旧的 `角色卡.json` 与 `chat.jsonl` | 没有拷贝其代码（它是 AGPL，本项目是 MIT）；`ST_ROOT` 环境变量可指向旧数据目录 |

## 设计上的参考

| 项目 | 借了什么 | 备注 |
|---|---|---|
| [Letta（原 MemGPT）](https://github.com/letta-ai/letta) | “core memory 常驻 + 可检索记忆”的分层思路 | 只借概念，实现是独立的（`CoreProfile` / `CardStore`） |
| [Mem0](https://github.com/mem0ai/mem0) | “用户画像每轮注入、细粒度事实检索”的对照做法 | 概念参考 |
| DSH 的 `fish-mood` 示例 | 心情三量的基线/半衰参数（70 基线、12h 半衰、判定值 ÷3） | 数值参考，代码独立实现（`MoodStore`） |
| 角色卡 JSON 格式（`name/description/personality/scenario/first_mes/mes_example`） | 字段命名与 SillyTavern 生态保持一致，方便迁移 | 格式本身属于社区约定，不是某家的专有代码 |

## 明确没有使用的

- 没有把 SillyTavern 的代码或资源打包进来（旧资产仅本地归档）。
- 没有内置任何角色卡、世界书、persona、对话或日记。
- 没有把任何 API Key、账号、个人路径写进仓库（`DSH_PATH`、`PYTHON_BIN`、`TTS_BRIDGE`、`ST_ROOT` 都是环境变量）。

## 如果你要再发布

- `Sources/`、`App/` 的 Swift 代码：MIT（见 `LICENSE`）。
- 你自己写的角色卡、世界书、persona：版权归你，建议单独放一个私有仓库。
- 上面列出的第三方项目：各自遵循其原始许可证；本仓库不包含它们的代码。
