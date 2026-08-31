import Foundation
import SwiftUI
import WidgetKit

@MainActor
final class WindStore: ObservableObject {
    @Published private(set) var snapshot: WindSnapshot
    @Published private(set) var isLoading = false
    @Published var lastError: String?
    @Published var unit: WindUnit {
        didSet {
            guard unit != oldValue else { return }
            SharedStore.shared.unit = unit
            Task { await liveActivity.push(snapshot: snapshot, unit: unit) }
        }
    }

    let liveActivity = LiveActivityManager()
    private var timer: Task<Void, Never>?

    init() {
        let cached = SharedStore.shared.loadSnapshot()
        snapshot = cached ?? .placeholder
        unit = SharedStore.shared.unit
    }

    var nextUpdateText: String {
        let target = snapshot.nextExpectedUpdate
        let seconds = max(0, Int(target.timeIntervalSinceNow))
        return seconds < 60 ? "dans \(seconds) s" : "dans \(seconds / 60) min"
    }

    func refresh(force: Bool = false) async {
        if isLoading && !force { return }
        isLoading = true
        defer { isLoading = false }

        let fresh = await BaliseClient.shared.loadSnapshot()
        let previous = snapshot
        snapshot = fresh
        lastError = fresh.current.averageKmh == nil ? "Relevé indisponible" : nil
        WidgetCenter.shared.reloadAllTimelines()

        if fresh.current.date != previous.current.date || force {
            await liveActivity.push(snapshot: fresh, unit: unit)
        }
    }

    /// Se recale sur la grille du site : le relevé tombe toutes les 10 min,
    /// on interroge 45 s après l'heure attendue pour ne jamais rater un cran.
    func startAutoRefresh() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let target = self.snapshot.current.date.addingTimeInterval(600 + 45)
                var delay = target.timeIntervalSinceNow
                if delay <= 5 { delay = 60 }          // relevé en retard : on repasse dans 1 min
                delay = min(delay, 11 * 60)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stopAutoRefresh() {
        timer?.cancel()
        timer = nil
    }
}
