/**
 * 역할: report JSON을 읽고 canonical TestResultDocument와 표시 컨텍스트의 계약 일치를 검증한다.
 * 경계: 입력 객체의 상태를 보정하지 않고 불일치, 손상, 안전하지 않은 PASS를 계약 오류로 거부한다.
 */
import fs from "node:fs/promises";
import path from "node:path";

const TEST_STATUSES = new Set(["PASS", "FAIL", "ERROR", "PENDING"]);
const xmlSafeText = (value) => String(value ?? "").replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/g, "");

async function readJson(reportDir, fileName, optional = false) {
  try {
    const text = (await fs.readFile(path.join(reportDir, fileName), "utf8")).replace(/^\uFEFF/, "");
    return JSON.parse(text, (_key, value) => typeof value === "string" ? xmlSafeText(value) : value);
  } catch (error) {
    if (optional && error?.code === "ENOENT") return null;
    throw new Error(`${fileName}을 읽거나 파싱할 수 없습니다: ${error.message}`, { cause: error });
  }
}

function validateTestResult(result, source) {
  if (!result || typeof result !== "object") throw new Error(`${source}: TestResult 객체가 필요합니다.`);
  if (!String(result.caseId ?? "").trim()) throw new Error(`${source}: caseId가 필요합니다.`);
  if (!TEST_STATUSES.has(result.status)) throw new Error(`${source}: 지원하지 않는 TestStatus '${result.status}'입니다.`);
  if (result.status === "PASS" && (result.executed !== true || result.evidencePresent !== true)) {
    throw new Error(`${source}: PASS에는 executed=true와 evidencePresent=true가 필요합니다.`);
  }
}

function validateCanonicalDocument(document) {
  if (!document || typeof document !== "object") throw new Error("test-results.json: TestResultDocument 객체가 필요합니다.");
  if (document.schemaVersion !== "1.0") throw new Error(`test-results.json: 지원하지 않는 schemaVersion '${document.schemaVersion ?? ""}'입니다.`);
  if (!Array.isArray(document.results)) throw new Error("test-results.json: results 배열이 필요합니다.");
  const byCaseId = new Map();
  for (const result of document.results) {
    validateTestResult(result, `test-results.json/results/${result?.caseId ?? "?"}`);
    if (byCaseId.has(result.caseId)) throw new Error(`test-results.json: 중복 caseId '${result.caseId}'입니다.`);
    byCaseId.set(result.caseId, result);
  }
  validateTestResult(document.overallResult, "test-results.json/overallResult");
  const counts = { PASS: 0, FAIL: 0, ERROR: 0, PENDING: 0 };
  for (const result of document.results) counts[result.status] += 1;
  const expected = document.summary ?? {};
  for (const [status, field] of [["PASS", "pass"], ["FAIL", "fail"], ["ERROR", "error"], ["PENDING", "pending"]]) {
    if (Number(expected[field] ?? -1) !== counts[status]) throw new Error(`test-results.json: summary.${field}가 results와 일치하지 않습니다.`);
  }
  if (Number(expected.total ?? -1) !== document.results.length) throw new Error("test-results.json: summary.total이 results와 일치하지 않습니다.");
  return byCaseId;
}

function validateDisplayContext(summary, results, canonicalDocument, canonicalByCaseId) {
  if (!summary || typeof summary !== "object") throw new Error("summary.json: 객체가 필요합니다.");
  if (!TEST_STATUSES.has(summary.status)) throw new Error(`summary.json: 지원하지 않는 status '${summary.status ?? ""}'입니다.`);
  if (!Array.isArray(results)) throw new Error("case-results.json: 배열 또는 단일 객체가 필요합니다.");
  const seen = new Set();
  for (const result of results) {
    const caseId = String(result?.caseId ?? "").trim();
    if (!caseId) throw new Error("case-results.json: caseId가 필요합니다.");
    if (seen.has(caseId)) throw new Error(`case-results.json: 중복 caseId '${caseId}'입니다.`);
    seen.add(caseId);
    if (!TEST_STATUSES.has(result.status)) throw new Error(`case-results.json/${caseId}: 지원하지 않는 status '${result.status ?? ""}'입니다.`);
    if (result.testResult) {
      validateTestResult(result.testResult, `case-results.json/${caseId}/testResult`);
      if (result.testResult.status !== result.status) throw new Error(`case-results.json/${caseId}: status와 testResult.status가 일치하지 않습니다.`);
    }
    if (canonicalDocument) {
      const canonical = canonicalByCaseId.get(caseId);
      if (!canonical) throw new Error(`case-results.json/${caseId}: canonical TestResult가 없습니다.`);
      if (canonical.status !== result.status) throw new Error(`case-results.json/${caseId}: canonical status '${canonical.status}'를 reporter status '${result.status}'로 변경할 수 없습니다.`);
    }
  }
  if (canonicalDocument && canonicalDocument.overallResult.status !== summary.status) {
    throw new Error(`summary.json: canonical overall status '${canonicalDocument.overallResult.status}'를 '${summary.status}'로 변경할 수 없습니다.`);
  }
}

function deepFreeze(value) {
  if (!value || typeof value !== "object" || Object.isFrozen(value)) return value;
  Object.freeze(value);
  for (const child of Object.values(value)) deepFreeze(child);
  return value;
}

export async function loadRuleResults(reportDir) {
  const summary = await readJson(reportDir, "summary.json");
  const parsedResults = await readJson(reportDir, "case-results.json");
  const results = Array.isArray(parsedResults) ? parsedResults : [parsedResults];
  const canonicalDocument = await readJson(reportDir, "test-results.json", true);
  const canonicalByCaseId = canonicalDocument ? validateCanonicalDocument(canonicalDocument) : new Map();
  validateDisplayContext(summary, results, canonicalDocument, canonicalByCaseId);
  const optional = async (name, fallback) => (await readJson(reportDir, name, true)) ?? fallback;
  return deepFreeze({
    reportDir,
    summary,
    results,
    canonicalDocument,
    canonicalSource: canonicalDocument ? "test-results.json" : "case-results.json#testResult",
    mapCatalog: await optional("map-screen-models.json", { screens: [] }),
    compiledPlan: await optional("compiled-plan.json", null),
    bindingCatalog: await optional("binding-catalog.json", null),
    physicalPlan: await optional("physical-plan.json", null),
    scenarioReviewItems: await optional("scenario-review-items.json", []),
  });
}
