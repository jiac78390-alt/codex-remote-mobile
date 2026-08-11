import Foundation

@main
private enum MobileRecoveryStateRegression {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() throws {
        try failedDeliveryRetainsCompleteSubmission()
        safeComposerMergePreservesNewerText()
        retryDeadlinesRemainIndependent()
        secretFallbackSurvivesKeychainFailure()
        feedbackOutcomesAreSemantic()
        createdThreadFailureRecoversIntoCreatedTask()
        recoveryMustPersistBeforeOutboxRemoval()
        delayedSuccessIsCancelledByLateFailure()
        turnActivityUsesAuthoritativeState()
        snapshotFinalAnswerWaitsForBackendSettlement()
        snapshotTerminalStatusNeedsCompletionEvidence()
        turnInactivationUsesCompareAndSwap()
        newerTurnDecisionPromotesRuntimeState()
        completedTurnCannotBeReactivatedByLateStart()
        completedTurnInterruptsBypassBackend()
        justStartedInterruptRetriesTransientNoActive()
        staleInterruptAcknowledgementSelfHeals()
        reliableInterruptsWaitForRuntimeConfirmation()
        reliableCommandsPreserveInterruptOrdering()
        stalledRuntimeConfirmationUsesBoundedFallback()
        print("PASS mobile recovery state")
    }

    private static func failedDeliveryRetainsCompleteSubmission() throws {
        let attachment = RemoteAttachment(
            id: "photo-1",
            name: "camera.jpg",
            kind: "image",
            mimeType: "image/jpeg",
            dataBase64: Data("camera-bytes".utf8).base64EncodedString(),
            sizeBytes: 12
        )
        let skill = RemoteSkill(
            name: "documents",
            path: "/skills/documents/SKILL.md",
            detail: "Open a document",
            pluginName: "documents"
        )
        let delivery = FailedDelivery(
            id: "message-1",
            contextID: "task:thread-1",
            commandType: RemoteMessage.prompt,
            text: "检查附件",
            attachments: [attachment],
            skills: [skill],
            createdAt: 100
        )

        let data = try JSONEncoder().encode(delivery)
        let restored = try JSONDecoder().decode(FailedDelivery.self, from: data)
        expect(restored == delivery, "failed delivery must round-trip without losing submission data")
        expect(restored.attachments.first?.dataBase64 == attachment.dataBase64,
               "failed delivery must retain attachment bytes")
        expect(restored.skills.first?.path == skill.path,
               "failed delivery must retain selected skills")
    }

    private static func safeComposerMergePreservesNewerText() {
        expect(
            ComposerDraftState.merged(existing: "新的未发送内容", recovered: "旧的失败内容")
                == "新的未发送内容\n\n旧的失败内容",
            "recovery must append instead of overwriting a newer draft"
        )
        expect(
            ComposerDraftState.merged(existing: "", recovered: "恢复内容") == "恢复内容",
            "recovery may fill an empty composer"
        )
        expect(
            ComposerDraftState.merged(existing: "相同内容", recovered: "相同内容") == "相同内容",
            "recovery must not duplicate identical text"
        )
        expect(
            ComposerDraftState.merged(existing: "新的内容\n\n恢复内容", recovered: "恢复内容")
                == "新的内容\n\n恢复内容",
            "recovery must not duplicate content already appended to a newer draft"
        )
    }

    private static func retryDeadlinesRemainIndependent() {
        var schedule = ReliableRetrySchedule(retryDelay: 8)
        schedule.enqueue(messageID: "first", now: 0)
        schedule.enqueue(messageID: "second", now: 7)

        expect(schedule.nextDeadline == 8, "a newer command must not postpone the oldest deadline")
        expect(schedule.dueMessageIDs(at: 8) == ["first"], "only the first command should be due")

        schedule.markAttempted(messageID: "first", now: 8)
        expect(schedule.nextDeadline == 15, "the second command must keep its original deadline")
        schedule.acknowledge(messageID: "second")
        expect(schedule.nextDeadline == 16, "acknowledging one command must not remove another deadline")
    }

