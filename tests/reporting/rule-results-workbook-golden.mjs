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
  const canonicalBefore = await sha256(path.join(tempDir, "test-results.json"));
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
  console.log("RULE_RESULTS_WORKBOOK_GOLDEN=PASS sheets=18 statuses=PASS,FAIL,ERROR,PENDING");
} finally {
  const artifactsRoot = `${path.resolve(root, "artifacts")}${path.sep}`;
  const resolvedTemp = path.resolve(tempDir);
  if (resolvedTemp.startsWith(artifactsRoot)) await fs.rm(resolvedTemp, { recursive: true, force: true });
}
