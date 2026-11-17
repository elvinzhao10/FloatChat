import SwiftUI
import ServiceManagement

final class ChatSettingsFields: ObservableObject {
    @Published var name = ""
    @Published var address = ""
    @Published var invalid = false
    @Published var hovered: String?
    @Published var draggedGroup: Bool?
    @Published var zoomRow: String?
    @Published var zoomDraft = 1.0
}

struct ChatSettingsView: View {
    struct Row: Identifiable {
        let id: String
        let index: Int
        let name: String
        let url: URL
        let pinned: Bool
        let custom: Bool
        let refreshingIcon: Bool
        let enabled: Bool
    }
    struct ShortcutControl: Identifiable {
        let id: String
        let title: String
        let checked: Bool
        let enabled: Bool
        let detail: String?
        let toggle: () -> Void
    }
    @ObservedObject var fields: ChatSettingsFields
    let pinnedFirst: Bool
    let setPinnedFirst: (Bool) -> Void
    let language: String
    let setLanguage: (String) -> Void
    let loginStatus: SMAppService.Status
    let setLaunchAtLogin: (Bool) -> Void
    let editEntry: (Int) -> Void
    let refreshIcon: (URL) -> Void
    let clearWebsiteData: () -> Void
    let clearingWebsiteData: Bool
    let reloadPages: () -> Void
    let glassEnabled: Bool
    let centerOnOpen: Bool
    let hideOnClickAway: Bool
    let zoomKeysEnabled: Bool
    let setPanelPreference: (Bool, String) -> Void
    let zoomFor: (String) -> Double
    let setZoom: (String, Double) -> Void
    let retention: Int
    let setRetention: (Int) -> Void
    let shortcutControls: [ShortcutControl]
    let shortcuts: () -> Void
    let reorder: (IndexSet, Int) -> Void
    let remove: (Int) -> Void
    let unpin: (Int) -> Void
    let providers: [Row]
    let toggle: (Int) -> Void
    let add: (String, String) -> Bool
    private static let groupDragType = "dev.quickchat.omni.chat-group"

