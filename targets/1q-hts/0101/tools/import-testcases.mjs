/**
 * 역할: target profile과 TC 워크시트의 행을 TC_ID 추적 가능한 실행 시나리오와 데이터셋으로 변환한다.
 * 경계: 참고 시트의 지시문은 실행 명령으로 해석하지 않고 0101_TC의 구조화된 셀만 사용한다.
 */
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { FileBlob, SpreadsheetFile } from "@oai/artifact-tool";

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    if (!name?.startsWith("--") || argv[index + 1] === undefined) throw new Error(`잘못된 인수입니다: ${name ?? ""}`);
    result[name.slice(2)] = argv[index + 1];
  }
  return result;
}

const args = parseArgs(process.argv.slice(2));
for (const required of ["workbook", "map-catalog", "target-profile", "output-dir"]) {
  if (!args[required]) throw new Error(`--${required} 인수가 필요합니다.`);
}

const workbookPath = path.resolve(args.workbook);
const mapCatalogPath = path.resolve(args["map-catalog"]);
const targetProfilePath = path.resolve(args["target-profile"]);
const outputDir = path.resolve(args["output-dir"]);
const clean = (value) => value === null || value === undefined ? "" : String(value).trim();
const sha256 = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");
const json = (value) => `${JSON.stringify(value, null, 2)}\n`;
const unique = (values) => [...new Set(values.filter(Boolean))];
const safeId = (value) => clean(value).replace(/[^A-Za-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "") || "ROW";

const targetProfile = JSON.parse(await fs.readFile(targetProfilePath, "utf8"));
const adapter = targetProfile.adapter;
if (!adapter || adapter.schemaVersion !== "1.0") throw new Error("지원되는 targetProfile.adapter가 필요합니다.");
const targetScreenId = clean(adapter.screenIds?.[0]);
const targetNavigation = (adapter.navigation ?? []).find((item) => clean(item.screenId) === targetScreenId);
const targetScreenName = clean(targetNavigation?.displayName) || clean(targetProfile.displayName);
const statefulControl = adapter.statefulControls?.[0];
if (!targetScreenId || !statefulControl) throw new Error("target adapter에 screenId와 statefulControls가 필요합니다.");

const sourceBytes = await fs.readFile(workbookPath);
const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(workbookPath));
const candidateSheetNames = adapter.import?.candidateSheetNames ?? [];
let tcSheet = null;
let sourceSheetName = "";
for (const candidate of candidateSheetNames) {
  try {
    tcSheet = workbook.worksheets.getItem(candidate);
    sourceSheetName = candidate;
    break;
  } catch {
    // Try the next explicitly supported TC sheet name.
  }
}
if (!tcSheet) throw new Error(`Target TC 워크시트를 찾을 수 없습니다. 지원 시트: ${candidateSheetNames.join(", ")}`);
const matrix = tcSheet.getUsedRange()?.values ?? [];
if (matrix.length < 2) throw new Error(`${sourceSheetName}에 테스트케이스 행이 없습니다.`);

const headers = matrix[0].map(clean);
const requiredHeaders = ["TC_ID", "대분류", "중분류", "입력값", "테스트절차", "기대결과", "거래소전송", "우선순위", "자동화", "내부화면코드", "컨트롤ID", "컨트롤종류", "이벤트/핸들러", "근거MAP"];
const missingHeaders = requiredHeaders.filter((header) => !headers.includes(header));
if (missingHeaders.length) throw new Error(`${sourceSheetName} 필수 열이 없습니다: ${missingHeaders.join(", ")}`);
const at = (row, name) => clean(row[headers.indexOf(name)]);
const rows = matrix.slice(1).filter((row) => at(row, "TC_ID"));
const duplicateTcIds = rows.map((row) => at(row, "TC_ID")).filter((id, index, all) => all.indexOf(id) !== index);
if (duplicateTcIds.length) throw new Error(`TC_ID가 중복되었습니다: ${unique(duplicateTcIds).join(", ")}`);

