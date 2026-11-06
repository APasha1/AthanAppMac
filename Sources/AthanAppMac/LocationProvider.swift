import CoreLocation
import Foundation

/// Gets a coarse location once (and on significant change) or geocodes a typed city.
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    var onUpdate: ((CLLocationCoordinate2D, String) -> Void)?

    @Published var status: CLAuthorizationStatus = .notDetermined
    @Published var lastError: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        status = manager.authorizationStatus
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorized:
            manager.startMonitoringSignificantLocationChanges()
            manager.requestLocation()
        default:
            lastError = "Location access is off. Set a city manually in Settings."
        }
    }

    func search(_ query: String) async -> (CLLocationCoordinate2D, String)? {
        do {
            let marks = try await geocoder.geocodeAddressString(query)
            guard let mark = marks.first, let loc = mark.location else { return nil }
            return (loc.coordinate, Self.describe(mark))
        } catch {
            lastError = "Couldn't find “\(query)”."
            return nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.status = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorized {
                self.start()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            let name: String
            if let mark = try? await self.geocoder.reverseGeocodeLocation(loc).first {
                name = Self.describe(mark)
            } else {
                name = String(format: "%.2f, %.2f", loc.coordinate.latitude, loc.coordinate.longitude)
            }
            self.lastError = nil
            self.onUpdate?(loc.coordinate, name)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.lastError = "Couldn't get your location." }
    }

    private static func describe(_ mark: CLPlacemark) -> String {
        [mark.locality ?? mark.subAdministrativeArea, mark.administrativeArea ?? mark.country]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