    private func move(_ offsets: IndexSet, to destination: Int, pinned: Bool) {
        let group = providers.filter { $0.pinned == pinned }
        let originals = IndexSet(offsets.map { group[$0].index })
        let target = destination < group.count ? group[destination].index : (group.last?.index ?? -1) + 1
        reorder(originals, target)
    }
    private func groupHeader(_ pinned: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Text(AppText.t(pinned ? "Pinned Conversations" : "Instant Chats")).font(.caption.weight(.semibold))
            Spacer()
        }.padding(.vertical, 4).foregroundStyle(.secondary)
            .help(AppText.t("Drag to move this group"))
            .onDrag {
                fields.draggedGroup = pinned
                let item = NSItemProvider()
                item.registerDataRepresentation(forTypeIdentifier: Self.groupDragType, visibility: .ownProcess) { completion in
                    completion(Data([pinned ? UInt8(1) : UInt8(0)]), nil)
                    return nil
                }
                return item
            }.onDrop(of: [Self.groupDragType], isTargeted: nil) { _ in
                guard let source = fields.draggedGroup, source != pinned else { return false }
                fields.draggedGroup = nil
                setPinnedFirst(!pinnedFirst)
                return true
            }.accessibilityLabel(AppText.t(pinned ? "Pinned Conversations" : "Instant Chats"))
            .accessibilityAction(named: Text(AppText.t("Move group first"))) { setPinnedFirst(pinned) }
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
    }
    private func chatRow(_ provider: Row) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: ProviderIcon.image(for: provider.url, size: 22))
                .resizable().scaledToFit().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).fontWeight(.medium).lineLimit(1)
                Text(provider.url.host ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            zoomControl(provider)
            if provider.custom || provider.pinned {
                Button { editEntry(provider.index) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain)
                    .help(AppText.t(provider.pinned ? "Rename Pinned Chat" : "Edit Website"))
                    .accessibilityLabel(AppText.t(provider.pinned ? "Rename Pinned Chat" : "Edit Website"))
            }
            if provider.custom {
                Button { refreshIcon(provider.url) } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.plain)
                    .disabled(provider.refreshingIcon)
                    .help(AppText.t(provider.refreshingIcon ? "Refreshing Icon…" : "Refresh Icon"))
                    .accessibilityLabel(AppText.t("Refresh Icon") + " " + provider.name)
            }
            Toggle(provider.name, isOn: Binding(get: { provider.enabled }, set: { _ in toggle(provider.index) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help(AppText.t("Show in the chat strip"))
            if provider.pinned {
                Button(AppText.t("Unpin & close")) { unpin(provider.index) }
                    .buttonStyle(.link).font(.caption)
            } else {
                Button { remove(provider.index) } label: {
                    Image(systemName: "trash").foregroundStyle(fields.hovered == provider.id ? .red : .secondary)
                }.buttonStyle(.plain).opacity(fields.hovered == provider.id ? 1 : 0.35)
                    .help(AppText.t("Remove Website")).accessibilityLabel(AppText.t("Remove Website") + " " + provider.name)
                    .disabled(providers.count == 1)
            }
        }.padding(.vertical, 4).onHover { inside in fields.hovered = inside ? provider.id : nil }
            .listRowBackground(Color.clear)
    }
    private func zoomControl(_ provider: Row) -> some View {
        let showing = Binding(get: { fields.zoomRow == provider.id }, set: {
            if !$0 && fields.zoomRow == provider.id { fields.zoomRow = nil }
        })
        let zoom = Binding(get: { fields.zoomDraft }, set: {
            setZoom(provider.id, $0)
            fields.zoomDraft = $0
        })
        let percent = zoomFor(provider.id).formatted(.percent.precision(.fractionLength(0)))
        return Button {
            fields.zoomDraft = zoomFor(provider.id)
            fields.zoomRow = provider.id
        } label: {
            Text(percent).font(.caption.monospacedDigit())
        }
        .buttonStyle(.borderless)
        .help(AppText.t("Website Zoom"))
        .accessibilityLabel(AppText.t("Website Zoom") + " " + percent)
        .popover(isPresented: showing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(AppText.t("Website Zoom")).font(.headline)
                Slider(value: zoom, in: 0.6...2, step: 0.05) { Text(AppText.t("Website Zoom")) }
                    .labelsHidden()
                HStack {
                    Text(fields.zoomDraft.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                    Spacer()
                    Button(AppText.t("Actual Size")) { zoom.wrappedValue = 1 }
                }
            }
            .padding(14)
            .frame(width: 210)
        }
    }

    var body: some View {
        TabView {
            chats.tabItem { Label(AppText.t("Chats"), systemImage: "bubble.left.and.bubble.right") }
            general.tabItem { Label(AppText.t("General"), systemImage: "gearshape") }
        }.padding(14).frame(width: 480, height: 520)
    }

    private var chats: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppText.t("Drag rows or group handles to arrange."))
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(pinnedFirst ? [true, false] : [false, true], id: \.self) { pinned in
                    if !pinned || providers.contains(where: \.pinned) {
                        groupHeader(pinned)
                        ForEach(providers.filter { $0.pinned == pinned }) { provider in chatRow(provider) }
                            .onMove { move($0, to: $1, pinned: pinned) }
                    }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
            HStack(spacing: 12) {
                TextField(AppText.t("Website name"), text: $fields.name).frame(width: 120)
                TextField(AppText.t("Website address"), text: $fields.address)
                Button {
                    fields.invalid = !add(fields.name.trimmingCharacters(in: .whitespacesAndNewlines), fields.address)
                    if !fields.invalid { fields.name = ""; fields.address = "" }
                } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                    .buttonStyle(.plain).help(AppText.t("Add Website")).accessibilityLabel(AppText.t("Add Website"))
                    .disabled(fields.name.isEmpty || fields.address.isEmpty)
            }.textFieldStyle(.plain).padding(.vertical, 6)
            if fields.invalid { Text(AppText.t("Enter a name and a unique HTTPS website address.")).font(.caption).foregroundStyle(.red) }
        }.padding(12)
    }

    private func panelSetting(_ value: Bool, _ key: String) -> Binding<Bool> {
        Binding(get: { value }, set: { setPanelPreference($0, key) })
    }

    private var general: some View {
        Form {
            Toggle(AppText.t("Launch at Login"), isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: { setLaunchAtLogin($0) }))
            if loginStatus == .requiresApproval {
                Button(AppText.t("Approve in Login Items…")) { SMAppService.openSystemSettingsLoginItems() }
            }
            Section(AppText.t("Floating Window")) {
                Toggle(AppText.t("Translucent background"), isOn: panelSetting(glassEnabled, "glassEnabled"))
                Picker(AppText.t("Open window at"), selection: panelSetting(centerOnOpen, "centerOnOpen")) {
                    Text(AppText.t("Last position")).tag(false)
                    Text(AppText.t("Default position")).tag(true)
                }
                Toggle(AppText.t("Hide when clicking outside"), isOn: panelSetting(hideOnClickAway, "hideOnClickAway"))
            }
            Section(AppText.t("Web Pages")) {
                Picker(AppText.t("Language"), selection: Binding(get: { language }, set: { setLanguage($0) })) {
                    Text("English").tag("en")
                    Text("简体中文").tag("zh-Hans")
                    Text(AppText.t("System Default")).tag("system")
                }
                Text(AppText.t("New pages use this language. A website's own saved language can take priority."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(AppText.t("Reload open chats…"), action: reloadPages)
                Picker(AppText.t("Keep hidden and inactive pages"), selection: Binding(get: { retention }, set: { setRetention($0) })) {
                    Text(AppText.t("Release immediately")).tag(0)
                    ForEach([1, 5, 10, 30], id: \.self) { Text("\($0) " + AppText.t("min")).tag($0) }
                }
                Text(AppText.t("Releasing a page keeps sign-ins and pinned links. Unsent text or an ongoing reply may be lost."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(AppText.t("Shortcuts")) {
                Toggle(AppText.t("Website zoom shortcuts") + " (⌘+, ⌘−)", isOn: panelSetting(zoomKeysEnabled, "zoomKeysEnabled"))
                ForEach(shortcutControls) { control in
                    Toggle(control.title, isOn: Binding(get: { control.checked }, set: { _ in control.toggle() }))
                        .disabled(!control.enabled)
                    if let detail = control.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button(AppText.t("Keyboard Shortcuts…"), action: shortcuts)
            }
            Section(AppText.t("Privacy")) {
                Button(AppText.t(clearingWebsiteData ? "Clearing website data…" : "Clear All Website Sign-ins…"),
                       action: clearWebsiteData)
                    .disabled(clearingWebsiteData)
            }
        }.formStyle(.grouped)
    }
}