const mapCatalog = JSON.parse(await fs.readFile(mapCatalogPath, "utf8"));
const familyFiles = unique((targetProfile.map?.familyFiles ?? []).map((value) => clean(value).toLowerCase()));
const requiredMapFamilyCount = Number(adapter.import?.requiredMapFamilyCount ?? 0);
if (!requiredMapFamilyCount || familyFiles.length !== requiredMapFamilyCount) throw new Error(`Target MAP family는 ${requiredMapFamilyCount}개여야 합니다. 현재 ${familyFiles.length}개입니다.`);
const catalogFiles = unique((mapCatalog.screens ?? []).map((screen) => path.basename(clean(screen.sourceFile)).toLowerCase()));
const missingCatalogFiles = familyFiles.filter((file) => !catalogFiles.includes(file));
if (missingCatalogFiles.length) throw new Error(`MAP 카탈로그에 family 파일이 누락되었습니다: ${missingCatalogFiles.join(", ")}`);

function workbookMapFiles(row) {
  const pattern = new RegExp(`ht${targetScreenId}[0-9a-z]{2}\\.map`, "gi");
  return unique((at(row, "근거MAP").match(pattern) ?? []).map((value) => value.toLowerCase()));
}

function findWorkbookSetting(labels) {
  for (const sheet of workbook.worksheets.items ?? []) {
    const values = sheet.getUsedRange()?.values ?? [];
    for (let rowIndex = 0; rowIndex < Math.min(values.length, 80); rowIndex += 1) {
      for (let columnIndex = 0; columnIndex < Math.min(values[rowIndex]?.length ?? 0, 20); columnIndex += 1) {
        if (!labels.includes(clean(values[rowIndex][columnIndex]))) continue;
        const right = clean(values[rowIndex][columnIndex + 1]);
        if (right) return right;
        const below = clean(values[rowIndex + 1]?.[columnIndex]);
        if (below) return below;
      }
    }
  }
  return "";
}

const accountId = clean(args["account-id"]) || findWorkbookSetting(["계좌 ID", "계좌ID", "테스트계좌ID"]) || `${targetScreenId}-test-account`;
const accountNumber = clean(args["account-number"]) || findWorkbookSetting(["계좌번호", "테스트 계좌번호", "테스트계좌번호"]);
const accountOwner = clean(args["account-owner"]) || findWorkbookSetting(["계좌소유자", "계좌 소유자", "예금주"]) || "테스트 계좌";

function controlKind(raw) {
  const value = clean(raw).toLowerCase();
  if (value.includes("date")) return "Date";
  if (value.includes("combo")) return "ComboBox";
  if (value.includes("radiogroup")) return "RadioGroup";
  if (value.includes("radio")) return "RadioButton";
  if (value.includes("check")) return "CheckBox";
  if (value.includes("tab")) return "Tab";
  if (value.includes("button")) return "Button";
  if (value.includes("grid") || value.includes("listview")) return "ListView";
  if (value.includes("list")) return "ListBox";
  if (value.includes("tree")) return "TreeView";
  if (value.includes("slider")) return "Slider";
  if (value.includes("spin")) return "Spin";
  if (value.includes("text") || value.includes("instrument") || value.includes("edit")) return "Text";
  return "Auto";
}

function actionForKind(kind) {
  if (["Text", "Date", "Spin"].includes(kind)) return "Input";
  if (["ComboBox", "RadioButton", "RadioGroup", "Tab", "ListBox"].includes(kind)) return "Select";
  if (kind === "CheckBox") return "Toggle";
  if (kind === "Button") return "Click";
  return "";
}

function concreteValue(raw, kind) {
  const value = clean(raw);
  if (!value) return "";
  if (/^(해당\s*없음|없음|-|n\/a)$/i.test(value)) return "";
  if (/(전체\s*옵션|모든\s*값|유효값|임의값|기본값|경계값|각각\s*입력|순회)/i.test(value)) return "";
  if (kind === "CheckBox") {
    const tokens = value.match(/(ON|OFF|TRUE|FALSE|체크|해제)/gi) ?? [];
    const last = tokens.at(-1)?.toLowerCase();
    if (["on", "true", "체크"].includes(last)) return "true";
    if (["off", "false", "해제"].includes(last)) return "false";
  }
  if (kind === "Date") {
    const match = /^(\d{4})(\d{2})(\d{2})$/.exec(value);
    if (!match) return "";
    const parsed = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])));
    if (parsed.getUTCFullYear() !== Number(match[1]) || parsed.getUTCMonth() !== Number(match[2]) - 1 || parsed.getUTCDate() !== Number(match[3])) return "";
  }
  return value;
}

