# MacAboboo

MacAboboo 是一款面向 macOS 的原生英语听力学习与音视频复读工具，目标是提供类似 Windows Aboboo 的学习体验。项目使用 Swift、SwiftUI、AppKit 和 AVFoundation 构建，界面以中文为主，并为多语言扩展预留空间。

## 当前能力

- 音频、视频播放与毫秒级定位
- AVFoundation、libmpv 及混合播放后端
- 主波形图与当前句子的放大波形图
- 断句列表、原文/译文编辑与即时保存
- 连续播放、单句循环、句末暂停和全曲循环
- SRT、LRC、文本导入及时间轴生成
- 手动切句、合并句子和波形锚点微调
- 本地音频 PCM 与波形缓存
- 三种断句预设：
  - 高精度多人对话
  - 快速断句
  - 纯语义断句

## 自动断句

自动断句使用统一的语音分段流水线：

1. 将媒体解码为 16 kHz、Float32、单声道 PCM。
2. 使用 Silero VAD 检测语音区间。
3. 在需要时使用 SpeakerKit / Pyannote Core ML 进行说话人分离。
4. 在高精度和纯语义模式下，通过进程内 whisper.cpp 获取词级时间戳。
5. 使用全局边界优化器综合停顿、声学边界、语义信息、说话人切换和最大句长约束。

旧任务、媒体切换和用户取消都会取消对应的异步任务，避免过期结果覆盖当前工程。

## 项目结构

```text
Sources/
  CSpeechRuntime/       whisper.cpp C API 封装
  MacAboboo/            核心播放、波形、断句和模型管理模块
  MacAbobooApp/         macOS 应用入口
Tests/                  单元测试与语音断句集成测试
Vendor/Whisper/         whisper.cpp macOS XCFramework
Scripts/                工程生成、图标和应用打包脚本
```

## 环境要求

- macOS 14 或更高版本
- Xcode，支持 Swift 5.9
- Apple Silicon 或 Intel Mac

项目依赖的 Silero、SpeakerKit 和 Whisper 运行资源位于应用资源或 `Vendor/` 目录中。Whisper 模型由应用按需管理，默认存放在：

```text
~/Library/Application Support/MacAboboo/Models/
```

## 构建与测试

使用 Xcode 打开 `MacAboboo.xcodeproj`，选择 `MacAboboo` scheme 后运行。

也可以使用 Swift Package Manager 构建和测试：

```bash
swift build
swift test
```

## 许可证

第三方组件的许可证位于 `Sources/MacAboboo/Resources/ThirdPartyNotices/` 和 `Vendor/Whisper/LICENSE`。发布应用时请同时遵守各依赖项目的许可证要求。
