import SwiftUI
import UIKit

/// Routes inside buildings: record one by walking it, or follow one.
struct IndoorView: View {
    @State private var library = IndoorLibrary.shared
    @State private var recording = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        recording = true
                    } label: {
                        Label("Record a Route", systemImage: "record.circle")
                            .font(.headline)
                    }
                } footer: {
                    Text("Walk from a starting point, like the main entrance, to the destination. The app notes your steps, turns, and floor changes. Add photos of landmarks so others can follow it.")
                }

                Section {
                    if library.routes.isEmpty {
                        Text("Routes you record appear here.").foregroundStyle(.secondary)
                    }
                    ForEach(library.routes) { route in
                        NavigationLink(value: route) { IndoorRouteRow(route: route) }
                    }
                    .onDelete { library.delete(at: $0) }
                } header: {
                    Text("On This iPhone")
                } footer: {
                    Text("Routes others have shared are in the Repository tab, under Indoor.")
                }
            }
            .navigationTitle("Indoor")
            .toolbar { ToolbarItem(placement: .topBarLeading) { HelpButton(topic: .indoor) } }
            .navigationDestination(for: IndoorRoute.self) { IndoorFollowView(route: $0, fromRepository: false) }
            .fullScreenCover(isPresented: $recording) { IndoorRecordView() }
        }
    }
}