function expectedOutcome(row) {
  const result = at(row, "기대결과");
  const errorCodes = unique(at(row, "예상오류코드").split(/[\s,;/]+/).filter((value) => value && !/^(없음|해당없음|-|N)$/i.test(value)));
  const requiresValidation = errorCodes.length > 0 || /(오류|에러|경고|팝업|메시지|불가|거부)/.test(result);
  return {
    type: requiresValidation ? "ValidationAllowed" : "ObservationOnly",
    messagePatterns: requiresValidation && result ? [result] : [],
    errorCodes,
    queryShouldComplete: null,
    source: "Dataset",
    confidence: "High",
    evidence: unique([`${sourceSheetName}:${at(row, "TC_ID")}`, at(row, "근거조건"), at(row, "근거MAP")]),
  };
}

function isTransactional(row) {
  const transmission = at(row, "거래소전송");
  const evidence = [at(row, "중분류"), at(row, "컨트롤ID"), at(row, "이벤트/핸들러"), at(row, "RQ/TR"), at(row, "테스트절차")].join(" ");
  return !/^(N|아니오|미전송|없음)$/i.test(transmission) || /(주문전송|매수주문|sendorder|commrequest|주문버튼)/i.test(evidence);
}

function hasPopupExpectation(row) {
  return /(팝업|메시지|msgbox|오류창|경고창)/i.test([at(row, "기대결과"), at(row, "테스트절차"), at(row, "예상오류코드")].join(" "));
}

// 0101은 조회 화면과 달리 주문 탭의 선택 상태가 명령의 의미를 결정한다.
// MAP의 TAB_Ord 영향 컨트롤과 화면의 표기 순서를 함께 사용해, 명령 전에 탭 선택과
// 선택 상태 검증을 강제한다. 이 값은 바인딩 키의 상태 컨텍스트로도 유지된다.
const orderTabOptions = (statefulControl.options ?? []).map((item) => ({ ...item, context: item.stateContext }));
const orderTabMapCodes = new Set([clean(statefulControl.mapScreenCode).toUpperCase(), ...Object.keys(adapter.mapAliases ?? {}).map((value) => clean(value).toUpperCase())]);
const orderCommandByControl = new Map(orderTabOptions.flatMap((tab) => tab.commandControls.map((controlId) => [controlId, tab])));
const activeOrderTabMapCode = clean(adapter.import?.activeStateMapScreenCode || statefulControl.mapScreenCode).toUpperCase();
const stateLogicalName = clean(statefulControl.logicalName);
const anyStateContext = `${clean(orderTabOptions[0]?.context).split(":")[0]}:any`;
const orderTabAffectedByMap = new Map((mapCatalog.screens ?? []).map((screen) => {
  const tab = (screen.controls ?? []).find((control) => clean(control.logicalName).toUpperCase() === stateLogicalName.toUpperCase());
  return [clean(screen.screenCode).toUpperCase(), new Set((tab?.affectedControls ?? []).map((controlId) => clean(controlId).toUpperCase()))];
}));
const mapControlNames = new Map((mapCatalog.screens ?? []).map((screen) => [
  clean(screen.screenCode).toUpperCase(),
  new Set((screen.controls ?? []).map((control) => clean(control.logicalName).toUpperCase()).filter(Boolean)),
]));

// HT010101/HT010102는 alternate composition의 주문 MAP이다. 현재 0101 기본 구성은
// HT010115를 실제 주문 탭 호스트로 올리므로, 같은 논리 컨트롤은 실행 바인딩을 이 호스트로
// 정규화한다. 원본 행의 근거 MAP은 sourceRefs에 보존된다.
function runtimeMapScreenCode(sourceMapScreenCode, controlId) {
  const runtimeAlias = Object.entries(adapter.mapAliases ?? {}).find(([source]) => source.toUpperCase() === sourceMapScreenCode)?.[1];
  if (!runtimeAlias) return sourceMapScreenCode;
  const activeControls = mapControlNames.get(activeOrderTabMapCode) ?? new Set();
  if (controlId === stateLogicalName || orderCommandByControl.has(controlId) || activeControls.has(controlId)) {
    return clean(runtimeAlias).toUpperCase();
  }
  return sourceMapScreenCode;
}

