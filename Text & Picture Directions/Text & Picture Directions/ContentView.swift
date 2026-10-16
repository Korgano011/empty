import SwiftUI

struct ContentView: View {
    @AppStorage("shownHowToUse") private var shownHowToUse = false
    @State private var showHowToUse = false

    var body: some View {
        TabView {
            Tab("Map", systemImage: "map") { MapTabView() }
            Tab("Text", systemImage: "text.magnifyingglass") { TextDirectionsView() }
            Tab("Picture", systemImage: "camera.viewfinder") { PictureDirectionsView() }
            Tab("Indoor", systemImage: "figure.walk.motion") { IndoorView() }
            Tab("Repository", systemImage: "icloud") { RepositoryView() }
        }
        .onAppear {
            LocationManager.shared.start()
            if !shownHowToUse {
                shownHowToUse = true
                showHowToUse = true
            }
        }
        .sheet(isPresented: $showHowToUse) { HelpView() }
        #if DEBUG
        // For testing from the Mac: DEBUG_ROUTE="latitude,longitude,Name" opens directions there.
        .fullScreenCover(item: .constant(Self.debugRoute)) { destination in
            NavigationStack {
                if LocationManager.shared.location != nil { RouteView(destination: destination) } else { ProgressView() }
            }
        }
        #endif
    }
}

#if DEBUG
extension ContentView {
    static let debugRoute: Destination? = {
        guard let text = ProcessInfo.processInfo.environment["DEBUG_ROUTE"] else { return nil }
        let parts = text.split(separator: ",", maxSplits: 2).map(String.init)
        guard parts.count == 3, let latitude = Double(parts[0]), let longitude = Double(parts[1]) else { return nil }
        return Destination(name: parts[2], address: nil, latitude: latitude, longitude: longitude)
    }()
}

extension Destination: Identifiable {
    public var id: String { "\(latitude),\(longitude)" }
}
#endif

#Preview {
    ContentView()
}
