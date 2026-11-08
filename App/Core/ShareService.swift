import UIKit

/// Teilen wie in Fotos: lädt die Originale (inkl. Bearbeitung) als Dateien und öffnet das System-Teilen-Fenster.
/// Ein reiner Link ginge nicht – der Server verlangt Anmeldung.
@MainActor
enum ShareService {
    static func share(_ ids: [String], app: AppModel) async {
        guard !ids.isEmpty else { return }
        let api = ImmichClient.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("teilen", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [URL] = []
        for (n, id) in ids.enumerated() {
            app.busy = ids.count > 1 ? String(localized: "Wird vorbereitet … \(n + 1) von \(ids.count)") : String(localized: "Wird vorbereitet …")
            guard let url = api.originalURL(id), let data = try? await api.data(url) else { continue }
            let name = (try? await api.asset(id))?.originalFileName ?? "\(id).jpg"
            var file = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { file = dir.appendingPathComponent("\(n)-\(name)") }
            if (try? data.write(to: file)) != nil { files.append(file) }
            RecentStore.add(id, to: .recentlyShared)
        }
        app.busy = nil
        present(files)
    }

    /// Teilen-Fenster für fertige Dateien (z. B. Rückblick-Video).
    static func present(_ files: [URL]) {
        guard !files.isEmpty, let top = topController() else { return }
        let vc = UIActivityViewController(activityItems: files, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        top.present(vc, animated: true)
    }

    private static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var c = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let p = c?.presentedViewController { c = p }
        return c
    }
}
