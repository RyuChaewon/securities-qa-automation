/**
 * 역할: MAP, 데이터셋, 정책과 런타임 관찰을 외부 시나리오 생성용 최소 패키지로 변환한다.
 * 목적: 민감정보와 불필요한 좌표를 제외하면서 화면별 근거와 출력 계약을 재현 가능하게 전달한다.
 * 참고: 현재 자동 룰 기반 경로와 별개인 호환 도구이며 수동 외부 생성 경로에서만 사용한다.
 */
import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";

// 이름 있는 CLI 인자를 단순 객체로 변환한다.
const parseArgs = (argv) => {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith("--")) continue;
    result[key.slice(2)] = argv[index + 1];
    index += 1;
  }
  return result;
};

const args = parseArgs(process.argv.slice(2));
for (const required of ["map", "dataset", "policy", "output"]) {
  if (!args[required]) throw new Error(`필수 인자가 없습니다: --${required}`);
}

const mapPath = path.resolve(args.map);
const datasetPath = path.resolve(args.dataset);
const policyPath = path.resolve(args.policy);
const runtimePath = args.runtime ? path.resolve(args.runtime) : "";
const outputDir = path.resolve(args.output);
const generatedAt = new Date().toISOString();
const referenceDate = generatedAt.slice(0, 10).replaceAll("-", "");

const readJson = async (filePath) => JSON.parse((await fs.readFile(filePath, "utf8")).replace(/^\uFEFF/, ""));
const catalog = await readJson(mapPath);
const dataset = await readJson(datasetPath);
const policy = await fs.readFile(policyPath, "utf8");
const validator = await fs.readFile(new URL("./validate-chatgpt-scenario-output.mjs", import.meta.url), "utf8");
const runtimeRows = runtimePath ? await readJson(runtimePath) : [];

// 원본 경로·계좌·암호를 제외하고 모델이 판단에 필요한 화면 의미만 압축한다.
const targetScreens = new Set((dataset.screens ?? []).filter((screen) => screen.enabled !== false).map((screen) => String(screen.screenNumber)));
const targetProfile = dataset.targetProfile ?? {};
const targetDisplayName = String(targetProfile.displayName ?? dataset.datasetId ?? "대상 화면");
const targetScreenIds = [...targetScreens];
const targetScopeLabel = targetScreenIds.join(", ");
const hasConfiguredAccounts = (dataset.accounts ?? []).some((account) => account.enabled !== false);
const interactionStrategy = String(dataset.autoExploration?.interactionStrategy ?? "RuntimeTabOrder");
const orderingPolicy = interactionStrategy === "CoordinateFocus"
  ? "실행은 검증된 MAP+Runtime 물리 좌표 클릭으로 대상 요소에 포커스한 뒤 조작한다. definitionOrder와 런타임 탭오더는 실행 순서로 사용하지 않는다."
  : "실행은 런타임 탭오더 우선. definitionOrder는 시나리오 초안의 보조 순서일 뿐 실제 탭 순서로 단정하지 않는다.";
const unique = (values) => [...new Set((values ?? []).filter((value) => value !== null && value !== undefined && String(value).trim() !== ""))];
const sortedUnique = (values) => unique(values).sort((left, right) => String(left).localeCompare(String(right), "ko"));
const redactSourcePath = (value) => {
  if (!value) return "";
  let text = String(value).replaceAll("\\", "/");
  const installationRoot = String(catalog.installationRoot ?? "").replaceAll("\\", "/").replace(/\/$/, "");
  if (installationRoot && text.toLowerCase().startsWith(installationRoot.toLowerCase())) {
    text = `<HTS_ROOT>${text.slice(installationRoot.length)}`;
  }
  return text;
};

const normalizeExpectedOutcome = (outcome = {}) => ({
  type: outcome.type ?? "Unspecified",
  messagePatterns: outcome.messagePatterns ?? [],
  errorCodes: outcome.errorCodes ?? [],
  queryShouldComplete: outcome.queryShouldComplete ?? null,
  source: outcome.source ?? "Unspecified",
  confidence: outcome.confidence ?? "Unspecified",
  evidence: (outcome.evidence ?? []).map(redactSourcePath),
});

const normalizeOption = (option = {}) => ({
  id: String(option.id ?? ""),
  value: String(option.value ?? ""),
  displayValue: String(option.displayValue ?? option.value ?? ""),
  index: Number(option.index ?? 0),
  expectedOutcome: normalizeExpectedOutcome(option.expectedOutcome),
});

