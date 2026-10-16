import MapKit
import Observation
import SwiftUI

/// How the person is getting there.
enum Transport: String, Codable, CaseIterable, Identifiable {
    /// `transit` is kept only so directions saved before Bus and Train were
    /// separate still open; it is no longer offered.
    case walking, driving, transit, bus, train

    /// The choices shown in the "Travel by" picker.
    static let choices: [Transport] = [.walking, .driving, .bus, .train]

    var id: String { rawValue }
    var title: String {
        switch self {
        case .walking: "Walk"
        case .driving: "Drive"
        case .transit: "Transit"
        case .bus: "Bus"
        case .train: "Train"
        }
    }
    var systemImage: String {
        switch self {
        case .walking: "figure.walk"
        case .driving: "car.fill"
        case .transit: "tram.fill"
        case .bus: "bus.fill"
        case .train: "train.side.front.car"
        }
    }
    var mapKitType: MKDirectionsTransportType {
        switch self {
        case .walking: .walking
        case .driving: .automobile
        case .transit, .bus, .train: .transit
        }
    }
    var mapsMode: String {
        switch self {
        case .walking: MKLaunchOptionsDirectionsModeWalking
        case .driving: MKLaunchOptionsDirectionsModeDriving
        case .transit, .bus, .train: MKLaunchOptionsDirectionsModeTransit
        }
    }
}

/// Where the person wants to go.
struct Destination: Hashable, Codable {
    var name: String
    var address: String?
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    init(name: String, address: String?, latitude: Double, longitude: Double) {
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ item: MKMapItem) {
        let coordinate = item.location.coordinate
        self.init(name: item.name ?? "Destination",
                  address: item.address?.shortAddress ?? item.address?.fullAddress,
                  latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var mapItem: MKMapItem {
        let item = MKMapItem(location: CLLocation(latitude: latitude, longitude: longitude), address: nil)
        item.name = name
        return item
    }
}

/// Opens Apple Maps with directions for one stretch of a trip.
struct StepLink {
    /// Nil starts from where the person is.
    var from: MKMapItem?
    var to: MKMapItem
    var mode: String

    init(from: MKMapItem?, to: MKMapItem, mode: String) {
        self.from = from
        self.to = to
        self.mode = mode
    }

    /// Walking or driving, the same way as the route MapKit planned.
    init(from: MKMapItem?, to: MKMapItem, like route: MKRoute) {
        self.init(from: from, to: to,
                  mode: route.transportType == .automobile ? MKLaunchOptionsDirectionsModeDriving : MKLaunchOptionsDirectionsModeWalking)
    }

    static func transit(from: MKMapItem, to: MKMapItem) -> StepLink {
        StepLink(from: from, to: to, mode: MKLaunchOptionsDirectionsModeTransit)
    }

    func open() {
        MKMapItem.openMaps(with: [from ?? MKMapItem.forCurrentLocation(), to],
                           launchOptions: [MKLaunchOptionsDirectionsModeKey: mode])
    }
}

/// A route from where the person is now.
struct PlannedRoute {
    /// Nil for transit, which MapKit only gives a travel time for.
    var route: MKRoute?
    var steps: [String]
    /// Apple Maps directions for each step, where the step is a stretch of the
    /// trip (same order as `steps`; nil for steps without one).
    var stepLinks: [StepLink?] = []
    var distance: CLLocationDistance
    var travelTime: TimeInterval
    /// For a bus or train trip: the getting-to and getting-from-the-stop legs.
    var legs: [MKRoute] = []
    /// For a bus or train trip: the stop to board at and the one to get off at.
    var stations: (board: MKMapItem, leave: MKMapItem)?
    /// Every stop within reach of the start and of the destination, nearest first,
    /// so the person can pick a different one.
    var boardOptions: [MKMapItem] = []
    var leaveOptions: [MKMapItem] = []
    /// Every station the trip uses, in order: board, each change of trains, leave.
    var rideStops: [MKMapItem] = []
    /// For a train trip: departures from the timetable, and the one in use.
    /// Every trip the timetable gave, trains or buses.
    var trainTrips: [TransitPlanner.Trip] = []
    var trip: TransitPlanner.Trip?
    var timetable: Timetable = .notChecked
    /// When the person gets there, when the timetable gives it.
    var arrival: Date?

    enum Timetable { case notChecked, found, notFound, unavailable }

    var polylines: [MKPolyline] { ([route].compactMap { $0 } + legs).map(\.polyline) }
}

enum DirectionsService {
    /// Places matching the words, nearest the person first.
    static func search(_ query: String, near location: CLLocation?) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let location {
            request.region = MKCoordinateRegion(center: location.coordinate,
                                                latitudinalMeters: 40_000, longitudinalMeters: 40_000)
        }
        let items = try await MKLocalSearch(request: request).start().mapItems
        guard let location else { return items }
        return items.sorted { $0.location.distance(from: location) < $1.location.distance(from: location) }
    }

    /// What is at the spot a picture was taken: the businesses and buildings
    /// within the GPS accuracy (ones the camera faced first), then the street address.
    static func places(at place: PhotoPlace) async -> [MKMapItem] {
        let spot = place.location
        let radius = min(max(spot.horizontalAccuracy * 2, 75), 300)
        var items: [MKMapItem] = []
        let request = MKLocalPointsOfInterestRequest(center: spot.coordinate, radius: radius)
        if let found = try? await MKLocalSearch(request: request).start().mapItems {
            items = ranked(found, around: place).prefix(3).map { $0 }
        }
        if let reverse = MKReverseGeocodingRequest(location: spot),
           let address = try? await reverse.mapItems.first,
           !items.contains(where: { $0.location.distance(from: address.location) < 30 && $0.name == address.name }) {
            items.append(address)
        }
        return items
    }

    /// Places matching the words, close to where a picture was taken. Only
    /// the nearest few are kept, favoring the direction the camera faced.
    static func search(_ query: String, around place: PhotoPlace) async throws -> [MKMapItem] {
        let spot = place.location
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        request.region = MKCoordinateRegion(center: spot.coordinate, latitudinalMeters: 3_000, longitudinalMeters: 3_000)
        let items = try await MKLocalSearch(request: request).start().mapItems
        let close = items.filter { $0.location.distance(from: spot) <= 1_500 }
        return Array(ranked(close.isEmpty ? items : close, around: place).prefix(close.isEmpty ? 3 : 5))
    }

    /// Nearest first; a place in front of the camera counts as half as far.
    private static func ranked(_ items: [MKMapItem], around place: PhotoPlace) -> [MKMapItem] {
        let spot = place.location
        func score(_ item: MKMapItem) -> Double {
            let distance = item.location.distance(from: spot)
            guard let heading = place.heading, distance > spot.horizontalAccuracy else { return distance }
            let a = spot.coordinate, b = item.location.coordinate
            let dLon = (b.longitude - a.longitude) * .pi / 180
            let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
            let bearing = atan2(sin(dLon) * cos(lat2), cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)) * 180 / .pi
            return abs(Compass.turn(from: heading, to: bearing)) <= 45 ? distance / 2 : distance
        }
        return items.sorted { score($0) < score($1) }
    }

