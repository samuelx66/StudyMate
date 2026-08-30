# MacAboboo

MacAboboo 是一款面向 macOS 的原生英语听力学习与音视频复读工具，使用 Swift、SwiftUI、AppKit 和 AVFoundation 构建。

## 当前功能

- 音频、视频播放，系统解码、扩展解码和智能混合解码
- 主波形图与当前句次波形图，支持直接拖动句首/句尾边界
- 快速断句与智能断句两种模式
- 原文、译文字幕编辑、导入和 LRC/SRT 导出
- 连续播放、单句重复、句后停顿、全篇循环
- 句子筛选、批量导出 AAC M4A 与双语 LRC/SRT
- 多句库管理：独立 M4A 片段、预览图、搜索、日期/来源筛选和试听
- DeepSeek、Gemini，以及 OpenAI/Anthropic 协议的自定义翻译服务
- 独立的 800×520 双栏欢迎首页、播放列表、快捷键和状态栏进度提示

## 断句流程

两种断句模式共用同一份 16 kHz、Float32、单声道 PCM：

1. PCM 按媒体路径、文件大小和修改时间缓存，波形和断句复用同一解码结果；首次解码会逐块写入临时 `.pcmcache`，完成后原子发布并以只读文件映射方式访问，正常路径不会先构造一份完整 `[Float]` 再复制到磁盘。
2. Silero VAD 输出逐帧概率和语音区间。
3. SpeakerKit 在本地使用随应用提供的 Core ML 模型分析说话人轮次和重叠语音；超过五分钟的媒体按带上下文重叠的窗口处理，并通过重叠证据和说话人中心向量维持跨窗口身份一致。
4. 智能断句额外通过应用内 whisper.cpp 获取词级时间戳、标点和语义证据；每个识别窗口直接读取对应 PCM 映射范围。
5. 全局边界优化器综合声学停顿、VAD 概率、说话人变化、Whisper 结果和句长硬上限，生成不重叠的断句。

快速断句只运行 Silero 与 SpeakerKit，优先速度和资源占用；智能断句完整联动 Silero、SpeakerKit 与 Whisper，适合需要更精准语义边界的材料。

## 数据与隐私

- AI 识别、Silero、SpeakerKit 和 Whisper 均在本机运行；SpeakerKit 模型随应用打包，不需要首次联网下载。
- Whisper 模型按需下载到 `~/Library/Application Support/MacAboboo/Models/`。
- PCM、工程和句库数据保存在 `~/Library/Application Support/MacAboboo/`。
- 从播放列表或欢迎页移除媒体、或清空播放列表时，只保留原始音视频文件；对应工程、波形和 PCM 派生缓存会一并清理。
- 工程和播放历史的后台保存失败会显示在状态栏，不会再被静默忽略。
- 工程文件当前写入 schema 4，打开时可迁移 schema 1～4 的旧工程；迁移会保留断句、原文、译文、书签和播放位置。工程存在但无法读取或媒体信息不匹配时，程序停止自动断句，不会用新结果覆盖旧工程。媒体信息不匹配时，状态栏的“处理工程”按钮会等待用户选择“继续使用原工程 / 重新断句 / 取消”；继续使用会先备份原工程，再只更新媒体绑定并保留原有字幕，完成后显示实际备份路径。
- 每次实际覆盖工程或波形缓存前，会在 `Projects/` 下保留最近 5 个独立备份快照；从播放列表删除媒体时，对应备份也会一起删除。
- API Key 仅保存在 macOS 钥匙串；翻译请求只在用户明确点击“开始翻译”后发送。
- 句库使用当前版本的 `.mablib` 目录包：`manifest.json`、`Library.sqlite3`、`Previews/` 和每句独立的 `Media/*.m4a`。首次扫描时会一次性原地迁移 v1/v2 句库到 v3，保留原 SQLite 数据、音频和缩略图；播放不依赖原始音视频。原文与译文检索由 SQLite FTS5 全文索引加速，并保持短关键词的精确匹配。
- 默认句库不可删除；勾选的句子可移动到其它句库，移动会保留原文、译文、备注、来源、时间戳、入库日期以及独立音频和缩略图。
- 句库播放和导出始终使用 `.mablib/Media` 内的独立 M4A，即使原始媒体仍存在也不会重新依赖源文件。
- 句库、翻译配置和 PCM 缓存继续只使用当前格式；工程文件单独保留向前兼容迁移，避免软件升级造成已编辑字幕丢失。

## 性能策略

- 播放边界、复读和换句使用独立高频媒体时钟；隐藏波形或缩放窗口只降低界面显示刷新。
- 长断句列表滚动时停用行内复杂悬停控件，波形标线命中只检查当前视口，句库缩略图在后台读取并缓存。
- 翻译按批次合并写入断句数组，AI 中间缓存同时限制条目数和估算内存，媒体关闭时取消相关后台工作。
- 长媒体 PCM 首次解码即流式落盘并强制只读映射：波形和 Silero 直接读取映射，Whisper 只读取当前推理窗口；生产接口不再暴露完整样本数组，SpeakerKit 每次最多复制约五分钟音频，避免两小时材料同时常驻多份完整 Float 数组。缓存不可写时仍保留内存解码作为可靠性兜底。

## 项目结构

```text
Sources/
  CSpeechRuntime/       whisper.cpp C API 封装
  MacAboboo/            播放、波形、断句、字幕、翻译和句库模块
  MacAbobooApp/         macOS 应用入口
Tests/                  单元测试与集成测试
Vendor/Whisper/         whisper.cpp macOS XCFramework
Scripts/                工程生成、图标和应用打包脚本
```

## 环境要求

- macOS 14 或更高版本
- Xcode（支持 Swift 5.9）
- Apple Silicon 或 Intel Mac

## 构建与测试

使用 Xcode 打开 `MacAboboo.xcodeproj`，选择 `MacAboboo` scheme 后运行。

也可以使用 Swift Package Manager：

```bash
swift build
swift test
```

发布包由 `Scripts/` 中的构建脚本生成到 `dist/`，同时包含应用需要的模型、动态库和资源。

## 许可证

第三方组件的许可证位于 `Sources/MacAboboo/Resources/ThirdPartyNotices/` 和 `Vendor/Whisper/LICENSE`。发布应用时请同时遵守各依赖项目的许可证要求。
