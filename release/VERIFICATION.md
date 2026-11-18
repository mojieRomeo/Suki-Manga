# preload 版公开源码验证 — 2026-11-18

基准安装包：`SukiManga-0.8.11-preload.apk`，330,015,840 字节。SHA256：`52621b863e5592c5a4144ff831f37f31f2f6cd5dd914f79f56b0773e6e0e12b3`。

| 检查 | 本次结果 |
|---|---|
| Flutter 单元/组件回归 | 54 项通过 |
| `flutter analyze` | 无问题 |
| `node --test app/test/source_reader_test.cjs` | 1 项通过 |
| `flutter build apk --release` | 构建通过，使用可公开的本机签名配置 |
| `python tools/fetch_models.py --check` | 固定的 12 个文件校验通过 |
| Android 原生 ReaderProbe | 私有 34 样本，passed=true、failures=[]、slantedGeometry=true |
| 最终 APK 模拟器安装/冷启动 | 安装成功，启动 Status=ok，TotalTime=3952ms，未发现崩溃日志 |
| 源码比对 | 46 个运行源码/资源文件与本地最终工程一致 |
| 模型比对 | 本地、公开工程和最终 APK 内两个运行模型一致 |

环境：Windows，Flutter 3.47.9 / Dart 3.13.7，Android x86_64 模拟器。工具版本与构建步骤见 README。

原生样本的区域数、耗时与引擎输出摘要见 [native-verification.json](native-verification.json)。耗时是单次模拟器原生处理秒数，含设备和初始化影响，不是翻页延迟、速度对比或模型准确率。34 样本覆盖彩色背景变体、斜沟槽、窄分镜、独立横分镜、连续人物、框外对白、窗户与空白页等断言；其中部分是同一页变体，不能当作 34 部独立漫画。

公开 Flutter 测试使用自绘图像。公开 ReaderProbe 及空白素材保留；完整私有漫画测试图片未发布，所以克隆仓库不能直接复现全部 34 样本检查。案例页图片是该次原生输出的可视化。

`source-baseline.json` 记录运行源文件哈希；`models/manifest.json` 固定模型来源与哈希。原始 APK 是作者指定文件，自建验证包没有替代它。源码比对和构建通过不能证明历史 APK 可逐字节重建；公开构建移除了作者路径和私人签名配置。没有测量全集准确率，也不承诺第三方站点持续可用。
