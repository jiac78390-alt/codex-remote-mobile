import Foundation

public enum RemoteEventCode {
    public static let noActiveTurn = "noActiveTurn"
}

public struct TurnActivityResolution: Equatable, Sendable {
    public var activeTurnID: String?
    public var inactiveTurnID: String?

    public init(activeTurnID: String?, inactiveTurnID: String?) {
        self.activeTurnID = activeTurnID
        self.inactiveTurnID = inactiveTurnID
    }
}

public enum TurnActivityResolver {
    public static func resolve(
        latestTurnID: String?,
        rawStatus: String?,
        observedActiveTurnID: String?,
        knownCompletedTurnID: String?,
        hasFinalAnswer: Bool,
        hasError: Bool
    ) -> TurnActivityResolution {
        guard let latestTurnID, !latestTurnID.isEmpty else {
            return TurnActivityResolution(
                activeTurnID: observedActiveTurnID,
                inactiveTurnID: nil
            )
        }

        let normalizedStatus = rawStatus?
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let explicitlyRunning = normalizedStatus == "inprogress" || normalizedStatus == "running"
        let terminalStatuses: Set<String> = [
            "completed", "failed", "cancelled", "canceled", "interrupted"
        ]
        let explicitlyInactive = normalizedStatus.map(terminalStatuses.contains) ?? false
        let knownInactive = knownCompletedTurnID == latestTurnID
            || hasFinalAnswer
            || hasError
            || explicitlyInactive

        if knownInactive {
            return TurnActivityResolution(
                activeTurnID: observedActiveTurnID == latestTurnID ? nil : observedActiveTurnID,
                inactiveTurnID: latestTurnID
            )
        }
        if explicitlyRunning {
            return TurnActivityResolution(
                activeTurnID: observedActiveTurnID ?? latestTurnID,
                inactiveTurnID: nil
            )
        }

        return TurnActivityResolution(
            activeTurnID: observedActiveTurnID,
            inactiveTurnID: nil
        )
    }
}

public struct SnapshotFinalAnswerGate: Sendable {
    public static let defaultGracePeriod: TimeInterval = 2

    private struct Observation: Sendable {
        var turnID: String
        var firstSeenAt: TimeInterval
    }

    public let gracePeriod: TimeInterval
    private var observationsByThread: [String: Observation] = [:]

    public init(gracePeriod: TimeInterval = Self.defaultGracePeriod) {
        self.gracePeriod = max(0, gracePeriod)
    }

    public mutating func shouldTreatAsTerminal(
        threadID: String,
        turnID: String?,
        observedActiveTurnID: String?,
        hasFinalAnswer: Bool,
        now: TimeInterval
    ) -> Bool {
        guard hasFinalAnswer,
              !threadID.isEmpty,
              let turnID,
              !turnID.isEmpty else { return false }

        guard observedActiveTurnID == turnID else {
            observationsByThread.removeValue(forKey: threadID)
            return true
        }

        guard let observation = observationsByThread[threadID],
              observation.turnID == turnID else {
            observationsByThread[threadID] = Observation(
                turnID: turnID,
                firstSeenAt: now
            )
            return gracePeriod == 0
        }
        return now - observation.firstSeenAt >= gracePeriod
    }

    public mutating func clear(threadID: String, turnID: String? = nil) {
        guard let turnID else {
            observationsByThread.removeValue(forKey: threadID)
            return
        }
        guard observationsByThread[threadID]?.turnID == turnID else { return }
        observationsByThread.removeValue(forKey: threadID)
    }

    public mutating func clearAll() {
        observationsByThread.removeAll()
    }
}

public enum SnapshotTerminalStatusPolicy {
    public static func statusForResolution(
        latestTurnID: String?,
        rawStatus: String?,
        observedActiveTurnID: String?,
        hasTerminalEvidence: Bool
    ) -> String? {
        guard latestTurnID == observedActiveTurnID,
              !hasTerminalEvidence,
              isTerminal(rawStatus) else { return rawStatus }
        return nil
    }

    private static func isTerminal(_ rawStatus: String?) -> Bool {
        let normalized = rawStatus?
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return normalized.map({
            ["completed", "failed", "cancelled", "canceled", "interrupted"].contains($0)
        }) ?? false
    }
}

