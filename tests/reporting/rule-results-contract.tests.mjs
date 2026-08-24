/**
 * 역할: loader, view model과 output manager가 TestResult 상태와 report directory 경계를 보존하는지 검증한다.
 * 경계: 임시 Fake JSON만 사용하며 workbook, HTS, FlaUI를 실행하지 않는다.
 */
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { loadRuleResults } from "../../tools/reporting/rule-results-loader.mjs";
import { createRuleResultsWorkbookViewModel } from "../../tools/reporting/rule-results-view-model.mjs";
import { createRuleReportOutputManager } from "../../tools/reporting/rule-report-output-manager.mjs";

const root = path.resolve(import.meta.dirname, "..", "..");
const fixtureDir = path.join(root, "tests", "fixtures", "reporting", "rule-results");
const artifactsRoot = path.resolve(root, "artifacts");
let assertions = 0;
const check = (actual, expected, message) => { assert.deepEqual(actual, expected, message); assertions += 1; };

async function createReportDir() {
  const reportDir = path.join(artifactsRoot, `reporting-contract-${crypto.randomUUID()}`);
  await fs.mkdir(reportDir, { recursive: true });
  for (const name of ["summary.json", "case-results.json", "test-results.json"]) {
    await fs.copyFile(path.join(fixtureDir, name), path.join(reportDir, name));
  }
  return reportDir;
}