    private static func secretFallbackSurvivesKeychainFailure() {
        var fallback: String?
        var removalCount = 0
        let securelyPersisted = SecretFallbackStore.persist(
            value: "pairing-key",
            persistSecurely: { _ in false },
            storeFallback: { fallback = $0 },
            removeFallback: {
                removalCount += 1
                fallback = nil
            }
        )
        expect(!securelyPersisted, "a rejected Keychain write must be reported")
        expect(fallback == "pairing-key", "a rejected Keychain write must retain the fallback")
        expect(removalCount == 0, "the fallback must not be deleted after a rejected Keychain write")

        fallback = "old-key"
        let migrated = SecretFallbackStore.persist(
            value: "pairing-key",
            persistSecurely: { _ in true },
            storeFallback: { fallback = $0 },
            removeFallback: {
                removalCount += 1
                fallback = nil
            }
        )
        expect(migrated, "a successful Keychain write must be reported")
        expect(fallback == nil, "a successful Keychain write may remove the fallback")
        expect(removalCount == 1, "the fallback must be removed exactly once after migration")
    }

    private static func feedbackOutcomesAreSemantic() {
        expect(
            TaskFeedbackOutcome.resolve(wasBusy: true, wasInterrupting: false, failed: false) == .completed,
            "normal completion must be successful"
        )
        expect(
            TaskFeedbackOutcome.resolve(wasBusy: true, wasInterrupting: true, failed: false) == .interrupted,
            "an interrupted turn must not report success"
        )
        expect(
            TaskFeedbackOutcome.resolve(wasBusy: true, wasInterrupting: false, failed: true) == .failed,
            "a failed turn must not report success"
        )
        expect(
            TaskFeedbackOutcome.resolve(wasBusy: true, wasInterrupting: true, failed: true) == .failed,
            "failure must take precedence over interruption"
        )
        expect(
            TaskFeedbackOutcome.resolve(wasBusy: false, wasInterrupting: false, failed: false) == nil,
            "an idle snapshot must not emit terminal feedback"
        )
    }

    private static func createdThreadFailureRecoversIntoCreatedTask() {
        let plan = FailedDeliveryRecoveryPlan.resolve(
            commandType: RemoteMessage.taskCreate,
            commandThreadID: nil,
            acknowledgedThreadID: "created-thread",
            projectID: "project-1",
            cwd: "/workspace"
        )
        expect(plan?.contextID == ComposerDraftState.taskContextID("created-thread"),
               "a failed first turn must recover into the thread that was already created")
        expect(plan?.createdThreadID == "created-thread",
               "the client must recover the acknowledged created thread instead of creating another")

        let preCreationFailure = FailedDeliveryRecoveryPlan.resolve(
            commandType: RemoteMessage.taskCreate,
            commandThreadID: nil,
            acknowledgedThreadID: nil,
            projectID: "project-1",
            cwd: "/workspace"
        )
        expect(preCreationFailure?.contextID == "new:project:project-1",
               "a failure before thread creation must remain in the new-task composer")

        let restoredOutboxPlan = FailedDeliveryRecoveryPlan.resolve(
            commandType: RemoteMessage.taskCreate,
            commandThreadID: "created-thread",
            acknowledgedThreadID: nil,
            projectID: "project-1",
            cwd: "/workspace"
        )
        expect(restoredOutboxPlan?.contextID == ComposerDraftState.taskContextID("created-thread"),
               "a restored outbox must remember that taskCreate already produced a thread")
    }

    private static func recoveryMustPersistBeforeOutboxRemoval() {
        expect(
            !RecoveryPersistenceGate.mayRemoveOutbox(
                recoveryRequired: true,
                recoveryPersisted: false
            ),
            "a failed cache write must leave the reliable command in the outbox"
        )
        expect(
            RecoveryPersistenceGate.mayRemoveOutbox(
                recoveryRequired: true,
                recoveryPersisted: true
            ),
            "the outbox may be cleared only after the full failed delivery is durable"
        )
    }