public enum TurnInactivationDecision: Equatable, Sendable {
    case changed
    case alreadyInactive
    case newerTurn(String)
}

public enum TurnInactivationResolver {
    public static func resolve(
        targetTurnID: String,
        currentActiveTurnID: String?,
        cachedBusy: Bool,
        cachedTurnID: String?,
        backendConfirmedNoActive: Bool
    ) -> TurnInactivationDecision {
        if let currentActiveTurnID {
            if currentActiveTurnID != targetTurnID {
                return .newerTurn(currentActiveTurnID)
            }
            if cachedBusy,
               let cachedTurnID,
               cachedTurnID != targetTurnID {
                return .newerTurn(cachedTurnID)
            }
            return .changed
        }
        if cachedBusy, let cachedTurnID {
            return cachedTurnID == targetTurnID
                ? .changed
                : .newerTurn(cachedTurnID)
        }
        if backendConfirmedNoActive { return .alreadyInactive }
        return .alreadyInactive
    }
}

public enum TurnInactivationApplication {
    public static func activeTurnID(
        targetTurnID: String,
        currentActiveTurnID: String?,
        decision: TurnInactivationDecision
    ) -> String? {
        if let currentActiveTurnID, currentActiveTurnID != targetTurnID {
            return currentActiveTurnID
        }
        if case .newerTurn(let newerTurnID) = decision {
            return newerTurnID
        }
        return nil
    }
}

public enum TurnStartAdmissionPolicy {
    public static func shouldActivate(
        turnID: String,
        knownCompletedTurnID: String?
    ) -> Bool {
        turnID != knownCompletedTurnID
    }
}

public enum CompletedTurnInterruptPolicy {
    public static func shouldContactBackend(
        requestedTurnID: String?,
        knownCompletedTurnID: String?
    ) -> Bool {
        guard let requestedTurnID else { return true }
        return requestedTurnID != knownCompletedTurnID
    }
}

public enum InterruptNoActiveRetryPolicy {
    public static let maximumRetries = 4

    public static func shouldRetry(
        requestedTurnID: String,
        currentActiveTurnID: String?,
        hasPendingStartContext: Bool,
        retryAttempt: Int
    ) -> Bool {
        retryAttempt < maximumRetries
            && currentActiveTurnID == requestedTurnID
            && hasPendingStartContext
    }

    public static func delayMilliseconds(retryAttempt: Int) -> Int {
        min(50 << min(max(0, retryAttempt), 4), 800)
    }
}

public enum InterruptTurnTransitionRetryPolicy {
    public static let maximumRetries = 6

    public static func shouldRetry(
        errorMessage: String,
        requestedTurnID: String,
        currentActiveTurnID: String?,
        hasPendingStartContext: Bool,
        retryAttempt: Int
    ) -> Bool {
        guard retryAttempt < maximumRetries,
              currentActiveTurnID == requestedTurnID,
              hasPendingStartContext else { return false }

        let normalizedMessage = errorMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let requested = requestedTurnID.lowercased()
        let marker = "expected active turn id \(requested) but found "
        guard let markerRange = normalizedMessage.range(of: marker) else { return false }
        let observed = normalizedMessage[markerRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !observed.isEmpty && observed != requested
    }

    public static func delayMilliseconds(retryAttempt: Int) -> Int {
        InterruptNoActiveRetryPolicy.delayMilliseconds(retryAttempt: retryAttempt)
    }
}

public enum SnapshotItemMergePolicy {
    public static func merge(
        previous: [RemoteTranscriptItem],
        recent: [RemoteTranscriptItem]
    ) -> [RemoteTranscriptItem] {
        guard !previous.isEmpty else { return recent }
        var merged = deduplicatingAdjacentAliases(previous)
        let aliasMatches = canonicalAliasMatches(previous: merged, recent: recent)
        var indexes = Dictionary(
            uniqueKeysWithValues: merged.enumerated().map { ($0.element.id, $0.offset) }
        )

        for (recentIndex, originalRecentItem) in recent.enumerated() {
            var recentItem = originalRecentItem
            if let canonicalIndex = aliasMatches[recentIndex] {
                recentItem.id = merged[canonicalIndex].id
            }
            guard let existingIndex = indexes[recentItem.id] else {
                indexes[recentItem.id] = merged.count
                merged.append(recentItem)
                continue
            }
            merged[existingIndex] = combining(
                existing: merged[existingIndex],
                recent: recentItem,
                preferredID: merged[existingIndex].id
            )
        }
        return deduplicatingAdjacentAliases(merged)
    }

