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
    let providers: [Row]
    let toggle: (Int) -> Void
    let add: (String, String) -> Bool
    @ObservedObject private var fields = ChatSettingsFields()

    var body: some View {
        Form {
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
                if fields.invalid { Text("Enter a name and a valid HTTPS address.").foregroundStyle(.red).font(.caption) }
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