    private static func delayedSuccessIsCancelledByLateFailure() {
        var coordinator = TaskFeedbackCoordinator()
        let sequence = [
            RemoteEvent(type: RemoteMessage.taskState, threadId: "thread-1", busy: false),
            RemoteEvent(type: RemoteMessage.error, threadId: "thread-1", message: "turn failed")
        ]
        var completion: UInt64?
        for event in sequence {
            if event.type == RemoteMessage.taskState, event.busy == false {
                completion = coordinator.scheduleCompletion()
            } else if event.type == RemoteMessage.error {
                coordinator.recordFailure()
            }
        }
        expect(completion != nil, "busy=false must schedule delayed success feedback")
        expect(!coordinator.consumeCompletion(completion ?? 0),
               "an error arriving after busy=false must cancel pending success feedback")

        let successfulCompletion = coordinator.scheduleCompletion()
        expect(coordinator.consumeCompletion(successfulCompletion),
               "a completion with no late failure must still emit success")
        expect(!coordinator.consumeCompletion(successfulCompletion),
               "a completion token must be consumed at most once")
    }

    private static func turnActivityUsesAuthoritativeState() {
        let completed = TurnActivityResolver.resolve(
            latestTurnID: "A",
            rawStatus: "completed",
            observedActiveTurnID: "A",
            knownCompletedTurnID: nil,
            hasFinalAnswer: false,
            hasError: false
        )
        expect(completed.activeTurnID == nil, "a completed turn must never remain busy")
        expect(completed.inactiveTurnID == "A", "a completed turn must be remembered")

        let running = TurnActivityResolver.resolve(
            latestTurnID: "A",
            rawStatus: "inProgress",
            observedActiveTurnID: nil,
            knownCompletedTurnID: nil,
            hasFinalAnswer: false,
            hasError: false
        )
        expect(running.activeTurnID == "A", "an explicit in-progress status must be busy")

        let notificationBacked = TurnActivityResolver.resolve(
            latestTurnID: "A",
            rawStatus: nil,
            observedActiveTurnID: "A",
            knownCompletedTurnID: nil,
            hasFinalAnswer: false,
            hasError: false
        )
        expect(notificationBacked.activeTurnID == "A",
               "missing status may retain a turn observed through turn/started")

        let contentOnly = TurnActivityResolver.resolve(
            latestTurnID: "A",
            rawStatus: nil,
            observedActiveTurnID: nil,
            knownCompletedTurnID: nil,
            hasFinalAnswer: false,
            hasError: false
        )
        expect(contentOnly.activeTurnID == nil,
               "content without a runtime event must not invent a busy turn")

        let lateCompletedSnapshot = TurnActivityResolver.resolve(
            latestTurnID: "A",
            rawStatus: "completed",
            observedActiveTurnID: "B",
            knownCompletedTurnID: nil,
            hasFinalAnswer: false,
            hasError: false
        )
        expect(lateCompletedSnapshot.activeTurnID == "B",
               "completion for an old turn must not clear a newer active turn")

        let rememberedCompletion = TurnActivityResolver.resolve(
            latestTurnID: "A",
            rawStatus: nil,
            observedActiveTurnID: "A",
            knownCompletedTurnID: "A",
            hasFinalAnswer: false,
            hasError: false
        )
        expect(rememberedCompletion.activeTurnID == nil,
               "a missing final answer must not resurrect a known completed turn")

        let unknownExplicitStatus = TurnActivityResolver.resolve(
            latestTurnID: "A",
            rawStatus: "queued",
            observedActiveTurnID: "A",
            knownCompletedTurnID: nil,
            hasFinalAnswer: false,
            hasError: false
        )
        expect(unknownExplicitStatus.activeTurnID == "A",
               "an unknown status must preserve a turn observed through turn/started")
        expect(unknownExplicitStatus.inactiveTurnID == nil,
               "an unknown status must not invent a terminal transition")

        let staleRunningSnapshot = TurnActivityResolver.resolve(
            latestTurnID: "A",
            rawStatus: "running",
            observedActiveTurnID: "B",
            knownCompletedTurnID: nil,
            hasFinalAnswer: false,
            hasError: false
        )
        expect(staleRunningSnapshot.activeTurnID == "B",
               "a stale snapshot must not replace a newer observed turn")
    }