    private static func canonicalAliasMatches(
        previous: [RemoteTranscriptItem],
        recent: [RemoteTranscriptItem]
    ) -> [Int: Int] {
        var matches: [Int: Int] = [:]
        var previousUpperBound = previous.count

        for recentIndex in recent.indices.reversed() {
            let recentItem = recent[recentIndex]
            if !isSummaryAlias(recentItem.id),
               let exactIndex = previous[..<previousUpperBound]
                .lastIndex(where: { $0.id == recentItem.id }) {
                previousUpperBound = exactIndex
                continue
            }
            guard isSummaryAlias(recentItem.id), previousUpperBound > 0 else { continue }
            let exactAliasIndex = previous[..<previousUpperBound]
                .lastIndex(where: { $0.id == recentItem.id })
            let candidateUpperBound = exactAliasIndex ?? previousUpperBound
            guard candidateUpperBound > 0 else {
                previousUpperBound = exactAliasIndex ?? previousUpperBound
                continue
            }
            guard let canonicalIndex = previous[..<candidateUpperBound].lastIndex(where: {
                !isSummaryAlias($0.id) && semanticallyEquivalent($0, recentItem)
            }) else {
                previousUpperBound = exactAliasIndex ?? previousUpperBound
                continue
            }
            matches[recentIndex] = canonicalIndex
            previousUpperBound = canonicalIndex
        }
        return matches
    }

    private static func deduplicatingAdjacentAliases(
        _ items: [RemoteTranscriptItem]
    ) -> [RemoteTranscriptItem] {
        var result: [RemoteTranscriptItem] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard let previous = result.last,
                  !isSummaryAlias(previous.id),
                  isSummaryAlias(item.id),
                  semanticallyEquivalent(previous, item) else {
                result.append(item)
                continue
            }
            result[result.count - 1] = combining(
                existing: previous,
                recent: item,
                preferredID: previous.id
            )
        }
        return result
    }

    private static func semanticallyEquivalent(
        _ lhs: RemoteTranscriptItem,
        _ rhs: RemoteTranscriptItem
    ) -> Bool {
        guard lhs.kind == rhs.kind, lhs.text == rhs.text else { return false }
        if let leftCommand = lhs.command,
           let rightCommand = rhs.command,
           leftCommand != rightCommand { return false }
        if let leftToolName = lhs.toolName,
           let rightToolName = rhs.toolName,
           leftToolName != rightToolName { return false }
        return true
    }