const roleHint = (control) => {
  const kind = String(control.kind ?? "");
  const role = String(control.semanticRole ?? "");
  if (kind === "Account") return "계좌 선택 또는 계좌번호 입력";
  if (kind === "Password") return "계좌 비밀번호 입력, 값 생성·기록 금지";
  if (kind === "Date") return "날짜 입력, yyyyMMdd 데이터 후보 필요";
  if (kind === "Instrument") return "종목코드 입력, 설치 종목 마스터 표본 우선";
  if (kind === "RadioGroup") return "라디오 그룹의 모든 항목 선택";
  if (kind === "CheckBox") return "선택·해제 두 상태 확인";
  if (kind === "ComboBox") return "공식 또는 런타임 목록의 모든 항목 선택";
  if (role === "Query" || role === "AutoQuery") return "조회 실행 또는 값 변경 후 자동조회";
  if (role === "Export") return "내보내기 명령, 파일 생성 여부는 별도 관찰";
  if (role === "Pagination") return "다음/이전 페이지 이동";
  if (role === "Navigation") return "연계 화면 열기 후 원래 화면 복귀";
  if (role === "StateController") return "다른 컨트롤의 활성·표시·값 상태 변경";
  return role ? `MAP 의미 역할: ${role}` : "표시문자 또는 런타임 상태 확인 필요";
};

const genericRuntimeLabel = (value) => {
  const text = String(value ?? "").trim();
  return !text || /^(이름 없는 콘텐츠 버튼|현재 상태|반대 상태|라디오 항목 \d+|탭 \d+)/.test(text) || /^\d{4}\/\d{2}\/\d{2}$/.test(text);
};

const runtimeByScreen = new Map((Array.isArray(runtimeRows) ? runtimeRows : []).map((row) => [String(row.screenNumber), row]));
const compactRuntimeObservation = (screenNumber) => {
  const row = runtimeByScreen.get(String(screenNumber));
  if (!row) return null;
  const seen = new Set();
  const controls = [];
  for (const control of row.discoveredControls ?? []) {
    const optionLabels = unique((control.options ?? []).map((option) => option.displayValue).filter((label) => !genericRuntimeLabel(label)));
    const key = [control.tabOrder, control.controlKind, control.name, optionLabels.join("|")].join("|");
    if (seen.has(key)) continue;
    seen.add(key);
    controls.push({
      observedTabOrder: Number(control.tabOrder ?? -1),
      controlKind: String(control.controlKind ?? "Unknown"),
      observedName: genericRuntimeLabel(control.name) ? "" : String(control.name ?? ""),
      claimedByDataset: Boolean(control.claimedByDataset),
      observedOptionCount: Number((control.options ?? []).length),
      trustworthyOptionLabels: optionLabels,
    });
  }
  controls.sort((left, right) => left.observedTabOrder - right.observedTabOrder);
  return {
    provenance: "2026-08-04 과거 실제 실행에서 민감값·좌표·결과를 제거한 관찰",
    authority: "SupplementalOnly",
    warning: "MAP 논리 컨트롤과 일대일 결합되지 않은 과거 관찰이다. MAP 정의보다 우선하지 말고 실제 다음 실행에서 다시 확인한다.",
    controls,
  };
};

const compactControl = (control) => ({
  logicalName: String(control.logicalName ?? ""),
  definitionOrder: Number(control.definitionOrder ?? 0),
  mapKind: String(control.kind ?? "Unknown"),
  runnerControlKind: String(control.ruleControlKind ?? "Unknown"),
  semanticRole: String(control.semanticRole ?? ""),
  roleHint: roleHint(control),
  tabStopCandidate: Boolean(control.isTabStopCandidate),
  events: sortedUnique(control.events),
  triggeredRequests: sortedUnique(control.triggeredRequestNames),
  readsControls: sortedUnique(control.readControls),
  affectsControls: sortedUnique(control.affectedControls),
  resultControls: sortedUnique(control.resultControls),
  invokedHandlers: sortedUnique(control.invokedHandlers),
  navigationTargets: (control.navigationTargets ?? []).map((target) => ({
    api: String(target.api ?? ""),
    targetScreenCode: String(target.targetScreenCode ?? ""),
    targetExpression: String(target.targetExpression ?? ""),
    dynamic: Boolean(target.isDynamic),
  })),
  officialOptions: (control.staticOptions ?? []).map(normalizeOption),
  optionSource: redactSourcePath(control.optionSource),
  labelStatus: (control.staticOptions ?? []).length ? "공식 선택지 표시문자 있음" : "MAP 논리 ID만 있음; 화면 표시문자는 런타임 확인 필요",
});

const compactDataReference = (reference) => ({
  usage: String(reference.usage ?? ""),
  section: String(reference.section ?? ""),
  boundControl: String(reference.boundControl ?? ""),
  sourceFile: redactSourcePath(reference.sourceFile),
  options: (reference.options ?? []).map((option) => typeof option === "string" ? option : normalizeOption(option)),
});

