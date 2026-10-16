import CoreLocation
import Foundation

/// Train and bus timetables from Transitous (transitous.org), a free,
/// community-run trip planner built on the published schedules. Apple Maps
/// does not give apps train or bus names or where to change, so this is where
/// they come from. Only where the trip starts (the station for trains; for
/// buses, the person's location rounded to about 100 m), where it goes, and
/// the time are sent.
enum TransitPlanner {
    struct Stop: Hashable {
        var name: String
        var latitude: Double
        var longitude: Double
        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    }

    /// One train, from getting on to getting off.
    struct Ride: Hashable {
        /// "Amtrak Northeast Regional 118"
        var title: String
        /// Where the train is heading, as shown on it.
        var headsign: String?
        var from: Stop
        var to: Stop
        var departure: Date
        var arrival: Date
        var timeZone: TimeZone
    }

    /// A way to make the trip: one or more trains, changing in between.
    struct Trip: Identifiable, Hashable {
        var rides: [Ride]
        /// Walking between trains at each change, when the timetable has it.
        var changeWalks: [CLLocationDistance?]

        var id: String { rides.map { "\($0.title)@\($0.departure.timeIntervalSince1970)" }.joined(separator: "|") }
        var departure: Date { rides[0].departure }
        var arrival: Date { rides[rides.count - 1].arrival }
        var changes: Int { rides.count - 1 }
        var duration: TimeInterval { arrival.timeIntervalSince(departure) }
        /// The stations where this trip changes trains, in order.
        var changeStations: [String] { rides.dropFirst().map(\.from.name) }
        /// "Philadelphia", "Lindenwold, 8th-Market, Philadelphia", or "Direct".
        var changeSummary: String { changes == 0 ? "Direct" : changeStations.joined(separator: ", ") }
        /// How far the trains carry you, station to station in straight lines,
        /// so a trip that goes past the destination and back counts the extra.
        var rideDistance: CLLocationDistance { rides.reduce(0) { $0 + $1.from.location.distance(from: $1.to.location) } }
    }

    /// The simplest good trip: the fewest changes among trips that arrive
    /// within 30 minutes of the quickest. Of those, a trip that goes out of
    /// the way (into New York Penn and back downtown, when Newark → PATH
    /// goes straight there) loses to a more direct one arriving within 10
    /// minutes of it.
    static func mostDirect(_ trips: [Trip]) -> Trip? {
        guard let fastest = quickest(trips) else { return nil }
        let soonEnough = trips.filter { $0.arrival <= fastest.arrival.addingTimeInterval(30 * 60) }
        guard let fewest = soonEnough.map(\.changes).min() else { return nil }
        let simplest = soonEnough.filter { $0.changes == fewest }
        guard let first = simplest.min(by: { $0.arrival < $1.arrival }) else { return nil }
        let close = simplest.filter { $0.arrival <= first.arrival.addingTimeInterval(10 * 60) }
        return close.min { ($0.rideDistance, $0.arrival) < ($1.rideDistance, $1.arrival) }
    }

    static func quickest(_ trips: [Trip]) -> Trip? {
        trips.min { ($0.arrival, $0.duration) < ($1.arrival, $1.duration) }
    }

    enum Outcome {
        case trips([Trip])
        /// The timetable has no train between these stations.
        case notFound
        /// Transitous could not be reached.
        case unavailable
    }

    static func trains(from: CLLocation, to: CLLocation, leavingAfter time: Date) async -> Outcome {
        await plan(from: from, to: to, leavingAfter: time, modes: "RAIL")
    }

    /// Bus trips from the bus timetables. `from` and `to` can be the person
    /// and the destination: Transitous picks the stops and the walks to them.
    /// `longWalk` allows up to 30 minutes' walk at each end instead of 15,
    /// for places with no bus stop close by.
    static func buses(from: CLLocation, to: CLLocation, leavingAfter time: Date, longWalk: Bool = false) async -> Outcome {
        await plan(from: rounded(from), to: to, leavingAfter: time, modes: "BUS", maxWalk: longWalk ? 30 * 60 : nil)
    }

    /// About 100 m: close enough to find the right stops, without sending
    /// exactly where the person is.
    private static func rounded(_ location: CLLocation) -> CLLocation {
        CLLocation(latitude: (location.coordinate.latitude * 1000).rounded() / 1000,
                   longitude: (location.coordinate.longitude * 1000).rounded() / 1000)
    }

