import ImageIO
import MapKit
import PhotosUI
import SwiftUI
import UIKit
import Vision

/// Take or choose a picture of a sign, storefront, or written address; the
/// words in it are read on the iPhone and searched to find the destination.
struct PictureDirectionsView: View {
    @State private var image: UIImage?
    @State private var found = FoundText()
    @State private var reading = false
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var error: String?
    @State private var destination: Destination?
    /// Where the picture was taken, from its GPS tags (or the phone, for a new photo).
    @State private var place: PhotoPlace?
    /// What is at that spot: the building or business first, then the street address.
    @State private var placeItems: [MKMapItem] = []
    @State private var locating = false
    /// A city or area typed for a picture with no location.
    @State private var area = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotoSourceButtons { picked($0, place: $1) }
                } footer: {
                    Text("Take or choose a picture of a sign, storefront, business card, or written address.")
                }

                if let image {
                    Section {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 240)
                    }
                }

                if let place {
                    Section {
                        if locating {
                            HStack { ProgressView(); Text("Looking up this spot…").foregroundStyle(.secondary) }
                        }
                        ForEach(placeItems, id: \.self) { item in
                            Button { destination = Destination(item) } label: { MapItemRow(item: item) }
                        }
                        Button {
                            destination = Destination(name: "Where the picture was taken", address: nil,
                                                      latitude: place.location.coordinate.latitude,
                                                      longitude: place.location.coordinate.longitude)
                        } label: {
                            Label(place.summary, systemImage: "location.viewfinder")
                        }
                    } header: {
                        Text("Where the picture was taken")
                    } footer: {
                        Text("Searches below stay close to this spot\(place.heading == nil ? "" : " and favor places in the direction the camera faced").")
                    }
                }

                if reading {
                    HStack { ProgressView(); Text("Reading the picture…").foregroundStyle(.secondary) }
                } else if image != nil {
                    Section {
                        if found.isEmpty {
                            Text("No words were found. Try a closer, straighter picture, or type the destination below.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(found.addresses, id: \.self) { candidate($0, systemImage: "mappin.and.ellipse") }
                        ForEach(found.lines, id: \.self) { candidate($0, systemImage: "text.quote") }
                    } header: {
                        Text("Found in the picture")
                    } footer: {
                        if !found.isEmpty { Text("Tap what you want to go to. Addresses are listed first, then the largest words.") }
                    }

                    Section {
                        TextField("Destination", text: $query)
                            .onSubmit { Task { await search() } }
                        if place == nil {
                            TextField("City or area (optional)", text: $area)
                                .textContentType(.addressCity)
                                .onSubmit { Task { await search() } }
                        }
                        Button("Search", systemImage: "magnifyingglass") { Task { await search() } }
                            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                    } header: {
                        Text("Search")
                    } footer: {
                        if place == nil {
                            Text("This picture has no location. Add the city it is in, or the words are searched together with the other words in the picture, near you and then everywhere.")
                        }
                    }
                }

                if searching {
                    HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if !results.isEmpty {
                    Section("Places") {
                        ForEach(results, id: \.self) { item in
                            Button { destination = Destination(item) } label: { MapItemRow(item: item) }
                        }
                    }
                }
            }
            .navigationTitle("Picture Directions")
            .toolbar { ToolbarItem(placement: .topBarLeading) { HelpButton(topic: .picture) } }
            .navigationDestination(item: $destination) { RouteView(destination: $0) }
        }
    }

    private func candidate(_ text: String, systemImage: String) -> some View {
        Button {
            query = text
            Task { await search() }
        } label: {
            Label(text, systemImage: systemImage)
        }
    }

    private func picked(_ picture: UIImage, place: PhotoPlace?) {
        image = picture
        self.place = place
        placeItems = []
        results = []
        error = nil
        query = ""
        area = ""
        reading = true
        Task {
            found = await TextFinder.find(in: picture)
            query = found.addresses.first ?? found.lines.first ?? ""
            reading = false
        }
        if let place {
            locating = true
            Task {
                placeItems = await DirectionsService.places(at: place)
                locating = false
            }
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        error = nil
        defer { searching = false }
        do {
            if let place {
                results = try await DirectionsService.search(text, around: place)
                if results.isEmpty { error = "No place called “\(text)” was found nearby." }
            } else {
                await searchWithoutLocation(text)
            }
        } catch {
            results = []
            self.error = "No place called “\(text)” was found nearby. Try other words from the picture."
        }
    }
}