// 대상 화면별 MAP 정의와 과거 런타임 관찰을 하나의 근거 레코드로 묶는다.
const screens = (catalog.screens ?? [])
  .filter((screen) => targetScreens.has(String(screen.screenNumber)))
  .sort((left, right) => String(left.screenNumber).localeCompare(String(right.screenNumber)))
  .map((screen) => {
    const actionable = (screen.controls ?? []).filter((control) => control.isActionable).sort((left, right) => left.definitionOrder - right.definitionOrder);
    const byName = new Map((screen.controls ?? []).map((control) => [String(control.logicalName), control]));
    return {
      screenNumber: String(screen.screenNumber ?? ""),
      screenCode: String(screen.screenCode ?? ""),
      screenName: String(screen.registry?.title || screen.screenName || ""),
      tabSiblingScreens: sortedUnique(screen.tabSiblings),
      sourceEvidence: {
        mapFile: redactSourcePath(screen.sourceFile),
        sha256: String(screen.sourceSha256 ?? ""),
        integrityStatus: String(screen.integrity?.status ?? "UNKNOWN"),
      },
      orderingPolicy,
      behavior: {
        queryControls: sortedUnique(screen.behavior?.queryControls),
        autoQueryControls: sortedUnique(screen.behavior?.autoQueryControls),
        stateControllerControls: sortedUnique(screen.behavior?.stateControllerControls),
        paginationControls: sortedUnique(screen.behavior?.paginationControls),
        exportControls: sortedUnique(screen.behavior?.exportControls),
        navigationControls: sortedUnique(screen.behavior?.navigationControls),
        inputControls: sortedUnique(screen.behavior?.inputControls),
        resultControls: sortedUnique(screen.behavior?.resultControls),
      },
      actionableControls: actionable.map(compactControl),
      resultSurfaces: sortedUnique(screen.behavior?.resultControls).map((logicalName) => {
        const control = byName.get(logicalName);
        return {
          logicalName,
          mapKind: String(control?.kind ?? "Unknown"),
          updatedBy: actionable.filter((item) => (item.resultControls ?? []).includes(logicalName)).map((item) => item.logicalName),
        };
      }),
      validationRules: (screen.errorOracle?.messageBoxes ?? []).map((message) => ({
        ruleId: String(message.ruleId ?? ""),
        classification: String(message.classification ?? "Info"),
        message: String(message.message ?? ""),
        conditionExpression: String(message.conditionExpression ?? ""),
        targetControls: sortedUnique(message.targetControls),
        expectedInterpretation: message.classification === "InputValidation"
          ? "조건을 의도적으로 만족시킨 음성 입력이면 정상 검증 후보이며 제품 결함으로 바로 판정하지 않는다."
          : "정보·경고·오류 분류와 입력 계약을 함께 대조한다.",
      })),
      dataReferences: (screen.dataReferences ?? []).map(compactDataReference),
      runtimeObservation: compactRuntimeObservation(screen.screenNumber),
      knownLimitations: [
        "MAP에는 일부 owner-drawn 컨트롤의 화면 표시문자가 없을 수 있다.",
        "결과 금액·수량·손익의 업무 정답은 설치 파일만으로 확정할 수 없다.",
        "복합 MAP 조건식은 테스트 데이터 조합으로 변환하기 전에 사람 또는 실행기의 검토가 필요할 수 있다.",
      ],
    };
  });

const officialInputDictionaries = [];
const resultCodeDictionaries = [];
for (const screen of screens) {
  for (const reference of screen.dataReferences) {
    const row = { screenNumber: screen.screenNumber, ...reference };
    if (reference.boundControl) officialInputDictionaries.push(row);
    else resultCodeDictionaries.push(row);
  }
}

const referenceData = {
  packageVersion: "1.0",
  generatedAt,
  referenceDate,
  sourceInstallationFingerprint: String(catalog.installationFingerprint ?? ""),
  accountPolicy: {
    inputMode: "Prefilled",
    guidance: "로그인된 테스트 계좌의 화면 기본값을 사용한다. 계좌번호·예금주·비밀번호를 생성하거나 출력하지 않는다.",
  },
  officialInputDictionaries,
  resultCodeDictionaries,
  instrumentMasters: (catalog.masterDataSources ?? []).map((master) => ({
    id: String(master.id ?? ""),
    purpose: String(master.purpose ?? ""),
    relativePath: redactSourcePath(master.relativePath),
    recordCount: Number(master.recordCount ?? 0),
    integrityStatus: String(master.integrity?.status ?? "UNKNOWN"),
    samples: (master.samples ?? []).map((sample) => ({
      code: String(sample.code ?? ""),
      name: String(sample.name ?? ""),
      market: String(sample.market ?? ""),
      expectedOutcome: normalizeExpectedOutcome(sample.expectedOutcome),
    })),
  })),
  officialErrorCodes: (catalog.errorCodes ?? []).map((item) => ({
    code: String(item.code ?? ""),
    message: String(item.message ?? ""),
    classification: String(item.classification ?? ""),
    isFailure: Boolean(item.isFailure),
  })),
  genericDataStrategies: {
    dateFormat: "yyyyMMdd",
    dateCandidates: ["기준일", "직전 영업일", "월초", "연초", "미래일", "시작일>종료일"],
    textBoundaryCandidates: ["빈값", "0", "1", "최대 길이 경계", "형식 밖 값"],
    checkboxCandidates: ["false", "true"],
    finiteChoicePolicy: "콤보·라디오·탭은 발견 가능한 모든 항목을 각각 한 번 이상 선택한다.",
    combinationPolicy: "상태 수가 작으면 전체 조합, 폭증하면 단일요인+pairwise를 우선하고 누락 조합을 명시한다.",
  },
};

