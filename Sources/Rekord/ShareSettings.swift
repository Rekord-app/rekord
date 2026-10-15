import SwiftUI
import Security
import RecorderCore
import UniformTypeIdentifiers

struct ShareSettingsView: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismiss) var dismiss
    @State private var address = UserDefaults.standard.string(forKey: "shareServer") ?? ""
    @State private var token = ""
    @State private var message = ""
    @State private var testing = false
    @State private var library = false
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading,spacing: 3) {
                    Text("Per Link teilen").font(StudioFont.pageTitle)
                    Text("Dein eigener Rekord-Share-Server. Hochgeladen wird erst, wenn du teilst oder im Loom-Modus stoppst.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false,vertical: true)
                }
                Spacer()
                Button("Schließen") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading,spacing: 10) {
                Text("Server").eyebrow()
                TextField("https://videos.deine-domain.de",text: $address).textFieldStyle(.roundedBorder).accessibilityLabel("Share-Server")
                SecureField("Upload-Schlüssel",text: $token).textFieldStyle(.roundedBorder).accessibilityLabel("Upload-Schlüssel")
                HStack {
                    Button("Verbindung importieren …") { importConnection() }.buttonStyle(.pill).disabled(testing)
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                    Button("Prüfen & speichern") {
                        testing = true; message = "Verbindung wird geprüft …"
                        Task {
                            defer { testing = false }
                            do {
                                guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ShareError.message("Serveradresse ist ungültig.") }
                                let client = try ShareClient(baseURL: url,token: token)
                                let status = try await client.status()
                                try ShareKeychain.save(token,server: client.baseURL.absoluteString)
                                UserDefaults.standard.set(client.baseURL.absoluteString,forKey: "shareServer")
                                store.shareConfigured = true
                                message = "Verbunden · \(status.availableBytes/1024/1024) MB verfügbar"
                                store.status = "Link-Freigabe eingerichtet"
                            } catch { message = error.localizedDescription }
                        }
                    }.buttonStyle(AccentButtonStyle(height: 32)).disabled(testing || address.isEmpty || token.isEmpty)
                }
                if !message.isEmpty { Text(message).font(StudioFont.caption).foregroundStyle(message.hasPrefix("Verbunden") ? StudioTheme.success : StudioTheme.textSecondary) }
            }.studioCard(padding: 16)
            Text("Der Schlüssel liegt nur im macOS-Schlüsselbund. Wer einen Videolink hat, kann die Aufnahme ansehen; Links lassen sich jederzeit deaktivieren.").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary).fixedSize(horizontal: false,vertical: true)
            if store.shareConfigured {
                HStack {
                    Label("Aktive Links verwalten, ältere Fassungen deaktivieren",systemImage: "list.bullet.rectangle").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                    Spacer()
                    Button("Freigaben verwalten") { library = true }.buttonStyle(.pill)
                }.studioInset()
            }
        }.padding(24).frame(width: 540).background(StudioTheme.background)
        .sheet(isPresented: $library) { ShareLibraryView().environmentObject(store) }
        .onAppear { token = (try? ShareKeychain.read(server: address)) ?? "" }
    }
    private func importConnection() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Verbindungsdatei deines Rekord-Share-Servers auswählen"
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do {
            struct Connection: Decodable { let baseURL: URL; let token: String }
            let connection = try JSONDecoder().decode(Connection.self,from: Data(contentsOf: url))
            let client = try ShareClient(baseURL: connection.baseURL,token: connection.token)
            address = client.baseURL.absoluteString; token = connection.token
            message = "Verbindung geladen · Mit Prüfen & speichern verbinden."
        } catch { message = "Verbindungsdatei konnte nicht geladen werden: \(error.localizedDescription)" }
    }
}
enum ShareKeychain {
    private static let service = "dev.sapunov.Rekord.share"
    /// Item name before the rename; read once, copied to the new name and removed.
    private static let legacyService = "dev.sapunov.FocusRecorder.share"
    /// The key is read from the Keychain once per app run. macOS ties the item's access to the exact build
    /// (cdhash) for locally signed apps, so every read by a new build would otherwise ask for the login password.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String:String] = [:]
    static func read(server: String) throws -> String? {
        // Diagnostics on a differently signed test build: no Keychain prompt (the item is bound to the cdhash).
        if let env = ProcessInfo.processInfo.environment["REKORD_SHARE_TOKEN"] { return env.isEmpty ? nil : env }
        if let token = lock.withLock({ cache[server] }) { return token }
        if let token = try readItem(service: service,server: server) { lock.withLock { cache[server] = token }; return token }
        guard let legacy = try readItem(service: legacyService,server: server) else { return nil }
        try save(legacy,server: server)
        SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:legacyService,kSecAttrAccount as String:server] as CFDictionary)
        return legacy
    }
    private static func readItem(service: String,server: String) throws -> String? {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:server,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,let data = result as? Data else { throw ShareError.message("Upload-Schlüssel konnte nicht aus dem Schlüsselbund gelesen werden.") }
        return String(data: data,encoding: .utf8)
    }
    static func remove(server: String) {
        lock.withLock { _ = cache.removeValue(forKey: server) }
        SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:server] as CFDictionary)
    }
    static func save(_ token: String,server: String) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:server]
        let data = Data(token.utf8)
        var status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary,nil)
        }
        guard status == errSecSuccess else { throw ShareError.message("Upload-Schlüssel konnte nicht im Schlüsselbund gespeichert werden.") }
        lock.withLock { cache[server] = token }
    }
}
struct ShareReceipt: Codable {
    let video: SharedVideo
    let server: URL
    let projectHash: String
}