    /// For a picture with no location: the words are also searched together with
    /// the other words from the picture (a hotel name plus a street sign points to
    /// one place). Places that several searches agree on come first. `near` limits
    /// the search to about 40 km around it; nil searches everywhere.
    static func search(_ query: String, with others: [String], near location: CLLocation?) async -> (items: [MKMapItem], agreed: Bool) {
        let extra = others.filter { $0.lowercased() != query.lowercased() && !query.lowercased().contains($0.lowercased()) }
        let queries = [query] + extra.prefix(5).map { "\(query) \($0)" }
        let lists = await withTaskGroup(of: [MKMapItem].self) { group in
            for text in queries {
                group.addTask { (try? await search(text, near: location))?.prefix(5).map { $0 } ?? [] }
            }
            return await group.reduce(into: [[MKMapItem]]()) { $0.append($1) }
        }
        var places: [(item: MKMapItem, votes: Int)] = []
        for item in lists.flatMap({ $0 }) where !places.contains(where: { $0.item.location.distance(from: item.location) < 50 }) {
            let votes = lists.count { list in list.contains { $0.location.distance(from: item.location) < 250 } }
            places.append((item, votes))
        }
        places.sort { a, b in
            if a.votes != b.votes { return a.votes > b.votes }
            guard let location else { return false }
            return a.item.location.distance(from: location) < b.item.location.distance(from: location)
        }
        let agreed = (places.first?.votes ?? 0) >= 2
        let kept = agreed ? places.filter { $0.votes >= 2 } : places
        return (kept.prefix(5).map(\.item), agreed)
    }