// 생성 결과가 현재 실행기에서 해석 가능한 값과 동작만 사용하도록 계약 범위를 고정한다.
const datasetContract = {
  packageVersion: "1.0",
  targetScreens: screens.map((screen) => ({ screenNumber: screen.screenNumber, screenName: screen.screenName })),
  runnerDatasetSchemaVersion: String(dataset.schemaVersion ?? "1.2"),
  outputWillBeMergedInto: path.basename(datasetPath),
  interactionStrategy,
  doNotGenerate: ["accounts", "accountNumber", "owner", "password", "passwordSecret", "절대좌표"],
  supportedControlKinds: ["Auto", "Text", "Date", "ComboBox", "RadioButton", "CheckBox", "Tab", "Button", "ListBox", "ListView", "TreeView", "Slider", "Spin"],
  supportedValueMatches: ["Value", "DisplayText", "Index", "Checked"],
  expectedOutcomeTypes: ["Unspecified", "Success", "ValidationAllowed", "ValidationRequired", "FailureRequired", "NoDataAllowed", "WarningAllowed", "ObservationOnly"],
  expectedOutcomeSources: ["Dataset", "InstallationInputOption", "InstallationMaster", "MapValidation", "MapBehavior", "RuntimeChoice", "GeneratedBoundary", "ScreenExpectedPattern", "Unspecified"],
  currentLimits: {
    maxExpandedCases: Number(dataset.maxExpandedCases ?? 10000),
    maxControlsPerScreen: Number(dataset.autoExploration?.maxControlsPerScreen ?? 500),
    maxOptionsPerControl: Number(dataset.autoExploration?.maxOptionsPerControl ?? 500),
    maxActionsPerScreen: Number(dataset.autoExploration?.maxActionsPerScreen ?? 50000),
  },
  variableShape: {
    requiredFields: ["name", "targetRole", "targetLogicalName", "controlKind", "valueMatch", "values", "appliesToScreens", "required", "triggerQueryAfterChange"],
    valueRequiredFields: ["id", "value", "displayValue", "expectedOutcome", "rationale", "sourceRefs"],
    locatorRule: "MAP logicalName만으로 현재 명시 변수 로케이터가 완성되지는 않는다. 화면 표시문자·클래스·런타임 결합 근거가 없으면 locatorRequests에 기록하고 좌표를 발명하지 않는다.",
  },
  generationRules: [
    "화면마다 기본 조회 1건 이상을 생성한다.",
    "모든 actionableControls는 최소 한 시나리오가 커버하거나 coverageGaps에 사유가 있어야 한다.",
    "공식 선택지는 누락 없이 각 값별 테스트 데이터에 포함한다.",
    "라디오·체크·콤보·탭은 가능한 모든 유한 상태를 포함한다.",
    "MAP validationRules의 각 ruleId는 음성 테스트 또는 미생성 사유로 추적한다.",
    "ValidationRequired에는 messagePatterns 또는 errorCodes를 반드시 넣는다.",
    "정상 입력에서 입력 검증이 발생하면 FAIL 후보, 의도한 음성 입력에서 지정 검증이 발생하면 PASS다.",
    "업무 결과 수치의 정답을 추측하지 않는다. 별도 오라클이 없으면 존재·무응답·오류 신호만 관찰한다.",
    `definitionOrder를 실제 탭 순서로 단정하지 않는다. 실행 순서는 ${interactionStrategy}로 지정한다.`,
  ],
};