    private static func isSummaryAlias(_ id: String) -> Bool {
        guard id.hasPrefix("item-") else { return false }
        let suffix = id.dropFirst("item-".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    private static func combining(
        existing: RemoteTranscriptItem,
        recent: RemoteTranscriptItem,
        preferredID: String
    ) -> RemoteTranscriptItem {
        var resolved = recent
        resolved.id = preferredID
        if existing.text.count > resolved.text.count { resolved.text = existing.text }
        if (existing.output ?? "").count > (resolved.output ?? "").count {
            resolved.output = existing.output
        }
        if resolved.status == nil { resolved.status = existing.status }
        if resolved.command == nil { resolved.command = existing.command }
        if resolved.files?.isEmpty != false { resolved.files = existing.files }
        if resolved.toolName == nil { resolved.toolName = existing.toolName }
        if resolved.resources?.isEmpty != false { resolved.resources = existing.resources }
        return resolved
    }
}

public struct MobileTaskRuntimeState: Equatable, Sendable {
    public var isBusy: Bool
    public var isInterrupting: Bool
    public var activeTurnID: String?

    public init(isBusy: Bool, isInterrupting: Bool, activeTurnID: String?) {
        self.isBusy = isBusy
        self.isInterrupting = isInterrupting
        self.activeTurnID = activeTurnID
    }

    @discardableResult
    public mutating func reconcileInterruptAcknowledgement(
        commandTurnID: String?,
        accepted: Bool,
        code: String?
    ) -> Bool {
        let targetsCurrentTurn = activeTurnID == nil
            || (commandTurnID != nil && commandTurnID == activeTurnID)
        let targetIsInactive = accepted || code == RemoteEventCode.noActiveTurn
        guard targetIsInactive else {
            if targetsCurrentTurn { isInterrupting = false }
            return false
        }

        guard targetsCurrentTurn else { return false }
        isBusy = false
        isInterrupting = false
        activeTurnID = nil
        return true
    }
}

public struct ReliableInterruptCandidate: Equatable, Sendable {
    public var messageID: String
    public var turnID: String?
    public var createdAt: TimeInterval

    public init(messageID: String, turnID: String?, createdAt: TimeInterval) {
        self.messageID = messageID
        self.turnID = turnID
        self.createdAt = createdAt
    }
}

public struct ReliableInterruptDecision: Equatable, Sendable {
    public var discardedMessageIDs: [String]
    public var messageIDToSend: String?
    public var deferUntilRuntimeConfirmation: Bool

    public init(
        discardedMessageIDs: [String],
        messageIDToSend: String?,
        deferUntilRuntimeConfirmation: Bool
    ) {
        self.discardedMessageIDs = discardedMessageIDs
        self.messageIDToSend = messageIDToSend
        self.deferUntilRuntimeConfirmation = deferUntilRuntimeConfirmation
    }
}

public enum ReliableCommandOrderingPolicy {
    public static func shouldDeferUntilInterruptSettles(
        commandCreatedAt: TimeInterval?,
        pendingInterrupts: [ReliableInterruptCandidate]
    ) -> Bool {
        guard !pendingInterrupts.isEmpty else { return false }
        guard let commandCreatedAt else { return true }
        return pendingInterrupts.contains { $0.createdAt <= commandCreatedAt }
    }
}

public enum ReliableInterruptFallbackPolicy {
    public static func messageIDToProbe(
        _ candidates: [ReliableInterruptCandidate],
        confirmationWaitElapsed: Bool
    ) -> String? {
        guard confirmationWaitElapsed else { return nil }
        return candidates.sorted {
            if $0.createdAt == $1.createdAt { return $0.messageID < $1.messageID }
            return $0.createdAt < $1.createdAt
        }.first?.messageID
    }
}

public enum SecretFallbackStore {
    @discardableResult
    public static func persist(
        value: String,
        persistSecurely: (String) -> Bool,
        storeFallback: (String) -> Void,
        removeFallback: () -> Void
    ) -> Bool {
        guard !value.isEmpty else { return false }
        let securelyPersisted = persistSecurely(value)
        if securelyPersisted {
            removeFallback()
        } else {
            storeFallback(value)
        }
        return securelyPersisted
    }
}

public enum ReliableInterruptPolicy {
    public static func reconcile(
        _ candidates: [ReliableInterruptCandidate],
        busy: Bool,
        activeTurnID: String?,
        inactiveTurnID: String?,
        isFullSnapshot: Bool,
        wasAwaitingRuntimeConfirmation: Bool
    ) -> ReliableInterruptDecision {
        let ordered = candidates.sorted {
            if $0.createdAt == $1.createdAt { return $0.messageID < $1.messageID }
            return $0.createdAt < $1.createdAt
        }
        guard !ordered.isEmpty else {
            return ReliableInterruptDecision(
                discardedMessageIDs: [],
                messageIDToSend: nil,
                deferUntilRuntimeConfirmation: false
            )
        }
        guard busy else {
            let discarded = isFullSnapshot || inactiveTurnID == nil
                ? ordered.map(\.messageID)
                : ordered.filter { $0.turnID == inactiveTurnID }.map(\.messageID)
            let discardedSet = Set(discarded)
            let hasUnconfirmedCandidate = ordered.contains {
                !discardedSet.contains($0.messageID)
            }
            return ReliableInterruptDecision(
                discardedMessageIDs: discarded,
                messageIDToSend: nil,
                deferUntilRuntimeConfirmation: wasAwaitingRuntimeConfirmation
                    && hasUnconfirmedCandidate
            )
        }
        guard let activeTurnID else {
            return ReliableInterruptDecision(
                discardedMessageIDs: [],
                messageIDToSend: nil,
                deferUntilRuntimeConfirmation: true
            )
        }
        let matching = ordered.filter { $0.turnID == activeTurnID }
        let retained = matching.first
        let discarded = ordered
            .filter { $0.messageID != retained?.messageID }
            .map(\.messageID)
        return ReliableInterruptDecision(
            discardedMessageIDs: discarded,
            messageIDToSend: wasAwaitingRuntimeConfirmation ? retained?.messageID : nil,
            deferUntilRuntimeConfirmation: false
        )
    }
}

public struct ComposerDraftState: Codable, Equatable, Sendable {
    public private(set) var drafts: [String: String]

    public init(drafts: [String: String] = [:]) {
        self.drafts = drafts.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public static func taskContextID(_ threadID: String) -> String {
        "task:\(threadID)"
    }

    public static func newTaskContextID(projectID: String?, cwd: String?) -> String {
        if let projectID, !projectID.isEmpty { return "new:project:\(projectID)" }
        if let cwd, !cwd.isEmpty { return "new:cwd:\(cwd)" }
        return "new:default"
    }

    public func draft(for contextID: String) -> String {
        drafts[contextID] ?? ""
    }

    public func hasDraft(for contextID: String) -> Bool {
        guard let value = drafts[contextID] else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func merged(existing: String, recovered: String) -> String {
        let existingIsEmpty = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let recoveredIsEmpty = recovered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if recoveredIsEmpty { return existing }
        if existingIsEmpty { return recovered }
        if existing == recovered { return existing }
        if recovered.hasPrefix(existing + "\n\n") { return recovered }
        if existing.hasPrefix(recovered + "\n\n") { return existing }
        if recovered.hasSuffix("\n\n" + existing) { return recovered }
        if existing.hasSuffix("\n\n" + recovered) { return existing }
        return existing + "\n\n" + recovered
    }

    public mutating func setDraft(_ value: String, for contextID: String) {
        guard !contextID.isEmpty else { return }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts.removeValue(forKey: contextID)
            return
        }
        drafts[contextID] = String(value.prefix(50_000))
    }

    public mutating func removeDraft(for contextID: String) {
        drafts.removeValue(forKey: contextID)
    }
}

public struct ReliableRetrySchedule: Equatable, Sendable {
    public let retryDelay: TimeInterval
    private var deadlines: [String: TimeInterval] = [:]

    public init(retryDelay: TimeInterval) {
        self.retryDelay = retryDelay
    }

    public var nextDeadline: TimeInterval? {
        deadlines.values.min()
    }

    public mutating func enqueue(messageID: String, now: TimeInterval) {
        guard !messageID.isEmpty, deadlines[messageID] == nil else { return }
        deadlines[messageID] = now + retryDelay
    }

    public func dueMessageIDs(at now: TimeInterval) -> [String] {
        deadlines
            .filter { $0.value <= now }
            .sorted {
                if $0.value == $1.value { return $0.key < $1.key }
                return $0.value < $1.value
            }
            .map(\.key)
    }

    public mutating func markAttempted(messageID: String, now: TimeInterval) {
        guard deadlines[messageID] != nil else { return }
        deadlines[messageID] = now + retryDelay
    }

    public mutating func acknowledge(messageID: String) {
        deadlines.removeValue(forKey: messageID)
    }
}

public enum TaskFeedbackOutcome: Equatable, Sendable {
    case completed
    case interrupted
    case failed

    public static func resolve(
        wasBusy: Bool,
        wasInterrupting: Bool,
        failed: Bool
    ) -> TaskFeedbackOutcome? {
        guard wasBusy else { return nil }
        if failed { return .failed }
        if wasInterrupting { return .interrupted }
        return .completed
    }
}

public enum RecoveryPersistenceGate {
    public static func mayRemoveOutbox(
        recoveryRequired: Bool,
        recoveryPersisted: Bool
    ) -> Bool {
        !recoveryRequired || recoveryPersisted
    }
}

public struct TaskFeedbackCoordinator: Equatable, Sendable {
    private var generation: UInt64 = 0
    private var pendingCompletion: UInt64?

    public init() {}

    public mutating func scheduleCompletion() -> UInt64 {
        generation &+= 1
        pendingCompletion = generation
        return generation
    }

    public mutating func recordFailure() {
        generation &+= 1
        pendingCompletion = nil
    }

    public mutating func cancelCompletion() {
        generation &+= 1
        pendingCompletion = nil
    }

    public mutating func consumeCompletion(_ token: UInt64) -> Bool {
        guard pendingCompletion == token else { return false }
        pendingCompletion = nil
        return true
    }
}
