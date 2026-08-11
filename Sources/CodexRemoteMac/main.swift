import AppKit
import Darwin
import Foundation
import Network
import UniformTypeIdentifiers

#if canImport(CodexRemoteShared)
import CodexRemoteShared
#endif

private let serverQueue = DispatchQueue(label: "com.codexremote.server")
private typealias JSONObject = [String: Any]

private enum RemoteInterruptResult {
    case interrupted
    case alreadyInactive
    case failed(String)
}

private func processEnvironmentValue(_ name: String, processID: pid_t) -> String? {
    var query = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), processID]
    var size = 0
    guard sysctl(&query, u_int(query.count), nil, &size, nil, 0) == 0, size > 0 else {
        return nil
    }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&query, u_int(query.count), &buffer, &size, nil, 0) == 0 else {
        return nil
    }
    let prefix = "\(name)="
    return buffer.split(separator: 0).lazy
        .map { String(decoding: $0, as: UTF8.self) }
        .first(where: { $0.hasPrefix(prefix) })
        .map { String($0.dropFirst(prefix.count)) }
}

private struct CodexProjectSnapshot: Equatable {
    var projects: [RemoteProject] = []
    var threadAssignments: [String: String] = [:]
    var threadOrders: [String: Int] = [:]
    var pinnedThreadOrders: [String: Int] = [:]
}

private func codexGlobalStateURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/.codex-global-state.json")
}

private func loadCodexProjectSnapshot() -> CodexProjectSnapshot {
    guard let data = try? Data(contentsOf: codexGlobalStateURL()),
          let state = try? JSONSerialization.jsonObject(with: data) as? JSONObject else {
        return CodexProjectSnapshot()
    }

    let rawProjects = state["local-projects"] as? [String: JSONObject] ?? [:]
    let orderedIDs = state["project-order"] as? [String] ?? []
    let selected = (state["selected-project"] as? JSONObject)?["projectId"] as? String
    let remainingIDs = rawProjects.keys
        .filter { !orderedIDs.contains($0) }
        .sorted()
    let projects = (orderedIDs + remainingIDs).compactMap { id -> RemoteProject? in
        guard let raw = rawProjects[id],
              let name = raw["name"] as? String,
              let paths = raw["rootPaths"] as? [String],
              let path = paths.first else { return nil }
        return RemoteProject(id: id, name: name, path: path, isDefault: id == selected)
    }

    let validProjectIDs = Set(projects.map(\.id))
    let rawAssignments = state["thread-project-assignments"] as? [String: JSONObject] ?? [:]
    let assignments = rawAssignments.reduce(into: [String: String]()) { result, entry in
        guard let projectID = entry.value["projectId"] as? String,
              validProjectIDs.contains(projectID) else { return }
        result[entry.key] = projectID
    }

    let rawSidebarOrders = state["sidebar-project-thread-orders"] as? [String: JSONObject] ?? [:]
    var threadOrders: [String: Int] = [:]
    for projectID in orderedIDs {
        guard let threadIDs = rawSidebarOrders[projectID]?["threadIds"] as? [String] else { continue }
        for (index, threadID) in threadIDs.enumerated() {
            threadOrders[threadID] = index
        }
    }
    let pinnedThreadIDs = state["pinned-thread-ids"] as? [String] ?? []
    let pinnedThreadOrders = Dictionary(uniqueKeysWithValues: pinnedThreadIDs.enumerated().map { ($0.element, $0.offset) })
    return CodexProjectSnapshot(
        projects: projects,
        threadAssignments: assignments,
        threadOrders: threadOrders,
        pinnedThreadOrders: pinnedThreadOrders
    )
}

private func codexAutomationsRootURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/automations", isDirectory: true)
}

private enum AutomationStoreError: LocalizedError {
    case invalid(String)
    case missing
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .missing: return "找不到这个自动化"
        case .unavailable: return "无法更新 Mac 上的自动化配置"
        }
    }
}

private func automationIdentifierIsSafe(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 80 && value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
    }
}

private func tomlQuoted(_ value: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    guard let encoded = String(data: data, encoding: .utf8) else {
        throw AutomationStoreError.unavailable
    }
    return encoded.replacingOccurrences(of: "\\/", with: "/")
}

private func updatingTopLevelField(_ contents: String, key: String, value: String?) -> String {
    var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let index = lines.firstIndex { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.firstIndex(of: "=") else { return false }
        return trimmed[..<separator].trimmingCharacters(in: .whitespaces) == key
    }
    if let value {
        let replacement = "\(key) = \(value)"
        if let index { lines[index] = replacement } else { lines.append(replacement) }
    } else if let index {
        lines.remove(at: index)
    }
    return lines.joined(separator: "\n")
}

private func automationConfigurationURL(id: String) throws -> URL {
    guard automationIdentifierIsSafe(id) else { throw AutomationStoreError.invalid("自动化 ID 无效") }
    let root = codexAutomationsRootURL().standardizedFileURL
    let directory = root.appendingPathComponent(id, isDirectory: true).standardizedFileURL
    guard directory.deletingLastPathComponent() == root else {
        throw AutomationStoreError.invalid("自动化路径无效")
    }
    return directory.appendingPathComponent("automation.toml")
}

private func loadCodexAutomations() -> [RemoteAutomation] {
    let root = codexAutomationsRootURL()
    guard let directories = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    func decodedValue(_ raw: Substring) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("\""), value.hasSuffix("\""),
              let data = value.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else {
            return value
        }
        return decoded
    }

    let values = directories.compactMap { directory -> RemoteAutomation? in
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        let configuration = directory.appendingPathComponent("automation.toml")
        guard let contents = try? String(contentsOf: configuration, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        var rawFields: [String: String] = [:]
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = trimmed[trimmed.index(after: separator)...]
            fields[key] = decodedValue(rawValue)
            rawFields[key] = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let id = fields["id"], let name = fields["name"], let prompt = fields["prompt"] else { return nil }
        let cwd: String? = rawFields["cwds"].flatMap { value in
            guard let data = value.data(using: .utf8),
                  let paths = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
            return paths.first
        }
        let projectID: String? = rawFields["target"].flatMap { value in
            guard let keyRange = value.range(of: "project_id"),
                  let equals = value[keyRange.upperBound...].firstIndex(of: "=") else { return nil }
            let tail = value[value.index(after: equals)...]
            guard let firstQuote = tail.firstIndex(of: "\""),
                  let secondQuote = tail[tail.index(after: firstQuote)...].firstIndex(of: "\"") else { return nil }
            return String(tail[tail.index(after: firstQuote)..<secondQuote])
        }
        return RemoteAutomation(
            id: id,
            kind: fields["kind"] ?? "cron",
            name: name,
            prompt: prompt,
            status: fields["status"] ?? "PAUSED",
            schedule: fields["rrule"] ?? "",
            model: fields["model"],
            reasoningEffort: fields["reasoning_effort"],
            targetThreadId: fields["target_thread_id"],
            cwd: cwd,
            projectId: projectID,
            updatedAt: Double(fields["updated_at"] ?? "") ?? 0
        )
    }
    return values.sorted {
        let leftActive = $0.status.uppercased() == "ACTIVE"
        let rightActive = $1.status.uppercased() == "ACTIVE"
        if leftActive != rightActive { return leftActive }
        if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
}

private func codexAutomation(id: String) -> RemoteAutomation? {
    loadCodexAutomations().first { $0.id == id }
}

private func saveCodexAutomation(_ incoming: RemoteAutomation) throws -> RemoteAutomation {
    let name = incoming.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let prompt = incoming.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let schedule = incoming.schedule.trimmingCharacters(in: .whitespacesAndNewlines)
    guard automationIdentifierIsSafe(incoming.id), !name.isEmpty, name.count <= 100 else {
        throw AutomationStoreError.invalid("请填写 1 到 100 个字符的自动化名称")
    }
    guard !prompt.isEmpty, prompt.count <= 250_000 else {
        throw AutomationStoreError.invalid("自动化内容不能为空，且不能超过 25 万字符")
    }
    guard !schedule.isEmpty, schedule.count <= 512,
          schedule.uppercased().contains("FREQ=") else {
        throw AutomationStoreError.invalid("运行计划格式无效")
    }
    let status = incoming.status.uppercased()
    guard status == "ACTIVE" || status == "PAUSED" else {
        throw AutomationStoreError.invalid("自动化状态无效")
    }
    let kind = incoming.kind == "heartbeat" ? "heartbeat" : "cron"
    let configuration = try automationConfigurationURL(id: incoming.id)
    let directory = configuration.deletingLastPathComponent()
    let manager = FileManager.default
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    var contents: String
    if manager.fileExists(atPath: configuration.path) {
        let values = try? configuration.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true,
              let existing = try? String(contentsOf: configuration, encoding: .utf8) else {
            throw AutomationStoreError.unavailable
        }
        contents = existing
    } else {
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        contents = [
            "version = 1",
            "id = \(try tomlQuoted(incoming.id))",
            "kind = \(try tomlQuoted(kind))",
            "created_at = \(now)"
        ].joined(separator: "\n") + "\n"
    }
    contents = try updatingTopLevelField(contents, key: "name", value: tomlQuoted(name))
    contents = try updatingTopLevelField(contents, key: "prompt", value: tomlQuoted(prompt))
    contents = try updatingTopLevelField(contents, key: "status", value: tomlQuoted(status))
    contents = try updatingTopLevelField(contents, key: "rrule", value: tomlQuoted(schedule))
    contents = try updatingTopLevelField(
        contents,
        key: "model",
        value: incoming.model?.isEmpty == false ? tomlQuoted(incoming.model!) : nil
    )
    contents = try updatingTopLevelField(
        contents,
        key: "reasoning_effort",
        value: incoming.reasoningEffort?.isEmpty == false ? tomlQuoted(incoming.reasoningEffort!) : nil
    )
    if !manager.fileExists(atPath: configuration.path) {
        contents = try updatingTopLevelField(contents, key: "execution_environment", value: tomlQuoted("local"))
        if let cwd = incoming.cwd, cwd.hasPrefix("/") {
            contents = try updatingTopLevelField(contents, key: "cwds", value: "[\(tomlQuoted(cwd))]")
        }
        if let projectID = incoming.projectId, automationIdentifierIsSafe(projectID) {
            contents = try updatingTopLevelField(
                contents,
                key: "target",
                value: "{ type = \(tomlQuoted("project")), project_id = \(tomlQuoted(projectID)) }"
            )
        }
    }
    contents = updatingTopLevelField(contents, key: "updated_at", value: String(now))
    if !contents.hasSuffix("\n") { contents.append("\n") }
    do {
        try contents.write(to: configuration, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
    } catch {
        throw AutomationStoreError.invalid("无法更新 Mac 上的自动化配置：\(error.localizedDescription)")
    }
    guard let saved = codexAutomation(id: incoming.id) else {
        throw AutomationStoreError.invalid("自动化已写入，但 companion 无法重新读取配置")
    }
    return saved
}

private func deleteCodexAutomation(id: String) throws {
    let configuration = try automationConfigurationURL(id: id)
    let directory = configuration.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: configuration.path) else { throw AutomationStoreError.missing }
    let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let destination = trash.appendingPathComponent("CodexRemote-automation-\(id)-\(Int(Date().timeIntervalSince1970))")
    do {
        try FileManager.default.moveItem(at: directory, to: destination)
    } catch {
        throw AutomationStoreError.invalid("无法把自动化移到废纸篓：\(error.localizedDescription)")
    }
}

final class CodexDesktopHostBridge {
    private enum HostBridgeError: LocalizedError {
        case codexNotRunning
        case inspectorUnavailable
        case inspectorOwnedByAnotherProcess(pid_t)
        case invalidResponse
        case timedOut
        case hostRejected(String)

        var errorDescription: String? {
            switch self {
            case .codexNotRunning:
                return "Mac 上的 Codex App 未运行"
            case .inspectorUnavailable:
                return "无法连接 Codex 本机宿主桥"
            case .inspectorOwnedByAnotherProcess(let processID):
                return "端口 9229 属于其他进程（PID \(processID)），已拒绝连接"
            case .invalidResponse:
                return "Codex 宿主桥返回了无效数据"
            case .timedOut:
                return "Codex 宿主桥响应超时"
            case .hostRejected(let message):
                return message
            }
        }
    }

    private let queue = DispatchQueue(label: "com.codexremote.desktop-host")
    private let inspectorURL = URL(string: "http://127.0.0.1:9229/json/list")!
    private let requestTimeout: TimeInterval = 10
    private let refreshRetryDelay: TimeInterval = 2
    private let maximumRefreshAttempts = 30
    private let maximumInspectorAttempts = 3
    private let accountHomeURL: URL

    init(accountHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.accountHomeURL = accountHomeURL.standardizedFileURL
    }

    fileprivate func refreshActiveThreadViaInspector(
        threadID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.attemptActiveThreadRefresh(
                threadID: threadID,
                remainingAttempts: self.maximumRefreshAttempts,
                completion: completion
            )
        }
    }

    private func attemptActiveThreadRefresh(
        threadID: String,
        remainingAttempts: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            if try executeActiveThreadRefresh(threadID: threadID) {
                completion(.success(()))
                return
            }
            guard remainingAttempts > 0 else {
                throw HostBridgeError.hostRejected("Mac 输入框中仍有未发送内容，桌面同步已延后")
            }
            queue.asyncAfter(deadline: .now() + refreshRetryDelay) { [weak self] in
                self?.attemptActiveThreadRefresh(
                    threadID: threadID,
                    remainingAttempts: remainingAttempts - 1,
                    completion: completion
                )
            }
        } catch {
            completion(.failure(error))
        }
    }

    private var rendererHostPrelude: String {
        """
        (async () => {
            const moduleURL = [...document.querySelectorAll("link[rel=modulepreload]")]
                .map(link => link.href)
                .find(url => url.includes("app-initial-"));
            if (!moduleURL) throw new Error("Codex host module was not found");
            const module = await import(moduleURL);
            const hostCall = module.qut ?? Object.values(module).find(value => {
                if (typeof value !== "function" || value.length !== 0) return false;
                const source = Function.prototype.toString.call(value);
                return source.startsWith("async function")
                    && source.includes("...e")
                    && source.includes("params:")
                    && source.includes("select:")
                    && source.includes("signal:")
                    && source.includes("source:");
            });
            if (!hostCall) throw new Error("Codex host RPC client was not found");
        """
    }

    private var rendererAppServerPrelude: String {
        rendererHostPrelude + """
            const appServerCall = module.ddt ?? Object.values(module).find(value => {
                if (typeof value !== "function" || value.length !== 2) return false;
                const source = Function.prototype.toString.call(value);
                return source.includes(".sendRequest(") && !source.startsWith("async ");
            });
            if (!appServerCall) throw new Error("Codex app-server bridge was not found");
        """
    }

    private func hostCallScript(method: String, params: JSONObject) -> String {
        do {
            let methodValue = try jsonLiteral(method)
            let paramsValue = try jsonLiteral(params)
            return rendererHostPrelude + """
                return await hostCall(\(methodValue), { params: \(paramsValue) });
            })()
            """
        } catch {
            return "(async () => { throw new Error(\"Unable to encode host request\") })()"
        }
    }

    private func perform(
        rendererScript: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.execute(rendererScript: rendererScript)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func execute(rendererScript: String) throws {
        let encoded = Data(rendererScript.utf8).base64EncodedString()
        _ = try executeInMainProcess { processID in
            """
            (async () => {
                if (process.pid !== \(processID)) throw new Error("Connected to the wrong inspector");
                const { BrowserWindow } = process.mainModule.require("electron");
                const windows = BrowserWindow.getAllWindows();
                const window = windows.find(candidate => {
                    const url = candidate.webContents.getURL();
                    return url === "app://-/index.html" || (
                        url.startsWith("app://-/index.html")
                        && !url.includes("avatar-overlay")
                    );
                });
                if (!window) throw new Error("Codex main window was not found");
                const code = Buffer.from("\(encoded)", "base64").toString("utf8");
                return await window.webContents.executeJavaScript(code, true);
            })()
            """
        }
    }

    private func executeActiveThreadRefresh(threadID: String) throws -> Bool {
        let thread = try jsonLiteral(threadID)
        let script = rendererAppServerPrelude + """
            const threadId = \(thread);
            const activeThread = document.querySelector(
                '[data-app-action-sidebar-thread-active="true"]'
            )?.getAttribute('data-app-action-sidebar-thread-id');
            const hasDraft = [...document.querySelectorAll(
                'textarea, [contenteditable="true"]'
            )].some(element => {
                if (element.offsetParent === null || element.disabled) return false;
                const value = 'value' in element ? element.value : element.textContent;
                return typeof value === 'string' && value.trim().length > 0;
            });
            if (activeThread === 'local:' + threadId && hasDraft) return false;

            await appServerCall("discard-conversation-from-cache", {
                conversationId: threadId
            });
            await appServerCall("hydrate-background-threads", {
                hostId: "local",
                threadIds: [threadId],
                includeTurns: true
            });
            if (activeThread === 'local:' + threadId) {
                window.postMessage({ type: 'navigate-to-route', path: '/' }, '*');
                await new Promise(resolve => setTimeout(resolve, 300));
                const expectedThread = 'local:' + threadId;
                for (let attempt = 0; attempt < 15; attempt += 1) {
                    window.postMessage({
                        type: 'navigate-to-route',
                        path: '/local/' + encodeURIComponent(threadId)
                    }, '*');
                    await new Promise(resolve => setTimeout(resolve, 300));
                    const restoredThread = document.querySelector(
                        '[data-app-action-sidebar-thread-active="true"]'
                    )?.getAttribute('data-app-action-sidebar-thread-id');
                    if (restoredThread === expectedThread) return true;
                }
                throw new Error("Codex did not restore the active task after hydration");
            }
            return true;
        })()
        """
        try execute(rendererScript: script)
        return true
    }

    private func executeInMainProcess(_ expression: (pid_t) -> String) throws -> Any? {
        var lastError: Error?
        for attempt in 0..<maximumInspectorAttempts {
            do {
                return try executeInMainProcessOnce(expression)
            } catch {
                lastError = error
                if let bridgeError = error as? HostBridgeError {
                    switch bridgeError {
                    case .codexNotRunning, .inspectorOwnedByAnotherProcess:
                        throw error
                    default:
                        break
                    }
                }
                if attempt + 1 < maximumInspectorAttempts {
                    usleep(useconds_t(250_000 * (attempt + 1)))
                }
            }
        }
        throw lastError ?? HostBridgeError.inspectorUnavailable
    }

    private func executeInMainProcessOnce(_ expression: (pid_t) -> String) throws -> Any? {
        guard let application = matchingApplication() else {
            throw HostBridgeError.codexNotRunning
        }
        let processID = application.processIdentifier
        guard application.bundleIdentifier == "com.openai.codex",
              let bundleURL = application.bundleURL?.standardizedFileURL,
              let executableURL = application.executableURL?.standardizedFileURL,
              executableURL.path.hasPrefix(
                  bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true).path + "/"
              ) else {
            throw HostBridgeError.codexNotRunning
        }

        let initialOwners = try inspectorListenerProcessIDs()
        if let foreignOwner = initialOwners.first(where: { $0 != processID }) {
            throw HostBridgeError.inspectorOwnedByAnotherProcess(foreignOwner)
        }
        let inspectorWasOpen = initialOwners.contains(processID)
            && (try? inspectorTarget(expectedProcessID: processID)) != nil
        if initialOwners.isEmpty {
            guard Darwin.kill(processID, SIGUSR1) == 0 else {
                throw HostBridgeError.inspectorUnavailable
            }
        }

        let deadline = Date().addingTimeInterval(2)
        var target: URL?
        repeat {
            let owners = try inspectorListenerProcessIDs()
            if let foreignOwner = owners.first(where: { $0 != processID }) {
                throw HostBridgeError.inspectorOwnedByAnotherProcess(foreignOwner)
            }
            if owners.contains(processID) {
                target = try? inspectorTarget(expectedProcessID: processID)
            }
            if target == nil { usleep(50_000) }
        } while target == nil && Date() < deadline
        guard let target else { throw HostBridgeError.inspectorUnavailable }
        if !inspectorWasOpen {
            usleep(750_000)
        }

        do {
            return try evaluate(
                expression: expression(processID),
                target: target,
                closeInspector: !inspectorWasOpen
            )
        } catch {
            if !inspectorWasOpen {
                try? scheduleInspectorClose(target: target)
            }
            throw error
        }
    }

    private func matchingApplication() -> NSRunningApplication? {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        let expectedHome = accountHomeURL.standardizedFileURL.path
        let matches = applications.filter { application in
            let fixedHome = processEnvironmentValue(
                "CFFIXED_USER_HOME",
                processID: application.processIdentifier
            )
            let home = URL(
                fileURLWithPath: fixedHome ?? FileManager.default.homeDirectoryForCurrentUser.path
            ).standardizedFileURL.path
            return home == expectedHome
        }
        if let active = matches.first(where: \.isActive) { return active }
        return matches.max {
            ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast)
        }
    }

    private func inspectorListenerProcessIDs() throws -> Set<pid_t> {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-iTCP:9229", "-sTCP:LISTEN", "-Fp"]
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw HostBridgeError.inspectorUnavailable
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let processIDs = Set(text.split(whereSeparator: \.isNewline).compactMap { line -> pid_t? in
            guard line.first == "p", let value = Int32(line.dropFirst()) else { return nil }
            return value
        })
        guard process.terminationStatus == 0
                || (process.terminationStatus == 1 && processIDs.isEmpty) else {
            throw HostBridgeError.inspectorUnavailable
        }
        return processIDs
    }

    private func inspectorTarget(expectedProcessID: pid_t) throws -> URL {
        let owners = try inspectorListenerProcessIDs()
        guard owners == Set([expectedProcessID]) else {
            if let foreignOwner = owners.first(where: { $0 != expectedProcessID }) {
                throw HostBridgeError.inspectorOwnedByAnotherProcess(foreignOwner)
            }
            throw HostBridgeError.inspectorUnavailable
        }
        var data: Data?
        var requestError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        var request = URLRequest(url: inspectorURL)
        request.timeoutInterval = 0.35
        URLSession.shared.dataTask(with: request) { responseData, _, error in
            data = responseData
            requestError = error
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 0.5) == .success else {
            throw HostBridgeError.timedOut
        }
        if let requestError { throw requestError }
        guard let data,
              let targets = try JSONSerialization.jsonObject(with: data) as? [JSONObject],
              let address = targets.compactMap({ $0["webSocketDebuggerUrl"] as? String }).first,
              let url = URL(string: address) else {
            throw HostBridgeError.invalidResponse
        }
        return url
    }

    private func evaluate(expression: String, target: URL, closeInspector: Bool) throws -> Any? {
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: target)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        let request: JSONObject = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": [
                "expression": expression,
                "returnByValue": true,
                "awaitPromise": true
            ]
        ]
        try send(request, through: socket)
        let response = try receiveResponse(id: 1, through: socket)
        guard let evaluation = response["result"] as? JSONObject else {
            throw HostBridgeError.invalidResponse
        }
        if let details = evaluation["exceptionDetails"] as? JSONObject {
            let exception = details["exception"] as? JSONObject
            let message = exception?["description"] as? String
                ?? details["text"] as? String
                ?? "Codex rejected the host request"
            throw HostBridgeError.hostRejected(message)
        }

        if closeInspector {
            try scheduleInspectorClose(through: socket)
        }
        let runtimeResult = evaluation["result"] as? JSONObject
        return runtimeResult?["value"]
    }

    private func scheduleInspectorClose(target: URL) throws {
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: target)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        try scheduleInspectorClose(through: socket)
    }

    private func scheduleInspectorClose(through socket: URLSessionWebSocketTask) throws {
        let request: JSONObject = [
            "id": 2,
            "method": "Runtime.evaluate",
            "params": [
                "expression": """
                setTimeout(() => {
                    try { process.mainModule.require("inspector").close(); } catch {}
                }, 150);
                true
                """,
                "returnByValue": true
            ]
        ]
        try send(request, through: socket)
        _ = try? receiveResponse(id: 2, through: socket)
    }

    private func send(_ object: JSONObject, through socket: URLSessionWebSocketTask) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HostBridgeError.invalidResponse
        }
        var sendError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        socket.send(.string(text)) { error in
            sendError = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + requestTimeout) == .success else {
            throw HostBridgeError.timedOut
        }
        if let sendError { throw sendError }
    }

    private func receiveResponse(
        id: Int,
        through socket: URLSessionWebSocketTask
    ) throws -> JSONObject {
        let deadline = Date().addingTimeInterval(requestTimeout)
        while Date() < deadline {
            var received: Result<URLSessionWebSocketTask.Message, Error>?
            let semaphore = DispatchSemaphore(value: 0)
            socket.receive { result in
                received = result
                semaphore.signal()
            }
            let remaining = max(0.05, deadline.timeIntervalSinceNow)
            guard semaphore.wait(timeout: .now() + remaining) == .success else {
                throw HostBridgeError.timedOut
            }
            guard let received else { throw HostBridgeError.invalidResponse }
            let message = try received.get()
            let data: Data
            switch message {
            case .string(let text):
                data = Data(text.utf8)
            case .data(let value):
                data = value
            @unknown default:
                continue
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
                continue
            }
            if (object["id"] as? NSNumber)?.intValue == id { return object }
        }
        throw HostBridgeError.timedOut
    }

    private func jsonLiteral(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        guard let string = String(data: data, encoding: .utf8) else {
            throw HostBridgeError.invalidResponse
        }
        return string
    }
}

final class CodexDesktopIPC {
    private struct StreamState {
        var revision: Int
        var conversation: JSONObject
    }

    private static let maximumFrameSize = 256 * 1024 * 1024

    fileprivate var onConversationState: ((String, JSONObject, Bool) -> Void)?
    fileprivate var onConnectionStateChanged: ((Bool) -> Void)?
    private let queue = DispatchQueue(label: "com.codexremote.desktop-ipc")
    private lazy var requestCoordinator = DesktopIPCRequestCoordinator(
        queue: queue,
        requestTimeout: 12
    )
    private let socketPath: String
    private let connectionNotBefore: Date?
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var clientID: String?
    private var initializeRequestID: String?
    private var reconnectWorkItem: DispatchWorkItem?
    private var invalidationWorkItem: DispatchWorkItem?
    private var pendingInvalidation = false
    private var followedThreadIDs = Set<String>()
    private var streamStates: [String: StreamState] = [:]
    private var started = false

    init() {
        socketPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/ipc/ipc.sock")
            .path
        if let rawDelay = ProcessInfo.processInfo.environment[
            "CODEX_REMOTE_TEST_DESKTOP_IPC_DELAY_MS"
        ], let delayMilliseconds = Double(rawDelay), delayMilliseconds > 0 {
            connectionNotBefore = Date().addingTimeInterval(delayMilliseconds / 1_000)
        } else {
            connectionNotBefore = nil
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.connect()
        }
    }