    private static func plan(from: CLLocation, to: CLLocation, leavingAfter time: Date, modes: String,
                             maxWalk: TimeInterval? = nil) async -> Outcome {
        var components = URLComponents(string: "https://api.transitous.org/api/v5/plan")!
        components.queryItems = [
            URLQueryItem(name: "fromPlace", value: "\(from.coordinate.latitude),\(from.coordinate.longitude)"),
            URLQueryItem(name: "toPlace", value: "\(to.coordinate.latitude),\(to.coordinate.longitude)"),
            URLQueryItem(name: "time", value: ISO8601DateFormatter().string(from: time)),
            URLQueryItem(name: "transitModes", value: modes),
        ]
        if let maxWalk {
            components.queryItems! += [URLQueryItem(name: "maxPreTransitTime", value: String(Int(maxWalk))),
                                       URLQueryItem(name: "maxPostTransitTime", value: String(Int(maxWalk)))]
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue("TextPictureDirections/1.0 (iOS; com.thomasdaly.TextPictureDirections)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let plan = try? JSONDecoder().decode(Plan.self, from: data) else { return .unavailable }
        let trips = plan.itineraries.compactMap(trip)
        return trips.isEmpty ? .notFound : .trips(trips)
    }

    // MARK: - Transitous answer

    private struct Plan: Decodable {
        var itineraries: [Itinerary]
    }

    private struct Itinerary: Decodable {
        var legs: [Leg]
    }

    private struct Leg: Decodable {
        struct Place: Decodable {
            var name: String
            var lat: Double
            var lon: Double
            var tz: String?
        }
        var mode: String
        var from: Place
        var to: Place
        var startTime: String
        var endTime: String
        var distance: Double?
        var headsign: String?
        var routeShortName: String?
        var routeLongName: String?
        var agencyName: String?
        var tripShortName: String?
        /// Where this bus or train's whole run starts.
        var tripFrom: TripEnd?

        struct TripEnd: Decodable {
            var name: String
        }
    }

    private static let walkingModes: Set<String> = ["WALK", "BIKE", "CAR", "FLEX", "RENTAL"]

    private static func trip(_ itinerary: Itinerary) -> Trip? {
        var rides: [Ride] = []
        var changeWalks: [CLLocationDistance?] = []
        var walkSinceLastRide: CLLocationDistance?
        for leg in itinerary.legs {
            if walkingModes.contains(leg.mode) {
                if !rides.isEmpty { walkSinceLastRide = (walkSinceLastRide ?? 0) + (leg.distance ?? 0) }
                continue
            }
            guard let departure = date(leg.startTime), let arrival = date(leg.endTime) else { return nil }
            if !rides.isEmpty { changeWalks.append(walkSinceLastRide) }
            walkSinceLastRide = nil
            rides.append(Ride(title: title(leg),
                              headsign: leg.headsign.map { headsign($0, of: leg) },
                              from: Stop(name: tidy(leg.from.name), latitude: leg.from.lat, longitude: leg.from.lon),
                              to: Stop(name: tidy(leg.to.name), latitude: leg.to.lat, longitude: leg.to.lon),
                              departure: departure, arrival: arrival,
                              timeZone: leg.from.tz.flatMap(TimeZone.init(identifier:)) ?? .current))
        }
        return rides.isEmpty ? nil : Trip(rides: rides, changeWalks: changeWalks)
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// "NJ Transit Atlantic City Rail Line", "Amtrak Northeast Regional 118",
    /// "NJ Transit bus 815 (Woodbridge Center Mall – New Brunswick)",
    /// "MTA New York City Transit bus M2 (Washington Heights – East Village)".
    private static func title(_ leg: Leg) -> String {
        var agency = tidy(leg.agencyName ?? "")
        if leg.mode == "BUS", let number = leg.routeShortName?.trimmingCharacters(in: .whitespaces), !number.isEmpty {
            // "NJ TRANSIT BUS" → "NJ Transit bus 815"
            if agency.lowercased().hasSuffix(" bus") { agency.removeLast(4) }
            // Some companies put their own name where the number goes.
            let bus = agency.isEmpty ? "Bus \(number)"
                : number.lowercased() == agency.lowercased() ? "\(agency) bus" : "\(agency) bus \(number)"
            return busLine(leg).map { "\(bus) (\($0))" } ?? bus
        }
        for suffix in [" Rail", " Railroad"] where agency.hasSuffix(suffix) { agency.removeLast(suffix.count) }
        let line = [leg.routeLongName, leg.routeShortName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            .map { tidy($0) } ?? "train"
        var parts: [String] = []
        if !agency.isEmpty, !line.lowercased().hasPrefix(agency.lowercased()) { parts.append(agency) }
        parts.append(line)
        if let number = leg.tripShortName?.trimmingCharacters(in: .whitespaces), !number.isEmpty { parts.append(number) }
        return parts.joined(separator: " ")
    }

    /// The bus line's name. When the bus company doesn't publish one (NJ Transit
    /// doesn't), it's named for the ends of this bus's run.
    private static func busLine(_ leg: Leg) -> String? {
        func spaced(_ text: String) -> String { text.split(separator: " ").joined(separator: " ") }
        if let name = leg.routeLongName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return spaced(tidy(name)).replacingOccurrences(of: " - ", with: " – ")
        }
        guard let start = leg.tripFrom.map({ spaced(tidy($0.name)) }), let end = leg.headsign.map({ spaced(headsign($0, of: leg)) }),
              !start.isEmpty, !end.isEmpty else { return nil }
        // "Metropark Rail Station Bus Lane 5 – Metropark" names nothing.
        let a = start.lowercased(), b = end.lowercased()
        guard !a.contains(b), !b.contains(a) else { return nil }
        return "\(start) – \(end)"
    }

    /// Bus signs often repeat the route number and the fare rule
    /// ("815 WOODBRIDGE CENTER-Exact Fare"); keep just where it's heading.
    private static func headsign(_ text: String, of leg: Leg) -> String {
        var sign = text.trimmingCharacters(in: .whitespaces)
        for suffix in ["-Exact Fare", " - Exact Fare"] where sign.lowercased().hasSuffix(suffix.lowercased()) {
            sign.removeLast(suffix.count)
        }
        if let number = leg.routeShortName?.trimmingCharacters(in: .whitespaces), !number.isEmpty,
           sign.hasPrefix(number + " ") {
            sign.removeFirst(number.count + 1)
        }
        return tidy(sign)
    }

    /// Railways often publish names in capitals ("30TH ST. PHL."); this makes
    /// them read normally ("30th St. PHL.") while keeping short initials.
    /// Bus stops too: "MAIN ST AT REID ST" → "Main St at Reid St",
    /// "WOODBRIDGE CTR DR" → "Woodbridge Ctr Dr".
    private static func tidy(_ text: String) -> String {
        // "TOWER CENTER BLVD AT PARK & RIDE CROSSWALK#"
        let trimmed = text.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "#")))
        // Small words are sometimes already lowercase: "HARLEM 147 ST via 6 AV".
        let small: Set<String> = ["at", "of", "and", "to", "via", "the", "on", "in", "for"]
        let capitals = trimmed.split(separator: " ").filter { !small.contains(String($0)) }.joined(separator: " ")
        guard capitals == capitals.uppercased(), trimmed.contains(where: \.isLetter) else { return trimmed }
        // Short words that are abbreviations, not initials, so they read "St", "Ave", "Ctr".
        let words: Set<String> = ["ST", "AV", "AVE", "RD", "DR", "CTR", "HTS", "LN", "PL", "CT", "SQ", "HWY", "PKY", "BUS",
                                  "THE", "OF", "AT", "AND", "TO", "VIA", "ON", "IN", "FOR", "NEW", "SEA"]
        let initials: Set<String> = ["SEPTA", "PATCO", "LIRR", "MBTA", "MARTA", "BART", "SMART", "VTA", "DART", "METRA"]
        return trimmed.split(separator: " ").enumerated().map { index, word -> String in
            let letters = word.filter(\.isLetter)
            if word.contains(where: \.isNumber) {
                // "30TH" → "30th", "BROADWAY-168" → "Broadway-168"
                let ordinal = word.drop { $0.isNumber }
                return ordinal.isEmpty || ["ST", "ND", "RD", "TH", "ST."].contains(ordinal.uppercased())
                    ? word.lowercased() : word.lowercased().capitalized
            }
            if initials.contains(letters) { return String(word) }
            if index > 0, small.contains(word.lowercased()) { return word.lowercased() }
            if letters.count <= 3, !words.contains(letters) { return String(word) }
            return word.lowercased().capitalized
        }.joined(separator: " ")
    }
}

extension TransitPlanner.Ride {
    /// "10:12 AM", with the time zone added when it is not the phone's.
    func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        var text = formatter.string(from: date)
        if timeZone.secondsFromGMT(for: date) != TimeZone.current.secondsFromGMT(for: date) {
            text += " " + (timeZone.abbreviation(for: date) ?? timeZone.identifier)
        }
        return text
    }
}