    private static func snapshotFinalAnswerWaitsForBackendSettlement() {
        var gate = SnapshotFinalAnswerGate(gracePeriod: 2)
        let firstFinalAnswer = gate.shouldTreatAsTerminal(
            threadID: "thread-1",
            turnID: "A",
            observedActiveTurnID: "A",
            hasFinalAnswer: true,
            now: 100
        )
        expect(!firstFinalAnswer,
               "the first final answer snapshot must not finish an active backend turn")

        let stillRunning = TurnActivityResolver.resolve(
            latestTurnID: "A",
            rawStatus: "inProgress",
            observedActiveTurnID: "A",
            knownCompletedTurnID: nil,
            hasFinalAnswer: firstFinalAnswer,
            hasError: false
        )
        expect(stillRunning.activeTurnID == "A",
               "an in-progress backend turn must stay busy during the final-answer grace period")
        expect(stillRunning.inactiveTurnID == nil,
               "a final answer alone must not admit the next prompt immediately")

        expect(
            !gate.shouldTreatAsTerminal(
                threadID: "thread-1",
                turnID: "A",
                observedActiveTurnID: "A",
                hasFinalAnswer: true,
                now: 101.999
            ),
            "the fallback must remain closed before the full grace period"
        )

        let explicitCompletion = TurnActivityResolver.resolve(
            latestTurnID: "A",
            rawStatus: "completed",
            observedActiveTurnID: "A",
            knownCompletedTurnID: nil,
            hasFinalAnswer: false,
            hasError: false
        )
        expect(explicitCompletion.inactiveTurnID == "A",
               "an authoritative completed status must bypass the fallback delay")

        let settledFinalAnswer = gate.shouldTreatAsTerminal(
            threadID: "thread-1",
            turnID: "A",
            observedActiveTurnID: "A",
            hasFinalAnswer: true,
            now: 102
        )
        expect(settledFinalAnswer,
               "a persistent final answer must recover a missed completion after the grace period")
        let recoveredCompletion = TurnActivityResolver.resolve(
            latestTurnID: "A",
            rawStatus: "inProgress",
            observedActiveTurnID: "A",
            knownCompletedTurnID: nil,
            hasFinalAnswer: settledFinalAnswer,
            hasError: false
        )
        expect(recoveredCompletion.activeTurnID == nil,
               "the settled final answer fallback must clear the stuck busy state")
        expect(recoveredCompletion.inactiveTurnID == "A",
               "the settled fallback must remember the recovered completed turn")

        gate.clear(threadID: "thread-1", turnID: "A")
        expect(
            !gate.shouldTreatAsTerminal(
                threadID: "thread-1",
                turnID: "B",
                observedActiveTurnID: "B",
                hasFinalAnswer: true,
                now: 200
            ),
            "a new turn must receive its own grace period"
        )
        gate.clear(threadID: "thread-1")
        expect(
            gate.shouldTreatAsTerminal(
                threadID: "thread-1",
                turnID: "B",
                observedActiveTurnID: nil,
                hasFinalAnswer: true,
                now: 201
            ),
            "a historical final answer with no active turn may be accepted immediately"
        )
    }

    private static func snapshotTerminalStatusNeedsCompletionEvidence() {
        let staleStatus = SnapshotTerminalStatusPolicy.statusForResolution(
            latestTurnID: "A",
            rawStatus: "completed",
            observedActiveTurnID: "A",
            hasTerminalEvidence: false
        )
        expect(staleStatus == nil,
               "a snapshot must not complete the active turn without terminal evidence")
        let protectedActivity = TurnActivityResolver.resolve(
            latestTurnID: "A",
            rawStatus: staleStatus,
            observedActiveTurnID: "A",
            knownCompletedTurnID: nil,
            hasFinalAnswer: false,
            hasError: false
        )
        expect(protectedActivity.activeTurnID == "A",
               "a stale completed snapshot must not admit another prompt")
        expect(protectedActivity.inactiveTurnID == nil,
               "a stale completed snapshot must not poison late turn/started admission")

        expect(
            SnapshotTerminalStatusPolicy.statusForResolution(
                latestTurnID: "A",
                rawStatus: "completed",
                observedActiveTurnID: "A",
                hasTerminalEvidence: true
            ) == "completed",
            "a settled final answer or error may confirm the terminal snapshot"
        )
        expect(
            SnapshotTerminalStatusPolicy.statusForResolution(
                latestTurnID: "A",
                rawStatus: "completed",
                observedActiveTurnID: nil,
                hasTerminalEvidence: false
            ) == "completed",
            "a historical snapshot may recover terminal state when no turn is active"
        )
        expect(
            SnapshotTerminalStatusPolicy.statusForResolution(
                latestTurnID: "A",
                rawStatus: "completed",
                observedActiveTurnID: "B",
                hasTerminalEvidence: false
            ) == "completed",
            "a terminal snapshot for an older turn must not be hidden from a newer turn"
        )
        expect(
            SnapshotTerminalStatusPolicy.statusForResolution(
                latestTurnID: "A",
                rawStatus: "inProgress",
                observedActiveTurnID: "A",
                hasTerminalEvidence: false
            ) == "inProgress",
            "running status must pass through unchanged"
        )
    }