function explicitOrderTab(row, mapScreenCode, controlId) {
  if (!orderTabMapCodes.has(mapScreenCode)) return null;
  const direct = orderCommandByControl.get(controlId);
  if (direct) return direct;
  const evidence = [at(row, "대분류"), at(row, "중분류"), at(row, "테스트절차"), at(row, "기대결과")].join(" ");
  if (/정정|취소/.test(evidence)) return orderTabOptions[2];
  if (/매도/.test(evidence)) return orderTabOptions[1];
  if (/매수/.test(evidence)) return orderTabOptions[0];
  return null;
}

function orderTabOwnsControl(mapScreenCode, controlId) {
  return orderTabMapCodes.has(mapScreenCode) &&
    (orderTabAffectedByMap.get(mapScreenCode)?.has(controlId) ?? false);
}

function addOrderTabVariable(tcId, tab, variables) {
  const name = `VAR-${safeId(tcId)}-TAB-ORD`;
  variables.push({
    name,
    targetRole: "OrderTab",
    targetLogicalName: stateLogicalName,
    controlKind: "Tab",
    valueMatch: "Index",
    values: [{
      id: `VAL-${safeId(tcId)}-TAB-${tab.id}`,
      value: tab.value,
      displayValue: tab.displayValue,
      expectedOutcome: { type: "ObservationOnly", source: "MapBehavior", confidence: "High", evidence: [`${stateLogicalName}:${tab.displayValue}`] },
      rationale: `주문 명령 전 ${tab.displayValue} 탭을 선택하고 상태를 검증한다.`,
      sourceRefs: [`${targetScreenId} ${stateLogicalName}`, `${sourceSheetName}:${tcId}`],
    }],
    appliesToScreens: [targetScreenId],
    required: true,
    triggerQueryAfterChange: false,
  });
  return name;
}

function addAllOrderTabVariable(tcId, variables) {
  const name = `VAR-${safeId(tcId)}-TAB-ORD-ALL`;
  variables.push({
    name,
    targetRole: "OrderTab",
    targetLogicalName: stateLogicalName,
    controlKind: "Tab",
    valueMatch: "Index",
    values: orderTabOptions.map((tab) => ({
      id: `VAL-${safeId(tcId)}-TAB-${tab.id}`,
      value: tab.value,
      displayValue: tab.displayValue,
      expectedOutcome: { type: "ObservationOnly", source: "MapBehavior", confidence: "High", evidence: [`${stateLogicalName}:${tab.displayValue}`] },
      rationale: `${stateLogicalName} ${tab.displayValue} 탭의 표시·선택 상태를 검증한다.`,
      sourceRefs: [`${targetScreenId} ${stateLogicalName}`, `${sourceSheetName}:${tcId}`],
    })),
    appliesToScreens: [targetScreenId],
    required: true,
    triggerQueryAfterChange: false,
  });
  return name;
}

const variables = [];
const scenarios = [];
const reviewItems = [];
const coverageGaps = [];
const workbookReferencedMaps = new Set();

