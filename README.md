# HoverDict — OCR 取词工具

鼠标悬停在屏幕英文单词上 → 截图 OCR → 在光标下方弹出浮窗显示**单词 + 音标 + 中文释义**,
可朗读。

技术栈:Swift + AppKit(浮窗用 `NSPanel`)、ScreenCaptureKit 截图、Vision OCR、
ECDICT 本地词库(SQLite)、NaturalLanguage 词形还原、AVSpeechSynthesizer 朗读。
最低 macOS 14.0(本机用 CLT 即可构建,无需完整 Xcode)。

**词库**:`Resources/ecdict.db`(125MB,135 万单词,自带音标+中文释义)是从开源
[ECDICT](https://github.com/skywind3000/ECDICT) 的 SQLite 版瘦身而来——只保留单词
(丢弃词组)+ `word/phonetic/translation` 三列。查词:先精确匹配,查不到则用
NaturalLanguage 还原词形(running→run)再查。打包时由脚本拷进 `.app` 的 Resources。

---

## 1. 构建与运行

只需 Command Line Tools(无需完整 Xcode)即可构建签名 `.app`。

**首次克隆后,先获取词库**(125MB,未随仓库提供):

```bash
./Scripts/fetch_dict.sh          # 下载 ECDICT 并生成 Resources/ecdict.db
./Scripts/create_signing_cert.sh # 一次性创建稳定自签名证书(屏幕录制授权不掉)
```

然后构建运行:

```bash
make run          # 编译 → 打包签名 .app → 杀旧进程 → 启动
# 相关命令:
#   make app      # 只打包,不启动
#   make stop     # 退出运行中的实例
#   make dmg      # 打包成可分发 DMG
```

> ⚠️ **务必通过 `.app` 启动**(`open build/HoverDict.app`),不要直接跑
> `.build/release/HoverDict`。屏幕录制权限绑定的是 `.app` 的 bundle id + 签名,
> 直接跑裸二进制会被归到「终端」名下,权限不生效。

### 首次运行:授予屏幕录制权限

1. 第一次启动会弹出系统提示,并把 **HoverDict** 加入
   **系统设置 → 隐私与安全性 → 屏幕录制** 列表;应用自带的弹窗里点「打开系统设置」。
2. 在列表里**勾选 HoverDict**。
3. **重新启动应用**(屏幕录制授权后必须重启进程才生效):
   ```bash
   make run
   ```

启动成功后没有 Dock 图标(它是 accessory/agent 应用)。把鼠标停在任意英文单词上
约 0.2 秒,光标下方就会冒出浮窗显示该单词,点 🔊 朗读。

### 签名与"授权不掉"

本机没有 Apple 证书。为避免 ad-hoc 签名每次重编 cdhash 变化导致**屏幕录制授权反复失效**,
本项目用一个**本地稳定自签名证书** `HoverDict Dev`:

```bash
./Scripts/create_signing_cert.sh    # 一次性创建(已执行过则跳过)
```

它让签名的 designated requirement 变成 `identifier "com.hoverdict.HoverDict" and
certificate root = …`,**与 cdhash 无关**,所以屏幕录制**授权一次就长期有效**,
之后随便重编都不掉。`build_app.sh` 会自动优先使用这个证书。

> 切换签名身份后,旧的授权记录会对不上,需要清一次重授:
> ```bash
> tccutil reset ScreenCapture com.hoverdict.HoverDict
> ```
> 然后重启 App,按提示重新勾选屏幕录制即可(这是最后一次)。

要换正式证书(为公证铺路):

```bash
CODESIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" ./Scripts/build_app.sh
```

---

## 2. 代码结构(按模块)

```
Sources/HoverDict/
  main.swift               入口:以 .accessory 启动 NSApplication(不抢焦点、无 Dock 图标)
  AppDelegate.swift        串联整条流水线 + 权限引导
  PermissionManager.swift  屏幕录制权限检测/请求/打开设置
  MouseMonitor.swift       全局鼠标移动监听 + 200ms 静止防抖
  ScreenCapturer.swift     ScreenCaptureKit 截光标周围 260×100pt 区域(含坐标系换算)
  OCRService.swift         Vision VNRecognizeTextRequest(.accurate),输出逐词归一化框
  CoordinateMapper.swift   ★ 坐标换算 + 命中测试(最易出 bug,注释最密)
  DictionaryService.swift  ECDICT SQLite 查词 + NaturalLanguage 词形还原
  OverlayPanel.swift       非激活浮窗 NSPanel(单词+音标+释义)+ 🔊 朗读
  StatusBarController.swift 菜单栏图标:暂停/继续、打开权限设置、退出
Resources/
  Info.plist               .app 的 bundle 配置(bundle id / LSUIElement 等)
  HoverDict.entitlements    非沙盒声明(留给后续公证 + Hardened Runtime)
  ecdict.db                 精简版 ECDICT 词库(125MB,135 万单词)
Scripts/build_app.sh       用 CLT 把 SwiftPM 产物组装成签名 .app(并拷入词库)
Scripts/create_signing_cert.sh  一次性创建稳定自签名证书 "HoverDict Dev"
Makefile                   make build / app / run / clean
```

### 坐标换算的关键链路(三处坐标系)

取词工具最容易在坐标系上翻车,这里把每一步拆清楚:

- **Vision 框**:归一化 `0...1`,原点在图像**左下**。
- **AppKit 全局屏幕坐标**:点(point),原点在主屏**左下**(`NSEvent.mouseLocation`、
  `NSWindow.setFrameOrigin` 都用这个空间)。
- **ScreenCaptureKit `sourceRect`**:点,原点在显示器**左上**。

要点:**上下翻转和 Retina 像素缩放在「截图阶段」就处理掉了**
(`ScreenCapturer.sourceRect(forGlobalRect:on:)` 把全局左下 rect 换成显示器左上 rect,
并用 `width/height = points × backingScaleFactor` 输出原生分辨率)。因此截出的图像
**正好覆盖** `captureRectGlobal`,而 Vision 与 AppKit **都用左下原点**,
于是把 Vision 框换回屏幕坐标只是一次纯线性缩放(`CoordinateMapper.globalRect`)——
不再需要二次翻转或缩放。

**命中测试**(`CoordinateMapper.wordUnderCursor`,严格模式):光标水平落在词框内、
垂直落在词框「底边 → 顶边 + 6pt 上边距」之间才算命中(人通常把指针压在词的顶部或略上方);
多个候选取垂直中心离光标最近的那行。正下方没有任何词 → 返回 nil → **不弹窗**。

---

## 3. 在三个目标应用里实测识别率

这三者底层都是 Web 渲染(Electron/Chromium 或 WebKit),所以取词主力是屏幕 OCR。
启动 HoverDict 后,鼠标悬停约 0.2 秒触发,观察浮窗里显示的单词是否 = 光标正下方的词。

### Claude 桌面客户端
- 打开任意一段英文回答,把鼠标停在不同英文单词上。
- 重点测:正文(中等字号)、代码块(等宽字体)、粗体/标题。
- 代码块里下划线/反引号可能影响分词,留意是否把 `foo_bar` 切成两词。

### 浏览器(Chrome / Edge / Safari 均可)
- 找一个正文密集的英文网页(如 Wikipedia 英文条目)。
- 测不同缩放级别(⌘+/⌘-):放大后字号更大,OCR 识别率应更高。
- 测深色模式 vs 浅色模式;浅底黑字通常最稳。

### VS Code
- 打开一个英文注释/标识符较多的源码文件。
- 测不同字号(设置 `editor.fontSize`)和主题(浅色主题识别率通常更高)。
- 等宽字体 + 语法高亮的彩色文字是 OCR 较难的场景,适合用来找弱点。

### 评估建议
- **命中准确性**:浮窗显示的词是否就是光标正下方那个词(而非邻词)。若经常偏到上一行/下一行,
  调 `CoordinateMapper.wordUnderCursor` 的 `topMargin`;若偏到左右邻词,调 `horizontalSlop`。
- **识别率**:小字号是 OCR 主要瓶颈。可调大 `ScreenCapturer.captureSize` 或确认输出用了
  `backingScaleFactor`(代码已用)。字号 < ~12pt 时识别率会明显下降。
- **多屏/Retina**:把窗口拖到外接显示器(尤其非 Retina 或不同缩放)再测,验证坐标换算在
  多屏下不偏移。

---

## 4. 打包分发(DMG)

```bash
make dmg     # → build/HoverDict-0.1.dmg(约 64MB,arm64)
```

这是**免费、自签名、未公证**的 DMG:能发给别人,但因为没走 Apple 公证,
**收件人首次打开需绕过门禁**(只需一次):

1. 打开 DMG,把 HoverDict 拖进 Applications。
2. 首次启动:**右键点 HoverDict.app → 打开 → 再点「打开」**。
   - 若提示「已损坏」:`xattr -dr com.apple.quarantine /Applications/HoverDict.app`
3. 首次会请求「屏幕录制」权限,按提示在系统设置勾选后重启 App。

> 当前仅 **Apple 芯片(arm64)**。Intel Mac 需改为通用二进制
> (`swift build --arch arm64 --arch x86_64` 后 lipo 合并)。

### 要做到「双击即用、零警告」(后续)

需付费 Apple Developer 账号($99/年):
Developer ID Application 证书 → 开启 Hardened Runtime 签名(用 `Resources/HoverDict.entitlements`)
→ `xcrun notarytool submit` 公证 → `xcrun stapler staple` → 再打 DMG。
届时把 `CODESIGN_IDENTITY` 换成 Developer ID 即可复用现有脚本。

## 5. 暂未实现(后续)
- Safari 的 Accessibility 快路
- 多语言 / 设置界面 / 自动更新
- Developer ID 签名 + 公证(`entitlements` 已就位,届时启用 Hardened Runtime)
- Intel / 通用二进制
