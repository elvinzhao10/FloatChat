<div align="center">
  <img src="Resources/AppIcon-Omni-1024.png" width="112" alt="Quick Chat Omni 图标">
  <h1>Quick Chat Omni</h1>
  <p><strong>常用的聊天网站，集中在一个 macOS 悬浮窗口里。</strong></p>
  <p>ChatGPT · Claude · DeepSeek · Kimi · Gemini · Perplexity · Copilot · Grok</p>
  <p><a href="https://github.com/elvinzhao10/QuickChat-Omni/releases/latest"><strong>下载 Mac 版</strong></a> · <a href="README.md">English</a></p>
</div>

Quick Chat Omni 将常用的聊天网站放进一个可移动、可调整大小的悬浮窗口。点击网站图标即可切换，用该网站的账户直接登录。应用无需 API 密钥，各网站的账户与订阅规则照常适用。

<p align="center"><img src="docs/images/panel.png" width="400" alt="悬浮聊天窗口和网站切换栏"></p>

### 安装

1. 在 [GitHub 发布页](https://github.com/elvinzhao10/QuickChat-Omni/releases/latest) 下载 **DMG**。
2. 打开磁盘映像，将 **Quick Chat Omni** 拖入**应用程序**文件夹。
3. 从**应用程序**打开 Quick Chat Omni，然后选择一个聊天网站。

也可以下载 ZIP，解压后将应用拖入**应用程序**。两个安装包都支持运行 macOS 14 或更高版本的 Apple 芯片与 Intel Mac。

当前社区版本使用临时签名，尚未经过 Apple 公证。如果 macOS 阻止首次启动，请先确认安装包来自本项目的发布页。尝试打开应用后，进入**系统设置 → 隐私与安全性**，点击**仍要打开**，然后按提示确认。详见 [Apple 的安全打开应用指南](https://support.apple.com/zh-cn/102445)。

### 使用

- **切换聊天。** 点击网站图标或按 **⌘1–9**。即时聊天和已固定的会话在同一条栏中，以细线分隔。可以用触控板或鼠标滚轮浏览。
- **固定会话。** 点击图钉保存会话链接。即使页面被释放或应用退出，链接仍可重新打开。取消固定会关闭该标签页。未发送的草稿仅保留在仍然打开的页面中。
- **整理网站。** 点击滑杆图标打开**设置 → 聊天**，可添加 HTTPS 网站、调整顺序、隐藏或移除条目。
- **常规设置。** 可选择界面和网页的首选语言、设置闲置页面保留时间，并在**通用**中启用或配置全局快捷键。默认快捷键为 **⌥Space**。网站自身的语言设置可能优先。
- **窗口与附件。** 拖动顶部空白处移动窗口，从角落调整大小，双击顶部可放大或还原。网站支持时，可上传、粘贴或拖入文件和截图。点击箭头可在默认浏览器中打开当前页面。

<p align="center"><img src="docs/images/websites.png" width="370" alt="聊天网站管理界面"> <img src="docs/images/general.png" width="370" alt="语言、页面保留时间与快捷键设置"></p>

### 隐私与页面保留

应用使用 macOS 原生 Swift、AppKit 和 WebKit。默认最多保留三个闲置页面，每个保留 10 分钟。选择**立即释放**可以减少内存占用。

登录由各网站处理。隐藏网站会保留登录状态。卸载前，如需清除应用保存的网站数据，请使用**设置 → 通用 → 隐私 → 清除所有网站登录…**。将应用拖入废纸篓后，本地网站数据仍会留在 Mac 上。部分网站限制内嵌登录或上传，可以改用默认浏览器继续。

<details>
<summary>从源代码构建</summary>

安装 Apple 命令行工具后运行 `make app`，应用将生成在 `build/Quick Chat Omni.app`。测试覆盖和已知限制见[发布检查记录](docs/RELEASE-AUDIT.md)。

</details>

基于 [shuaibird/Quick-Chat](https://github.com/shuaibird/Quick-Chat) 开发，采用 [MIT 许可证](LICENSE)。各网站的名称和图标归其权利人所有。
