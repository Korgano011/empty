import CoreLocation
import Foundation

/// PATH trains between New Jersey and Manhattan. Transitous has no PATH
/// timetable, so the Port Authority's regular weekday, Saturday and Sunday
/// timetable is built into the app (PATHTimetable.json) and searched on the
/// iPhone. Construction and holiday changes are not included.
enum PATHPlanner {
    // MARK: - Timetable

    private struct Timetable: Decodable {
        struct Station: Decodable {
            var name: String
            var lat: Double
            var lon: Double
        }
        /// Trains that run the same stops with the same running times.
        struct Pattern: Decodable {
            var route: String
            var headsign: String
            var stops: [Int]
            /// Seconds after the first stop, one per stop.
            var offsets: [Int]
            /// "weekday", "saturday", "sunday" → first-stop times, seconds after midnight.
            var days: [String: [Int]]
        }
        var source: String
        var stations: [Station]
        var patterns: [Pattern]
    }

    private static let timetable: Timetable? = {
        guard let url = Bundle.main.url(forResource: "PATHTimetable", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Timetable.self, from: data)
    }()

    private static let newYork = TimeZone(identifier: "America/New_York")!

    /// Stations where PATH meets other trains, and the walk between them.
    private struct Hub {
        var station: String
        var rail: CLLocation
        var walk: CLLocationDistance
        var minutes: Double
    }

    private static let hubs = [
        Hub(station: "Newark", rail: CLLocation(latitude: 40.7347, longitude: -74.1644), walk: 150, minutes: 5),
        Hub(station: "Hoboken", rail: CLLocation(latitude: 40.7350, longitude: -74.0275), walk: 150, minutes: 5),
        Hub(station: "33rd Street", rail: CLLocation(latitude: 40.7506, longitude: -73.9935), walk: 450, minutes: 8),
    ]

    /// How far from a PATH station a start or destination can be to use it.
    private static let walkLimit: CLLocationDistance = 1_200

    // MARK: - Trips with PATH

    /// Train trips that use PATH for the start or end, or the whole way:
    /// PATH to or from Newark, Hoboken or 33rd Street, with the other trains
    /// from Transitous.
    static func trips(board: CLLocation, leave: CLLocation, start: CLLocation, destination: CLLocation,
                      after time: Date) async -> [TransitPlanner.Trip] {
        guard let timetable else { return [] }
        let origin = nearestStation(to: start, in: timetable)
        let target = nearestStation(to: destination, in: timetable)
        var found: [TransitPlanner.Trip] = []

        // PATH the whole way.
        if let origin, let target, origin != target,
           let rides = journey(from: origin, to: target, after: time, in: timetable) {
            found.append(TransitPlanner.Trip(rides: rides, changeWalks: walks(rides)))
        }

        // Trains to a hub, then PATH to the destination.
        if let target {
            let usable = hubs.filter { index(of: $0.station, in: timetable).map { $0 != target } ?? false }
            let results = await withTaskGroup(of: (Hub, TransitPlanner.Outcome).self) { group in
                for hub in usable where board.distance(from: hub.rail) > 1_000 {
                    group.addTask { (hub, await TransitPlanner.trains(from: board, to: hub.rail, leavingAfter: time)) }
                }
                var all: [(Hub, TransitPlanner.Outcome)] = []
                for await result in group { all.append(result) }
                return all
            }
            for (hub, outcome) in results {
                guard case .trips(let toHub) = outcome, let hubIndex = index(of: hub.station, in: timetable) else { continue }
                for trip in toHub.prefix(5) where trip.rides[trip.rides.count - 1].to.location.distance(from: hub.rail) < 800 {
                    let ready = trip.arrival.addingTimeInterval(hub.minutes * 60)
                    guard let rides = journey(from: hubIndex, to: target, after: ready, in: timetable) else { continue }
                    found.append(TransitPlanner.Trip(rides: trip.rides + rides,
                                                     changeWalks: trip.changeWalks + [hub.walk] + walks(rides)))
                }
            }
        }

        // PATH from the start to a hub, then trains onward.
        if let origin {
            for hub in hubs where leave.distance(from: hub.rail) > 1_000 {
                guard let hubIndex = index(of: hub.station, in: timetable), hubIndex != origin,
                      let rides = journey(from: origin, to: hubIndex, after: time, in: timetable) else { continue }
                let ready = rides[rides.count - 1].arrival.addingTimeInterval(hub.minutes * 60)
                guard case .trips(let onward) = await TransitPlanner.trains(from: hub.rail, to: leave, leavingAfter: ready)
                else { continue }
                for trip in onward.prefix(2) where trip.rides[0].from.location.distance(from: hub.rail) < 800 {
                    found.append(TransitPlanner.Trip(rides: rides + trip.rides,
                                                     changeWalks: walks(rides) + [hub.walk] + trip.changeWalks))
                }
            }
        }
        return found
    }

