import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const argv = process.argv.slice(2);
const option = (name) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 ? argv[index + 1] : "";
};
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const packageDir = path.resolve(option("package") || scriptDir);
const positional = argv.find((item, index) => !item.startsWith("--") && (index === 0 || !argv[index - 1].startsWith("--")));
const outputPath = path.resolve(option("file") || positional || path.join(packageDir, "generated-scenarios.json"));
const readJson = async (filePath) => JSON.parse((await fs.readFile(filePath, "utf8")).replace(/^\uFEFF/, ""));

const context = await readJson(path.join(packageDir, "02_화면_시나리오_컨텍스트.json"));
const contract = await readJson(path.join(packageDir, "04_데이터셋_작성_계약.json"));
const output = await readJson(outputPath);
const errors = [];
const warnings = [];
const required = (condition, message) => { if (!condition) errors.push(message); };
const array = (value) => Array.isArray(value) ? value : [];

required(output.packageVersion === "1.0", "packageVersion은 1.0이어야 합니다.");
required(output.sourceInstallationFingerprint === context.sourceInstallationFingerprint, "설치 지문이 입력 컨텍스트와 다릅니다.");
required(/^\d{8}$/.test(String(output.generationSummary?.referenceDate ?? "")), "generationSummary.referenceDate는 yyyyMMdd여야 합니다.");

const targetScreens = context.scope.registeredTargetScreens.map(String);
const outputScreens = array(output.screens).map((screen) => String(screen.screenNumber));
required(outputScreens.length === targetScreens.length, `screens는 ${targetScreens.length}개여야 합니다.`);
required(new Set(outputScreens).size === outputScreens.length, "screens에 중복 화면번호가 있습니다.");
for (const screenNumber of targetScreens) required(outputScreens.includes(screenNumber), `필수 화면 ${screenNumber}가 누락되었습니다.`);
for (const screenNumber of outputScreens) required(targetScreens.includes(screenNumber), `대상 외 화면 ${screenNumber}가 포함되었습니다.`);

const knownScreens = new Map(context.screens.map((screen) => [String(screen.screenNumber), screen]));
const scenarioIds = new Set();
let scenarioCount = 0;
let coveredControlCount = 0;
let coveredValidationCount = 0;
for (const plan of array(output.screens)) {
  const screenNumber = String(plan.screenNumber ?? "");
  const source = knownScreens.get(screenNumber);
  if (!source) continue;
  const knownControls = new Set(source.actionableControls.map((control) => String(control.logicalName)));
  const knownRules = new Set(source.validationRules.map((rule) => String(rule.ruleId)));
  const coveredControls = new Set();
  const coveredRules = new Set();
  required(array(plan.scenarios).length > 0, `${screenNumber}: 시나리오가 없습니다.`);
  for (const scenario of array(plan.scenarios)) {
    scenarioCount += 1;
    const id = String(scenario.scenarioId ?? "");
    required(/^TS-07\d{2}-[A-Z0-9_-]+$/.test(id), `${screenNumber}: 잘못된 scenarioId '${id}'`);
    required(!scenarioIds.has(id), `중복 scenarioId '${id}'`);
    scenarioIds.add(id);
    required(scenario.executionOrder === "RuntimeTabOrder", `${id}: executionOrder는 RuntimeTabOrder여야 합니다.`);
    const sequences = array(scenario.steps).map((step) => Number(step.sequence));
    required(sequences.length > 0, `${id}: 실행 단계가 없습니다.`);
    required(new Set(sequences).size === sequences.length && sequences.every((value) => Number.isInteger(value) && value > 0), `${id}: 단계 순번이 중복되거나 잘못되었습니다.`);
    for (const step of array(scenario.steps)) {
      const logicalName = step.controlLogicalName;
      if (logicalName !== null && logicalName !== undefined && logicalName !== "") {
        required(knownControls.has(String(logicalName)), `${id}: 알 수 없는 단계 컨트롤 '${logicalName}'`);
      }
    }
    for (const logicalName of array(scenario.coveredControls).map(String)) {
      required(knownControls.has(logicalName), `${id}: 알 수 없는 커버리지 컨트롤 '${logicalName}'`);
      if (knownControls.has(logicalName)) coveredControls.add(logicalName);
    }
    for (const ruleId of array(scenario.coveredValidationRuleIds).map(String)) {
      required(knownRules.has(ruleId), `${id}: 알 수 없는 검증 규칙 '${ruleId}'`);
      if (knownRules.has(ruleId)) coveredRules.add(ruleId);
    }
  }
  const missingControls = [...knownControls].filter((name) => !coveredControls.has(name));
  const missingRules = [...knownRules].filter((name) => !coveredRules.has(name));
  const gaps = array(plan.coverageGaps);
  if (missingControls.length && !gaps.length) errors.push(`${screenNumber}: 미커버 컨트롤 ${missingControls.length}개인데 coverageGaps가 없습니다.`);
  if (missingRules.length && !gaps.length) errors.push(`${screenNumber}: 미커버 검증 규칙 ${missingRules.length}개인데 coverageGaps가 없습니다.`);
  if (missingControls.length) warnings.push(`${screenNumber}: 미커버 컨트롤 ${missingControls.join(", ")}`);
  if (missingRules.length) warnings.push(`${screenNumber}: 미커버 검증 규칙 ${missingRules.join(", ")}`);
  coveredControlCount += coveredControls.size;
  coveredValidationCount += coveredRules.size;
}