for (const row of rows) {
  const tcId = at(row, "TC_ID");
  const sourceMapScreenCode = at(row, "내부화면코드").toUpperCase();
  const controlId = at(row, "컨트롤ID");
  const mapScreenCode = runtimeMapScreenCode(sourceMapScreenCode, controlId);
  const kind = controlKind(at(row, "컨트롤종류"));
  const action = actionForKind(kind);
  const input = concreteValue(at(row, "입력값"), kind);
  const orderTab = explicitOrderTab(row, mapScreenCode, controlId);
  const orderCommand = orderCommandByControl.get(controlId) ?? null;
  const orderTabTarget = controlId === stateLogicalName && orderTabMapCodes.has(mapScreenCode);
  const transactional = isTransactional(row) || Boolean(orderCommand);
  const procedure = at(row, "테스트절차");
  const popupExpected = hasPopupExpectation(row);
  const restoreRequired = /원상복구/i.test(procedure);
  const doubleClickRequired = !transactional && action === "Click" && /(빠른\s*)?(이중|더블)\s*클릭|double\s*click/i.test(procedure);
  const steps = [];
  let sequence = 1;
  let popupAssertionsAdded = 0;
  let restoreAdded = false;
  const addStep = (step) => steps.push({ sequence: sequence++, ...step });
  addStep({ action: "Focus", mapScreenCode, stateContext: "", transactional: false, expectedObservation: `${targetScreenId} 화면이 전경에 있고 조작 가능한 상태` });

  let orderTabValueRef = null;
  if (orderTabTarget) {
    orderTabValueRef = addAllOrderTabVariable(tcId, variables);
    addStep({ action: "AssertVisible", controlLogicalName: stateLogicalName, mapScreenCode, stateContext: "", transactional: false, expectedObservation: "주문구분 탭이 표시됨" });
    addStep({ action: "AssertEnabled", controlLogicalName: stateLogicalName, mapScreenCode, stateContext: "", transactional: false, expectedObservation: "주문구분 탭이 선택 가능함" });
    addStep({ action: "Select", controlLogicalName: stateLogicalName, mapScreenCode, stateContext: anyStateContext, transactional: false, valueRef: orderTabValueRef, expectedObservation: "매수·매도·정정/취소 탭 중 지정 탭을 선택" });
    addStep({ action: "AssertSelected", controlLogicalName: stateLogicalName, mapScreenCode, stateContext: anyStateContext, transactional: false, valueRef: orderTabValueRef, expectedObservation: "지정한 주문구분 탭이 선택됨" });
  } else if (orderTab) {
    orderTabValueRef = addOrderTabVariable(tcId, orderTab, variables);
    addStep({ action: "AssertVisible", controlLogicalName: stateLogicalName, mapScreenCode, stateContext: "", transactional: false, expectedObservation: "주문구분 탭이 표시됨" });
    addStep({ action: "AssertEnabled", controlLogicalName: stateLogicalName, mapScreenCode, stateContext: "", transactional: false, expectedObservation: "주문구분 탭이 선택 가능함" });
    addStep({ action: "Select", controlLogicalName: stateLogicalName, mapScreenCode, stateContext: orderTab.context, transactional: false, valueRef: orderTabValueRef, expectedObservation: `${orderTab.displayValue} 탭을 선택` });
    addStep({ action: "AssertSelected", controlLogicalName: stateLogicalName, mapScreenCode, stateContext: orderTab.context, transactional: false, valueRef: orderTabValueRef, expectedObservation: `${orderTab.displayValue} 탭이 선택됨` });
  } else if (orderTabOwnsControl(mapScreenCode, controlId)) {
    // MAP은 영향 관계만 제공하므로 특정 탭 소유를 추측하지 않는다. 세 탭을 모두
    // 선택한 뒤 같은 컨트롤을 확인해 실제 화면별 표시/활성 차이를 결과로 남긴다.
    orderTabValueRef = addAllOrderTabVariable(tcId, variables);
    addStep({ action: "AssertVisible", controlLogicalName: stateLogicalName, mapScreenCode, stateContext: "", transactional: false, expectedObservation: "주문구분 탭이 표시됨" });
    addStep({ action: "AssertEnabled", controlLogicalName: stateLogicalName, mapScreenCode, stateContext: "", transactional: false, expectedObservation: "주문구분 탭이 선택 가능함" });
    addStep({ action: "Select", controlLogicalName: stateLogicalName, mapScreenCode, stateContext: anyStateContext, transactional: false, valueRef: orderTabValueRef, expectedObservation: "매수·매도·정정/취소 탭을 각각 선택" });
    addStep({ action: "AssertSelected", controlLogicalName: stateLogicalName, mapScreenCode, stateContext: anyStateContext, transactional: false, valueRef: orderTabValueRef, expectedObservation: "선택한 주문구분 탭이 유지됨" });
  }

  const tabOwnedControl = orderTabOwnsControl(mapScreenCode, controlId);
  const controlStateContext = orderTab?.context ?? (tabOwnedControl ? "order-tab:any" : "");
  if (controlId && !orderTabTarget) {
    addStep({ action: "AssertVisible", controlLogicalName: controlId, mapScreenCode, stateContext: controlStateContext, transactional: false, expectedObservation: `${controlId}가 현재 선택된 탭에서 표시됨` });
    addStep({ action: "AssertEnabled", controlLogicalName: controlId, mapScreenCode, stateContext: controlStateContext, transactional: false, expectedObservation: `${controlId}가 현재 선택된 탭에서 활성화됨` });
  }

  let valueRef = null;
  if (!orderTabTarget && action && controlId && (action === "Click" || input)) {
    if (action !== "Click") {
      valueRef = `VAR-${safeId(tcId)}`;
      variables.push({
        name: valueRef,
        targetRole: "Input",
        targetLogicalName: controlId,
        controlKind: kind,
        valueMatch: kind === "CheckBox" ? "Checked" : "Value",
        values: [{ id: `VAL-${safeId(tcId)}`, value: input, displayValue: input, expectedOutcome: expectedOutcome(row), rationale: at(row, "사전조건"), sourceRefs: [`${sourceSheetName}:${tcId}`] }],
        appliesToScreens: [targetScreenId],
        required: true,
        triggerQueryAfterChange: false,
      });
    }
    addStep({ action, controlLogicalName: controlId, mapScreenCode, stateContext: controlStateContext, transactional, ...(valueRef ? { valueRef } : {}), expectedObservation: at(row, "기대결과") });
    if (doubleClickRequired) {
      if (popupExpected) {
        addStep({ action: "AssertPopup", mapScreenCode, stateContext: controlStateContext, transactional: false, expectedObservation: at(row, "기대결과") });
        popupAssertionsAdded += 1;
      }
      if (restoreRequired) {
        addStep({ action: "Restore", mapScreenCode, stateContext: controlStateContext, transactional: false, expectedObservation: `열린 설정/편집 UI를 안전하게 닫고 ${targetScreenId} 화면으로 복귀` });
        restoreAdded = true;
      }
      addStep({ action: "DoubleClick", controlLogicalName: controlId, mapScreenCode, stateContext: controlStateContext, transactional: false, expectedObservation: at(row, "기대결과") });
      if (popupExpected) {
        addStep({ action: "AssertPopup", mapScreenCode, stateContext: controlStateContext, transactional: false, expectedObservation: at(row, "기대결과") });
        popupAssertionsAdded += 1;
      }
    }
    if (["Select", "Toggle"].includes(action)) {
      addStep({ action: "AssertSelected", controlLogicalName: controlId, mapScreenCode, stateContext: controlStateContext, transactional: false, ...(valueRef ? { valueRef } : {}), expectedObservation: `${controlId}의 선택 상태가 입력값과 일치함` });
    }
  }

  if (kind === "ListView" && controlId) {
    addStep({ action: "AssertGrid", controlLogicalName: controlId, mapScreenCode, stateContext: controlStateContext, transactional: false, expectedObservation: at(row, "기대결과") });
  }
  if (popupExpected && popupAssertionsAdded === 0) {
    addStep({ action: "AssertPopup", mapScreenCode, stateContext: controlStateContext, transactional: false, expectedObservation: at(row, "기대결과") });
  }
  if (restoreRequired && !restoreAdded) {
    addStep({ action: "Restore", mapScreenCode, stateContext: controlStateContext, transactional: false, expectedObservation: `열린 팝업/연계 UI를 안전하게 닫고 ${targetScreenId} 화면으로 복귀` });
  }
  if (/^(N|아니오|미전송|없음)$/i.test(at(row, "거래소전송"))) {
    addStep({ action: "AssertNoTransmission", mapScreenCode, stateContext: controlStateContext, transactional: false, expectedObservation: "주문/거래소 전송 로그와 체결 이벤트가 증가하지 않음" });
  }

  const automation = at(row, "자동화");
  const unresolvedInput = Boolean(!orderTabTarget && action && action !== "Click" && !input);
  const manual = transactional || /수동|불가/i.test(automation) || unresolvedInput;
  if (unresolvedInput) {
    const subject = `${tcId}:${controlId || "control"}`;
    reviewItems.push({ severity: "Required", screenNumber: targetScreenId, subject, question: "구체 실행 입력값 또는 상태 순회 규칙을 승인해 주세요.", reason: `입력값 '${at(row, "입력값")}'은 단일 실행값으로 확정할 수 없습니다.` });
  }
  for (const file of workbookMapFiles(row)) workbookReferencedMaps.add(file);
  if (!mapScreenCode || !controlId) coverageGaps.push(`${tcId}: 내부화면코드 또는 컨트롤ID가 없어 전역 검증 단계만 생성됨`);

  scenarios.push({
    scenarioId: `TC-${safeId(tcId)}`,
    sourceTestCaseId: tcId,
    mapScreenCode,
    transactional,
    title: `${at(row, "대분류")} / ${at(row, "중분류")}`,
    objective: at(row, "테스트절차"),
    priority: at(row, "우선순위") || "P2",
    category: orderCommand ? "주문명령" : at(row, "대분류") || targetScreenId,
    executionOrder: "CoordinateFocus",
    preconditions: unique([at(row, "사전조건"), at(row, "상품유형"), at(row, "시장/장구분"), at(row, "주문유형"), at(row, "체결조건")]),
    steps,
    coveredControls: unique([controlId, ...((orderTab || tabOwnedControl) && !orderTabTarget ? [stateLogicalName] : [])]),
    coveredValidationRuleIds: unique([at(row, "예상오류코드"), at(row, "RQ/TR")]),
    expectedResult: at(row, "기대결과"),
    automationStatus: manual ? "ManualReview" : controlId ? "NeedsLocator" : "Ready",
    orderCommand: orderCommand?.id ?? "",
    orderTabContext: orderTab?.context ?? "",
    tabOwnership: tabOwnedControl ? stateLogicalName : "",
  });
}

