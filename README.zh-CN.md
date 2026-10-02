# TapTap

把 MacBook 掌托上的轻敲变成实用动作。TapTap 是原生 macOS 菜单栏 App，可以识别左右掌托的双击和三击。

[English](README.md) · [MIT 许可证](LICENSE)

## 功能

- 左双击、左三击、右双击、右三击，各自指定动作。
- 动作包括媒体键、键盘快捷键、打开 App、运行 Apple 快捷指令和 Shell 命令。
- 录制或手动编辑快捷键：单键、多修饰键、Fn、F1–F20、方向键和数字小键盘。
- 快捷键可发给当前 App，也可直接发送到指定 App；「测试」按钮会在 3 秒后执行。
- 灵敏度为 4–20 mg，并过滤打字、移动电脑和敲桌面等干扰。
- 屏幕提示、登录启动、菜单栏图标均可开关。隐藏图标后，从「应用程序」重新打开 TapTap 即可显示设置。
- 英文、简体中文、繁体中文，可在「设置 → 其他／一般 → 语言」即时切换。

默认左双击播放／暂停，右双击下一首；三击未指定动作。

## 环境与安装

需要 macOS 14 或更新版本，以及提供 `AppleSPUHIDDevice` 动作传感器的 MacBook。并非所有 Apple Silicon 机型都支持，App 会显示硬件是否可用。传感器接口没有公开文档，识别效果可能随设备、桌面和电脑摆放方式而变化。

构建图标需要 Xcode 26 或更新版本，并将 Xcode 设为当前开发工具目录。

```sh
git clone https://github.com/yu2001-s/TapTap.git
cd TapTap
swift test
Scripts/install-app.sh
```

安装脚本使用本机的 Apple Development 证书，将 App 更新至 `/Applications/TapTap.app`，然后打开设置。也可指定签名身份：

```sh
SIGN_IDENTITY='Apple Development: Your Name (TEAMID)' Scripts/install-app.sh
```

没有开发者证书时，可以明确选择临时签名：

```sh
SIGN_IDENTITY=- Scripts/build-app.sh
open build/TapTap.app
```

临时签名重建后可能需要重新授权辅助功能。保持同一证书与 Bundle ID 可保留 App 的签名身份。登录启动建议使用 `/Applications` 中的 App。

## 权限与使用

媒体键和键盘快捷键需要辅助功能权限：点击「授权…」，在「系统设置 → 隐私与安全性 → 辅助功能」启用 TapTap。打开 App、运行快捷指令和 Shell 命令不需要这项权限。Shell 命令会以当前用户身份通过 `zsh -lc` 执行。

Discord 静音可以设置为 **⇧⌘M → 发送到 Discord**。请先启动 Discord，使用「测试」确认后台切换效果。部分 App 的自定义全局热键不会响应模拟按键，直接发送到 App 提供了另一种方式；实际效果取决于接收方。

正常运行时，检测和分类都在本机完成，不保存传感器录制。设置存在 UserDefaults 中，没有分析服务或后端。录制快捷键时仅处理 TapTap 中的输入；检测器只查询最近按键／点击发生多久之前，以过滤误触。用户指定的动作可能自行访问文件或网络。

## 开发与发布

查看 [构建说明](docs/BUILDING.md)、[贡献指南](CONTRIBUTING.md) 和 [模型训练](docs/TRAINING.md)。

公开源码不包含原始录制、个人签名配置、证书和构建产物。CI 产物采用临时签名，未经公证，供开发测试使用。正式分发需要自己的 Developer ID 证书及 Apple 公证。
