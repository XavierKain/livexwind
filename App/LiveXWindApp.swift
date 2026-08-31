import SwiftUI
import BackgroundTasks
import WidgetKit

@main
struct LiveXWindApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundRefresh.schedule() }
        }
    }
}

/// Réveil périodique en arrière-plan : rafraîchit le cache partagé, les widgets
/// et l'activité en direct même quand l'app est fermée (cadence décidée par iOS).
enum BackgroundRefresh {
    static let identifier = "com.xavierkain.livexwind.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handle(task)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(10 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task { @MainActor in
            let snapshot = await BaliseClient.shared.loadSnapshot()
            let unit = SharedStore.shared.unit
            await LiveActivityManager().push(snapshot: snapshot, unit: unit)
            WidgetCenter.shared.reloadAllTimelines()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}
