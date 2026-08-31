import CoreLocation

/// Position ponctuelle, uniquement pour « chercher les balises autour de moi ».
/// Rien n'est stocké ni envoyé ailleurs que dans la requête de recherche.
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    enum LocationError: Error, LocalizedError {
        case denied
        case unavailable

        var errorDescription: String? {
            switch self {
            case .denied: return "Localisation refusée — Réglages > LiveXWind > Position"
            case .unavailable: return "Position indisponible"
            }
        }
    }

    func current() async throws -> CLLocationCoordinate2D {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw LocationError.denied
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.continuation?.resume(returning: coordinate)
            self.continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: LocationError.unavailable)
            self.continuation = nil
        }
    }
}
