import { readFileSync } from "node:fs";

const source = readFileSync(
  new URL("../Sources/CodexRemoteMac/main.swift", import.meta.url),
  "utf8",
);

function requireMatch(pattern, message) {
  if (!pattern.test(source)) throw new Error(message);
}

requireMatch(
  /private var companionTurnReconciliationAt: \[String: Date\] = \[:\]/,
  "companion turns need a per-thread reconciliation clock",
);
requireMatch(
  /private var snapshotFinalAnswerGate = SnapshotFinalAnswerGate\(\)/,
  "snapshot completion needs a final-answer settlement gate",
);

const timerStart = source.indexOf("private func startSyncTimer()");
const timerEnd = source.indexOf("private func listModels()", timerStart);
if (timerStart < 0 || timerEnd < 0) {
  throw new Error("could not locate the sync timer implementation");
}
const timer = source.slice(timerStart, timerEnd);

if (!/if isCompanionTurn \{[\s\S]*?companionTurnReconciliationAt\[watched\][\s\S]*?readThread\([\s\S]*?watched,[\s\S]*?queueIfBusy: false,[\s\S]*?allowDesktopFallback: true[\s\S]*?\)/.test(timer)) {
  throw new Error(
    "the sync timer must periodically reconcile companion turns instead of trusting one completion notification",
  );
}

if (!/timeIntervalSince\(lastReconciliation\) >= 6/.test(timer)) {
  throw new Error("companion reconciliation must be throttled to avoid loading full history continuously");
}

requireMatch(
  /companionTurnReconciliationAt\.removeAll\(\)/,
  "app-server restart must clear companion reconciliation clocks",
);

const snapshotStart = source.indexOf("private func emitSnapshot(");
const snapshotEnd = source.indexOf("private func recentRawTranscriptItems", snapshotStart);
if (snapshotStart < 0 || snapshotEnd < 0) {
  throw new Error("could not locate snapshot reconciliation");
}
const snapshot = source.slice(snapshotStart, snapshotEnd);
if (!/pendingTurnContexts\.removeValue\(forKey: inactiveTurnID\)[\s\S]*?markTurnInactiveIfCurrent\([\s\S]*?emitAuthoritativeTaskState\(/.test(snapshot)) {
  throw new Error(
    "a terminal snapshot must clear the pending turn and emit the missed busy=false state",
  );
}
if (!/snapshotFinalAnswerGate\.shouldTreatAsTerminal\([\s\S]*?hasFinalAnswer: finalAnswerIsTerminal/.test(snapshot)) {
  throw new Error(
    "snapshot reconciliation must delay final-answer fallback before resolving terminal activity",
  );
}
if (!/SnapshotTerminalStatusPolicy\.statusForResolution\([\s\S]*?rawStatus: statusForActivity/.test(snapshot)) {
  throw new Error(
    "snapshot reconciliation must suppress stale terminal status for the active turn",
  );
}
if (!/scheduleSnapshotFinalAnswerRecheck\([\s\S]*?threadID: summary\.id,[\s\S]*?turnID: latestTurnID/.test(snapshot)) {
  throw new Error(
    "a deferred final answer must schedule a bounded reconciliation read",
  );
}

requireMatch(
  /private func markTurnInactiveIfCurrent\([\s\S]*?clearSnapshotFinalAnswerTracking\(threadID: threadId, turnID: turnId\)/,
  "every authoritative inactivation must clear final-answer tracking",
);
requireMatch(
  /case "turn\/started":[\s\S]*?if activeTurns\[threadId\] != turnId \{[\s\S]*?clearSnapshotFinalAnswerTracking\(threadID: threadId\)/,
  "a duplicate turn/started notification must preserve an existing settlement observation",
);
requireMatch(
  /private func markThreadDeleted\([\s\S]*?clearSnapshotFinalAnswerTracking\(threadID: threadId\)/,
  "deleting a task must cancel its final-answer reconciliation",
);
requireMatch(
  /self\.activeTurns\.removeAll\(\)[\s\S]*?self\.resetAllSnapshotFinalAnswerTracking\(\)/,
  "app-server restart must clear all final-answer reconciliation state",
);

console.log(JSON.stringify({
  ok: true,
  companionTurnCompletionFallback: true,
  missedCompletionStateRecovered: true,
  finalAnswerSettlementGraceSeconds: 2,
  minimumPollIntervalSeconds: 6,
}));
