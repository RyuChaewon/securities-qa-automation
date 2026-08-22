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

  const mismatchDir = await createReportDir();
  tempDirs.push(mismatchDir);
  const mismatchCases = JSON.parse(await fs.readFile(path.join(mismatchDir, "case-results.json"), "utf8"));
  mismatchCases[1].status = "PASS";
  await fs.writeFile(path.join(mismatchDir, "case-results.json"), JSON.stringify(mismatchCases));
  await assert.rejects(loadRuleResults(mismatchDir), /status와 testResult.status|canonical status/);
  assertions += 1;

  const unsafePassDir = await createReportDir();
  tempDirs.push(unsafePassDir);
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
