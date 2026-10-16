import MapKit
import SwiftUI

/// Type a place, business, or address and get directions there.
struct TextDirectionsView: View {
    @State private var completer = SearchCompleter()
    @State private var text = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var error: String?
    @State private var destination: Destination?

    var body: some View {
        NavigationStack {
            List {
                if searching {
                    HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results, id: \.self) { item in
                            Button { destination = Destination(item) } label: { MapItemRow(item: item) }
                        }
                    }
                } else if !completer.results.isEmpty {
                    Section("Suggestions") {
                        ForEach(completer.results, id: \.self) { suggestion in
                            Button {
                                Task { await pick(suggestion) }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(suggestion.title).foregroundStyle(.primary)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if text.isEmpty && results.isEmpty {
                    ContentUnavailableView("Where to?", systemImage: "text.magnifyingglass",
                                           description: Text("Type a place, business, or address to get directions from where you are."))
                }
            }
            .navigationTitle("Text Directions")
            .toolbar { ToolbarItem(placement: .topBarLeading) { HelpButton(topic: .text) } }
            .searchable(text: $text, prompt: "Place, business, or address")
            .onChange(of: text) {
                results = []
                error = nil
                completer.update(text, near: LocationManager.shared.location)
            }
            .onSubmit(of: .search) { Task { await searchAll() } }
            .navigationDestination(item: $destination) { RouteView(destination: $0) }
        }
    }

    private func pick(_ suggestion: MKLocalSearchCompletion) async {
        await run {
            let items = try await DirectionsService.search(suggestion)
            if items.count == 1, let item = items.first {
                destination = Destination(item)
            } else {
                results = items
            }
        }
    }

    private func searchAll() async {
        await run {
            results = try await DirectionsService.search(text, near: LocationManager.shared.location)
            if results.isEmpty { error = "Nothing found for “\(text)”." }
        }
    }

    private func run(_ work: () async throws -> Void) async {
        searching = true
        error = nil
        defer { searching = false }
        do { try await work() } catch { self.error = "Nothing found. Check the spelling or try a nearby city." }
    }
}