    /// The middle of a city, town, or area the person typed.
    static func locate(area: String) async -> CLLocation? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = area
        request.resultTypes = .address
        return try? await MKLocalSearch(request: request).start().mapItems.first?.location
    }

    static func search(_ completion: MKLocalSearchCompletion) async throws -> [MKMapItem] {
        try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start().mapItems
    }

    /// `board` and `leave` replace the nearest stops when the person picked others;
    /// `transfers` are stations where the person changes trains. `trips` are
    /// train departures already looked up for these stations, and `tripID`
    /// the one picked.
    static func route(to destination: Destination, by transport: Transport,
                      board: MKMapItem? = nil, leave: MKMapItem? = nil,
                      transfers: [MKMapItem] = [],
                      trips: [TransitPlanner.Trip]? = nil, tripID: String? = nil) async throws -> PlannedRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = destination.mapItem
        request.transportType = transport.mapKitType
        let directions = MKDirections(request: request)

        if let ride = Ride(transport) {
            return try await rideRoute(to: destination, by: ride, board: board, leave: leave,
                                       transfers: transfers, trips: trips, tripID: tripID)
        }
        if transport == .transit {
            let eta = try await directions.calculateETA()
            return PlannedRoute(route: nil, steps: [], distance: eta.distance, travelTime: eta.expectedTravelTime)
        }
        guard let route = try await directions.calculate().routes.first else {
            throw DirectionsError.noRoute
        }
        let steps = route.steps.compactMap { step -> String? in
            let text = step.instructions.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return step.distance > 0 ? "\(text) — \(Format.distance(step.distance))" : text
        }
        return PlannedRoute(route: route, steps: steps, distance: route.distance, travelTime: route.expectedTravelTime)
    }
}

/// A bus or train ride, and how to find its stops.
enum Ride {
    case bus, train

    init?(_ transport: Transport) {
        switch transport {
        case .bus: self = .bus
        case .train: self = .train
        default: return nil
        }
    }

    var vehicles: String { self == .bus ? "buses" : "trains" }
    var vehicle: String {
        switch self {
        case .bus: "bus"
        case .train: "train"
        }
    }
    var stop: String {
        switch self {
        case .bus: "stop"
        case .train: "station"
        }
    }
    var queries: [String] {
        switch self {
        case .bus: ["bus stop", "bus station"]
        case .train: ["train station", "rail station", "Amtrak station"]
        }
    }
    /// Shortest trip worth riding for.
    var minimumTrip: CLLocationDistance {
        switch self {
        case .bus: 1_500
        case .train: 3_000
        }
    }
    /// Farthest a stop can be from the start or the destination.
    var searchRadius: CLLocationDistance {
        switch self {
        case .bus: 3_000
        case .train: 24_140 // 15 miles
        }
    }

    func matches(_ name: String) -> Bool {
        let name = name.lowercased()
        switch self {
        case .bus:
            return ["bus", "stop", "terminal", "transit center", "transportation center"].contains { name.contains($0) }
                && !["rail", "train", "amtrak", "subway", "metro station"].contains { name.contains($0) }
        case .train:
            return ["station", "rail", "train", "terminal", "amtrak", "transit center"].contains { name.contains($0) }
                && !name.contains("bus")
        }
    }
}

