/**
 * 역할: 0101 importer의 오프라인 경계와 이동 전후 의미 비교기의 fail-closed 동작을 검증한다.
 * 경계: 원본 workbook, artifact-tool, HTS, FlaUI, 계좌 또는 외부 API를 사용하지 않는다.
 */
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { spawnSync } from "node:child_process";

const root = path.resolve(import.meta.dirname, "..", "..", "..", "..");
const importerPath = path.join(root, "targets", "1q-hts", "0101", "tools", "import-testcases.mjs");
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
  assert.match(importer, /sourceWorkbook:\s*path\.basename\(workbookPath\)/, "import summary must not expose a local workbook path");
  assert.match(importer, /candidateSheetNames/, "importer must use target-adapter approved sheet names");
  assert.doesNotMatch(importer, /\bfetch\s*\(|https?:\/\//, "importer execution must not call an external API");
  assertions += 3;

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
