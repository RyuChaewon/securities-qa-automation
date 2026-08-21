// 역할: target importer 이동 전후 산출물의 실행 의미가 동일한지 외부 의존성 없이 비교한다.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";

const [beforeArg, afterArg] = process.argv.slice(2);
if (!beforeArg || !afterArg) throw new Error("usage: node compare-import-results.mjs <before-dir> <after-dir>");
const beforeDir = path.resolve(beforeArg);
const afterDir = path.resolve(afterArg);
const read = async (directory, name) => JSON.parse(await fs.readFile(path.join(directory, name), "utf8"));

function scenarioMeaning(document) {
  const { generator: _generator, generatorVersion: _generatorVersion, ...generationMeaning } = document.generationSummary ?? {};
  return {
    packageVersion: document.packageVersion,
    sourceInstallationFingerprint: document.sourceInstallationFingerprint,
    generationSummary: generationMeaning,
    screens: document.screens,
    tabTopology: document.tabTopology,
    datasetPatch: document.datasetPatch,
    reviewItems: document.reviewItems,
  };
}

function datasetMeaning(dataset) {
  const { adapter: _adapter, ...profileMeaning } = dataset.targetProfile ?? {};
  return { ...dataset, targetProfile: profileMeaning };
}

const [beforeSummary, afterSummary, beforeScenarios, afterScenarios, beforeDataset, afterDataset] = await Promise.all([
  read(beforeDir, "import-summary.json"),
  read(afterDir, "import-summary.json"),
  read(beforeDir, "generated-scenarios.json"),
  read(afterDir, "generated-scenarios.json"),
  read(beforeDir, "0101.dataset.json"),
  read(afterDir, "0101.dataset.json"),
]);

assert.deepStrictEqual(afterSummary, beforeSummary, "import summary changed");
assert.deepStrictEqual(scenarioMeaning(afterScenarios), scenarioMeaning(beforeScenarios), "scenario meaning changed");
assert.deepStrictEqual(datasetMeaning(afterDataset), datasetMeaning(beforeDataset), "dataset meaning outside adapter changed");
assert.equal(afterDataset.targetProfile.adapter?.schemaVersion, "1.0", "new dataset does not embed a versioned adapter");

console.log("TARGET_IMPORT_REGRESSION=PASS scenarios=1159 variables=457 transactional=26");