extension DirectionsService {
    /// Walk (or drive, when it is far) to the nearest stop, ride the bus or
    /// train to the stop nearest the destination, then walk the rest.
    static func rideRoute(to destination: Destination, by ride: Ride,
                          board chosenBoard: MKMapItem?, leave chosenLeave: MKMapItem?,
                          transfers: [MKMapItem] = [],
                          trips cachedTrips: [TransitPlanner.Trip]? = nil, tripID: String? = nil) async throws -> PlannedRoute {
        guard let here = LocationManager.shared.location else { throw DirectionsError.noRoute }
        let there = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
        guard here.distance(from: there) > ride.minimumTrip else { throw DirectionsError.tooClose(ride) }

        async let boardSearch = nearbyStops(to: here, ride: ride)
        async let leaveSearch = nearbyStops(to: there, ride: ride)

        // Buses: the timetable picks the stops, from where the person is to the destination.
        if case .bus = ride,
           let route = try await busTimetableRoute(to: destination, from: here, there: there,
                                                   board: chosenBoard, leave: chosenLeave,
                                                   trips: cachedTrips, tripID: tripID) {
            var route = route
            route.boardOptions = await boardSearch
            route.leaveOptions = await leaveSearch
            return route
        }

        let boardOptions = await boardSearch, leaveOptions = await leaveSearch
        // Nothing within a long walk: try once more from the nearest stop Apple Maps knows.
        if case .bus = ride, chosenBoard == nil, cachedTrips == nil, let nearest = boardOptions.first,
           let route = try await busTimetableRoute(to: destination, from: here, there: there,
                                                   board: nearest, leave: chosenLeave, trips: nil, tripID: tripID) {
            var route = route
            route.boardOptions = boardOptions
            route.leaveOptions = leaveOptions
            return route
        }
        guard let board = chosenBoard ?? boardOptions.first, let leave = chosenLeave ?? leaveOptions.first
        else { throw DirectionsError.noStops(ride) }
        guard board.location.distance(from: leave.location) > 500 else { throw DirectionsError.sameStop(ride) }

        let current = MKMapItem.forCurrentLocation()
        async let toStop = leg(from: current, fromLocation: here, to: board)
        async let fromStop = leg(from: leave, fromLocation: leave.location, to: destination.mapItem)

        // Trains: use the timetable, unless the person picked their own changes.
        var timetable = PlannedRoute.Timetable.notChecked
        if case .train = ride, transfers.isEmpty {
            let first = try await toStop
            var trips = cachedTrips ?? []
            if cachedTrips == nil {
                let catchable = Date().addingTimeInterval(first.expectedTravelTime + 5 * 60)
                switch await TransitPlanner.trainsWithPATH(board: board.location, leave: leave.location, start: here,
                                                           destination: there, toDestination: chosenLeave == nil,
                                                           leavingAfter: catchable) {
                case .trips(let found): trips = found; timetable = .found
                case .notFound: timetable = .notFound
                case .unavailable: timetable = .unavailable
                }
            } else {
                timetable = trips.isEmpty ? .notFound : .found
            }
            if let trip = trips.first(where: { $0.id == tripID }) ?? TransitPlanner.mostDirect(trips) {
                // A trip using PATH may start or end at a PATH station instead.
                let tripStart = trip.rides[0].from, tripEnd = trip.rides[trip.rides.count - 1].to
                let startsAtBoard = tripStart.location.distance(from: board.location) < 400
                let endsAtLeave = tripEnd.location.distance(from: leave.location) < 400
                let startItem = startsAtBoard ? board : mapItem(tripStart)
                let endItem = endsAtLeave ? leave : mapItem(tripEnd)
                let firstLeg = startsAtBoard ? first : try await leg(from: current, fromLocation: here, to: startItem)
                let lastLeg = endsAtLeave ? try await fromStop
                    : try await leg(from: endItem, fromLocation: endItem.location, to: destination.mapItem)
                var route = timetableRoute(trip, first: firstLeg, last: lastLeg, board: startItem, leave: endItem,
                                           destination: destination, ride: .train)
                // The timetable picked a better station to get off at: list it first.
                let pickedStation = !endsAtLeave && !trip.rides[trip.rides.count - 1].title.hasPrefix("PATH")
                route.stations = (board, pickedStation ? endItem : leave)
                route.boardOptions = boardOptions
                route.leaveOptions = pickedStation ? [endItem] + leaveOptions.filter { $0.location.distance(from: endItem.location) > 150 }
                    : leaveOptions
                route.trainTrips = trips
                route.timetable = timetable
                return route
            }
        }

        // One ride between each pair of stations, changing trains in between.
        let stops = [board] + transfersInOrder(transfers, from: board, to: leave) + [leave]
        let rides = await withTaskGroup(of: (Int, MKDirections.ETAResponse?).self) { group in
            for index in 0..<(stops.count - 1) {
                group.addTask { (index, await transitETA(from: stops[index], to: stops[index + 1])) }
            }
            var etas = [MKDirections.ETAResponse?](repeating: nil, count: stops.count - 1)
            for await (index, eta) in group { etas[index] = eta }
            return etas
        }
        let first = try await toStop, last = try await fromStop

        func name(_ stop: MKMapItem) -> String { stop.name ?? "the \(ride.stop)" }
        var steps: [String] = []
        var links: [StepLink?] = []
        let firstVerb = first.transportType == .automobile ? "Drive" : "Walk"
        steps.append("\(firstVerb) to \(name(board)) — \(Format.distance(first.distance)), \(Format.time(first.expectedTravelTime))")
        links.append(StepLink(from: nil, to: board, like: first))
        var rideDistance: CLLocationDistance = 0
        var rideTime: TimeInterval = 0
        for (index, eta) in rides.enumerated() {
            let from = stops[index], to = stops[index + 1]
            let vehicle = ride.vehicle
            if index > 0 {
                steps.append("Change \(ride.vehicles) at \(name(from))")
                links.append(nil)
            }
            links.append(.transit(from: from, to: to))
            if let eta {
                steps.append("Take the \(vehicle) from \(name(from)) to \(name(to)) — about \(Format.time(eta.expectedTravelTime)) including waiting")
                rideTime += eta.expectedTravelTime
            } else {
                steps.append("Take the \(vehicle) from \(name(from)) to \(name(to)) — check Maps for times")
            }
            rideDistance += eta?.distance ?? from.location.distance(from: to.location)
        }
        steps.append("\(lastLegVerb(last)) from \(name(leave)) to \(destination.name) — \(Format.distance(last.distance)), \(Format.time(last.expectedTravelTime))")
        links.append(StepLink(from: leave, to: destination.mapItem, like: last))

        return PlannedRoute(route: nil, steps: steps, stepLinks: links,
                            distance: first.distance + rideDistance + last.distance,
                            travelTime: first.expectedTravelTime + rideTime + last.expectedTravelTime,
                            legs: [first, last], stations: (board, leave),
                            boardOptions: boardOptions, leaveOptions: leaveOptions, rideStops: stops,
                            timetable: timetable)
    }