const tempDirs = [];
try {
  const validDir = await createReportDir();
  tempDirs.push(validDir);
  const loaded = await loadRuleResults(validDir);
  check(loaded.canonicalSource, "test-results.json", "canonical source");
  check(loaded.results.map((item) => item.status), ["PASS", "FAIL", "ERROR", "PENDING"], "loaded statuses");
  check(Object.isFrozen(loaded.canonicalDocument), true, "canonical document is immutable");
  check(createRuleResultsWorkbookViewModel(loaded).resultRows.map((row) => row[10]), ["통과", "실패", "오류", "대기"], "view labels");

  const legacyDir = await createReportDir();
  tempDirs.push(legacyDir);
  await fs.rm(path.join(legacyDir, "test-results.json"));
  const legacy = await loadRuleResults(legacyDir);
  check(legacy.canonicalSource, "case-results.json#testResult", "legacy JSON fallback source");
  check(legacy.results.map((item) => item.status), ["PASS", "FAIL", "ERROR", "PENDING"], "legacy statuses are preserved");

  const failClosedDir = await createReportDir();
  tempDirs.push(failClosedDir);
  const failClosedDocument = JSON.parse(await fs.readFile(path.join(failClosedDir, "test-results.json"), "utf8"));
  failClosedDocument.results[1].code = "EXPECTED_OUTCOME_NOT_OBSERVED";
  failClosedDocument.results[1].reason = "required validation was not observed";
  failClosedDocument.results[1].evidenceRole = "Checkpoint";
  failClosedDocument.results[1].checkpointRequired = true;
  failClosedDocument.results[1].actionSent = true;
  failClosedDocument.results[1].actionVerified = true;
  await fs.writeFile(path.join(failClosedDir, "test-results.json"), JSON.stringify(failClosedDocument));
  const failClosedCases = JSON.parse(await fs.readFile(path.join(failClosedDir, "case-results.json"), "utf8"));
  failClosedCases[1].testResult.code = "EXPECTED_OUTCOME_NOT_OBSERVED";
  failClosedCases[1].testResult.reason = "required validation was not observed";
  failClosedCases[1].errorCode = "EXPECTED_OUTCOME_NOT_OBSERVED";
  failClosedCases[1].outputSummary = "required validation was not observed";
  await fs.writeFile(path.join(failClosedDir, "case-results.json"), JSON.stringify(failClosedCases));
  const failClosed = await loadRuleResults(failClosedDir);
  check(failClosed.results[1].status, "FAIL", "reporter preserves evaluator fail verdict");
  check(failClosed.results[1].testResult.code, "EXPECTED_OUTCOME_NOT_OBSERVED", "display context preserves evaluator reason code");
  check(failClosed.canonicalDocument.results[1].code, "EXPECTED_OUTCOME_NOT_OBSERVED", "canonical evaluator reason code remains unchanged");
  check(failClosed.canonicalDocument.results[1].evidenceRole, "Checkpoint", "reporter preserves evaluator evidence role");
  check(failClosed.canonicalDocument.results[1].actionVerified, true, "reporter preserves action verification metadata");

  const stateReportDir = await createReportDir();
  tempDirs.push(stateReportDir);
  const stateDiscovery = {
    schemaVersion: "1.0", graphId: "fake-graph", observedAt: "2026-08-24T00:00:00+09:00", transitionActionCount: 1, transactionalActionCount: 0,
    states: [
      { stateContext: { stateId: "a", stateContextId: "state:a" }, status: "SUCCESS", failureCategory: "NONE", reasonCode: "", controls: [{ runtimeControlId: "same" }], screenshotRef: "screenshots/a.png", uiTreeRef: "ui-tree/a.json" },
      { stateContext: { stateId: "b", stateContextId: "state:b" }, status: "FAILED", failureCategory: "APPLICATION", reasonCode: "STATE_ARRIVAL_CHECKPOINT_NOT_SATISFIED", transition: { actionSent: true, actionVerified: true, arrivalCheckpointSatisfied: false }, controls: [], screenshotRef: "screenshots/b.png", uiTreeRef: "ui-tree/b.json" },
    ],
    restore: { status: "SUCCESS", actionSent: true, arrivalCheckpointSatisfied: true, failureCategory: "NONE", reasonCode: "" },
  };
  await fs.writeFile(path.join(stateReportDir, "state-discovery-results.json"), JSON.stringify(stateDiscovery));
  const stateLoaded = await loadRuleResults(stateReportDir);
  check(stateLoaded.stateDiscovery.states.map((state) => state.status), ["SUCCESS", "FAILED"], "reporter preserves canonical state statuses");
  check(Object.isFrozen(stateLoaded.stateDiscovery), true, "state discovery document is immutable");
  check(createRuleResultsWorkbookViewModel(stateLoaded).stateDiscoveryRows.map((row) => row[2]), ["SUCCESS", "FAILED", "SUCCESS"], "state and restore statuses are displayed without re-evaluation");
  check(createRuleResultsWorkbookViewModel(stateLoaded).stateDiscoveryRows[2][0], "@restore", "restore result remains a separate display row");

  const controlResolutions = {
    schemaVersion: "1.0", repositoryId: "fake-controls", resolutions: [{
      repositoryKey: "F001|MAP|CONTROL|STATE", status: "Resolved", trustTier: "StableIdentity", locatorSource: "StableIdentity",
      fallbackReason: "", reasonCode: "RESOLVED", reason: "canonical", approvalStatus: "Approved", approvalPayloadHash: "a".repeat(64),
      action: "Assert", actionSent: false, evidence: ["fixture:uia"],
    }],
  };
  await fs.writeFile(path.join(stateReportDir, "control-repository-resolutions.json"), JSON.stringify(controlResolutions));
  const repositoryLoaded = await loadRuleResults(stateReportDir);
  check(repositoryLoaded.controlRepositoryResolutions.resolutions[0].status, "Resolved", "reporter preserves canonical locator resolution");
  check(repositoryLoaded.controlRepositoryResolutions.resolutions[0].trustTier, "StableIdentity", "reporter preserves trust tier");
  check(createRuleResultsWorkbookViewModel(repositoryLoaded).controlRepositoryRows[0][5], "Approved", "reporter preserves approval status");
  check(Object.isFrozen(repositoryLoaded.controlRepositoryResolutions), true, "repository resolution document is immutable");
  const authoringDir = await createReportDir();
  tempDirs.push(authoringDir);
  const calibration = {
    schemaVersion: "1.0", sessionId: "fixture-session", targetProfileId: "fixture-target", repositoryId: "fixture-repository",
    screen: "F001", map: "FAKE-MAP", stateContext: "state:a", capturedAt: "2026-08-24T09:00:00+09:00",
    reviewer: "fixture-reviewer", status: "ReviewRequired", repositoryApplied: false, canonicalApprovalHash: "",
    observations: [{
      observationId: "one", capturedAt: "2026-08-24T09:00:00+09:00", screen: "F001", map: "FAKE-MAP", stateContext: "state:a",
      locatorTier: "ApprovedAnchoredRelative", expectedControlKind: "Edit", sensitiveDataRedacted: true, pixelCropStored: false,
      cursorMoved: false, clickSent: false, keyInputSent: false, automaticallyApproved: false,
    }],
  };
  const validation = {
    schemaVersion: "1.0", scenarioId: "fixture-scenario", status: "ConfigurationRequired", isValid: false,
    issues: [{ code: "ORDER_SCENARIO.REPOSITORY_KEY_NOT_FOUND", stepId: "action", message: "not found", remediation: "approve first", severity: "ERROR" }],
    resolvedControls: [],
  };
  const runPlan = {
    schemaVersion: "1.0", compilerVersion: "1.0.0", planId: "fixture-plan", planHash: "a".repeat(64),
    scenarioId: "fixture-scenario", caseId: "fixture-case", repositoryId: "fixture-repository", stateGraphId: "fixture-graph",
    executionMode: "DryRun", actualExecutionAllowed: false, restoreSequence: ["restore"],
    steps: [{
      stepId: "required-checkpoint", sequence: 1, repositoryKey: "F001|FAKE-MAP|CONTROL|STATE:A",
      resolvedLocatorTier: "StableIdentity", approvalHash: "b".repeat(64), role: "Checkpoint", operation: "AssertState",
      expectedMode: "Success", checkpointRequirement: "Required", affectsVerdict: true, requiredForPass: true,
    }],
  };
  const dryRun = {
    schemaVersion: "1.0", planId: "fixture-plan", status: "PENDING", planHashValid: true,
    requiredCheckpointChecked: true, restorePlanChecked: true, actualUiActionCount: 0, transactionalActionCount: 0,
    reason: "DryRun does not determine PASS.",
  };
  await Promise.all([
    fs.writeFile(path.join(authoringDir, "calibration-session.json"), JSON.stringify(calibration)),
    fs.writeFile(path.join(authoringDir, "order-scenario-validation.json"), JSON.stringify(validation)),
    fs.writeFile(path.join(authoringDir, "order-run-plan.json"), JSON.stringify(runPlan)),
    fs.writeFile(path.join(authoringDir, "order-scenario-dry-run.json"), JSON.stringify(dryRun)),
  ]);
  const authoringLoaded = await loadRuleResults(authoringDir);
  const authoringRows = createRuleResultsWorkbookViewModel(authoringLoaded).orderAuthoringRows;
  check(authoringLoaded.calibrationSession.status, "ReviewRequired", "reporter preserves calibration status");
  check(authoringLoaded.orderScenarioValidation.status, "ConfigurationRequired", "reporter preserves validation status");
  check(authoringLoaded.orderScenarioDryRun.status, "PENDING", "reporter preserves DryRun status without PASS conversion");
  check(authoringRows.find((row) => row[0] === "Validation" && row[3] === "Summary")?.[2], "ConfigurationRequired", "validation summary remains canonical");
  check(authoringRows.find((row) => row[0] === "DryRun")?.[2], "PENDING", "DryRun display remains PENDING");
  check(Object.isFrozen(authoringLoaded.orderRunPlan), true, "order run plan is immutable in reporter");

  const unsafeDryRunDir = await createReportDir();
  tempDirs.push(unsafeDryRunDir);
  await fs.writeFile(path.join(unsafeDryRunDir, "order-scenario-dry-run.json"), JSON.stringify({ ...dryRun, actualUiActionCount: 1 }));
  await assert.rejects(loadRuleResults(unsafeDryRunDir), /action count는 0/);
  assertions += 1;


  const unsafeStateDir = await createReportDir();
  tempDirs.push(unsafeStateDir);
  const unsafeStateDiscovery = structuredClone(stateDiscovery);
  unsafeStateDiscovery.states[1].status = "SUCCESS";
  await fs.writeFile(path.join(unsafeStateDir, "state-discovery-results.json"), JSON.stringify(unsafeStateDiscovery));
  await assert.rejects(loadRuleResults(unsafeStateDir), /action 전달만으로 SUCCESS/);
  assertions += 1;

  const mismatchDir = await createReportDir();
  tempDirs.push(mismatchDir);
  const mismatchCases = JSON.parse(await fs.readFile(path.join(mismatchDir, "case-results.json"), "utf8"));
  mismatchCases[1].status = "PASS";
  await fs.writeFile(path.join(mismatchDir, "case-results.json"), JSON.stringify(mismatchCases));
  await assert.rejects(loadRuleResults(mismatchDir), /status와 testResult.status|canonical status/);
  assertions += 1;

  const unsafePassDir = await createReportDir();
  tempDirs.push(unsafePassDir);
  const actionPassDir = await createReportDir();
  tempDirs.push(actionPassDir);
  const actionPassDocument = JSON.parse(await fs.readFile(path.join(actionPassDir, "test-results.json"), "utf8"));
  actionPassDocument.results[0].evidenceRole = "Action";
  actionPassDocument.results[0].checkpointRequired = false;
  actionPassDocument.results[0].actionSent = true;
  actionPassDocument.results[0].actionVerified = true;
  await fs.writeFile(path.join(actionPassDir, "test-results.json"), JSON.stringify(actionPassDocument));
  await assert.rejects(loadRuleResults(actionPassDir), /Action 전달 결과는 canonical PASS/);
  assertions += 1;
  const unsafeDocument = JSON.parse(await fs.readFile(path.join(unsafePassDir, "test-results.json"), "utf8"));
  unsafeDocument.results[0].executed = false;
  await fs.writeFile(path.join(unsafePassDir, "test-results.json"), JSON.stringify(unsafeDocument));
  await assert.rejects(loadRuleResults(unsafePassDir), /PASS에는 executed=true/);
  assertions += 1;

  const corruptOptionalDir = await createReportDir();
  tempDirs.push(corruptOptionalDir);
  await fs.writeFile(path.join(corruptOptionalDir, "map-screen-models.json"), "{broken");
  await assert.rejects(loadRuleResults(corruptOptionalDir), /map-screen-models.json을 읽거나 파싱/);
  assertions += 1;

  const outputManager = createRuleReportOutputManager(validDir, "..\\outside.xlsx");
  check(path.dirname(outputManager.outputPath), path.resolve(validDir), "output remains inside report directory");
  check(await outputManager.readEvidence("..\\outside.png"), null, "outside evidence is rejected");
  check(createRuleReportOutputManager(validDir, "report.xlsx", { renderPreviews: false }).renderPreviews, false, "preview rendering can be disabled without changing the default");
  console.log(`RULE_RESULTS_CONTRACT_TESTS=PASS assertions=${assertions}`);
} finally {
  for (const tempDir of tempDirs) {
    if (path.resolve(tempDir).startsWith(`${artifactsRoot}${path.sep}`)) await fs.rm(tempDir, { recursive: true, force: true });
  }
}
