import SwiftUI

final class ChatSettingsFields: ObservableObject {
    @Published var name = ""
    @Published var address = ""
    @Published var invalid = false
}

struct ChatSettingsView: View {
    struct Row: Identifiable {
        let id: Int
        let name: String
        let host: String
        let enabled: Bool
    }
    @ObservedObject var fields: ChatSettingsFields
    let retention: Int
    let setRetention: (Int) -> Void
    let providers: [Row]
    let toggle: (Int) -> Void
    let add: (String, String) -> Bool

    var body: some View {
        Form {
            Section {
                Picker("Keep inactive pages", selection: Binding(get: { retention }, set: { setRetention($0) })) {
                    Text("Release immediately").tag(0)
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("30 minutes").tag(30)
                }
                Text("Keeps drafts, scroll position and page history for up to three inactive websites. Older pages reload when reopened. macOS may reclaim pages under memory pressure.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Page memory") }
            Section {
                ForEach(providers) { provider in
                    Toggle(isOn: Binding(get: { provider.enabled }, set: { _ in toggle(provider.id) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.name)
                            Text(provider.host).font(.caption).foregroundStyle(.secondary)
                        }
                    }.toggleStyle(.switch)
                }
            } header: { Text("Your chat websites") }
              footer: { Text("Choose which websites appear in the popup. Sign in directly on each website.") }
            Section("Add a website") {
                TextField("Name", text: $fields.name)
                TextField("https://example.com", text: $fields.address)
                if fields.invalid { Text("Enter a name and a unique HTTPS address.").foregroundStyle(.red).font(.caption) }
                Button("Add Website") {
                    fields.invalid = !add(fields.name.trimmingCharacters(in: .whitespacesAndNewlines), fields.address.trimmingCharacters(in: .whitespacesAndNewlines))
                    if !fields.invalid { fields.name = ""; fields.address = "" }
                }.disabled(fields.name.isEmpty || fields.address.isEmpty)
            }
            Section {
                Text("Continue in Browser opens the current page in your default browser. You may need to sign in there separately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 440, height: 560)
    }
}