    /// After the bus or train the car is back at the first station, so a
    /// stretch too far to walk is a taxi or rideshare, not a drive.
    private static func lastLegVerb(_ last: MKRoute) -> String {
        last.transportType == .automobile ? "Take a taxi or rideshare" : "Walk"
    }

    private static func mapItem(_ stop: TransitPlanner.Stop) -> MKMapItem {
        let item = MKMapItem(location: stop.location, address: nil)
        item.name = stop.name
        return item
    }

    /// A bus trip from the timetable, or nil when it has none (then the
    /// nearest stops and Apple Maps' estimate are used instead).
    private static func busTimetableRoute(to destination: Destination, from here: CLLocation, there: CLLocation,
                                          board: MKMapItem?, leave: MKMapItem?,
                                          trips cachedTrips: [TransitPlanner.Trip]?, tripID: String?) async throws -> PlannedRoute? {
        var trips = cachedTrips ?? []
        var timetable = PlannedRoute.Timetable.found
        if cachedTrips == nil {
            let start = board?.location ?? here
            let walk = board.map { here.distance(from: $0.location) / 1.3 } ?? 0
            let end = leave?.location ?? there, leavingAfter = Date().addingTimeInterval(walk)
            // A short walk to the stop first; if no bus is that close, a longer one.
            if case .trips(let found) = await TransitPlanner.buses(from: start, to: end, leavingAfter: leavingAfter) {
                trips = found
            } else if case .trips(let found) = await TransitPlanner.buses(from: start, to: end, leavingAfter: leavingAfter,
                                                                           longWalk: true) {
                trips = found
            } else {
                return nil
            }
        } else if trips.isEmpty {
            timetable = .notFound
        }
        guard let trip = trips.first(where: { $0.id == tripID }) ?? TransitPlanner.mostDirect(trips) else { return nil }
        let startItem = mapItem(trip.rides[0].from), endItem = mapItem(trip.rides[trip.rides.count - 1].to)
        async let toStop = leg(from: MKMapItem.forCurrentLocation(), fromLocation: here, to: startItem)
        async let fromStop = leg(from: endItem, fromLocation: endItem.location, to: destination.mapItem)
        var route = timetableRoute(trip, first: try await toStop, last: try await fromStop,
                                   board: startItem, leave: endItem, destination: destination, ride: .bus)
        route.stations = (startItem, endItem)
        route.trainTrips = trips
        route.timetable = timetable
        return route
    }