const outputSchema = {
  $schema: "https://json-schema.org/draft/2020-12/schema",
  $id: "https://local.example/target-qa/generated-scenarios.schema.json",
  title: `${targetDisplayName} 외부 생성 테스트 시나리오`,
  type: "object",
  additionalProperties: false,
  required: ["packageVersion", "sourceInstallationFingerprint", "generationSummary", "screens", "datasetPatch", "reviewItems"],
  properties: {
    packageVersion: { const: "1.0" },
    sourceInstallationFingerprint: { const: String(catalog.installationFingerprint ?? "") },
    generationSummary: {
      type: "object",
      additionalProperties: false,
      required: ["referenceDate", "combinationStrategy", "assumptions"],
      properties: {
        referenceDate: { type: "string", pattern: "^[0-9]{8}$" },
        combinationStrategy: { enum: ["Full", "SingleFactor", "Pairwise", "Mixed"] },
        assumptions: { type: "array", items: { type: "string" } },
      },
    },
    screens: {
      type: "array",
      minItems: screens.length,
      maxItems: screens.length,
      items: { $ref: "#/$defs/screenPlan" },
      allOf: screens.map((screen) => ({
        contains: {
          type: "object",
          required: ["screenNumber"],
          properties: { screenNumber: { const: screen.screenNumber } },
        },
        minContains: 1,
        maxContains: 1,
      })),
    },
    datasetPatch: {
      type: "object",
      additionalProperties: false,
      required: ["variables", "locatorRequests"],
      properties: {
        variables: { type: "array", items: { $ref: "#/$defs/variable" } },
        locatorRequests: { type: "array", items: { $ref: "#/$defs/locatorRequest" } },
      },
    },
    reviewItems: { type: "array", items: { $ref: "#/$defs/reviewItem" } },
  },
  $defs: {
    expectedOutcome: {
      type: "object",
      additionalProperties: false,
      required: ["type", "messagePatterns", "errorCodes", "queryShouldComplete", "source", "confidence", "evidence"],
      properties: {
        type: { enum: datasetContract.expectedOutcomeTypes },
        messagePatterns: { type: "array", items: { type: "string" } },
        errorCodes: { type: "array", items: { type: "string" } },
        queryShouldComplete: { type: ["boolean", "null"] },
        source: { enum: datasetContract.expectedOutcomeSources },
        confidence: { enum: ["High", "Medium", "Low", "Unspecified"] },
        evidence: { type: "array", items: { type: "string" } },
      },
    },
    testValue: {
      type: "object",
      additionalProperties: false,
      required: ["id", "value", "displayValue", "expectedOutcome", "rationale", "sourceRefs"],
      properties: {
        id: { type: "string", minLength: 1 },
        value: { type: "string" },
        displayValue: { type: "string" },
        expectedOutcome: { $ref: "#/$defs/expectedOutcome" },
        rationale: { type: "string", minLength: 1 },
        sourceRefs: { type: "array", minItems: 1, items: { type: "string" } },
      },
    },
    variable: {
      type: "object",
      additionalProperties: false,
      required: datasetContract.variableShape.requiredFields,
      properties: {
        name: { type: "string", minLength: 1 },
        targetRole: { type: "string", minLength: 1 },
        targetLogicalName: { type: "string", minLength: 1 },
        controlKind: { enum: datasetContract.supportedControlKinds },
        valueMatch: { enum: datasetContract.supportedValueMatches },
        values: { type: "array", minItems: 1, items: { $ref: "#/$defs/testValue" } },
        appliesToScreens: { type: "array", minItems: 1, items: { enum: screens.map((screen) => screen.screenNumber) } },
        required: { type: "boolean" },
        triggerQueryAfterChange: { type: "boolean" },
      },
    },
    step: {
      type: "object",
      additionalProperties: false,
      required: ["sequence", "action", "controlLogicalName", "valueRef", "expectedObservation"],
      properties: {
        sequence: { type: "integer", minimum: 1 },
        action: { enum: ["Focus", "Input", "Select", "Toggle", "Click", "DoubleClick", "Query", "Observe", "Restore", "AssertVisible", "AssertEnabled", "AssertSelected", "AssertGrid", "AssertPopup", "AssertNoTransmission"] },
        controlLogicalName: { type: ["string", "null"] },
        valueRef: { type: ["string", "null"] },
        expectedObservation: { type: "string" },
      },
    },
    scenario: {
      type: "object",
      additionalProperties: false,
      required: ["scenarioId", "title", "objective", "priority", "category", "executionOrder", "preconditions", "steps", "coveredControls", "coveredValidationRuleIds", "expectedResult", "automationStatus"],
      properties: {
        scenarioId: { type: "string", pattern: "^TS-07[0-9]{2}-[A-Z0-9_-]+$" },
        title: { type: "string", minLength: 1 },
        objective: { type: "string", minLength: 1 },
        priority: { enum: ["P0", "P1", "P2", "P3"] },
        category: { enum: ["기본조회", "입력검증", "경계값", "선택지전수", "상태조합", "기간조합", "조회결과관찰", "내보내기", "페이지이동", "연계화면", "복구"] },
        executionOrder: { const: interactionStrategy },
        preconditions: { type: "array", items: { type: "string" } },
        steps: { type: "array", minItems: 1, items: { $ref: "#/$defs/step" } },
        coveredControls: { type: "array", items: { type: "string" } },
        coveredValidationRuleIds: { type: "array", items: { type: "string" } },
        expectedResult: { type: "string", minLength: 1 },
        automationStatus: { enum: ["Ready", "NeedsLocator", "NeedsBusinessData", "ManualReview"] },
      },
    },
    screenPlan: {
      type: "object",
      additionalProperties: false,
      required: ["screenNumber", "screenName", "scenarios", "coverageGaps"],
      properties: {
        screenNumber: { enum: screens.map((screen) => screen.screenNumber) },
        screenName: { type: "string", minLength: 1 },
        scenarios: { type: "array", minItems: 1, items: { $ref: "#/$defs/scenario" } },
        coverageGaps: { type: "array", items: { type: "string" } },
      },
    },
    locatorRequest: {
      type: "object",
      additionalProperties: false,
      required: ["screenNumber", "targetRole", "logicalName", "reason", "recommendedEvidence"],
      properties: {
        screenNumber: { type: "string", pattern: "^07[0-9]{2}$" },
        targetRole: { type: "string" },
        logicalName: { type: "string" },
        reason: { type: "string" },
        recommendedEvidence: { type: "string" },
      },
    },
    reviewItem: {
      type: "object",
      additionalProperties: false,
      required: ["severity", "screenNumber", "subject", "question", "reason"],
      properties: {
        severity: { enum: ["Required", "Recommended", "Informational"] },
        screenNumber: { type: ["string", "null"] },
        subject: { type: "string" },
        question: { type: "string" },
        reason: { type: "string" },
      },
    },
  },
};

