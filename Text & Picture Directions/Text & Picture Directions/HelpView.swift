import SwiftUI

/// How to use the app. Shown the first time the app opens, and from the
/// question-mark button on every tab, with that tab's section first.
struct HelpView: View {
    enum Topic: String, CaseIterable, Identifiable {
        case start, map, text, picture, directions, indoor, repository
        var id: String { rawValue }
    }

    var topic: Topic = .start
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Opened from a tab: that tab's section comes first, then the rest.
                section(topic)
                ForEach(Topic.allCases.filter { $0 != topic }) { section($0) }
                privacy
            }
            .navigationTitle("How to Use")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder private func section(_ topic: Topic) -> some View {
        switch topic {
        case .start: start
        case .map: map
        case .text: text
        case .picture: picture
        case .directions: directions
        case .indoor: indoor
        case .repository: repository
        }
    }

    private var start: some View {
        Section {
            point("location", "Directions start from where you are, so allow Location “While Using the App”. Camera and Motion & Fitness are asked for when you first take a picture or record an indoor route.")
            point("map", "**Map** shows where you are.")
            point("text.magnifyingglass", "**Text** finds a place you type.")
            point("camera.viewfinder", "**Picture** finds a place from a photo of a sign, flyer, or address.")
            point("figure.walk.motion", "**Indoor** records and follows routes inside buildings.")
            point("icloud", "**Repository** has directions and indoor routes people have shared.")
            point("questionmark.circle", "Tap the question mark on any tab to come back here.")
        } header: {
            Text("Getting Started")
        }
    }

    private var map: some View {
        Section {
            point("location.fill", "The blue dot is you. The bubble at the top shows how accurate your location is, and the floor when a building provides it.")
            point("location.north.line", "Use the buttons on the map to go back to your location, turn the map north, or tilt it to 3D.")
        } header: {
            Text("Map")
        }
    }

    private var text: some View {
        Section {
            numbered(1, "Type a place, business, or address in the search box.")
            numbered(2, "Tap a suggestion. Places near you are listed first.")
            numbered(3, "Pick how to travel: Walk, Drive, Bus, or Train.")
        } header: {
            Text("Text")
        }
    }

    private var picture: some View {
        Group {
            Section {
                numbered(1, "Tap **Take Photo** or **Choose Photo**.")
                numbered(2, "The app reads the words in the picture. Under **Found in the picture**, addresses are listed first, then the largest words. Tap the one you want to go to.")
                numbered(3, "Tap a place under **Places** to get directions.")
            } header: {
                Text("Picture")
            }

            Section {
                point("camera.fill", "**Camera pictures know where they were taken.** The app uses where you were standing and which way the phone faced, so even a picture with no words, like a playground or a building, works: tap a place under **Where the picture was taken**.")
                point("photo.on.rectangle", "Photos taken earlier with the iPhone Camera usually keep where they were taken too, when Location was on for the Camera.")
                point("globe", "**Internet pictures, screenshots, and pictures sent to you have no location.** They must contain words: an address, a business name, or a sign. With no words, there is nothing to find.")
            } header: {
                Text("Camera or Internet Pictures")
            }

            Section {
                FlyerExample()
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                point("checkmark.circle.fill", "This part of a flyer works well: the app finds the address **201 N 17th Street, Philadelphia, PA 19103** and lists it first.", tint: .green)
            } header: {
                Text("A Good Internet Picture")
            }

            Section {
                point("xmark.circle.fill", "A picture with no words, like a street scene from a website.", tint: .red)
                point("xmark.circle.fill", "Words that are tiny or blurry. Small internet pictures often are: zoom in on the words and take a screenshot of just that part.", tint: .red)
                point("exclamationmark.triangle.fill", "Only a name, like “Sheraton”. Many places have that name, so type the city in **City or area** before you search.", tint: .orange)
            } header: {
                Text("Pictures That Don’t Work")
            }

            Section {
                point("camera.viewfinder", "**Take a screenshot.** Find the place’s website, a flyer, an email, a ticket, or a listing that shows its name and address. Press the side button and volume up together, then tap **Choose Photo** and pick the screenshot.")
                point("crop", "Crop the screenshot to the name and address so they’re large and easy to read.")
            } header: {
                Text("Can’t Find a Picture With Words?")
            }
        }
    }

    private var directions: some View {
        Section {
            point("figure.walk", "**Walk** and **Drive** give turn-by-turn steps.")
            point("bus", "**Bus** uses real bus timetables: which bus, when it comes, where to get on and off, and where to change. The stops are picked for the shortest walk, not just the nearest one.")
            point("tram.fill", "**Train** uses real timetables and shows the most direct trip: which train, when it leaves, and where to change. If the station is far, you drive there and the car stays at that station, so a long last stretch is a taxi or rideshare.")
            point("list.bullet", "Tap **More Options** to pick another place to change or a later bus or train, or, for trains, other stations.")
            point("map.circle", "The blue button next to a step opens that part of the trip in Apple Maps.")
            point("icloud.and.arrow.up", "The cloud button saves the directions to the Repository, with or without the steps.")
        } header: {
            Text("Directions")
        }
    }

    private var indoor: some View {
        Section {
            point("record.circle", "**Record a Route** while you walk. Distance is counted from your steps; turns, stairs, and elevators are noticed on their own. Use the buttons to add a turn or a landmark with a photo.")
            point("arrow.triangle.turn.up.right.diamond", "Open a saved route to follow it. Each step moves on as you walk, and the arrow points the way.")
            point("square.and.arrow.up", "Share a route to the Repository so others can follow it.")
        } header: {
            Text("Indoor")
        }
    }

    private var repository: some View {
        Section {
            point("globe", "Everything here is public. Switch between Directions and Indoor, and between Everyone and Mine.")
            point("ellipsis.circle", "Use the ⋯ menu to delete what you saved, report something wrong, or hide a person.")
        } header: {
            Text("Repository")
        }
    }

    private var privacy: some View {
        Section("Privacy") {
            point("iphone", "Words in your pictures are read on this iPhone. Pictures are not uploaded.")
            point("tram", "For train times, the location of the station you start from, the location of the place you’re going, and the time are sent to Transitous, a free timetable service.")
            point("bus", "For bus times, your location rounded to about 100 meters (330 feet), the location of the place you’re going, and the time are sent to Transitous.")
        }
    }

    // MARK: - Rows

    private func point(_ symbol: String, _ text: LocalizedStringKey, tint: Color? = nil) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
        }
    }

    private func numbered(_ number: Int, _ text: LocalizedStringKey) -> some View {
        Label { Text(text) } icon: { Image(systemName: "\(number).circle.fill").foregroundStyle(.tint) }
    }
}

/// A drawing of the convention flyer example, with the address the app finds marked.
private struct FlyerExample: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("ST-PHL: TREK TO PHILADELPHIA 60th CELEBRATION").font(.caption.weight(.black))
            Text("November 14–15, 2026").font(.caption.weight(.heavy))
            VStack(spacing: 2) {
                Text("Sheraton Philadelphia Downtown Hotel").font(.caption.weight(.heavy))
                Text("201 N 17th Street").font(.caption.weight(.heavy))
                Text("Philadelphia, PA 19103").font(.caption.weight(.heavy))
            }
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.green, lineWidth: 2))
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example flyer: Sheraton Philadelphia Downtown Hotel, 201 N 17th Street, Philadelphia, PA 19103")
    }
}

/// The question-mark button that opens How to Use at a tab's section.
struct HelpButton: View {
    var topic: HelpView.Topic
    @State private var showing = false

    var body: some View {
        Button("How to Use", systemImage: "questionmark.circle") { showing = true }
            .sheet(isPresented: $showing) { HelpView(topic: topic) }
    }
}
