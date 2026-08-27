import SwiftData
import SwiftUI

@main
struct LLMDictiOSApp: App {
    @State private var persistenceState: PersistenceState

    init() {
        _persistenceState = State(initialValue: Self.makePersistenceState())
    }

    var body: some Scene {
        WindowGroup {
            switch persistenceState {
            case .ready(let modelContainer):
                AppBootstrapView()
                    .modelContainer(modelContainer)
            case .failed:
                PersistenceFailureView {
                    persistenceState = Self.makePersistenceState()
                }
            }
        }
    }

    private static func makePersistenceState() -> PersistenceState {
        let schema = Schema([RecordingItem.self, PromptItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let modelContainer = try ModelContainer(for: schema, configurations: [configuration])
            return .ready(modelContainer)
        } catch {
            return .failed
        }
    }

    private enum PersistenceState {
        case ready(ModelContainer)
        case failed
    }
}

struct PersistenceFailureView: View {
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            AppBackdrop().ignoresSafeArea()

            GlassPanel {
                VStack(spacing: 18) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 68, height: 68)
                        .background(.white.opacity(0.12), in: Circle())

                    VStack(spacing: 8) {
                        Text("Не удалось открыть данные")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)

                        Text("Локальные данные не удалялись. Повторите попытку открыть хранилище.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.white.opacity(0.78))
                            .multilineTextAlignment(.center)
                    }

                    Button(action: onRetry) {
                        Label("Повторить", systemImage: "arrow.clockwise")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(red: 0.08, green: 0.16, blue: 0.29))
                    .background(.white, in: Capsule(style: .continuous))
                }
            }
            .frame(maxWidth: 430)
            .padding(24)
        }
    }
}

struct AppBootstrapView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var controller: AppController?

    var body: some View {
        Group {
            if let controller {
                RootTabView(controller: controller)
            } else {
                ProgressView("Подготовка проекта")
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.04, green: 0.08, blue: 0.16),
                                Color(red: 0.08, green: 0.18, blue: 0.32),
                                Color(red: 0.82, green: 0.43, blue: 0.25)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .task {
            guard controller == nil else { return }
            let controller = AppController(modelContext: modelContext)
            try? controller.repairRecordingFilePaths()
            try? controller.recoverInterruptedOperations()
            try? controller.seedPromptsIfNeeded()
            self.controller = controller
        }
    }
}
