/**
 * 역할: 동일한 TestResult fixture가 workbook의 핵심 시트, 열과 상태를 바꾸지 않는지 검증한다.
 * 경계: Fake JSON만 사용하며 HTS, FlaUI, 외부 API를 실행하지 않는다.
 */
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { FileBlob, SpreadsheetFile } from "../../tools/node_modules/@oai/artifact-tool/dist/artifact_tool.mjs";

const root = path.resolve(import.meta.dirname, "..", "..");
const fixtureDir = path.join(root, "tests", "fixtures", "reporting", "rule-results");
const tempDir = path.join(root, "artifacts", `reporting-golden-${crypto.randomUUID()}`);
const outputName = "golden.xlsx";

const sha256 = async (filePath) => crypto.createHash("sha256").update(await fs.readFile(filePath)).digest("hex");

try {
  await fs.mkdir(tempDir, { recursive: true });
  for (const name of ["summary.json", "case-results.json", "test-results.json"]) {
    await fs.copyFile(path.join(fixtureDir, name), path.join(tempDir, name));
  }
  const stateDiscovery = {
    schemaVersion: "1.0", graphId: "fake-graph", observedAt: "2026-08-24T00:00:00+09:00", transitionActionCount: 0, transactionalActionCount: 0,
    states: [{ stateContext: { stateId: "a", stateContextId: "state:a" }, status: "PENDING", failureCategory: "POLICY", reasonCode: "STATE_CONFIGURATION_REQUIRED", controls: [], screenshotRef: "", uiTreeRef: "" }],
    restore: { status: "PENDING", actionSent: false, arrivalCheckpointSatisfied: false, failureCategory: "POLICY", reasonCode: "STATE_RESTORE_CONFIGURATION_REQUIRED", screenshotRef: "", uiTreeRef: "" },
  };
  await fs.writeFile(path.join(tempDir, "state-discovery-results.json"), JSON.stringify(stateDiscovery));
  const canonicalBefore = await sha256(path.join(tempDir, "test-results.json"));
  const controlResolutions = {
    schemaVersion: "1.0", repositoryId: "fake-controls", resolutions: [{
      repositoryKey: "F001|MAP|CONTROL|STATE", status: "Blocked", trustTier: "Unresolved", locatorSource: "",
      fallbackReason: "", reasonCode: "ENTRY_NOT_APPROVED", reason: "review required", approvalStatus: "PendingApproval",
      approvalPayloadHash: "", action: "Input", actionSent: false, evidence: ["fixture:capture"],
    }],
  };
  await fs.writeFile(path.join(tempDir, "control-repository-resolutions.json"), JSON.stringify(controlResolutions));
  const execution = spawnSync(process.execPath, [path.join(root, "tools", "build-rule-results-workbook.mjs"), tempDir, outputName], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  assert.equal(execution.status, 0, execution.stderr || execution.stdout);
  assert.equal(await sha256(path.join(tempDir, "test-results.json")), canonicalBefore, "Reporter must not mutate canonical TestResult JSON");

  const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(path.join(tempDir, outputName)));
  const expected = JSON.parse(await fs.readFile(path.join(fixtureDir, "expected-core.json"), "utf8"));
  const sheetNames = expected.sheetNames.filter((name) => workbook.worksheets.getItem(name));
  assert.deepEqual(sheetNames, expected.sheetNames, "Core worksheet contract changed");
  assert.deepEqual(workbook.worksheets.getItem("요약").getRange("A4:B9").values, expected.summaryRows, "Summary view changed");
  assert.deepEqual(workbook.worksheets.getItem("테스트결과").getRange("A1:K1").values[0], expected.resultHeaders, "Result columns changed");
  assert.deepEqual(workbook.worksheets.getItem("테스트결과").getRange("K2:K5").values.flat(), expected.resultStatuses, "TestResult statuses changed");
  assert.deepEqual(workbook.worksheets.getItem("상태탐색").getRange("A5:A6").values.flat(), ["a", "@restore"], "State and restore rows must remain separate");
  assert.deepEqual(workbook.worksheets.getItem("상태탐색").getRange("C5:C6").values.flat(), ["PENDING", "PENDING"], "Reporter must preserve canonical state statuses");
  assert.deepEqual(workbook.worksheets.getItem("컨트롤저장소").getRange("B5:C5").values[0], ["Blocked", "Unresolved"], "Reporter must preserve canonical resolution and trust tier");
  assert.equal(workbook.worksheets.getItem("컨트롤저장소").getRange("F5").values[0][0], "PendingApproval", "Reporter must preserve approval status");
  assert.equal(workbook.worksheets.getItem("주문작성").getRange("A1").values[0][0], "캘리브레이션·정적 검증·불변 RunPlan·DryRun canonical 표시", "Order authoring sheet must remain display-only");
  console.log(`RULE_RESULTS_WORKBOOK_GOLDEN=PASS sheets=${expected.sheetNames.length} statuses=PASS,FAIL,ERROR,PENDING state=PENDING restore=PENDING repository=Blocked`);
} finally {
  const artifactsRoot = `${path.resolve(root, "artifacts")}${path.sep}`;
  const resolvedTemp = path.resolve(tempDir);
  if (resolvedTemp.startsWith(artifactsRoot)) await fs.rm(resolvedTemp, { recursive: true, force: true });
}
