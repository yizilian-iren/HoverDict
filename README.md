# HoverDict

把鼠标停在屏幕上的英文单词上,光标下方自动弹出**中文释义**并**朗读**——无需选中、无需复制。

因为取词主力是**屏幕 OCR**(而非 Accessibility API),所以对底层是 Web 渲染的应用同样有效:
Claude 桌面客户端、浏览器(Chrome/Edge/Safari)、VS Code 等。

> 状态:可用的早期版本。当前显示折叠后的中文释义并自动发音。

## 下载安装

👉 **[下载最新版 HoverDict.dmg](https://github.com/yizilian-iren/HoverDict/releases/latest)**(Apple 芯片 / macOS 14+)

### 第 1 步:安装
1. 双击下载好的 `HoverDict-0.1.dmg`
2. 在弹出的窗口里,把 **HoverDict** 图标拖到 **应用程序(Applications)** 文件夹

### 第 2 步:第一次打开(只需做一次)
未经苹果公证的软件,所以第一次打开系统会拦一下:

1. 打开 **应用程序** 文件夹,找到 **HoverDict**
2. **不要双击**,而是 **按住 Control 键点它**(或用触控板双指点),在菜单里选 **打开**
3. 弹出的提示框里再点一次 **打开**

> 如果上面没有「打开」按钮,或提示「已损坏」:
> 打开 **系统设置 → 隐私与安全性**,向下滚动,会看到一行「已阻止打开 HoverDict…」,
> 点它旁边的 **仍要打开**,再确认一次即可。

### 第 3 步:允许「屏幕录制」

1. 第一次运行会提示需要权限,点 **打开系统设置**
2. 在 **屏幕录制** 列表里把 **HoverDict** 的开关打开
3. 退出 HoverDict 再重新打开一次

### 完成 🎉
把鼠标停在任意英文单词上约半秒,下方就会弹出中文意思并自动朗读。

<details>
<summary>极少数情况:以上都打不开、且提示「已损坏」</summary>

打开terminal
粘贴下面这行后按回车,再回到第 2 步:

```
xattr -dr com.apple.quarantine /Applications/HoverDict.app
```
这行的作用是「撕掉系统给下载文件盖的隔离印章」,执行一次即可。
</details>

## 功能

- 🖱️ **悬停取词**:光标静止约 0.1s 即触发,无需点击
- 🔤 **屏幕 OCR**:基于 Vision,适配 Electron/Chromium/WebKit 渲染的文字
- 🇨🇳 **中文释义 + 音标**:离线本地词库([ECDICT](https://github.com/skywind3000/ECDICT)),含词形还原(running→run)
- 🔊 **自动朗读**:悬停即读,另有按钮可重听
- 🪟 **不抢焦点**:非激活浮窗,阅读中的应用保持焦点
- 🎛️ **菜单栏控制**:暂停/继续、退出

## 系统要求

- macOS 14.0 (Sonoma) 及以上
- Apple 芯片(arm64)
- 仅需 **Command Line Tools**(无需完整 Xcode)即可从源码构建