    /// Changing between PATH trains is on the same platform or across it.
    private static func walks(_ rides: [TransitPlanner.Ride]) -> [CLLocationDistance?] {
        Array(repeating: 0, count: max(0, rides.count - 1))
    }

    private static func nearestStation(to location: CLLocation, in timetable: Timetable) -> Int? {
        timetable.stations.indices
            .map { ($0, CLLocation(latitude: timetable.stations[$0].lat, longitude: timetable.stations[$0].lon).distance(from: location)) }
            .filter { $0.1 <= walkLimit }
            .min { $0.1 < $1.1 }?.0
    }

    private static func index(of name: String, in timetable: Timetable) -> Int? {
        timetable.stations.firstIndex { $0.name == name }
    }

    // MARK: - Searching the timetable

    private struct Connection {
        var trip: Int
        var from: Int
        var to: Int
        var departure: Date
        var arrival: Date
    }

    /// The PATH trains that get from one station to another soonest after
    /// `time`, changing trains where needed.
    private static func journey(from origin: Int, to target: Int, after time: Date,
                                in timetable: Timetable) -> [TransitPlanner.Ride]? {
        let (connections, trips) = connections(from: time, hours: 4, in: timetable)
        var arrival: [Int: Date] = [origin: time]
        var boarded: [Int: Int] = [:]                    // trip → connection boarded at
        var pointer: [Int: (board: Int, leave: Int)] = [:] // station → how it was reached
        let changeTime: TimeInterval = 120

        for (i, c) in connections.enumerated() {
            if let best = arrival[target], c.departure > best { break }
            if boarded[c.trip] == nil {
                guard let at = arrival[c.from],
                      at.addingTimeInterval(c.from == origin ? 0 : changeTime) <= c.departure else { continue }
                boarded[c.trip] = i
            }
            if arrival[c.to].map({ c.arrival < $0 }) ?? true {
                arrival[c.to] = c.arrival
                pointer[c.to] = (boarded[c.trip]!, i)
            }
        }

        var legs: [(board: Int, leave: Int)] = []
        var station = target
        while station != origin, let leg = pointer[station], legs.count < 6 {
            legs.insert(leg, at: 0)
            station = connections[leg.board].from
        }
        guard station == origin, !legs.isEmpty else { return nil }

        func stop(_ index: Int) -> TransitPlanner.Stop {
            let station = timetable.stations[index]
            return TransitPlanner.Stop(name: "\(station.name) (PATH)", latitude: station.lat, longitude: station.lon)
        }
        return legs.map { leg in
            let first = connections[leg.board], last = connections[leg.leave]
            let trip = trips[first.trip]
            return TransitPlanner.Ride(title: "PATH " + trip.route.replacingOccurrences(of: " - ", with: " – "),
                                       headsign: trip.headsign,
                                       from: stop(first.from), to: stop(last.to),
                                       departure: first.departure, arrival: last.arrival,
                                       timeZone: newYork)
        }
    }

