import CloudKit
import Foundation
import Observation

/// Directions someone saved to the repository.
struct SavedDirections: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var destinationName: String
    var address: String?
    var latitude: Double
    var longitude: Double
    var transport: Transport
    /// Step-by-step directions from where the saver was; empty if they
    /// shared only the destination.
    var steps: [String]
    var distance: Double
    var travelTime: Double
    var note: String
    var authorName: String
    var authorID: String?
    var createdAt: Date

    var destination: Destination {
        Destination(name: destinationName, address: address, latitude: latitude, longitude: longitude)
    }
}

/// Something in the repository that can be reported, hidden, or deleted.
protocol RepositoryItem {
    static var recordType: String { get }
    var id: String { get }
    var title: String { get }
    var authorID: String? { get }
    var authorName: String { get }
}

extension SavedDirections: RepositoryItem { static let recordType = "Directions" }
extension IndoorRoute: RepositoryItem { static let recordType = "IndoorRoute" }

enum RepositoryInfo {
    static let publicNote = "Saved to the public repository on Apple iCloud: anyone using the app can see it. You can delete it at any time."
}

enum RepositoryError: LocalizedError {
    case noAccount, notYours

    var errorDescription: String? {
        switch self {
        case .noAccount: "Sign in to iCloud in Settings to use the repository."
        case .notYours: "Only the person who saved this can delete it."
        }
    }
}

/// The public repository of saved directions and indoor routes, in the
/// app's CloudKit public database. In test mode everything is kept in a
/// file on this iPhone instead, so the app can be tried without iCloud.
@Observable
final class Repository {
    static let shared = Repository()

    /// False until the iCloud capability and container are set up; the
    /// app then stays in test mode.
    static let cloudEnabled = true

    /// Bumped on every change, so lists know to reload.
    private(set) var changes = 0
    var testMode: Bool {
        didSet { UserDefaults.standard.set(testMode, forKey: "repositoryTestMode"); changes += 1 }
    }
    private(set) var hiddenAuthors: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenAuthors), forKey: "hiddenAuthors") }
    }
    private(set) var myID: String?

    var isLocal: Bool { !Self.cloudEnabled || testMode }

    @ObservationIgnored private lazy var database = CKContainer.default().publicCloudDatabase
    @ObservationIgnored private let localURL = URL.applicationSupportDirectory.appending(path: "RepositoryTest.json")
    private static let localAuthorID = "local-tester"

    init() {
        testMode = UserDefaults.standard.bool(forKey: "repositoryTestMode")
        hiddenAuthors = Set(UserDefaults.standard.stringArray(forKey: "hiddenAuthors") ?? [])
    }

    // MARK: Reading

    func directions(mine: Bool) async throws -> [SavedDirections] {
        if isLocal { return visible(local.directions, mine: mine) }
        return visible(try await records(SavedDirections.recordType, mine: mine).map(SavedDirections.init), mine: mine)
    }

    func indoorRoutes(mine: Bool) async throws -> [IndoorRoute] {
        if isLocal { return visible(local.routes, mine: mine) }
        return visible(try await records(IndoorRoute.recordType, mine: mine).map(IndoorRoute.init), mine: mine)
    }

    func isMine(_ authorID: String?) -> Bool {
        guard let authorID else { return false }
        if isLocal { return authorID == Self.localAuthorID }
        return authorID == CKCurrentUserDefaultName || authorID == myID
    }

    private func visible<Item: RepositoryItem>(_ items: [Item], mine: Bool) -> [Item] {
        items.filter { mine ? isMine($0.authorID) : !hiddenAuthors.contains($0.authorID ?? "") }
    }

    private func records(_ type: String, mine: Bool) async throws -> [CKRecord] {
        try await checkAccount()
        let me = try await userID()
        let predicate = mine
            ? NSPredicate(format: "creatorUserRecordID == %@", CKRecord.ID(recordName: me))
            : NSPredicate(value: true)
        let query = CKQuery(recordType: type, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        do {
            let (results, _) = try await database.records(matching: query, resultsLimit: 200)
            return results.compactMap { try? $0.1.get() }
        } catch let error as CKError where error.code == .unknownItem {
            return []   // nothing of this type saved yet
        }
    }

    private func checkAccount() async throws {
        guard try await CKContainer.default().accountStatus() == .available else { throw RepositoryError.noAccount }
    }

    private func userID() async throws -> String {
        if let myID { return myID }
        let id = try await CKContainer.default().userRecordID().recordName
        myID = id
        return id
    }

    // MARK: Writing

    func save(_ directions: SavedDirections) async throws {
        if isLocal {
            var item = directions
            item.authorID = Self.localAuthorID
            updateLocal { $0.directions.insert(item, at: 0) }
            return
        }
        try await checkAccount()
        let record = CKRecord(recordType: SavedDirections.recordType)
        directions.fill(record)
        _ = try await database.save(record)
        changes += 1
    }

    /// Returns the repository ID of the shared route.
    @discardableResult
    func save(_ route: IndoorRoute) async throws -> String {
        if isLocal {
            var item = route
            item.id = UUID().uuidString
            item.authorID = Self.localAuthorID
            item.publishedID = nil
            updateLocal { $0.routes.insert(item, at: 0) }
            return item.id
        }
        try await checkAccount()
        let record = CKRecord(recordType: IndoorRoute.recordType)
        let files = try route.fill(record)
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        let saved = try await database.save(record)
        changes += 1
        return saved.recordID.recordName
    }

    func delete<Item: RepositoryItem>(_ item: Item) async throws {
        guard isMine(item.authorID) else { throw RepositoryError.notYours }
        if isLocal {
            updateLocal {
                $0.directions.removeAll { $0.id == item.id }
                $0.routes.removeAll { $0.id == item.id }
            }
            return
        }
        try await database.deleteRecord(withID: CKRecord.ID(recordName: item.id))
        changes += 1
    }

    func report<Item: RepositoryItem>(_ item: Item, reason: String) async throws {
        if isLocal {
            updateLocal { $0.reports.append(.init(itemType: Item.recordType, itemID: item.id, reason: reason, date: Date())) }
            return
        }
        try await checkAccount()
        let record = CKRecord(recordType: "Report")
        record["itemType"] = Item.recordType
        record["itemID"] = item.id
        record["title"] = item.title
        record["reason"] = reason
        _ = try await database.save(record)
    }

    /// Hides everything from this author on this iPhone.
    func hide(author: String?) {
        guard let author else { return }
        hiddenAuthors.insert(author)
        changes += 1
    }

    func unhideAll() {
        hiddenAuthors = []
        changes += 1
    }

    // MARK: Test mode

    struct LocalData: Codable {
        struct Report: Codable { var itemType, itemID, reason: String; var date: Date }
        var directions: [SavedDirections] = []
        var routes: [IndoorRoute] = []
        var reports: [Report] = []
    }

    private var local: LocalData {
        (try? Data(contentsOf: localURL)).flatMap { try? JSONDecoder().decode(LocalData.self, from: $0) } ?? LocalData()
    }

    private func updateLocal(_ change: (inout LocalData) -> Void) {
        var data = local
        change(&data)
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(data).write(to: localURL, options: .atomic)
        changes += 1
    }

    func clearTestData() {
        try? FileManager.default.removeItem(at: localURL)
        changes += 1
    }
}

