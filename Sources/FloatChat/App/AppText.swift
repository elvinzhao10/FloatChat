import Foundation

/// App-local language preferences. Never changes the Mac's global language settings.
enum AppText {
    static let supported = ["en", "zh-Hans", "system"]
    static var language: String {
        let value = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        return supported.contains(value) ? value : "en"
    }
    static func webTag(for language: String) -> String {
        switch language {
        case "en": return "en-US"
        case "zh-Hans": return "zh-CN"
        default:
            return (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String])?.first ?? "en-US"
        }
    }
    static func applyOwnLanguage() {
        if language == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([webTag(for: language)], forKey: "AppleLanguages") }
    }
    static func t(_ text: String) -> String {
        guard webTag(for: language).hasPrefix("zh") else { return text }
        if let value = chinese[text] { return value }
        if text.hasSuffix("…"), let value = chinese[String(text.dropLast())] { return value + "…" }
        return text
    }
    private static let chinese: [String: String] = [
        "Website Icon": "网站图标", "Choose Icon…": "选取图标…", "Use Website Icon": "使用网站图标",
        "Couldn’t use this icon.": "无法使用此图标。", "Choose a PNG, JPEG, GIF, ICO, or WebP image under 5 MB.": "请选择小于 5 MB 的 PNG、JPEG、GIF、ICO 或 WebP 图片。",
        "Floating Window": "悬浮窗口", "Translucency": "透明度",
        "Open window at": "窗口打开位置", "Last position": "上次位置", "Default position": "默认位置",
        "Hide when clicking outside": "点击窗口外时隐藏", "Website Zoom": "网页缩放",
        "Website zoom shortcuts": "网页缩放快捷键", "You’re offline.": "当前没有网络连接。",
        "Still loading…": "页面仍在加载…", "Loading…": "正在加载…",
        "Keep inactive chats": "保留闲置的聊天",
        "After the time expires, instant chats start fresh and pins reopen their saved conversation. Sign-ins are kept.": "保留时间结束后，即时聊天会重新开始，固定聊天会打开保存的会话。登录状态会保留。",
        "Releasing a page keeps sign-ins and pinned links. Unsent text or an ongoing reply may be lost.": "释放页面会保留登录状态和固定链接。未发送的文字可能丢失，正在生成的回复可能中断。",
        "Launch at Login": "登录时启动", "Approve in Login Items…": "在登录项中允许…",
        "Couldn’t change Launch at Login.": "无法更改登录时启动设置。",
        "Generating reply": "正在生成回复",
        "Show reply indicator": "显示回复指示灯",
        "Chat is generating. Click to reopen or drag to move.": "正在生成回复。点按打开聊天，或拖动指示灯。",
        "Background replies have a small ring on their tab. A movable dot appears when the window is hidden.": "后台生成回复的标签会显示小圆环。窗口隐藏时，会显示可拖动的指示灯。",
        "Let the desktop show through website backgrounds while keeping text and controls opaque.": "让桌面透过网页背景显示，同时保持文字和控件清晰。",
        "Hide the chat window when you click elsewhere. Settings can stay open alongside it.": "点按其他位置时隐藏聊天窗口。设置窗口可以同时保持打开。",
        "Help": "帮助",
        "Check for Updates…": "检查更新…", "Edit Website": "编辑网站",
        "Rename Pinned Chat": "重命名已固定的聊天", "Save": "保存",
        "Zoom In": "放大", "Zoom Out": "缩小", "Actual Size": "实际大小",
        "Downloaded": "下载完成", "Show in Finder": "在访达中显示",
        "Couldn’t load this website.": "无法加载此网站。", "Retry": "重试",
        "Open in Browser": "在浏览器中打开", "None": "无", "Clear": "清除",
        "Refresh Icon": "刷新图标", "Refreshing Icon…": "正在刷新图标…",
        "Privacy": "隐私", "Clear All Website Sign-ins…": "清除所有网站登录…",
        "Clear all website data?": "清除所有网站数据？",
        "Clear Website Data": "清除网站数据", "Clearing website data…": "正在清除网站数据…",
        "This signs out every website in FloatChat and discards open drafts. Your website list and pinned links are kept.": "这会退出 FloatChat 中所有网站的登录并丢弃打开的草稿。网站列表和固定链接将保留。",
        "Chats": "聊天", "General": "通用", "Switch Chat": "切换聊天",
        "Web Pages": "网页", "Shortcuts": "快捷键",
        "Chats & Websites": "聊天与网站", "Your space for quick chats": "你的快捷聊天空间",
        "Drag rows or group handles to arrange.": "拖动聊天或分组手柄来调整顺序。",
        "Instant Chats": "即时聊天", "Pinned Conversations": "已固定的会话",
        "Move group first": "将此分组移到前面",
        "Drag to move this group": "拖动以移动分组", "Unpin & close": "取消固定并关闭",
        "Remove Website": "移除网站", "Remove": "移除", "Cancel": "取消",
        "Show in the chat strip": "在聊天栏中显示", "Website name": "网站名称",
        "Website address": "网站地址", "Add Website": "添加网站", "Keep inactive pages": "保留非活动页面",
        "Release immediately": "立即释放", "min": "分钟", "Shortcuts…": "快捷键…",
        "Language": "语言", "System Default": "跟随系统", "App and website language": "应用与网站语言",
        "New pages use this language. A website's own saved language can take priority.": "新页面将使用此语言；网站自身保存的语言设置可能优先。",
        "Reload open chats…": "重新加载打开的聊天…", "Reload open chats?": "重新加载打开的聊天？",
        "Reload": "重新加载", "This keeps sign-ins and pinned links. Unsent drafts in open pages may be lost.": "登录状态和固定链接将保留，但打开页面中未发送的草稿可能丢失。",
        "Instant chats stay temporary. Unpin closes a saved tab; removing a website keeps its account and sign-in data.": "即时聊天保持临时状态。取消固定将关闭保存的标签；移除网站不会删除账户或登录数据。",
        "Enter a name and a unique HTTPS website address.": "请输入名称和未添加过的 HTTPS 网站地址。",
        "Hide Chat": "隐藏聊天", "Pin Conversation": "固定会话", "Pin this conversation": "固定此会话",
        "Unpin and close this chat": "取消固定并关闭此聊天", "Continue in Default Browser": "在默认浏览器中继续",
        "Settings": "设置", "New chat": "新聊天", "Open Chat": "打开聊天",
        "Keep Inactive Pages": "保留非活动页面", "Release Immediately": "立即释放",
        "Keyboard Shortcuts…": "键盘快捷键…", "Enable Global Shortcut": "启用全局快捷键",
        "Advanced": "高级", "Quit FloatChat": "退出 FloatChat",
        "Edit": "编辑", "Undo": "撤销", "Redo": "重做", "Cut": "剪切", "Copy": "复制",
        "Paste": "粘贴", "Paste and Match Style": "粘贴并匹配样式", "Select All": "全选",
        "FloatChat Shortcuts": "FloatChat 快捷键", "Global Shortcut": "全局快捷键",
        "Reset Window Size": "恢复窗口大小", "Expand or Restore": "展开或还原", "Maximize / Restore Size": "最大化／还原",
        "Reset to": "重置为", "In use": "已被占用",
        "Opens FloatChat from any app.": "从任何应用打开 FloatChat。",
        "Works only while FloatChat is focused.": "仅在 FloatChat 获得焦点时生效。",
        "ChatGPT Mini has no shortcut assigned. Other apps may still use a combination.": "ChatGPT Mini 未设置快捷键，但其他应用仍可能占用组合键。",
        "Removes this website from your list. Your account, conversations and sign-in data are kept. You can add it again later.": "将此网站从列表中移除，保留你的账户、会话和登录数据。之后可重新添加。",
        "Closes this chat tab and removes its saved link. Unsent drafts in this tab will be lost. The conversation on the website and your sign-in data are kept.": "关闭此聊天标签并移除保存的链接。此标签内未发送的草稿将丢失，网站上的会话和登录数据将保留。",
        "Done": "完成", "Available to register. macOS cannot reveal every app's shortcuts.": "此快捷键可以注册。macOS 无法列出所有应用的快捷键。",
        "Unavailable for global registration. Another app may be using it.": "无法注册为全局快捷键，可能正被其他应用使用。",
        "Reserved by macOS. Choose another combination.": "此组合由 macOS 保留，请选择其他组合。",
        "Available for global registration right now": "当前可以注册为全局快捷键",
        "Click, then press a key combination to record a shortcut.": "点击后按下组合键来录制快捷键。"
    ]
}
