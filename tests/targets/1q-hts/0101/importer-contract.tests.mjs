/**
 * 역할: 0101 importer의 오프라인 경계와 이동 전후 의미 비교기의 fail-closed 동작을 검증한다.
 * 경계: 원본 workbook, artifact-tool, HTS, FlaUI, 계좌 또는 외부 API를 사용하지 않는다.
 */
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { classifyExpectedOutcome, isStructuredErrorCode, RULE_EXPECTED_OUTCOME_TYPES } from "../../../../targets/1q-hts/0101/tools/expected-outcome-classifier.mjs";

const root = path.resolve(import.meta.dirname, "..", "..", "..", "..");
const importerPath = path.join(root, "targets", "1q-hts", "0101", "tools", "import-testcases.mjs");
const targetProfilePath = path.join(root, "targets", "1q-hts", "0101", "target-profile.json");
const comparatorPath = path.join(import.meta.dirname, "compare-import-results.mjs");
const artifactsRoot = path.join(root, "artifacts");
const tempRoot = path.join(artifactsRoot, `importer-contract-${crypto.randomUUID()}`);
const beforeDir = path.join(tempRoot, "before");
const afterDir = path.join(tempRoot, "after");
let assertions = 0;

const check = (condition, message) => {
  assert.ok(condition, message);
  assertions += 1;
};