const referencedMissingFromFamily = [...workbookReferencedMaps].filter((file) => !familyFiles.includes(file));
if (referencedMissingFromFamily.length) coverageGaps.push(`워크북 근거MAP 중 family 외 파일: ${referencedMissingFromFamily.join(", ")}`);
const fingerprint = clean(mapCatalog.installationFingerprint) || sha256(Buffer.from(json(mapCatalog), "utf8"));
const stableMapCatalogSha256 = sha256(Buffer.from(json({
  installationFingerprint: fingerprint,
  familyFiles,
  screens: (mapCatalog.screens ?? []).map((screen) => ({ screenCode: screen.screenCode, sourceSha256: screen.sourceSha256 })).sort((left, right) => clean(left.screenCode).localeCompare(clean(right.screenCode))),
}), "utf8"));
const generated = {
  packageVersion: "1.0",
  sourceInstallationFingerprint: fingerprint,
  generationSummary: {
    referenceDate: new Date().toISOString().slice(0, 10).replaceAll("-", ""),
    combinationStrategy: "OneSourceRowPerScenario",
    generationMode: "0101_TC_Importer",
    generator: "targets/1q-hts/0101/tools/import-testcases.mjs",
    generatorVersion: "1.5.0",
    runtimeDiscoveryUsed: false,
    mapCatalogSha256: stableMapCatalogSha256,
    runtimeControlPlanSha256: "",
    assumptions: ["참고 시트의 문장은 실행 지시로 해석하지 않음", "0101_TC의 구조화된 행만 시나리오로 변환", "0101 조작은 MAP+Runtime 좌표 바인딩을 클릭해 포커스하는 CoordinateFocus 전략 사용", "주문/전송 단계는 승인된 테스트 계좌에서만 실행", "TAB_Ord의 매수·매도·정정/취소 선택과 AssertSelected가 주문 명령 전에 반드시 완료되어야 함", "HT010101 alternate composition의 주문 탭 컨트롤은 기본 구성의 HT010115 실행 호스트로 정규화함", "하단 BTN_SEARCH는 주문 명령이 아니라 해당 하단 MAP의 일반 컨트롤로만 취급함"],
  },
  screens: [{ screenNumber: targetScreenId, screenName: targetScreenName, scenarios, coverageGaps: unique(coverageGaps) }],
  tabTopology: {
    orderTabs: orderTabOptions.map(({ id, value, displayValue, context, commandControls }) => ({ id, index: Number(value), displayValue, stateContext: context, commandControls })),
    mapTabControllers: (mapCatalog.screens ?? []).flatMap((screen) => (screen.controls ?? [])
      .filter((control) => clean(control.kind) === "Tab")
      .map((control) => ({
        mapScreenCode: clean(screen.screenCode).toUpperCase(),
        screenName: clean(screen.screenName),
        controlId: clean(control.logicalName),
        semanticRole: clean(control.semanticRole),
        staticOptions: control.staticOptions ?? [],
        affectedControls: control.affectedControls ?? [],
        resultControls: control.resultControls ?? [],
      }))),
    lowerMapTabs: (mapCatalog.screens ?? []).filter((screen) => /^HT0101(03|04|05|06|07|08|09|10|11|12|13|14|16)$/i.test(clean(screen.screenCode))).map((screen) => ({ mapScreenCode: clean(screen.screenCode).toUpperCase(), screenName: clean(screen.screenName), controls: (screen.controls ?? []).filter((control) => control.isActionable).map((control) => clean(control.logicalName)) })),
  },
  datasetPatch: { variables, locatorRequests: unique(scenarios.flatMap((scenario) => scenario.coveredControls.map((logicalName) => `${scenario.mapScreenCode}|${logicalName}`))).map((key) => {
    const [mapScreenCode, logicalName] = key.split("|");
    return { screenNumber: targetScreenId, mapScreenCode, targetRole: "Input", logicalName, reason: `${mapScreenCode} MAP family 컨트롤의 실제 HWND/UIA 바인딩 필요`, recommendedEvidence: `${mapScreenCode}|${logicalName}|stateContext 복합 키` };
  }) },
  reviewItems,
};