const exampleOutput = {
  packageVersion: "1.0",
  sourceInstallationFingerprint: referenceData.sourceInstallationFingerprint,
  generationSummary: {
    referenceDate,
    combinationStrategy: "Mixed",
    assumptions: ["예시이므로 한 화면의 기본 조회만 축약해 표시했다."],
  },
  screens: screens.map((screen) => {
    const query = screen.behavior.queryControls[0] ?? null;
    return {
      screenNumber: screen.screenNumber,
      screenName: screen.screenName,
      scenarios: [{
        scenarioId: `TS-${screen.screenNumber}-BASIC_QUERY`,
        title: "기본값 조회",
        objective: "현재 화면 기본값으로 조회가 실행되고 시스템 실패 신호가 없는지 확인한다.",
        priority: "P0",
        category: "기본조회",
        executionOrder: interactionStrategy,
        preconditions: [`${targetDisplayName} 로그인 및 표시 완료`, hasConfiguredAccounts ? "테스트 계좌 기본값 표시" : "대상 화면 기본 입력값 표시"],
        steps: [
          { sequence: 1, action: "Focus", controlLogicalName: null, valueRef: null, expectedObservation: "대상 화면이 표시된다." },
          { sequence: 2, action: "Query", controlLogicalName: query, valueRef: null, expectedObservation: "조회 동작이 실행되고 화면이 응답 상태를 유지한다." },
          { sequence: 3, action: "Observe", controlLogicalName: null, valueRef: null, expectedObservation: "시스템·통신·프로그램 실패 팝업과 신규 실패 로그가 없다." },
        ],
        coveredControls: query ? [query] : [],
        coveredValidationRuleIds: [],
        expectedResult: "제품 실패 신호가 없고 조회 실행 증거가 있으면 PASS 후보이며, 업무 수치 정합성은 판정하지 않는다.",
        automationStatus: query ? "Ready" : "NeedsLocator",
      }],
      coverageGaps: ["예시 파일이므로 기본 조회 외 컨트롤과 검증 규칙은 생략했다."],
    };
  }),
  datasetPatch: {
    variables: [],
    locatorRequests: screens.filter((screen) => !screen.behavior.queryControls.length).map((screen) => ({
      screenNumber: screen.screenNumber,
      targetRole: "query",
      logicalName: "UNKNOWN_QUERY",
      reason: "MAP 조회 컨트롤을 찾지 못했다.",
      recommendedEvidence: "런타임 탭 순회와 버튼 표시문자",
    })),
  },
  reviewItems: [{
    severity: "Informational",
    screenNumber: null,
    subject: "예시 범위",
    question: `실제 생성 시 ${screens.length}개 대상 화면의 모든 컨트롤과 검증 규칙을 커버했는가?`,
    reason: "이 파일은 스키마를 만족하는 최소 형식 예시이며 완성 시나리오가 아니다.",
  }],
};

const context = {
  packageVersion: "1.0",
  generatedAt,
  referenceDate,
  sourceInstallationFingerprint: String(catalog.installationFingerprint ?? ""),
  scope: {
    requestedRange: targetScopeLabel,
    registeredTargetScreens: screens.map((screen) => screen.screenNumber),
    note: `화면 ID 범위를 추정하지 않고 데이터셋에 등록된 ${screens.length}개 화면만 대상으로 한다.`,
  },
  sourceAuthority: [
    { rank: 1, source: "Dataset", meaning: "사용자가 명시한 계약" },
    { rank: 2, source: "InstallationInputOption/InstallationMaster", meaning: "HTS 설치본 공식 입력 사전과 마스터" },
    { rank: 3, source: "MapValidation/MapBehavior", meaning: "MAP 검증 조건과 동작 그래프" },
    { rank: 4, source: "HistoricalRuntimeObservation", meaning: "과거 실행에서 민감정보를 제거한 탭·라벨 관찰, 보조 근거만 사용" },
  ],
  globalRules: datasetContract.generationRules,
  screens,
};