// MARK: - CloudKit records

extension SavedDirections {
    init(record: CKRecord) {
        self.init(
            id: record.recordID.recordName,
            title: record["title"] as? String ?? "",
            destinationName: record["destinationName"] as? String ?? "",
            address: record["address"] as? String,
            latitude: record["latitude"] as? Double ?? 0,
            longitude: record["longitude"] as? Double ?? 0,
            transport: (record["transport"] as? String).flatMap(Transport.init) ?? .walking,
            steps: record["steps"] as? [String] ?? [],
            distance: record["distance"] as? Double ?? 0,
            travelTime: record["travelTime"] as? Double ?? 0,
            note: record["note"] as? String ?? "",
            authorName: record["authorName"] as? String ?? "",
            authorID: record.creatorUserRecordID?.recordName,
            createdAt: record.creationDate ?? Date())
    }

    func fill(_ record: CKRecord) {
        record["title"] = title
        record["destinationName"] = destinationName
        record["address"] = address
        record["latitude"] = latitude
        record["longitude"] = longitude
        record["location"] = CLLocation(latitude: latitude, longitude: longitude)
        record["transport"] = transport.rawValue
        if !steps.isEmpty { record["steps"] = steps }
        record["distance"] = distance
        record["travelTime"] = travelTime
        record["note"] = note
        record["authorName"] = authorName
    }
}

extension IndoorRoute {
    init(record: CKRecord) {
        var steps = (record["steps"] as? String)
            .flatMap { try? JSONDecoder().decode([IndoorStep].self, from: Data($0.utf8)) } ?? []
        // Photos are stored as assets, matched to their steps by ID.
        let assets = record["photos"] as? [CKAsset] ?? []
        let photoSteps = record["photoSteps"] as? [String] ?? []
        for (asset, stepID) in zip(assets, photoSteps) {
            if let index = steps.firstIndex(where: { $0.id.uuidString == stepID }),
               let url = asset.fileURL {
                steps[index].photo = try? Data(contentsOf: url)
            }
        }
        let location = record["location"] as? CLLocation
        self.init(
            id: record.recordID.recordName,
            title: record["title"] as? String ?? "",
            building: record["building"] as? String ?? "",
            startPoint: record["startPoint"] as? String ?? "",
            destination: record["destination"] as? String ?? "",
            steps: steps,
            authorName: record["authorName"] as? String ?? "",
            authorID: record.creatorUserRecordID?.recordName,
            createdAt: record.creationDate ?? Date(),
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude)
    }

    /// Fills the record; returns the temporary photo files to delete after saving.
    func fill(_ record: CKRecord) throws -> [URL] {
        record["title"] = title
        record["building"] = building
        record["startPoint"] = startPoint
        record["destination"] = destination
        record["authorName"] = authorName
        if let latitude, let longitude {
            record["location"] = CLLocation(latitude: latitude, longitude: longitude)
        }
        let withoutPhotos = steps.map { step -> IndoorStep in
            var copy = step
            copy.photo = nil
            return copy
        }
        record["steps"] = String(decoding: try JSONEncoder().encode(withoutPhotos), as: UTF8.self)

        var files: [URL] = []
        var stepIDs: [String] = []
        for step in steps {
            guard let photo = step.photo else { continue }
            let url = FileManager.default.temporaryDirectory.appending(path: "\(step.id.uuidString).jpg")
            try photo.write(to: url)
            files.append(url)
            stepIDs.append(step.id.uuidString)
        }
        if !files.isEmpty {
            record["photos"] = files.map { CKAsset(fileURL: $0) }
            record["photoSteps"] = stepIDs
        }
        return files
    }
}