    func invalidateQueries() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingInvalidation = true
            if self.invalidationWorkItem == nil {
                self.scheduleInvalidation(after: .milliseconds(160))
            }
            if self.socketFD < 0 { self.connect() }
        }
    }

    func loadCompleteHistory(
        threadID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.socketFD >= 0, let clientID = self.clientID else {
                if self.socketFD < 0 { self.connect() }
                completion(.failure(DesktopIPCRequestError.disconnected))
                return
            }
            let request = self.requestCoordinator.prepareRequest(
                clientID: clientID,
                method: "thread-follower-load-complete-history",
                version: 1,
                params: [
                    "hostId": "local",
                    "conversationId": threadID
                ]
            ) { result in
                switch result {
                case .success(let response):
                    guard (response["revision"] as? NSNumber)?.intValue != nil else {
                        completion(.failure(DesktopIPCRequestError.invalidResponse))
                        return
                    }
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
            guard self.send(request) else {
                self.requestCoordinator.failAll(with: .disconnected)
                return
            }
        }
    }

    fileprivate func startTurn(
        threadID: String,
        turnStartParams: JSONObject,
        completion: @escaping (Result<JSONObject, Error>) -> Void
    ) {
        requestThreadFollower(
            method: "thread-follower-start-turn",
            threadID: threadID,
            params: ["turnStartParams": turnStartParams],
            completion: completion
        )
    }

    fileprivate func steerTurn(
        threadID: String,
        input: [JSONObject],
        restoreMessage: JSONObject,
        additionalContext: JSONObject?,
        completion: @escaping (Result<JSONObject, Error>) -> Void
    ) {
        var params: JSONObject = [
            "input": input,
            "restoreMessage": restoreMessage,
            "attachments": [],
            "clientUserMessageId": UUID().uuidString
        ]
        if let additionalContext { params["additionalContext"] = additionalContext }
        requestThreadFollower(
            method: "thread-follower-steer-turn",
            threadID: threadID,
            params: params,
            completion: completion
        )
    }

    fileprivate func interruptTurn(
        threadID: String,
        expectedTurnID: String?,
        completion: @escaping (Result<JSONObject, Error>) -> Void
    ) {
        var params: JSONObject = ["mode": "user-stop"]
        if let expectedTurnID { params["expectedTurnId"] = expectedTurnID }
        requestThreadFollower(
            method: "thread-follower-interrupt-turn",
            threadID: threadID,
            params: params,
            completion: completion
        )
    }

    fileprivate func updateThreadSettings(
        threadID: String,
        settings: JSONObject,
        completion: @escaping (Result<JSONObject, Error>) -> Void
    ) {
        requestThreadFollower(
            method: "thread-follower-update-thread-settings",
            threadID: threadID,
            params: ["threadSettings": settings],
            completion: completion
        )
    }

    private func requestThreadFollower(
        method: String,
        threadID: String,
        params: JSONObject,
        completion: @escaping (Result<JSONObject, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.socketFD >= 0, let clientID = self.clientID else {
                if self.socketFD < 0 { self.connect() }
                completion(.failure(DesktopIPCRequestError.disconnected))
                return
            }
            var routedParams = params
            routedParams["hostId"] = "local"
            routedParams["conversationId"] = threadID
            let request = self.requestCoordinator.prepareRequest(
                clientID: clientID,
                method: method,
                version: 1,
                params: routedParams,
                completion: completion
            )
            guard self.send(request) else {
                self.requestCoordinator.failAll(with: .disconnected)
                return
            }
        }
    }

    func setFollowedThreads(_ threadIDs: Set<String>) {
        queue.async { [weak self] in
            guard let self else { return }
            let removed = self.followedThreadIDs.subtracting(threadIDs)
            let added = threadIDs.subtracting(self.followedThreadIDs)
            self.followedThreadIDs = threadIDs
            for threadID in removed {
                self.streamStates.removeValue(forKey: threadID)
                self.sendFollowing(threadID, following: false)
            }
            for threadID in added { self.sendFollowing(threadID, following: true) }
            if self.socketFD < 0 { self.connect() }
        }
    }

    private func connect() {
        guard started, socketFD < 0 else { return }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        if let connectionNotBefore, Date() < connectionNotBefore {
            scheduleReconnect()
            return
        }

        guard FileManager.default.fileExists(atPath: socketPath) else {
            scheduleReconnect()
            return
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            scheduleReconnect()
            return
        }

        var noSignal: Int32 = 1
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            scheduleReconnect()
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                destination[index] = UInt8(bitPattern: byte)
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            scheduleReconnect()
            return
        }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        socketFD = fd
        buffer.removeAll(keepingCapacity: true)
        clientID = nil

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource = source
        source.setEventHandler { [weak self] in self?.readAvailableData() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        sendInitialize()
    }

    private func readAvailableData() {
        guard socketFD >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(socketFD, &bytes, bytes.count)
            if count > 0 {
                buffer.append(contentsOf: bytes.prefix(count))
                processFrames()
                continue
            }
            if count == 0 {
                resetConnection()
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            resetConnection()
            return
        }
    }

    private func processFrames() {
        while buffer.count >= 4 {
            let length = Int(buffer[0])
                | (Int(buffer[1]) << 8)
                | (Int(buffer[2]) << 16)
                | (Int(buffer[3]) << 24)
            guard length >= 0, length <= Self.maximumFrameSize else {
                resetConnection()
                return
            }
            guard buffer.count >= 4 + length else { return }
            let payload = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? JSONObject else { continue }
            handle(object)
        }
    }

    private func handle(_ object: JSONObject) {
        switch object["type"] as? String {
        case "response":
            if requestCoordinator.resolve(object) { return }
            guard object["requestId"] as? String == initializeRequestID,
                  object["resultType"] as? String == "success",
                  let result = object["result"] as? JSONObject,
                  let clientID = result["clientId"] as? String else { return }
            initializeRequestID = nil
            self.clientID = clientID
            NSLog("Codex Remote connected to desktop IPC")
            onConnectionStateChanged?(true)
            for threadID in followedThreadIDs.sorted() {
                sendFollowing(threadID, following: true)
            }
            if pendingInvalidation { scheduleInvalidation(after: .milliseconds(10)) }
        case "broadcast":
            handleBroadcast(object)
        case "client-discovery-request":
            guard let requestID = object["requestId"] as? String else { return }
            send([
                "type": "client-discovery-response",
                "requestId": requestID,
                "response": ["canHandle": false]
            ])
        default:
            break
        }
    }

    private func handleBroadcast(_ object: JSONObject) {
        guard object["method"] as? String == "thread-stream-state-changed",
              let params = object["params"] as? JSONObject,
              let threadID = params["conversationId"] as? String,
              followedThreadIDs.contains(threadID),
              let change = params["change"] as? JSONObject,
              let changeType = change["type"] as? String else { return }

        switch changeType {
        case "snapshot":
            guard let revision = (change["revision"] as? NSNumber)?.intValue,
                  let conversation = change["conversationState"] as? JSONObject else { return }
            streamStates[threadID] = StreamState(revision: revision, conversation: conversation)
            onConversationState?(threadID, conversation, true)
        case "patches":
            guard let baseRevision = (change["baseRevision"] as? NSNumber)?.intValue,
                  let revision = (change["revision"] as? NSNumber)?.intValue,
                  let patches = change["patches"] as? [JSONObject] else {
                NSLog("Codex Remote desktop IPC sent a malformed patch envelope for %@", threadID)
                requestFreshSnapshot(threadID)
                return
            }
            guard var state = streamStates[threadID] else {
                requestFreshSnapshot(threadID)
                return
            }
            guard state.revision == baseRevision else {
                NSLog(
                    "Codex Remote desktop IPC revision gap for %@: current=%d base=%d next=%d",
                    threadID,
                    state.revision,
                    baseRevision,
                    revision
                )
                requestFreshSnapshot(threadID)
                return
            }
            for patch in patches {
                guard let updated = applying(patch, to: state.conversation) else {
                    NSLog(
                        "Codex Remote desktop IPC patch failed for %@: op=%@ path=%@",
                        threadID,
                        patch["op"] as? String ?? "?",
                        String(describing: patch["path"] ?? "?")
                    )
                    requestFreshSnapshot(threadID)
                    return
                }
                state.conversation = updated
            }
            state.revision = revision
            streamStates[threadID] = state
            onConversationState?(threadID, state.conversation, false)
        default:
            break
        }
    }

    private func sendFollowing(_ threadID: String, following: Bool) {
        guard let clientID else { return }
        _ = send([
            "type": "broadcast",
            "method": "thread-stream-following-changed",
            "sourceClientId": clientID,
            "version": 1,
            "params": [
                "hostId": "local",
                "conversationId": threadID,
                "following": following
            ]
        ])
    }

    private func requestFreshSnapshot(_ threadID: String) {
        streamStates.removeValue(forKey: threadID)
        sendFollowing(threadID, following: false)
        queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
            guard let self, self.followedThreadIDs.contains(threadID) else { return }
            self.sendFollowing(threadID, following: true)
        }
    }

    private func applying(_ patch: JSONObject, to root: JSONObject) -> JSONObject? {
        guard let operation = patch["op"] as? String,
              let path = patch["path"] as? [Any] else { return nil }
        let value = patch["value"]
        guard let updated = applying(
            operation: operation,
            path: ArraySlice(path),
            value: value,
            to: root
        ) else { return nil }
        return updated as? JSONObject
    }

    private func applying(
        operation: String,
        path: ArraySlice<Any>,
        value: Any?,
        to node: Any
    ) -> Any? {
        guard let segment = path.first else {
            guard operation == "add" || operation == "replace", let value else { return nil }
            return value
        }
        let remainder = path.dropFirst()

        if var object = node as? JSONObject, let key = segment as? String {
            if remainder.isEmpty {
                switch operation {
                case "add", "replace":
                    guard let value else { return nil }
                    object[key] = value
                case "remove":
                    guard object.removeValue(forKey: key) != nil else { return nil }
                default:
                    return nil
                }
                return object
            }
            guard let child = object[key],
                  let updated = applying(
                      operation: operation,
                      path: remainder,
                      value: value,
                      to: child
                  ) else { return nil }
            object[key] = updated
            return object
        }

        if var array = node as? [Any] {
            let index: Int
            if let number = segment as? NSNumber {
                index = number.intValue
            } else if let text = segment as? String, let parsed = Int(text) {
                index = parsed
            } else if segment as? String == "-", operation == "add", remainder.isEmpty {
                index = array.count
            } else {
                return nil
            }

            if remainder.isEmpty {
                switch operation {
                case "add":
                    guard let value, index >= 0, index <= array.count else { return nil }
                    array.insert(value, at: index)
                case "replace":
                    guard let value, array.indices.contains(index) else { return nil }
                    array[index] = value
                case "remove":
                    guard array.indices.contains(index) else { return nil }
                    array.remove(at: index)
                default:
                    return nil
                }
                return array
            }
            guard array.indices.contains(index),
                  let updated = applying(
                      operation: operation,
                      path: remainder,
                      value: value,
                      to: array[index]
                  ) else { return nil }
            array[index] = updated
            return array
        }

        return nil
    }

    private func sendInitialize() {
        let requestID = UUID().uuidString
        initializeRequestID = requestID
        send([
            "type": "request",
            "requestId": requestID,
            "method": "initialize",
            "version": 0,
            "params": ["clientType": "codex-remote-companion"]
        ])
    }

    private func scheduleInvalidation(after delay: DispatchTimeInterval) {
        invalidationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.flushInvalidation() }
        invalidationWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func flushInvalidation() {
        invalidationWorkItem = nil
        guard pendingInvalidation else { return }
        guard let clientID else {
            if socketFD < 0 { connect() }
            return
        }
        guard send([
            "type": "broadcast",
            "method": "query-cache-invalidate",
            "sourceClientId": clientID,
            "version": 0,
            "params": ["queryKey": []]
        ]) else { return }
        pendingInvalidation = false
    }

    @discardableResult
    private func send(_ object: JSONObject) -> Bool {
        guard socketFD >= 0,
              JSONSerialization.isValidJSONObject(object),
              let payload = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              payload.count <= Self.maximumFrameSize else { return false }
        let count = UInt32(payload.count)
        var frame = Data([
            UInt8(count & 0xFF),
            UInt8((count >> 8) & 0xFF),
            UInt8((count >> 16) & 0xFF),
            UInt8((count >> 24) & 0xFF)
        ])
        frame.append(payload)

        var offset = 0
        let written = frame.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            while offset < frame.count {
                let count = Darwin.write(socketFD, baseAddress.advanced(by: offset), frame.count - offset)
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
        if !written {
            pendingInvalidation = true
            resetConnection()
        }
        return written
    }

    private func resetConnection() {
        guard socketFD >= 0 || readSource != nil else { return }
        let source = readSource
        readSource = nil
        socketFD = -1
        source?.cancel()
        buffer.removeAll(keepingCapacity: true)
        clientID = nil
        initializeRequestID = nil
        requestCoordinator.failAll(with: .disconnected)
        onConnectionStateChanged?(false)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard started, reconnectWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.connect()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 1, execute: workItem)
    }
}

final class WebSocketPeer {
    private static let maximumFrameSize = 48 * 1024 * 1024
    private let connection: NWConnection
    private let queue: DispatchQueue
    private weak var server: RemoteServer?
    private var buffer = Data()
    private var handshakeComplete = false
    private var handshakeResponseFlushed = false
    private let stateLock = NSLock()
    private var closed = false
    private var closing = false
    private var authenticatedClientID: String?
    private var handshakeTimeoutWorkItem: DispatchWorkItem?
    private var fragmentedPayload = Data()
    private var fragmentedOpcode: UInt8?
    private var outgoingFrames: [Data] = []
    private var outgoingBytes = 0
    private var isSendingFrame = false

    init(connection: NWConnection, server: RemoteServer) {
        self.connection = connection
        self.server = server
        queue = DispatchQueue(label: "com.codexremote.peer.\(UUID().uuidString)")
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in
            guard self?.handshakeComplete == false else { return }
            self?.close()
        }
        handshakeTimeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
        receive()
    }

    func send(text: String) {
        queue.async { [weak self] in
            guard let self, self.handshakeComplete else { return }
            self.sendFrame(opcode: 0x1, payload: Data(text.utf8))
        }
    }

    func sendHandshake(_ response: String, allowQueuedFrames: Bool = false) {
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if error != nil {
                    self.close()
                    return
                }
                guard allowQueuedFrames else { return }
                self.handshakeResponseFlushed = true
                self.drainOutgoingFrames()
            }
        })
    }

    func rejectHandshake(status: String) {
        let body = status
        let response = "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        sendHandshake(response)
    }

    func markAuthenticated(clientID: String) {
        stateLock.lock()
        authenticatedClientID = clientID
        stateLock.unlock()
    }

    var clientID: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return authenticatedClientID
    }

    var allowsLegacyQueryAuthentication: Bool {
        guard case .hostPort(let host, _) = connection.endpoint else { return false }
        let value = String(describing: host).lowercased()
        return value == "localhost" || value == "::1" || value == "[::1]" || value.hasPrefix("127.")
    }

    func close() {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        closing = false
        stateLock.unlock()
        handshakeTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem = nil
        connection.cancel()
        server?.remove(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if self.buffer.count > Self.maximumFrameSize + 16 * 1024 {
                    self.close()
                    return
                }
                self.processBuffer()
            }
            if complete || error != nil {
                if !self.isClosing { self.close() }
            } else if !self.isClosing {
                self.receive()
            }
        }
    }

    private func processBuffer() {
        if !handshakeComplete {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let request = String(data: buffer[..<range.upperBound], encoding: .utf8) ?? ""
            buffer.removeSubrange(..<range.upperBound)
            guard server?.completeHandshake(request, peer: self) == true else {
                queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.close() }
                return
            }
            handshakeComplete = true
            handshakeTimeoutWorkItem?.cancel()
            handshakeTimeoutWorkItem = nil
        }

        while let frame = nextFrame() {
            switch frame.opcode {
            case 0x1:
                guard fragmentedOpcode == nil else { close(); return }
                if frame.isFinal {
                    handleCommandPayload(frame.payload)
                } else {
                    fragmentedOpcode = frame.opcode
                    fragmentedPayload = frame.payload
                }
            case 0x0:
                guard fragmentedOpcode == 0x1 else { close(); return }
                fragmentedPayload.append(frame.payload)
                guard fragmentedPayload.count <= Self.maximumFrameSize else { close(); return }
                if frame.isFinal {
                    let payload = fragmentedPayload
                    fragmentedPayload.removeAll(keepingCapacity: false)
                    fragmentedOpcode = nil
                    handleCommandPayload(payload)
                }
            case 0x8:
                replyToClose(frame.payload)
                return
            case 0x9:
                sendFrame(opcode: 0xA, payload: frame.payload)
            default:
                break
            }
        }
    }

    private struct Frame {
        let isFinal: Bool
        let opcode: UInt8
        let payload: Data
    }

    private func handleCommandPayload(_ payload: Data) {
        guard let command = try? RemoteJSON.decoder.decode(RemoteCommand.self, from: payload) else { return }
        server?.handle(command, from: self)
    }

    private func nextFrame() -> Frame? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.startIndex + 1]
        let isFinal = (first & 0x80) != 0
        let opcode = first & 0x0F
        guard (first & 0x70) == 0 else { close(); return nil }
        let masked = (second & 0x80) != 0
        guard masked else {
            close()
            buffer.removeAll(keepingCapacity: false)
            return nil
        }
        var length = Int(second & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            length = Int(buffer[offset]) << 8 | Int(buffer[offset + 1])
            offset += 2
        } else if length == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            var value: UInt64 = 0
            for index in 0..<8 { value = (value << 8) | UInt64(buffer[offset + index]) }
            guard value <= UInt64(Int.max) else { close(); return nil }
            length = Int(value)
            offset += 8
        }
        let maskLength = masked ? 4 : 0
        guard length <= Self.maximumFrameSize else {
            close()
            buffer.removeAll(keepingCapacity: false)
            return nil
        }
        if opcode >= 0x8, (!isFinal || length > 125) {
            close()
            return nil
        }
        guard buffer.count >= offset + maskLength + length else { return nil }
        var payload = Data(buffer[(offset + maskLength)..<(offset + maskLength + length)])
        if masked {
            let mask = Array(buffer[offset..<(offset + 4)])
            for index in payload.indices { payload[index] ^= mask[index % 4] }
        }
        buffer.removeSubrange(0..<(offset + maskLength + length))
        return Frame(isFinal: isFinal, opcode: opcode, payload: payload)
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        guard !isClosedOrClosing else { return }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            var length = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        outgoingFrames.append(frame)
        outgoingBytes += frame.count
        guard outgoingBytes <= Self.maximumFrameSize + 16 * 1024 * 1024 else {
            close()
            return
        }
        drainOutgoingFrames()
    }

    private func drainOutgoingFrames() {
        guard handshakeResponseFlushed, !isClosedOrClosing,
              !isSendingFrame, !outgoingFrames.isEmpty else { return }
        isSendingFrame = true
        let frame = outgoingFrames.removeFirst()
        outgoingBytes -= frame.count
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.isSendingFrame = false
                if error != nil {
                    self.close()
                } else {
                    self.drainOutgoingFrames()
                }
            }
        })
    }

    private var isClosing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closing
    }

    fileprivate var isClosedOrClosing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed || closing
    }

    private func replyToClose(_ payload: Data) {
        stateLock.lock()
        guard !closed, !closing else {
            stateLock.unlock()
            return
        }
        closing = true
        stateLock.unlock()
        let body = Data(payload.prefix(125))
        var frame = Data([0x88, UInt8(body.count)])
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }
}

final class RemoteServer {
    private struct CommandReceipt: Codable {
        var key: String
        var completedAt: Double
        var acknowledgement: RemoteEvent
    }

    private struct ReceiptEnvelope: Codable {
        var version: Int
        var receipts: [CommandReceipt]
    }