extension PictureDirectionsView {
    /// A picture with no GPS could be from anywhere: search the typed area, or
    /// the words together near the person, then everywhere.
    private func searchWithoutLocation(_ text: String) async {
        let others = found.addresses + found.lines
        let areaName = area.trimmingCharacters(in: .whitespaces)
        if !areaName.isEmpty {
            guard let center = await DirectionsService.locate(area: areaName) else {
                results = []
                error = "“\(areaName)” was not found. Check the city or area name."
                return
            }
            results = await DirectionsService.search(text, with: others, near: center).items
            if results.isEmpty { error = "No place called “\(text)” was found in \(areaName)." }
            return
        }
        let here = LocationManager.shared.location
        let nearby = await DirectionsService.search(text, with: others, near: here)
        if nearby.agreed || (here != nil && !nearby.items.isEmpty && others.count < 2) {
            results = nearby.items
            return
        }
        let anywhere = await DirectionsService.search(text, with: others, near: nil)
        if anywhere.agreed || nearby.items.isEmpty {
            results = anywhere.items
        } else {
            results = nearby.items
        }
        if results.isEmpty {
            error = "No place called “\(text)” was found. Add the city the picture is from."
        }
    }
}

/// Where a picture was taken and which way the camera faced.
struct PhotoPlace {
    var location: CLLocation
    /// Degrees from north the camera pointed, when recorded.
    var heading: CLLocationDirection?

    /// "±37 m · facing SE · Oct 15, 11:51 AM"
    var summary: String {
        var parts = [String(format: "%.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude)]
        if location.horizontalAccuracy > 0 { parts.append("±\(Int(location.horizontalAccuracy.rounded())) m") }
        if let heading { parts.append("facing \(Compass.name(heading))") }
        parts.append(location.timestamp.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    /// The GPS tags saved in a photo file, if location was kept.
    static func read(from data: Data) -> PhotoPlace? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              var latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              var longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { latitude = -latitude }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { longitude = -longitude }
        let accuracy = gps[kCGImagePropertyGPSHPositioningError] as? Double ?? 50
        let altitude = gps[kCGImagePropertyGPSAltitude] as? Double ?? 0

        var date = Date()
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        if let original = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String {
                formatter.dateFormat += "xxx"
                date = formatter.date(from: original + offset) ?? date
            } else {
                date = formatter.date(from: original) ?? date
            }
        }

        let location = CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                  altitude: altitude, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                                  timestamp: date)
        return PhotoPlace(location: location, heading: gps[kCGImagePropertyGPSImgDirection] as? Double)
    }

    /// For a photo just taken: where the phone is now and which way it faces.
    static var current: PhotoPlace? {
        guard let location = LocationManager.shared.location else { return nil }
        return PhotoPlace(location: location, heading: LocationManager.shared.heading)
    }
}

/// Words read from a picture.
struct FoundText {
    var addresses: [String] = []
    /// Lines of text, largest (most sign-like) first.
    var lines: [String] = []
    var isEmpty: Bool { addresses.isEmpty && lines.isEmpty }
}

enum TextFinder {
    static func find(in image: UIImage) async -> FoundText {
        guard let cgImage = ImageTools.upright(image, maxDimension: 2000).cgImage else { return FoundText() }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: cgImage) else { return FoundText() }

        let sized = observations.compactMap { observation -> (text: String, height: Double)? in
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                  text.count(where: \.isLetter) >= 2 else { return nil }
            return (text, Double(observation.boundingBox.height))
        }
        let allText = sized.map(\.text).joined(separator: "\n")

        var found = FoundText()
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue) {
            let range = NSRange(allText.startIndex..., in: allText)
            found.addresses = detector.matches(in: allText, range: range).compactMap {
                Range($0.range, in: allText).map { allText[$0].replacingOccurrences(of: "\n", with: ", ") }
            }
        }
        var seen = Set(found.addresses.map { $0.lowercased() })
        for item in sized.sorted(by: { $0.height > $1.height }) where seen.insert(item.text.lowercased()).inserted {
            found.lines.append(item.text)
            if found.lines.count == 12 { break }
        }
        return found
    }
}

enum ImageTools {
    /// Redraws the picture the right way up, no larger than `maxDimension`.
    static func upright(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// A small JPEG for saving with an indoor route.
    static func jpeg(_ image: UIImage) -> Data? {
        upright(image, maxDimension: 1200).jpegData(compressionQuality: 0.6)
    }
}

/// "Take Photo" and "Choose Photo" buttons.
struct PhotoSourceButtons: View {
    /// The picture, and where it was taken when that is known.
    var onImage: (UIImage, PhotoPlace?) -> Void

    @State private var item: PhotosPickerItem?
    @State private var showCamera = false

    var body: some View {
        HStack {
            Button {
                showCamera = true
            } label: {
                Label("Take Photo", systemImage: "camera")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!CameraPicker.isAvailable)
            PhotosPicker(selection: $item, matching: .images) {
                Label("Choose Photo", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { onImage($0, PhotoPlace.current) }.ignoresSafeArea()
                .onAppear { LocationManager.shared.startHeading() }
                .onDisappear { LocationManager.shared.stopHeading() }
        }
        .onChange(of: item) {
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    onImage(image, PhotoPlace.read(from: data))
                }
                self.item = nil
            }
        }
    }
}

/// The system camera.
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