const dataset = {
  schemaVersion: "2.0",
  datasetId: `${targetScreenId}-TC-${sha256(sourceBytes).slice(0, 12)}`,
  targetProfile: {
    ...targetProfile,
    map: {
      ...targetProfile.map,
      installationRoot: clean(mapCatalog.installationRoot) || clean(targetProfile.map?.installationRoot),
      familyFiles,
    },
  },
  maxExpandedCases: Math.max(2000, scenarios.length + 100),
  executionPolicy: {
    mode: "explicitErrorOnly",
    stopOnFirstError: false,
    screenOpenTimeoutMs: 10000,
    actionTimeoutMs: 5000,
    allowTransactionalActions: true,
    requireApprovedPlanForTransactionalActions: true,
    allowObservedPrefilledTransactionalAccount: true,
    allowedTransactionalAccountIds: [accountId],
    allowedTransactionalScreens: [targetScreenId],
  },
  accounts: [{ id: accountId, accountNumber, owner: accountOwner, inputMode: "Prefilled", enabled: true, metadata: { purpose: `${targetScreenId} 주문 테스트 전용 계좌`, source: `${sourceSheetName} importer` } }],
  screens: [{ screenNumber: targetScreenId, screenName: targetScreenName, enabled: true, queryTrigger: "F12", locators: {}, fixedConditions: {}, expectedPopupPatterns: [] }],
  variables: [],
  defaultLocators: {},
  autoExploration: { interactionStrategy: "CoordinateFocus", enabled: true, includeButtons: true, includeUnlabeledButtons: true, triggerQueryAfterStateChange: false, maxControlsPerScreen: 120, maxOptionsPerControl: 100, maxActionsPerScreen: 5000, contentRegionFile: "data/realhts/content-regions.json", defaultTextValues: [], defaultDateValues: [], excludeTitlePatterns: [], mapBaseline: { enabled: true, matchTolerancePx: 36 } },
};

