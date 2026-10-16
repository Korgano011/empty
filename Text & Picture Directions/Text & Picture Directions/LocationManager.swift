import CoreLocation
import Observation

/// The person's location (for the map and the start of directions) and
/// compass heading (for indoor routes).
@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    var location: CLLocation?
    /// Degrees from north: true north when known, otherwise magnetic.
    var heading: CLLocationDirection?
    var authorization: CLAuthorizationStatus

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var headingUsers = 0

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    /// The floor the person is on, where the building provides it.
    var floorLevel: Int? { location?.floor?.level }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    /// Compass updates are shared by everything that needs them; each
    /// `startHeading` is paired with a `stopHeading`.
    func startHeading() {
        headingUsers += 1
        guard headingUsers == 1, CLLocationManager.headingAvailable() else { return }
        manager.headingFilter = 2
        manager.startUpdatingHeading()
    }

    func stopHeading() {
        headingUsers = max(0, headingUsers - 1)
        if headingUsers == 0 { manager.stopUpdatingHeading() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated { location = last }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        MainActor.assumeIsolated { heading = degrees }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}

enum Compass {
    /// "N", "NE", … for a heading in degrees.
    static func name(_ degrees: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((normalized(degrees) + 22.5) / 45) % 8
        return names[index]
    }

    static func normalized(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    /// The turn from one heading to another, -180…180 (negative is left).
    static func turn(from: Double, to: Double) -> Double {
        var diff = normalized(to) - normalized(from)
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        return diff
    }
}