async function writeJson(directory, name, value) {
  await fs.writeFile(path.join(directory, name), `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function runComparator() {
  return spawnSync(process.execPath, [comparatorPath, beforeDir, afterDir], {
    cwd: root,
    encoding: "utf8",
  });
}

try {
  const importer = await fs.readFile(importerPath, "utf8");
  const targetProfile = JSON.parse(await fs.readFile(targetProfilePath, "utf8"));
  assert.match(importer, /sourceWorkbook:\s*path\.basename\(workbookPath\)/, "import summary must not expose a local workbook path");
  assert.match(importer, /candidateSheetNames/, "importer must use target-adapter approved sheet names");
  assert.doesNotMatch(importer, /\bfetch\s*\(|https?:\/\//, "importer execution must not call an external API");
  assert.match(importer, /ExpectationClassification:/, "fallback classification reason must be serialized as evidence");
  assert.match(importer, /generatorVersion:\s*"1\.6\.0"/, "semantic classifier change must bump importer generator version");
  assert.deepEqual(targetProfile.adapter.import.expectedOutcomeModeHeaders,
    ["ExpectedMode", "expectedMode", "기대결과유형", "기대결과모드"], "structured expected mode headers are target-owned");
  assertions += 6;

  const classified = (input) => classifyExpectedOutcome(input).type;
  check(classified({ rawInput: "<계좌 미선택>", procedure: "필수 계좌 없이 진행", expectedResult: "계좌 필요 동작이 차단되고 오류 경로가 실행" }) === "ValidationRequired",
    "prefixed missing-selection placeholders must require validation");
  check(classified({ rawInput: "선택값 변경", procedure: "이벤트 호출", expectedResult: "핸들러가 실행되고 결과가 반영" }) === "Unspecified",
    "generic handler execution must not become business Success");
  check(classified({ rawInput: "<허용길이-1/허용길이/허용길이+1>", expectedResult: "초과 값은 차단" }) === "Unspecified",
    "composite boundary placeholders must be expanded before classification");
  check(classified({ rawInput: "005930\n<공백>", expectedResult: "공백은 오류 메시지" }) === "Unspecified",
    "mixed valid and blank placeholders must remain unresolved");
  check(classified({ structuredMode: "Success", rawInput: "정상값", expectedResult: "오류 팝업 문구 확인" }) === "Success",
    "structured expected mode must override text fallback");
  check(classified({ structuredMode: "REVIEW", expectedResult: "정상 처리" }) === "Unspecified",
    "structured REVIEW must remain unresolved");
  check(classified({ rawInput: "99999999", procedure: "유효하지 않은 종목코드 입력", expectedResult: "종목코드오류 메시지 표시" }) === "ValidationRequired",
    "known invalid stock code intent must require validation");
  check(classified({ rawInput: "<공백>", procedure: "필수 입력값 없이 진행", expectedResult: "입력이 차단되고 메시지 표시" }) === "ValidationRequired",
    "missing required input must require validation");
  check(classified({ rawInput: "ABC", procedure: "형식 위반 값 입력", expectedResult: "검증 오류 표시" }) === "ValidationRequired",
    "format error must require validation");
  check(classified({ rawInput: "<Max+1>", procedure: "허용 범위 초과", expectedResult: "진행되지 않고 오류 표시" }) === "ValidationRequired",
    "out-of-range input must require validation");
  check(classified({ rawInput: "005930", expectedResult: "정상 조회가 완료되고 결과 반영" }) === "Success",
    "normal business outcome must classify as success");
  check(classified({ rawInput: "경계값", procedure: "최대 경계 조건", expectedResult: "정책에 따라 성공 또는 검증" }) === "ValidationAllowed",
    "only a genuinely alternative boundary may allow validation");
  check(classified({ rawInput: "값", procedure: "OnError 이벤트 확인", expectedResult: "오류 팝업 메시지 또는 거부 경로" }) === "Unspecified",
    "error words alone must not create ValidationAllowed");
  check(classified({ rawInput: "값", expectedResult: "초기 상태와 표시 상태가 MAP과 일치하는지 확인" }) === "ObservationOnly",
    "pure observation must remain ObservationOnly");
  check(classified({ rawInput: "값", expectedResult: "동작 확인" }) === "Unspecified",
    "insufficient expectation evidence must remain unresolved");
  check(classified({ rawInput: "유효하지 않은 값", expectedResult: "검증 메시지", errorCodes: ["E100"] }) === "ValidationRequired",
    "structured error code plus invalid intent must require validation");
  check(classified({ rawInput: "오류 조건", expectedResult: "OnError 실행", errorCodes: ["MAP", "OnError"] }) === "Unspecified",
    "descriptive error-code tokens must remain unresolved");
  check(isStructuredErrorCode("ORDER_TAB_NOT_SELECTED") && isStructuredErrorCode("E100") && !isStructuredErrorCode("OnError"),
    "only structured code-shaped tokens may become error-code matchers");
  check(RULE_EXPECTED_OUTCOME_TYPES.includes(classifyExpectedOutcome({ structuredMode: "unsupported" }).type),
    "classifier must emit only an existing Core enum name");

  await fs.mkdir(beforeDir, { recursive: true });
  await fs.mkdir(afterDir, { recursive: true });

  const beforeSummary = { sourceWorkbook: "old-path.xlsx", importedTestCases: 1 };
  const afterSummary = { sourceWorkbook: "approved-input.xlsx", importedTestCases: 1 };
  const beforeScenarios = {
    packageVersion: "1.0",
    sourceInstallationFingerprint: "fixture",
    generationSummary: { referenceDate: "20260823", generator: "old", generatorVersion: "1.0", generationMode: "fixture" },
    screens: [],
    tabTopology: {},
    datasetPatch: {},
    reviewItems: [],
  };
  const afterScenarios = {
    ...beforeScenarios,
    generationSummary: { ...beforeScenarios.generationSummary, referenceDate: "20260824", generator: "current", generatorVersion: "1.1" },
  };
  const beforeDataset = { schemaVersion: "2.0", targetProfile: { displayName: "fixture", adapter: { schemaVersion: "0.9" } } };
  const afterDataset = { schemaVersion: "2.0", targetProfile: { displayName: "fixture", adapter: { schemaVersion: "1.0" } } };

  await Promise.all([
    writeJson(beforeDir, "import-summary.json", beforeSummary),
    writeJson(afterDir, "import-summary.json", afterSummary),
    writeJson(beforeDir, "generated-scenarios.json", beforeScenarios),
    writeJson(afterDir, "generated-scenarios.json", afterScenarios),
    writeJson(beforeDir, "0101.dataset.json", beforeDataset),
    writeJson(afterDir, "0101.dataset.json", afterDataset),
  ]);

  const compatible = runComparator();
  assert.equal(compatible.status, 0, compatible.stderr || compatible.stdout);
  assert.match(compatible.stdout, /TARGET_IMPORT_REGRESSION=PASS/);
  assertions += 2;

  await writeJson(afterDir, "0101.dataset.json", {
    ...afterDataset,
    targetProfile: { ...afterDataset.targetProfile, displayName: "changed-meaning" },
  });
  const incompatible = runComparator();
  check(incompatible.status !== 0, "comparator must reject an importer output meaning change");

  console.log(`IMPORTER_CONTRACT_TESTS=PASS assertions=${assertions}`);
} finally {
  const resolvedArtifacts = `${path.resolve(artifactsRoot)}${path.sep}`;
  const resolvedTemp = path.resolve(tempRoot);
  if (resolvedTemp.startsWith(resolvedArtifacts)) await fs.rm(resolvedTemp, { recursive: true, force: true });
}
