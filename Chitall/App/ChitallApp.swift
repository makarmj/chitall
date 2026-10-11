import SwiftData
import SwiftUI

@main
struct ChitallApp: App {
    private let startup: Startup

    init() {
        startup = Startup.make()
    }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case let .ready(container, files):
                RootView(files: files)
                    .modelContainer(container)
            case let .failed(message):
                StartupErrorView(message: message)
            }
        }
    }
}

enum Startup {
    case ready(ModelContainer, BookFileStore)
    case failed(String)

    static func make() -> Startup {
        do {
            let files = try BookFileStore.live()
            let container = try ChitallStore.makeContainer()
            return .ready(container, files)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(ReaderPreferences.themeKey) private var themeRaw = AppTheme.system.rawValue
    @State private var coordinator: AppCoordinator

    init(files: BookFileStore) {
        _coordinator = State(initialValue: AppCoordinator(files: files))
    }

    private var colorScheme: ColorScheme? {
        (AppTheme(rawValue: themeRaw) ?? .system).colorScheme
    }

    var body: some View {
        TabView(selection: $coordinator.selectedTab) {
            LibraryView()
                .tabItem { Label("Библиотека", systemImage: "books.vertical") }
                .tag(AppTab.library)
            MaterialsView()
                .tabItem { Label("Материалы", systemImage: "text.quote") }
                .tag(AppTab.materials)
        }
        .environment(coordinator)
        .tint(Palette.accent)
        .preferredColorScheme(colorScheme)
        .fullScreenCover(item: $coordinator.readerRequest) { request in
            ReaderView(book: request.book, files: coordinator.files, initialHighlightID: request.highlightID)
                .environment(coordinator)
                .tint(Palette.accent)
                .preferredColorScheme(colorScheme)
        }
        .overlay {
            if coordinator.isImporting { ImportingOverlay() }
        }
        .alert(
            coordinator.alert?.title ?? "",
            isPresented: Binding(
                get: { coordinator.alert != nil },
                set: { if !$0 { coordinator.alert = nil } }
            ),
            presenting: coordinator.alert
        ) { _ in
            Button("Понятно", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .onOpenURL { url in
            // "Open in Chitall" from Files or the share sheet: the system hands over a copy.
            Task { await coordinator.importFiles([url], context: context) }
        }
        .task {
            TagCatalog.seedIfNeeded(context)
        }
    }
}

struct ImportingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Читаю книгу…")
                    .font(Typography.serif(.body))
                    .foregroundStyle(Palette.ink)
            }
            .padding(24)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .transition(.opacity)
    }
}

struct StartupErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
            Text("Не удалось открыть хранилище")
                .font(Typography.serif(.title2))
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.secondaryInk)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }
}