    private static func turnInactivationUsesCompareAndSwap() {
        expect(
            TurnInactivationResolver.resolve(
                targetTurnID: "A",
                currentActiveTurnID: "A",
                cachedBusy: true,
                cachedTurnID: "A",
                backendConfirmedNoActive: false
            ) == .changed,
            "the current target turn may be cleared"
        )
        expect(
            TurnInactivationResolver.resolve(
                targetTurnID: "A",
                currentActiveTurnID: "B",
                cachedBusy: true,
                cachedTurnID: "B",
                backendConfirmedNoActive: false
            ) == .newerTurn("B"),
            "a late completion for A must preserve active turn B"
        )
        expect(
            TurnInactivationResolver.resolve(
                targetTurnID: "A",
                currentActiveTurnID: nil,
                cachedBusy: true,
                cachedTurnID: "B",
                backendConfirmedNoActive: false
            ) == .newerTurn("B"),
            "a cached newer turn must survive an unconfirmed old completion"
        )
        expect(
            TurnInactivationResolver.resolve(
                targetTurnID: "A",
                currentActiveTurnID: "A",
                cachedBusy: true,
                cachedTurnID: "B",
                backendConfirmedNoActive: false
            ) == .newerTurn("B"),
            "a conflicting newer cache must block clearing until a live read resolves it"
        )
        expect(
            TurnInactivationResolver.resolve(
                targetTurnID: "A",
                currentActiveTurnID: nil,
                cachedBusy: true,
                cachedTurnID: "B",
                backendConfirmedNoActive: true
            ) == .newerTurn("B"),
            "a target-specific no-active result must not clear a different cached turn"
        )
        expect(
            TurnInactivationResolver.resolve(
                targetTurnID: "A",
                currentActiveTurnID: nil,
                cachedBusy: false,
                cachedTurnID: nil,
                backendConfirmedNoActive: false
            ) == .alreadyInactive,
            "an idle runtime must remain idempotently idle"
        )
    }

    private static func newerTurnDecisionPromotesRuntimeState() {
        expect(
            TurnInactivationApplication.activeTurnID(
                targetTurnID: "A",
                currentActiveTurnID: "A",
                decision: .newerTurn("B")
            ) == "B",
            "a cached newer turn must replace the stale target turn"
        )
        expect(
            TurnInactivationApplication.activeTurnID(
                targetTurnID: "A",
                currentActiveTurnID: nil,
                decision: .newerTurn("B")
            ) == "B",
            "a newer turn must be restored when the active map is empty"
        )
        expect(
            TurnInactivationApplication.activeTurnID(
                targetTurnID: "A",
                currentActiveTurnID: "C",
                decision: .newerTurn("B")
            ) == "C",
            "a late decision must not replace an independently observed newer turn"
        )
    }

    private static func completedTurnInterruptsBypassBackend() {
        expect(
            !CompletedTurnInterruptPolicy.shouldContactBackend(
                requestedTurnID: "A",
                knownCompletedTurnID: "A"
            ),
            "a repeated interrupt for the same completed turn must stay local"
        )
        expect(
            CompletedTurnInterruptPolicy.shouldContactBackend(
                requestedTurnID: "B",
                knownCompletedTurnID: "A"
            ),
            "a different turn must still reach the backend"
        )
        expect(
            CompletedTurnInterruptPolicy.shouldContactBackend(
                requestedTurnID: nil,
                knownCompletedTurnID: "A"
            ),
            "a nil-turn interrupt must preserve runtime reconciliation"
        )
    }

