import MapKit
import UIKit
import SwiftUI

/// The person's location on the map, with the floor when indoors.
struct MapTabView: View {
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    private var location: LocationManager { .shared }

    var body: some View {
        Map(position: $position) {
            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .all))
        .overlay(alignment: .bottomLeading) {
            HelpButton(topic: .map)
                .labelStyle(.iconOnly)
                .font(.title2)
                .padding(10)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding()
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapPitchToggle()
            MapScaleView()
        }
        .safeAreaInset(edge: .top) {
            if location.isDenied {
                VStack(spacing: 6) {
                    Label("Location is off", systemImage: "location.slash").font(.headline)
                    Text("Allow location access to see where you are and get directions from here.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
            } else if let here = location.location {
                HStack(spacing: 12) {
                    if let floor = location.floorLevel {
                        Label("Floor \(floor)", systemImage: "building.2")
                    }
                    Label("±\(Format.distance(here.horizontalAccuracy))", systemImage: "scope")
                }
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 4)
            }
        }
    }
}
