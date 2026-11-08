import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(TimelineStore.self) private var timeline
    @Namespace private var zoom
    @Environment(\.scenePhase) private var phase

    var body: some View {
        @Bindable var app = app
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            Group {
                switch app.tab {
                case .library: LibraryView()
                case .forYou: CollectionsView(mode: .forYou)
                case .albums: CollectionsView(mode: .albums)
                case .search: SearchView(isTab: true)
                }
            }
            .environment(\.zoomNamespace, zoom)
            if app.tab == .library { BottomBlur() }
            if app.selecting {
                SelectionBar()
                    .padding(.horizontal, 22)
                    .padding(.bottom, 8)
            } else {
                BottomBar()
            }
        }
        .overlay(alignment: .top) { VStack { BusyBadge(); ToastBadge() } }
        .actionSheets($app.sheet)
        .task {
            if timeline.buckets.isEmpty { await timeline.showCached() }
            var reloaded = false
            if let me = try? await ImmichClient.shared.me() {
                app.userID = me.id; app.userName = me.name; reloaded = await timeline.setUser(me.id)
            }
            if !reloaded { await timeline.reload() }
            BackupEngine.shared.runIfDue()
            WidgetFeeder.syncAccess()
            OfflineSync.shared.timeline = timeline
            // Widgets füllen, wenn die Zeitleiste steht (leise im Hintergrund)
            Task { try? await Task.sleep(for: .seconds(12)); await WidgetFeeder.update(timeline: timeline) }
            OfflineSync.shared.kick()
            #if DEBUG
            if ProcessInfo.processInfo.environment["FOTOS_BACKUP_NOW"] != nil { BackupEngine.shared.start() }
            if let d = ProcessInfo.processInfo.environment["FOTOS_BACKUP_DEMO"] { BackupEngine.shared.demo(d) }
            #endif
        }
        .onChange(of: app.tab) { app.endSelection(); app.tabsExpanded = false }
        .onChange(of: perfScreen, initial: true) { _, s in PerfLog.setScreen(s) }
        .onChange(of: phase) { _, p in
            // erst nachladen, wenn das Konto feststeht (beim Start erledigt das .task)
            if p == .active, !app.userID.isEmpty { BackupEngine.shared.runIfDue(); Task { await timeline.reload(); OfflineSync.shared.kick() } }
            // wie Fotos: geschützte Alben sperren sich wieder, sobald die App in den Hintergrund geht
            guard p == .background else { return }
            BackupEngine.shared.schedule()
            OfflineSync.shared.stop()
            Task { await MemoryNotifications.schedule(timeline: timeline); await WidgetFeeder.update(timeline: timeline) }
            app.privateUnlocked = false
            if app.viewer?.assets.contains(where: { $0.isHidden || $0.trashedAt != nil }) == true { app.viewer = nil }
        }
        .onChange(of: app.tabsExpanded) { _, open in
            // wie bei Apple klappt die Leiste nach kurzer Zeit wieder zu
            guard open else { return }
            Task { try? await Task.sleep(for: .seconds(6)); withAnimation(.snappy) { app.tabsExpanded = false } }
        }
        .fullScreenCover(item: $app.viewer) { req in
            if #available(iOS 18.0, *) {
                ViewerView(assets: req.assets, start: req.index)
                    .navigationTransition(.zoom(sourceID: app.zoomID, in: zoom))
            } else {
                ViewerView(assets: req.assets, start: req.index)
            }
        }
        .fullScreenCover(isPresented: $app.showSearch) { SearchView() }
        // Tippen aufs Widget: homeroll://memory/<id> bzw. homeroll://asset/<id>
        .onOpenURL { open($0) }
        .onReceive(NotificationCenter.default.publisher(for: .openFotosURL)) { n in if let u = n.object as? URL { open(u) } }
        .fullScreenCover(item: $app.memory) { MemoryPlayer(memory: $0) }
    }

    private func open(_ url: URL) {
            guard url.scheme == "homeroll", let id = url.pathComponents.dropFirst().first else { return }
            app.viewer = nil; app.showSearch = false
            if url.host == "album" || url.host == "person" {
                let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value ?? ""
                app.tab = .albums
                Task {
                    var title = name
                    if url.host == "album", title.isEmpty { title = (try? await ImmichClient.shared.albums())?.first { $0.id == id }?.albumName ?? "" }
                    app.pendingRoute = url.host == "album" ? .album(AlbumRef(id: id, name: title)) : .person(PersonRef(id: id, name: title))
                }
                return
            }
            if url.host == "memory", let m = MemoryCenter.shared.items.first(where: { $0.id == id }) { app.memory = m }
            else if url.host == "asset" {
                // wie Apple: Foto direkt öffnen (mit den Nachbarn aus der Mediathek zum Weiterwischen)
                Task {
                    await timeline.loadAll()
                    // war schon ein Foto offen: erst schließen lassen, sonst bleibt die alte Einzelansicht stehen
                    try? await Task.sleep(for: .milliseconds(450))
                    let all = timeline.allLoaded
                    if let i = all.firstIndex(where: { $0.id == id }) { app.open(all, at: i) }
                    else if let dto = try? await ImmichClient.shared.asset(id) { app.open([dto.asset], at: 0) }
                }
            }
    }
}