struct IndoorRouteRow: View {
    let route: IndoorRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(route.title).font(.headline)
            Text("\(route.building) · \(route.startPoint) → \(route.destination)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("\(route.steps.count) steps · \(Format.distance(route.totalDistance))")
                if route.publishedID != nil { Label("Shared", systemImage: "icloud") }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

struct IndoorStepRow: View {
    let step: IndoorStep
    var highlighted = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: step.systemImage)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(highlighted ? Color.white : Color.accentColor)
                .padding(4)
                .background(highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text(step.title).fontWeight(highlighted ? .semibold : .regular)
                if let detail = step.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let data = step.photo, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Record

struct IndoorRecordView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("displayName") private var displayName = ""
    @State private var recorder = IndoorRecorder()
    @State private var building = ""
    @State private var startPoint = "Main entrance"
    @State private var destination = ""
    @State private var title = ""
    @State private var finished = false
    @State private var editing: IndoorStep?
    @State private var addingLandmark = false
    @State private var confirmCancel = false

    private var location: LocationManager { .shared }

    var body: some View {
        NavigationStack {
            List {
                if !recorder.isRecording && !finished {
                    setup
                } else if recorder.isRecording {
                    live
                } else {
                    Section {
                        TextField("Title", text: $title)
                    } header: {
                        Text("Name this route")
                    } footer: {
                        Text("Tap a step to fix it, add a note, or attach a photo. Swipe to delete, or drag to reorder.")
                    }
                }

                if !recorder.steps.isEmpty {
                    Section("Steps") {
                        ForEach(recorder.steps) { step in
                            Button { editing = step } label: { IndoorStepRow(step: step) }
                                .foregroundStyle(.primary)
                        }
                        .onDelete { recorder.delete(at: $0) }
                        .onMove { recorder.move(from: $0, to: $1) }
                    }
                }
            }
            .navigationTitle(finished ? "Finish Route" : recorder.isRecording ? "Recording…" : "Record a Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if recorder.steps.isEmpty { recorder.stop(); dismiss() } else { confirmCancel = true }
                    }
                }
                if finished {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || recorder.steps.isEmpty)
                    }
                }
            }
            .confirmationDialog("Discard this route?", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Discard Route", role: .destructive) { recorder.stop(); dismiss() }
            }
            .sheet(item: $editing) { step in
                StepEditor(step: step) { recorder.replace($0) }
            }
            .sheet(isPresented: $addingLandmark) {
                StepEditor(step: IndoorStep(kind: .landmark)) { recorder.add($0) }
            }
            .onDisappear { recorder.stop() }
        }
    }

    private var setup: some View {
        Section {
            TextField("Building (e.g. City Hospital)", text: $building)
            TextField("Starting point", text: $startPoint)
            TextField("Destination (e.g. Room 312)", text: $destination)
            Button {
                recorder.start()
            } label: {
                Label("Start Recording", systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled([building, startPoint, destination].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        } footer: {
            Text("Stand at the starting point, then tap Start. Hold the phone flat in front of you and walk normally. "
                 + (recorder.canCountSteps ? "" : "This device can’t count steps, so add each step with the buttons below."))
        }
    }

    private var live: some View {
        Group {
            Section {
                VStack(spacing: 8) {
                    Text(recorder.canCountSteps ? Format.distance(recorder.walkedInSegment) : "—")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("walked since the last step").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        if let heading = location.heading {
                            Label("\(Compass.name(heading)) \(Int(heading))°", systemImage: "location.north.line")
                        }
                        if let floor = location.floorLevel {
                            Label("Floor \(floor)", systemImage: "building.2")
                        }
                    }
                    .font(.caption.bold())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
                    addButton("Left", "arrow.turn.up.left") { recorder.add(IndoorStep(kind: .left)) }
                    addButton("Right", "arrow.turn.up.right") { recorder.add(IndoorStep(kind: .right)) }
                    addButton("Around", "arrow.uturn.down") { recorder.add(IndoorStep(kind: .turnAround)) }
                    addButton("Up Floor", "arrow.up.square") { recorder.add(IndoorStep(kind: .up, floors: 1)) }
                    addButton("Down Floor", "arrow.down.square") { recorder.add(IndoorStep(kind: .down, floors: 1)) }
                    addButton("Landmark", "camera") { addingLandmark = true }
                }
                .buttonStyle(.bordered)
                Button {
                    recorder.finish()
                    finished = true
                    if title.isEmpty { title = "\(startPoint) to \(destination)" }
                } label: {
                    Label("I’ve Arrived", systemImage: "flag.checkered")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } footer: {
                Text("Turns and floor changes are noticed automatically; use these buttons for any that are missed. Landmark adds a note and photo, like “Through the double doors.”")
            }
        }
    }

    private func addButton(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private func save() {
        let route = IndoorRoute(
            id: UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespaces),
            building: building.trimmingCharacters(in: .whitespaces),
            startPoint: startPoint.trimmingCharacters(in: .whitespaces),
            destination: destination.trimmingCharacters(in: .whitespaces),
            steps: recorder.steps,
            authorName: displayName,
            authorID: nil,
            createdAt: Date(),
            latitude: recorder.latitude,
            longitude: recorder.longitude)
        IndoorLibrary.shared.add(route)
        dismiss()
    }
}

/// Edits one step: its kind, distance or floors, note, and photo.
struct StepEditor: View {
    @State var step: IndoorStep
    var onSave: (IndoorStep) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var meters = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Step", selection: $step.kind) {
                        ForEach(IndoorStep.Kind.allCases, id: \.self) { kind in
                            Text(IndoorStep(kind: kind, floors: 1).title.replacingOccurrences(of: "Landmark", with: "Landmark / note"))
                                .tag(kind)
                        }
                    }
                    if step.kind == .walk {
                        TextField("Distance in meters", text: $meters)
                            .keyboardType(.numberPad)
                    }
                    if step.kind == .up || step.kind == .down {
                        Stepper("Floors: \(step.floors ?? 1)", value: Binding(get: { step.floors ?? 1 }, set: { step.floors = $0 }), in: 1...100)
                    }
                    TextField(step.kind == .landmark ? "What’s here (e.g. Through the double doors)" : "Note (optional)",
                              text: $step.note, axis: .vertical)
                }
                Section("Photo") {
                    if let data = step.photo, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                        Button("Remove Photo", role: .destructive) { step.photo = nil }
                    }
                    PhotoSourceButtons { image, _ in step.photo = ImageTools.jpeg(image) }
                }
            }
            .navigationTitle(step.kind == .landmark && step.note.isEmpty ? "Add Landmark" : "Edit Step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if step.kind == .walk { step.distance = Double(meters) ?? step.distance }
                        onSave(step)
                        dismiss()
                    }
                }
            }
            .onAppear { meters = step.distance.map { String(Int($0)) } ?? "" }
        }
    }
}