const allowedKinds = new Set(contract.supportedControlKinds);
const allowedMatches = new Set(contract.supportedValueMatches);
const allowedOutcomes = new Set(contract.expectedOutcomeTypes);
for (const variable of array(output.datasetPatch?.variables)) {
  const name = String(variable.name ?? "(이름 없음)");
  required(allowedKinds.has(variable.controlKind), `${name}: 지원하지 않는 controlKind '${variable.controlKind}'`);
  required(allowedMatches.has(variable.valueMatch), `${name}: 지원하지 않는 valueMatch '${variable.valueMatch}'`);
  required(array(variable.appliesToScreens).length > 0, `${name}: appliesToScreens가 비어 있습니다.`);
  for (const screenNumber of array(variable.appliesToScreens).map(String)) {
    required(knownScreens.has(screenNumber), `${name}: 대상 외 화면 ${screenNumber}`);
    if (knownScreens.has(screenNumber)) {
      const controls = new Set(knownScreens.get(screenNumber).actionableControls.map((control) => String(control.logicalName)));
      required(controls.has(String(variable.targetLogicalName)), `${name}: ${screenNumber}에 '${variable.targetLogicalName}' 컨트롤이 없습니다.`);
    }
  }
  required(array(variable.values).length > 0, `${name}: 테스트 값이 없습니다.`);
  for (const value of array(variable.values)) {
    const outcome = value.expectedOutcome ?? {};
    required(allowedOutcomes.has(outcome.type), `${name}/${value.id}: 지원하지 않는 기대 결과 '${outcome.type}'`);
    if (["ValidationRequired", "FailureRequired"].includes(outcome.type)) {
      required(array(outcome.messagePatterns).length > 0 || array(outcome.errorCodes).length > 0, `${name}/${value.id}: ${outcome.type}에는 messagePatterns 또는 errorCodes가 필요합니다.`);
    }
    required(array(value.sourceRefs).length > 0, `${name}/${value.id}: sourceRefs가 없습니다.`);
  }
}

const forbiddenKeys = new Set(["accounts", "accountnumber", "owner", "password", "passwordsecret"]);
const walk = (value, location = "$") => {
  if (Array.isArray(value)) return value.forEach((item, index) => walk(item, `${location}[${index}]`));
  if (!value || typeof value !== "object") return;
  for (const [key, child] of Object.entries(value)) {
    if (forbiddenKeys.has(key.toLowerCase())) errors.push(`${location}.${key}: 민감정보 키는 생성 결과에 포함할 수 없습니다.`);
    walk(child, `${location}.${key}`);
  }
};
walk(output);

const summary = {
  status: errors.length ? "FAIL" : "PASS",
  outputFile: outputPath,
  screens: outputScreens.length,
  scenarios: scenarioCount,
  variables: array(output.datasetPatch?.variables).length,
  locatorRequests: array(output.datasetPatch?.locatorRequests).length,
  coveredControls: coveredControlCount,
  totalControls: context.screens.reduce((sum, screen) => sum + screen.actionableControls.length, 0),
  coveredValidationRules: coveredValidationCount,
  totalValidationRules: context.screens.reduce((sum, screen) => sum + screen.validationRules.length, 0),
  errors,
  warnings,
};
console.log(JSON.stringify(summary, null, 2));
if (errors.length) process.exit(1);