    /// Steps for a timetabled bus or train trip: which ones, when, and where to change.
    private static func timetableRoute(_ trip: TransitPlanner.Trip, first: MKRoute, last: MKRoute,
                                       board: MKMapItem, leave: MKMapItem, destination: Destination,
                                       ride: Ride) -> PlannedRoute {
        // A few minutes to spare: more for a train station than a bus stop.
        let spare: TimeInterval = ride == .bus ? 2 * 60 : 5 * 60
        let leaveBy = trip.departure.addingTimeInterval(-first.expectedTravelTime - spare)
        let start = trip.rides[0]
        func item(_ stop: TransitPlanner.Stop) -> MKMapItem {
            let item = MKMapItem(location: stop.location, address: nil)
            item.name = stop.name
            return item
        }
        var steps: [String] = []
        var links: [StepLink?] = []
        let firstVerb = first.transportType == .automobile ? "Drive" : "Walk"
        steps.append("\(firstVerb) to \(board.name ?? start.from.name) — \(Format.distance(first.distance)), "
                     + "\(Format.time(first.expectedTravelTime)). Leave by \(start.time(leaveBy)).")
        links.append(StepLink(from: nil, to: board, like: first))
        for (index, train) in trip.rides.enumerated() {
            let from = index == 0 ? board : item(train.from)
            let to = index == trip.rides.count - 1 ? leave : item(train.to)
            if index > 0 {
                let previous = trip.rides[index - 1]
                let wait = Format.time(train.departure.timeIntervalSince(previous.arrival))
                if let walk = trip.changeWalks[index - 1], walk > 30 || previous.to.name != train.from.name {
                    steps.append("Change \(ride.vehicles): walk \(Format.distance(walk)) from \(previous.to.name) to \(train.from.name) — \(wait) to make the connection")
                    links.append(StepLink(from: item(previous.to), to: item(train.from), mode: MKLaunchOptionsDirectionsModeWalking))
                } else {
                    steps.append("Change \(ride.vehicles) at \(train.from.name) — \(wait) to make the connection")
                    links.append(nil)
                }
            }
            let toward = train.headsign.map { " toward \($0)" } ?? ""
            steps.append("\(train.time(train.departure)): take the \(train.title)\(toward) from \(train.from.name). "
                         + "Get off at \(train.to.name) at \(train.time(train.arrival)).")
            links.append(.transit(from: from, to: to))
        }
        steps.append("\(lastLegVerb(last)) from \(leave.name ?? trip.rides[trip.rides.count - 1].to.name) to \(destination.name) — "
                     + "\(Format.distance(last.distance)), \(Format.time(last.expectedTravelTime))")
        links.append(StepLink(from: leave, to: destination.mapItem, like: last))

        let changeStops = trip.rides.dropFirst().map { item($0.from) }
        let rideDistance = trip.rides.reduce(0) { $0 + $1.from.location.distance(from: $1.to.location) }
        let arrival = trip.arrival.addingTimeInterval(last.expectedTravelTime)
        return PlannedRoute(route: nil, steps: steps, stepLinks: links,
                            distance: first.distance + rideDistance + last.distance,
                            travelTime: arrival.timeIntervalSince(leaveBy),
                            legs: [first, last], stations: (board, leave),
                            rideStops: [board] + changeStops + [leave],
                            trip: trip, arrival: arrival)
    }

    /// Changes of train in travel order: nearest the boarding station first.
    static func transfersInOrder(_ transfers: [MKMapItem], from board: MKMapItem, to leave: MKMapItem) -> [MKMapItem] {
        transfers
            .filter { $0.location.distance(from: board.location) > 150 && $0.location.distance(from: leave.location) > 150 }
            .sorted { $0.location.distance(from: board.location) < $1.location.distance(from: board.location) }
    }