extension RootView {
    /// Für das Leistungsprotokoll: wo man gerade ist.
    private var perfScreen: String {
        if app.viewer != nil { return "Einzelansicht" }
        if app.showSearch || app.tab == .search { return "Suche" }
        if app.memory != nil { return "Rückblick" }
        if app.tab == .forYou { return "Für dich" }
        if app.tab == .albums { return "Alben" }
        return app.scale == .all ? "Mediathek \(app.columns) Spalten" : "Mediathek \(app.scale.rawValue)"
    }
}

private extension View {
    /// Während ein Foto darüber gezogen wird, nach 0,6 s zum Tab `to` wechseln (Ablegen selbst passiert nicht hier).
    func springLoaded(to tab: Tab, hovering: Binding<Tab?>) -> some View {
        modifier(SpringLoad(tab: tab, hovering: hovering))
    }
}

private struct SpringLoad: ViewModifier {
    let tab: Tab
    @Binding var hovering: Tab?
    @Environment(AppModel.self) private var app
    func body(content: Content) -> some View {
        content
            .background { GeometryReader { g in Color.clear.preference(key: SpringFrames.self, value: [tab: g.frame(in: .global)]) } }
            .onPreferenceChange(SpringFrames.self) { f in SpringLoadWindow.shared.frames.merge(f) { $1 } }
            .background { SpringLoadWindow.Attach() }
            .onAppear {
                SpringLoadWindow.shared.onHover = { t in
                    hovering = t
                    guard let t else { return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        guard hovering == t, app.tab != t else { return }
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(.snappy) { app.tab = t; app.tabsExpanded = false }
                    }
                }
            }
    }
}