const prompt = `# ChatGPT 요청문\n\n첨부된 파일은 ${targetDisplayName}에 등록된 ${screens.length}개 화면(${targetScopeLabel})의 테스트 시나리오 생성용 근거다. 다음 파일을 모두 읽고 작업하라.\n\n- \`02_화면_시나리오_컨텍스트.json\`: 화면별 MAP 컨트롤, 조회·상태·결과 관계, 검증 조건, 과거 런타임 관찰\n- \`03_공통_테스트데이터_사전.json\`: 공식 선택지, 종목 마스터 표본, 오류코드, 공통 데이터 전략\n- \`04_데이터셋_작성_계약.json\`: 현재 실행기가 받을 수 있는 변수 구조와 제한\n- \`05_생성결과.schema.json\`: 반드시 만족해야 하는 최종 JSON Schema\n- \`06_생성결과_예시.json\`: 형식 예시이며 범위나 값은 복사하지 말 것\n- \`07_오류_판정_정책.md\`: 기대 검증과 제품 결함을 구분하는 기준\n\n## 목표\n\n각 대상 화면에 대해 기본 조회, 모든 유한 선택지, 날짜·텍스트 경계, MAP 입력 검증, 상태 토글로 나타나는 하위 요소, 조회·페이지·내보내기·연계 화면을 가능한 범위에서 커버하는 테스트 시나리오와 테스트 데이터를 생성하라.\n\n## 필수 규칙\n\n1. 최종 산출물은 \`05_생성결과.schema.json\`을 만족하는 UTF-8 \`generated-scenarios.json\` 파일이어야 한다. 채팅 본문에는 화면별 시나리오 수, 변수 수, 미해결 항목 수만 요약하라.\n2. 화면 ID는 컨텍스트에 등록된 ${screens.length}개만 사용한다. 등록되지 않은 화면 ID를 추측하지 않는다.\n3. 계좌번호, 예금주, 비밀번호, 비밀번호 환경변수 이름을 생성하거나 요구하거나 출력하지 않는다. 민감 입력은 로그인된 테스트 환경의 화면 기본값을 사용한다.\n4. MAP \`definitionOrder\`를 실제 탭 순서로 단정하지 않는다. 모든 시나리오의 \`executionOrder\`는 \`RuntimeTabOrder\`다.\n5. MAP 논리 ID와 화면 표시문자가 모호하면 좌표·라벨을 발명하지 말고 \`locatorRequests\`와 \`reviewItems\`에 기록한다.\n6. 공식 입력 선택지는 각 값을 빠짐없이 테스트 데이터에 넣는다. 라디오·체크·콤보·탭은 가능한 모든 상태를 포함한다.\n7. 날짜 값은 \`yyyyMMdd\`를 사용하고 \`generationSummary.referenceDate\`를 기준으로 산정 근거를 적는다. 영업일 여부를 확정할 수 없으면 가정으로 명시한다.\n8. 각 MAP \`validationRules.ruleId\`는 음성 테스트로 커버하거나 \`coverageGaps\`에 미생성 사유를 적는다. \`ValidationRequired\`에는 원문 기반 \`messagePatterns\` 또는 공식 \`errorCodes\`가 필요하다.\n9. 의도한 잘못된 입력을 대상 프로그램이 거부하는 것은 정상 검증이다. 시스템·통신·인증·프로그램 실패는 어떤 허용 규칙으로도 숨기지 않는다.\n10. 설치 자료에 없는 업무 결과의 정답은 추측하지 않는다. 그런 결과는 표시·갱신·무응답·오류 신호만 관찰하고 \`NeedsBusinessData\` 또는 검토 항목으로 남긴다.\n11. 조합 수가 작으면 전체 조합을 사용한다. 폭증하면 단일요인과 pairwise를 사용하되 생략한 조합과 이유를 명시한다.\n12. 모든 actionable control은 하나 이상의 \`coveredControls\`에 나타나거나 화면의 \`coverageGaps\`에 이유가 있어야 한다.\n13. 근거는 \`sourceRefs\`와 \`expectedOutcome.evidence\`에 화면 ID, control logicalName, validation ruleId, 설치 사전 ID 중 하나 이상으로 기록한다.\n\n생성을 시작하기 전에 내부적으로 스키마와 ${screens.length}개 화면 목록을 검증하고, 완성 후 다시 JSON Schema 적합성과 컨트롤·검증 규칙 커버리지를 자체 점검하라.\n`;

