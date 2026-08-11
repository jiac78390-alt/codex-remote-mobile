import Darwin
import Foundation

enum DesktopGlobalStateStoreError: LocalizedError {
    case unavailable
    case invalidState
    case concurrentModification
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Codex global state is unavailable"
        case .invalidState: return "Codex global state is not a JSON object"
        case .concurrentModification: return "Codex global state kept changing during the update"
        case .verificationFailed: return "Codex global state update could not be verified"
        }
    }
}

final class DesktopGlobalStateStore {
    typealias Object = [String: Any]

    private let queue = DispatchQueue(label: "com.codexremote.desktop-global-state")
    private let stateURL: URL
    private let lockURL: URL

    init(
        stateURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.codex-global-state.json")
    ) {
        self.stateURL = stateURL.standardizedFileURL
        lockURL = stateURL.deletingLastPathComponent()
            .appendingPathComponent(".codex-global-state.codexremote.lock")
    }

    func setThreadPinned(
        _ threadID: String,
        pinned: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        mutate({ state in
            var pinnedIDs = Self.stringList(state["pinned-thread-ids"])
                .filter { $0 != threadID }
            if pinned { pinnedIDs.insert(threadID, at: 0) }
            state["pinned-thread-ids"] = pinnedIDs
        }, verify: { state in
            let pinnedIDs = Self.stringList(state["pinned-thread-ids"])
            return pinned ? pinnedIDs.first == threadID : !pinnedIDs.contains(threadID)
        }, completion: completion)
    }

    func assignThread(
        _ threadID: String,
        projectID: String?,
        cwd: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        mutate({ state in
            var assignments = Self.objectMap(state["thread-project-assignments"])
            var projectless = Self.stringList(state["projectless-thread-ids"])
                .filter { $0 != threadID }
            var orders = Self.objectMap(state["sidebar-project-thread-orders"])
            Self.remove(threadID, from: &orders)

            if let projectID {
                assignments[threadID] = [
                    "projectKind": "local",
                    "projectId": projectID,
                    "path": cwd,
                    "cwd": cwd,
                    "pendingCoreUpdate": false
                ]
                var project = orders[projectID] ?? [:]
                var threadIDs = Self.stringList(project["threadIds"])
                    .filter { $0 != threadID }
                threadIDs.insert(threadID, at: 0)
                project["threadIds"] = threadIDs
                orders[projectID] = project
            } else {
                assignments.removeValue(forKey: threadID)
                projectless.insert(threadID, at: 0)
            }

            state["thread-project-assignments"] = assignments
            state["projectless-thread-ids"] = projectless
            state["sidebar-project-thread-orders"] = orders
        }, verify: { state in
            let assignments = Self.objectMap(state["thread-project-assignments"])
            let projectless = Self.stringList(state["projectless-thread-ids"])
            let orders = Self.objectMap(state["sidebar-project-thread-orders"])
            let occurrences = orders.values.reduce(0) { count, project in
                count + Self.stringList(project["threadIds"]).filter { $0 == threadID }.count
            }
            if let projectID {
                return assignments[threadID]?["projectId"] as? String == projectID
                    && !projectless.contains(threadID)
                    && Self.stringList(orders[projectID]?["threadIds"]).first == threadID
                    && occurrences == 1
            }
            return assignments[threadID] == nil
                && projectless.first == threadID
                && occurrences == 0
        }, completion: completion)
    }

    func removeThreadMetadata(
        _ threadID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        mutate({ state in
            state["pinned-thread-ids"] = Self.stringList(state["pinned-thread-ids"])
                .filter { $0 != threadID }
            state["projectless-thread-ids"] = Self.stringList(state["projectless-thread-ids"])
                .filter { $0 != threadID }
            var assignments = Self.objectMap(state["thread-project-assignments"])
            assignments.removeValue(forKey: threadID)
            state["thread-project-assignments"] = assignments
            var orders = Self.objectMap(state["sidebar-project-thread-orders"])
            Self.remove(threadID, from: &orders)
            state["sidebar-project-thread-orders"] = orders
        }, verify: { state in
            let assignments = Self.objectMap(state["thread-project-assignments"])
            let orders = Self.objectMap(state["sidebar-project-thread-orders"])
            return !Self.stringList(state["pinned-thread-ids"]).contains(threadID)
                && !Self.stringList(state["projectless-thread-ids"]).contains(threadID)
                && assignments[threadID] == nil
                && orders.values.allSatisfy {
                    !Self.stringList($0["threadIds"]).contains(threadID)
                }
        }, completion: completion)
    }

    private func mutate(
        _ update: @escaping (inout Object) -> Void,
        verify: @escaping (Object) -> Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [self] in
            do {
                try withFileLock {
                    for _ in 0..<5 {
                        let initialData = try readCurrentData()
                        let initialMode = try currentFileMode()
                        var state = try decode(initialData)
                        update(&state)
                        guard JSONSerialization.isValidJSONObject(state) else {
                            throw DesktopGlobalStateStoreError.invalidState
                        }
                        guard try readCurrentData() == initialData else { continue }
                        let updatedData = try JSONSerialization.data(withJSONObject: state)
                        try updatedData.write(to: stateURL, options: .atomic)
                        if let initialMode, Darwin.chmod(stateURL.path, initialMode) != 0 {
                            throw DesktopGlobalStateStoreError.unavailable
                        }
                        let saved = try decode(readCurrentData())
                        guard verify(saved) else { continue }
                        return
                    }
                    throw DesktopGlobalStateStoreError.concurrentModification
                }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func withFileLock(_ body: () throws -> Void) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw DesktopGlobalStateStoreError.unavailable }
        defer { Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw DesktopGlobalStateStoreError.unavailable
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        try body()
    }

    private func readCurrentData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        return try Data(contentsOf: stateURL, options: .mappedIfSafe)
    }

    private func currentFileMode() throws -> mode_t? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else { return nil }
        return mode_t(permissions.uint16Value)
    }

    private func decode(_ data: Data?) throws -> Object {
        guard let data else { return [:] }
        guard let state = try JSONSerialization.jsonObject(with: data) as? Object else {
            throw DesktopGlobalStateStoreError.invalidState
        }
        return state
    }

    private static func stringList(_ value: Any?) -> [String] {
        value as? [String] ?? []
    }

    private static func objectMap(_ value: Any?) -> [String: Object] {
        value as? [String: Object] ?? [:]
    }

    private static func remove(_ threadID: String, from orders: inout [String: Object]) {
        for projectID in Array(orders.keys) {
            var project = orders[projectID] ?? [:]
            project["threadIds"] = stringList(project["threadIds"])
                .filter { $0 != threadID }
            orders[projectID] = project
        }
    }
}
