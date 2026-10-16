import CoreMotion
import Foundation
import Observation
import SwiftUI

/// One step of a route inside a building.
struct IndoorStep: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case walk, left, right, slightLeft, slightRight, turnAround, up, down, landmark, arrive
    }

    var id = UUID()
    var kind: Kind
    /// Meters, for walk steps.
    var distance: Double?
    /// Compass heading while walking, for walk steps.
    var heading: Double?
    /// Floors climbed or descended, for up/down steps.
    var floors: Int?
    var note = ""
    /// A JPEG of what's there (a door, a sign, the elevator).
    var photo: Data?

    var title: String {
        switch kind {
        case .walk:
            let distance = distance.map { "Walk \(Format.distance($0))" } ?? "Walk"
            return heading.map { "\(distance) heading \(Compass.name($0))" } ?? distance
        case .left: return "Turn left"
        case .right: return "Turn right"
        case .slightLeft: return "Bear left"
        case .slightRight: return "Bear right"
        case .turnAround: return "Turn around"
        case .up: return "Go up \(floorText)"
        case .down: return "Go down \(floorText)"
        case .landmark: return note.isEmpty ? "Landmark" : note
        case .arrive: return "Arrive"
        }
    }

    /// The note, when it isn't already the title.
    var detail: String? {
        kind == .landmark || note.isEmpty ? nil : note
    }

    var systemImage: String {
        switch kind {
        case .walk: "arrow.up"
        case .left: "arrow.turn.up.left"
        case .right: "arrow.turn.up.right"
        case .slightLeft: "arrow.up.left"
        case .slightRight: "arrow.up.right"
        case .turnAround: "arrow.uturn.down"
        case .up: "arrow.up.square"
        case .down: "arrow.down.square"
        case .landmark: "flag"
        case .arrive: "mappin.circle.fill"
        }
    }

    private var floorText: String {
        let count = floors ?? 1
        return count == 1 ? "1 floor" : "\(count) floors"
    }
}

/// A walked route inside a building, from a starting point (like the main
/// entrance) to a destination (like Room 312).
struct IndoorRoute: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var building: String
    var startPoint: String
    var destination: String
    var steps: [IndoorStep]
    var authorName: String
    var authorID: String?
    var createdAt: Date
    /// Where the building is (where recording started).
    var latitude: Double?
    var longitude: Double?
    /// The repository copy, once published from this iPhone.
    var publishedID: String?

    var totalDistance: Double { steps.compactMap(\.distance).reduce(0, +) }
}

/// Routes recorded on this iPhone (with their photos), kept in
/// Application Support/IndoorRoutes.json.
@Observable
final class IndoorLibrary {
    static let shared = IndoorLibrary()

    private(set) var routes: [IndoorRoute] = []

    private let url = URL.applicationSupportDirectory.appending(path: "IndoorRoutes.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([IndoorRoute].self, from: data) {
            routes = saved
        }
    }

    func add(_ route: IndoorRoute) {
        routes.insert(route, at: 0)
        save()
    }

    func update(_ route: IndoorRoute) {
        guard let index = routes.firstIndex(where: { $0.id == route.id }) else { return }
        routes[index] = route
        save()
    }

    func delete(at offsets: IndexSet) {
        routes.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(routes).write(to: url, options: .atomic)
    }
}

enum Motion {
    /// A pedometer handler that reports the distance walked on the main actor.
    nonisolated static func distanceHandler(_ update: @escaping @MainActor @Sendable (Double) -> Void) -> CMPedometerHandler {
        { data, _ in
            guard let meters = data?.distance?.doubleValue else { return }
            Task { @MainActor in update(meters) }
        }
    }

    /// Roughly the height of one floor, in meters.
    static let floorHeight = 3.5
}

/// Records a route while the person walks it: distance from the pedometer,
/// turns from the compass, and floor changes from the barometer. Steps can
/// also be added by hand (and must be, in the Simulator).
@Observable
final class IndoorRecorder {
    private(set) var steps: [IndoorStep] = []
    private(set) var isRecording = false
    /// Meters walked since the last step was added.
    private(set) var walkedInSegment: Double = 0
    var latitude: Double?
    var longitude: Double?

    let canCountSteps = CMPedometer.isDistanceAvailable()
    let canSenseFloors = CMAltimeter.isRelativeAltitudeAvailable()

    @ObservationIgnored private let pedometer = CMPedometer()
    @ObservationIgnored private let altimeter = CMAltimeter()
    @ObservationIgnored private var totalDistance: Double = 0
    @ObservationIgnored private var segmentStart: Double = 0
    @ObservationIgnored private var segmentHeading: Double?
    @ObservationIgnored private var turnSince: Date?
    @ObservationIgnored private var altitudeBase: Double?
    @ObservationIgnored private var watcher: Task<Void, Never>?