const readme = `# ${targetDisplayName} 외부 시나리오 생성 패키지\n\n## 사용 방법\n\n1. ChatGPT 새 대화에 이 폴더의 \`01_ChatGPT_요청문.md\`부터 \`07_오류_판정_정책.md\`까지 7개 파일을 첨부한다.\n2. \`01_ChatGPT_요청문.md\`의 내용을 그대로 요청문으로 사용한다.\n3. ChatGPT가 만든 \`generated-scenarios.json\`을 \`05_생성결과.schema.json\`과 로컬 검증기로 검사한다.\n4. \`datasetPatch.variables\`는 검토 후 \`${path.basename(datasetPath)}\`의 \`variables[]\`에 병합한다.\n5. \`locatorRequests\`가 남은 컨트롤은 화면 표시문자 또는 실제 런타임 결합 정보를 확보하기 전까지 실행 데이터로 확정하지 않는다.\n\n## 파일 설명\n\n- \`01_ChatGPT_요청문.md\`: 바로 사용할 요청문\n- \`02_화면_시나리오_컨텍스트.json\`: ${screens.length}개 화면의 압축된 기준 모델\n- \`03_공통_테스트데이터_사전.json\`: 공식 입력값·종목 표본·오류코드\n- \`04_데이터셋_작성_계약.json\`: 실행기 데이터 구조와 생성 규칙\n- \`05_생성결과.schema.json\`: ChatGPT 산출물 검증 스키마\n- \`06_생성결과_예시.json\`: 형식 예시\n- \`07_오류_판정_정책.md\`: PASS·FAIL·PENDING 기준\n- \`08_생성결과_검증.mjs\`: 화면·컨트롤·검증규칙·민감키 검사\n- \`PACKAGE_MANIFEST.json\`: 파일 해시와 출처 지문\n\n## 중요한 제한\n\n- 이 패키지에는 계좌번호·예금주·비밀번호·로그 원문·스크린샷·좌표가 없다.\n- MAP은 정적 정의이며 실제 활성 상태와 탭 순서는 실행 시 다시 확인한다.\n- 과거 런타임 관찰은 MAP과 일대일 결합되지 않은 보조 근거다.\n- 업무 결과 수치의 기대값은 별도 업무 데이터가 없으면 생성하지 않는다.\n- 생성 결과는 바로 실제 대상에 적용하지 말고 스키마 검증과 사람 검토를 거친다.\n\n## 생성 결과 검사\n\nChatGPT가 만든 파일을 이 폴더에 \`generated-scenarios.json\`으로 둔 뒤 실행한다.\n\n\`\`\`powershell\nnode .\\08_생성결과_검증.mjs .\\generated-scenarios.json\n\`\`\`\n`;

await fs.mkdir(outputDir, { recursive: true });
// 패키지 파일 목록은 사용자 요청문, 근거, 스키마, 검증기를 함께 제공하는 완결 단위다.
const files = new Map([
  ["00_사용안내.md", readme],
  ["01_ChatGPT_요청문.md", prompt.replaceAll("RuntimeTabOrder", interactionStrategy)],
  ["02_화면_시나리오_컨텍스트.json", JSON.stringify(context, null, 2) + "\n"],
  ["03_공통_테스트데이터_사전.json", JSON.stringify(referenceData, null, 2) + "\n"],
  ["04_데이터셋_작성_계약.json", JSON.stringify(datasetContract, null, 2) + "\n"],
  ["05_생성결과.schema.json", JSON.stringify(outputSchema, null, 2) + "\n"],
  ["06_생성결과_예시.json", JSON.stringify(exampleOutput, null, 2) + "\n"],
  ["07_오류_판정_정책.md", policy.trim() + "\n"],
  ["08_생성결과_검증.mjs", validator],
]);

// 파일을 쓰기 직전에 민감 토큰이 직렬화 결과에 남았는지 다시 검사한다.
const forbiddenTokens = unique((dataset.accounts ?? []).flatMap((account) => [account.accountNumber, account.owner, account.passwordSecret?.key]))
  .filter((token) => String(token).trim().length >= 2);
for (const [name, content] of files) {
  for (const token of forbiddenTokens) {
    if (content.includes(String(token))) throw new Error(`민감정보 검사 실패: ${name}에 데이터셋 계좌 식별값이 포함되었습니다.`);
  }
  await fs.writeFile(path.join(outputDir, name), content, "utf8");
}

const manifestFiles = [];
for (const name of files.keys()) {
  const bytes = await fs.readFile(path.join(outputDir, name));
  manifestFiles.push({
    name,
    sizeBytes: bytes.length,
    sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
  });
}
const manifest = {
  packageVersion: "1.0",
  generatedAt,
  referenceDate,
  sourceInstallationFingerprint: String(catalog.installationFingerprint ?? ""),
  targetScreens: screens.map((screen) => screen.screenNumber),
  counts: {
    screens: screens.length,
    actionableControls: screens.reduce((sum, screen) => sum + screen.actionableControls.length, 0),
    validationRules: screens.reduce((sum, screen) => sum + screen.validationRules.length, 0),
    officialInputDictionaries: officialInputDictionaries.length,
    officialInputValues: officialInputDictionaries.reduce((sum, item) => sum + item.options.length, 0),
    masterSamples: referenceData.instrumentMasters.reduce((sum, master) => sum + master.samples.length, 0),
    officialErrorCodes: referenceData.officialErrorCodes.length,
    runtimeObservedScreens: screens.filter((screen) => screen.runtimeObservation).length,
  },
  privacy: {
    accountValuesIncluded: false,
    ownerNamesIncluded: false,
    passwordsIncluded: false,
    logsIncluded: false,
    screenshotsIncluded: false,
    coordinatesIncluded: false,
  },
  files: manifestFiles,
};
await fs.writeFile(path.join(outputDir, "PACKAGE_MANIFEST.json"), JSON.stringify(manifest, null, 2) + "\n", "utf8");

console.log(JSON.stringify({ outputDir, manifest }, null, 2));