    private static let maximumResourceBytes = 24 * 1024 * 1024
    private static let maximumReceiptCount = 2_000
    private static let maximumPeerCount = 24
    private static let maximumPendingPeerCount = 32
    let port: UInt16
    let pairingKey: String
    let bridge: CodexAppServerBridge
    private let desktopIPC: CodexDesktopIPC
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: WebSocketPeer] = [:]
    private var watchedThreadsByPeer: [ObjectIdentifier: String] = [:]
    private var latestTasks: [Bool: [RemoteTaskSummary]] = [:]
    private var latestModels: [RemoteModel] = []
    private var latestPlugins: [RemotePlugin] = []
    private var resourceCatalog: [String: RemoteResource] = [:]
    private var commandReceipts: [String: CommandReceipt] = [:]
    private var commandsInFlight: [String: RemoteCommand] = [:]
    private let lock = NSLock()
    private let receiptPersistenceQueue = DispatchQueue(label: "com.codexremote.command-receipts")

    init(port: UInt16 = 8765) {
        self.port = port
        if let existing = UserDefaults.standard.string(forKey: "CodexRemote.pairingKey"), !existing.isEmpty {
            pairingKey = existing
        } else {
            pairingKey = String((0..<24).compactMap { _ in
                "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789".randomElement()
            })
            UserDefaults.standard.set(pairingKey, forKey: "CodexRemote.pairingKey")
        }
        let desktopIPC = CodexDesktopIPC()
        let bridge = CodexAppServerBridge(desktopIPC: desktopIPC)
        self.desktopIPC = desktopIPC
        self.bridge = bridge
        bridge.onEvent = { [weak self] event in self?.receive(event) }
        bridge.onDesktopInvalidation = { [weak desktopIPC] in desktopIPC?.invalidateQueries() }
        desktopIPC.onConversationState = { [weak bridge] threadID, conversation, isSnapshot in
            bridge?.receiveDesktopConversationState(
                threadID: threadID,
                conversation: conversation,
                isSnapshot: isSnapshot
            )
        }
        desktopIPC.onConnectionStateChanged = { [weak bridge] connected in
            bridge?.setDesktopStreamConnected(connected)
        }
        restoreCommandReceipts()
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("Codex Remote listener failed: %@", String(describing: error))
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                let peer = WebSocketPeer(connection: connection, server: self)
                self.lock.lock()
                self.peers = self.peers.filter { !$0.value.isClosedOrClosing }
                guard self.peers.count < Self.maximumPendingPeerCount else {
                    self.lock.unlock()
                    connection.cancel()
                    return
                }
                self.peers[ObjectIdentifier(peer)] = peer
                self.lock.unlock()
                peer.start()
            }
            self.listener = listener
            listener.start(queue: serverQueue)
            desktopIPC.start()
            bridge.start()
        } catch {
            NSLog("Codex Remote could not listen on %hu: %@", port, String(describing: error))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let connectedPeers = Array(peers.values)
        peers.removeAll()
        lock.unlock()
        connectedPeers.forEach { $0.close() }
        desktopIPC.setFollowedThreads([])
        bridge.stop()
    }

    func completeHandshake(_ request: String, peer: WebSocketPeer) -> Bool {
        guard let firstLine = request.split(separator: "\r\n", omittingEmptySubsequences: false).first,
              firstLine.hasPrefix("GET ") else { return false }
        let pieces = firstLine.split(separator: " ")
        guard pieces.count >= 2 else { return false }
        let target = String(pieces[1])
        guard let components = URLComponents(string: "http://codex.local\(target)"),
              components.path == "/control" else {
            peer.rejectHandshake(status: "404 Not Found")
            NSLog("Codex Remote rejected a WebSocket request with an invalid path")
            return false
        }
        let authorization = requestHeader("authorization", in: request)
        let bearerToken = authorization.flatMap { value -> String? in
            guard value.lowercased().hasPrefix("bearer ") else { return nil }
            return String(value.dropFirst(7))
        }
        let headerToken = bearerToken ?? requestHeader("x-codexremote-token", in: request)
        let legacyToken = peer.allowsLegacyQueryAuthentication
            ? components.queryItems?.first(where: { $0.name == "token" })?.value
            : nil
        guard constantTimeEqual(headerToken ?? legacyToken ?? "", pairingKey) else {
            peer.rejectHandshake(status: "401 Unauthorized")
            NSLog("Codex Remote rejected a WebSocket request with an invalid pairing key")
            return false
        }
        let headerClientID = requestHeader("x-codexremote-client-id", in: request)
        let queryClientID = peer.allowsLegacyQueryAuthentication
            ? components.queryItems?.first(where: { $0.name == "clientId" })?.value
            : nil
        let suppliedClientID = headerClientID ?? queryClientID
        let authenticatedClientID: String
        if let suppliedClientID, !suppliedClientID.isEmpty {
            authenticatedClientID = String(suppliedClientID.prefix(128))
        } else {
            authenticatedClientID = "legacy-\(ObjectIdentifier(peer).hashValue)"
        }
        guard let keyLine = request.split(separator: "\r\n").first(where: {
            $0.lowercased().hasPrefix("sec-websocket-key:")
        }) else { return false }
        let key = keyLine.split(separator: ":", maxSplits: 1).dropFirst().joined()
            .trimmingCharacters(in: .whitespaces)
        peer.markAuthenticated(clientID: authenticatedClientID)
        lock.lock()
        let replacedPeers = peers.values.filter {
            $0 !== peer && $0.clientID == authenticatedClientID
        }
        lock.unlock()
        replacedPeers.forEach { $0.close() }

        lock.lock()
        let authenticatedPeerCount = peers.values.filter { $0.clientID != nil }.count
        lock.unlock()
        guard authenticatedPeerCount <= Self.maximumPeerCount else {
            peer.rejectHandshake(status: "503 Service Unavailable")
            return false
        }
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(websocketAccept(key))\r\n\r\n"
        peer.sendHandshake(response, allowQueuedFrames: true)
        NSLog("Codex Remote connected client %@", authenticatedClientID)
        send(RemoteEvent(type: RemoteMessage.hello, name: "Codex Remote Mac", version: "0.12", codexReady: bridge.isReady, serverTime: Date().timeIntervalSince1970), to: peer)
        send(RemoteEvent(type: RemoteMessage.projects, projects: projectCatalog()), to: peer)
        send(RemoteEvent(type: RemoteMessage.automations, automations: loadCodexAutomations()), to: peer)
        lock.lock()
        let cachedTasks = latestTasks[false]
        let cachedModels = latestModels
        let cachedPlugins = latestPlugins
        lock.unlock()
        if let cachedTasks {
            send(RemoteEvent(type: RemoteMessage.tasks, tasks: cachedTasks, archived: false), to: peer)
        }
        if !cachedModels.isEmpty {
            send(RemoteEvent(type: RemoteMessage.models, models: cachedModels), to: peer)
        }
        if !cachedPlugins.isEmpty {
            send(RemoteEvent(type: RemoteMessage.plugins, plugins: cachedPlugins), to: peer)
        }
        bridge.requestTaskList()
        if cachedModels.isEmpty { bridge.requestModels() }
        return true
    }

    func handle(_ command: RemoteCommand, from peer: WebSocketPeer) {
        guard beginReliableCommand(command, from: peer) else { return }
        switch command.type {
        case RemoteMessage.tasksRequest:
            bridge.requestTaskList(archived: command.archived ?? false)
        case RemoteMessage.projectsRequest:
            broadcast(RemoteEvent(type: RemoteMessage.projects, projects: projectCatalog()))
        case RemoteMessage.refresh:
            bridge.requestTaskList(archived: command.archived ?? false)
            broadcast(RemoteEvent(type: RemoteMessage.projects, projects: projectCatalog()))
            broadcast(RemoteEvent(type: RemoteMessage.automations, automations: loadCodexAutomations()))
        case RemoteMessage.taskOpen:
            if let id = command.threadId {
                selectThread(id, for: peer)
                bridge.openThread(id)
            }
        case RemoteMessage.taskCreate:
            if let requestID = command.requestId {
                broadcast(RemoteEvent(
                    type: RemoteMessage.taskAction,
                    requestId: requestID,
                    value: "creating"
                ))
            }
            bridge.createThread(
                cwd: command.cwd,
                initialPrompt: command.value,
                requestId: command.requestId,
                projectId: command.projectId,
                model: command.model,
                effort: command.effort,
                permissionMode: command.permissionMode,
                planMode: command.planMode,
                attachments: command.attachments ?? [],
                skills: command.skills ?? []
            ) { [weak self] threadID, turnID, errorMessage in
                if let threadID { self?.selectThread(threadID, for: peer) }
                self?.completeReliableCommand(
                    command,
                    accepted: errorMessage == nil,
                    retryable: errorMessage.map(Self.isRetryableDeliveryError) ?? false,
                    threadId: threadID,
                    turnId: turnID,
                    message: errorMessage
                )
            }
            return
        case RemoteMessage.taskRename:
            if let id = command.threadId, let name = command.value { bridge.renameThread(id, name: name) }
        case RemoteMessage.taskPin:
            if let id = command.threadId, let pinned = command.pinned { bridge.setPinned(id, pinned: pinned) }
        case RemoteMessage.taskArchive:
            if let id = command.threadId { bridge.setArchived(id, archived: true) }
        case RemoteMessage.taskUnarchive:
            if let id = command.threadId { bridge.setArchived(id, archived: false) }
        case RemoteMessage.taskDelete:
            if let id = command.threadId { bridge.deleteThread(id) }
        case RemoteMessage.taskSettingsUpdate:
            if let id = command.threadId {
                bridge.updateSettings(
                    threadId: id,
                    model: command.model,
                    effort: command.effort,
                    cwd: command.cwd,
                    permissionMode: command.permissionMode,
                    planMode: command.planMode
                )
            }
        case RemoteMessage.prompt:
            let value = command.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty || !(command.attachments ?? []).isEmpty || !(command.skills ?? []).isEmpty else {
                completeReliableCommand(command, accepted: false, retryable: false, message: "消息内容为空")
                return
            }
            if let threadID = command.threadId { selectThread(threadID, for: peer) }
            bridge.sendPrompt(
                value,
                attachments: command.attachments ?? [],
                skills: command.skills ?? [],
                threadId: command.threadId,
                cwd: command.cwd,
                model: command.model,
                effort: command.effort,
                permissionMode: command.permissionMode,
                planMode: command.planMode
            ) { [weak self] threadID, turnID, errorMessage in
                self?.completeReliableCommand(
                    command,
                    accepted: errorMessage == nil,
                    retryable: errorMessage.map(Self.isRetryableDeliveryError) ?? false,
                    threadId: threadID,
                    turnId: turnID,
                    message: errorMessage
                )
            }
            return
        case RemoteMessage.interrupt:
            guard let threadId = command.threadId else {
                completeReliableCommand(command, accepted: false, retryable: false, message: "缺少任务 ID")
                return
            }
            bridge.interrupt(threadId: threadId, turnId: command.turnId) { [weak self] result in
                switch result {
                case .interrupted:
                    self?.completeReliableCommand(
                        command,
                        accepted: true,
                        retryable: false,
                        threadId: threadId,
                        turnId: command.turnId
                    )
                case .alreadyInactive:
                    self?.completeReliableCommand(
                        command,
                        accepted: true,
                        retryable: false,
                        threadId: threadId,
                        turnId: command.turnId,
                        code: RemoteEventCode.noActiveTurn
                    )
                case .failed(let message):
                    self?.completeReliableCommand(
                        command,
                        accepted: false,
                        retryable: Self.isRetryableDeliveryError(message),
                        threadId: threadId,
                        turnId: command.turnId,
                        message: message
                    )
                }
            }
            return
        case RemoteMessage.steer:
            let value = command.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let id = command.threadId,
                  !value.isEmpty || !(command.attachments ?? []).isEmpty || !(command.skills ?? []).isEmpty else {
                completeReliableCommand(command, accepted: false, retryable: false, message: "追加指令内容为空")
                return
            }
            bridge.steer(
                value,
                attachments: command.attachments ?? [],
                skills: command.skills ?? [],
                threadId: id,
                turnId: command.turnId,
                model: command.model,
                effort: command.effort,
                permissionMode: command.permissionMode,
                planMode: command.planMode,
                afterInterrupt: command.afterInterrupt ?? false
            ) { [weak self] errorMessage in
                self?.completeReliableCommand(
                    command,
                    accepted: errorMessage == nil,
                    retryable: errorMessage.map(Self.isRetryableDeliveryError) ?? false,
                    threadId: id,
                    turnId: command.turnId,
                    message: errorMessage
                )
            }
            return
        case RemoteMessage.modelsRequest:
            bridge.requestModels()
        case RemoteMessage.pluginsRequest:
            bridge.requestPlugins(cwd: command.cwd)
        case RemoteMessage.automationsRequest:
            broadcast(RemoteEvent(type: RemoteMessage.automations, automations: loadCodexAutomations()))
        case RemoteMessage.automationSave:
            guard let automation = command.automation else {
                completeReliableCommand(command, accepted: false, retryable: false, message: "自动化内容无效")
                return
            }
            do {
                _ = try saveCodexAutomation(automation)
                broadcast(RemoteEvent(type: RemoteMessage.automations, automations: loadCodexAutomations()))
                completeReliableCommand(command, accepted: true, retryable: false)
            } catch {
                completeReliableCommand(command, accepted: false, retryable: false, message: error.localizedDescription)
            }
            return
        case RemoteMessage.automationSetEnabled:
            guard let id = command.automation?.id, var automation = codexAutomation(id: id) else {
                completeReliableCommand(command, accepted: false, retryable: false, message: "找不到这个自动化")
                return
            }
            automation.status = command.value?.uppercased() == "ACTIVE" ? "ACTIVE" : "PAUSED"
            do {
                _ = try saveCodexAutomation(automation)
                broadcast(RemoteEvent(type: RemoteMessage.automations, automations: loadCodexAutomations()))
                completeReliableCommand(command, accepted: true, retryable: false)
            } catch {
                completeReliableCommand(command, accepted: false, retryable: false, message: error.localizedDescription)
            }
            return
        case RemoteMessage.automationRun:
            guard let id = command.automation?.id, let automation = codexAutomation(id: id) else {
                completeReliableCommand(command, accepted: false, retryable: false, message: "找不到这个自动化")
                return
            }
            if let targetThreadID = automation.targetThreadId, !targetThreadID.isEmpty {
                bridge.sendPrompt(
                    automation.prompt,
                    attachments: [],
                    skills: [],
                    threadId: targetThreadID,
                    cwd: automation.cwd,
                    model: automation.model,
                    effort: automation.reasoningEffort,
                    permissionMode: RemotePermissionMode.custom.rawValue,
                    planMode: false
                ) { [weak self] threadID, turnID, errorMessage in
                    self?.completeReliableCommand(
                        command,
                        accepted: errorMessage == nil,
                        retryable: errorMessage.map(Self.isRetryableDeliveryError) ?? false,
                        threadId: threadID,
                        turnId: turnID,
                        message: errorMessage
                    )
                }
            } else {
                bridge.createThread(
                    cwd: automation.cwd,
                    initialPrompt: automation.prompt,
                    requestId: command.messageId,
                    projectId: automation.projectId,
                    model: automation.model,
                    effort: automation.reasoningEffort,
                    permissionMode: RemotePermissionMode.custom.rawValue,
                    planMode: false,
                    attachments: [],
                    skills: []
                ) { [weak self] threadID, turnID, errorMessage in
                    self?.completeReliableCommand(
                        command,
                        accepted: errorMessage == nil,
                        retryable: errorMessage.map(Self.isRetryableDeliveryError) ?? false,
                        threadId: threadID,
                        turnId: turnID,
                        message: errorMessage
                    )
                }
            }
            return
        case RemoteMessage.automationDelete:
            guard let id = command.automation?.id else {
                completeReliableCommand(command, accepted: false, retryable: false, message: "自动化 ID 无效")
                return
            }
            do {
                try deleteCodexAutomation(id: id)
                broadcast(RemoteEvent(type: RemoteMessage.automations, automations: loadCodexAutomations()))
                completeReliableCommand(command, accepted: true, retryable: false)
            } catch {
                completeReliableCommand(command, accepted: false, retryable: false, message: error.localizedDescription)
            }
            return
        case RemoteMessage.resourceRequest:
            guard let requestID = command.requestId, let path = command.value else { return }
            lock.lock()
            let resource = resourceCatalog[path]
            lock.unlock()
            guard let resource else {
                broadcast(RemoteEvent(
                    type: RemoteMessage.resourceData,
                    requestId: requestID,
                    message: "这个文件不在当前 Codex 对话中"
                ))
                return
            }
            sendResource(resource, requestID: requestID)
        case RemoteMessage.approvalDecision:
            if let requestId = command.requestId, let decision = command.decision {
                bridge.answerApproval(requestId: requestId, decision: decision)
            }
        default:
            break
        }
        completeReliableCommand(command, accepted: true, retryable: false)
    }

    private func beginReliableCommand(_ command: RemoteCommand, from peer: WebSocketPeer) -> Bool {
        guard let messageID = command.messageId else { return true }
        if peer.allowsLegacyQueryAuthentication,
           peer.clientID?.hasPrefix("legacy-") == true,
           let requestedClientID = command.clientId,
           !requestedClientID.isEmpty {
            peer.markAuthenticated(clientID: String(requestedClientID.prefix(128)))
        }
        guard let clientID = command.clientId,
              clientID == peer.clientID,
              !messageID.isEmpty,
              messageID.count <= 128 else {
            send(RemoteEvent(
                type: RemoteMessage.commandAck,
                message: "可靠消息身份无效",
                messageId: messageID,
                accepted: false,
                retryable: false,
                serverTime: Date().timeIntervalSince1970
            ), to: peer)
            return false
        }
        let key = receiptKey(clientID: clientID, messageID: messageID)
        lock.lock()
        let receipt = commandReceipts[key]
        let alreadyInFlight = commandsInFlight[key] != nil
        if receipt == nil && !alreadyInFlight { commandsInFlight[key] = command }
        lock.unlock()
        if let receipt {
            send(receipt.acknowledgement, to: peer)
            return false
        }
        return !alreadyInFlight
    }

    private func completeReliableCommand(
        _ command: RemoteCommand,
        accepted: Bool,
        retryable: Bool,
        threadId: String? = nil,
        turnId: String? = nil,
        code: String? = nil,
        message: String? = nil
    ) {
        guard let messageID = command.messageId, let clientID = command.clientId else { return }
        let event = RemoteEvent(
            type: RemoteMessage.commandAck,
            requestId: command.requestId,
            threadId: threadId ?? command.threadId,
            turnId: turnId,
            code: code,
            message: message,
            messageId: messageID,
            accepted: accepted,
            retryable: retryable,
            serverTime: Date().timeIntervalSince1970
        )
        let key = receiptKey(clientID: clientID, messageID: messageID)
        var shouldPersist = false
        lock.lock()
        commandsInFlight.removeValue(forKey: key)
        if accepted || !retryable {
            commandReceipts[key] = CommandReceipt(
                key: key,
                completedAt: Date().timeIntervalSince1970,
                acknowledgement: event
            )
            if commandReceipts.count > Self.maximumReceiptCount {
                let expired = commandReceipts.values
                    .sorted { $0.completedAt < $1.completedAt }
                    .prefix(commandReceipts.count - Self.maximumReceiptCount)
                expired.forEach { commandReceipts.removeValue(forKey: $0.key) }
            }
            shouldPersist = true
        }
        lock.unlock()
        if shouldPersist { persistCurrentCommandReceipts() }
        send(event, toClient: clientID)
    }

    private func send(_ event: RemoteEvent, toClient clientID: String) {
        guard let data = try? RemoteJSON.encoder.encode(event),
              let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        let connected = peers.values.filter { $0.clientID == clientID }
        lock.unlock()
        connected.forEach { $0.send(text: text) }
    }

    private func releaseReliableCommandsAfterAppServerInterruption() {
        lock.lock()
        let interruptedCommands = Array(commandsInFlight.values)
        commandsInFlight.removeAll()
        lock.unlock()
        for command in interruptedCommands {
            completeReliableCommand(
                command,
                accepted: false,
                retryable: true,
                message: "Codex 服务连接中断，消息将在恢复后自动重试"
            )
        }
    }

    private func receiptKey(clientID: String, messageID: String) -> String {
        "\(clientID)|\(messageID)"
    }

    private func restoreCommandReceipts() {
        guard let data = try? Data(contentsOf: commandReceiptURL),
              let envelope = try? RemoteJSON.decoder.decode(ReceiptEnvelope.self, from: data),
              envelope.version == 1 else { return }
        commandReceipts = Dictionary(uniqueKeysWithValues: envelope.receipts.map { ($0.key, $0) })
    }

    private func persistCurrentCommandReceipts() {
        receiptPersistenceQueue.sync {
            lock.lock()
            let receipts = Array(commandReceipts.values)
            lock.unlock()
            let envelope = ReceiptEnvelope(version: 1, receipts: receipts)
            guard let data = try? RemoteJSON.encoder.encode(envelope) else { return }
            let directory = commandReceiptURL.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: commandReceiptURL, options: .atomic)
            } catch {
                NSLog("Codex Remote could not persist command receipts: %@", error.localizedDescription)
            }
        }
    }

    private var commandReceiptURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CodexRemote", isDirectory: true)
            .appendingPathComponent("command-receipts-v1.json")
    }

    private static func isRetryableDeliveryError(_ message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("连接")
            || value.contains("超时")
            || value.contains("connection")
            || value.contains("timeout")
            || value.contains("timed out")
            || value.contains("temporarily")
            || value.contains("正在恢复")
            || value.contains("自动恢复")
            || (value.contains("expected active turn id") && value.contains("but found"))
    }

    func refreshProjects() {
        broadcast(RemoteEvent(type: RemoteMessage.projects, projects: projectCatalog()))
    }

    func remove(_ peer: WebSocketPeer) {
        lock.lock()
        let peerID = ObjectIdentifier(peer)
        peers.removeValue(forKey: peerID)
        watchedThreadsByPeer.removeValue(forKey: peerID)
        let watchedThreadIDs = Set(watchedThreadsByPeer.values)
        lock.unlock()
        bridge.setWatchedThreads(watchedThreadIDs)
        desktopIPC.setFollowedThreads(watchedThreadIDs)
    }

    private func selectThread(_ threadID: String, for peer: WebSocketPeer) {
        let peerID = ObjectIdentifier(peer)
        lock.lock()
        guard peers[peerID] === peer else {
            lock.unlock()
            return
        }
        watchedThreadsByPeer[peerID] = threadID
        let watchedThreadIDs = Set(watchedThreadsByPeer.values)
        lock.unlock()
        bridge.setWatchedThreads(watchedThreadIDs)
        desktopIPC.setFollowedThreads(watchedThreadIDs)
    }

    private func send(_ event: RemoteEvent, to peer: WebSocketPeer) {
        guard let data = try? RemoteJSON.encoder.encode(event), let text = String(data: data, encoding: .utf8) else { return }
        peer.send(text: text)
    }

    private func broadcast(_ event: RemoteEvent) {
        guard let data = try? RemoteJSON.encoder.encode(event), let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        let connected = Array(peers.values)
        lock.unlock()
        connected.forEach { $0.send(text: text) }
    }

    private func receive(_ event: RemoteEvent) {
        if event.type == RemoteMessage.hello, event.codexReady == false {
            releaseReliableCommandsAfterAppServerInterruption()
        }
        lock.lock()
        let resources = (event.item?.resources ?? [])
            + (event.items ?? []).flatMap { $0.resources ?? [] }
        for resource in resources { resourceCatalog[resource.path] = resource }
        if event.type == RemoteMessage.tasks, let tasks = event.tasks {
            latestTasks[event.archived ?? false] = tasks
        } else if event.type == RemoteMessage.models, let models = event.models {
            latestModels = models
        } else if event.type == RemoteMessage.plugins, let plugins = event.plugins {
            latestPlugins = plugins
        }
        lock.unlock()
        broadcast(event)
    }

    private func sendResource(_ resource: RemoteResource, requestID: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard resource.sizeBytes <= Self.maximumResourceBytes else {
                self.broadcast(RemoteEvent(
                    type: RemoteMessage.resourceData,
                    requestId: requestID,
                    message: "文件超过 24 MB，无法在移动端预览"
                ))
                return
            }
            let url = URL(fileURLWithPath: resource.path)
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  data.count == resource.sizeBytes,
                  data.count <= Self.maximumResourceBytes else {
                self.broadcast(RemoteEvent(
                    type: RemoteMessage.resourceData,
                    requestId: requestID,
                    message: "Mac 无法读取这个文件"
                ))
                return
            }
            self.broadcast(RemoteEvent(
                type: RemoteMessage.resourceData,
                resource: RemoteResourcePayload(resource: resource, dataBase64: data.base64EncodedString()),
                requestId: requestID
            ))
        }
    }

    private func projectCatalog() -> [RemoteProject] {
        loadCodexProjectSnapshot().projects
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func requestHeader(_ name: String, in request: String) -> String? {
        let prefix = name.lowercased() + ":"
        return request.split(separator: "\r\n", omittingEmptySubsequences: false)
            .dropFirst()
            .first { $0.lowercased().hasPrefix(prefix) }
            .map { line in
                line.split(separator: ":", maxSplits: 1)
                    .dropFirst()
                    .joined(separator: ":")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }

    private func websocketAccept(_ key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        var digest = [UInt8](repeating: 0, count: 20)
        SHA1.hash(Array(magic.utf8), into: &digest)
        return Data(digest).base64EncodedString()
    }
}

final class CodexAppServerBridge {
    private struct PendingRequest {
        var method: String
        var completion: (JSONObject) -> Void
        var timeoutWorkItem: DispatchWorkItem
    }

    private struct SnapshotCacheEnvelope: Codable {
        var version: Int
        var snapshots: [String: RemoteEvent]
    }

    private struct PendingTurnContext {
        var threadId: String
        var input: [JSONObject]
        var fallbackAttempted: Bool
        var permissionMode: String?
        var planMode: Bool?
    }

    private struct RecentInterrupt {
        var turnID: String
        var expiresAt: Date
    }

    private struct FinalAnswerRecheck {
        var turnID: String
        var workItem: DispatchWorkItem
    }

    private struct DeferredPostInterruptPrompt {
        var prompt: String
        var attachments: [RemoteAttachment]
        var skills: [RemoteSkill]
        var model: String?
        var effort: String?
        var permissionMode: String?
        var planMode: Bool?
        var completion: (String?) -> Void
    }

    private enum InputError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let message): return message
            }
        }
    }

    var onEvent: ((RemoteEvent) -> Void)?
    var onDesktopInvalidation: (() -> Void)?
    private(set) var isReady = false

    private let queue = DispatchQueue(label: "com.codexremote.codex-app-server")
    private let desktopIPC: CodexDesktopIPC
    private let desktopState = DesktopGlobalStateStore()
    private let desktopHost = CodexDesktopHostBridge()
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputBuffer = Data()
    private var outputScanOffset = 0
    private var errorBuffer = Data()
    private var initializationTimeoutWorkItem: DispatchWorkItem?
    private var appServerRecoveryMessage: String?
    private var restartWorkItem: DispatchWorkItem?
    private var restartAttempt = 0
    private var shouldRun = false
    private var requestID = 0
    private var pending: [Int: PendingRequest] = [:]
    private var queuedActions: [() -> Void] = []
    private var loadedThreads = Set<String>()
    private var activeTurns: [String: String] = [:]
    private var recentInterrupts: [String: RecentInterrupt] = [:]
    private var deferredPostInterruptPrompts: [String: [DeferredPostInterruptPrompt]] = [:]
    private var postInterruptPromptInFlight: [String: DeferredPostInterruptPrompt] = [:]
    private var completedTurnIDsByThread: [String: String] = [:]
    private var companionTurnReconciliationAt: [String: Date] = [:]
    private var snapshotFinalAnswerGate = SnapshotFinalAnswerGate()
    private var finalAnswerRechecks: [String: FinalAnswerRecheck] = [:]
    private var settingsByThread: [String: RemoteTaskSettings] = [:]
    private var permissionModesByThread = UserDefaults.standard.dictionary(forKey: "CodexRemotePermissionModes") as? [String: String] ?? [:]
    private var plansByThread: [String: [RemotePlanStep]] = [:]
    private var planExplanationsByThread: [String: String] = [:]
    private var approvals: [String: (rpcID: Any, method: String, params: JSONObject)] = [:]
    private var sessionProjectAssignments: [String: String] = [:]
    private var syncTimer: DispatchSourceTimer?
    private var taskListRequestInFlight = false
    private var taskListRefreshPending = false
    private var pendingArchivedFilter = false
    private var taskCreationRequestsInFlight = 0
    private var threadReadRequestsInFlight = Set<String>()
    private var threadReadRefreshPending = Set<String>()
    private var threadReadForceRefreshPending = Set<String>()
    private var threadSnapshotOnNextLiveItem = Set<String>()
    private var threadSnapshotOnNextLiveItemExpiry: [String: DispatchWorkItem] = [:]
    private var threadReadRetryWorkItems: [String: DispatchWorkItem] = [:]
    private var threadResumeWaiters: [String: [(String?) -> Void]] = [:]
    private var rolloutPathsByThreadID: [String: String] = [:]
    private var missingRolloutPathThreadIDs = Set<String>()
    private var pendingDesktopRefreshThreads = Set<String>()
    private var deletedThreadIDs = Set<String>()
    private var activeArchivedFilter = false
    private var watchedThreadIDs = Set<String>()
    private var desktopStreamThreadIDs = Set<String>()
    private var desktopHistoryRequestsInFlight = Set<String>()
    private var desktopHistoryLoadGenerations: [String: UUID] = [:]
    private var desktopHistoryLoadStartedAt: [String: Date] = [:]
    private var desktopHistoryRetryWorkItems: [String: DispatchWorkItem] = [:]
    private var desktopOwnedThreadIDs = Set<String>()
    private let desktopHistoryRecoveryPolicy = DesktopHistoryRecoveryPolicy()
    private var lastProjectSnapshot = CodexProjectSnapshot()
    private var lastTaskLists: [Bool: [RemoteTaskSummary]] = [:]
    private var cachedThreadSnapshots: [String: RemoteEvent] = [:]
    private var snapshotCacheSaveWorkItem: DispatchWorkItem?
    private var pendingTurnContexts: [String: PendingTurnContext] = [:]
    private var modelCatalog: [RemoteModel] = []
    private var pluginCatalog: [RemotePlugin] = []
    private var pluginSkillsByPath: [String: RemoteSkill] = [:]
    private var pluginRequestGeneration = 0
    private var pluginRequestInFlight = false
    private var activePluginCwd: String?
    private var pluginRefreshPending = false
    private var pendingPluginCwd: String?
    private var unsupportedModelIDs = Set<String>()
    private let providerID: String
    private let configuredModelID: String?
    private let companionInstanceID: String

    private static let appServerPIDKey = "CodexRemote.appServerPID"
    private static let companionInstanceIDKey = "CodexRemote.companionInstanceID"
    private static let childMarkerEnvironmentKey = "CODEX_REMOTE_COMPANION_ID"

    init(desktopIPC: CodexDesktopIPC) {
        self.desktopIPC = desktopIPC
        if let saved = UserDefaults.standard.string(forKey: Self.companionInstanceIDKey), !saved.isEmpty {
            companionInstanceID = saved
        } else {
            let generated = UUID().uuidString
            companionInstanceID = generated
            UserDefaults.standard.set(generated, forKey: Self.companionInstanceIDKey)
        }
        providerID = Self.configuredValue("model_provider") ?? "default"
        configuredModelID = Self.configuredValue("model")
        unsupportedModelIDs = Set(
            UserDefaults.standard.stringArray(forKey: "CodexRemote.unsupportedModels.\(providerID)") ?? []
        )
        restoreSnapshotCache()
        terminateRecordedAppServer()
    }

    func start() {
        queue.async { [weak self] in
            self?.shouldRun = true
            self?.launch()
        }
    }

    func stop() {
        queue.sync {
            self.shouldRun = false
            self.restartWorkItem?.cancel()
            self.restartWorkItem = nil
            self.initializationTimeoutWorkItem?.cancel()
            self.initializationTimeoutWorkItem = nil
            self.syncTimer?.cancel()
            self.syncTimer = nil
            self.desktopHistoryRetryWorkItems.values.forEach { $0.cancel() }
            self.desktopHistoryRetryWorkItems.removeAll()
            self.desktopHistoryLoadGenerations.removeAll()
            self.desktopHistoryLoadStartedAt.removeAll()
            self.desktopHistoryRequestsInFlight.removeAll()
            self.inputPipe?.fileHandleForWriting.closeFile()
            self.process?.terminationHandler = nil
            if self.process?.isRunning == true { self.process?.terminate() }
            self.clearRecordedAppServerPID(self.process?.processIdentifier)
            self.process = nil
            self.inputPipe = nil
            self.isReady = false
            self.companionTurnReconciliationAt.removeAll()
            self.resetAllSnapshotFinalAnswerTracking()
        }
    }

    func requestTaskList(archived: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeArchivedFilter = archived
            if let cached = self.lastTaskLists[archived] {
                self.emit(RemoteEvent(type: RemoteMessage.tasks, tasks: cached, archived: archived))
            }
            self.whenReady { self.listThreads(archived: archived) }
        }
    }

    func requestModels() {
        queue.async { [weak self] in
            self?.whenReady { self?.listModels() }
        }
    }

    func requestPlugins(cwd: String? = nil) {
        queue.async { [weak self] in
            self?.whenReady { self?.listPlugins(cwd: cwd) }
        }
    }

    func openThread(_ threadId: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.requestSnapshotOnNextLiveItem(threadId)
            if let activeTurnID = self.activeTurns[threadId] {
                self.emit(RemoteEvent(
                    type: RemoteMessage.taskState,
                    threadId: threadId,
                    turnId: activeTurnID,
                    busy: true,
                    runtimeAuthoritative: true
                ))
            } else if let completedTurnID = self.completedTurnIDsByThread[threadId] {
                self.emit(RemoteEvent(
                    type: RemoteMessage.taskState,
                    threadId: threadId,
                    turnId: completedTurnID,
                    busy: false,
                    runtimeAuthoritative: true
                ))
            }
            if var cached = self.cachedThreadSnapshots[threadId] {
                cached.task = self.lastTaskLists.values
                    .lazy
                    .flatMap { $0 }
                    .first(where: { $0.id == threadId })
                cached.busy = nil
                cached.turnId = nil
                cached.runtimeAuthoritative = false
                self.emit(cached)
            }
            self.loadOpenThreadFromDesktopOrAppServer(threadId)
        }
    }

    private func loadOpenThreadFromDesktopOrAppServer(_ threadId: String) {
        guard watchedThreadIDs.contains(threadId),
              desktopHistoryRequestsInFlight.insert(threadId).inserted else { return }
        let generation = UUID()
        desktopHistoryLoadGenerations[threadId] = generation
        desktopHistoryLoadStartedAt[threadId] = Date()
        attemptDesktopHistoryLoad(threadId, generation: generation, attempt: 0)
    }

    private func attemptDesktopHistoryLoad(
        _ threadId: String,
        generation: UUID,
        attempt: Int
    ) {
        guard watchedThreadIDs.contains(threadId),
              desktopHistoryLoadGenerations[threadId] == generation else {
            finishDesktopHistoryLoad(threadId, generation: generation)
            return
        }
        desktopIPC.loadCompleteHistory(threadID: threadId) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.watchedThreadIDs.contains(threadId),
                      self.desktopHistoryLoadGenerations[threadId] == generation else {
                    self.finishDesktopHistoryLoad(threadId, generation: generation)
                    return
                }
                switch result {
                case .success:
                    self.finishDesktopHistoryLoad(threadId, generation: generation)
                    self.desktopStreamThreadIDs.insert(threadId)
                    self.desktopOwnedThreadIDs.insert(threadId)
                case .failure(let error):
                    let startedAt = self.desktopHistoryLoadStartedAt[threadId] ?? Date()
                    let elapsed = Date().timeIntervalSince(startedAt)
                    if self.desktopHistoryRecoveryPolicy.shouldRetry(
                        error: error,
                        elapsed: elapsed,
                        desktopAppRunning: self.isDesktopCodexRunning,
                        knownDesktopOwner: self.desktopOwnedThreadIDs.contains(threadId)
                    ) {
                        self.scheduleDesktopHistoryRetry(
                            threadId,
                            generation: generation,
                            attempt: attempt + 1
                        )
                        return
                    }
                    self.finishDesktopHistoryLoad(threadId, generation: generation)
                    self.loadOpenThreadFromAppServer(threadId)
                }
            }
        }
    }

    private func scheduleDesktopHistoryRetry(
        _ threadId: String,
        generation: UUID,
        attempt: Int
    ) {
        desktopHistoryRetryWorkItems.removeValue(forKey: threadId)?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.watchedThreadIDs.contains(threadId),
                  self.desktopHistoryLoadGenerations[threadId] == generation else { return }
            self.desktopHistoryRetryWorkItems.removeValue(forKey: threadId)
            self.attemptDesktopHistoryLoad(
                threadId,
                generation: generation,
                attempt: attempt
            )
        }
        desktopHistoryRetryWorkItems[threadId] = workItem
        queue.asyncAfter(
            deadline: .now() + desktopHistoryRecoveryPolicy.retryDelay(afterAttempt: attempt),
            execute: workItem
        )
    }

    private func finishDesktopHistoryLoad(_ threadId: String, generation: UUID) {
        guard desktopHistoryLoadGenerations[threadId] == generation else { return }
        desktopHistoryRetryWorkItems.removeValue(forKey: threadId)?.cancel()
        desktopHistoryLoadGenerations.removeValue(forKey: threadId)
        desktopHistoryLoadStartedAt.removeValue(forKey: threadId)
        desktopHistoryRequestsInFlight.remove(threadId)
    }

    private func loadOpenThreadFromAppServer(_ threadId: String) {
        whenReady {
            let needsRefreshAfterLoad = self.loadedThreads.contains(threadId)
                && self.threadResumeWaiters[threadId] == nil
            self.ensureLoaded(threadId) { [weak self] error in
                guard let self, error == nil, needsRefreshAfterLoad else { return }
                self.readThread(threadId, forceSnapshot: true)
            }
        }
    }

    private var isDesktopCodexRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).isEmpty
    }

    func setWatchedThreads(_ threadIDs: Set<String>) {
        queue.async { [weak self] in
            guard let self else { return }
            let removed = self.watchedThreadIDs.subtracting(threadIDs)
            self.watchedThreadIDs = threadIDs
            self.desktopStreamThreadIDs.formIntersection(threadIDs)
            for threadID in removed {
                self.desktopHistoryRetryWorkItems.removeValue(forKey: threadID)?.cancel()
                self.desktopHistoryLoadGenerations.removeValue(forKey: threadID)
                self.desktopHistoryLoadStartedAt.removeValue(forKey: threadID)
                self.desktopHistoryRequestsInFlight.remove(threadID)
            }
        }
    }

    fileprivate func setDesktopStreamConnected(_ connected: Bool) {
        queue.async { [weak self] in
            guard let self, !connected else { return }
            self.desktopStreamThreadIDs.removeAll()
            for threadID in self.watchedThreadIDs {
                let activeTurnID = self.activeTurns[threadID]
                let isCompanionTurn = activeTurnID.flatMap {
                    self.pendingTurnContexts[$0]
                } != nil
                if isCompanionTurn {
                    self.readThread(threadID, forceSnapshot: true)
                } else {
                    self.loadOpenThreadFromDesktopOrAppServer(threadID)
                }
            }
        }
    }

    fileprivate func receiveDesktopConversationState(
        threadID: String,
        conversation: JSONObject,
        isSnapshot: Bool
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.watchedThreadIDs.contains(threadID) else { return }
            self.desktopStreamThreadIDs.insert(threadID)
            self.desktopOwnedThreadIDs.insert(threadID)
            if let activeTurnID = self.activeTurns[threadID],
               self.pendingTurnContexts[activeTurnID] != nil {
                return
            }
            let thread = self.desktopThread(conversation, threadID: threadID)
            self.captureDesktopSettings(conversation, threadID: threadID)
            self.emitSnapshot(
                thread,
                force: isSnapshot,
                incrementally: !isSnapshot
            )
        }
    }

    func createThread(
        cwd: String?,
        initialPrompt: String?,
        requestId: String?,
        projectId: String?,
        model: String?,
        effort: String?,
        permissionMode: String?,
        planMode: Bool?,
        attachments: [RemoteAttachment],
        skills: [RemoteSkill],
        completion: @escaping (String?, String?, String?) -> Void
    ) {
        queue.async { [weak self] in
            self?.whenReady {
                self?.startThread(
                    cwd: cwd,
                    prompt: initialPrompt,
                    requestId: requestId,
                    projectId: projectId,
                    model: model,
                    effort: effort,
                    permissionMode: permissionMode,
                    planMode: planMode,
                    attachments: attachments,
                    skills: skills,
                    onAccepted: completion
                )
            }
        }
    }

    func sendPrompt(
        _ prompt: String,
        attachments: [RemoteAttachment],
        skills: [RemoteSkill],
        threadId: String?,
        cwd: String?,
        model: String?,
        effort: String?,
        permissionMode: String?,
        planMode: Bool?,
        completion: @escaping (String?, String?, String?) -> Void
    ) {
        queue.async { [weak self] in
            self?.sendPromptWhenReady(
                prompt,
                attachments: attachments,
                skills: skills,
                threadId: threadId,
                cwd: cwd,
                model: model,
                effort: effort,
                permissionMode: permissionMode,
                planMode: planMode,
                completion: completion
            )
        }
    }

    private func sendPromptWhenReady(
        _ prompt: String,
        attachments: [RemoteAttachment],
        skills: [RemoteSkill],
        threadId: String?,
        cwd: String?,
        model: String?,
        effort: String?,
        permissionMode: String?,
        planMode: Bool?,
        completion: @escaping (String?, String?, String?) -> Void
    ) {
        whenReady { [weak self] in
            guard let self else { return }
            if let threadId, !threadId.isEmpty {
                let input: [JSONObject]
                do {
                    input = try self.userInput(
                        prompt: prompt,
                        attachments: attachments,
                        skills: skills,
                        threadId: threadId
                    )
                } catch {
                    self.emitError(error.localizedDescription, threadId: threadId)
                    completion(threadId, nil, error.localizedDescription)
                    return
                }
                if self.shouldUseDesktopWriter(threadId) {
                    self.startDesktopTurn(
                        threadId: threadId,
                        input: input,
                        model: model,
                        effort: effort,
                        permissionMode: permissionMode,
                        planMode: planMode
                    ) { turnID, errorMessage in
                        completion(threadId, turnID, errorMessage)
                    }
                    return
                }
                self.ensureLoaded(threadId) { [weak self] loadError in
                    guard let self else { return }
                    if let loadError {
                        completion(threadId, nil, loadError)
                        return
                    }
                    self.applyModelSettings(threadId: threadId, model: model, effort: effort) { errorMessage in
                        if let errorMessage {
                            self.emitError(errorMessage, threadId: threadId)
                            completion(threadId, nil, errorMessage)
                            return
                        }
                        self.startTurn(
                            threadId: threadId,
                            input: input,
                            model: model,
                            effort: effort,
                            permissionMode: permissionMode,
                            planMode: planMode,
                            onStarted: { turnID, errorMessage in
                                completion(threadId, turnID, errorMessage)
                            }
                        )
                    }
                }
            } else {
                self.startThread(
                    cwd: cwd,
                    prompt: prompt,
                    requestId: nil,
                    model: model,
                    effort: effort,
                    permissionMode: permissionMode,
                    planMode: planMode,
                    attachments: attachments,
                    skills: skills,
                    onAccepted: completion
                )
            }
        }
    }

    fileprivate func interrupt(
        threadId: String,
        turnId: String?,
        completion: @escaping (RemoteInterruptResult) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.whenReady {
                if self.shouldUseDesktopWriter(threadId) {
                    self.interruptDesktopTurn(
                        threadId: threadId,
                        expectedTurnID: turnId,
                        completion: completion
                    )
                    return
                }
                let observedActiveTurnID = self.activeTurns[threadId]
                if let requestedTurnID = turnId,
                   !CompletedTurnInterruptPolicy.shouldContactBackend(
                       requestedTurnID: requestedTurnID,
                       knownCompletedTurnID: self.completedTurnIDsByThread[threadId]
                   ) {
                    let decision = self.markTurnInactiveIfCurrent(
                        threadId: threadId,
                        turnId: requestedTurnID,
                        backendConfirmedNoActive: true
                    )
                    self.emitAuthoritativeTaskState(
                        threadId: threadId,
                        inactiveTurnId: requestedTurnID,
                        decision: decision
                    )
                    completion(.alreadyInactive)
                    self.startNextPostInterruptPrompt(threadId: threadId)
                    return
                }
                if let requestedTurnID = turnId,
                   let observedActiveTurnID,
                   requestedTurnID != observedActiveTurnID {
                    let decision = self.markTurnInactiveIfCurrent(
                        threadId: threadId,
                        turnId: requestedTurnID,
                        backendConfirmedNoActive: false
                    )
                    self.emitAuthoritativeTaskState(
                        threadId: threadId,
                        inactiveTurnId: requestedTurnID,
                        decision: decision
                    )
                    self.readThread(threadId, forceSnapshot: true)
                    completion(.alreadyInactive)
                    return
                }
                guard let id = turnId ?? observedActiveTurnID else {
                    self.updateCachedTaskState(threadId, turnId: nil, busy: false)
                    self.emit(RemoteEvent(
                        type: RemoteMessage.taskState,
                        threadId: threadId,
                        busy: false,
                        runtimeAuthoritative: true
                    ))
                    self.readThread(threadId, forceSnapshot: true)
                    completion(.alreadyInactive)
                    return
                }
                self.recentInterrupts[threadId] = RecentInterrupt(
                    turnID: id,
                    expiresAt: Date().addingTimeInterval(60)
                )
                self.sendInterruptRequest(
                    threadId: threadId,
                    turnId: id,
                    retryAttempt: 0,
                    completion: completion
                )
            }
        }
    }

    private func interruptDesktopTurn(
        threadId: String,
        expectedTurnID: String?,
        completion: @escaping (RemoteInterruptResult) -> Void
    ) {
        desktopIPC.interruptTurn(
            threadID: threadId,
            expectedTurnID: expectedTurnID
        ) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .failure(let error):
                    completion(.failed(error.localizedDescription))
                case .success(let response):
                    let interruptedTurnID = response["interruptedTurnId"] as? String
                    let inactiveTurnID = interruptedTurnID ?? expectedTurnID
                    if let inactiveTurnID {
                        self.completedTurnIDsByThread[threadId] = inactiveTurnID
                    }
                    self.activeTurns.removeValue(forKey: threadId)
                    self.updateCachedTaskState(threadId, turnId: inactiveTurnID, busy: false)
                    self.emit(RemoteEvent(
                        type: RemoteMessage.taskState,
                        threadId: threadId,
                        turnId: inactiveTurnID,
                        busy: false,
                        runtimeAuthoritative: true
                    ))
                    completion(interruptedTurnID == nil ? .alreadyInactive : .interrupted)
                    self.startNextPostInterruptPrompt(threadId: threadId)
                }
            }
        }
    }

    private func sendInterruptRequest(
        threadId: String,
        turnId: String,
        retryAttempt: Int,
        completion: @escaping (RemoteInterruptResult) -> Void
    ) {
        sendRequest(
            method: "turn/interrupt",
            params: ["threadId": threadId, "turnId": turnId]
        ) { [weak self] response in
            guard let self else { return }
            if let error = response["error"] as? JSONObject {
                let message = self.errorMessage(error)
                let noActiveTurn = self.isNoActiveTurnInterruptError(message)
                let shouldRetryNoActiveTurn = noActiveTurn
                    && InterruptNoActiveRetryPolicy.shouldRetry(
                        requestedTurnID: turnId,
                        currentActiveTurnID: self.activeTurns[threadId],
                        hasPendingStartContext: self.pendingTurnContexts[turnId] != nil,
                        retryAttempt: retryAttempt
                    )
                let shouldRetryTurnTransition = InterruptTurnTransitionRetryPolicy.shouldRetry(
                    errorMessage: message,
                    requestedTurnID: turnId,
                    currentActiveTurnID: self.activeTurns[threadId],
                    hasPendingStartContext: self.pendingTurnContexts[turnId] != nil,
                    retryAttempt: retryAttempt
                )
                if shouldRetryNoActiveTurn || shouldRetryTurnTransition {
                    let delay = shouldRetryTurnTransition
                        ? InterruptTurnTransitionRetryPolicy.delayMilliseconds(
                            retryAttempt: retryAttempt
                        )
                        : InterruptNoActiveRetryPolicy.delayMilliseconds(
                            retryAttempt: retryAttempt
                        )
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(delay)) {
                        if self.completedTurnIDsByThread[threadId] == turnId {
                            completion(.alreadyInactive)
                            self.startNextPostInterruptPrompt(threadId: threadId)
                            return
                        }
                        self.sendInterruptRequest(
                            threadId: threadId,
                            turnId: turnId,
                            retryAttempt: retryAttempt + 1,
                            completion: completion
                        )
                    }
                    return
                }
                if noActiveTurn {
                    let decision = self.markTurnInactiveIfCurrent(
                        threadId: threadId,
                        turnId: turnId,
                        backendConfirmedNoActive: true
                    )
                    self.emitAuthoritativeTaskState(
                        threadId: threadId,
                        inactiveTurnId: turnId,
                        decision: decision
                    )
                    self.invalidateDesktop()
                    self.readThread(threadId, forceSnapshot: true)
                    completion(.alreadyInactive)
                    self.startNextPostInterruptPrompt(threadId: threadId)
                    return
                }
                if self.recentInterrupts[threadId]?.turnID == turnId {
                    self.recentInterrupts.removeValue(forKey: threadId)
                }
                self.failDeferredPostInterruptPrompts(threadId: threadId, message: message)
                self.emitError(message, threadId: threadId)
                completion(.failed(message))
            } else {
                self.invalidateDesktop()
                self.readThread(threadId, forceSnapshot: true)
                completion(.interrupted)
            }
        }
    }

    func steer(
        _ prompt: String,
        attachments: [RemoteAttachment],
        skills: [RemoteSkill],
        threadId: String,
        turnId: String?,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: String? = nil,
        planMode: Bool? = nil,
        afterInterrupt: Bool = false,
        completion: @escaping (String?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.whenReady {
                let startAsNewTurn = {
                    self.sendPromptWhenReady(
                        prompt,
                        attachments: attachments,
                        skills: skills,
                        threadId: threadId,
                        cwd: nil,
                        model: model,
                        effort: effort,
                        permissionMode: permissionMode,
                        planMode: planMode
                    ) { _, _, errorMessage in
                        completion(errorMessage)
                    }
                }
                let requestedTurnID = turnId ?? self.activeTurns[threadId]
                if afterInterrupt, self.shouldUseDesktopWriter(threadId) {
                    startAsNewTurn()
                    return
                }
                if afterInterrupt || requestedTurnID.map({
                    self.wasRecentlyInterrupted(threadId: threadId, turnId: $0)
                }) == true {
                    self.enqueuePostInterruptPrompt(
                        DeferredPostInterruptPrompt(
                            prompt: prompt,
                            attachments: attachments,
                            skills: skills,
                            model: model,
                            effort: effort,
                            permissionMode: permissionMode,
                            planMode: planMode,
                            completion: completion
                        ),
                        threadId: threadId
                    )
                    return
                }
                guard let id = requestedTurnID else {
                    startAsNewTurn()
                    return
                }
                let input: [JSONObject]
                do {
                    input = try self.userInput(
                        prompt: prompt,
                        attachments: attachments,
                        skills: skills,
                        threadId: threadId
                    )
                } catch {
                    self.emitError(error.localizedDescription, threadId: threadId)
                    completion(error.localizedDescription)
                    return
                }
                if self.shouldUseDesktopWriter(threadId) {
                    self.steerDesktopTurn(
                        input: input,
                        threadId: threadId,
                        planMode: planMode,
                        completion: completion
                    )
                    return
                }
                self.sendSteerRequest(
                    input: input,
                    threadId: threadId,
                    expectedTurnId: id,
                    mayRerouteOnce: true,
                    startAsNewTurn: startAsNewTurn,
                    completion: completion
                )
            }
        }
    }

    private func steerDesktopTurn(
        input: [JSONObject],
        threadId: String,
        planMode: Bool?,
        completion: @escaping (String?) -> Void
    ) {
        let cwd = settingsByThread[threadId]?.cwd.isEmpty == false
            ? settingsByThread[threadId]!.cwd
            : (threadShell(threadId)["cwd"] as? String ?? "/")
        var context: JSONObject = ["workspaceRoots": [cwd]]
        if let planMode,
           let mode = collaborationMode(planMode, threadId: threadId) {
            context["collaborationMode"] = mode
        }
        let restoreMessage: JSONObject = [
            "cwd": cwd,
            "context": context,
            "responsesapiClientMetadata": ["workspace_kind": "project"] as JSONObject
        ]
        desktopIPC.steerTurn(
            threadID: threadId,
            input: input,
            restoreMessage: restoreMessage,
            additionalContext: attachmentContext(for: input)
        ) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .failure(let error):
                    completion(error.localizedDescription)
                case .success:
                    completion(nil)
                }
            }
        }
    }

    private func sendSteerRequest(
        input: [JSONObject],
        threadId: String,
        expectedTurnId: String,
        mayRerouteOnce: Bool,
        startAsNewTurn: @escaping () -> Void,
        completion: @escaping (String?) -> Void
    ) {
        var params: JSONObject = [
            "threadId": threadId,
            "expectedTurnId": expectedTurnId,
            "input": input
        ]
        if let context = attachmentContext(for: input) {
            params["additionalContext"] = context
        }
        sendRequest(method: "turn/steer", params: params) { [weak self] response in
            guard let self else { return }
            if let error = response["error"] as? JSONObject {
                let message = self.errorMessage(error)
                guard self.isNoActiveTurnSteerError(message) else {
                    self.emitError(message, threadId: threadId)
                    completion(message)
                    return
                }
                let decision = self.markTurnInactiveIfCurrent(
                    threadId: threadId,
                    turnId: expectedTurnId,
                    backendConfirmedNoActive: true
                )
                self.emitAuthoritativeTaskState(
                    threadId: threadId,
                    inactiveTurnId: expectedTurnId,
                    decision: decision
                )
                if case .newerTurn(let newerTurnID) = decision {
                    guard mayRerouteOnce else {
                        completion("任务运行状态再次变化，追加内容已保留，请重试")
                        return
                    }
                    self.sendSteerRequest(
                        input: input,
                        threadId: threadId,
                        expectedTurnId: newerTurnID,
                        mayRerouteOnce: false,
                        startAsNewTurn: startAsNewTurn,
                        completion: completion
                    )
                    return
                }
                startAsNewTurn()
                return
            }
            self.invalidateDesktop()
            completion(nil)
        }
    }

    private func wasRecentlyInterrupted(threadId: String, turnId: String) -> Bool {
        guard let interrupt = recentInterrupts[threadId] else { return false }
        guard interrupt.expiresAt > Date() else {
            recentInterrupts.removeValue(forKey: threadId)
            return false
        }
        return interrupt.turnID == turnId
    }

    private func enqueuePostInterruptPrompt(
        _ prompt: DeferredPostInterruptPrompt,
        threadId: String
    ) {
        deferredPostInterruptPrompts[threadId, default: []].append(prompt)
        startNextPostInterruptPrompt(threadId: threadId)
    }

    private func startNextPostInterruptPrompt(threadId: String) {
        guard activeTurns[threadId] == nil,
              postInterruptPromptInFlight[threadId] == nil,
              var queued = deferredPostInterruptPrompts[threadId],
              !queued.isEmpty else { return }
        let pendingPrompt = queued.removeFirst()
        if queued.isEmpty {
            deferredPostInterruptPrompts.removeValue(forKey: threadId)
        } else {
            deferredPostInterruptPrompts[threadId] = queued
        }
        postInterruptPromptInFlight[threadId] = pendingPrompt
        sendPromptWhenReady(
            pendingPrompt.prompt,
            attachments: pendingPrompt.attachments,
            skills: pendingPrompt.skills,
            threadId: threadId,
            cwd: nil,
            model: pendingPrompt.model,
            effort: pendingPrompt.effort,
            permissionMode: pendingPrompt.permissionMode,
            planMode: pendingPrompt.planMode
        ) { [weak self] _, _, errorMessage in
            guard let self,
                  let completedPrompt = self.postInterruptPromptInFlight.removeValue(forKey: threadId) else { return }
            completedPrompt.completion(errorMessage)
            if errorMessage != nil {
                self.startNextPostInterruptPrompt(threadId: threadId)
            }
        }
    }

    private func failDeferredPostInterruptPrompts(threadId: String? = nil, message: String) {
        let threadIDs: Set<String>
        if let threadId {
            threadIDs = [threadId]
        } else {
            threadIDs = Set(deferredPostInterruptPrompts.keys)
                .union(postInterruptPromptInFlight.keys)
        }
        for threadID in threadIDs {
            let queued = deferredPostInterruptPrompts.removeValue(forKey: threadID) ?? []
            let inFlight = postInterruptPromptInFlight.removeValue(forKey: threadID)
            queued.forEach { $0.completion(message) }
            inFlight?.completion(message)
        }
    }

    func renameThread(_ threadId: String, name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        queue.async { [weak self] in
            self?.whenReady {
                self?.performTaskAction(method: "thread/name/set", threadId: threadId, params: ["threadId": threadId, "name": cleanName], action: "renamed")
            }
        }
    }

    func setPinned(_ threadId: String, pinned: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let previousPinned = self.lastTaskLists.values
                .lazy
                .flatMap { $0 }
                .first(where: { $0.id == threadId })?
                .pinned ?? !pinned
            self.emit(RemoteEvent(
                type: RemoteMessage.taskAction,
                threadId: threadId,
                value: pinned ? "pinned" : "unpinned"
            ))
            self.applyPinnedState(threadId: threadId, pinned: pinned)
            self.desktopState.setThreadPinned(threadId, pinned: pinned) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    switch result {
                    case .success:
                        self.invalidateDesktop()
                        self.listThreads(archived: self.activeArchivedFilter)
                    case .failure(let error):
                        self.emit(RemoteEvent(
                            type: RemoteMessage.taskAction,
                            threadId: threadId,
                            value: pinned ? "unpinned" : "pinned"
                        ))
                        self.applyPinnedState(threadId: threadId, pinned: previousPinned)
                        self.emitError("\(pinned ? "置顶" : "取消置顶")失败：\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func setArchived(_ threadId: String, archived: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.whenReady {
                let action = archived ? "archived" : "unarchived"
                self.sendRequest(
                    method: archived ? "thread/archive" : "thread/unarchive",
                    params: ["threadId": threadId]
                ) { [weak self] response in
                    guard let self else { return }
                    if let error = response["error"] as? JSONObject {
                        self.emitError(self.errorMessage(error))
                        return
                    }
                    guard archived else {
                        self.finishTaskAction(threadId: threadId, action: action)
                        return
                    }
                    self.desktopState.setThreadPinned(threadId, pinned: false) { [weak self] result in
                        guard let self else { return }
                        self.queue.async {
                            if case .failure(let error) = result {
                                self.emitError("任务已归档，但取消置顶同步失败：\(error.localizedDescription)")
                            } else {
                                self.invalidateDesktop()
                            }
                            self.finishTaskAction(threadId: threadId, action: action)
                        }
                    }
                }
            }
        }
    }

    func deleteThread(_ threadId: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.whenReady {
                self.sendRequest(method: "thread/delete", params: ["threadId": threadId]) { [weak self] response in
                    guard let self else { return }
                    if let error = response["error"] as? JSONObject {
                        self.emitError(self.errorMessage(error))
                        return
                    }
                    self.markThreadDeleted(threadId)
                    self.desktopState.removeThreadMetadata(threadId) { [weak self] result in
                        guard let self else { return }
                        self.queue.async {
                            if case .failure(let error) = result {
                                self.emitError("任务已删除，但 Mac 侧栏清理失败：\(error.localizedDescription)")
                            } else {
                                self.invalidateDesktop()
                            }
                            self.finishTaskAction(threadId: threadId, action: "deleted")
                        }
                    }
                }
            }
        }
    }

    func updateSettings(
        threadId: String,
        model: String?,
        effort: String?,
        cwd: String?,
        permissionMode: String?,
        planMode: Bool?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.whenReady {
                var params: JSONObject = ["threadId": threadId]
                if let model, !model.isEmpty { params["model"] = model }
                if let effort, !effort.isEmpty { params["effort"] = effort }
                if let cwd, cwd.hasPrefix("/") { params["cwd"] = cwd }
                if let permissionMode, RemotePermissionMode(rawValue: permissionMode) != nil {
                    self.applyPermissionMode(permissionMode, to: &params, sandboxKey: "sandboxPolicy", clearCustom: true)
                    self.permissionModesByThread[threadId] = permissionMode
                    self.persistPermissionModes()
                }
                if let planMode,
                   let collaborationMode = self.collaborationMode(
                       planMode,
                       threadId: threadId,
                       modelOverride: model,
                       effortOverride: effort
                ) {
                    params["collaborationMode"] = collaborationMode
                }
                if self.shouldUseDesktopWriter(threadId) {
                    var desktopSettings = params
                    desktopSettings.removeValue(forKey: "threadId")
                    self.desktopIPC.updateThreadSettings(
                        threadID: threadId,
                        settings: desktopSettings
                    ) { [weak self] result in
                        guard let self else { return }
                        self.queue.async {
                            switch result {
                            case .failure(let error):
                                self.emitError(error.localizedDescription, threadId: threadId)
                            case .success:
                                self.recordUpdatedSettings(
                                    threadId: threadId,
                                    model: model,
                                    effort: effort,
                                    cwd: cwd,
                                    permissionMode: permissionMode,
                                    planMode: planMode
                                )
                            }
                        }
                    }
                    return
                }
                self.sendRequest(method: "thread/settings/update", params: params) { [weak self] response in
                    guard let self else { return }
                    if let error = response["error"] as? JSONObject {
                        self.emitError(self.errorMessage(error))
                        return
                    }
                    self.recordUpdatedSettings(
                        threadId: threadId,
                        model: model,
                        effort: effort,
                        cwd: cwd,
                        permissionMode: permissionMode,
                        planMode: planMode
                    )
                    self.invalidateDesktop()
                }
            }
        }
    }

    private func recordUpdatedSettings(
        threadId: String,
        model: String?,
        effort: String?,
        cwd: String?,
        permissionMode: String?,
        planMode: Bool?
    ) {
        var settings = settingsByThread[threadId]
            ?? RemoteTaskSettings(threadId: threadId, model: "", effort: nil, cwd: cwd ?? "")
        if let model, !model.isEmpty { settings.model = model }
        if let effort, !effort.isEmpty { settings.effort = effort }
        if let cwd, cwd.hasPrefix("/") { settings.cwd = cwd }
        if let permissionMode, RemotePermissionMode(rawValue: permissionMode) != nil {
            settings.permissionMode = permissionMode
        }
        if let planMode { settings.planMode = planMode }
        settingsByThread[threadId] = settings
        emit(RemoteEvent(type: RemoteMessage.taskSettings, settings: settings, threadId: threadId))
    }

    private func applyModelSettings(
        threadId: String,
        model: String?,
        effort: String?,
        completion: @escaping (String?) -> Void
    ) {
        var params: JSONObject = ["threadId": threadId]
        if let model, !model.isEmpty { params["model"] = model }
        if let effort, !effort.isEmpty { params["effort"] = effort }
        guard params.count > 1 else {
            completion(nil)
            return
        }
        sendRequest(method: "thread/settings/update", params: params) { [weak self] response in
            guard let self else { return }
            if let error = response["error"] as? JSONObject {
                completion(self.errorMessage(error))
                return
            }
            var settings = self.settingsByThread[threadId]
                ?? RemoteTaskSettings(threadId: threadId, model: model ?? "", effort: effort, cwd: "")
            if let model, !model.isEmpty { settings.model = model }
            if let effort, !effort.isEmpty { settings.effort = effort }
            self.settingsByThread[threadId] = settings
            self.emit(RemoteEvent(type: RemoteMessage.taskSettings, settings: settings, threadId: threadId))
            completion(nil)
        }
    }

    private func applyPermissionMode(
        _ rawValue: String?,
        to params: inout JSONObject,
        sandboxKey: String,
        clearCustom: Bool
    ) {
        guard let rawValue, let mode = RemotePermissionMode(rawValue: rawValue) else { return }
        switch mode {
        case .ask, .auto:
            params["approvalPolicy"] = "on-request"
            params["approvalsReviewer"] = mode == .auto ? "auto_review" : "user"
            params[sandboxKey] = sandboxKey == "sandbox"
                ? "workspace-write"
                : [
                    "type": "workspaceWrite",
                    "writableRoots": [],
                    "networkAccess": false,
                    "excludeTmpdirEnvVar": false,
                    "excludeSlashTmp": false
                ] as JSONObject
        case .full:
            params["approvalPolicy"] = "never"
            params["approvalsReviewer"] = "user"
            params[sandboxKey] = sandboxKey == "sandbox"
                ? "danger-full-access"
                : ["type": "dangerFullAccess"] as JSONObject
        case .custom:
            guard clearCustom else { return }
            params["approvalPolicy"] = NSNull()
            params["approvalsReviewer"] = NSNull()
            params[sandboxKey] = NSNull()
        }
    }

    private func collaborationMode(
        _ planMode: Bool,
        threadId: String,
        modelOverride: String? = nil,
        effortOverride: String? = nil
    ) -> JSONObject? {
        let model = modelOverride?.isEmpty == false
            ? modelOverride!
            : (settingsByThread[threadId]?.model.isEmpty == false
                ? settingsByThread[threadId]!.model
                : modelCatalog.first(where: \.isDefault)?.model ?? modelCatalog.first?.model ?? "")
        guard !model.isEmpty else { return nil }
        let effort = effortOverride?.isEmpty == false ? effortOverride : settingsByThread[threadId]?.effort
        return [
            "mode": planMode ? "plan" : "default",
            "settings": [
                "model": model,
                "reasoning_effort": effort ?? NSNull(),
                "developer_instructions": NSNull()
            ] as JSONObject
        ]
    }

    private func persistPermissionModes() {
        UserDefaults.standard.set(permissionModesByThread, forKey: "CodexRemotePermissionModes")
    }

    func answerApproval(requestId: String, decision: String) {
        queue.async { [weak self] in
            guard let self, let approval = self.approvals.removeValue(forKey: requestId) else { return }
            let result: JSONObject
            switch approval.method {
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                let mapped = decision == "approveSession" ? "acceptForSession" : (decision == "approve" ? "accept" : "decline")
                result = ["decision": mapped]
            case "execCommandApproval", "applyPatchApproval":
                let mapped: Any
                if decision == "approveSession" {
                    mapped = "approved_for_session"
                } else if decision == "approve" {
                    mapped = "approved"
                } else {
                    mapped = ["denied": ["rejection": "User declined on Codex Remote"]]
                }
                result = ["decision": mapped]
            case "item/permissions/requestApproval":
                result = decision == "approve"
                    ? ["permissions": approval.params["permissions"] ?? JSONObject(), "scope": "turn"]
                    : ["permissions": JSONObject(), "scope": "turn"]
            default:
                result = JSONObject()
            }
            self.sendResponse(id: approval.rpcID, result: result)
        }
    }

    private func launch() {
        guard shouldRun, process == nil else { return }
        restartWorkItem?.cancel()
        restartWorkItem = nil
        guard let executable = codexExecutable() else {
            emitError("找不到 Codex，可重新安装 ChatGPT/Codex App 后再试")
            scheduleRestart()
            return
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        [
            "CODEX_THREAD_ID",
            "CODEX_PERMISSION_PROFILE",
            "CODEX_CI",
            "CODEX_INTERNAL_ORIGINATOR_OVERRIDE",
            "CODEX_SANDBOX_NETWORK_DISABLED",
            "CODEX_SHELL"
        ].forEach { environment.removeValue(forKey: $0) }
        environment[Self.childMarkerEnvironmentKey] = companionInstanceID
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.captureErrorOutput(data) }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            self?.queue.async {
                guard let self, let process, self.process === process else { return }
                let recoveryMessage = self.appServerRecoveryMessage
                    ?? "Codex 服务连接中断，正在自动恢复"
                self.appServerRecoveryMessage = nil
                self.initializationTimeoutWorkItem?.cancel()
                self.initializationTimeoutWorkItem = nil
                self.clearRecordedAppServerPID(process.processIdentifier)
                self.process = nil
                self.inputPipe = nil
                self.isReady = false
                self.outputBuffer.removeAll(keepingCapacity: false)
                self.outputScanOffset = 0
                self.failDeferredPostInterruptPrompts(message: recoveryMessage)
                let interruptedRequests = self.takePendingRequests()
                self.loadedThreads.removeAll()
                self.activeTurns.removeAll()
                self.companionTurnReconciliationAt.removeAll()
                self.resetAllSnapshotFinalAnswerTracking()
                self.recentInterrupts.removeAll()
                self.completedTurnIDsByThread.removeAll()
                self.syncTimer?.cancel()
                self.syncTimer = nil
                self.taskListRequestInFlight = false
                self.taskListRefreshPending = false
                self.taskCreationRequestsInFlight = 0
                self.threadReadRequestsInFlight.removeAll()
                self.threadReadRefreshPending.removeAll()
                self.threadReadForceRefreshPending.removeAll()
                self.threadSnapshotOnNextLiveItem.removeAll()
                self.threadSnapshotOnNextLiveItemExpiry.values.forEach { $0.cancel() }
                self.threadSnapshotOnNextLiveItemExpiry.removeAll()
                self.threadReadRetryWorkItems.values.forEach { $0.cancel() }
                self.threadReadRetryWorkItems.removeAll()
                self.pendingDesktopRefreshThreads.removeAll()
                self.deletedThreadIDs.removeAll()
                self.pendingTurnContexts.removeAll()
                self.pluginCatalog.removeAll()
                self.pluginSkillsByPath.removeAll()
                self.pluginRequestInFlight = false
                self.activePluginCwd = nil
                self.pluginRefreshPending = false
                self.pendingPluginCwd = nil
                self.completePendingRequests(
                    interruptedRequests,
                    message: recoveryMessage
                )
                self.emit(RemoteEvent(type: RemoteMessage.hello, name: "Codex Remote Mac", version: "0.12", codexReady: false))
                self.emitError(recoveryMessage)
                self.scheduleRestart()
            }
        }

        do {
            try process.run()
            self.process = process
            UserDefaults.standard.set(
                Int(process.processIdentifier),
                forKey: Self.appServerPIDKey
            )
            inputPipe = input
            scheduleInitializationTimeout(for: process)
            sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": ["name": "codex-remote", "title": "Codex Remote", "version": "0.12"],
                    "capabilities": ["experimentalApi": true]
                ]
            ) { [weak self] response in
                guard let self else { return }
                if let error = response["error"] as? JSONObject {
                    self.emitError(self.errorMessage(error))
                    process.terminate()
                    return
                }
                self.initializationTimeoutWorkItem?.cancel()
                self.initializationTimeoutWorkItem = nil
                self.restartAttempt = 0
                self.isReady = true
                self.sendNotification(method: "initialized", params: nil)
                self.emit(RemoteEvent(type: RemoteMessage.hello, name: "Codex Remote Mac", version: "0.12", codexReady: true))
                let actions = self.queuedActions
                self.queuedActions.removeAll()
                actions.forEach { $0() }
                self.listThreads()
                self.listModels()
                self.startSyncTimer()
            }
        } catch {
            self.process = nil
            inputPipe = nil
            emitError("无法启动 Codex 服务：\(error.localizedDescription)")
            scheduleRestart()
        }
    }

    private func scheduleInitializationTimeout(for process: Process) {
        initializationTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak process] in
            guard let self, let process, self.process === process, !self.isReady else { return }
            let detail = self.latestErrorLine()
            self.emitError(detail.map { "Codex 启动超时：\($0)，正在自动恢复" }
                ?? "Codex 启动超时，正在自动恢复")
            process.terminate()
        }
        initializationTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    private func scheduleRestart() {
        guard shouldRun, process == nil, restartWorkItem == nil else { return }
        let delays: [Double] = [1, 2, 4, 8, 15]
        let delay = delays[min(restartAttempt, delays.count - 1)]
        restartAttempt += 1
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.launch()
        }
        restartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func captureErrorOutput(_ data: Data) {
        errorBuffer.append(data)
        if errorBuffer.count > 32 * 1024 {
            errorBuffer.removeFirst(errorBuffer.count - 32 * 1024)
        }
        if let line = latestErrorLine() {
            NSLog("Codex Remote app-server: %@", line)
        }
    }

    private func terminateRecordedAppServer() {
        let recordedPID = UserDefaults.standard.integer(forKey: Self.appServerPIDKey)
        guard recordedPID > 0 else { return }
        let pid = pid_t(recordedPID)
        guard processEnvironmentValue(Self.childMarkerEnvironmentKey, processID: pid) == companionInstanceID else {
            UserDefaults.standard.removeObject(forKey: Self.appServerPIDKey)
            return
        }
        _ = Darwin.kill(pid, SIGTERM)
        UserDefaults.standard.removeObject(forKey: Self.appServerPIDKey)
    }

    private func clearRecordedAppServerPID(_ pid: pid_t?) {
        guard let pid,
              UserDefaults.standard.integer(forKey: Self.appServerPIDKey) == Int(pid) else { return }
        UserDefaults.standard.removeObject(forKey: Self.appServerPIDKey)
    }

    private func latestErrorLine() -> String? {
        guard let text = String(data: errorBuffer, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline)
            .last
            .map(String.init)
            .map { String($0.prefix(600)) }
    }

    private func whenReady(_ action: @escaping () -> Void) {
        if isReady {
            action()
        } else {
            queuedActions.append(action)
            if process == nil { launch() }
        }
    }

    private func listThreads(archived: Bool = false) {
        guard !taskListRequestInFlight else {
            taskListRefreshPending = true
            pendingArchivedFilter = archived
            return
        }
        taskListRequestInFlight = true
        sendRequest(
            method: "thread/list",
            params: ["limit": 100, "sortKey": "updated_at", "sortDirection": "desc", "archived": archived]
        ) { [weak self] response in
            guard let self else { return }
            self.taskListRequestInFlight = false
            let runPendingRefresh = {
                guard self.taskListRefreshPending else { return }
                let nextFilter = self.pendingArchivedFilter
                self.taskListRefreshPending = false
                self.listThreads(archived: nextFilter)
            }
            if let error = response["error"] as? JSONObject {
                self.emitError(self.errorMessage(error))
                runPendingRefresh()
                return
            }
            let result = response["result"] as? JSONObject
            let rawTasks = result?["data"] as? [JSONObject] ?? []
            let projectSnapshot = loadCodexProjectSnapshot()
            let tasks = rawTasks.map { thread -> RemoteTaskSummary in
                let threadID = thread["id"] as? String ?? ""
                if let path = (thread["path"] as? String) ?? (thread["rolloutPath"] as? String),
                   path.hasPrefix("/") {
                    self.rolloutPathsByThreadID[threadID] = path
                }
                let projectID = self.sessionProjectAssignments[threadID]
                    ?? projectSnapshot.threadAssignments[threadID]
                return self.taskSummary(
                    thread,
                    archived: archived,
                    projectId: projectID,
                    projectOrder: projectSnapshot.threadOrders[threadID],
                    pinOrder: projectSnapshot.pinnedThreadOrders[threadID]
                )
            }
            let previous = self.lastTaskLists[archived]
            let previousByID = Dictionary(
                uniqueKeysWithValues: (previous ?? []).map { ($0.id, $0) }
            )
            self.lastTaskLists[archived] = tasks
            if previous != tasks {
                self.emit(RemoteEvent(type: RemoteMessage.tasks, tasks: tasks, archived: archived))
            }
            for watched in self.watchedThreadIDs {
                guard let currentTask = tasks.first(where: { $0.id == watched }) else { continue }
                let needsSnapshot = self.cachedThreadSnapshots[watched] == nil
                    || previousByID[watched] != currentTask
                guard needsSnapshot else { continue }
                let activeTurnID = self.activeTurns[watched]
                let isCompanionTurn = activeTurnID.flatMap { self.pendingTurnContexts[$0] } != nil
                if !isCompanionTurn, !self.desktopStreamThreadIDs.contains(watched) {
                    self.readThread(watched, queueIfBusy: false)
                }
            }
            runPendingRefresh()
        }
    }

    private func startSyncTimer() {
        guard syncTimer == nil else { return }
        lastProjectSnapshot = loadCodexProjectSnapshot()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, self.isReady else { return }
            let snapshot = loadCodexProjectSnapshot()
            if snapshot.projects != self.lastProjectSnapshot.projects {
                self.emit(RemoteEvent(type: RemoteMessage.projects, projects: snapshot.projects))
            }
            self.lastProjectSnapshot = snapshot
            if self.taskCreationRequestsInFlight == 0 {
                self.listThreads(archived: self.activeArchivedFilter)
            }
            if self.threadResumeWaiters.isEmpty {
                let now = Date()
                for watched in self.watchedThreadIDs {
                    let activeTurnID = self.activeTurns[watched]
                    let isCompanionTurn = activeTurnID.flatMap { self.pendingTurnContexts[$0] } != nil
                    if isCompanionTurn {
                        let lastReconciliation = self.companionTurnReconciliationAt[watched]
                            ?? .distantPast
                        guard now.timeIntervalSince(lastReconciliation) >= 6 else { continue }
                        self.companionTurnReconciliationAt[watched] = now
                        self.readThread(
                            watched,
                            queueIfBusy: false,
                            allowDesktopFallback: true
                        )
                    } else {
                        self.companionTurnReconciliationAt.removeValue(forKey: watched)
                        self.readThread(
                            watched,
                            queueIfBusy: false
                        )
                    }
                }
            }
        }
        syncTimer = timer
        timer.resume()
    }

    private func listModels() {
        sendRequest(method: "model/list", params: ["includeHidden": false, "limit": 100]) { [weak self] response in
            guard let self else { return }
            if let error = response["error"] as? JSONObject {
                if !self.useCachedModels() {
                    self.emitError(self.errorMessage(error))
                }
                return
            }
            let result = response["result"] as? JSONObject
            let data = result?["data"] as? [JSONObject] ?? []
            self.modelCatalog = data.compactMap(self.remoteModel)
            if self.modelCatalog.isEmpty, self.useCachedModels() { return }
            self.emitAvailableModels()
        }
    }

    @discardableResult
    private func useCachedModels() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
              let rawModels = root["models"] as? [JSONObject] else { return false }
        let models = rawModels.compactMap { raw -> RemoteModel? in
            guard let model = raw["slug"] as? String, !model.isEmpty,
                  raw["visibility"] as? String != "hide" else { return nil }
            let levels = raw["supported_reasoning_levels"] as? [JSONObject] ?? []
            let efforts = levels.compactMap { level -> RemoteReasoningEffort? in
                guard let value = level["effort"] as? String, !value.isEmpty else { return nil }
                return RemoteReasoningEffort(
                    value: value,
                    detail: level["description"] as? String ?? ""
                )
            }
            return RemoteModel(
                id: model,
                model: model,
                displayName: raw["display_name"] as? String ?? model,
                detail: raw["description"] as? String ?? "",
                isDefault: model == configuredModelID,
                defaultEffort: raw["default_reasoning_level"] as? String
                    ?? efforts.first?.value
                    ?? "medium",
                efforts: efforts
            )
        }
        guard !models.isEmpty else { return false }
        modelCatalog = models
        emitAvailableModels()
        return true
    }

    private func listPlugins(cwd: String?) {
        if pluginRequestInFlight {
            guard cwd != activePluginCwd else { return }
            pluginRefreshPending = true
            pendingPluginCwd = cwd
            return
        }
        pluginRequestInFlight = true
        activePluginCwd = cwd
        pluginRequestGeneration += 1
        let generation = pluginRequestGeneration
        var params: JSONObject = [:]
        if let cwd, cwd.hasPrefix("/") { params["cwds"] = [cwd] }
        sendRequest(method: "plugin/installed", params: params) { [weak self] response in
            guard let self, generation == self.pluginRequestGeneration else { return }
            if let error = response["error"] as? JSONObject {
                self.emitError("读取插件失败：\(self.errorMessage(error))")
                self.finishPluginRequest(generation: generation)
                return
            }
            let result = response["result"] as? JSONObject
            let marketplaces = result?["marketplaces"] as? [JSONObject] ?? []
            var entries: [(summary: JSONObject, marketplaceName: String, marketplacePath: String?)] = []
            for marketplace in marketplaces {
                let marketplaceName = marketplace["name"] as? String ?? "Codex"
                let marketplacePath = marketplace["path"] as? String
                for summary in marketplace["plugins"] as? [JSONObject] ?? [] {
                    guard summary["installed"] as? Bool == true,
                          summary["enabled"] as? Bool == true else { continue }
                    entries.append((summary, marketplaceName, marketplacePath))
                }
            }

            guard !entries.isEmpty else {
                self.publishPlugins([], generation: generation)
                return
            }

            var remaining = entries.count
            var plugins: [RemotePlugin] = []
            let finishOne = {
                remaining -= 1
                if remaining == 0 { self.publishPlugins(plugins, generation: generation) }
            }
            for entry in entries {
                guard let pluginName = entry.summary["name"] as? String, !pluginName.isEmpty else {
                    finishOne()
                    continue
                }
                var readParams: JSONObject = ["pluginName": pluginName]
                if let path = entry.marketplacePath, path.hasPrefix("/") {
                    readParams["marketplacePath"] = path
                } else {
                    readParams["remoteMarketplaceName"] = entry.marketplaceName
                }
                self.sendRequest(method: "plugin/read", params: readParams) { [weak self] readResponse in
                    guard let self, generation == self.pluginRequestGeneration else { return }
                    let detail = (readResponse["result"] as? JSONObject)?["plugin"] as? JSONObject
                    if let plugin = self.remotePlugin(
                        summary: entry.summary,
                        detail: detail,
                        marketplaceName: entry.marketplaceName
                    ) {
                        plugins.append(plugin)
                    }
                    finishOne()
                }
            }
        }
    }

    private func remotePlugin(
        summary originalSummary: JSONObject,
        detail: JSONObject?,
        marketplaceName: String
    ) -> RemotePlugin? {
        let summary = detail?["summary"] as? JSONObject ?? originalSummary
        guard let name = summary["name"] as? String, !name.isEmpty else { return nil }
        let interface = summary["interface"] as? JSONObject
        let displayName = (interface?["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pluginDisplayName = displayName?.isEmpty == false ? displayName! : name
        let pluginDetail = (interface?["shortDescription"] as? String)
            ?? (detail?["description"] as? String)
            ?? marketplaceName
        let rawSkills = detail?["skills"] as? [JSONObject] ?? []
        let skills = rawSkills.compactMap { raw -> RemoteSkill? in
            guard raw["enabled"] as? Bool == true,
                  let skillName = raw["name"] as? String,
                  let path = raw["path"] as? String,
                  path.hasPrefix("/") else { return nil }
            return RemoteSkill(
                name: skillName,
                path: path,
                detail: (raw["shortDescription"] as? String) ?? (raw["description"] as? String) ?? "",
                pluginName: pluginDisplayName
            )
        }
        let rawID = summary["id"] as? String ?? name
        return RemotePlugin(
            id: "\(marketplaceName):\(rawID)",
            name: name,
            displayName: pluginDisplayName,
            detail: pluginDetail,
            skills: skills.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
    }

    private func publishPlugins(_ plugins: [RemotePlugin], generation: Int) {
        guard generation == pluginRequestGeneration else { return }
        pluginCatalog = plugins.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        var skillsByPath: [String: RemoteSkill] = [:]
        for skill in pluginCatalog.flatMap(\.skills) { skillsByPath[skill.path] = skill }
        pluginSkillsByPath = skillsByPath
        emit(RemoteEvent(type: RemoteMessage.plugins, plugins: pluginCatalog))
        finishPluginRequest(generation: generation)
    }

    private func finishPluginRequest(generation: Int) {
        guard generation == pluginRequestGeneration else { return }
        pluginRequestInFlight = false
        activePluginCwd = nil
        guard pluginRefreshPending else { return }
        let cwd = pendingPluginCwd
        pluginRefreshPending = false
        pendingPluginCwd = nil
        listPlugins(cwd: cwd)
    }

    private func readThread(
        _ threadId: String,
        retryAttempt: Int = 0,
        forceSnapshot: Bool = false,
        queueIfBusy: Bool = true,
        allowDesktopFallback: Bool = false
    ) {
        guard !deletedThreadIDs.contains(threadId) else { return }
        if retryAttempt == 0 {
            threadReadRetryWorkItems.removeValue(forKey: threadId)?.cancel()
        }
        if threadResumeWaiters[threadId] != nil {
            if queueIfBusy {
                threadReadRefreshPending.insert(threadId)
                if forceSnapshot { threadReadForceRefreshPending.insert(threadId) }
            }
            return
        }
        let activeTurnID = activeTurns[threadId]
        let isCompanionTurn = activeTurnID.flatMap { pendingTurnContexts[$0] } != nil
        if desktopHistoryRequestsInFlight.contains(threadId),
           !isCompanionTurn, !allowDesktopFallback {
            threadReadRefreshPending.remove(threadId)
            threadReadForceRefreshPending.remove(threadId)
            return
        }
        if desktopStreamThreadIDs.contains(threadId),
           !isCompanionTurn, !forceSnapshot, !allowDesktopFallback {
            threadReadRefreshPending.remove(threadId)
            threadReadForceRefreshPending.remove(threadId)
            return
        }
        guard loadedThreads.contains(threadId) else {
            ensureLoaded(threadId) { [weak self] error in
                guard let self, error == nil else { return }
                self.threadReadRefreshPending.remove(threadId)
                self.threadReadForceRefreshPending.remove(threadId)
                self.refreshDesktopAfterSnapshotIfNeeded(threadId)
            }
            return
        }
        if desktopStreamThreadIDs.contains(threadId), !isCompanionTurn, !forceSnapshot,
           !allowDesktopFallback {
            threadReadRefreshPending.remove(threadId)
            threadReadForceRefreshPending.remove(threadId)
            return
        }
        guard !threadReadRequestsInFlight.contains(threadId) else {
            if queueIfBusy {
                threadReadRefreshPending.insert(threadId)
                if forceSnapshot { threadReadForceRefreshPending.insert(threadId) }
            }
            return
        }
        threadReadRequestsInFlight.insert(threadId)
        let thread = threadShell(threadId)
        sendRequest(
            method: "thread/turns/list",
            params: [
                "threadId": threadId,
                "limit": 24,
                "sortDirection": "desc",
                "itemsView": "summary"
            ]
        ) { [weak self] response in
            guard let self else { return }
            self.threadReadRequestsInFlight.remove(threadId)
            guard !self.deletedThreadIDs.contains(threadId) else {
                self.threadReadRefreshPending.remove(threadId)
                self.threadReadForceRefreshPending.remove(threadId)
                self.threadReadRetryWorkItems.removeValue(forKey: threadId)?.cancel()
                self.pendingDesktopRefreshThreads.remove(threadId)
                return
            }
            let runPendingRead = {
                guard self.threadReadRefreshPending.remove(threadId) != nil else { return }
                let forcePendingSnapshot = self.threadReadForceRefreshPending.remove(threadId) != nil
                self.readThread(threadId, forceSnapshot: forcePendingSnapshot)
            }
            if let error = response["error"] as? JSONObject {
                let message = self.errorMessage(error)
                if self.isTransientThreadReadError(message), retryAttempt < 12 {
                    self.scheduleThreadReadRetry(
                        threadId,
                        attempt: retryAttempt + 1,
                        forceSnapshot: forceSnapshot
                    )
                    return
                }
                self.threadReadRetryWorkItems.removeValue(forKey: threadId)?.cancel()
                self.pendingDesktopRefreshThreads.remove(threadId)
                self.emitError(self.friendlyThreadReadError(message), threadId: threadId)
                runPendingRead()
                return
            }
            guard let result = response["result"] as? JSONObject else {
                if retryAttempt < 12 {
                    self.scheduleThreadReadRetry(
                        threadId,
                        attempt: retryAttempt + 1,
                        forceSnapshot: forceSnapshot
                    )
                    return
                }
                self.threadReadRetryWorkItems.removeValue(forKey: threadId)?.cancel()
                self.pendingDesktopRefreshThreads.remove(threadId)
                self.emitError("这个任务暂时无法读取，请稍后重试", threadId: threadId)
                runPendingRead()
                return
            }
            self.threadReadRetryWorkItems.removeValue(forKey: threadId)?.cancel()
            var hydratedThread = thread
            let newestFirst = result["data"] as? [JSONObject] ?? []
            hydratedThread["turns"] = Array(newestFirst.reversed())
            self.captureSettings(result, threadId: threadId, fallbackCwd: thread["cwd"] as? String)
            self.emitSnapshot(hydratedThread, force: forceSnapshot)
            self.refreshDesktopAfterSnapshotIfNeeded(threadId)
            runPendingRead()
        }
    }

    private func threadShell(_ threadId: String) -> JSONObject {
        let knownTask = lastTaskLists.values
            .lazy
            .flatMap { $0 }
            .first(where: { $0.id == threadId })
            ?? cachedThreadSnapshots[threadId]?.task
        guard let knownTask else { return ["id": threadId] }
        return [
            "id": knownTask.id,
            "name": knownTask.title,
            "preview": knownTask.preview,
            "cwd": knownTask.cwd,
            "updatedAt": knownTask.updatedAt,
            "status": knownTask.status
        ]
    }

    private func refreshDesktopAfterSnapshotIfNeeded(_ threadId: String) {
        guard pendingDesktopRefreshThreads.remove(threadId) != nil else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            guard let self, !self.deletedThreadIDs.contains(threadId) else { return }
            self.refreshActiveThread(threadId)
        }
    }

    private func refreshActiveThread(_ threadId: String) {
        desktopIPC.loadCompleteHistory(threadID: threadId) { [weak self] ipcResult in
            switch ipcResult {
            case .success:
                NSLog("Codex Remote refreshed desktop history through IPC for %@", threadId)
            case .failure(let ipcError):
                NSLog(
                    "Codex Remote desktop IPC refresh failed for %@; trying verified inspector fallback: %@",
                    threadId,
                    ipcError.localizedDescription
                )
                self?.desktopHost.refreshActiveThreadViaInspector(threadID: threadId) { inspectorResult in
                    if case .failure(let inspectorError) = inspectorResult {
                        NSLog(
                            "Codex Remote could not refresh the active desktop task: IPC=%@ inspector=%@",
                            ipcError.localizedDescription,
                            inspectorError.localizedDescription
                        )
                    }
                }
            }
        }
    }

    private func ensureLoaded(_ threadId: String, completion: @escaping (String?) -> Void) {
        if loadedThreads.contains(threadId) {
            completion(nil)
            return
        }
        if threadResumeWaiters[threadId] != nil {
            threadResumeWaiters[threadId]?.append(completion)
            return
        }
        threadResumeWaiters[threadId] = [completion]
        resumeThread(threadId, rolloutPath: rolloutPath(for: threadId))
    }

    private func resumeThread(_ threadId: String, rolloutPath: String?) {
        var params: JSONObject = [
            "threadId": threadId,
            "excludeTurns": true
        ]
        if let rolloutPath { params["path"] = rolloutPath }
        sendRequest(method: "thread/resume", params: params) { [weak self] response in
            guard let self else { return }
            if let error = response["error"] as? JSONObject {
                let message = self.errorMessage(error)
                if DesktopHistoryRecoveryPolicy.isActiveWriterConflict(message) {
                    self.desktopOwnedThreadIDs.insert(threadId)
                    self.finishThreadResume(threadId, error: "desktop-owner")
                    self.loadOpenThreadFromDesktopOrAppServer(threadId)
                    NSLog(
                        "Codex Remote redirected active-writer recovery to desktop IPC for %@",
                        threadId
                    )
                    return
                }
                if rolloutPath == nil,
                   self.isTransientThreadReadError(message),
                   let path = self.rolloutPath(for: threadId) {
                    self.resumeThread(threadId, rolloutPath: path)
                    return
                }
                let friendlyMessage = self.friendlyThreadResumeError(message)
                self.emitError(friendlyMessage, threadId: threadId)
                self.finishThreadResume(threadId, error: friendlyMessage)
                return
            }
            guard let result = response["result"] as? JSONObject,
                  var thread = result["thread"] as? JSONObject else {
                let message = "暂时无法恢复这个任务，聊天记录仍保存在 Mac"
                self.emitError(message, threadId: threadId)
                self.finishThreadResume(threadId, error: message)
                return
            }
            thread["id"] = (thread["id"] as? String) ?? threadId
            self.loadedThreads.insert(threadId)
            self.captureSettings(result, threadId: threadId, fallbackCwd: thread["cwd"] as? String)
            self.loadRecentThreadTurns(threadId: threadId, thread: thread)
        }
    }

    private func loadRecentThreadTurns(threadId: String, thread: JSONObject) {
        sendRequest(
            method: "thread/turns/list",
            params: [
                "threadId": threadId,
                "limit": 24,
                "sortDirection": "desc",
                "itemsView": "summary"
            ]
        ) { [weak self] response in
            guard let self else { return }
            if let error = response["error"] as? JSONObject {
                let message = self.errorMessage(error)
                self.emitSnapshot(thread, force: true)
                self.finishThreadResume(threadId, error: self.userFacingError(message))
                return
            }
            let result = response["result"] as? JSONObject
            let newestFirst = result?["data"] as? [JSONObject] ?? []
            var hydratedThread = thread
            hydratedThread["turns"] = Array(newestFirst.reversed())
            self.emitSnapshot(hydratedThread, force: true)
            self.finishThreadResume(threadId, error: nil)
        }
    }

    private func finishThreadResume(_ threadId: String, error: String?) {
        let completions = threadResumeWaiters.removeValue(forKey: threadId) ?? []
        completions.forEach { $0(error) }
        let refreshPending = threadReadRefreshPending.remove(threadId) != nil
        let forceSnapshot = threadReadForceRefreshPending.remove(threadId) != nil
        if error == nil, refreshPending, forceSnapshot {
            readThread(threadId, forceSnapshot: true)
        }
    }

    private func rolloutPath(for threadId: String) -> String? {
        if let cached = rolloutPathsByThreadID[threadId] { return cached }
        guard !missingRolloutPathThreadIDs.contains(threadId) else { return nil }
        let fileManager = FileManager.default
        let codexRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let roots = ["sessions", "archived_sessions"].map {
            codexRoot.appendingPathComponent($0, isDirectory: true)
        }
        let suffix = "-\(threadId).jsonl"
        for directory in datedSessionDirectories(root: roots[0], threadId: threadId) {
            if let path = matchingRolloutPath(in: directory, suffix: suffix) {
                rolloutPathsByThreadID[threadId] = path
                return path
            }
        }
        if let path = matchingRolloutPath(in: roots[1], suffix: suffix) {
            rolloutPathsByThreadID[threadId] = path
            return path
        }
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(suffix) {
                rolloutPathsByThreadID[threadId] = url.path
                return url.path
            }
        }
        missingRolloutPathThreadIDs.insert(threadId)
        return nil
    }

    private func datedSessionDirectories(root: URL, threadId: String) -> [URL] {
        guard let milliseconds = UInt64(String(threadId.prefix(12)), radix: 16) else { return [] }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return (-1...1).compactMap { offset -> URL? in
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: date) else { return nil }
            let components = calendar.dateComponents([.year, .month, .day], from: candidate)
            guard let year = components.year, let month = components.month, let day = components.day else {
                return nil
            }
            return root
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        }
    }

    private func matchingRolloutPath(in directory: URL, suffix: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries.first(where: { $0.lastPathComponent.hasSuffix(suffix) })?.path
    }

    private func friendlyThreadResumeError(_ message: String) -> String {
        if isTransientThreadReadError(message) {
            return "暂时无法从 Codex 索引恢复这个任务，聊天记录仍保存在 Mac"
        }
        return userFacingError(message)
    }

    private func startThread(
        cwd: String?,
        prompt: String?,
        requestId: String?,
        projectId: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: String? = nil,
        planMode: Bool? = nil,
        attachments: [RemoteAttachment] = [],
        skills: [RemoteSkill] = [],
        onAccepted: ((String?, String?, String?) -> Void)? = nil
    ) {
        let workspace = resolvedWorkspace(cwd)
        taskCreationRequestsInFlight += 1
        var threadParams: JSONObject = ["cwd": workspace, "threadSource": "user"]
        if let model, !model.isEmpty { threadParams["model"] = model }
        applyPermissionMode(permissionMode, to: &threadParams, sandboxKey: "sandbox", clearCustom: false)
        sendRequest(
            method: "thread/start",
            params: threadParams
        ) { [weak self] response in
            guard let self else { return }
            self.taskCreationRequestsInFlight = max(0, self.taskCreationRequestsInFlight - 1)
            if let error = response["error"] as? JSONObject {
                let message = self.errorMessage(error)
                self.emitError(message, requestId: requestId)
                onAccepted?(nil, nil, message)
                return
            }
            guard let result = response["result"] as? JSONObject,
                  let thread = result["thread"] as? JSONObject,
                  let id = thread["id"] as? String else {
                let message = "创建任务失败"
                self.emitError(message, requestId: requestId)
                onAccepted?(nil, nil, message)
                return
            }
            self.loadedThreads.insert(id)
            self.deletedThreadIDs.remove(id)
            let selectedPermissionMode = RemotePermissionMode(rawValue: permissionMode ?? "")?.rawValue
                ?? RemotePermissionMode.custom.rawValue
            self.permissionModesByThread[id] = selectedPermissionMode
            self.persistPermissionModes()
            if let projectId, !projectId.isEmpty {
                self.sessionProjectAssignments[id] = projectId
            } else {
                self.sessionProjectAssignments.removeValue(forKey: id)
            }

            let initialInput: [JSONObject]
            do {
                initialInput = try self.userInput(
                    prompt: prompt ?? "",
                    attachments: attachments,
                    skills: skills,
                    threadId: id
                )
            } catch {
                self.sendRequest(method: "thread/delete", params: ["threadId": id]) { _ in }
                self.emitError(error.localizedDescription, requestId: requestId)
                onAccepted?(id, nil, error.localizedDescription)
                return
            }

            let finishCreation = { [weak self] (readImmediately: Bool) in
                guard let self else { return }
                self.emit(RemoteEvent(
                    type: RemoteMessage.taskAction,
                    requestId: requestId,
                    threadId: id,
                    value: "created"
                ))
                self.publishCreatedTask(
                    thread,
                    projectId: projectId,
                    workspace: workspace,
                    prompt: prompt
                )
                self.captureSettings(result, threadId: id, fallbackCwd: thread["cwd"] as? String)
                self.invalidateDesktop()
                self.listThreads(archived: self.activeArchivedFilter)
                if readImmediately { self.readThread(id) }
            }

            self.desktopState.assignThread(
                id,
                projectID: projectId?.isEmpty == false ? projectId : nil,
                cwd: workspace
            ) { [weak self] syncResult in
                guard let self else { return }
                self.queue.async {
                    if case .failure(let error) = syncResult {
                        let destination = projectId?.isEmpty == false ? "Mac 项目" : "Mac 侧边栏"
                        self.emitError(
                            "任务已创建，但无法同步到\(destination)：\(error.localizedDescription)",
                            threadId: id
                        )
                    }
                    self.invalidateDesktop()
                    self.listThreads(archived: self.activeArchivedFilter)
                }
            }

            finishCreation(false)
            self.applyModelSettings(threadId: id, model: model, effort: effort) { [weak self] settingsError in
                guard let self else { return }
                if let settingsError {
                    self.emitError(settingsError, requestId: requestId)
                    onAccepted?(id, nil, settingsError)
                    return
                }
                guard !initialInput.isEmpty else {
                    self.emitSnapshot(thread)
                    onAccepted?(id, nil, nil)
                    return
                }
                self.startTurn(
                    threadId: id,
                    input: initialInput,
                    model: model,
                    effort: effort,
                    permissionMode: selectedPermissionMode,
                    planMode: planMode
                ) { [weak self] turnID, errorMessage in
                    guard let self else { return }
                    self.readThread(id)
                    if let errorMessage {
                        self.emitError(errorMessage, requestId: requestId)
                    }
                    onAccepted?(id, turnID, errorMessage)
                }
            }
        }
    }

    private func startTurn(
        threadId: String,
        input: [JSONObject],
        fallbackAttempted: Bool = false,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: String? = nil,
        planMode: Bool? = nil,
        onStarted: ((String?, String?) -> Void)? = nil
    ) {
        let params = turnStartParameters(
            threadId: threadId,
            input: input,
            model: model,
            effort: effort,
            permissionMode: permissionMode,
            planMode: planMode
        )
        sendRequest(method: "turn/start", params: params) { [weak self] response in
            guard let self else { return }
            if let error = response["error"] as? JSONObject {
                let message = self.errorMessage(error)
                if let onStarted { onStarted(nil, message) }
                else { self.emitError(message) }
                return
            }
            if let result = response["result"] as? JSONObject,
               let turn = result["turn"] as? JSONObject,
               let turnId = turn["id"] as? String {
                guard TurnStartAdmissionPolicy.shouldActivate(
                    turnID: turnId,
                    knownCompletedTurnID: self.completedTurnIDsByThread[threadId]
                ) else {
                    self.pendingTurnContexts.removeValue(forKey: turnId)
                    onStarted?(turnId, nil)
                    return
                }
                if self.activeTurns[threadId] != turnId {
                    self.clearSnapshotFinalAnswerTracking(threadID: threadId)
                }
                self.activeTurns[threadId] = turnId
                self.companionTurnReconciliationAt[threadId] = Date()
                self.updateCachedTaskState(threadId, turnId: turnId, busy: true)
                self.pendingTurnContexts[turnId] = PendingTurnContext(
                    threadId: threadId,
                    input: input,
                    fallbackAttempted: fallbackAttempted,
                    permissionMode: permissionMode,
                    planMode: planMode
                )
                onStarted?(turnId, nil)
                self.emit(RemoteEvent(type: RemoteMessage.taskState, threadId: threadId, turnId: turnId, busy: true))
                self.invalidateDesktop()
            } else {
                let message = "Codex 没有返回新的运行 ID"
                if let onStarted { onStarted(nil, message) }
                else { self.emitError(message) }
            }
        }
    }

    private func startDesktopTurn(
        threadId: String,
        input: [JSONObject],
        model: String?,
        effort: String?,
        permissionMode: String?,
        planMode: Bool?,
        completion: @escaping (String?, String?) -> Void
    ) {
        let params = turnStartParameters(
            threadId: threadId,
            input: input,
            model: model,
            effort: effort,
            permissionMode: permissionMode,
            planMode: planMode
        )
        desktopIPC.startTurn(threadID: threadId, turnStartParams: params) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .failure(let error):
                    completion(nil, error.localizedDescription)
                case .success(let response):
                    guard let forwarded = response["result"] as? JSONObject,
                          let turn = forwarded["turn"] as? JSONObject,
                          let turnID = turn["id"] as? String,
                          !turnID.isEmpty else {
                        completion(nil, "Codex 桌面端没有返回新的运行 ID")
                        return
                    }
                    self.activeTurns[threadId] = turnID
                    self.updateCachedTaskState(threadId, turnId: turnID, busy: true)
                    self.emit(RemoteEvent(
                        type: RemoteMessage.taskState,
                        threadId: threadId,
                        turnId: turnID,
                        busy: true,
                        runtimeAuthoritative: true
                    ))
                    completion(turnID, nil)
                }
            }
        }
    }

    private func turnStartParameters(
        threadId: String,
        input: [JSONObject],
        model: String?,
        effort: String?,
        permissionMode: String?,
        planMode: Bool?
    ) -> JSONObject {
        var params: JSONObject = [
            "threadId": threadId,
            "input": input
        ]
        if let model, !model.isEmpty { params["model"] = model }
        if let effort, !effort.isEmpty { params["effort"] = effort }
        applyPermissionMode(permissionMode, to: &params, sandboxKey: "sandboxPolicy", clearCustom: true)
        if let planMode,
           let mode = collaborationMode(
               planMode,
               threadId: threadId,
               modelOverride: model,
               effortOverride: effort
           ) {
            params["collaborationMode"] = mode
        }
        if let context = attachmentContext(for: input) {
            params["additionalContext"] = context
        }
        return params
    }

    private func shouldUseDesktopWriter(_ threadId: String) -> Bool {
        let activeTurnID = activeTurns[threadId]
        let isCompanionTurn = activeTurnID.flatMap { pendingTurnContexts[$0] } != nil
        return !isCompanionTurn && (
            desktopStreamThreadIDs.contains(threadId)
                || desktopHistoryRequestsInFlight.contains(threadId)
        )
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        guard outputBuffer.count <= 256 * 1024 * 1024 else {
            outputBuffer.removeAll(keepingCapacity: false)
            outputScanOffset = 0
            emitError("Codex 返回的单条数据超过 256 MB，正在重启本机服务")
            process?.terminate()
            return
        }
        while outputScanOffset < outputBuffer.count {
            let searchStart = outputBuffer.index(outputBuffer.startIndex, offsetBy: outputScanOffset)
            guard let newline = outputBuffer[searchStart...].firstIndex(of: 0x0A) else {
                outputScanOffset = outputBuffer.count
                return
            }
            let line = outputBuffer[..<newline]
            let object = line.isEmpty
                ? nil
                : try? JSONSerialization.jsonObject(with: line) as? JSONObject
            outputBuffer.removeSubrange(...newline)
            outputScanOffset = 0
            if let object { handle(object) }
        }
    }

    private func handle(_ object: JSONObject) {
        if let id = numberID(object["id"]), let request = pending.removeValue(forKey: id) {
            request.timeoutWorkItem.cancel()
            request.completion(object)
            return
        }
        if object["id"] != nil, let method = object["method"] as? String {
            handleServerRequest(object, method: method)
            return
        }
        guard let method = object["method"] as? String else { return }
        let params = object["params"] as? JSONObject ?? [:]
        handleNotification(method, params: params)
    }

    private func handleNotification(_ method: String, params: JSONObject) {
        let threadId = params["threadId"] as? String
        let desktopMutationNotifications: Set<String> = [
            "thread/started",
            "thread/name/updated",
            "thread/status/changed",
            "thread/settings/updated",
            "thread/archived",
            "thread/unarchived",
            "thread/deleted",
            "turn/started",
            "turn/completed",
            "item/started",
            "item/completed",
            "item/agentMessage/delta",
            "item/commandExecution/outputDelta",
            "turn/plan/updated",
            "turn/diff/updated"
        ]
        if desktopMutationNotifications.contains(method) { invalidateDesktop() }
        switch method {
        case "thread/started":
            if let thread = params["thread"] as? JSONObject { emitSnapshot(thread) }
            listThreads(archived: activeArchivedFilter)
        case "thread/name/updated", "thread/status/changed":
            listThreads(archived: activeArchivedFilter)
        case "thread/settings/updated":
            if let threadId, let raw = params["threadSettings"] as? JSONObject {
                let settings = taskSettings(raw, threadId: threadId)
                settingsByThread[threadId] = settings
                emit(RemoteEvent(type: RemoteMessage.taskSettings, settings: settings, threadId: threadId))
            }
        case "thread/archived", "thread/unarchived", "thread/deleted":
            if method == "thread/deleted", let threadId {
                markThreadDeleted(threadId)
            }
            listThreads(archived: activeArchivedFilter)
        case "turn/started":
            if let threadId,
               let turn = params["turn"] as? JSONObject,
               let turnId = turn["id"] as? String {
                guard TurnStartAdmissionPolicy.shouldActivate(
                    turnID: turnId,
                    knownCompletedTurnID: completedTurnIDsByThread[threadId]
                ) else { return }
                if activeTurns[threadId] != turnId {
                    clearSnapshotFinalAnswerTracking(threadID: threadId)
                }
                completedTurnIDsByThread.removeValue(forKey: threadId)
                activeTurns[threadId] = turnId
                companionTurnReconciliationAt[threadId] = Date()
                updateCachedTaskState(threadId, turnId: turnId, busy: true)
                publishPlan([], explanation: nil, threadId: threadId)
                emit(RemoteEvent(
                    type: RemoteMessage.taskState,
                    threadId: threadId,
                    turnId: turnId,
                    busy: true,
                    runtimeAuthoritative: true
                ))
            }
        case "turn/completed":
            let turn = params["turn"] as? JSONObject
            let completedTurnID = turn?["id"] as? String ?? params["turnId"] as? String
            let context = completedTurnID.flatMap { pendingTurnContexts.removeValue(forKey: $0) }
            if let completedThreadID = threadId ?? context?.threadId {
                if let completedTurnID {
                    let decision = markTurnInactiveIfCurrent(
                        threadId: completedThreadID,
                        turnId: completedTurnID,
                        backendConfirmedNoActive: false
                    )
                    if decision == .changed {
                        emitAuthoritativeTaskState(
                            threadId: completedThreadID,
                            inactiveTurnId: completedTurnID,
                            decision: decision
                        )
                        startNextPostInterruptPrompt(threadId: completedThreadID)
                    }
                }
                var shouldRefreshDesktop = true
                if let message = turnCompletionError(params),
                   recoverUnsupportedModel(
                       from: message,
                       threadId: completedThreadID,
                       turnId: completedTurnID,
                       context: context
                   ) {
                    shouldRefreshDesktop = false
                } else if let message = turnCompletionError(params) {
                    emitError(userFacingError(message), threadId: completedThreadID)
                }
                if shouldRefreshDesktop {
                    pendingDesktopRefreshThreads.insert(completedThreadID)
                }
                readThread(completedThreadID)
            }
            listThreads(archived: activeArchivedFilter)
        case "item/started", "item/completed":
            if let threadId, let itemJSON = params["item"] as? JSONObject, let item = transcriptItem(itemJSON) {
                mergeCachedItem(item, threadId: threadId)
                emit(RemoteEvent(type: RemoteMessage.taskItem, item: item, threadId: threadId, turnId: params["turnId"] as? String))
            }
        case "item/agentMessage/delta":
            emit(RemoteEvent(
                type: RemoteMessage.taskDelta,
                threadId: threadId,
                turnId: params["turnId"] as? String,
                itemId: params["itemId"] as? String,
                delta: params["delta"] as? String
            ))
        case "item/commandExecution/outputDelta":
            emit(RemoteEvent(
                type: RemoteMessage.taskDelta,
                threadId: threadId,
                turnId: params["turnId"] as? String,
                itemId: params["itemId"] as? String,
                delta: params["delta"] as? String
            ))
        case "turn/plan/updated":
            guard let threadId else { return }
            let plan = (params["plan"] as? [JSONObject] ?? []).compactMap { value -> RemotePlanStep? in
                guard let step = value["step"] as? String,
                      let status = value["status"] as? String else { return nil }
                return RemotePlanStep(step: step, status: status)
            }
            publishPlan(plan, explanation: params["explanation"] as? String, threadId: threadId)
        case "turn/diff/updated":
            if let threadId, let diff = params["diff"] as? String,
               var cached = cachedThreadSnapshots[threadId] {
                cached.diff = diff
                cachedThreadSnapshots[threadId] = cached
                scheduleSnapshotCacheSave()
            }
            emit(RemoteEvent(
                type: RemoteMessage.taskDiff,
                threadId: threadId,
                turnId: params["turnId"] as? String,
                diff: params["diff"] as? String
            ))
        case "error":
            if activeTurns.isEmpty, let message = nestedErrorMessage(params) {
                emitError(userFacingError(message), threadId: threadId)
            }
        default:
            break
        }
    }

    private func publishPlan(_ plan: [RemotePlanStep], explanation: String?, threadId: String) {
        plansByThread[threadId] = plan
        if let explanation, !explanation.isEmpty {
            planExplanationsByThread[threadId] = explanation
        } else {
            planExplanationsByThread.removeValue(forKey: threadId)
        }
        if var cached = cachedThreadSnapshots[threadId] {
            cached.plan = plan
            cached.planExplanation = planExplanationsByThread[threadId]
            cachedThreadSnapshots[threadId] = cached
            scheduleSnapshotCacheSave()
        }
        emit(RemoteEvent(
            type: RemoteMessage.taskPlan,
            threadId: threadId,
            plan: plan,
            planExplanation: planExplanationsByThread[threadId]
        ))
    }

    private func handleServerRequest(_ object: JSONObject, method: String) {
        guard let rpcID = object["id"] else { return }
        let params = object["params"] as? JSONObject ?? [:]
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let command = params["command"] as? String
                ?? (params["command"] as? [String])?.joined(separator: " ")
                ?? "命令执行"
            publishApproval(rpcID: rpcID, method: method, params: params, title: "Codex 请求执行命令", detail: command, allowsSession: true)
        case "item/fileChange/requestApproval", "applyPatchApproval":
            let reason = params["reason"] as? String ?? "Codex 请求修改工作区文件"
            publishApproval(rpcID: rpcID, method: method, params: params, title: "Codex 请求修改文件", detail: reason, allowsSession: true)
        case "item/permissions/requestApproval":
            let reason = params["reason"] as? String ?? "Codex 请求本次任务的额外权限"
            publishApproval(rpcID: rpcID, method: method, params: params, title: "Codex 请求权限", detail: reason, allowsSession: false)
        default:
            sendResponse(id: rpcID, errorCode: -32601, message: "Codex Remote does not support this interactive request yet")
            emitError("任务需要一种尚未支持的交互，请稍后在 Mac 上处理")
        }
    }

    private func publishApproval(rpcID: Any, method: String, params: JSONObject, title: String, detail: String, allowsSession: Bool) {
        let id = UUID().uuidString
        approvals[id] = (rpcID, method, params)
        emit(RemoteEvent(
            type: RemoteMessage.approval,
            approval: RemoteApproval(
                id: id,
                threadId: params["threadId"] as? String ?? params["conversationId"] as? String,
                title: title,
                detail: detail,
                allowsSessionApproval: allowsSession
            )
        ))
    }

    private func sendRequest(method: String, params: JSONObject, completion: @escaping (JSONObject) -> Void) {
        requestID += 1
        let id = requestID
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.expireRequest(id: id)
        }
        pending[id] = PendingRequest(
            method: method,
            completion: completion,
            timeoutWorkItem: timeoutWorkItem
        )
        queue.asyncAfter(
            deadline: .now() + requestTimeout(for: method),
            execute: timeoutWorkItem
        )
        sendJSON(["method": method, "id": id, "params": params])
    }

    private func requestTimeout(for method: String) -> TimeInterval {
        switch method {
        case "initialize", "thread/read", "thread/resume", "thread/turns/list": return 20
        default: return 8
        }
    }

    private func expireRequest(id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutWorkItem.cancel()
        let shouldRestart = shouldRestartAppServerAfterTimeout(method: request.method)
        let message = shouldRestart
            ? "Codex 请求超时（\(request.method)），正在自动恢复"
            : "Codex 请求超时（\(request.method)），稍后自动重试"
        if shouldRestart { appServerRecoveryMessage = message }
        request.completion([
            "id": id,
            "error": [
                "code": -32_001,
                "message": message
            ] as JSONObject
        ])
        if shouldRestart { process?.terminate() }
    }

    private func shouldRestartAppServerAfterTimeout(method: String) -> Bool {
        switch method {
        case "initialize", "thread/start", "thread/resume", "turn/start", "turn/steer", "turn/interrupt":
            return true
        default:
            return false
        }
    }

    private func takePendingRequests() -> [PendingRequest] {
        let requests = Array(pending.values)
        pending.removeAll()
        requests.forEach { $0.timeoutWorkItem.cancel() }
        return requests
    }

    private func completePendingRequests(_ requests: [PendingRequest], message: String) {
        for request in requests {
            request.completion([
                "error": ["code": -32_002, "message": message] as JSONObject
            ])
        }
    }

    private func performTaskAction(method: String, threadId: String, params: JSONObject, action: String) {
        sendRequest(method: method, params: params) { [weak self] response in
            guard let self else { return }
            if let error = response["error"] as? JSONObject {
                self.emitError(self.errorMessage(error))
                return
            }
            self.finishTaskAction(threadId: threadId, action: action)
        }
    }

    private func finishTaskAction(threadId: String, action: String) {
        if action == "deleted" {
            markThreadDeleted(threadId)
        }
        emit(RemoteEvent(type: RemoteMessage.taskAction, threadId: threadId, value: action))
        invalidateDesktop()
        listThreads(archived: activeArchivedFilter)
    }

    private func markThreadDeleted(_ threadId: String) {
        deletedThreadIDs.insert(threadId)
        watchedThreadIDs.remove(threadId)
        loadedThreads.remove(threadId)
        desktopStreamThreadIDs.remove(threadId)
        desktopHistoryRequestsInFlight.remove(threadId)
        desktopHistoryRetryWorkItems.removeValue(forKey: threadId)?.cancel()
        desktopHistoryLoadGenerations.removeValue(forKey: threadId)
        desktopHistoryLoadStartedAt.removeValue(forKey: threadId)
        desktopOwnedThreadIDs.remove(threadId)
        activeTurns.removeValue(forKey: threadId)
        companionTurnReconciliationAt.removeValue(forKey: threadId)
        clearSnapshotFinalAnswerTracking(threadID: threadId)
        recentInterrupts.removeValue(forKey: threadId)
        failDeferredPostInterruptPrompts(threadId: threadId, message: "这个任务已被删除")
        completedTurnIDsByThread.removeValue(forKey: threadId)
        settingsByThread.removeValue(forKey: threadId)
        permissionModesByThread.removeValue(forKey: threadId)
        persistPermissionModes()
        sessionProjectAssignments.removeValue(forKey: threadId)
        plansByThread.removeValue(forKey: threadId)
        planExplanationsByThread.removeValue(forKey: threadId)
        cachedThreadSnapshots.removeValue(forKey: threadId)
        threadReadRefreshPending.remove(threadId)
        threadReadForceRefreshPending.remove(threadId)
        threadSnapshotOnNextLiveItem.remove(threadId)
        threadSnapshotOnNextLiveItemExpiry.removeValue(forKey: threadId)?.cancel()
        threadReadRetryWorkItems.removeValue(forKey: threadId)?.cancel()
        pendingDesktopRefreshThreads.remove(threadId)
        pendingTurnContexts = pendingTurnContexts.filter { $0.value.threadId != threadId }
        scheduleSnapshotCacheSave()
    }

    private func applyPinnedState(threadId: String, pinned: Bool) {
        for archived in Array(lastTaskLists.keys) {
            guard var tasks = lastTaskLists[archived],
                  let index = tasks.firstIndex(where: { $0.id == threadId }),
                  tasks[index].pinned != pinned else { continue }
            tasks[index].pinned = pinned
            tasks[index].pinOrder = pinned ? (tasks[index].pinOrder ?? 0) : nil
            lastTaskLists[archived] = tasks
            emit(RemoteEvent(type: RemoteMessage.tasks, tasks: tasks, archived: archived))
        }
    }

    private func publishCreatedTask(
        _ thread: JSONObject,
        projectId: String?,
        workspace: String,
        prompt: String?
    ) {
        guard var tasks = lastTaskLists[false] else { return }
        var optimisticThread = thread
        if (optimisticThread["cwd"] as? String)?.isEmpty != false {
            optimisticThread["cwd"] = workspace
        }
        let cleanPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preview = (optimisticThread["preview"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if preview.isEmpty, !cleanPrompt.isEmpty {
            optimisticThread["preview"] = cleanPrompt
        }
        if number(optimisticThread["updatedAt"]) == nil,
           number(optimisticThread["createdAt"]) == nil {
            optimisticThread["createdAt"] = Date().timeIntervalSince1970
        }

        let summary = taskSummary(
            optimisticThread,
            projectId: projectId?.isEmpty == false ? projectId : nil,
            projectOrder: 0
        )
        tasks.removeAll { $0.id == summary.id }
        tasks.insert(summary, at: 0)
        lastTaskLists[false] = tasks
        emit(RemoteEvent(type: RemoteMessage.tasks, tasks: tasks, archived: false))
    }

    private func sendNotification(method: String, params: JSONObject?) {
        var object: JSONObject = ["method": method]
        if let params { object["params"] = params }
        sendJSON(object)
    }

    private func sendResponse(id: Any, result: JSONObject) {
        sendJSON(["id": id, "result": result])
    }

    private func sendResponse(id: Any, errorCode: Int, message: String) {
        sendJSON(["id": id, "error": ["code": errorCode, "message": message]])
    }

    private func sendJSON(_ object: JSONObject) {
        guard let handle = inputPipe?.fileHandleForWriting,
              JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
        } catch {
            emitError("Codex 服务连接已断开")
        }
    }

    private func desktopThread(_ conversation: JSONObject, threadID: String) -> JSONObject {
        var thread = conversation
        thread["id"] = threadID
        thread["turns"] = desktopTurns(conversation)

        let knownTask = lastTaskLists.values
            .lazy
            .flatMap { $0 }
            .first(where: { $0.id == threadID })
        if let title = conversation["title"] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            thread["name"] = title
        } else if let knownTask {
            thread["name"] = knownTask.title
        }
        if (thread["preview"] as? String)?.isEmpty != false, let knownTask {
            thread["preview"] = knownTask.preview
        }
        if (thread["cwd"] as? String)?.isEmpty != false, let knownTask {
            thread["cwd"] = knownTask.cwd
        }
        if let knownTask, knownTask.updatedAt > 0 {
            thread["updatedAt"] = knownTask.updatedAt
        }
        if let runtimeStatus = conversation["threadRuntimeStatus"] {
            thread["status"] = runtimeStatus
        } else if let knownTask {
            thread["status"] = knownTask.status
        }
        return thread
    }

    private func desktopTurns(_ conversation: JSONObject) -> [JSONObject] {
        guard let turnHistory = conversation["turnHistory"] as? JSONObject,
              let history = turnHistory["history"] as? JSONObject,
              let entities = history["entitiesByKey"] as? [String: Any] else {
            return conversation["turns"] as? [JSONObject] ?? []
        }

        var turns: [JSONObject] = []
        var seen = Set<String>()
        let islands = history["islands"] as? [JSONObject] ?? []
        for island in islands {
            for entry in island["entries"] as? [JSONObject] ?? [] {
                guard let key = entry["value"] as? String ?? entry["key"] as? String,
                      seen.insert(key).inserted,
                      var turn = entities[key] as? JSONObject,
                      turn["items"] is [JSONObject] else { continue }
                turn["id"] = turn["turnId"] as? String ?? key
                turns.append(turn)
            }
        }
        if !turns.isEmpty { return turns }

        return entities.compactMap { key, value -> JSONObject? in
            guard var turn = value as? JSONObject, turn["items"] is [JSONObject] else { return nil }
            turn["id"] = turn["turnId"] as? String ?? key
            return turn
        }.sorted {
            let left = ($0["turnStartedAtMs"] as? NSNumber)?.doubleValue ?? 0
            let right = ($1["turnStartedAtMs"] as? NSNumber)?.doubleValue ?? 0
            return left < right
        }
    }

    private func captureDesktopSettings(_ conversation: JSONObject, threadID: String) {
        var result = conversation["latestThreadSettings"] as? JSONObject ?? [:]
        if let model = conversation["latestModel"] as? String { result["model"] = model }
        if let effort = conversation["latestReasoningEffort"] as? String {
            result["reasoningEffort"] = effort
        }
        if let cwd = conversation["cwd"] as? String { result["cwd"] = cwd }
        if let collaborationMode = conversation["latestCollaborationMode"] as? JSONObject {
            result["collaborationMode"] = collaborationMode
        }
        captureSettings(result, threadId: threadID, fallbackCwd: conversation["cwd"] as? String)
    }

    private func clearSnapshotFinalAnswerTracking(
        threadID: String,
        turnID: String? = nil
    ) {
        snapshotFinalAnswerGate.clear(threadID: threadID, turnID: turnID)
        guard let recheck = finalAnswerRechecks[threadID],
              turnID == nil || recheck.turnID == turnID else { return }
        recheck.workItem.cancel()
        finalAnswerRechecks.removeValue(forKey: threadID)
    }

    private func resetAllSnapshotFinalAnswerTracking() {
        snapshotFinalAnswerGate.clearAll()
        finalAnswerRechecks.values.forEach { $0.workItem.cancel() }
        finalAnswerRechecks.removeAll()
    }

    private func scheduleSnapshotFinalAnswerRecheck(
        threadID: String,
        turnID: String
    ) {
        if let existing = finalAnswerRechecks[threadID] {
            guard existing.turnID != turnID else { return }
            existing.workItem.cancel()
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.finalAnswerRechecks[threadID]?.turnID == turnID else { return }
            self.finalAnswerRechecks.removeValue(forKey: threadID)
            guard self.activeTurns[threadID] == turnID else {
                self.snapshotFinalAnswerGate.clear(threadID: threadID, turnID: turnID)
                return
            }
            self.readThread(
                threadID,
                forceSnapshot: true,
                allowDesktopFallback: true
            )
        }
        finalAnswerRechecks[threadID] = FinalAnswerRecheck(
            turnID: turnID,
            workItem: workItem
        )
        queue.asyncAfter(
            deadline: .now() + SnapshotFinalAnswerGate.defaultGracePeriod + 0.05,
            execute: workItem
        )
    }

    private func emitSnapshot(
        _ thread: JSONObject,
        force: Bool = false,
        incrementally: Bool = false
    ) {
        let threadID = thread["id"] as? String ?? ""
        let projectSnapshot = loadCodexProjectSnapshot()
        let projectID = sessionProjectAssignments[threadID]
            ?? projectSnapshot.threadAssignments[threadID]
        let summary = taskSummary(
            thread,
            projectId: projectID,
            projectOrder: projectSnapshot.threadOrders[threadID],
            pinOrder: projectSnapshot.pinnedThreadOrders[threadID]
        )
        let turns = thread["turns"] as? [JSONObject] ?? []
        let rawItems = recentRawTranscriptItems(from: turns)
        let recentItems = mobileTranscriptItems(from: rawItems)
        let latestTurn = turns.last
        let latestRawItems = latestTurn?["items"] as? [JSONObject] ?? []
        let latestTurnItems = latestRawItems.suffix(300).compactMap(transcriptItem)
        let latestDiff = latestTurnItems
            .flatMap { $0.files ?? [] }
            .map(\.diff)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        let previousSnapshot = cachedThreadSnapshots[summary.id]
        let items = mergeSnapshotItems(
            previous: previousSnapshot?.items ?? [],
            recent: recentItems
        )
        let latestTurnID = latestTurn?["id"] as? String
        let latestStatus = latestTurn?["status"] as? String
        let latestUserIndex = latestRawItems.lastIndex {
            $0["type"] as? String == "userMessage"
        }
        let currentRawItems = latestUserIndex.map {
            Array(latestRawItems[$0...])
        } ?? latestRawItems
        let hasFinalAnswer = currentRawItems.contains { item in
            guard item["type"] as? String == "agentMessage",
                  let text = item["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            let phase = item["phase"] as? String
            return phase == "final_answer" || phase == "finalAnswer"
        }
        let hasTurnError = latestTurn?["error"] != nil && !(latestTurn?["error"] is NSNull)
        let observedActiveTurnID = activeTurns[summary.id]
        let finalAnswerIsTerminal = snapshotFinalAnswerGate.shouldTreatAsTerminal(
            threadID: summary.id,
            turnID: latestTurnID,
            observedActiveTurnID: observedActiveTurnID,
            hasFinalAnswer: hasFinalAnswer,
            now: ProcessInfo.processInfo.systemUptime
        )
        let statusForActivity = SnapshotTerminalStatusPolicy.statusForResolution(
            latestTurnID: latestTurnID,
            rawStatus: latestStatus,
            observedActiveTurnID: observedActiveTurnID,
            hasTerminalEvidence: finalAnswerIsTerminal || hasTurnError
        )
        let activity = TurnActivityResolver.resolve(
            latestTurnID: latestTurnID,
            rawStatus: statusForActivity,
            observedActiveTurnID: observedActiveTurnID,
            knownCompletedTurnID: completedTurnIDsByThread[summary.id],
            hasFinalAnswer: finalAnswerIsTerminal,
            hasError: hasTurnError
        )
        if let inactiveTurnID = activity.inactiveTurnID {
            clearSnapshotFinalAnswerTracking(
                threadID: summary.id,
                turnID: inactiveTurnID
            )
            completedTurnIDsByThread[summary.id] = inactiveTurnID
            if observedActiveTurnID == inactiveTurnID {
                pendingTurnContexts.removeValue(forKey: inactiveTurnID)
                let decision = markTurnInactiveIfCurrent(
                    threadId: summary.id,
                    turnId: inactiveTurnID,
                    backendConfirmedNoActive: true
                )
                emitAuthoritativeTaskState(
                    threadId: summary.id,
                    inactiveTurnId: inactiveTurnID,
                    decision: decision
                )
                pendingDesktopRefreshThreads.insert(summary.id)
                startNextPostInterruptPrompt(threadId: summary.id)
            }
        } else if hasFinalAnswer,
                  !finalAnswerIsTerminal,
                  let latestTurnID,
                  observedActiveTurnID == latestTurnID {
            scheduleSnapshotFinalAnswerRecheck(
                threadID: summary.id,
                turnID: latestTurnID
            )
        }
        if let activeTurnID = activity.activeTurnID {
            activeTurns[summary.id] = activeTurnID
        } else if activeTurns[summary.id] == latestTurnID {
            activeTurns.removeValue(forKey: summary.id)
            companionTurnReconciliationAt.removeValue(forKey: summary.id)
        }
        let activeTurnID = activeTurns[summary.id]
        let busy = activeTurnID != nil
        let knownCompleted = latestTurnID != nil && completedTurnIDsByThread[summary.id] == latestTurnID
        let event = RemoteEvent(
            type: RemoteMessage.taskSnapshot,
            task: summary,
            settings: settingsByThread[summary.id],
            items: items,
            threadId: summary.id,
            turnId: activeTurnID,
            busy: busy,
            runtimeAuthoritative: true,
            diff: latestDiff.isEmpty ? previousSnapshot?.diff : latestDiff,
            plan: plansByThread[summary.id] ?? previousSnapshot?.plan,
            planExplanation: planExplanationsByThread[summary.id] ?? previousSnapshot?.planExplanation
        )
        if !force, knownCompleted,
           let previousItems = previousSnapshot?.items,
           snapshotItemsRegress(previous: previousItems, next: items) {
            return
        }
        let snapshotChanged = event != previousSnapshot
        guard force || snapshotChanged else { return }
        if snapshotChanged {
            cachedThreadSnapshots[summary.id] = event
            scheduleSnapshotCacheSave()
        }
        if incrementally, snapshotChanged, let previousSnapshot {
            emitIncrementalSnapshot(previous: previousSnapshot, next: event)
            return
        }
        emit(event)
    }

    private func recentRawTranscriptItems(
        from turns: [JSONObject],
        limit: Int = 300
    ) -> [JSONObject] {
        var newestFirst: [JSONObject] = []
        newestFirst.reserveCapacity(limit)
        outer: for turn in turns.reversed() {
            for item in (turn["items"] as? [JSONObject] ?? []).reversed() {
                newestFirst.append(item)
                if newestFirst.count == limit { break outer }
            }
        }
        return Array(newestFirst.reversed())
    }

    private func mergeSnapshotItems(
        previous: [RemoteTranscriptItem],
        recent: [RemoteTranscriptItem]
    ) -> [RemoteTranscriptItem] {
        mobileTranscriptItems(SnapshotItemMergePolicy.merge(previous: previous, recent: recent))
    }

    private func emitIncrementalSnapshot(previous: RemoteEvent, next: RemoteEvent) {
        let previousItems = previous.items ?? []
        let nextItems = next.items ?? []
        let previousByID = Dictionary(uniqueKeysWithValues: previousItems.map { ($0.id, $0) })
        let invalidRemoval = !retainsPreviousOrderAfterLeadingTrim(
            previous: previousItems,
            next: nextItems
        )
        let changedItems = nextItems.filter { item in
            guard let previousItem = previousByID[item.id] else { return true }
            guard previousItem != item else { return false }
            if previousItem.kind == "file", item.kind == "file" {
                return previousItem.status != item.status
            }
            return true
        }
        guard !invalidRemoval, changedItems.count <= 32 else {
            emit(next)
            return
        }
        if previous.busy != next.busy || previous.turnId != next.turnId {
            emit(RemoteEvent(
                type: RemoteMessage.taskState,
                threadId: next.threadId,
                turnId: next.turnId,
                busy: next.busy
            ))
        }
        for item in changedItems {
            emit(RemoteEvent(
                type: RemoteMessage.taskItem,
                item: item,
                threadId: next.threadId,
                turnId: next.turnId
            ))
        }
        if previous.diff != next.diff {
            emit(RemoteEvent(
                type: RemoteMessage.taskDiff,
                threadId: next.threadId,
                turnId: next.turnId,
                diff: next.diff
            ))
        }
        if previous.plan != next.plan || previous.planExplanation != next.planExplanation {
            emit(RemoteEvent(
                type: RemoteMessage.taskPlan,
                threadId: next.threadId,
                plan: next.plan,
                planExplanation: next.planExplanation
            ))
        }
    }

    private func restoreSnapshotCache() {
        guard let data = try? Data(contentsOf: snapshotCacheURL),
              let cache = try? RemoteJSON.decoder.decode(SnapshotCacheEnvelope.self, from: data),
              cache.version == 1 else { return }
        cachedThreadSnapshots = cache.snapshots.mapValues { snapshot in
            var restored = snapshot
            restored.busy = nil
            restored.turnId = nil
            restored.runtimeAuthoritative = false
            return restored
        }
        for (threadID, snapshot) in cachedThreadSnapshots {
            if let plan = snapshot.plan { plansByThread[threadID] = plan }
            if let explanation = snapshot.planExplanation { planExplanationsByThread[threadID] = explanation }
        }
    }

    private func scheduleSnapshotCacheSave() {
        snapshotCacheSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.persistSnapshotCache() }
        snapshotCacheSaveWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func persistSnapshotCache() {
        let retained = cachedThreadSnapshots.values
            .sorted { ($0.task?.updatedAt ?? 0) > ($1.task?.updatedAt ?? 0) }
            .prefix(16)
        let snapshots = Dictionary(uniqueKeysWithValues: retained.compactMap { event -> (String, RemoteEvent)? in
            guard let threadID = event.threadId ?? event.task?.id else { return nil }
            var cached = event
            cached.busy = false
            cached.turnId = nil
            cached.runtimeAuthoritative = false
            cached.items = Array((event.items ?? []).suffix(300)).map { item in
                var capped = item
                capped.text = limitedText(capped.text, limit: 80_000)
                return capped
            }
            return (threadID, cached)
        })
        let envelope = SnapshotCacheEnvelope(version: 1, snapshots: snapshots)
        guard let data = try? RemoteJSON.encoder.encode(envelope) else { return }
        let directory = snapshotCacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: snapshotCacheURL, options: .atomic)
    }

    private var snapshotCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CodexRemote", isDirectory: true)
            .appendingPathComponent("thread-snapshots-v1.json")
    }

    private func taskSummary(
        _ thread: JSONObject,
        archived: Bool = false,
        projectId: String? = nil,
        projectOrder: Int? = nil,
        pinOrder: Int? = nil
    ) -> RemoteTaskSummary {
        let id = thread["id"] as? String ?? UUID().uuidString
        let name = (thread["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = (thread["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = (name?.isEmpty == false ? name! : firstLine(preview, fallback: "未命名任务"))
        let cwd = thread["cwd"] as? String ?? ""
        let statusObject = thread["status"] as? JSONObject
        let status = statusObject?["type"] as? String ?? thread["status"] as? String ?? "notLoaded"
        return RemoteTaskSummary(
            id: id,
            title: title,
            preview: preview,
            cwd: cwd,
            updatedAt: number(thread["updatedAt"]) ?? number(thread["createdAt"]) ?? 0,
            status: status,
            archived: archived,
            projectId: projectId,
            projectOrder: projectOrder,
            pinned: pinOrder != nil,
            pinOrder: pinOrder
        )
    }

    private func captureSettings(_ result: JSONObject, threadId: String, fallbackCwd: String?) {
        let previous = settingsByThread[threadId]
        let settings = RemoteTaskSettings(
            threadId: threadId,
            model: result["model"] as? String ?? settingsByThread[threadId]?.model ?? "",
            effort: result["reasoningEffort"] as? String ?? settingsByThread[threadId]?.effort,
            cwd: result["cwd"] as? String ?? fallbackCwd ?? settingsByThread[threadId]?.cwd ?? "",
            permissionMode: permissionModesByThread[threadId] ?? RemotePermissionMode.custom.rawValue,
            planMode: collaborationPlanMode(result) ?? settingsByThread[threadId]?.planMode
        )
        settingsByThread[threadId] = settings
        if settings != previous {
            emit(RemoteEvent(type: RemoteMessage.taskSettings, settings: settings, threadId: threadId))
        }
    }

    private func mergeCachedItem(_ item: RemoteTranscriptItem, threadId: String) {
        guard var snapshot = cachedThreadSnapshots[threadId] else { return }
        var items = snapshot.items ?? []
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        snapshot.items = mobileTranscriptItems(items)
        let emitFullSnapshot = threadSnapshotOnNextLiveItem.remove(threadId) != nil
        if emitFullSnapshot {
            threadSnapshotOnNextLiveItemExpiry.removeValue(forKey: threadId)?.cancel()
            snapshot.busy = activeTurns[threadId] != nil
            snapshot.turnId = activeTurns[threadId]
        }
        cachedThreadSnapshots[threadId] = snapshot
        scheduleSnapshotCacheSave()
        if emitFullSnapshot { emit(snapshot) }
    }

    private func requestSnapshotOnNextLiveItem(_ threadId: String) {
        threadSnapshotOnNextLiveItemExpiry.removeValue(forKey: threadId)?.cancel()
        threadSnapshotOnNextLiveItem.insert(threadId)
        let workItem = DispatchWorkItem { [weak self] in
            self?.threadSnapshotOnNextLiveItem.remove(threadId)
            self?.threadSnapshotOnNextLiveItemExpiry.removeValue(forKey: threadId)
        }
        threadSnapshotOnNextLiveItemExpiry[threadId] = workItem
        queue.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func updateCachedTaskState(_ threadId: String, turnId: String?, busy: Bool) {
        guard var snapshot = cachedThreadSnapshots[threadId] else { return }
        snapshot.busy = busy
        snapshot.turnId = busy ? turnId : nil
        snapshot.runtimeAuthoritative = true
        cachedThreadSnapshots[threadId] = snapshot
        scheduleSnapshotCacheSave()
    }

    @discardableResult
    private func markTurnInactiveIfCurrent(
        threadId: String,
        turnId: String,
        backendConfirmedNoActive: Bool
    ) -> TurnInactivationDecision {
        clearSnapshotFinalAnswerTracking(threadID: threadId, turnID: turnId)
        completedTurnIDsByThread[threadId] = turnId
        let cached = cachedThreadSnapshots[threadId]
        let decision = TurnInactivationResolver.resolve(
            targetTurnID: turnId,
            currentActiveTurnID: activeTurns[threadId],
            cachedBusy: cached?.busy == true,
            cachedTurnID: cached?.turnId,
            backendConfirmedNoActive: backendConfirmedNoActive
        )
        let reconciledActiveTurnID = TurnInactivationApplication.activeTurnID(
            targetTurnID: turnId,
            currentActiveTurnID: activeTurns[threadId],
            decision: decision
        )
        if let reconciledActiveTurnID {
            activeTurns[threadId] = reconciledActiveTurnID
            updateCachedTaskState(
                threadId,
                turnId: reconciledActiveTurnID,
                busy: true
            )
        } else {
            activeTurns.removeValue(forKey: threadId)
            companionTurnReconciliationAt.removeValue(forKey: threadId)
            updateCachedTaskState(threadId, turnId: nil, busy: false)
        }
        return decision
    }

    private func emitAuthoritativeTaskState(
        threadId: String,
        inactiveTurnId: String,
        decision: TurnInactivationDecision
    ) {
        let activeTurnID: String?
        activeTurnID = activeTurns[threadId]
        updateCachedTaskState(
            threadId,
            turnId: activeTurnID,
            busy: activeTurnID != nil
        )
        emit(RemoteEvent(
            type: RemoteMessage.taskState,
            threadId: threadId,
            turnId: activeTurnID ?? inactiveTurnId,
            busy: activeTurnID != nil,
            runtimeAuthoritative: true
        ))
    }

    private func isNoActiveTurnInterruptError(_ message: String) -> Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("no active turn to interrupt") == .orderedSame
    }

    private func isNoActiveTurnSteerError(_ message: String) -> Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("no active turn to steer") == .orderedSame
    }

    private func snapshotItemsRegress(
        previous: [RemoteTranscriptItem],
        next: [RemoteTranscriptItem]
    ) -> Bool {
        guard retainsPreviousOrderAfterLeadingTrim(previous: previous, next: next) else {
            return true
        }
        let nextByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        return previous.contains { item in
            guard let candidate = nextByID[item.id] else { return false }
            return candidate.text.count < item.text.count
                || (candidate.output ?? "").count < (item.output ?? "").count
        }
    }

    private func retainsPreviousOrderAfterLeadingTrim(
        previous: [RemoteTranscriptItem],
        next: [RemoteTranscriptItem]
    ) -> Bool {
        guard !previous.isEmpty else { return true }
        let nextIDs = Set(next.map(\.id))
        guard let firstRetained = previous.firstIndex(where: { nextIDs.contains($0.id) }) else {
            return false
        }
        let retainedPrevious = previous[firstRetained...].filter { nextIDs.contains($0.id) }
        guard retainedPrevious.count == previous.count - firstRetained else { return false }
        let retainedIDs = Set(retainedPrevious.map(\.id))
        let retainedNext = next.filter { retainedIDs.contains($0.id) }
        return retainedPrevious.map(\.id) == retainedNext.map(\.id)
    }

    private func taskSettings(_ raw: JSONObject, threadId: String) -> RemoteTaskSettings {
        RemoteTaskSettings(
            threadId: threadId,
            model: raw["model"] as? String ?? settingsByThread[threadId]?.model ?? "",
            effort: raw["effort"] as? String ?? settingsByThread[threadId]?.effort,
            cwd: raw["cwd"] as? String ?? settingsByThread[threadId]?.cwd ?? "",
            permissionMode: permissionModesByThread[threadId] ?? RemotePermissionMode.custom.rawValue,
            planMode: collaborationPlanMode(raw) ?? settingsByThread[threadId]?.planMode
        )
    }

    private func collaborationPlanMode(_ raw: JSONObject) -> Bool? {
        guard let mode = (raw["collaborationMode"] as? JSONObject)?["mode"] as? String else { return nil }
        return mode == "plan"
    }

    private func remoteModel(_ raw: JSONObject) -> RemoteModel? {
        guard raw["hidden"] as? Bool != true,
              let id = raw["id"] as? String,
              let model = raw["model"] as? String else { return nil }
        let effortObjects = raw["supportedReasoningEfforts"] as? [JSONObject] ?? []
        let efforts = effortObjects.compactMap { effort -> RemoteReasoningEffort? in
            guard let value = effort["reasoningEffort"] as? String else { return nil }
            return RemoteReasoningEffort(value: value, detail: effort["description"] as? String ?? "")
        }
        return RemoteModel(
            id: id,
            model: model,
            displayName: raw["displayName"] as? String ?? model,
            detail: raw["description"] as? String ?? "",
            isDefault: raw["isDefault"] as? Bool ?? false,
            defaultEffort: raw["defaultReasoningEffort"] as? String ?? efforts.first?.value ?? "medium",
            efforts: efforts
        )
    }

    private func emitAvailableModels() {
        let available = modelCatalog.filter { !unsupportedModelIDs.contains($0.model) }
        emit(RemoteEvent(type: RemoteMessage.models, models: available))
    }

    private func rememberUnsupportedModel(_ model: String) {
        guard unsupportedModelIDs.insert(model).inserted else { return }
        UserDefaults.standard.set(
            Array(unsupportedModelIDs).sorted(),
            forKey: "CodexRemote.unsupportedModels.\(providerID)"
        )
        emitAvailableModels()
    }

    private func scheduleThreadReadRetry(
        _ threadId: String,
        attempt: Int,
        forceSnapshot: Bool = false
    ) {
        threadReadRetryWorkItems.removeValue(forKey: threadId)?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.threadReadRetryWorkItems.removeValue(forKey: threadId)
            self.readThread(threadId, retryAttempt: attempt, forceSnapshot: forceSnapshot)
        }
        threadReadRetryWorkItems[threadId] = workItem
        let delay = min(100 * attempt, 800)
        queue.asyncAfter(deadline: .now() + .milliseconds(delay), execute: workItem)
    }

    private func isTransientThreadReadError(_ message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("is empty")
            || value.contains("failed to read session metadata")
            || value.contains("thread not found")
            || value.contains("no such file")
            || value.contains("not materialized yet")
            || value.contains("includeturns is unavailable")
    }

    private func friendlyThreadReadError(_ message: String) -> String {
        if isTransientThreadReadError(message) {
            return "这个任务仍在初始化，请稍后重试"
        }
        return userFacingError(message)
    }

    private func turnCompletionError(_ params: JSONObject) -> String? {
        if let turn = params["turn"] as? JSONObject,
           let message = nestedErrorMessage(turn["error"]) {
            return message
        }
        return nestedErrorMessage(params["error"])
    }

    private func nestedErrorMessage(_ value: Any?) -> String? {
        if let message = value as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let object = value as? JSONObject else { return nil }
        for key in ["message", "error", "detail", "cause"] {
            if let message = nestedErrorMessage(object[key]) { return message }
        }
        return nil
    }

    private func unsupportedModelID(in message: String) -> String? {
        guard message.localizedCaseInsensitiveContains("is not supported"),
              let start = message.range(of: "Model \"")?.upperBound else { return nil }
        let remainder = message[start...]
        guard let end = remainder.firstIndex(of: "\"") else { return nil }
        let model = String(remainder[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }

    private func userFacingError(_ message: String) -> String {
        if let model = unsupportedModelID(in: message) {
            return "\(model) 当前不受已配置账户支持"
        }
        if let urlRange = message.range(of: ", url:") {
            return String(message[..<urlRange.lowerBound])
        }
        return message
    }

    private func recoverUnsupportedModel(
        from message: String,
        threadId: String,
        turnId: String?,
        context: PendingTurnContext?
    ) -> Bool {
        guard let failedModel = unsupportedModelID(in: message) else { return false }
        rememberUnsupportedModel(failedModel)
        guard let context, !context.fallbackAttempted else { return false }
        let fallback = modelCatalog.first {
            $0.model == configuredModelID && !unsupportedModelIDs.contains($0.model)
        } ?? modelCatalog.first {
            $0.isDefault && !unsupportedModelIDs.contains($0.model)
        }
        guard let fallback, fallback.model != failedModel else { return false }

        let params: JSONObject = [
            "threadId": threadId,
            "model": fallback.model,
            "effort": fallback.defaultEffort
        ]
        sendRequest(method: "thread/settings/update", params: params) { [weak self] response in
            guard let self else { return }
            if let error = response["error"] as? JSONObject {
                self.emitError(self.userFacingError(self.errorMessage(error)), threadId: threadId)
                return
            }
            var settings = self.settingsByThread[threadId]
                ?? RemoteTaskSettings(threadId: threadId, model: fallback.model, effort: fallback.defaultEffort, cwd: "")
            settings.model = fallback.model
            settings.effort = fallback.defaultEffort
            self.settingsByThread[threadId] = settings
            self.emit(RemoteEvent(type: RemoteMessage.taskSettings, settings: settings, threadId: threadId))
            self.emit(RemoteEvent(
                type: RemoteMessage.taskItem,
                item: RemoteTranscriptItem(
                    id: "model-fallback-\(turnId ?? UUID().uuidString)",
                    kind: "system",
                    text: "\(failedModel) 不可用，已切换到 \(fallback.displayName) 并自动重试"
                ),
                threadId: threadId
            ))
            self.invalidateDesktop()
            self.startTurn(
                threadId: threadId,
                input: context.input,
                fallbackAttempted: true,
                model: fallback.model,
                effort: fallback.defaultEffort,
                permissionMode: context.permissionMode,
                planMode: context.planMode
            )
        }
        return true
    }

    private static func configuredValue(_ key: String) -> String? {
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? NSHomeDirectory()
        let url = URL(fileURLWithPath: home)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { break }
            let fields = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard fields.count == 2,
                  fields[0].trimmingCharacters(in: .whitespacesAndNewlines) == key else { continue }
            var value = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func resources(in text: String) -> [RemoteResource] {
        var candidates: [String] = []
        var cursor = text.startIndex
        while let marker = text.range(of: "](", range: cursor..<text.endIndex) {
            let start = marker.upperBound
            guard let end = text[start...].firstIndex(of: ")") else { break }
            candidates.append(String(text[start..<end]))
            cursor = text.index(after: end)
        }

        let backtickParts = text.components(separatedBy: "`")
        for index in stride(from: 1, to: backtickParts.count, by: 2) {
            candidates.append(backtickParts[index])
        }

        var seen = Set<String>()
        return candidates.compactMap(resource).filter { seen.insert($0.path).inserted }
    }

    private func resource(_ rawValue: String) -> RemoteResource? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<"), value.hasSuffix(">") {
            value.removeFirst()
            value.removeLast()
        }
        value = value.removingPercentEncoding ?? value

        let initialPath: String
        if value.hasPrefix("file://"), let url = URL(string: value), url.isFileURL {
            initialPath = url.path
        } else {
            initialPath = value
        }
        guard initialPath.hasPrefix("/") else { return nil }

        func existingURL(for path: String) -> URL? {
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            return url
        }

        var url = existingURL(for: initialPath)
        if url == nil {
            var pathWithoutLocation = initialPath
            for _ in 0..<2 {
                guard let separator = pathWithoutLocation.lastIndex(of: ":"),
                      !pathWithoutLocation[pathWithoutLocation.index(after: separator)...].isEmpty,
                      pathWithoutLocation[pathWithoutLocation.index(after: separator)...].allSatisfy(\.isNumber) else { break }
                pathWithoutLocation = String(pathWithoutLocation[..<separator])
                if let candidate = existingURL(for: pathWithoutLocation) {
                    url = candidate
                    break
                }
            }
        }
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else { return nil }

        let type = UTType(filenameExtension: url.pathExtension)
        let kind = type?.conforms(to: .image) == true ? "image" : "document"
        return RemoteResource(
            name: url.lastPathComponent,
            path: url.path,
            kind: kind,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            sizeBytes: size
        )
    }

    private func transcriptItem(_ item: JSONObject) -> RemoteTranscriptItem? {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return nil }
        switch type {
        case "userMessage":
            let content = item["content"] as? [JSONObject] ?? []
            let text = content.compactMap { value -> String? in
                switch value["type"] as? String {
                case "text":
                    return value["text"] as? String
                case "localImage":
                    let path = value["path"] as? String ?? ""
                    return "附件：\((path as NSString).lastPathComponent)"
                case "image":
                    return "附件：图片"
                case "mention":
                    let name = value["name"] as? String ?? "文档"
                    return "附件：\((name as NSString).lastPathComponent)"
                case "skill":
                    return "插件：\(value["name"] as? String ?? "Codex 插件")"
                case "localAudio", "audio":
                    return "附件：音频"
                default:
                    return value["text"] as? String
                }
            }.filter { !$0.isEmpty }.joined(separator: "\n")
            var seen = Set<String>()
            let attachedResources = content.compactMap { value -> String? in
                switch value["type"] as? String {
                case "localImage": return value["path"] as? String
                case "mention":
                    return value["path"] as? String ?? value["uri"] as? String ?? value["name"] as? String
                default: return nil
                }
            }.compactMap(resource).filter { seen.insert($0.path).inserted }
            return RemoteTranscriptItem(
                id: id,
                kind: "user",
                text: text,
                resources: attachedResources.isEmpty ? nil : attachedResources
            )
        case "agentMessage":
            let text = item["text"] as? String ?? ""
            let linkedResources = resources(in: text)
            return RemoteTranscriptItem(
                id: id,
                kind: "assistant",
                text: text,
                resources: linkedResources.isEmpty ? nil : linkedResources
            )
        case "reasoning":
            let summary = item["summary"] as? [String] ?? []
            guard !summary.isEmpty else { return nil }
            return RemoteTranscriptItem(id: id, kind: "reasoning", text: summary.joined(separator: "\n"))
        case "plan":
            return RemoteTranscriptItem(id: id, kind: "plan", text: item["text"] as? String ?? "")
        case "commandExecution":
            let command = item["command"] as? String ?? "终端命令"
            let output = limitedText(item["aggregatedOutput"] as? String ?? "", limit: 16_000)
            let text = output.isEmpty ? command : "\(command)\n\(output)"
            return RemoteTranscriptItem(
                id: id,
                kind: "tool",
                text: text,
                status: item["status"] as? String,
                command: command,
                output: output,
                toolName: "终端"
            )
        case "fileChange":
            let changes = item["changes"] as? [JSONObject] ?? []
            let files = changes.map { change -> RemoteFileChange in
                let kind: String
                if let rawKind = change["kind"] as? String {
                    kind = rawKind
                } else if let rawKind = change["kind"] as? JSONObject {
                    kind = rawKind.keys.first ?? "update"
                } else {
                    kind = "update"
                }
                let path = change["path"] as? String ?? "文件"
                let diff = change["diff"] as? String ?? ""
                return RemoteFileChange(path: path, kind: kind, diff: diff)
            }
            let detail = files.map { change in
                change.diff.isEmpty
                    ? "\(change.kind) · \(change.path)"
                    : "\(change.kind) · \(change.path)\n\(change.diff)"
            }.joined(separator: "\n\n")
            let text = detail.isEmpty ? "没有文件变更详情" : limitedText(detail, limit: 24_000)
            return RemoteTranscriptItem(
                id: id,
                kind: "file",
                text: text,
                status: item["status"] as? String,
                files: files
            )
        case "mcpToolCall":
            let server = item["server"] as? String ?? "工具"
            let tool = item["tool"] as? String ?? "调用"
            let arguments = item["arguments"] as? JSONObject ?? [:]
            let title = (arguments["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let command = (arguments["cmd"] as? String)
                ?? (arguments["command"] as? String)
            let path = (arguments["path"] as? String)
                ?? (arguments["file"] as? String)
            let detail: String
            if let title, !title.isEmpty {
                detail = title
            } else if tool.lowercased().contains("image"), let path, !path.isEmpty {
                detail = "查看图片：\((path as NSString).lastPathComponent)"
            } else if let command, !command.isEmpty {
                detail = limitedText(command, limit: 4_000)
            } else if let path, !path.isEmpty {
                detail = "\(tool)：\((path as NSString).lastPathComponent)"
            } else {
                detail = "\(server) · \(tool)"
            }
            return RemoteTranscriptItem(
                id: id,
                kind: "tool",
                text: detail,
                status: item["status"] as? String,
                command: command,
                toolName: title?.isEmpty == false ? title : "\(server) · \(tool)"
            )
        case "webSearch":
            return RemoteTranscriptItem(
                id: id,
                kind: "tool",
                text: "网页搜索：\(item["query"] as? String ?? "")",
                toolName: "网页搜索"
            )
        case "imageGeneration":
            let result = item["result"] as? String ?? "图片生成"
            let generatedResources = resources(in: result)
            return RemoteTranscriptItem(
                id: id,
                kind: "tool",
                text: result,
                status: item["status"] as? String,
                toolName: "图片生成",
                resources: generatedResources.isEmpty ? nil : generatedResources
            )
        case "contextCompaction":
            return RemoteTranscriptItem(id: id, kind: "system", text: "已整理任务上下文")
        default:
            return nil
        }
    }

    private func userInput(
        prompt: String,
        attachments: [RemoteAttachment],
        skills: [RemoteSkill],
        threadId: String
    ) throws -> [JSONObject] {
        let maximumAttachmentCount = 6
        let maximumAttachmentBytes = 16 * 1024 * 1024
        let maximumTotalBytes = 28 * 1024 * 1024
        guard attachments.count <= maximumAttachmentCount else {
            throw InputError.invalid("一次最多添加 \(maximumAttachmentCount) 个附件")
        }

        var input: [JSONObject] = []
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanPrompt.isEmpty { input.append(["type": "text", "text": cleanPrompt]) }

        var totalBytes = 0
        var usedFileNames = Set<String>()
        let uploadDirectory = attachments.isEmpty ? nil : try prepareUploadDirectory(threadId: threadId)
        for attachment in attachments {
            guard attachment.sizeBytes >= 0, attachment.sizeBytes <= maximumAttachmentBytes else {
                throw InputError.invalid("\(attachment.name) 超过 16 MB 限制")
            }
            guard attachment.dataBase64.utf8.count <= (maximumAttachmentBytes * 4 / 3) + 8,
                  let data = Data(base64Encoded: attachment.dataBase64),
                  data.count == attachment.sizeBytes else {
                throw InputError.invalid("\(attachment.name) 的附件数据无效")
            }
            totalBytes += data.count
            guard totalBytes <= maximumTotalBytes else {
                throw InputError.invalid("本次附件总大小超过 28 MB")
            }

            let kind = attachment.kind.lowercased()
            guard kind == "image" || kind == "document" else {
                throw InputError.invalid("不支持的附件类型：\(attachment.name)")
            }
            if kind == "image" {
                guard attachment.mimeType.lowercased().hasPrefix("image/"), NSImage(data: data) != nil else {
                    throw InputError.invalid("\(attachment.name) 不是有效图片")
                }
            }

            guard let uploadDirectory else { continue }
            let preferredName = safeAttachmentName(
                attachment.name,
                fallback: kind == "image" ? "image.jpg" : "document"
            )
            let fileName = uniqueAttachmentName(preferredName, usedNames: &usedFileNames)
            let fileURL = uploadDirectory.appendingPathComponent(fileName, isDirectory: false)
            do {
                try data.write(to: fileURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch {
                throw InputError.invalid("无法在 Mac 保存附件：\(fileName)")
            }
            if kind == "image" {
                input.append(["type": "localImage", "path": fileURL.path, "detail": "auto"])
            } else {
                input.append(["type": "mention", "name": fileURL.path, "path": fileURL.path])
            }
        }

        var includedSkillPaths = Set<String>()
        for requestedSkill in skills where includedSkillPaths.insert(requestedSkill.path).inserted {
            guard let skill = pluginSkillsByPath[requestedSkill.path],
                  skill.name == requestedSkill.name,
                  skill.pluginName == requestedSkill.pluginName else {
                throw InputError.invalid("插件 \(requestedSkill.pluginName) 已变化，请重新选择")
            }
            input.append(["type": "skill", "name": skill.name, "path": skill.path])
        }
        guard !input.isEmpty else { throw InputError.invalid("请输入消息或添加附件") }
        return input
    }

    private func safeAttachmentName(_ value: String, fallback: String) -> String {
        let source = (value as NSString).lastPathComponent
        let allowedPunctuation = CharacterSet(charactersIn: " ._()-[]")
        let filteredScalars = source.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || allowedPunctuation.contains($0)
        }
        var result = String(String.UnicodeScalarView(filteredScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result == "." || result == ".." { result = "" }
        if result.isEmpty { result = fallback }
        if result.count > 120 { result = String(result.prefix(120)) }
        return result
    }

    private func uniqueAttachmentName(_ preferredName: String, usedNames: inout Set<String>) -> String {
        if usedNames.insert(preferredName).inserted { return preferredName }
        let source = preferredName as NSString
        let stem = source.deletingPathExtension
        let pathExtension = source.pathExtension
        var index = 2
        while true {
            let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
            let candidate = "\(stem) (\(index))\(suffix)"
            if usedNames.insert(candidate).inserted { return candidate }
            index += 1
        }
    }

    private func attachmentContext(for input: [JSONObject]) -> JSONObject? {
        let files = input.compactMap { value -> String? in
            guard let type = value["type"] as? String,
                  type == "mention" || type == "localImage",
                  let path = value["path"] as? String else { return nil }
            return "- \((path as NSString).lastPathComponent): \(path)"
        }
        guard !files.isEmpty else { return nil }
        let value = """
        Files selected by the user in Codex Remote are available at these exact local paths. Use these paths directly:
        \(files.joined(separator: "\n"))
        """
        return ["codex_remote_attachments": ["kind": "application", "value": value]]
    }

    private func prepareUploadDirectory(threadId: String) throws -> URL {
        let safeThreadID = threadId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !safeThreadID.isEmpty, safeThreadID.count <= 80 else {
            throw InputError.invalid("任务 ID 无效，无法保存附件")
        }
        let root = URL(fileURLWithPath: "/private/tmp/codex-remote-attachments", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let expiration = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            let staleDirectories = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for url in staleDirectories {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                if values?.isDirectory == true, (values?.contentModificationDate ?? .distantFuture) < expiration {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let threadDirectory = root.appendingPathComponent(safeThreadID, isDirectory: true)
            try FileManager.default.createDirectory(
                at: threadDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let directory = threadDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return directory
        } catch {
            throw InputError.invalid("无法创建 Mac 附件目录")
        }
    }

    private func resolvedWorkspace(_ requested: String?) -> String {
        if let requested, requested.hasPrefix("/"), FileManager.default.fileExists(atPath: requested) { return requested }
        if let saved = UserDefaults.standard.string(forKey: "CodexRemote.defaultWorkspace"),
           FileManager.default.fileExists(atPath: saved) { return saved }
        let preferred = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents").path
        if FileManager.default.fileExists(atPath: preferred) { return preferred }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func firstLine(_ value: String, fallback: String) -> String {
        let line = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? fallback
        return String(line.prefix(64))
    }

    private func limitedText(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return "…已省略较早输出…\n" + String(value.suffix(limit))
    }

    private func mobileTranscriptItems(_ items: [RemoteTranscriptItem]) -> [RemoteTranscriptItem] {
        var remainingCharacters = 600_000
        var retained: [RemoteTranscriptItem] = []
        for original in items.suffix(300).reversed() {
            guard remainingCharacters > 0 else { break }
            var item = original
            item.text = limitedText(item.text, limit: min(80_000, remainingCharacters))
            remainingCharacters = max(0, remainingCharacters - item.text.count)
            retained.append(item)
        }
        return Array(retained.reversed())
    }

    private func mobileTranscriptItems(from rawItems: [JSONObject]) -> [RemoteTranscriptItem] {
        var newestFirst: [RemoteTranscriptItem] = []
        newestFirst.reserveCapacity(300)
        for rawItem in rawItems.reversed() {
            guard let item = transcriptItem(rawItem) else { continue }
            newestFirst.append(item)
            if newestFirst.count == 300 { break }
        }
        return mobileTranscriptItems(Array(newestFirst.reversed()))
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func numberID(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private func errorMessage(_ error: JSONObject) -> String {
        error["message"] as? String ?? "Codex 请求失败"
    }

    private func emitError(_ message: String, requestId: String? = nil, threadId: String? = nil) {
        emit(RemoteEvent(type: RemoteMessage.error, requestId: requestId, threadId: threadId, message: message))
    }

    private func emit(_ event: RemoteEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    private func invalidateDesktop() {
        onDesktopInvalidation?()
    }

    private func codexExecutable() -> URL? {
        let paths = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
}

enum SHA1 {
    static func hash(_ input: [UInt8], into output: inout [UInt8]) {
        var message = input
        let bitLength = UInt64(message.count * 8)
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        message.append(contentsOf: withUnsafeBytes(of: bitLength.bigEndian, Array.init))
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 80)
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                words[index] = UInt32(message[offset]) << 24 | UInt32(message[offset + 1]) << 16 |
                    UInt32(message[offset + 2]) << 8 | UInt32(message[offset + 3])
            }
            for index in 16..<80 { words[index] = (words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16]).rotatedLeft(1) }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for index in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch index {
                case 0..<20: f = (b & c) | ((~b) & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let temp = a.rotatedLeft(5) &+ f &+ e &+ k &+ words[index]
                e = d; d = c; c = b.rotatedLeft(30); b = a; a = temp
            }
            h0 &+= a; h1 &+= b; h2 &+= c; h3 &+= d; h4 &+= e
        }
        output = [h0, h1, h2, h3, h4].flatMap { value in
            let big = value.bigEndian
            return withUnsafeBytes(of: big, Array.init)
        }
    }
}

private extension UInt32 {
    func rotatedLeft(_ amount: UInt32) -> UInt32 { (self << amount) | (self >> (32 - amount)) }
}

final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let server: RemoteServer
    private var sleepActivity: NSObjectProtocol?

    init(server: RemoteServer) {
        self.server = server
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Codex Remote")
        menu.delegate = self
        statusItem.menu = menu
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Keep Codex Remote available while the Mac is locked"
        )
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Codex Remote 直接模式", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let state = NSMenuItem(
            title: server.bridge.isReady ? "Codex 服务：已连接" : "Codex 服务：正在启动",
            action: nil,
            keyEquivalent: ""
        )
        state.isEnabled = false
        menu.addItem(state)

        let lock = NSMenuItem(title: "锁屏可用 · 无需屏幕录制或辅助功能", action: nil, keyEquivalent: "")
        lock.isEnabled = false
        menu.addItem(lock)
        menu.addItem(.separator())

        let port = NSMenuItem(title: "端口：\(server.port)", action: nil, keyEquivalent: "")
        port.isEnabled = false
        menu.addItem(port)

        let key = NSMenuItem(title: "复制配对密钥", action: #selector(copyKey), keyEquivalent: "")
        key.target = self
        menu.addItem(key)

        let workspace = UserDefaults.standard.string(forKey: "CodexRemote.defaultWorkspace")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path
        let workspaceItem = NSMenuItem(title: "默认工作区：\((workspace as NSString).lastPathComponent)", action: nil, keyEquivalent: "")
        workspaceItem.isEnabled = false
        menu.addItem(workspaceItem)
        let choose = NSMenuItem(title: "选择默认工作区…", action: #selector(chooseWorkspace), keyEquivalent: "")
        choose.target = self
        menu.addItem(choose)
        menu.addItem(.separator())

        let restart = NSMenuItem(title: "重新启动 Codex Remote", action: #selector(restart), keyEquivalent: "q")
        restart.target = self
        menu.addItem(restart)
    }

    deinit {
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity) }
    }

    @objc private func copyKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(server.pairingKey, forType: .string)
    }

    @objc private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        UserDefaults.standard.set(path, forKey: "CodexRemote.defaultWorkspace")
        server.refreshProjects()
        rebuildMenu()
    }

    @objc private func restart() { NSApplication.shared.terminate(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: RemoteServer?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let server = RemoteServer()
        self.server = server
        statusController = StatusItemController(server: server)
        server.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }
}

signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