    func start() {
        steps = []
        totalDistance = 0
        segmentStart = 0
        walkedInSegment = 0
        segmentHeading = nil
        altitudeBase = nil
        isRecording = true
        let here = LocationManager.shared.location?.coordinate
        latitude = here?.latitude
        longitude = here?.longitude

        LocationManager.shared.startHeading()
        if canCountSteps {
            pedometer.startUpdates(from: Date(), withHandler: Motion.distanceHandler { [weak self] meters in
                self?.distanceChanged(meters)
            })
        }
        if canSenseFloors {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let meters = data?.relativeAltitude.doubleValue else { return }
                MainActor.assumeIsolated { self?.altitudeChanged(meters) }
            }
        }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.checkForTurn()
            }
        }
    }

    /// Ends the recording with an Arrive step.
    func finish() {
        guard isRecording else { return }
        closeWalk()
        steps.append(IndoorStep(kind: .arrive))
        stop()
    }

    func stop() {
        isRecording = false
        watcher?.cancel()
        pedometer.stopUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        LocationManager.shared.stopHeading()
    }

    /// A step added by hand (a turn the compass missed, a landmark photo…).
    func add(_ step: IndoorStep) {
        if step.kind != .landmark { closeWalk() }
        steps.append(step)
        if step.kind != .landmark && step.kind != .walk {
            segmentHeading = LocationManager.shared.heading
            turnSince = nil
        }
    }

    func delete(at offsets: IndexSet) { steps.remove(atOffsets: offsets) }
    func move(from source: IndexSet, to destination: Int) { steps.move(fromOffsets: source, toOffset: destination) }
    func replace(_ step: IndoorStep) {
        if let index = steps.firstIndex(where: { $0.id == step.id }) { steps[index] = step }
    }

    private func distanceChanged(_ meters: Double) {
        totalDistance = meters
        walkedInSegment = totalDistance - segmentStart
    }

    /// Adds the walk since the last step, if it's long enough to matter.
    private func closeWalk() {
        let walked = totalDistance - segmentStart
        if walked >= 1 {
            steps.append(IndoorStep(kind: .walk, distance: walked.rounded(), heading: segmentHeading))
        }
        segmentStart = totalDistance
        walkedInSegment = 0
    }

    /// A turn is a heading change of over 45° held for 1.5 seconds.
    private func checkForTurn() {
        guard isRecording, let heading = LocationManager.shared.heading else { return }
        guard let segmentHeading else { self.segmentHeading = heading; return }
        let turn = Compass.turn(from: segmentHeading, to: heading)
        guard abs(turn) > 45 else { turnSince = nil; return }
        guard let since = turnSince else { turnSince = Date(); return }
        guard Date().timeIntervalSince(since) >= 1.5 else { return }

        closeWalk()
        let kind: IndoorStep.Kind = abs(turn) >= 150 ? .turnAround
            : abs(turn) < 70 ? (turn < 0 ? .slightLeft : .slightRight)
            : (turn < 0 ? .left : .right)
        steps.append(IndoorStep(kind: kind))
        self.segmentHeading = heading
        turnSince = nil
    }

    /// Each ~3.5 m of height change is a floor; an elevator ride that
    /// arrives in pieces is merged into one step.
    private func altitudeChanged(_ meters: Double) {
        guard let base = altitudeBase else { altitudeBase = meters; return }
        let floors = Int((meters - base) / Motion.floorHeight)
        guard floors != 0 else { return }
        altitudeBase = base + Double(floors) * Motion.floorHeight
        let kind: IndoorStep.Kind = floors > 0 ? .up : .down
        if let last = steps.indices.last, steps[last].kind == kind {
            steps[last].floors = (steps[last].floors ?? 0) + abs(floors)
        } else {
            closeWalk()
            steps.append(IndoorStep(kind: kind, floors: abs(floors)))
        }
    }
}

/// Follows a route: counts the distance walked on each walk step and moves
/// to the next step when it's done.
@Observable
final class IndoorFollower {
    /// Meters walked since this step started.
    private(set) var walked: Double = 0
    let canCountSteps = CMPedometer.isDistanceAvailable()

    @ObservationIgnored private let pedometer = CMPedometer()
    @ObservationIgnored private var total: Double = 0
    @ObservationIgnored private var stepStart: Double = 0

    func start() {
        LocationManager.shared.startHeading()
        guard canCountSteps else { return }
        pedometer.startUpdates(from: Date(), withHandler: Motion.distanceHandler { [weak self] meters in
            guard let self else { return }
            total = meters
            walked = total - stepStart
        })
    }

    func stop() {
        pedometer.stopUpdates()
        LocationManager.shared.stopHeading()
    }

    /// Call when a new step begins.
    func resetStep() {
        stepStart = total
        walked = 0
    }
}
