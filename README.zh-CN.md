<div align="center">
  <img src="Resources/AppIcon-Omni-1024.png" width="104" alt="Quick Chat Omni 应用图标">
  <h1>Quick Chat Omni</h1>
  <p><strong>常用的聊天网站，集中在一个 Mac 悬浮窗口里。</strong></p>
  <p><a href="https://github.com/elvinzhao10/QuickChat-Omni/releases/latest"><strong>下载 Mac 版</strong></a> · <a href="README.md">English</a> · <a href="CHANGELOG.md">更新日志</a></p>
  <p>macOS 14 或更高版本 · 支持 Apple 芯片和 Intel Mac</p>
  <p><img src="docs/images/panel.png" width="350" alt="Quick Chat Omni 悬浮窗口，顶部显示网站图标，当前打开 ChatGPT"></p>
  <p>ChatGPT · Claude · DeepSeek · Kimi · Gemini · Perplexity · Copilot · Grok</p>
</div>

## 安装与启动

1. 下载 **DMG**，打开后将 **Quick Chat Omni** 拖入**应用程序**文件夹。ZIP 版包含同一个应用。
2. 从**应用程序**打开 Omni。之后可点击菜单栏图标重新打开窗口，或在**设置 → 通用**启用全局快捷键 **⌥Space**。
3. 点击网站图标，直接使用已有账户登录。Omni 无需 API 密钥。

<p><img src="docs/images/menu-bar.png" width="160" alt="浅色和深色菜单栏中的 Omni 图标"></p>

<details>
<summary>如果 macOS 阻止首次启动</summary>

社区版本使用临时签名，尚未经过 Apple 公证。尝试打开应用后，确认安装包来自项目的官方发布页，然后选择**系统设置 → 隐私与安全性 → 仍要打开**。[Apple 的安全打开应用指南](https://support.apple.com/zh-cn/102445)

</details>

## 使用悬浮窗口

| 操作 | 方法 |
| --- | --- |
| 切换聊天 | 点击网站图标或按 **⌘1–9**。横向滚动图标栏可查看更多标签。 |
| 固定会话 | 点击图钉保存会话链接。即时聊天和固定会话在同一栏内，以细线分隔。将指针停在固定标签上可看会话主题。取消固定会关闭该标签。 |
| 移动或调整大小 | 拖动窗口顶部移动，拖动角落调整大小，双击顶部放大或还原。 |
| 在浏览器中继续 | 点击箭头，在默认浏览器中打开当前页面。网站要求在浏览器登录或上传时，也可以用这个入口。 |
| 上传或下载文件 | 网站支持时，可使用上传按钮、粘贴或拖入文件。下载完成后，可点击**在访达中显示**查看文件。 |

## 自定义

<img src="docs/images/websites.png" width="460" alt="聊天设置页面，显示网站开关以及添加网站的输入框">

点击窗口的滑杆图标，或在菜单栏选择**设置…**。

- **聊天**管理网站和固定会话。可添加 HTTPS 网站、修改地址、重命名固定会话、拖动排序或隐藏网站。右键点击标签可以查看当前主机名或调整网页缩放。
- **通用**管理语言、登录时启动、快捷键和页面保留时间。网站可能优先使用自身保存的语言设置。

## 页面保留与登录

Omni 使用 macOS 原生 Swift、AppKit 和 WebKit。默认最多在内存中保留三个隐藏或闲置页面，每个最多保留 10 分钟。在**设置 → 通用**中选择**立即释放**可更快释放闲置页面。释放页面可能丢失未发送的文字或中断回复，但会保留固定链接和网站登录状态。

Omni 与默认浏览器分别管理登录状态。隐藏或移除网站会保留它的本地登录。自定义网站图标通过独立的 HTTPS 会话直接向该网站获取，不携带聊天页面的 Cookie。

<details>
<summary>清除网站数据或卸载</summary>

卸载前，选择**设置 → 通用 → 隐私 → 清除所有网站登录…**并等待完成。此操作会清除 Omni 的本地网站数据。如果已经卸载，可从官方发布页重新安装，完成清除后退出并再次卸载。

如需手动清理，先退出 Omni。在 Finder 中按 **⇧⌘G**，分别检查 `~/Library/WebKit`、`~/Library/HTTPStorages` 和 `~/Library/Caches`。如果存在名为 `dev.quickchat.omni` 的文件夹，仅将该文件夹移入废纸篓。存储位置可能因 macOS 版本而异。需要完整清除登录时，建议使用应用内功能。

</details>

## 项目

[发布记录](https://github.com/elvinzhao10/QuickChat-Omni/releases) · [更新日志](CHANGELOG.md) · [发布检查](docs/RELEASE-AUDIT.md) · [MIT 许可证](LICENSE)

<details>
<summary>从源代码构建</summary>

安装 Apple 命令行工具后运行 `make app`。应用会生成在 `build/Quick Chat Omni.app`。

</details>

基于 [shuaibird/Quick-Chat](https://github.com/shuaibird/Quick-Chat) 开发。各网站的名称与图标归其权利人所有。
