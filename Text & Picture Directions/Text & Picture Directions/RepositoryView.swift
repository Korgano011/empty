import SwiftUI

/// Browse the public repository: saved directions and indoor routes.
struct RepositoryView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case directions = "Directions", indoor = "Indoor"
        var id: String { rawValue }
    }

    @State private var repository = Repository.shared
    @State private var kind = Kind.directions
    @State private var mine = false
    @State private var directions: [SavedDirections] = []
    @State private var routes: [IndoorRoute] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var showAbout = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                if kind == .directions {
                    ForEach(filteredDirections) { item in
                        NavigationLink(value: item) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.headline)
                                Text(item.address ?? item.destinationName).font(.caption).foregroundStyle(.secondary)
                                Label("\(item.transport.title) · \(item.authorName) · \(item.createdAt.formatted(date: .abbreviated, time: .omitted))",
                                      systemImage: item.transport.systemImage)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions { deleteButton(item) }
                    }
                } else {
                    ForEach(filteredRoutes) { route in
                        NavigationLink(value: route) {
                            VStack(alignment: .leading, spacing: 3) {
                                IndoorRouteRow(route: route)
                                Text("Shared by \(route.authorName)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions { deleteButton(route) }
                    }
                }
            }
            .overlay {
                if loading && isEmpty {
                    ProgressView()
                } else if isEmpty {
                    ContentUnavailableView {
                        Label(mine ? "Nothing Saved Yet" : "Nothing Here Yet", systemImage: "icloud")
                    } description: {
                        Text(error ?? emptyMessage)
                    } actions: {
                        Button("Refresh") { Task { await load() } }
                    }
                }
            }
            .searchable(text: $search, prompt: kind == .directions ? "Search places" : "Search buildings and rooms")
            .safeAreaInset(edge: .top) {
                VStack(spacing: 6) {
                    if repository.isLocal {
                        Label("Test mode — saved on this iPhone only", systemImage: "testtube.2")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(.orange.opacity(0.2))
                    }
                    Picker("Kind", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    Picker("Show", selection: $mine) {
                        Text("Everyone").tag(false)
                        Text("Mine").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                }
                .background(.bar)
            }
            .navigationTitle("Repository")
            .navigationDestination(for: SavedDirections.self) { RouteView(destination: $0.destination, saved: $0) }
            .navigationDestination(for: IndoorRoute.self) { IndoorFollowView(route: $0, fromRepository: true) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("Local Test Mode", isOn: Binding(get: { repository.isLocal }, set: { repository.testMode = $0 }))
                            .disabled(!Repository.cloudEnabled)
                        Button("Clear Test Data", systemImage: "trash", role: .destructive) { confirmClear = true }
                        if !repository.hiddenAuthors.isEmpty {
                            Button("Show Hidden People Again", systemImage: "eye") { repository.unhideAll() }
                        }
                    } label: {
                        Image(systemName: "testtube.2")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("About the Repository", systemImage: "info.circle") { showAbout = true }
                }
                ToolbarItem(placement: .primaryAction) { HelpButton(topic: .repository) }
            }
            .confirmationDialog("Delete everything saved in test mode on this iPhone?",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Test Data", role: .destructive) { repository.clearTestData() }
            }
            .sheet(isPresented: $showAbout) { RepositoryAboutView() }
            .refreshable { await load() }
            .task(id: "\(kind)\(mine)\(repository.changes)") { await load() }
        }
    }

    private var isEmpty: Bool { kind == .directions ? filteredDirections.isEmpty : filteredRoutes.isEmpty }

    private var emptyMessage: String {
        kind == .directions
            ? "Get directions in the Text or Picture tab, then tap Save to Repository."
            : "Record a route in the Indoor tab, then tap Share to Repository."
    }

    private var term: String { search.trimmingCharacters(in: .whitespaces) }

    private var filteredDirections: [SavedDirections] {
        guard !term.isEmpty else { return directions }
        return directions.filter {
            [$0.title, $0.destinationName, $0.address ?? "", $0.note].contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    private var filteredRoutes: [IndoorRoute] {
        guard !term.isEmpty else { return routes }
        return routes.filter {
            [$0.title, $0.building, $0.startPoint, $0.destination].contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    @ViewBuilder
    private func deleteButton<Item: RepositoryItem>(_ item: Item) -> some View {
        if repository.isMine(item.authorID) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task {
                    do { try await repository.delete(item) } catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            if kind == .directions {
                directions = try await repository.directions(mine: mine)
            } else {
                routes = try await repository.indoorRoutes(mine: mine)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Delete (own), Report, and Hide for something in the repository.
struct RepositoryMenu<Item: RepositoryItem>: View {
    let item: Item

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var reporting = false
    @State private var message: String?

    private var repository: Repository { .shared }

    var body: some View {
        Menu {
            if repository.isMine(item.authorID) {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } else {
                Button("Report…", systemImage: "flag") { reporting = true }
                Button("Hide Everything from \(item.authorName)", systemImage: "eye.slash") {
                    repository.hide(author: item.authorID)
                    dismiss()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .confirmationDialog("Delete “\(item.title)” from the repository for everyone?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await repository.delete(item)
                        dismiss()
                    } catch {
                        message = error.localizedDescription
                    }
                }
            }
        }
        .confirmationDialog("Why are you reporting this?", isPresented: $reporting, titleVisibility: .visible) {
            ForEach(["Wrong or dangerous directions", "Offensive or abusive", "Private information or faces in photos", "Spam"], id: \.self) { reason in
                Button(reason) {
                    Task {
                        do {
                            try await repository.report(item, reason: reason)
                            message = "Thanks. It will be reviewed within 24 hours."
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                }
            }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        }
    }
}

struct RepositoryAboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                point("globe", "The repository is public. Directions and indoor routes saved to it can be seen by anyone using the app.")
                point("icloud", "It’s stored in the app’s public database on Apple iCloud. Saving needs an iCloud account; browsing works for everyone.")
                point("figure.walk", "Saved directions can include the step-by-step route from where you were when you saved them. Turn that off when saving to share only the destination.")
                point("camera", "Indoor routes include any landmark photos you took. Avoid photos of people’s faces or private information.")
                point("trash", "You can delete anything you saved at any time: swipe left on it, or ⋯ → Delete.")
                point("flag", "Report anything wrong, dangerous, or offensive from its ⋯ menu, or hide everything from a person. Reports are reviewed within 24 hours.")
            }
            .navigationTitle("About the Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(.tint) }
    }
}
