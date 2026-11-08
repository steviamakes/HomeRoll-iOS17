import Foundation
import Security

/// Gemeinsamer Speicher von App, Widget und Teilen-Erweiterung.
/// Дополнительно дублирует данные авторизации в Keychain и UserDefaults(suiteName:),
/// чтобы Share-расширение видело авторизацию при любой установке (TrollStore / Sideloadly / AltStore).
enum AppGroup {
    static let base = "group.org.homeroll.app"
    static let id: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let lists = [info["ALTAppGroups"]] + info.values.map { Optional($0) }
        var candidates: [String] = []
        for case let list as [String] in lists.compactMap({ $0 }) { candidates += list.filter { $0.hasPrefix(base) } }
        candidates += [base]
        return candidates.first { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil } ?? base
    }()
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }

    /// Server + Token für die Teilen-Erweiterung
    struct Access: Codable { let server: String; let token: String }
    private static var accessFile: URL? { container?.appendingPathComponent("zugang.json") }
    private static let keychainService = "org.homeroll.app.shared.access"

    static func saveAccess(_ a: Access?) {
        // 1. Keychain (работает между основным приложением и Share Extension в одном бандле)
        let qBase: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "access"
        ]
        SecItemDelete(qBase as CFDictionary)
        if let a, let d = try? JSONEncoder().encode(a) {
            var add = qBase
            add[kSecValueData as String] = d
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }

        // 2. UserDefaults suiteName
        if let ud = UserDefaults(suiteName: id) {
            if let a {
                ud.set(a.server, forKey: "shared.serverURL")
                ud.set(a.token, forKey: "shared.accessToken")
            } else {
                ud.removeObject(forKey: "shared.serverURL")
                ud.removeObject(forKey: "shared.accessToken")
            }
            ud.synchronize()
        }

        // 3. Файл в AppGroup контейнере
        if let f = accessFile {
            if let a, let d = try? JSONEncoder().encode(a) {
                try? d.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    static func loadAccess() -> Access? {
        // 1. Пробуем файл в AppGroup контейнере
        if let f = accessFile, let d = try? Data(contentsOf: f),
           let a = try? JSONDecoder().decode(Access.self, from: d), !a.server.isEmpty, !a.token.isEmpty {
            return a
        }
        // 2. Пробуем UserDefaults(suiteName:)
        if let ud = UserDefaults(suiteName: id),
           let s = ud.string(forKey: "shared.serverURL"),
           let t = ud.string(forKey: "shared.accessToken"),
           !s.isEmpty, !t.isEmpty {
            return Access(server: s, token: t)
        }
        // 3. Пробуем общий Keychain
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "access",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let d = out as? Data,
           let a = try? JSONDecoder().decode(Access.self, from: d), !a.server.isEmpty, !a.token.isEmpty {
            return a
        }
        // 4. Пробуем основной Keychain приложения (org.homeroll.app)
        let qMain: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.homeroll.app",
            kSecAttrAccount as String: "accessToken",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var outMain: AnyObject?
        if SecItemCopyMatching(qMain as CFDictionary, &outMain) == errSecSuccess,
           let tData = outMain as? Data,
           let t = String(data: tData, encoding: .utf8),
           let s = UserDefaults(suiteName: base)?.string(forKey: "shared.serverURL") ?? UserDefaults.standard.string(forKey: "serverURL") {
            return Access(server: s, token: t)
        }
        return nil
    }
}

/// Was das Widget zeigt (die App schreibt es, das Widget liest es – ohne eigenen Serverzugriff).
struct WidgetSnapshot: Codable {
    struct Item: Codable, Hashable {
        let id: String
        let title: String
        let subtitle: String
        let file: String
        let memory: Bool
    }
    var memories: [Item] = []
    var photos: [Item] = []
    var updated = Date()

    static var folder: URL? { AppGroup.container?.appendingPathComponent("widget", isDirectory: true) }
    static func load() -> WidgetSnapshot? {
        guard let f = folder?.appendingPathComponent("snapshot.json"), let d = try? Data(contentsOf: f) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
    }
    func save() {
        guard let dir = Self.folder, let d = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: dir.appendingPathComponent("snapshot.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

func L(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }
