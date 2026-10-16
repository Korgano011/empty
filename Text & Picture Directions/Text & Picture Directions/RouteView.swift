import MapKit
import SwiftUI

/// Directions from where the person is to a destination: the route on a
/// map, travel time, and each step. Saved directions from the repository
/// also show the steps as they were saved.
struct RouteView: View {
    let destination: Destination
    var saved: SavedDirections? = nil

    @AppStorage("transport") private var transport: Transport = .walking
    @State private var planned: PlannedRoute?
    @State private var loading = false
    @State private var error: String?
    @State private var position: MapCameraPosition = .automatic
    @State private var saving = false
    /// Train stations the person picked instead of the nearest ones.
    @State private var board: MKMapItem?
    @State private var leave: MKMapItem?
    /// The choices to pick from, kept while a new route loads.
    @State private var boardOptions: [MKMapItem] = []
    @State private var leaveOptions: [MKMapItem] = []
    /// Stations where the person changes trains.
    @State private var transfers: [MKMapItem] = []
    @State private var choosingTransfer = false
    /// Train departures from the timetable for the current stations (nil until
    /// looked up), and the one picked.
    @State private var trips: [TransitPlanner.Trip]?
    @State private var tripID: String?
    @State private var loadingLater = false
    /// Only show departures that change at these stations (a trip's changeSummary).
    @State private var changeFilter: String?
    /// Trains start with just the most direct route; this shows the rest.
    @State private var showMoreOptions = false

    var body: some View {
        List {
            Section {
                Map(position: $position) {
                    UserAnnotation()
                    Marker(destination.name, coordinate: destination.coordinate)
                    if let first = planned?.rideStops.first, let last = planned?.rideStops.last {
                        Marker(first.name ?? "Board", systemImage: transport.systemImage,
                               coordinate: first.location.coordinate)
                            .tint(.green)
                        Marker(last.name ?? "Get off", systemImage: transport.systemImage,
                               coordinate: last.location.coordinate)
                            .tint(.green)
                    }
                    ForEach(Array((planned?.rideStops ?? []).dropFirst().dropLast().enumerated()), id: \.offset) { _, stop in
                        Marker(stop.name ?? "Change trains", systemImage: "arrow.triangle.swap",
                               coordinate: stop.location.coordinate)
                            .tint(.orange)
                    }
                    ForEach(Array((planned?.polylines ?? []).enumerated()), id: \.offset) { _, polyline in
                        MapPolyline(polyline)
                            .stroke(.blue, lineWidth: 6)
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .frame(height: 280)
                .listRowInsets(EdgeInsets())
            }

            Section {
                Picker("Travel by", selection: $transport) {
                    ForEach(Transport.choices) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                .pickerStyle(.segmented)
                if loading {
                    HStack { ProgressView(); Text("Finding a route…").foregroundStyle(.secondary) }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if let planned {
                    LabeledContent("Distance", value: Format.distance(planned.distance))
                    LabeledContent("Time", value: Format.time(planned.travelTime))
                    if let arrival = planned.arrival, let ride = planned.trip?.rides.last {
                        LabeledContent("Arrive", value: ride.time(arrival))
                    }
                }
            } header: {
                Text(destination.name)
            } footer: {
                if let address = destination.address { Text(address) }
            }

            if let planned, !planned.steps.isEmpty {
                Section("Directions") {
                    ForEach(Array(planned.steps.enumerated()), id: \.offset) { index, step in
                        StepRow(number: index + 1, text: step,
                                link: index < planned.stepLinks.count ? planned.stepLinks[index] : nil)
                    }
                }
                if transport == .bus, planned.trip == nil {
                    Section {
                        Label("No bus in the timetable goes from near here to this place, so these are Apple Maps’ nearest stops and estimated time, without bus names. Bus Times in Maps may show which buses run.",
                              systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                if let stations = planned.stations {
                    Section {
                        Button("\(transport.title) Times in Maps", systemImage: transport.systemImage) {
                            MKMapItem.openMaps(with: [stations.board, stations.leave],
                                               launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit])
                        }
                        Button("Whole Trip by Transit in Maps", systemImage: "map", action: openInMaps)
                    } footer: {
                        Text("The map button on each step opens Apple Maps for just that stretch. \(transport.title) Times shows Maps' transit directions from \(stations.board.name ?? "the first stop") to \(stations.leave.name ?? "the last stop"). Times are estimates; check the schedule before you go.")
                    }
                }
            } else if transport == .transit && planned != nil {
                Section {
                    Button("Open Transit Directions in Maps", systemImage: "map", action: openInMaps)
                } footer: {
                    Text("Apple Maps has the bus and train steps for this trip.")
                }
            }

            // Trains and timetabled buses show just the most direct route; the
            // other departures, stations and changes are tucked under More Options.
            if hasMoreOptions {
                Section {
                    Button {
                        withAnimation { showMoreOptions.toggle() }
                    } label: {
                        Label(showMoreOptions ? "Fewer Options" : "More Options",
                              systemImage: showMoreOptions ? "chevron.up" : "slider.horizontal.3")
                    }
                } footer: {
                    if !showMoreOptions {
                        Text(transport == .bus
                             ? "Showing the most direct route. More Options has other buses and places to change."
                             : "Showing the most direct route. More Options has other trains, stations and places to change.")
                    }
                }
            }

            if !hasMoreOptions || showMoreOptions {
                // Shown even when the picked stations give no route, so another can be picked.
                if transport == .train, !boardOptions.isEmpty {
                    stationChoices(title: "Get on at", subtitle: "within 15 miles of you",
                                   options: boardOptions, current: board ?? planned?.stations?.board,
                                   from: LocationManager.shared.location) { board = $0 }
                    stationChoices(title: "Get off at", subtitle: "within 15 miles of \(destination.name)",
                                   options: leaveOptions, current: leave ?? planned?.stations?.leave,
                                   from: CLLocation(latitude: destination.latitude, longitude: destination.longitude)) { leave = $0 }
                }

                if transport == .train || transport == .bus, transfers.isEmpty, let trips, !trips.isEmpty {
                    let options = changeOptions(trips)
                    if options.count > 1 {
                        Section {
                            Button {
                                changeFilter = nil
                                tripID = TransitPlanner.mostDirect(trips)?.id
                            } label: {
                                ChangeOptionRow(title: "Any", trips: trips, selected: changeFilter == nil, vehicle: vehicle)
                            }
                            ForEach(options, id: \.self) { option in
                                let matching = trips.filter { $0.changeSummary == option }
                                Button {
                                    changeFilter = option
                                    tripID = TransitPlanner.mostDirect(matching)?.id
                                } label: {
                                    ChangeOptionRow(title: option == "Direct" ? "Direct — no change" : "Change at \(option)",
                                                    trips: matching, selected: changeFilter == option, vehicle: vehicle)
                                }
                            }
                        } header: {
                            Text("Where to change")
                        } footer: {
                            Text("Each way of making the trip in the timetable. Pick one to see only its \(vehicles).")
                        }
                    }

                    Section {
                        let quickest = TransitPlanner.quickest(trips)
                        ForEach(trips.filter { changeFilter == nil || $0.changeSummary == changeFilter }) { trip in
                            Button { tripID = trip.id } label: {
                                TripRow(trip: trip, selected: trip.id == (planned?.trip?.id ?? tripID),
                                        quickest: trip.id == quickest?.id)
                            }
                        }
                        if loadingLater {
                            HStack { ProgressView(); Text("Finding later \(vehicles)…").foregroundStyle(.secondary) }
                        } else {
                            Button("Later \(vehicles.capitalized)", systemImage: "clock.arrow.circlepath") { Task { await loadLaterTrains() } }
                        }
                    } header: {
                        Text("Departures")
                    } footer: {
                        Text(transport == .bus
                             ? "From published bus timetables via Transitous. Traffic delays aren't shown; check with the bus company before you go."
                             : "From published timetables via Transitous. PATH times are from the Port Authority's regular PATH timetable built into the app, without construction or holiday changes. Delays and track changes aren't shown; check with the railway before you go.")
                    }
                }

                if transport == .train, let stations = planned?.stations {
                    Section {
                        if transfers.isEmpty, let trip = planned?.trip {
                            if trip.changes == 0 {
                                Label("No change — \(trip.rides[0].title) goes all the way", systemImage: "checkmark.circle")
                            }
                            ForEach(Array(trip.rides.dropFirst().enumerated()), id: \.offset) { index, train in
                                VStack(alignment: .leading) {
                                    Label(train.from.name, systemImage: "arrow.triangle.swap")
                                    Text("\(trip.rides[index].title) → \(train.title)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach(DirectionsService.transfersInOrder(transfers, from: stations.board, to: stations.leave), id: \.self) { stop in
                            Label(stop.name ?? "Station", systemImage: "arrow.triangle.swap")
                        }
                        .onDelete { offsets in
                            let ordered = DirectionsService.transfersInOrder(transfers, from: stations.board, to: stations.leave)
                            let removed = offsets.map { ordered[$0] }
                            transfers.removeAll { removed.contains($0) }
                        }
                        Button(transfers.isEmpty && planned?.trip != nil ? "Plan My Own Change of Trains" : "Add a Change of Trains",
                               systemImage: "plus") { choosingTransfer = true }
                    } header: {
                        Text("Change trains at")
                    } footer: {
                        Text(changeFooter)
                    }
                }

            }

            if let saved, !saved.steps.isEmpty {
                Section {
                    ForEach(Array(saved.steps.enumerated()), id: \.offset) { index, step in
                        StepRow(number: index + 1, text: step)
                    }
                } header: {
                    Text("As saved by \(saved.authorName)")
                } footer: {
                    Text("These steps start where \(saved.authorName) was when they saved them. The directions above start where you are.")
                }
            }
            if let note = saved?.note, !note.isEmpty {
                Section("Note") { Text(note) }
            }
        }
        .navigationTitle(destination.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Open in Maps", systemImage: "map", action: openInMaps)
            }
            ToolbarItem(placement: .primaryAction) {
                if let saved {
                    RepositoryMenu(item: saved)
                } else {
                    Button("Save to Repository", systemImage: "icloud.and.arrow.up") { saving = true }
                        .disabled(planned == nil)
                }
            }
        }
        .task(id: transport) {
            if transport == .transit { transport = .bus }
            board = nil
            leave = nil
            boardOptions = []
            leaveOptions = []
            transfers = []
            resetTrips()
            await load()
        }
        .onChange(of: board) { resetTrips(); Task { await load() } }
        .onChange(of: transfers) { Task { await load() } }
        .sheet(isPresented: $choosingTransfer) {
            if let stations = planned?.stations {
                TransferPicker(board: stations.board, leave: stations.leave, chosen: transfers) {
                    transfers.append($0)
                }
            }
        }
        .onChange(of: leave) { resetTrips(); Task { await load() } }
        .onChange(of: tripID) { Task { await load() } }
        .sheet(isPresented: $saving) {
            SaveDirectionsSheet(destination: destination, transport: transport, planned: planned)
        }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let route = try await DirectionsService.route(to: destination, by: transport, board: board, leave: leave,
                                                          transfers: transport == .train ? transfers : [],
                                                          trips: trips, tripID: tripID)
            planned = route
            if !route.boardOptions.isEmpty { boardOptions = route.boardOptions }
            if !route.leaveOptions.isEmpty { leaveOptions = route.leaveOptions }
            let firstLookup = trips == nil
            if route.timetable != .notChecked, route.timetable != .unavailable { trips = route.trainTrips }
            // One batch of departures shows few ways to change; fetch the next batch too.
            if firstLookup, route.timetable == .found { Task { await loadLaterTrains() } }
            position = .automatic
        } catch {
            planned = nil
            self.error = LocationManager.shared.isDenied
                ? "Allow location access in Settings to get directions from where you are."
                : error.localizedDescription
        }
    }

    private func resetTrips() {
        trips = nil
        tripID = nil
        changeFilter = nil
    }

    /// The different ways of making the trip, quickest first.
    private func changeOptions(_ trips: [TransitPlanner.Trip]) -> [String] {
        let grouped = Dictionary(grouping: trips, by: \.changeSummary)
        return grouped.keys.sorted {
            let a = TransitPlanner.quickest(grouped[$0]!)!, b = TransitPlanner.quickest(grouped[$1]!)!
            return (a.arrival, a.duration) < (b.arrival, b.duration)
        }
    }

    /// Whether the other departures and changes are behind More Options.
    private var hasMoreOptions: Bool {
        switch transport {
        case .train: !boardOptions.isEmpty || planned?.trip != nil
        case .bus: planned?.trip != nil
        default: false
        }
    }

    private var vehicle: String { transport == .bus ? "bus" : "train" }
    private var vehicles: String { transport == .bus ? "buses" : "trains" }

    /// Adds the trains or buses after the last one listed.
    private func loadLaterTrains() async {
        guard let stations = planned?.stations, let lastTrip = trips?.last else { return }
        loadingLater = true
        defer { loadingLater = false }
        let there = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
        if transport == .bus {
            guard let here = LocationManager.shared.location,
                  case .trips(let later) = await TransitPlanner.buses(
                    from: board?.location ?? here, to: leave?.location ?? there,
                    leavingAfter: lastTrip.departure.addingTimeInterval(60))
            else { return }
            let known = Set((trips ?? []).map(\.id))
            trips = (trips ?? []) + later.filter { !known.contains($0.id) }
            return
        }
        guard case .trips(let later) = await TransitPlanner.trainsWithPATH(
            board: stations.board.location, leave: stations.leave.location, start: LocationManager.shared.location,
            destination: CLLocation(latitude: destination.latitude, longitude: destination.longitude),
            toDestination: leave == nil, leavingAfter: lastTrip.departure.addingTimeInterval(60))
        else { return }
        let known = Set((trips ?? []).map(\.id))
        trips = (trips ?? []) + later.filter { !known.contains($0.id) }
    }

    private var changeFooter: String {
        if !transfers.isEmpty {
            return "Swipe left to remove a change. Remove them all to go back to the timetable's trains."
        }
        switch planned?.timetable {
        case .found?:
            return "Changes come from the timetable for the train you picked above."
        case .unavailable?:
            return "The train timetable couldn't be reached, so train names and changes aren't shown. Add a change yourself, or check Train Times in Maps."
        case .notFound?:
            return "No trains were found in the timetable between these stations. Try other stations, add a change yourself, or check Train Times in Maps."
        default:
            return ""
        }
    }

    /// The stations to choose from, nearest first, with the one in use checked.
    private func stationChoices(title: String, subtitle: String, options: [MKMapItem], current: MKMapItem?,
                                from origin: CLLocation?, choose: @escaping (MKMapItem) -> Void) -> some View {
        Section {
            ForEach(options.prefix(12), id: \.self) { option in
                Button {
                    choose(option)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(option.name ?? "Station").foregroundStyle(.primary)
                            if let address = option.address?.shortAddress {
                                Text(address).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let origin {
                            Text(Format.distance(option.location.distance(from: origin)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let current, option.location.distance(from: current.location) < 150 {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            }
        } header: {
            Text("\(title) — \(subtitle)")
        } footer: {
            if options.count <= 1 { Text("No other train stations were found.") }
        }
    }

    private func openInMaps() {
        destination.mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: transport.mapsMode])
    }
}

/// Train stations along the way to pick where to change trains.
struct TransferPicker: View {
    let board: MKMapItem
    let leave: MKMapItem
    let chosen: [MKMapItem]
    var onPick: (MKMapItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stations: [MKMapItem]?

    var body: some View {
        NavigationStack {
            List {
                if let stations {
                    if stations.isEmpty {
                        Text("No train stations were found between \(board.name ?? "these stations") and \(leave.name ?? "the last station").")
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        ForEach(stations, id: \.self) { station in
                            let picked = chosen.contains { $0.location.distance(from: station.location) < 150 }
                            Button {
                                onPick(station)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(station.name ?? "Station").foregroundStyle(.primary)
                                        if let address = station.address?.shortAddress {
                                            Text(address).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text("\(Format.distance(station.location.distance(from: board.location))) from start")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if picked { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                            .disabled(picked)
                        }
                    } footer: {
                        if !stations.isEmpty {
                            Text("Stations closest to the straight line from \(board.name ?? "the first station") to \(leave.name ?? "the last station") are listed first.")
                        }
                    }
                } else {
                    HStack { ProgressView(); Text("Finding stations along the way…").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Change Trains At")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { stations = await DirectionsService.transferStations(from: board, to: leave, ride: .train) }
        }
    }
}

/// A way of changing trains, with how soon it gets there.
struct ChangeOptionRow: View {
    let title: String
    let trips: [TransitPlanner.Trip]
    let selected: Bool
    var vehicle = "train"

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let best = TransitPlanner.quickest(trips), let ride = best.rides.last {
                    Text("Gets there first at \(ride.time(best.arrival)) · \(trips.count) \(vehicle)\(trips.count == 1 ? "" : vehicle == "bus" ? "es" : "s") listed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
    }
}

/// A departure: times, number of changes, and the trains.
struct TripRow: View {
    let trip: TransitPlanner.Trip
    let selected: Bool
    var quickest = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                let first = trip.rides[0], last = trip.rides[trip.rides.count - 1]
                HStack {
                    Text("\(first.time(trip.departure)) → \(last.time(trip.arrival))")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if quickest {
                        Text("Quickest")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.2), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(trip.rides.map(\.title).joined(separator: " → "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(Format.time(trip.duration)) · "
                     + (trip.changes == 0 ? "direct" : "change at \(trip.changeSummary)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
    }
}

struct StepRow: View {
    let number: Int
    let text: String
    /// Apple Maps directions for this stretch, if it has one.
    var link: StepLink? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(.tint.opacity(0.15), in: Circle())
            Text(text)
            if let link {
                Spacer()
                Button("Open in Maps", systemImage: link.mode == MKLaunchOptionsDirectionsModeTransit ? "tram.circle" : "map.circle") {
                    link.open()
                }
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.borderless)
            }
        }
    }
}

/// Saves the directions to the public repository.
struct SaveDirectionsSheet: View {
    let destination: Destination
    let transport: Transport
    let planned: PlannedRoute?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("displayName") private var displayName = ""
    @State private var title = ""
    @State private var note = ""
    @State private var includeSteps = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Note (optional)", text: $note, axis: .vertical)
                } footer: {
                    Text("To \(destination.name) by \(transport.title.lowercased())")
                }
                Section {
                    Toggle("Include the step-by-step directions", isOn: $includeSteps)
                } footer: {
                    Text("The steps start from where you are now, so they show roughly where you started. Turn this off to share only the destination.")
                }
                Section {
                    TextField("Your name (shown with it)", text: $displayName)
                } footer: {
                    Text(RepositoryInfo.publicNote)
                }
            }
            .navigationTitle("Save Directions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                                      || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .alert("Couldn’t Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") {}
            } message: {
                Text(error ?? "")
            }
            .onAppear { if title.isEmpty { title = "Directions to \(destination.name)" } }
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let directions = SavedDirections(
            id: UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespaces),
            destinationName: destination.name,
            address: destination.address,
            latitude: destination.latitude,
            longitude: destination.longitude,
            transport: transport,
            steps: includeSteps ? planned?.steps ?? [] : [],
            distance: includeSteps ? planned?.distance ?? 0 : 0,
            travelTime: includeSteps ? planned?.travelTime ?? 0 : 0,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            authorName: displayName.trimmingCharacters(in: .whitespaces),
            authorID: nil,
            createdAt: Date())
        do {
            try await Repository.shared.save(directions)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