    private static func completedTurnCannotBeReactivatedByLateStart() {
        expect(
            !TurnStartAdmissionPolicy.shouldActivate(
                turnID: "A",
                knownCompletedTurnID: "A"
            ),
            "a late start response must not reactivate an already completed turn"
        )
        expect(
            TurnStartAdmissionPolicy.shouldActivate(
                turnID: "B",
                knownCompletedTurnID: "A"
            ),
            "a genuinely newer turn must remain eligible for activation"
        )
    }

    private static func justStartedInterruptRetriesTransientNoActive() {
        expect(
            InterruptNoActiveRetryPolicy.shouldRetry(
                requestedTurnID: "A",
                currentActiveTurnID: "A",
                hasPendingStartContext: true,
                retryAttempt: 0
            ),
            "a no-active response immediately after turn/start must be retried"
        )
        expect(
            !InterruptNoActiveRetryPolicy.shouldRetry(
                requestedTurnID: "A",
                currentActiveTurnID: nil,
                hasPendingStartContext: true,
                retryAttempt: 0
            ),
            "an already inactive runtime must not be retried"
        )
        expect(
            !InterruptNoActiveRetryPolicy.shouldRetry(
                requestedTurnID: "A",
                currentActiveTurnID: "A",
                hasPendingStartContext: true,
                retryAttempt: InterruptNoActiveRetryPolicy.maximumRetries
            ),
            "transient no-active retries must remain bounded"
        )
    }

    private static func staleInterruptAcknowledgementSelfHeals() {
        var stale = MobileTaskRuntimeState(
            isBusy: true,
            isInterrupting: true,
            activeTurnID: "A"
        )
        let healed = stale.reconcileInterruptAcknowledgement(
            commandTurnID: "A",
            accepted: false,
            code: RemoteEventCode.noActiveTurn
        )
        expect(healed, "no-active acknowledgement must satisfy a stale stop request")
        expect(!stale.isBusy && !stale.isInterrupting && stale.activeTurnID == nil,
               "stale stop acknowledgement must clear all matching runtime state")

        var ordinaryFailure = MobileTaskRuntimeState(
            isBusy: true,
            isInterrupting: true,
            activeTurnID: "A"
        )
        let ordinaryCleared = ordinaryFailure.reconcileInterruptAcknowledgement(
            commandTurnID: "A",
            accepted: false,
            code: nil
        )
        expect(!ordinaryCleared && ordinaryFailure.isBusy,
               "an ordinary stop failure must not pretend the turn ended")
        expect(!ordinaryFailure.isInterrupting,
               "an ordinary stop failure may allow a deliberate retry")

        var newerTurn = MobileTaskRuntimeState(
            isBusy: true,
            isInterrupting: true,
            activeTurnID: "B"
        )
        let oldAcknowledgementCleared = newerTurn.reconcileInterruptAcknowledgement(
            commandTurnID: "A",
            accepted: true,
            code: RemoteEventCode.noActiveTurn
        )
        expect(!oldAcknowledgementCleared, "an old acknowledgement must not clear a newer turn")
        expect(newerTurn.isBusy && newerTurn.isInterrupting && newerTurn.activeTurnID == "B",
               "newer runtime state must survive a late old-turn acknowledgement")

        var newerTurnAfterUncorrelatedInterrupt = MobileTaskRuntimeState(
            isBusy: true,
            isInterrupting: true,
            activeTurnID: "B"
        )
        let nilTurnAcknowledgementCleared = newerTurnAfterUncorrelatedInterrupt
            .reconcileInterruptAcknowledgement(
                commandTurnID: nil,
                accepted: true,
                code: RemoteEventCode.noActiveTurn
            )
        expect(!nilTurnAcknowledgementCleared,
               "an uncorrelated acknowledgement must not clear a newer identified turn")
        expect(newerTurnAfterUncorrelatedInterrupt.isBusy
                && newerTurnAfterUncorrelatedInterrupt.isInterrupting
                && newerTurnAfterUncorrelatedInterrupt.activeTurnID == "B",
               "a newer identified turn must survive a late nil-turn acknowledgement")

        var newerTurnAfterUncorrelatedFailure = MobileTaskRuntimeState(
            isBusy: true,
            isInterrupting: true,
            activeTurnID: "B"
        )
        let nilTurnFailureCleared = newerTurnAfterUncorrelatedFailure
            .reconcileInterruptAcknowledgement(
                commandTurnID: nil,
                accepted: false,
                code: nil
            )
        expect(!nilTurnFailureCleared,
               "an uncorrelated failure must not settle a newer identified turn")
        expect(newerTurnAfterUncorrelatedFailure.isBusy
                && newerTurnAfterUncorrelatedFailure.isInterrupting
                && newerTurnAfterUncorrelatedFailure.activeTurnID == "B",
               "a late nil-turn failure must not clear the newer turn's interrupt state")

        var unidentifiedBusyTurn = MobileTaskRuntimeState(
            isBusy: true,
            isInterrupting: true,
            activeTurnID: nil
        )
        let unidentifiedTurnHealed = unidentifiedBusyTurn.reconcileInterruptAcknowledgement(
            commandTurnID: nil,
            accepted: false,
            code: RemoteEventCode.noActiveTurn
        )
        expect(unidentifiedTurnHealed,
               "no-active acknowledgement must heal busy state when neither side has a turn ID")
        expect(!unidentifiedBusyTurn.isBusy
                && !unidentifiedBusyTurn.isInterrupting
                && unidentifiedBusyTurn.activeTurnID == nil,
               "an unidentified inactive turn must clear all stale runtime state")
    }

