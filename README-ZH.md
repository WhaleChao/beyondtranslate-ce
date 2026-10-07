# BeyondTranslate CE

[![GitHub release](https://img.shields.io/github/release/beyondtranslate/beyondtranslate-ce/all.svg?style=flat-square)](https://github.com/beyondtranslate/beyondtranslate-ce/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/beyondtranslate/beyondtranslate-ce/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/beyondtranslate/beyondtranslate-ce/actions/workflows/ci.yml)

**BeyondTranslate CE** 是 **BeyondTranslate**（原名 **Biyi**）的开源社区版：一款快速、原生体验出色的翻译应用，支持 macOS、Windows 和 Linux。从屏幕任意位置取词，交给你选定的引擎翻译；平时不打扰，需要时随时在。[查看文档](https://beyondtranslate.com/docs/)

UI 由 Flutter 承载；设置、翻译、OCR、词典等核心服务由 Rust 实现，通过生成的 FFI 绑定调用；macOS 上的设置窗口是原生 SwiftUI。

---

[English](./README.md) | 简体中文

---

![](https://beyondtranslate.com/images/screenshots/biyi_extract_text_from_screen_selection.gif)

## 平台支持

| Linux | macOS | Windows |
| :---: | :---: | :-----: |
|   ✔️   |   ✔️   |    ✔️    |

## 安装

三个平台的安装包都在 [Releases](https://github.com/beyondtranslate/beyondtranslate-ce/releases/latest) 页面。[官网](https://beyondtranslate.com/release-notes)列出了其他安装方式和更新日志。

**macOS，使用 Homebrew：**

```bash
brew install --cask beyondtranslate/tap/beyondtranslate-ce
```

> **macOS，从 DMG 安装：** 应用尚未经过公证，macOS 会拒绝打开刚下载的副本。Homebrew 会替你处理；手动安装后请执行一次：
>
> ```bash
> xattr -dr com.apple.quarantine "/Applications/BeyondTranslate-CE.app"
> ```

**Linux：** `.deb` 已声明所需依赖（GTK 3、X11 和 XInput，任何桌面环境都自带）。AppImage 同样依赖系统里的这些库。

## 开发

### 环境要求

- **Flutter** stable 渠道。CI 使用 3.47.5 构建。
- **Rust** stable 工具链。应用构建时由 Flutter 的 native-assets 钩子编译 Rust 运行时。
- **Python 3**，用于 `scripts/` 下的脚本。
- **仅 Linux**：Flutter 桌面工具链，以及原生窗口层编译所需的头文件：

  ```bash
  sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libx11-dev libxi-dev
  ```

### 初始化

```bash
git clone https://github.com/beyondtranslate/beyondtranslate-ce.git
cd beyondtranslate-ce
dart pub get
dart run melos bootstrap
```

### 运行

```bash
cd apps/desktop/flutter
flutter run -d macos   # 或 linux / windows
```

### 检查

```bash
dart run melos run analyze
dart run melos run test
cargo test --workspace
python3 scripts/format.py --check
```

[AGENTS.md](./AGENTS.md) 详细说明了仓库结构、Flutter 与 Rust 之间的桥接以及代码生成流程。

## 讨论

> 欢迎加入讨论组，分享你的建议和想法。

- [QQ 群](https://jq.qq.com/?_wv=1027&k=vYQ5jW7y)

## 相关链接

- [nativeapi](https://github.com/libnativeapi/nativeapi)：原生窗口、托盘与快捷键层
- [dazzui](https://github.com/dazzlabs/dazzui)：Flutter 设计系统
- [Fastforge](https://github.com/fastforgedev/fastforge)：负责打包发布

## 许可证

[AGPL](./LICENSE)