// MARK: - Follow

/// Step-by-step guidance along a route, with a compass arrow and the
/// distance left on each walk.
struct IndoorFollowView: View {
    @State var route: IndoorRoute
    let fromRepository: Bool

    @State private var follower = IndoorFollower()
    @State private var current = 0
    @State private var publishing = false
    private var location: LocationManager { .shared }

    var body: some View {
        List {
            Section {
                LabeledContent("Building", value: route.building)
                LabeledContent("Start at", value: route.startPoint)
                LabeledContent("Go to", value: route.destination)
                LabeledContent("Walking", value: Format.distance(route.totalDistance))
                if fromRepository { LabeledContent("Shared by", value: route.authorName) }
            }

            if route.steps.indices.contains(current) {
                Section("Now") { currentCard(route.steps[current]) }
            }

            Section("All Steps") {
                ForEach(Array(route.steps.enumerated()), id: \.element.id) { index, step in
                    Button {
                        go(to: index)
                    } label: {
                        IndoorStepRow(step: step, highlighted: index == current)
                    }
                    .foregroundStyle(index < current ? .secondary : .primary)
                }
            }
        }
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if fromRepository {
                    RepositoryMenu(item: route)
                } else if route.publishedID == nil {
                    Button("Share to Repository", systemImage: "icloud.and.arrow.up") { publishing = true }
                }
            }
        }
        .sheet(isPresented: $publishing) {
            PublishRouteSheet(route: route) { route = $0 }
        }
        .onAppear { follower.start(); follower.resetStep() }
        .onDisappear { follower.stop() }
        .onChange(of: follower.walked) {
            // A walk is done at 90% of its distance, to allow for stride differences.
            let step = route.steps[current]
            if step.kind == .walk, let distance = step.distance, follower.walked >= distance * 0.9 {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                go(to: current + 1)
            }
        }
    }

    private func currentCard(_ step: IndoorStep) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: step.systemImage)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(step.title).font(.title3.bold())
                    if let detail = step.detail { Text(detail).foregroundStyle(.secondary) }
                }
                Spacer()
                if step.kind == .walk, let target = step.heading, let heading = location.heading {
                    Image(systemName: "location.north.fill")
                        .font(.title)
                        .rotationEffect(.degrees(Compass.turn(from: heading, to: target)))
                        .foregroundStyle(abs(Compass.turn(from: heading, to: target)) < 30 ? .green : .orange)
                        .animation(.easeOut, value: heading)
                }
            }
            if step.kind == .walk, let distance = step.distance, follower.canCountSteps {
                ProgressView(value: min(follower.walked, distance), total: distance) {
                    Text("\(Format.distance(max(0, distance - follower.walked))) to go")
                        .font(.caption)
                }
            }
            if let data = step.photo, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Button("Back", systemImage: "chevron.left") { go(to: current - 1) }
                    .disabled(current == 0)
                Spacer()
                Button(step.kind == .arrive ? "Done" : "Next") { go(to: current + 1) }
                    .buttonStyle(.borderedProminent)
                    .disabled(current >= route.steps.count - 1)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
    }

    private func go(to index: Int) {
        guard route.steps.indices.contains(index) else { return }
        current = index
        follower.resetStep()
    }
}

/// Shares a recorded route to the public repository.
struct PublishRouteSheet: View {
    let route: IndoorRoute
    var onPublished: (IndoorRoute) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("displayName") private var displayName = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    IndoorRouteRow(route: route)
                }
                Section {
                    TextField("Your name (shown with it)", text: $displayName)
                } footer: {
                    Text(RepositoryInfo.publicNote + " Photos of landmarks are shared with the route, so check they don’t show people’s faces or private information.")
                }
            }
            .navigationTitle("Share Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Share") { Task { await publish() } }
                            .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .alert("Couldn’t Share", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") {}
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func publish() async {
        busy = true
        defer { busy = false }
        var shared = route
        shared.authorName = displayName.trimmingCharacters(in: .whitespaces)
        do {
            shared.publishedID = try await Repository.shared.save(shared)
            IndoorLibrary.shared.update(shared)
            onPublished(shared)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