    /// Every stop-to-stop hop of every PATH train in the next few hours,
    /// earliest first, including trains that started the evening before.
    private static func connections(from time: Date, hours: Double,
                                    in timetable: Timetable) -> ([Connection], [(route: String, headsign: String)]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let end = time.addingTimeInterval(hours * 3600)
        let today = calendar.startOfDay(for: time)
        var connections: [Connection] = []
        var trips: [(route: String, headsign: String)] = []

        for offset in -1...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let kind: String
            switch calendar.component(.weekday, from: day) {
            case 1: kind = "sunday"
            case 7: kind = "saturday"
            default: kind = "weekday"
            }
            for pattern in timetable.patterns {
                for start in pattern.days[kind] ?? [] {
                    let first = day.addingTimeInterval(TimeInterval(start))
                    guard first.addingTimeInterval(TimeInterval(pattern.offsets.last ?? 0)) >= time, first <= end else { continue }
                    let trip = trips.count
                    trips.append((pattern.route, pattern.headsign))
                    for i in 0..<(pattern.stops.count - 1) {
                        let departure = first.addingTimeInterval(TimeInterval(pattern.offsets[i]))
                        guard departure >= time, departure <= end else { continue }
                        connections.append(Connection(trip: trip, from: pattern.stops[i], to: pattern.stops[i + 1],
                                                      departure: departure,
                                                      arrival: first.addingTimeInterval(TimeInterval(pattern.offsets[i + 1]))))
                    }
                }
            }
        }
        connections.sort { $0.departure < $1.departure }
        return (connections, trips)
    }
}

extension TransitPlanner {
    /// Train trips between two stations from the timetable, plus trips that
    /// use PATH at either end when the start or destination is near PATH.
    /// With `toDestination`, the timetable picks the station to get off at:
    /// the one with the best walk to the destination (Apple Maps' nearest
    /// station is often not the best one, or not near at all).
    static func trainsWithPATH(board: CLLocation, leave: CLLocation, start: CLLocation?, destination: CLLocation,
                               toDestination: Bool = false, leavingAfter time: Date) async -> Outcome {
        async let main = mainTrains(board: board, leave: leave, destination: destination,
                                    toDestination: toDestination, leavingAfter: time)
        async let path = PATHPlanner.trips(board: board, leave: leave, start: start ?? board,
                                           destination: destination, after: time)
        let outcome = await main, pathTrips = await path
        var all: [Trip] = []
        if case .trips(let found) = outcome { all = found }
        var seen = Set(all.map(\.id))
        for trip in pathTrips where seen.insert(trip.id).inserted { all.append(trip) }
        if all.isEmpty {
            if case .unavailable = outcome { return .unavailable }
            return .notFound
        }
        // Drop roundabout trips: ones another trip beats by leaving no earlier
        // and arriving at least 10 minutes sooner. Trips can start at different
        // stations, so "leaving" counts the rough time to get to the first one.
        let origin = start ?? board
        func setOff(_ trip: Trip) -> Date {
            let distance = origin.distance(from: trip.rides[0].from.location)
            return trip.departure.addingTimeInterval(-distance / (distance <= 2_000 ? 1.3 : 9))
        }
        let worthShowing = all.filter { trip in
            !all.contains { other in
                setOff(other) >= setOff(trip) && other.arrival <= trip.arrival.addingTimeInterval(-10 * 60)
            }
        }
        return .trips(worthShowing.sorted { ($0.departure, $0.arrival) < ($1.departure, $1.arrival) })
    }

    /// To the destination when the timetable can reach it on foot, otherwise to `leave`.
    private static func mainTrains(board: CLLocation, leave: CLLocation, destination: CLLocation,
                                   toDestination: Bool, leavingAfter time: Date) async -> Outcome {
        if toDestination, case .trips(let found) = await trains(from: board, to: destination, leavingAfter: time) {
            return .trips(found)
        }
        return await trains(from: board, to: leave, leavingAfter: time)
    }
}
