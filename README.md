# Suki Manga

Android 漫画阅读器，初版 **0.8.11 (811)**，Flutter + Kotlin/Java + OpenCV + ExecuTorch。

## 下载

[0.8.11 初版安装包与模型依赖](https://github.com/mojieRomeo/Suki-Manga/releases/tag/v0.8.11)。APK SHA256：

```text
9ec4724694558de2f0a92c762c565d2e6bbf208811c3a71dff576c3c94a617b9
```

## 阅读行为

- 按阅读顺序累积揭晓完整区域，保留原图黑框、框外对白和物体；可靠分格页面最后一步继续显示区域累计结果。
- 跨格气泡、物体及关联分镜按原有规则组合；防止其他画格内容提前露出。
- 无可靠分格证据、大跨页显示整页；检测非白色页背景并先显示背景。
- 原图按比例居中，完成位置计算后显示；后台预加载后续页，加载中可切页。
- 向下、向右下一步；向上、向左上一步。保留气泡放大、书源、书库及缓存管理。

识别存在模型能力边界，不能保证任意漫画都分格正确。网络书源可用性受站点和网络影响。

## 构建

1. 安装 Flutter **3.47.9 stable**（Dart **3.13.7**）、Android SDK 与 JDK 17 或兼容的 Android Studio JBR。运行 `flutter doctor` 完成环境检查。
2. Python **3.11+**：在仓库根目录运行 `python tools/fetch_models.py`，下载并校验原版运行模型和导出源模型。普通构建不需要安装 PyTorch。
3. `cd app`，运行 `flutter pub get`、`flutter test`、`flutter analyze`、`flutter build apk --release`。
4. 输出为 `app/build/app/outputs/flutter-apk/app-release.apk`。最低 Android 9 / API 28，包含 arm64-v8a 和 x86_64。

Gradle 9.3.1 从官方地址下载，AGP 9.1.0，Kotlin 2.4.0，ExecuTorch 1.5.1，OpenCV 4.13.0。Flutter 创建本机 `android/local.properties`，无需固定 C/D 盘路径。

默认自行构建使用本机调试证书。发布自己的正式版本时，将 `app/android/key.properties.example` 复制为 `key.properties` 并填写自己的签名信息。原版私钥不公开；自建 APK 不能直接覆盖原版签名的安装，切换前请导出个人书库。

## 模型与导出

`models/manifest.json` 固定模型文件及压缩包 SHA256。可用 `python tools/fetch_models.py --check` 核验，或 `--archive /path/to/SukiManga-0.8.11-models.zip` 离线恢复。

运行模型安装位置：`app/android/app/src/main/assets/models/{magi,bubbles}.pte`。源模型安装位置：`models/source/model/`。模型不是可有可无的缓存。

重新导出可在单独 Python 环境安装 `tools/requirements-export.txt` 后运行 `python tools/export_executorch.py`，输出 `models/*.pte` 与 `reports/export-executorch.json`。这仅用于模型开发；重新导出的文件不保证逐字节相同。使用前需校验数值并自行复制到 Android assets，不能随意替换初版模型。

## 源码及验证

`app/lib/`：界面、书库、网络、阅读流程；`app/android/app/src/main/`：原生识别、Android 接口与资源。运行逻辑及原生资源均从初版工程逐文件校验复制，见 `release/source-baseline.json`。公开构建配置仅调整本机路径和签名，不改变漫画逻辑。

`app/test/` 为可公开运行的单元/界面回归；图片读取用例使用自绘图像，不发布漫画整页测试素材、设备数据或私人测试记录。初版既有验证记录为 39 项 Flutter 测试、34 个原生样本、26 页模拟器回归；这是历史验证范围，不表示这些漫画样本已公开或本次重新运行了全部原生检查。

## 许可

原创应用代码采用 **AGPL-3.0-only**。模型、字体和封面各自保留原许可，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。**MAGI 限个人、研究、非商业及非营利用途，商业使用需要联系模型作者。** 因此，源码开放不代表整套附带模型的软件可任意商用。漫画与封面版权属于各权利人。