    /// Train stations between two stations where a change of trains could be,
    /// those adding the least distance first.
    static func transferStations(from board: MKMapItem, to leave: MKMapItem, ride: Ride) async -> [MKMapItem] {
        let a = board.location, b = leave.location
        let direct = a.distance(from: b)
        let middle = CLLocation(latitude: (a.coordinate.latitude + b.coordinate.latitude) / 2,
                                longitude: (a.coordinate.longitude + b.coordinate.longitude) / 2)
        var items: [MKMapItem] = []
        // Search the whole stretch, and also around the middle and each end,
        // since each search returns only a limited number of places.
        for (center, span) in [(middle, direct * 1.4), (middle, direct * 0.6), (a, direct * 0.6), (b, direct * 0.6)] {
            for query in ride.queries {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                request.resultTypes = .pointOfInterest
                request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.publicTransport])
                request.region = MKCoordinateRegion(center: center.coordinate,
                                                    latitudinalMeters: max(span, 5_000), longitudinalMeters: max(span, 5_000))
                items += (try? await MKLocalSearch(request: request).start().mapItems) ?? []
            }
        }
        func detour(_ item: MKMapItem) -> Double { a.distance(from: item.location) + item.location.distance(from: b) - direct }
        let sorted = items
            .filter { ride.matches($0.name ?? "") }
            .filter { $0.location.distance(from: a) > 500 && $0.location.distance(from: b) > 500 }
            .filter { detour($0) <= max(direct * 0.4, 5_000) }
            .sorted { detour($0) < detour($1) }
        var stops: [MKMapItem] = []
        for item in sorted where !stops.contains(where: { $0.location.distance(from: item.location) < 150 }) {
            stops.append(item)
        }
        return Array(stops.prefix(20))
    }

    /// Bus stops or train stations within the ride's search radius, nearest first.
    private static func nearbyStops(to location: CLLocation, ride: Ride) async -> [MKMapItem] {
        var items: [MKMapItem] = []
        for query in ride.queries {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = .pointOfInterest
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.publicTransport])
            request.region = MKCoordinateRegion(center: location.coordinate,
                                                latitudinalMeters: ride.searchRadius * 2, longitudinalMeters: ride.searchRadius * 2)
            items += (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        }
        let sorted = items
            .filter { ride.matches($0.name ?? "") && $0.location.distance(from: location) <= ride.searchRadius }
            .sorted { $0.location.distance(from: location) < $1.location.distance(from: location) }
        // The searches overlap, so drop repeats of the same stop.
        var stops: [MKMapItem] = []
        for item in sorted where !stops.contains(where: { $0.location.distance(from: item.location) < 150 }) {
            stops.append(item)
        }
        return stops
    }

    /// Walking when the stop is within 2 km, otherwise driving.
    private static func leg(from source: MKMapItem, fromLocation: CLLocation, to target: MKMapItem) async throws -> MKRoute {
        let request = MKDirections.Request()
        request.source = source
        request.destination = target
        request.transportType = fromLocation.distance(from: target.location) <= 2_000 ? .walking : .automobile
        guard let route = try await MKDirections(request: request).calculate().routes.first else {
            throw DirectionsError.noRoute
        }
        return route
    }

    private static func transitETA(from board: MKMapItem, to leave: MKMapItem) async -> MKDirections.ETAResponse? {
        let request = MKDirections.Request()
        request.source = board
        request.destination = leave
        request.transportType = .transit
        return try? await MKDirections(request: request).calculateETA()
    }
}

enum DirectionsError: LocalizedError {
    case noRoute, tooClose(Ride), noStops(Ride), sameStop(Ride)
    var errorDescription: String? {
        switch self {
        case .noRoute: "No route was found to this place."
        case .tooClose(let ride): "This place is too close for the \(ride.vehicle). Try Walk."
        case .noStops(.bus): "No bus stops were found near both you and this place. Try Train."
        case .noStops(.train): "No train stations were found near both you and this place. Try Bus."
        case .sameStop(let ride): "The \(ride.stop)s to get on and off at are the same. Pick a different \(ride.stop)."
        }
    }
}

enum Format {
    private static let distanceFormatter: MKDistanceFormatter = {
        let formatter = MKDistanceFormatter()
        formatter.unitStyle = .abbreviated
        return formatter
    }()

    static func distance(_ meters: CLLocationDistance) -> String {
        distanceFormatter.string(fromDistance: meters)
    }

    static func time(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(60, seconds)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

/// Suggestions while typing a destination.
@Observable
final class SearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    func update(_ text: String, near location: CLLocation?) {
        if let location {
            completer.region = MKCoordinateRegion(center: location.coordinate,
                                                  latitudinalMeters: 40_000, longitudinalMeters: 40_000)
        }
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            results = []
        } else {
            completer.queryFragment = text
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { results = completer.results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {}
}

/// A search result: name, address, and how far away it is.
struct MapItemRow: View {
    let item: MKMapItem

    var body: some View {
        HStack {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading) {
                Text(item.name ?? "Place").foregroundStyle(.primary)
                if let address = item.address?.shortAddress ?? item.address?.fullAddress {
                    Text(address).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let here = LocationManager.shared.location {
                Text(Format.distance(item.location.distance(from: here)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