private struct SpringFrames: PreferenceKey {
    static let defaultValue: [Tab: CGRect] = [:]
    static func reduce(value: inout [Tab: CGRect], nextValue: () -> [Tab: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Ablegeziel am Fenster: UIKit nimmt es nur, wenn unter dem Finger kein anderes Ziel annimmt (Alben bleiben
/// Ziele). Liegt der Finger über einem Tab-Knopf, meldet es den Tab – abgelegt wird hier nie.
@MainActor
final class SpringLoadWindow: NSObject, UIDropInteractionDelegate {
    static let shared = SpringLoadWindow()
    var frames: [Tab: CGRect] = [:]
    var onHover: (Tab?) -> Void = { _ in }
    private weak var window: UIWindow?
    private var current: Tab?

    func attach(to w: UIWindow) {
        guard window !== w else { return }
        window = w
        w.addInteraction(UIDropInteraction(delegate: self))
    }
    private func report(_ t: Tab?) { guard t != current else { return }; current = t; onHover(t) }

    nonisolated func dropInteraction(_ i: UIDropInteraction, canHandle s: UIDropSession) -> Bool { s.localDragSession != nil }
    nonisolated func dropInteraction(_ i: UIDropInteraction, sessionDidUpdate s: UIDropSession) -> UIDropProposal {
        MainActor.assumeIsolated {
            guard let w = window else { return }; let p = s.location(in: w)
            report(frames.first { $0.value.insetBy(dx: -8, dy: -8).contains(p) }?.key)
        }
        return UIDropProposal(operation: .cancel)
    }
    nonisolated func dropInteraction(_ i: UIDropInteraction, sessionDidExit s: UIDropSession) { MainActor.assumeIsolated { report(nil) } }
    nonisolated func dropInteraction(_ i: UIDropInteraction, sessionDidEnd s: UIDropSession) { MainActor.assumeIsolated { report(nil) } }

    struct Attach: UIViewRepresentable {
        func makeUIView(context: Context) -> V { V() }
        func updateUIView(_ v: V, context: Context) {}
        final class V: UIView {
            override func didMoveToWindow() { super.didMoveToWindow(); if let window { SpringLoadWindow.shared.attach(to: window) } }
        }
    }
}

/// Классическая нижняя панель Фото как в iOS 17:
/// постоянный 4-вкладочный таббар («Медиатека», «Для вас», «Альбомы», «Поиск»),
/// а на вкладке «Медиатека» над ним парит компактный переключатель «Годы | Месяцы | Все фото».
struct BottomBar: View {
    @Environment(AppModel.self) private var app
    @State private var hovering: Tab?

    var body: some View {
        VStack(spacing: 10) {
            if app.tab == .library {
                ScaleSwitcher()
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .padding(.horizontal, 36)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 0) {
                tabButton(.library, icon: "photo.fill.on.rectangle.fill", title: String(localized: "Mediathek"))
                    .springLoaded(to: .library, hovering: $hovering)
                tabButton(.forYou, icon: "heart.text.square.fill", title: String(localized: "Für dich"))
                    .springLoaded(to: .forYou, hovering: $hovering)
                tabButton(.albums, icon: "rectangle.stack.fill", title: String(localized: "Alben"))
                    .springLoaded(to: .albums, hovering: $hovering)
                tabButton(.search, icon: "magnifyingglass", title: String(localized: "Suchen"))
                    .springLoaded(to: .search, hovering: $hovering)
            }
            .padding(.top, 7)
            .padding(.bottom, 2)
            .background {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.white.opacity(0.14)).frame(height: 0.5)
                    }
                    .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    private func tabButton(_ t: Tab, icon: String, title: String) -> some View {
        let on = app.tab == t
        return Button {
            if t == .library && app.tab == .library {
                NotificationCenter.default.post(name: .scrollToNewest, object: nil)
            }
            withAnimation(.snappy(duration: 0.2)) {
                app.tab = t
                app.tabsExpanded = false
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .medium))
                    .frame(height: 24)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(on ? Color.blue : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ScaleSwitcher: View {
    @Environment(AppModel.self) private var app
    @Namespace private var sel
    var body: some View {
        HStack(spacing: 0) {
            ForEach(LibraryScale.allCases) { s in
                Button {
                    if s == .all && app.scale == .all { NotificationCenter.default.post(name: .scrollToNewest, object: nil) }
                    withAnimation(.snappy(duration: 0.25)) { app.scale = s }
                } label: {
                    Text(L(s.rawValue))
                        .font(.system(size: 14, weight: app.scale == s ? .semibold : .medium))
                        .foregroundStyle(app.scale == s ? .white : .white.opacity(0.75))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background {
                            if app.scale == s {
                                Capsule().fill(.white.opacity(0.22))
                                    .matchedGeometryEffect(id: "sel", in: sel)
                                    .padding(3)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 42)
    }
}

/// Kleine Glas-Kapsel oben, solange etwas vorbereitet wird (Teilen, Sichern …).
struct BusyBadge: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if let text = app.busy {
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 18).frame(height: 44)
            .glassEffect(.regular.tint(.black.opacity(0.45)), in: .capsule)   // auf hellen Fotos lesbar
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}


extension Notification.Name {
    static let scrollToNewest = Notification.Name("scrollToNewest")
    static let openFotosURL = Notification.Name("openFotosURL")
    static let personThumbChanged = Notification.Name("personThumbChanged")
}