const summary = {
  sourceWorkbook: workbookPath,
  sourceSha256: sha256(sourceBytes),
  sourceSheet: sourceSheetName,
  importedTestCases: rows.length,
  generatedScenarios: scenarios.length,
  generatedVariables: variables.length,
  transactionalScenarios: scenarios.filter((scenario) => scenario.transactional).length,
  manualReviewScenarios: scenarios.filter((scenario) => scenario.automationStatus === "ManualReview").length,
  mapFamilyCount: familyFiles.length,
  mapCatalogScreenCount: mapCatalog.screens?.length ?? 0,
  workbookReferencedMapCount: workbookReferencedMaps.size,
  accountId,
  accountNumberConfigured: Boolean(accountNumber),
  outputs: { dataset: `${targetScreenId}.dataset.json`, scenarios: "generated-scenarios.json", mapCatalog: path.basename(mapCatalogPath) },
};

await fs.mkdir(outputDir, { recursive: true });
await Promise.all([
  fs.writeFile(path.join(outputDir, `${targetScreenId}.dataset.json`), json(dataset), "utf8"),
  fs.writeFile(path.join(outputDir, "generated-scenarios.json"), json(generated), "utf8"),
  fs.writeFile(path.join(outputDir, "import-summary.json"), json(summary), "utf8"),
]);
console.log(JSON.stringify(summary));
