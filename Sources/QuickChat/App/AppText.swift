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
        "Refresh Icon": "刷新图标", "Refreshing Icon…": "正在刷新图标…",
        "Privacy": "隐私", "Clear All Website Sign-ins…": "清除所有网站登录…",
        "Clear all website data?": "清除所有网站数据？",
        "Clear Website Data": "清除网站数据", "Clearing website data…": "正在清除网站数据…",
        "This signs out every website in Omni and discards open drafts. Your website list and pinned links are kept.": "这会退出 Omni 中所有网站的登录并丢弃打开的草稿。网站列表和固定链接将保留。",
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
        "Advanced": "高级", "Quit Quick Chat Omni": "退出 Quick Chat Omni",
        "Edit": "编辑", "Undo": "撤销", "Redo": "重做", "Cut": "剪切", "Copy": "复制",
        "Paste": "粘贴", "Paste and Match Style": "粘贴并匹配样式", "Select All": "全选",
        "Quick Chat Omni Shortcuts": "Quick Chat Omni 快捷键", "Global Shortcut": "全局快捷键",
        "Reset Window Size": "恢复窗口大小", "Expand or Restore": "展开或还原", "Maximize / Restore Size": "最大化／还原",
        "Reset to": "重置为", "In use": "已被占用",
        "Opens Quick Chat Omni from any app.": "从任何应用打开 Quick Chat Omni。",
        "Works only while Quick Chat Omni is focused.": "仅在 Quick Chat Omni 获得焦点时生效。",
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