    private static func reliableInterruptsWaitForRuntimeConfirmation() {
        let duplicateCandidates = [
            ReliableInterruptCandidate(messageID: "first", turnID: "A", createdAt: 1),
            ReliableInterruptCandidate(messageID: "second", turnID: "A", createdAt: 2)
        ]
        let compacted = ReliableInterruptPolicy.reconcile(
            duplicateCandidates,
            busy: true,
            activeTurnID: "A",
            inactiveTurnID: nil,
            isFullSnapshot: true,
            wasAwaitingRuntimeConfirmation: true
        )
        expect(compacted.messageIDToSend == "first",
               "reconnect must replay at most one interrupt for the confirmed turn")
        expect(compacted.discardedMessageIDs == ["second"],
               "duplicate interrupts for one turn must be compacted")

        let uncorrelatedBusy = ReliableInterruptPolicy.reconcile(
            duplicateCandidates,
            busy: true,
            activeTurnID: nil,
            inactiveTurnID: nil,
            isFullSnapshot: true,
            wasAwaitingRuntimeConfirmation: true
        )
        expect(uncorrelatedBusy.deferUntilRuntimeConfirmation,
               "busy without a turn ID must not replay a stale interrupt")
        expect(uncorrelatedBusy.messageIDToSend == nil,
               "an uncorrelated interrupt must remain deferred")

        let unidentifiedCandidate = [
            ReliableInterruptCandidate(messageID: "unknown", turnID: nil, createdAt: 1)
        ]
        let identifiedNewerTurn = ReliableInterruptPolicy.reconcile(
            unidentifiedCandidate,
            busy: true,
            activeTurnID: "B",
            inactiveTurnID: nil,
            isFullSnapshot: true,
            wasAwaitingRuntimeConfirmation: true
        )
        expect(identifiedNewerTurn.discardedMessageIDs == ["unknown"],
               "an unidentified stale interrupt must be discarded when runtime identifies B")
        expect(identifiedNewerTurn.messageIDToSend == nil,
               "an unidentified stale interrupt must never be replayed against identified B")
        expect(!identifiedNewerTurn.deferUntilRuntimeConfirmation,
               "an authoritative identified turn settles the ambiguous stale interrupt")

        let unidentifiedRuntime = ReliableInterruptPolicy.reconcile(
            unidentifiedCandidate,
            busy: true,
            activeTurnID: nil,
            inactiveTurnID: nil,
            isFullSnapshot: true,
            wasAwaitingRuntimeConfirmation: true
        )
        expect(unidentifiedRuntime.deferUntilRuntimeConfirmation,
               "an unidentified interrupt and unidentified busy runtime must remain deferred")
        expect(unidentifiedRuntime.messageIDToSend == nil,
               "an unidentified runtime must not receive an ambiguous interrupt")

        let mixedCandidates = [
            ReliableInterruptCandidate(messageID: "old-A", turnID: "A", createdAt: 1),
            ReliableInterruptCandidate(messageID: "current-B", turnID: "B", createdAt: 2)
        ]
        let newerTurn = ReliableInterruptPolicy.reconcile(
            mixedCandidates,
            busy: true,
            activeTurnID: "B",
            inactiveTurnID: nil,
            isFullSnapshot: true,
            wasAwaitingRuntimeConfirmation: true
        )
        expect(newerTurn.discardedMessageIDs == ["old-A"],
               "runtime confirmation for B must discard a stale A interrupt")
        expect(newerTurn.messageIDToSend == "current-B",
               "only the interrupt matching active turn B may replay")

        let lateACompletion = ReliableInterruptPolicy.reconcile(
            mixedCandidates,
            busy: false,
            activeTurnID: nil,
            inactiveTurnID: "A",
            isFullSnapshot: false,
            wasAwaitingRuntimeConfirmation: true
        )
        expect(lateACompletion.discardedMessageIDs == ["old-A"],
               "a late A completion may settle only A's interrupt")
        expect(!lateACompletion.discardedMessageIDs.contains("current-B"),
               "a late A completion must preserve B's interrupt")
        expect(lateACompletion.deferUntilRuntimeConfirmation,
               "a partial A completion must keep B deferred during reconnect")
        expect(lateACompletion.messageIDToSend == nil,
               "a partial completion must not replay B without B confirmation")

        let authoritativeIdle = ReliableInterruptPolicy.reconcile(
            mixedCandidates,
            busy: false,
            activeTurnID: nil,
            inactiveTurnID: nil,
            isFullSnapshot: true,
            wasAwaitingRuntimeConfirmation: true
        )
        expect(Set(authoritativeIdle.discardedMessageIDs) == Set(["old-A", "current-B"]),
               "an authoritative idle snapshot satisfies all pending stops for the thread")

        let unidentifiedAuthoritativeIdle = ReliableInterruptPolicy.reconcile(
            unidentifiedCandidate,
            busy: false,
            activeTurnID: nil,
            inactiveTurnID: nil,
            isFullSnapshot: true,
            wasAwaitingRuntimeConfirmation: true
        )
        expect(unidentifiedAuthoritativeIdle.discardedMessageIDs == ["unknown"],
               "an authoritative idle snapshot must discard an unidentified stale interrupt")
        expect(unidentifiedAuthoritativeIdle.messageIDToSend == nil
                && !unidentifiedAuthoritativeIdle.deferUntilRuntimeConfirmation,
               "authoritative idle must fully settle the unidentified interrupt")
    }

