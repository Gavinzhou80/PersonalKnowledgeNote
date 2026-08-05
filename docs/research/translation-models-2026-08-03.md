# 学术论文双语阅读器：翻译模型与 API 调研

调研日期：2026-08-03

## 结论

存在真正的专用翻译模型，不必把 DeepSeek 这类通用大模型当作唯一选择。对当前“1 人、4 个月、仅 macOS、英文论文译中文、正文按块缓存”的 MVP，首选是 **Qwen-MT**，默认使用 `qwen-mt-plus` 做论文正文翻译，并保留 `qwen-mt-flash` 作为低成本/快速档。DeepSeek 更适合后续承担术语解释、章节总结、卡片生成等通用 AI 工作，而不是默认翻译引擎。

第二候选是 **DeepL API**。它的文本数组、上下文、术语表、翻译记忆、HTML/XML 标签保护等接口非常适合段落块翻译，但需要新增独立适配器，不能直接复用 OpenAI-compatible 客户端。[DeepL Translate API](https://developers.deepl.com/api-reference/translate/request-translation)

无论使用哪家模型，都不应让翻译 API 负责 PDF 版面、图片或公式。应用应先抽取阅读顺序，把自然语言正文送去翻译；图片、公式、表格作为本地媒体块原样插入译文 View。翻译结果按 `document_id + source_block_id + source_hash + engine/model/config_version` 持久化，第二次打开直接读取缓存。

## 专用机器翻译与通用大模型的区别

- **专用机器翻译（MT）**：接口和训练目标围绕源语言→目标语言，通常原生提供术语表、翻译记忆、文档/HTML 处理和稳定的输入输出顺序。Qwen-MT、DeepL、Google Cloud Translation、Microsoft Translator 属于这一类。
- **通用大模型翻译**：翻译只是模型的一种指令能力。它更容易同时完成解释、改写和结构化生成，但也更容易擅自改写、遗漏引用标记或破坏占位符。DeepSeek API 属于这一类；DeepSeek 官方当前把模型描述为通用生成/推理模型，并提供 JSON Output，而不是专用翻译服务。[DeepSeek 模型与价格](https://api-docs.deepseek.com/quick_start/pricing) [DeepSeek JSON Output](https://api-docs.deepseek.com/guides/json_mode)

## 方案对比

| 方案 | 类型 | 与本产品最相关的官方能力 | 对块 ID / 公式占位符的适配 | MVP 评价 |
|---|---|---|---|---|
| Qwen-MT Plus / Flash | 专用 MT（基于 Qwen3 优化） | 92 种语言；术语干预、翻译记忆、领域提示；Plus 官方明确面向专业领域、正式文档、学术论文和技术报告；支持 OpenAI-compatible 调用 | `translation_options` 是 OpenAI 协议之外的扩展参数；接口要求单条 user message，默认返回译文而非任意 JSON。块 ID 最好由客户端按请求/数组顺序维护，不依赖模型回显 | **首选**。中国区端点与当前 OpenAI-compatible 适配方向吻合，首版接入成本最低 |
| DeepSeek API | 通用 LLM | OpenAI 格式、长上下文、JSON Output；价格低 | 可要求 JSON，但仍需校验 ID、占位符和段落数；缺少专用 MT 的术语表/翻译记忆语义接口 | 不作为默认翻译；用于总结、解释、卡片生成更合适 |
| DeepL API | 专用 MT | 单次请求可传 `text[]`，结果保持相同顺序；`context` 影响翻译但不翻译且不计费；术语表、翻译记忆、自定义指令、HTML/XML 标签和 `ignore_tags`；请求上限 128 KiB | **非常适合**。客户端可按数组下标映射 block；可用标签保护公式/引用占位符 | **第二候选/质量对照组**。接口不是 OpenAI-compatible，需要独立适配器 |
| Google Cloud Translation | 专用 NMT + Translation LLM | 标准 NMT、Translation LLM、Adaptive Translation、术语表、批量和文档翻译 | REST 数据结构稳定；术语表与示例译文适合一致性控制。原生 PDF 文档翻译不利于本产品自己的段落锚点，因此更适合用文本 API | 能力完整，但 Google Cloud 项目、IAM、区域与计费接入明显扩大首版工作量 |
| Microsoft Translator | 专用 NMT | Text Translation、Document Translation、Custom Translator；文档翻译支持保留结构并可用 glossary | REST 接口稳定，但要新增 Azure 认证/资源配置；本产品仍应使用文本块 API而非把 PDF 整体交给服务 | 成熟备选，不建议四个月 MVP 同时接入 |
| Meta NLLB-200 | 可本地部署的研究型 MT | 官方研究项目覆盖 200 种语言，有开源模型权重 | 可以完全本地控制块映射，但需自行部署、分词、批处理、性能和质量评测 | **不适合首版**。官方模型卡明确说 distilled 600M 是研究模型、不面向生产部署，且不是文档翻译模型；许可也需单独审查 |

## Qwen-MT：最贴合当前 MVP

阿里云官方将 Qwen-MT 描述为“基于 Qwen3 优化的机器翻译大语言模型”，支持 92 种语言，并提供三种对专业翻译很关键的约束能力：

1. `terms`：显式指定源术语及目标译法，保证技术名词一致。
2. `tm_list`：提供源句/目标句对作为翻译记忆，使大文档保持既有句式与风格。
3. `domains`：用领域提示控制专业文体；官方说明当前领域提示仅支持英文内容。

官方模型建议是：`qwen-mt-plus` 用于专业领域、正式文档、学术论文和技术报告；`qwen-mt-flash` 是质量、速度和成本的通用平衡；`qwen-mt-lite` 面向简单的低延迟场景；`qwen-mt-turbo` 将不再更新，官方建议迁移到 Flash。[Qwen-MT 官方文档](https://help.aliyun.com/en/model-studio/machine-translation)

Qwen-MT 当前单次最大输入为 8,192 tokens，官方建议在段落、完整句子等自然语义边界切分长文；术语表、翻译记忆和领域提示也占用输入 token。它不是整篇论文一次提交的文档翻译接口，因此应用侧的分块、缓存和重组是必需设计。[Qwen-MT API 参考](https://www.alibabacloud.com/help/en/model-studio/qwen-mt-api)

它支持 OpenAI-compatible SDK，但 `translation_options` 不是标准 OpenAI 参数，必须通过 `extra_body` 发送。阿里云官方示例提供中国北京地域的兼容端点，因此从中国区服务接入的角度，它比只提供海外云端点的服务更容易纳入当前方案。API key 与地域绑定，具体 endpoint 需要按用户工作区配置。[Qwen-MT 调用示例](https://help.aliyun.com/en/model-studio/machine-translation)

### 推荐调用方式

- MVP 默认：`qwen-mt-plus`，源语言显式设为 English，目标语言设为 Chinese，避免自动检测降低准确度；官方也建议显式源语言。
- 快速/省钱模式：`qwen-mt-flash`。
- 不使用 `qwen-mt-turbo`，因为官方已标为不再更新。
- 每个请求携带当前文档/主题的术语表；跨章节累计经用户确认的术语译法。
- 不要求模型生成整套 `{block_id, translation}` JSON。客户端把每个文本块作为独立任务，或按固定顺序批处理并保存顺序映射；写库前校验输出非空、占位符完整、引用编号未丢失。
- Qwen-MT 的自定义 prompt 与 `translation_options` 互斥；优先使用结构化的 `translation_options`，不要为了 JSON 输出牺牲术语、翻译记忆和领域控制。[Qwen-MT 限制与自定义提示](https://help.aliyun.com/en/model-studio/machine-translation)
- 官方响应是纯译文字符串，没有 JSON Schema / `response_format` 契约；不要依赖它稳定生成 `{block_id, translation}`。目前也未发现 Qwen 官方发布可下载的 Qwen-MT 权重，应按云 API 能力规划，而不是本地模型。[Qwen-MT API 参考](https://www.alibabacloud.com/help/en/model-studio/qwen-mt-api) [Qwen 官方 GitHub](https://github.com/QwenLM) [Qwen 官方 Hugging Face](https://huggingface.co/Qwen)

阿里云当前公开文档把 Qwen-MT 的上下文限制与价格引导到 Model Studio 控制台查询，因此本文不记录可能很快过期的价格数字。[Qwen-MT 模型选择](https://help.aliyun.com/en/model-studio/machine-translation)

## DeepL：接口最适合“段落块”

DeepL 文本 API 一次可以接收多个 `text` 字符串，返回顺序与请求顺序一致；每个字符串独立翻译，因此应用可以稳定用数组下标映射 `source_block_id`。单次请求大小上限为 128 KiB。[DeepL Translate API](https://developers.deepl.com/api-reference/translate/request-translation)

与论文阅读器特别契合的参数包括：

- `context`：给短段落补充标题、上一段或摘要作为上下文；该内容影响译文但不会被翻译，也不计入字符计费。
- `glossary_id` / `glossary_ids`：固定专业术语译法。
- `translation_memory_id`：复用已有句对；可设置匹配阈值。
- `custom_instructions`：可要求保持学术文体等行为；官方当前列出的目标语言包含中文。
- `tag_handling=xml/html` 与 `ignore_tags`：可把行内公式、变量、引用编号先替换成受保护标签，翻译后再恢复。

DeepL 支持简体中文作为翻译语言；具体语言和模型支持应在运行时通过官方 Languages API 或支持语言页确认。[DeepL 支持语言](https://developers.deepl.com/docs/getting-started/supported-languages)

## Google Cloud Translation

Google 提供标准 NMT、Translation LLM（TLLM）和基于示例译文的 Adaptive Translation；Cloud Translation Advanced 还提供 glossary、文档、批量和实时翻译。[Translation LLM](https://docs.cloud.google.com/translate/docs/translation-llm) [Adaptive Translation](https://docs.cloud.google.com/translate/docs/advanced/adaptive-translation) [Glossary](https://docs.cloud.google.com/translate/docs/advanced/glossary) [产品概览](https://docs.cloud.google.com/translate/docs/overview)

官方当前价格页列出：标准 NMT 每月前 50 万字符由每月 10 美元赠金覆盖，之后为每百万输入字符 20 美元；Translation LLM 文本翻译为每百万输入字符 10 美元、每百万输出字符 10 美元；Adaptive Translation 为输入和输出各每百万字符 25 美元；NMT 的 PDF/DOCX/PPT 文档翻译为每页 0.08 美元。价格可能变化，应以调用时官方页面为准。[Google Cloud Translation 定价](https://cloud.google.com/translate/pricing)

对本产品而言，不建议直接调用“整份 PDF 文档翻译”：那会让服务自己的版面结果和应用的 `source_block_id`/坐标锚点产生两套结构。使用文本翻译 API，图片、公式、表格留在本地渲染，更符合双语同步设计。

## Microsoft Translator

Microsoft 提供 Text Translation、Document Translation 和 Custom Translator，属于专用翻译产品线，而不是通用聊天模型。Document Translation 可以处理整份文档并保留结构，也支持 glossary；Custom Translator 用平行语料定制领域模型。[Translator 概览](https://learn.microsoft.com/en-us/azure/ai-services/translator/) [Document Translation](https://learn.microsoft.com/en-us/azure/ai-services/translator/document-translation/overview) [Custom Translator](https://learn.microsoft.com/en-us/azure/ai-services/translator/custom-translator/overview)

它适合未来作为企业/Azure 用户的可选供应商，但首版引入 Azure 资源、区域、密钥和计费配置，不会复用现有 OpenAI-compatible 适配器。对于当前产品同样应使用文本块翻译，而非依赖整文档翻译输出。

## Meta NLLB-200：仅作为未来本地实验

Meta 的 NLLB 项目提供覆盖 200 种语言的研究型机器翻译模型。官方 `nllb-200-distilled-600M` 模型卡明确限制其定位：研究用途，不面向生产部署；不是文档翻译模型；训练输入长度不超过 512 tokens；许可为 CC-BY-NC-4.0。它因此不适合作为潜在商业产品的默认本地引擎。[Meta NLLB 官方项目](https://github.com/facebookresearch/fairseq/tree/nllb) [官方模型卡](https://huggingface.co/facebook/nllb-200-distilled-600M)

若未来需要完全离线，可单独评估 NLLB 或其他明确允许商用的本地 MT 模型，但需要承担模型下载、Metal/CPU 推理、内存、分句、术语约束和质量回归测试；这不属于 1 人 4 个月 MVP 的合理范围。

## 推荐的首版架构决策

1. 定义产品自己的 `TranslationProvider`，不要把领域层绑定到 OpenAI Chat Completions。
2. 首个实现 `QwenMTProvider`；保留通用 `OpenAICompatibleProvider` 给 DeepSeek 的总结、解释和卡片生成。
3. 翻译请求的领域对象固定包含：`sourceBlockID`、源/目标语言、正文、不可翻译占位符、术语表版本、上文 context、模型配置版本。
4. 翻译结果逐块持久化；唯一性键至少包括 `document_id + source_block_id + source_hash + provider + model + config_version`。
5. 图片、块级公式、表格不发送给文本翻译模型；只翻译图注/表注。行内公式和引用先替换成不可翻译占位符，返回后严格校验并恢复。
6. 失败重试必须保持幂等；原文 hash 未变化时不重新翻译。用户手动修订的译文单独标记，自动重翻不得覆盖。
7. 内测阶段用同一组 20–30 篇中英文学术段落做 Qwen-MT Plus、Qwen-MT Flash、DeepL、DeepSeek 盲测，重点检查术语一致性、遗漏、引用/公式占位符完整率和可读性，而不是只凭通用排行榜选型。

## 中国大陆可用性说明

官方资料能确认阿里云 Qwen-MT 提供中国地域的 Model Studio endpoint，DeepSeek 提供自己的 API endpoint；这两者最容易在当前中国区部署假设下验证。Google、DeepL、Microsoft 的公开产品文档并未对“中国大陆网络可直连性”给出本产品可依赖的保证，因此本文不作可用/不可用断言；如未来接入，应以目标用户网络和企业合规环境做实测。
