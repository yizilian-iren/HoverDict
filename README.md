# HoverDict

把鼠标停在屏幕上的英文单词上,光标下方自动弹出**中文释义**并**朗读**——无需选中、无需复制。

因为取词主力是**屏幕 OCR**(而非 Accessibility API),所以对底层是 Web 渲染的应用同样有效:
Claude 桌面客户端、浏览器(Chrome/Edge/Safari)、VS Code 等。

> 状态:可用的早期版本。当前显示折叠后的中文释义并自动发音。

## 功能

- 🖱️ **悬停取词**:光标静止约 0.2s 即触发,无需点击
- 🔤 **屏幕 OCR**:基于 Vision,适配 Electron/Chromium/WebKit 渲染的文字
- 🇨🇳 **中文释义 + 音标**:离线本地词库([ECDICT](https://github.com/skywind3000/ECDICT)),含词形还原(running→run)
- 🔊 **自动朗读**:悬停即读,另有按钮可重听
- 🪟 **不抢焦点**:非激活浮窗,阅读中的应用保持焦点
- 🎛️ **菜单栏控制**:暂停/继续、退出

## 系统要求

- macOS 14.0 (Sonoma) 及以上
- Apple 芯片(arm64)
- 仅需 **Command Line Tools**(无需完整 Xcode)即可从源码构建

## 从源码构建

```bash
git clone https://github.com/yizilian-iren/HoverDict.git
cd HoverDict

# 1) 获取词库(125MB,未随仓库提供,需下载 ECDICT 并生成)
./Scripts/fetch_dict.sh

# 2) 创建本地稳定签名证书(让屏幕录制授权不随重编失效)
./Scripts/create_signing_cert.sh

# 3) 构建并运行
make run
```

常用命令:

| 命令 | 作用 |
|---|---|
| `make run` | 编译 → 打包签名 `.app` → 重启 |
| `make app` | 只打包,不启动 |
| `make stop` | 退出运行中的实例 |
| `make dmg` | 打包成可分发 DMG |

> ⚠️ 始终通过 `.app` 启动(`make run` 已处理)。屏幕录制权限绑定 `.app` 的 bundle id +
> 签名,直接跑裸二进制(如 IDE 的 Debug/Run)会被归到终端名下,权限与词库都不生效。

## 首次运行:授予屏幕录制权限

1. 首次启动会请求「屏幕录制」权限,并把 HoverDict 加入
   **系统设置 → 隐私与安全性 → 屏幕录制**。
2. 在列表里**勾选 HoverDict**。
3. 退出并重启 App(屏幕录制授权后必须重启进程才生效)。

菜单栏会出现一个取景框图标(▣);点它可暂停/继续、打开权限设置、退出。

## 使用

把鼠标停在任意英文单词上约 0.2s —— 光标下方弹出中文释义,并自动朗读该词。
移开光标浮窗消失;移到新词会重新取词。

## 打包分发(DMG)

```bash
make dmg      # → build/HoverDict-<版本>.dmg(arm64)
```

这是**自签名、未公证**的 DMG:能发给别人,但因未走 Apple 公证,**收件人首次打开需绕过门禁**:

1. 打开 DMG,把 HoverDict 拖进 Applications
2. 首次启动:**右键 → 打开 → 再点「打开」**(仅一次)
   - 若提示「已损坏」:`xattr -dr com.apple.quarantine /Applications/HoverDict.app`
3. 首次授予屏幕录制权限后重启 App

> 要做到「双击即用、零警告」,需付费 Apple Developer 账号走 Developer ID + 公证。

## 工作原理

```
鼠标静止(防抖) → ScreenCaptureKit 截取光标周围区域 → Vision OCR(逐词 boundingBox)
  → 坐标换算 + 命中测试(锁定光标正下方的词) → 查词典 → 非激活 NSPanel 浮窗 → 朗读
```

模块:

| 文件 | 职责 |
|---|---|
| [MouseMonitor.swift](Sources/HoverDict/MouseMonitor.swift) | 全局鼠标移动监听 + 静止防抖 |
| [ScreenCapturer.swift](Sources/HoverDict/ScreenCapturer.swift) | ScreenCaptureKit 截取光标周围区域(含坐标换算) |
| [OCRService.swift](Sources/HoverDict/OCRService.swift) | Vision 文字识别,输出逐词归一化框 |
| [CoordinateMapper.swift](Sources/HoverDict/CoordinateMapper.swift) | 坐标系换算 + 命中测试 |
| [DictionaryService.swift](Sources/HoverDict/DictionaryService.swift) | ECDICT SQLite 查词 + 词形还原 |
| [OverlayPanel.swift](Sources/HoverDict/OverlayPanel.swift) | 非激活浮窗 + 朗读 |
| [StatusBarController.swift](Sources/HoverDict/StatusBarController.swift) | 菜单栏图标 |

**坐标换算**是取词工具最易出错处:Vision(归一化、左下原点)、AppKit 屏幕坐标(点、左下原点)、
ScreenCaptureKit(点、左上原点)三套坐标系。关键做法是把上下翻转与 Retina 缩放在**截图阶段**
就消化掉,使截图正好覆盖目标区域,于是 Vision 框换回屏幕坐标只是一次线性缩放。详见
[CoordinateMapper.swift](Sources/HoverDict/CoordinateMapper.swift) 注释。

## 致谢

- 词库:[ECDICT](https://github.com/skywind3000/ECDICT)(开源英汉词典,含音标与中文释义)