    private static func reliableCommandsPreserveInterruptOrdering() {
        let pendingInterrupt = [
            ReliableInterruptCandidate(messageID: "stop-A", turnID: "A", createdAt: 10)
        ]
        expect(
            ReliableCommandOrderingPolicy.shouldDeferUntilInterruptSettles(
                commandCreatedAt: 11,
                pendingInterrupts: pendingInterrupt
            ),
            "a command created after stop A must wait until the stop settles"
        )
        expect(
            !ReliableCommandOrderingPolicy.shouldDeferUntilInterruptSettles(
                commandCreatedAt: 9,
                pendingInterrupts: pendingInterrupt
            ),
            "a command created before stop A must retain its original delivery order"
        )
        expect(
            ReliableCommandOrderingPolicy.shouldDeferUntilInterruptSettles(
                commandCreatedAt: nil,
                pendingInterrupts: pendingInterrupt
            ),
            "a restored command with unknown ordering must wait conservatively"
        )
        expect(
            !ReliableCommandOrderingPolicy.shouldDeferUntilInterruptSettles(
                commandCreatedAt: 11,
                pendingInterrupts: []
            ),
            "a later command may resume immediately after the stop leaves the outbox"
        )
    }

    private static func stalledRuntimeConfirmationUsesBoundedFallback() {
        let pending = [
            ReliableInterruptCandidate(
                messageID: "stale-stop",
                turnID: "old-turn",
                createdAt: 1
            )
        ]
        expect(
            ReliableInterruptFallbackPolicy.messageIDToProbe(
                pending,
                confirmationWaitElapsed: false
            ) == nil,
            "a reconnect must still wait briefly for authoritative runtime state"
        )
        expect(
            ReliableInterruptFallbackPolicy.messageIDToProbe(
                pending,
                confirmationWaitElapsed: true
            ) == "stale-stop",
            "a missing runtime snapshot must not block later prompts forever"
        )
    }
}
