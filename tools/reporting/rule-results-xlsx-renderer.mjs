/**
 * 역할: 검증된 workbook view model을 artifact-tool Workbook과 XLSX로 렌더링한다.
 * 경계: TestResult 상태를 계산하거나 변경하지 않고 output manager가 허용한 경로에만 파생 파일을 쓴다.
 */
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

export async function renderRuleResultsWorkbook(viewModel, outputManager) {
const {
  summary, results, mapCatalog, compiledPlan, bindingCatalog, physicalPlan, scenarioReviewItems,
  targetDisplayName, targetInstallationRoot, targetScreenDirectory, targetMapPattern, exampleScreenNumber,
  summaryRows, resultHeaders, resultRows, incompleteRows, incompleteByCase, incompleteSummary,
  statusLabel, scenarioReadinessLabel, bindingStatusLabel, confidenceLabel, reviewSeverityLabel,
  physicalDispositionLabel, approvalStatusLabel, actionLabel, cleanCollectedLabel,
  cleanExecutionDetail, compactNavigationTargets, incompleteLabel, excelDate,
} = viewModel;

// 시트 이름은 사용자 보고서의 공개 계약이므로 변경 시 README와 컬럼 설명도 함께 갱신한다.
const workbook = Workbook.create();
const columnGuideSheet = workbook.worksheets.add("컬럼설명");
const errorGuideSheet = workbook.worksheets.add("오류판정기준");
const pipelineSheet = workbook.worksheets.add("테스트모듈로직");
const inputGuideSheet = workbook.worksheets.add("입력데이터안내");
const installationSheet = workbook.worksheets.add("설치카탈로그");
const scenarioSheet = workbook.worksheets.add("시나리오계획");
const bindingSheet = workbook.worksheets.add("컨트롤바인딩");
const approvalSheet = workbook.worksheets.add("승인및제외");
const summarySheet = workbook.worksheets.add("요약");
const resultsSheet = workbook.worksheets.add("테스트결과");
const actionsSheet = workbook.worksheets.add("단계결과");
const variablesSheet = workbook.worksheets.add("입력변수");
const controlsSheet = workbook.worksheets.add("컨트롤계획");
const controlTestsSheet = workbook.worksheets.add("선택지테스트");
const popupsSheet = workbook.worksheets.add("팝업관찰");
const oracleEventsSheet = workbook.worksheets.add("판정이벤트");
const incompleteSheet = workbook.worksheets.add("자동화미완료");
const errorShotsSheet = workbook.worksheets.add("오류스크린샷");

const colors = {
  navy: "#18324A",
  cyan: "#D9EEF2",
  line: "#CBD5E1",
  text: "#17202A",
  muted: "#64748B",
  pass: "#DCFCE7",
  fail: "#FEE2E2",
  pending: "#FEF3C7",
  error: "#FFE4E6",
  white: "#FFFFFF",
};

// 모든 표에 공통 머리글 서식을 적용한다.
function header(range) {
  range.format = {
    fill: colors.navy,
    font: { bold: true, color: colors.white },
    verticalAlignment: "center",
    wrapText: true,
    borders: { preset: "inside", style: "thin", color: "#5C7285" },
  };
}

// 설명형 시트의 제목, 표, 필터, 고정 행과 열 너비를 동일한 방식으로 구성한다.
function writeGuideSheet(sheet, title, headers, rows, widths) {
  const lastColumn = String.fromCharCode(64 + headers.length);
  sheet.mergeCells(`A1:${lastColumn}2`);
  sheet.getRange("A1").values = [[title]];
  sheet.getRange(`A1:${lastColumn}2`).format = {
    fill: colors.navy,
    font: { bold: true, color: colors.white, size: 18 },
    verticalAlignment: "center",
    horizontalAlignment: "left",
  };
  sheet.getRangeByIndexes(3, 0, 1, headers.length).values = [headers];
  header(sheet.getRange(`A4:${lastColumn}4`));
  if (rows.length) {
    sheet.getRangeByIndexes(4, 0, rows.length, headers.length).values = rows;
    sheet.getRange(`A5:${lastColumn}${rows.length + 4}`).format = {
      verticalAlignment: "top",
      wrapText: true,
      borders: { preset: "inside", style: "thin", color: colors.line },
    };
    for (let row = 5; row <= rows.length + 4; row += 2) {
      sheet.getRange(`A${row}:${lastColumn}${row}`).format.fill = "#F8FAFC";
    }
  }
  widths.forEach((width, index) => {
    const column = String.fromCharCode(65 + index);
    sheet.getRange(`${column}1:${column}${rows.length + 4}`).format.columnWidth = width;
  });
  sheet.getRange(`A4:${lastColumn}${rows.length + 4}`).format.rowHeight = 38;
  sheet.freezePanes.freezeRows(4);
}

function statusFill(status) {
  if (status === "PASS" || status === "통과") return colors.pass;
  if (status === "FAIL" || status === "실패") return colors.fail;
  if (status === "ERROR" || status === "오류") return colors.error;
  return colors.pending;
}

for (const sheet of [summarySheet, resultsSheet, actionsSheet, variablesSheet, controlsSheet, controlTestsSheet, popupsSheet, oracleEventsSheet, incompleteSheet, errorShotsSheet, columnGuideSheet, errorGuideSheet, pipelineSheet, inputGuideSheet, installationSheet, scenarioSheet, bindingSheet, approvalSheet]) {
  sheet.showGridLines = false;
}

summarySheet.mergeCells("A1:H2");
summarySheet.getRange("A1").values = [[`${summary.targetDisplayName ?? "대상 화면"} 룰 기반 테스트 결과`]];
summarySheet.getRange("A1:H2").format = {
  fill: colors.navy,
  font: { bold: true, color: colors.white, size: 18 },
  verticalAlignment: "center",
  horizontalAlignment: "left",
};
summarySheet.getRange("A4:B12").values = summaryRows;
summarySheet.getRange("A4:A12").format = { fill: colors.cyan, font: { bold: true, color: colors.text } };
summarySheet.getRange("A4:B12").format.borders = { preset: "outside", style: "thin", color: colors.line };
summarySheet.getRange("B10").format.numberFormat = "yyyy-mm-dd hh:mm:ss";
summarySheet.getRange("D4:H4").values = [["전체", "통과", "실패", "오류", "대기"]];
header(summarySheet.getRange("D4:H4"));
summarySheet.getRange("D5:H5").formulas = [[
  "=COUNTA('테스트결과'!A2:A5001)",
  '=COUNTIF(\'테스트결과\'!K2:K5001,"통과")',
  '=COUNTIF(\'테스트결과\'!K2:K5001,"실패")',
  '=COUNTIF(\'테스트결과\'!K2:K5001,"오류")',
  '=COUNTIF(\'테스트결과\'!K2:K5001,"대기")',
]];
summarySheet.getRange("D5:H5").format = {
  font: { bold: true, size: 16, color: colors.text },
  horizontalAlignment: "center",
  fill: "#F8FAFC",
  borders: { preset: "outside", style: "thin", color: colors.line },
};
summarySheet.getRange("D7:H7").values = [["판정 기준", "팝업", "프로세스", "로그", "스크린샷"]];
header(summarySheet.getRange("D7:H7"));
summarySheet.getRange("D8:H9").values = [
  ["입력 계약 기반 판정", "기대 반응과 대조", "응답 없음/종료", "새 심각 오류 행", "결함·실행 오류 저장"],
  ["업무 값 정합성", "대기", "대기", "대기", "평가하지 않음"],
];
summarySheet.getRange("D8:H9").format = { wrapText: true, fill: "#F8FAFC", borders: { preset: "inside", style: "thin", color: colors.line } };
summarySheet.getRange("D11:F11").values = [["발견 컨트롤", "선택지 테스트", "팝업 관찰"]];
header(summarySheet.getRange("D11:F11"));
summarySheet.getRange("D12:F12").formulas = [[
  "=COUNTA('컨트롤계획'!A2:A100001)",
  "=COUNTA('선택지테스트'!A2:A100001)",
  "=COUNTA('팝업관찰'!A2:A100001)",
]];
summarySheet.getRange("D12:F12").format = { font: { bold: true, size: 14 }, horizontalAlignment: "center", fill: "#F8FAFC" };
summarySheet.mergeCells("G11:H11");
summarySheet.getRange("G11").values = [["결함·실행 오류 이미지"]];
header(summarySheet.getRange("G11:H11"));
summarySheet.mergeCells("G12:H12");
summarySheet.getRange("G12").values = [[results.filter((result) => result.errorDetected || ["FAIL", "ERROR"].includes(result.status)).length]];
summarySheet.getRange("G12:H12").format = { font: { bold: true, size: 14 }, horizontalAlignment: "center", fill: "#F8FAFC" };
summarySheet.getRange("D14:H14").values = [["MAP 모델", "MAP 정의", "실시간 결합", "미결합", "런타임 추가"]];
header(summarySheet.getRange("D14:H14"));
summarySheet.getRange("D15:H15").values = [[
  Number(summary.mapModels ?? 0), Number(summary.mapDefinedControls ?? 0), Number(summary.mapBoundControls ?? 0),
  Number(summary.mapUnboundControls ?? 0), Number(summary.runtimeOnlyControls ?? 0),
]];
summarySheet.getRange("D15:H15").format = { font: { bold: true, size: 14 }, horizontalAlignment: "center", fill: "#F8FAFC" };
summarySheet.getRange("A14:C14").values = [["MAP 오류 화면", "MAP 판정 문구", "MAP 팝업 일치"]];
header(summarySheet.getRange("A14:C14"));
summarySheet.getRange("A15:C15").values = [[
  Number(summary.mapOracleScreens ?? 0), Number(summary.mapOracleMessages ?? 0), Number(summary.mapOracleMatchedPopups ?? 0),
]];
summarySheet.getRange("A15:C15").format = { font: { bold: true, size: 14 }, horizontalAlignment: "center", fill: "#F8FAFC" };
summarySheet.getRange("A20:H21").merge();
summarySheet.getRange("A20").values = [[summary.dryRun
  ? "대기: 이 통합문서는 드라이런 결과입니다. HTS 화면 조작을 실행하지 않았고 어떤 케이스도 통과로 집계하지 않았습니다."
  : `통과는 정해진 조회 동작을 완료하고 입력값별 기대 결과 계약을 위반하지 않았다는 뜻입니다. 기대 입력 검증은 제품 결함과 분리하며 시스템 실패와 기대 위반은 실패로 판정합니다. 모든 물리 입력은 HTS 메인창과 현재 대상 화면의 콘텐츠 경계 안에서만 허용되며, 업무 값의 정합성까지 증명하지는 않습니다.`]];
summarySheet.getRange("A20:H21").format = { fill: colors.pending, wrapText: true, font: { color: colors.text } };
summarySheet.getRange("A1:H21").format.rowHeight = 22;
summarySheet.getRange("A1:H21").format.columnWidth = 18;
summarySheet.getRange("B4:B12").format.columnWidth = 42;

// 시나리오·바인딩·승인 자료는 실제 실행 결과와 분리해 계획의 준비 상태를 보여준다.
const scenarioRows = [];
for (const screen of (compiledPlan?.screens ?? [])) {
  for (const scenario of (screen.scenarios ?? [])) {
    scenarioRows.push([
      Number(screen.screenNumber ?? 0), screen.screenName ?? "", scenario.scenarioId ?? "", scenario.title ?? "",
      scenario.priority ?? "", scenario.category ?? "", scenarioReadinessLabel(scenario.readiness), Number(scenario.caseCount ?? 0), Number(scenario.stepCount ?? 0),
      (scenario.coveredControls ?? []).join(" | "), (scenario.coveredValidationRuleIds ?? []).join(" | "), (scenario.blockingReasons ?? []).join(" | "),
      compiledPlan?.scenarioGenerationMode ?? "External", [compiledPlan?.scenarioGenerator, compiledPlan?.scenarioGeneratorVersion].filter(Boolean).join("/"),
    ]);
  }
}
if (!scenarioRows.length) scenarioRows.push(["", "", "(시나리오 모드 아님)", "기존 룰 자동탐색 실행", "", "", "", 0, 0, "", "", "", "", ""]);
writeGuideSheet(
  scenarioSheet,
  "컴파일된 시나리오 실행계획",
  ["화면번호", "화면명", "시나리오 ID", "제목", "우선순위", "분류", "준비 상태", "케이스 수", "단계 수", "커버 컨트롤", "커버 MAP 규칙", "차단 사유", "생성 방식", "생성기/버전"],
  scenarioRows,
  [10, 24, 34, 34, 10, 18, 20, 12, 12, 45, 38, 55, 24, 38],
);
scenarioSheet.getRangeByIndexes(4, 0, scenarioRows.length, 1).format.numberFormat = "0000";

const bindingRows = [];
for (const screen of (bindingCatalog?.screens ?? [])) {
  for (const control of (screen.controls ?? [])) {
    const candidates = control.candidates ?? [];
    bindingRows.push([
      Number(screen.screenNumber ?? 0), screen.screenName ?? "", control.logicalName ?? "", bindingStatusLabel(control.status), confidenceLabel(control.confidence),
      control.required ? "예" : "아니요", control.executionEligible ? "예" : "아니요", candidates.length,
      candidates.map((candidate) => candidate.controlId ?? "").join(" | "),
      candidates.map((candidate) => candidate.className ?? "").join(" | "),
      candidates.map((candidate) => candidate.runtimeControlKind ?? "").join(" | "),
      candidates.map((candidate) => candidate.runtimeActionable ? "예" : "아니요").join(" | "),
      candidates.map((candidate) => candidate.mapMatchDistance ?? "").join(" | "),
      candidates.map((candidate) => Number(candidate.tabOrder ?? 0) + 1).join(" | "),
      candidates.map((candidate) => candidate.stateContext ?? "").join(" | "),
      candidates.flatMap((candidate) => candidate.evidence ?? []).join(" | "), control.reason ?? "",
    ]);
  }
}
if (!bindingRows.length) bindingRows.push(["", "", "(바인딩 결과 없음)", "PENDING", "", "", "", 0, "", "", "", "", "", "", "", "", "Binding Plan-only 결과가 첨부되지 않았습니다."]);
writeGuideSheet(
  bindingSheet,
  "시나리오 logicalName과 실제 HTS 컨트롤 결합 결과",
  ["화면번호", "화면명", "logicalName", "결합 상태", "신뢰도", "필수", "실행 가능", "후보 수", "컨트롤 ID", "클래스", "런타임 종류", "후보 실행 가능", "MAP 거리", "탭 순서", "상태 컨텍스트", "실행 근거", "판정 사유"],
  bindingRows,
  [10, 24, 28, 18, 12, 10, 12, 10, 42, 30, 20, 16, 14, 16, 34, 68, 58],
);
bindingSheet.getRangeByIndexes(4, 0, bindingRows.length, 1).format.numberFormat = "0000";

const unresolvedReviewIds = new Set((compiledPlan?.screens ?? []).flatMap((screen) =>
  (screen.scenarios ?? []).flatMap((scenario) => scenario.requiredReviewIds ?? [])));
const approvalRows = [];
if (compiledPlan) {
  const approvalIdentity = [compiledPlan.approvedBy, compiledPlan.approvedAt].filter(Boolean).join(" / ") || "승인자·승인시각 없음";
  approvalRows.push([
    "승인 요약", "", compiledPlan.planId ?? "", "논리 실행계획 승인 오버레이", "",
    approvalStatusLabel(compiledPlan.approvalStatus), approvalIdentity,
    `생성 ${compiledPlan.scenarioGenerationMode || "External"} / ${[compiledPlan.scenarioGenerator, compiledPlan.scenarioGeneratorVersion].filter(Boolean).join("/") || "외부 작성"}; 승인 SHA-256 ${compiledPlan.approvalSha256 || "없음"}; 검토 ${Number(compiledPlan.reviewDecisionCount ?? 0)}건; 수동 시나리오 ${Number(compiledPlan.scenarioDecisionCount ?? 0)}건; 커버리지 공백 ${Number(compiledPlan.coverageGapDecisionCount ?? 0)}건`,
  ]);
}
for (const item of (Array.isArray(scenarioReviewItems) ? scenarioReviewItems : [])) {
  approvalRows.push([
    "검토 항목", Number(item.screenNumber ?? 0), item.reviewId ?? "", item.subject ?? "", reviewSeverityLabel(item.severity),
    unresolvedReviewIds.has(item.reviewId) ? "미해결" : "해결 또는 비차단", item.question ?? "", item.reason ?? "",
  ]);
}
for (const screen of (compiledPlan?.screens ?? [])) {
  for (const gap of (screen.coverageGaps ?? [])) approvalRows.push(["커버리지 제외", Number(screen.screenNumber ?? 0), "", gap, "", "검토 필요", "", gap]);
}
for (const disposition of (physicalPlan?.scenarioDispositions ?? [])) {
  approvalRows.push([
    "실행 승인", Number(disposition.screenNumber ?? 0), disposition.scenarioId ?? "", disposition.scenarioId ?? "", "",
    physicalDispositionLabel(disposition.status), "", (disposition.reasons ?? []).join(" | "),
  ]);
}
if (!approvalRows.length) approvalRows.push(["안내", "", "", "시나리오 승인 자료 없음", "", "PENDING", "", "기존 룰 자동탐색 실행에는 적용되지 않습니다."]);
writeGuideSheet(
  approvalSheet,
  "시나리오 검토·승인·커버리지 제외 현황",
  ["구분", "화면번호", "참조 ID", "대상", "심각도", "상태", "확인 질문", "사유·근거"],
  approvalRows,
  [18, 10, 36, 45, 14, 22, 52, 62],
);
approvalSheet.getRangeByIndexes(4, 1, approvalRows.length, 1).format.numberFormat = "0000";

// 실행 결과의 핵심 요약 행을 만들고 오류 증거 파일을 상대 경로로 연결한다.
resultsSheet.getRangeByIndexes(0, 0, 1, resultHeaders.length).values = [resultHeaders];
header(resultsSheet.getRangeByIndexes(0, 0, 1, resultHeaders.length));
const resultEnd = Math.max(2, resultRows.length + 1);
if (resultRows.length) {
  resultsSheet.getRangeByIndexes(1, 2, resultRows.length, 1).format.numberFormat = "0000";
  resultsSheet.getRangeByIndexes(1, 0, resultRows.length, resultHeaders.length).values = resultRows;
  resultsSheet.getRangeByIndexes(1, 18, resultRows.length, 2).format.numberFormat = "#,##0";
  resultsSheet.getRangeByIndexes(1, 16, resultRows.length, 2).format.numberFormat = "yyyy-mm-dd hh:mm:ss";
  for (let index = 0; index < results.length; index += 1) {
    resultsSheet.getCell(index + 1, 10).format = { fill: statusFill(results[index].status), font: { bold: true } };
  }
}
resultsSheet.freezePanes.freezeRows(1);
resultsSheet.getRange(`A1:AE${resultEnd}`).format.wrapText = true;
resultsSheet.getRange(`A1:A${resultEnd}`).format.columnWidth = 28;
resultsSheet.getRange(`B1:B${resultEnd}`).format.columnWidth = 22;
resultsSheet.getRange(`C1:C${resultEnd}`).format.columnWidth = 10;
resultsSheet.getRange(`D1:D${resultEnd}`).format.columnWidth = 25;
resultsSheet.getRange(`E1:I${resultEnd}`).format.columnWidth = 18;
resultsSheet.getRange(`J1:J${resultEnd}`).format.columnWidth = 30;
resultsSheet.getRange(`K1:M${resultEnd}`).format.columnWidth = 15;
resultsSheet.getRange(`N1:P${resultEnd}`).format.columnWidth = 34;
resultsSheet.getRange(`Q1:R${resultEnd}`).format.columnWidth = 24;
resultsSheet.getRange(`S1:S${resultEnd}`).format.columnWidth = 14;
resultsSheet.getRange(`T1:T${resultEnd}`).format.columnWidth = 14;
resultsSheet.getRange(`U1:U${resultEnd}`).format.columnWidth = 34;
resultsSheet.getRange(`V1:V${resultEnd}`).format.columnWidth = 18;
resultsSheet.getRange(`W1:X${resultEnd}`).format.columnWidth = 16;
resultsSheet.getRange(`Y1:Z${resultEnd}`).format.columnWidth = 32;
resultsSheet.getRange(`AA1:AB${resultEnd}`).format.columnWidth = 14;
resultsSheet.getRange(`AC1:AD${resultEnd}`).format.columnWidth = 30;
resultsSheet.getRange(`AE1:AE${resultEnd}`).format.columnWidth = 14;

// 아래 세부 시트들은 한 케이스 안에서 수행된 액션과 관찰을 순서대로 펼친다.
const actionHeaders = ["케이스 ID", "화면번호", "계좌 ID", "순번", "동작", "대상", "상태", "출력", "오류 코드", "소요시간(ms)"];
actionsSheet.getRangeByIndexes(0, 0, 1, actionHeaders.length).values = [actionHeaders];
header(actionsSheet.getRangeByIndexes(0, 0, 1, actionHeaders.length));
const actionRows = [];
for (const result of results) {
  const actions = Array.isArray(result.actions) ? result.actions : [];
  actions.forEach((action, index) => actionRows.push([
    result.caseId ?? "", Number(result.screenNumber ?? 0), result.accountId ?? "", index + 1,
    actionLabel(action.action), action.target ?? "", statusLabel(action.status), action.output ?? "", action.errorCode ?? "",
    Number(action.elapsedMs ?? 0),
  ]));
}
if (actionRows.length) {
  actionsSheet.getRangeByIndexes(1, 1, actionRows.length, 1).format.numberFormat = "0000";
  actionsSheet.getRangeByIndexes(1, 0, actionRows.length, actionHeaders.length).values = actionRows;
  for (let index = 0; index < actionRows.length; index += 1) {
    actionsSheet.getCell(index + 1, 6).format = { fill: statusFill(actionRows[index][6]), font: { bold: true } };
  }
}
const actionEnd = Math.max(2, actionRows.length + 1);
actionsSheet.freezePanes.freezeRows(1);
actionsSheet.getRange(`A1:J${actionEnd}`).format.wrapText = true;
actionsSheet.getRange(`A1:A${actionEnd}`).format.columnWidth = 22;
actionsSheet.getRange(`B1:B${actionEnd}`).format.columnWidth = 10;
actionsSheet.getRange(`C1:C${actionEnd}`).format.columnWidth = 24;
actionsSheet.getRange(`D1:D${actionEnd}`).format.columnWidth = 12;
actionsSheet.getRange(`E1:G${actionEnd}`).format.columnWidth = 20;
actionsSheet.getRange(`H1:H${actionEnd}`).format.columnWidth = 42;
actionsSheet.getRange(`I1:I${actionEnd}`).format.columnWidth = 24;
actionsSheet.getRange(`J1:J${actionEnd}`).format.columnWidth = 14;

const variableHeaders = ["케이스 ID", "화면번호", "계좌 ID", "변수명", "값"];
variablesSheet.getRange("A1:E1").values = [variableHeaders];
header(variablesSheet.getRange("A1:E1"));
const variableRows = [];
for (const result of results) {
  const entries = Object.entries(result.inputVariables ?? {});
  if (!entries.length) variableRows.push([result.caseId ?? "", Number(result.screenNumber ?? 0), result.accountId ?? "", "(없음)", ""]);
  for (const [name, value] of entries) variableRows.push([result.caseId ?? "", Number(result.screenNumber ?? 0), result.accountId ?? "", name, String(value)]);
}
if (variableRows.length) {
  variablesSheet.getRangeByIndexes(1, 1, variableRows.length, 1).format.numberFormat = "0000";
  variablesSheet.getRangeByIndexes(1, 0, variableRows.length, variableHeaders.length).values = variableRows;
}
const variableEnd = Math.max(2, variableRows.length + 1);
variablesSheet.freezePanes.freezeRows(1);
variablesSheet.getRange(`A1:A${variableEnd}`).format.columnWidth = 21;
variablesSheet.getRange(`B1:B${variableEnd}`).format.columnWidth = 10;
variablesSheet.getRange(`C1:C${variableEnd}`).format.columnWidth = 24;
variablesSheet.getRange(`D1:E${variableEnd}`).format.columnWidth = 30;

const controlHeaders = [
  "케이스 ID", "화면번호", "컨트롤 ID", "탭 순서", "탭 정지", "탭 상태", "종류", "이름", "클래스", "위치 서명", "초기값",
  "데이터셋 지정", "추가 데이터 필요", "발견 선택지", "라벨 출처", "대기 사유", "정의 출처", "MAP 타입", "MAP 정의 순서",
  "실시간 결합", "결합 거리(px)", "런타임 분류", "MAP 이벤트", "MAP 설계 좌표",
  "MAP 의미 역할", "연결 RQ", "읽는 컨트롤", "영향 컨트롤", "결과 컨트롤", "호출 핸들러",
  "MAP 화면전환 대상", "공식 선택지 출처",
  "자동화 엔진", "AutomationId", "UIA RuntimeId", "UIA ControlType", "지원 UIA3 동작",
];
controlsSheet.getRangeByIndexes(0, 0, 1, controlHeaders.length).values = [controlHeaders];
header(controlsSheet.getRangeByIndexes(0, 0, 1, controlHeaders.length));
const controlRows = [];
for (const result of results) {
  for (const control of (Array.isArray(result.discoveredControls) ? result.discoveredControls : [])) {
    const options = Array.isArray(control.options) ? control.options : [];
    controlRows.push([
      result.caseId ?? "", Number(result.screenNumber ?? 0), control.controlId ?? "", Number(control.tabOrder ?? 0) + 1, control.tabStop ? "예" : "아니요", control.stateContext ?? "",
      control.controlKind ?? "", control.name ?? "", control.className ?? "", control.locatorSignature ?? "", control.initialValue ?? "",
      control.claimedByDataset ? "예" : "아니요", control.dataRequired ? "예" : "아니요",
      options.map((option, index) => cleanCollectedLabel(option.displayValue ?? option.value ?? option.id, control.controlKind, index)).join(" | "),
      [...new Set(options.map((option) => option.labelSource ?? "기존 결과: 미기록"))].join(" | "), control.pendingReason ?? "",
      control.definitionSource ?? "기존 결과: 미기록", control.mapTypeCode ?? "", Number(control.mapDefinitionOrder ?? -1) >= 0 ? Number(control.mapDefinitionOrder) + 1 : "",
      control.mapMatched ? "예" : "아니요", control.mapMatchDistance ?? "", control.runtimeControlKind ?? "",
      (Array.isArray(control.mapEvents) ? control.mapEvents : []).join(" | "), control.mapRect ? `${control.mapRect.x},${control.mapRect.y},${control.mapRect.width},${control.mapRect.height}` : "",
      control.mapSemanticRole ?? "", (Array.isArray(control.mapTriggeredRequests) ? control.mapTriggeredRequests : []).join(" | "),
      (Array.isArray(control.mapReadControls) ? control.mapReadControls : []).join(" | "), (Array.isArray(control.mapAffectedControls) ? control.mapAffectedControls : []).join(" | "),
      (Array.isArray(control.mapResultControls) ? control.mapResultControls : []).join(" | "), (Array.isArray(control.mapInvokedHandlers) ? control.mapInvokedHandlers : []).join(" | "),
      compactNavigationTargets(control.mapNavigationTargets), control.mapOptionSource ?? "",
      control.automationEngine ?? "Win32/MAP", control.automationId ?? "", control.uiaRuntimeId ?? "", control.uiaControlType ?? "",
      (Array.isArray(control.supportedActions) ? control.supportedActions : []).join(" | "),
    ]);
  }
}
if (controlRows.length) {
  controlsSheet.getRangeByIndexes(1, 1, controlRows.length, 1).format.numberFormat = "0000";
  controlsSheet.getRangeByIndexes(1, 0, controlRows.length, controlHeaders.length).values = controlRows;
}
const controlEnd = Math.max(2, controlRows.length + 1);
controlsSheet.freezePanes.freezeRows(1);
controlsSheet.getRange(`A1:AK${controlEnd}`).format.wrapText = true;
controlsSheet.getRange(`A1:A${controlEnd}`).format.columnWidth = 22;
controlsSheet.getRange(`B1:B${controlEnd}`).format.columnWidth = 10;
controlsSheet.getRange(`C1:C${controlEnd}`).format.columnWidth = 18;
controlsSheet.getRange(`D1:G${controlEnd}`).format.columnWidth = 12;
controlsSheet.getRange(`H1:J${controlEnd}`).format.columnWidth = 26;
controlsSheet.getRange(`K1:M${controlEnd}`).format.columnWidth = 16;
controlsSheet.getRange(`N1:P${controlEnd}`).format.columnWidth = 34;
controlsSheet.getRange(`Q1:V${controlEnd}`).format.columnWidth = 18;
controlsSheet.getRange(`W1:X${controlEnd}`).format.columnWidth = 34;
controlsSheet.getRange(`Y1:AD${controlEnd}`).format.columnWidth = 28;
controlsSheet.getRange(`AE1:AF${controlEnd}`).format.columnWidth = 34;
controlsSheet.getRange(`AG1:AK${controlEnd}`).format.columnWidth = 28;

const controlTestHeaders = ["케이스 ID", "화면번호", "계획 항목 ID", "컨트롤 ID", "종류", "컨트롤명", "선택지 ID", "입력값", "표시값", "상태", "조회 실행", "제품 결함 감지", "출력", "오류 코드", "스크린샷", "소요시간(ms)", "기대 결과", "기대 일치", "기대 출처", "신뢰도", "기대 근거", "시나리오 ID", "시나리오 제목", "시나리오 단계 ID", "시나리오 순번", "시나리오 동작", "자동화 엔진"];
controlTestsSheet.getRangeByIndexes(0, 0, 1, controlTestHeaders.length).values = [controlTestHeaders];
header(controlTestsSheet.getRangeByIndexes(0, 0, 1, controlTestHeaders.length));
const controlTestRows = [];
const controlTestStatuses = [];
for (const result of results) {
  for (const item of (Array.isArray(result.controlTests) ? result.controlTests : [])) {
    controlTestStatuses.push(item.status ?? "PENDING");
    controlTestRows.push([
      result.caseId ?? "", Number(result.screenNumber ?? 0), item.planItemId ?? "", item.controlId ?? "", item.controlKind ?? "", item.controlName ?? "",
      item.optionId ?? "", item.inputValue ?? "", cleanCollectedLabel(item.displayValue, item.controlKind), statusLabel(item.status), item.queryTriggered ? "예" : "아니요",
      item.errorDetected ? "예" : "아니요", cleanExecutionDetail(item.output, `${item.controlKind ?? "컨트롤"} '${cleanCollectedLabel(item.displayValue, item.controlKind)}' 동작 결과`), item.errorCode ?? "", item.screenshotPath ?? "", Number(item.elapsedMs ?? 0),
      item.expectedOutcomeType ?? "Unspecified", item.expectationSatisfied ? "예" : "아니요",
      item.expectedOutcomeSource ?? "Unspecified", item.expectedOutcomeConfidence ?? "Unspecified", (item.expectedOutcomeEvidence ?? []).join(" | "),
      item.scenarioId ?? result.scenarioId ?? "", item.scenarioTitle ?? result.scenarioTitle ?? "", item.scenarioStepId ?? "",
      Number(item.scenarioSequence ?? 0), item.scenarioAction ?? "", item.automationEngine ?? "기존 결과: 미기록",
    ]);
  }
}
if (controlTestRows.length) {
  controlTestsSheet.getRangeByIndexes(1, 1, controlTestRows.length, 1).format.numberFormat = "0000";
  controlTestsSheet.getRangeByIndexes(1, 0, controlTestRows.length, controlTestHeaders.length).values = controlTestRows;
  controlTestsSheet.getRangeByIndexes(1, 15, controlTestRows.length, 1).format.numberFormat = "#,##0";
  controlTestStatuses.forEach((status, index) => { controlTestsSheet.getCell(index + 1, 9).format = { fill: statusFill(status), font: { bold: true } }; });
}
const controlTestEnd = Math.max(2, controlTestRows.length + 1);
controlTestsSheet.freezePanes.freezeRows(1);
controlTestsSheet.getRange(`A1:AA${controlTestEnd}`).format.wrapText = true;
controlTestsSheet.getRange(`A1:F${controlTestEnd}`).format.columnWidth = 20;
controlTestsSheet.getRange(`G1:L${controlTestEnd}`).format.columnWidth = 15;
controlTestsSheet.getRange(`M1:M${controlTestEnd}`).format.columnWidth = 42;
controlTestsSheet.getRange(`N1:O${controlTestEnd}`).format.columnWidth = 25;
controlTestsSheet.getRange(`P1:P${controlTestEnd}`).format.columnWidth = 14;
controlTestsSheet.getRange(`Q1:R${controlTestEnd}`).format.columnWidth = 18;
controlTestsSheet.getRange(`S1:T${controlTestEnd}`).format.columnWidth = 20;
controlTestsSheet.getRange(`U1:U${controlTestEnd}`).format.columnWidth = 52;
controlTestsSheet.getRange(`V1:X${controlTestEnd}`).format.columnWidth = 30;
controlTestsSheet.getRange(`Y1:Z${controlTestEnd}`).format.columnWidth = 16;
controlTestsSheet.getRange(`AA1:AA${controlTestEnd}`).format.columnWidth = 22;

const popupHeaders = ["케이스 ID", "화면번호", "팝업 ID", "분류", "예상 여부", "제목", "본문", "버튼", "요약", "판정 출처", "MAP 규칙 ID", "MAP 핸들러", "MAP 원문", "스크린샷", "감지 시각", "HTS 오류코드", "HTS 오류 분류"];
popupsSheet.getRangeByIndexes(0, 0, 1, popupHeaders.length).values = [popupHeaders];
header(popupsSheet.getRangeByIndexes(0, 0, 1, popupHeaders.length));
const popupRows = [];
for (const result of results) {
  for (const popup of (Array.isArray(result.popupObservations) ? result.popupObservations : [])) {
    popupRows.push([
      result.caseId ?? "", Number(result.screenNumber ?? 0), popup.popupId ?? "", popup.classification ?? "", popup.expected ? "예" : "아니요",
      popup.title ?? "", (popup.messageLines ?? []).join(" | "), (popup.buttons ?? []).join(" | "), popup.summary ?? "",
      popup.oracleSource ?? "공통 규칙", popup.oracleRuleId ?? "", popup.mapHandler ?? "", popup.mapMessage ?? "", popup.screenshotPath ?? "", excelDate(popup.detectedAt),
      popup.installedErrorCode ?? "", popup.installedErrorClass ?? "",
    ]);
  }
}
if (popupRows.length) {
  popupsSheet.getRangeByIndexes(1, 1, popupRows.length, 1).format.numberFormat = "0000";
  popupsSheet.getRangeByIndexes(1, 0, popupRows.length, popupHeaders.length).values = popupRows;
  popupsSheet.getRangeByIndexes(1, 14, popupRows.length, 1).format.numberFormat = "yyyy-mm-dd hh:mm:ss";
}
const popupEnd = Math.max(2, popupRows.length + 1);
popupsSheet.freezePanes.freezeRows(1);
popupsSheet.getRange(`A1:Q${popupEnd}`).format.wrapText = true;
popupsSheet.getRange(`A1:F${popupEnd}`).format.columnWidth = 19;
popupsSheet.getRange(`G1:I${popupEnd}`).format.columnWidth = 38;
popupsSheet.getRange(`J1:M${popupEnd}`).format.columnWidth = 24;
popupsSheet.getRange(`N1:O${popupEnd}`).format.columnWidth = 26;
popupsSheet.getRange(`P1:Q${popupEnd}`).format.columnWidth = 20;

const oracleEventHeaders = ["케이스 ID", "화면번호", "단계", "컨트롤 ID", "선택지 ID", "이벤트 유형", "판정", "기대 결과", "기대 출처", "신뢰도", "기대 근거", "기대 ID", "관찰 근거", "근거 코드", "관찰 메시지", "제품 결함", "판정 보류", "감지 시각"];
oracleEventsSheet.getRange("A1:R1").values = [oracleEventHeaders];
header(oracleEventsSheet.getRange("A1:R1"));
const oracleEventRows = [];
for (const result of results) {
  for (const event of (Array.isArray(result.oracleEvents) ? result.oracleEvents : [])) {
    oracleEventRows.push([
      result.caseId ?? "", Number(result.screenNumber ?? 0), event.stage ?? "", event.controlId ?? "", event.optionId ?? "",
      event.eventType ?? "", event.disposition ?? "", event.expectedOutcomeType ?? "Unspecified",
      event.expectedOutcomeSource ?? "Unspecified", event.expectedOutcomeConfidence ?? "Unspecified", (event.expectedOutcomeEvidence ?? []).join(" | "), event.expectationId ?? "",
      event.source ?? "", event.sourceCode ?? "", event.message ?? "", event.productDefect ? "예" : "아니요",
      event.requiresReview ? "예" : "아니요", excelDate(event.detectedAt),
    ]);
  }
}
if (oracleEventRows.length) {
  oracleEventsSheet.getRangeByIndexes(1, 1, oracleEventRows.length, 1).format.numberFormat = "0000";
  oracleEventsSheet.getRangeByIndexes(1, 0, oracleEventRows.length, oracleEventHeaders.length).values = oracleEventRows;
  oracleEventsSheet.getRangeByIndexes(1, 17, oracleEventRows.length, 1).format.numberFormat = "yyyy-mm-dd hh:mm:ss";
  oracleEventRows.forEach((row, index) => {
    oracleEventsSheet.getCell(index + 1, 6).format.fill = row[15] === "예" ? colors.fail : row[16] === "예" ? colors.pending : colors.pass;
  });
} else {
  oracleEventsSheet.getRange("A2:R2").merge();
  oracleEventsSheet.getRange("A2").values = [["관찰된 판정 이벤트가 없습니다."]];
  oracleEventsSheet.getRange("A2:R2").format = { fill: colors.pass, font: { bold: true, color: colors.text }, horizontalAlignment: "center" };
}
const oracleEventEnd = Math.max(2, oracleEventRows.length + 1);
oracleEventsSheet.freezePanes.freezeRows(1);
oracleEventsSheet.getRange(`A1:R${oracleEventEnd}`).format.wrapText = true;
oracleEventsSheet.getRange(`A1:B${oracleEventEnd}`).format.columnWidth = 20;
oracleEventsSheet.getRange(`C1:J${oracleEventEnd}`).format.columnWidth = 19;
oracleEventsSheet.getRange(`K1:K${oracleEventEnd}`).format.columnWidth = 52;
oracleEventsSheet.getRange(`L1:N${oracleEventEnd}`).format.columnWidth = 20;
oracleEventsSheet.getRange(`O1:O${oracleEventEnd}`).format.columnWidth = 48;
oracleEventsSheet.getRange(`P1:R${oracleEventEnd}`).format.columnWidth = 18;

const incompleteHeaders = ["케이스 ID", "화면번호", "컨트롤 종류", "컨트롤명", "선택지/입력값", "오류 코드", "정리된 사유", "상세 내용"];
incompleteSheet.getRange("A1:H1").values = [incompleteHeaders];
header(incompleteSheet.getRange("A1:H1"));
const incompleteValues = incompleteRows.map((row) => [
  row.caseId, Number(row.screenNumber ?? 0), row.controlKind, row.controlName, row.option, row.errorCode, row.reason, row.detail,
]);
if (incompleteValues.length) {
  incompleteSheet.getRangeByIndexes(1, 1, incompleteValues.length, 1).format.numberFormat = "0000";
  incompleteSheet.getRangeByIndexes(1, 0, incompleteValues.length, incompleteHeaders.length).values = incompleteValues;
} else {
  incompleteSheet.getRange("A2:H2").merge();
  incompleteSheet.getRange("A2").values = [["자동화 미완료 항목이 없습니다."]];
  incompleteSheet.getRange("A2:H2").format = { fill: colors.pass, font: { bold: true, color: colors.text }, horizontalAlignment: "center" };
}
const incompleteEnd = Math.max(2, incompleteValues.length + 1);
incompleteSheet.freezePanes.freezeRows(1);
incompleteSheet.getRange(`A1:H${incompleteEnd}`).format.wrapText = true;
incompleteSheet.getRange(`A1:A${incompleteEnd}`).format.columnWidth = 22;
incompleteSheet.getRange(`B1:G${incompleteEnd}`).format.columnWidth = 18;
incompleteSheet.getRange(`H1:H${incompleteEnd}`).format.columnWidth = 46;

const errorResults = results.filter((result) => result.errorDetected || ["FAIL", "ERROR"].includes(result.status));
errorShotsSheet.mergeCells("A1:L1");
errorShotsSheet.getRange("A1").values = [["제품 결함·실행 오류 감지 화면"]];
header(errorShotsSheet.getRange("A1:L1"));
errorShotsSheet.getRange("A1:L1").format.font.size = 16;
errorShotsSheet.getRange("A1:L1").format.rowHeight = 28;
errorShotsSheet.getRange("A1:A10000").format.columnWidth = 18;
errorShotsSheet.getRange("B1:C10000").format.columnWidth = 28;
errorShotsSheet.getRange("D1:L10000").format.columnWidth = 12;

let embeddedErrorImages = 0;
if (!errorResults.length) {
  errorShotsSheet.mergeCells("A3:L5");
  errorShotsSheet.getRange("A3").values = [["제품 결함 또는 실행 오류가 감지된 케이스가 없습니다."]];
  errorShotsSheet.getRange("A3:L5").format = { fill: colors.pass, font: { bold: true, color: colors.text }, verticalAlignment: "center", horizontalAlignment: "center" };
} else {
  for (let index = 0; index < errorResults.length; index += 1) {
    const result = errorResults[index];
    const startRow = 2 + (index * 24);
    const labels = [["케이스 ID"], ["화면"], ["상태"], ["오류 코드"], ["오류 메시지"], ["스크린샷 경로"]];
    const values = [[result.caseId ?? ""], [`${result.screenNumber ?? ""} ${result.screenName ?? ""}`], [statusLabel(result.status)], [result.errorCode ?? ""], [result.errorMessage ?? ""], [result.screenshotPath ?? ""]];
    errorShotsSheet.getRangeByIndexes(startRow, 0, labels.length, 1).values = labels;
    errorShotsSheet.getRangeByIndexes(startRow, 1, values.length, 1).values = values;
    errorShotsSheet.getRangeByIndexes(startRow, 0, labels.length, 1).format = { fill: colors.cyan, font: { bold: true, color: colors.text } };
    errorShotsSheet.getRangeByIndexes(startRow, 0, labels.length, 3).format.wrapText = true;
    errorShotsSheet.getRangeByIndexes(startRow, 0, 22, 12).format.rowHeight = 20;

    let imageAdded = false;
    const evidence = await outputManager.readEvidence(result.screenshotPath);
    if (evidence) {
      errorShotsSheet.images.add({
        dataUrl: `data:${evidence.mimeType};base64,${evidence.bytes.toString("base64")}`,
        anchor: { from: { row: startRow, col: 3 }, extent: { widthPx: 600, heightPx: 450 } },
      });
      imageAdded = true;
      embeddedErrorImages += 1;
    }
    if (!imageAdded) {
      errorShotsSheet.getCell(startRow + 7, 3).values = [["오류 스크린샷 이미지 없음"]];
      errorShotsSheet.getRangeByIndexes(startRow + 7, 3, 5, 9).format = { fill: colors.pending, font: { bold: true, color: colors.text }, verticalAlignment: "center", horizontalAlignment: "center" };
    }
  }
}
errorShotsSheet.freezePanes.freezeRows(1);
summarySheet.getRange("G12").values = [[embeddedErrorImages]];

summarySheet.getRange("A17:E17").values = [["MAP 이벤트", "MAP 조회", "MAP 상태제어", "MAP 결과", "동적 재결합"]];
header(summarySheet.getRange("A17:E17"));
summarySheet.getRange("A18:E18").values = [[
  Number(summary.mapBehaviorHandlers ?? 0), Number(summary.mapQueryControls ?? 0), Number(summary.mapStateControllers ?? 0),
  Number(summary.mapResultControls ?? 0), Number(summary.mapReboundControls ?? 0),
]];
summarySheet.getRange("A18:E18").format = { font: { bold: true, size: 14 }, horizontalAlignment: "center", fill: "#F8FAFC" };
summarySheet.mergeCells("F17:H18");
summarySheet.getRange("F17").values = [["문서화 시트: 컬럼설명 / 오류판정기준 / 테스트모듈로직 / 입력데이터안내 / 설치카탈로그 / 판정이벤트"]];
summarySheet.getRange("F17:H18").format = {
  fill: colors.cyan, font: { bold: true, color: colors.text }, verticalAlignment: "center",
  horizontalAlignment: "left", wrapText: true, borders: { preset: "outside", style: "thin", color: colors.line },
};

const requestedScreens = new Set((mapCatalog.requestedScreens ?? []).map(String));
const topScreens = (Array.isArray(mapCatalog.screens) ? mapCatalog.screens : [])
  .filter((screen) => !requestedScreens.size || requestedScreens.has(String(screen.screenNumber)));
const topScreenCodes = new Set(topScreens.map((screen) => String(screen.screenCode ?? "")));
const installationCatalogRows = [
  ["요약", "설치 루트", mapCatalog.installationRoot ?? "미지정", "dataset.targetProfile.map.installationRoot", mapCatalog.installationRoot ? "적용" : "미적용", "MAP·메뉴·탭·오류코드·마스터·로그 기준 파일의 루트"],
  ["요약", "설치 지문", mapCatalog.installationFingerprint ?? "없음", "화면/마스터 배포 파일 해시", mapCatalog.installationFingerprint ? "생성" : "미생성", "동일 HTS 설치 버전에서 생성한 결과인지 비교"],
  ["요약", "대상/의존 화면", `${topScreens.length} / ${(mapCatalog.dependencyScreens ?? []).length}`, "map-screen-models.json", "수집", `직접 대상 화면과 참조 화면 수; 정적 연결 누락 ${(mapCatalog.dependencies ?? []).filter((item) => !item.isDynamic && !item.targetExists).length}개`],
  ["요약", "오류코드/컨트롤타입", `${(mapCatalog.errorCodes ?? []).length} / ${(mapCatalog.controlTypes ?? []).length}`, "data/errcode.txt + system/*.ini", "수집", "팝업·로그 오류 판정과 MAP 타입 해석에 사용"],
  ["요약", "무결성 일치/불일치", `${(mapCatalog.integrityEntries ?? []).filter((item) => item.status === "MATCH").length} / ${(mapCatalog.integrityEntries ?? []).filter((item) => item.status !== "MATCH").length}`, "screen_hts.vst + mst.vst", (mapCatalog.integrityEntries ?? []).some((item) => item.status !== "MATCH") ? "확인 필요" : "정상", "배포 목록의 MD5·크기와 실제 파일을 대조"],
];

for (const screen of topScreens) {
  const references = Array.isArray(screen.dataReferences) ? screen.dataReferences : [];
  const officialOptions = (screen.controls ?? []).filter((control) => (control.staticOptions ?? []).length > 0);
  installationCatalogRows.push([
    "화면", String(screen.screenNumber ?? ""), screen.registry?.title || screen.screenName || "제목 없음", screen.sourceFile ?? "",
    screen.integrity?.status ?? "미확인",
    `활성 컨트롤 ${Number(screen.actionableControlCount ?? 0)}개; 탭 형제 ${(screen.tabSiblings ?? []).join(", ") || "없음"}; 연결 ${(screen.dependencies ?? []).length}개; 데이터 사전 ${references.length}개; 공식 선택지 컨트롤 ${officialOptions.length}개`,
  ]);
  for (const reference of references) {
    const optionText = (reference.options ?? []).slice(0, 12).map((option) => {
      if (typeof option === "string") return option;
      const outcome = option.expectedOutcome ?? {};
      const contract = outcome.type && outcome.type !== "Unspecified" ? ` [${outcome.type}/${outcome.confidence || "Unspecified"}]` : "";
      return `${option.value}:${option.displayValue}${contract}`;
    }).join(" | ");
    installationCatalogRows.push([
      "화면 데이터", `${screen.screenNumber}/${reference.section || "기본"}`, reference.usage ?? "참조", reference.sourceFile ?? "",
      reference.boundControl ? "컨트롤 결합 / 자동 기대" : "판정 사전",
      `${reference.boundControl ? `대상 ${reference.boundControl}; 설치 입력 사전 값은 Success/InstallationInputOption/High; ` : ""}${optionText}${(reference.options ?? []).length > 12 ? ` 외 ${(reference.options ?? []).length - 12}개` : ""}`,
    ]);
  }
}

for (const dependency of (mapCatalog.dependencies ?? []).filter((item) => topScreenCodes.has(String(item.sourceScreenCode ?? "")))) {
  installationCatalogRows.push([
    "화면 연결", dependency.ruleId ?? "", `${dependency.sourceScreenCode ?? ""}/${dependency.sourceControl || dependency.handler || "화면"} -> ${dependency.targetScreenCode || dependency.targetExpression || "동적 대상"}`,
    dependency.api ?? dependency.kind ?? "", dependency.isDynamic ? "동적" : (dependency.targetExists ? "존재" : "누락"),
    "MAP 이벤트 조작 뒤 새 창·연계 화면의 기대 대상 판정에 사용",
  ]);
}

for (const group of (mapCatalog.tabGroups ?? []).filter((item) => (item.screenNumbers ?? []).some((screen) => requestedScreens.has(String(screen))))) {
  installationCatalogRows.push(["탭 그룹", group.groupId ?? "", (group.screenNumbers ?? []).join(", "), group.sourceFile ?? "", "등록", "같은 탭 묶음의 화면 전환·형제 화면 관찰에 사용"]);
}

for (const type of (mapCatalog.controlTypes ?? [])) {
  installationCatalogRows.push(["컨트롤 타입", type.typeCode ?? "", `${type.name ?? ""} -> ${type.kind ?? ""}`, type.source ?? "", type.runtimeDll ?? "", `접두어 ${type.prefix || "없음"}; 기본 크기 ${type.defaultWidth ?? 0}x${type.defaultHeight ?? 0}`]);
}

for (const errorCode of (mapCatalog.errorCodes ?? [])) {
  installationCatalogRows.push(["오류코드", errorCode.code ?? "", errorCode.message ?? "", errorCode.sourceFile ?? "", `${errorCode.classification ?? ""}${errorCode.isFailure ? " / 실패" : " / 비실패"}`, "팝업·신규 로그의 코드/문구 일치 시 설치 공식 오라클로 기록"]);
}

for (const integrity of (mapCatalog.integrityEntries ?? [])) {
  installationCatalogRows.push(["무결성", integrity.relativePath ?? "", `크기 ${integrity.actualSize ?? 0}/${integrity.expectedSize ?? 0}`, integrity.manifestFile ?? "", integrity.status ?? "", `MD5 ${integrity.actualMd5 || "없음"} / 기대 ${integrity.expectedMd5 || "없음"}`]);
}

for (const master of (mapCatalog.masterDataSources ?? [])) {
  installationCatalogRows.push(["마스터", master.id ?? "", `${master.purpose ?? ""}; 레코드 ${Number(master.recordCount ?? 0).toLocaleString("ko-KR")}개`, master.relativePath ?? "", `${master.integrity?.status ?? ""} / 자동 기대`, `검증된 표본은 Success/InstallationMaster/High; ${(master.samples ?? []).map((sample) => `${sample.code}:${sample.name}`).join(" | ")}`]);
}

for (const log of (mapCatalog.logSources ?? [])) {
  installationCatalogRows.push(["로그", log.id ?? "", log.purpose ?? "", log.pathPattern ?? "", log.mode ?? "", `${log.sensitive ? "민감정보 원문 미수집" : "증분 텍스트 검사"}; 변경 시 실패=${log.failureOnChange ? "예" : "아니요"}`]);
}

for (const warning of (mapCatalog.warnings ?? [])) {
  installationCatalogRows.push(["경고", "카탈로그", String(warning), "map-screen-models.json", "확인 필요", "설치 모델 추출 범위와 파일 상태를 확인"]);
}

writeGuideSheet(installationSheet, `${targetDisplayName} 설치 파일 기준 카탈로그`, ["구분", "식별자", "대상·값", "원본 파일·API", "상태·분류", "테스트 활용 방법"], installationCatalogRows, [18, 34, 55, 50, 20, 62]);

// 실제 보고서의 모든 컬럼을 사용자가 해석할 수 있도록 출처와 판정 의미를 함께 명시한다.
const columnGuideRows = [
  ["요약", "A4:B11", "실행 ID", "한 번의 테스트 묶음을 식별하는 고유 ID", "동일 실행의 모든 케이스가 같은 값을 사용", "summary.runId"],
  ["요약", "A4:B11", "데이터셋", "사용한 룰 테스트 데이터셋 ID", "입력 파일과 실행 결과의 추적 키", "summary.datasetId"],
  ["요약", "A4:B11", "종합 상태", "Core ResultEvaluator가 전체 TestResult를 집계한 최종 상태", "리포터는 overallResult.status를 재판정 없이 표시", "summary.status / test-results.json"],
  ["요약", "A4:B11", "실행 구분", "계획 전용 또는 실제 HTS 실행 여부", "실제 조작은 실제 HTS로 표시", "summary.executionMode / dryRun"],
  ["요약", "A4:B11", "입력 방식", "화면 기본값 사용 또는 데이터셋 명시 입력 방식", "Prefilled/Explicit를 한국어로 표시", "summary.inputMode"],
  ["요약", "A4:B11", "계획 방식", "LLM 없이 결정론적 룰로 계획했음을 표시", "현재 값: 결정론적 규칙", "summary.planner"],
  ["요약", "A4:B11", "완료 시각", "전체 실행 종료 시각", "KST 날짜·시간", "summary.finishedAt"],
  ["요약", "A4:B11", "원본 결과 파일", "엑셀 생성의 근거가 된 JSON", "case-results.json", "고정 표시"],
  ["요약", "A12:B12", "자동화 엔진", "실제 탐색·조작 엔진과 호출/성공/fallback 수", "FlaUI.UIA3와 버전 및 실행 계수", "summary.automationEngine / flaUi*"],
  ["요약", "D4:H5", "전체/통과/실패/오류/대기", "테스트결과 시트의 상태별 케이스 수", "수식으로 자동 집계", "COUNTA / COUNTIF"],
  ["요약", "D7:H9", "판정 기준", "관찰 이벤트와 입력값별 기대 결과 계약을 비교하는 현재 오라클 범위", "기대 검증·제품 결함·판정 보류를 분리", "실행 설정과 판정 정책"],
  ["요약", "D11:H12", "발견 컨트롤/선택지 테스트/팝업 관찰/결함·실행 오류 이미지", "세부 결과의 총량", "각 상세 시트 행 수 및 포함 이미지 수", "COUNTA / embeddedErrorImages"],
  ["요약", "A14:C15", "MAP 오류 화면/판정 문구/팝업 일치", "화면별 MAP 오류 오라클의 적용 범위와 실제 런타임 일치 건수", "드라이런의 팝업 일치는 0", "summary.mapOracleScreens / mapOracleMessages / mapOracleMatchedPopups"],
  ["요약", "D14:H15", "MAP 모델/정의/실시간 결합/미결합/런타임 추가", "정적 MAP 기준과 현재 실행 상태 결합 규모", "실행하지 않은 결합은 0", "summary.mapModels / mapDefinedControls / mapBoundControls / mapUnboundControls / runtimeOnlyControls"],
  ["요약", "A17:E18", "MAP 이벤트/조회/상태제어/결과/동적 재결합", "MAP 스크립트에서 추출한 동작 그래프와 실행 중 새로 결합된 컨트롤 규모", "동적 재결합은 토글·탭 변경 뒤 MAP 미결합 컨트롤이 런타임 컨트롤로 승격된 횟수", "summary.mapBehaviorHandlers / mapQueryControls / mapStateControllers / mapResultControls / mapReboundControls"],
  ["컨트롤계획", "AG:AK", "자동화 엔진/UIA 식별자/지원 동작", "FlaUI UIA3가 탐색한 요소의 재식별 정보와 패턴 능력", "RuntimeId 우선, HWND·AutomationId·좌표 보완", "control.automationEngine / automationId / uiaRuntimeId / uiaControlType / supportedActions"],
  ["선택지테스트", "AA", "자동화 엔진", "해당 선택지 조작에 실제 사용된 엔진", "FlaUI.UIA3 또는 Win32 fallback, 계획 전용은 미실행", "item.automationEngine"],
  ["테스트결과", "A", "실행 ID", "실행 묶음 식별자", "요약 시트의 실행 ID와 동일", "result.runId"],
  ["테스트결과", "B", "케이스 ID", "화면·계좌·조건 조합별 고유 키", "세부 시트를 연결하는 기본 키", "result.caseId"],
  ["테스트결과", "C", "화면 ID", "대상 프로그램의 화면 식별자", "targetProfile.screenIdPattern과 데이터셋 screens[]로 검증", "result.screenNumber"],
  ["테스트결과", "D", "화면명", "대상 화면의 업무 명칭", "데이터셋 정의 또는 수집된 제목", "result.screenName"],
  ["테스트결과", "E", "입력 방식", "기본값 사용/명시 입력", "화면 기본값 또는 데이터셋 명시 입력", "result.inputMode"],
  ["테스트결과", "F", "실행 컨텍스트 ID", "계좌 또는 일반 화면 실행 조건의 별칭", "accounts[]가 없으면 default", "result.accountId"],
  ["테스트결과", "G", "식별값(마스킹)", "계좌 사용 시 일부를 가린 식별값", "계좌가 없는 화면군은 빈 값", "result.maskedAccountNumber"],
  ["테스트결과", "H", "계좌 지문", "계좌를 비교하기 위한 비가역 식별값", "원본 계좌번호 대신 추적에 사용", "result.accountFingerprint"],
  ["테스트결과", "I", "예금주", "테스트 계좌 소유자 표시명", "데이터셋의 owner", "result.owner"],
  ["테스트결과", "J", "입력 변수", "해당 케이스에 적용된 조건 요약", "변수명=값 목록", "result.variables"],
  ["테스트결과", "K", "상태", "케이스 최종 결과", "통과/실패/오류/대기", "result.status"],
  ["테스트결과", "L", "제품 결함 여부", "입력 의도와 무관한 시스템 실패 또는 기대 결과 위반이 탐지됐는지 표시", "예/아니오", "result.productDefectDetected / errorDetected"],
  ["테스트결과", "M", "오류 코드", "오류 유형의 기계 판독 코드", "예: EXPLICIT_ERROR_DETECTED", "result.errorCode"],
  ["테스트결과", "N", "오류 메시지", "탐지한 오류의 요약", "팝업·창 텍스트·로그·예외의 정리된 설명", "result.errorMessage"],
  ["테스트결과", "O", "출력 요약", "화면 조작과 조회 결과를 요약한 텍스트", "업무 값 정합성 보증이 아니라 실행 관찰 요약", "result.outputSummary"],
  ["테스트결과", "P", "스크린샷", "오류 시 저장된 화면 이미지 경로", "오류가 없으면 비어 있을 수 있음", "result.screenshotPath"],
  ["테스트결과", "Q", "시작 시각", "케이스 실행 시작 시각", "KST 날짜·시간", "result.startedAt"],
  ["테스트결과", "R", "종료 시각", "케이스 실행 종료 시각", "KST 날짜·시간", "result.finishedAt"],
  ["테스트결과", "S", "소요시간(ms)", "케이스 전체 경과 시간", "종료-시작 밀리초", "result.durationMs"],
  ["테스트결과", "T", "미완료 건수", "자동화가 끝내지 못한 항목 수", "0이면 자동화미완료 세부 없음", "incompleteByCase 집계"],
  ["테스트결과", "U", "미완료 요약", "미완료 사유별 건수 요약", "같은 오류 코드를 묶어 표시", "incompleteSummary(caseId)"],
  ["테스트결과", "V", "상세 시트", "세부 증적이 있는 시트 안내", "단계·컨트롤·선택지·팝업 시트를 참조", "고정 안내"],
  ["테스트결과", "W", "기대 반응 건수", "입력값에 정의한 검증·자료 없음·경고와 일치한 이벤트 수", "제품 결함이 아니라 테스트 오라클 충족", "result.oracleEvents[disposition=Expected]"],
  ["테스트결과", "X", "판정 보류 건수", "관찰 신호는 있지만 기대 결과가 없어 정상·결함을 단정하지 않은 수", "1건 이상이면 케이스 PENDING", "result.oracleEvents[requiresReview=true]"],
  ["단계결과", "A", "케이스 ID", "단계가 속한 테스트 케이스", "테스트결과의 케이스 ID와 연결", "action.caseId"],
  ["단계결과", "B", "화면번호", "단계가 실행된 HTS 화면", "4자리 화면번호", "action.screenNumber"],
  ["단계결과", "C", "계좌 ID", "단계에 적용된 계좌 별칭", "민감정보 대신 별칭 사용", "action.accountId"],
  ["단계결과", "D", "순번", "케이스 내부의 실행 순서", "1부터 증가", "action.sequence"],
  ["단계결과", "E", "동작", "열기·발견·입력·조회·판정·닫기 등의 작업", "원본 action을 한국어로 변환", "action.action"],
  ["단계결과", "F", "대상", "동작 대상 화면 또는 컨트롤", "이름/ID/역할", "action.target"],
  ["단계결과", "G", "상태", "해당 단계의 성공·실패·대기", "통과/실패/오류/대기", "action.status"],
  ["단계결과", "H", "출력", "단계 수행 결과의 설명", "인코딩 손상 문구는 정리된 대체 문구 사용", "action.output"],
  ["단계결과", "I", "오류 코드", "단계 실패 또는 미완료 코드", "없으면 빈값", "action.errorCode"],
  ["단계결과", "J", "소요시간(ms)", "단계별 경과 시간", "밀리초", "action.durationMs"],
  ["입력변수", "A", "케이스 ID", "변수가 적용된 케이스", "세부 시트 연결 키", "variable.caseId"],
  ["입력변수", "B", "화면번호", "변수가 적용된 화면", "4자리 화면번호", "variable.screenNumber"],
  ["입력변수", "C", "계좌 ID", "변수가 적용된 계좌 별칭", "accounts[].id", "variable.accountId"],
  ["입력변수", "D", "변수명", "데이터셋에서 정의한 조건 이름", "예: 기준일자, 거래구분", "variable.name"],
  ["입력변수", "E", "값", "해당 케이스에 실제 적용한 값", "민감 변수는 마스킹", "variable.value"],
  ["컨트롤계획", "A", "케이스 ID", "발견 컨트롤이 속한 케이스", "세부 시트 연결 키", "control.caseId"],
  ["컨트롤계획", "B", "화면번호", "컨트롤이 있는 화면", "4자리 화면번호", "control.screenNumber"],
  ["컨트롤계획", "C", "컨트롤 ID", "실행 중 재식별에 사용하는 안정화 ID", "종류·위치·순번 기반", "control.controlId"],
  ["컨트롤계획", "D", "탭 순서", "Tab 키로 관찰한 포커스 순서", "1부터 순회, 미관찰 시 빈값", "control.tabOrder"],
  ["컨트롤계획", "E", "탭 정지", "해당 컨트롤에서 포커스가 실제 멈췄는지", "예/아니오", "control.tabStop"],
  ["컨트롤계획", "F", "탭 상태", "탭 순회·중복·미도달 등 관찰 결과", "탭오더 품질 확인", "control.tabStatus"],
  ["컨트롤계획", "G", "종류", "Text/Date/Combo/Radio/CheckBox/Tab/Button 등", "룰 실행 분기를 결정", "control.controlKind"],
  ["컨트롤계획", "H", "이름", "표시문자·라벨·윈도우 텍스트에서 얻은 이름", "수집 불가 시 안정화 이름", "control.name"],
  ["컨트롤계획", "I", "클래스", "Win32 창 클래스명", "HTS 네이티브 컨트롤 식별 단서", "control.className"],
  ["컨트롤계획", "J", "위치 서명", "컨텐츠 영역 내부 좌표 기반 서명", "동적 HWND 재발견에 사용", "control.positionSignature"],
  ["컨트롤계획", "K", "초기값", "조작 전 컨트롤 상태", "복원 및 변경 검증 기준", "control.initialValue"],
  ["컨트롤계획", "L", "데이터셋 지정", "명시 입력 변수가 매칭되었는지", "예/아니오", "control.datasetBound"],
  ["컨트롤계획", "M", "추가 데이터 필요", "값을 자동 추론할 수 없어 데이터셋이 필요한지", "예이면 입력데이터안내 참조", "control.requiresAdditionalData"],
  ["컨트롤계획", "N", "발견 선택지", "콤보·라디오·탭 등에서 수집한 선택지 수", "0 이상", "control.discoveredOptionCount"],
  ["컨트롤계획", "O", "라벨 출처", "이름을 얻은 근거", "윈도우 텍스트/인접 라벨/데이터셋 등", "control.labelSource"],
  ["컨트롤계획", "P", "대기 사유", "자동화 미완료가 된 이유", "없으면 빈값", "control.pendingReason"],
  ["컨트롤계획", "Q", "정의 출처", "컨트롤 기준 정보가 MAP과 런타임 중 어디에서 왔는지", "MAP+Runtime/MAP/RuntimeOnly", "control.definitionSource"],
  ["컨트롤계획", "R", "MAP 타입", "MAP 바이너리의 2자리 컨트롤 타입 코드", "예: 05=버튼, 11=날짜, 13=체크", "control.mapTypeCode"],
  ["컨트롤계획", "S", "MAP 정의 순서", "MAP 컨트롤 테이블에 저장된 순서", "탭 순서와 구분되는 정적 설계 순서", "control.mapDefinitionOrder"],
  ["컨트롤계획", "T", "실시간 결합", "MAP 정의가 실행 중 HWND/UIA/탭 컨트롤과 결합됐는지", "예인 항목만 MAP 기준으로 실제 조작", "control.mapMatched"],
  ["컨트롤계획", "U", "결합 거리(px)", "좌표 변환 후 MAP 중심과 런타임 중심 사이 거리", "설정 허용치 이하여야 결합", "control.mapMatchDistance"],
  ["컨트롤계획", "V", "런타임 분류", "MAP을 적용하기 전 HWND/UIA/탭 기반 추정 종류", "MAP 종류와 비교해 오분류 확인", "control.runtimeControlKind"],
  ["컨트롤계획", "W", "MAP 이벤트", "MAP 스크립트에서 논리 ID와 연결된 이벤트 함수", "Click/SelectChange/ChangeCheckState 등", "control.mapEvents"],
  ["컨트롤계획", "X", "MAP 설계 좌표", "원본 MAP의 x,y,width,height", "DPI·실시간 앵커 보정 전 좌표", "control.mapRect"],
  ["컨트롤계획", "Y", "MAP 의미 역할", "이벤트와 통신 흐름으로 판정한 컨트롤 역할", "Query/AutoQuery/StateController/Export/Pagination/Input 등", "control.mapSemanticRole"],
  ["컨트롤계획", "Z", "연결 RQ", "해당 컨트롤 이벤트에서 직접 또는 간접 호출하는 요청 이름", "RQ_* 목록", "control.mapTriggeredRequests"],
  ["컨트롤계획", "AA", "읽는 컨트롤", "해당 이벤트가 값을 참조하는 입력 컨트롤", "MAP 논리 ID 목록", "control.mapReadControls"],
  ["컨트롤계획", "AB", "영향 컨트롤", "토글·탭·버튼 이벤트가 활성화·표시·값을 바꾸는 컨트롤", "상태 변경 후 재발견 대상", "control.mapAffectedControls"],
  ["컨트롤계획", "AC", "결과 컨트롤", "조회·페이지 이동이 갱신하거나 초기화하는 그리드·차트", "결과 오라클의 관찰 범위", "control.mapResultControls"],
  ["컨트롤계획", "AD", "호출 핸들러", "해당 이벤트가 연쇄 호출하는 MAP 함수·이벤트", "간접 조회와 검증 흐름 추적", "control.mapInvokedHandlers"],
  ["컨트롤계획", "AE", "MAP 화면전환 대상", "버튼·그리드·탭 이벤트가 열도록 정의된 화면·대화상자", "실제 새 창이 기대 대상인지 판정", "control.mapNavigationTargets"],
  ["컨트롤계획", "AF", "공식 선택지 출처", "HTS 설치 INI에서 해당 컨트롤에 결합한 선택지 사전", "출처가 있으면 런타임 발견값과 병합해 전수 계획", "control.mapOptionSource"],
  ["선택지테스트", "A", "케이스 ID", "선택지 실행이 속한 케이스", "세부 시트 연결 키", "test.caseId"],
  ["선택지테스트", "B", "화면번호", "테스트한 화면", "4자리 화면번호", "test.screenNumber"],
  ["선택지테스트", "C", "계획 항목 ID", "결정론적 실행 큐의 항목 ID", "재현 가능한 순서 추적", "test.planItemId"],
  ["선택지테스트", "D", "컨트롤 ID", "대상 컨트롤 안정화 ID", "컨트롤계획 시트와 연결", "test.controlId"],
  ["선택지테스트", "E", "종류", "대상 컨트롤 유형", "종류별 실행기 선택", "test.controlKind"],
  ["선택지테스트", "F", "컨트롤명", "사람이 식별할 수 있는 대상 이름", "수집/정리된 라벨", "test.controlName"],
  ["선택지테스트", "G", "선택지 ID", "입력값 조합의 데이터셋 ID", "재실행 시 같은 값을 식별", "test.optionId"],
  ["선택지테스트", "H", "입력값", "컨트롤에 전달한 기계 값", "날짜는 yyyyMMdd, 체크는 true/false", "test.inputValue"],
  ["선택지테스트", "I", "표시값", "화면에서 보이는 사람이 읽는 값", "콤보·라디오 라벨 등", "test.displayValue"],
  ["선택지테스트", "J", "상태", "해당 값 조작 결과", "통과/실패/오류/대기", "test.status"],
  ["선택지테스트", "K", "조회 실행", "값 변경 후 조회를 수행했는지", "예/아니오", "test.queryInvoked"],
  ["선택지테스트", "L", "제품 결함 감지", "조작 또는 조회 뒤 기대 결과를 벗어난 결함이 감지됐는지", "예/아니오", "test.errorDetected"],
  ["선택지테스트", "M", "출력", "선택·입력·조회 관찰 결과", "실제 적용 여부와 팝업 요약 포함 가능", "test.output"],
  ["선택지테스트", "N", "오류 코드", "실패/미완료 유형 코드", "없으면 빈값", "test.errorCode"],
  ["선택지테스트", "O", "스크린샷", "오류 발생 시 증적 이미지 경로", "정상일 때 비어 있을 수 있음", "test.screenshotPath"],
  ["선택지테스트", "P", "소요시간(ms)", "해당 선택지 조작과 조회 경과 시간", "밀리초", "test.durationMs"],
  ["선택지테스트", "Q", "기대 결과", "입력값에 지정된 Success/ValidationAllowed/ValidationRequired/FailureRequired/NoDataAllowed/WarningAllowed/ObservationOnly/Unspecified", "실행 전 판정 계약", "test.expectedOutcomeType"],
  ["선택지테스트", "R", "기대 일치", "해당 조작 단계에서 기대 문구·코드를 관찰했는지", "ValidationRequired/FailureRequired는 반드시 예여야 함", "test.expectationSatisfied"],
  ["선택지테스트", "S", "기대 출처", "Dataset/InstallationInputOption/InstallationMaster/MapValidation/MapBehavior/RuntimeChoice/GeneratedBoundary 등 기대 계약의 생성 근거", "설치·MAP 근거가 수동 기본값보다 우선", "test.expectedOutcomeSource"],
  ["선택지테스트", "T", "신뢰도", "High/Medium/Low/Unspecified", "정적 원문과 조건이 직접 연결되면 High", "test.expectedOutcomeConfidence"],
  ["선택지테스트", "U", "기대 근거", "기대 결과를 생성한 설치 파일·MAP 규칙·조건식 설명", "감사 가능한 원문 근거", "test.expectedOutcomeEvidence"],
  ["팝업관찰", "A", "케이스 ID", "팝업이 나타난 케이스", "세부 시트 연결 키", "popup.caseId"],
  ["팝업관찰", "B", "화면번호", "팝업 발생 화면", "4자리 화면번호", "popup.screenNumber"],
  ["팝업관찰", "C", "팝업 ID", "관찰된 팝업의 고유 ID", "같은 팝업 중복 식별", "popup.popupId"],
  ["팝업관찰", "D", "분류", "오류/경고/확인/정보 등", "키워드·버튼·제목 기반 룰 분류", "popup.category"],
  ["팝업관찰", "E", "예상 여부", "expectedPopupPatterns와 일치하는지", "예/아니오", "popup.expected"],
  ["팝업관찰", "F", "제목", "팝업 창 제목", "Win32 창 텍스트", "popup.title"],
  ["팝업관찰", "G", "본문", "팝업 내부에서 읽은 텍스트", "자식 HWND 텍스트 수집", "popup.body"],
  ["팝업관찰", "H", "버튼", "팝업에 표시된 버튼 목록", "확인/취소/예/아니오 등", "popup.buttons"],
  ["팝업관찰", "I", "요약", "판정에 사용할 정리된 팝업 설명", "제목·본문·분류 요약", "popup.summary"],
  ["팝업관찰", "J", "판정 출처", "공통 키워드 또는 화면별 MAP 중 실제 적용한 오라클", "MAP 문구가 일치하면 MAP 우선", "popup.oracleSource"],
  ["팝업관찰", "K:M", "MAP 규칙 ID/핸들러/원문", "MAP에서 추출해 팝업과 일치한 정적 오류 근거", "MAP 미일치 시 빈값", "popup.oracleRuleId / mapHandler / mapMessage"],
  ["팝업관찰", "N", "스크린샷", "오류 팝업의 증적 이미지 경로", "관찰된 팝업마다 저장", "popup.screenshotPath"],
  ["팝업관찰", "O", "감지 시각", "팝업을 처음 관찰한 시각", "KST 날짜·시간", "popup.detectedAt"],
  ["팝업관찰", "P", "HTS 오류코드", "data/errcode.txt의 코드 또는 문구와 일치한 공식 오류코드", "일치하지 않으면 빈값", "popup.installedErrorCode"],
  ["팝업관찰", "Q", "HTS 오류 분류", "설치 오류코드 사전의 Normal/NoData/Authentication/TransientFailure/SystemFailure/InputOrBusinessValidation 분류", "분류와 isFailure 정책으로 명시 오류 판정 보강", "popup.installedErrorClass"],
  ["판정이벤트", "A:R", "관찰 이벤트", "팝업·화면·로그에서 발견한 검증·자료 없음·경고·제품 실패와 기대 결과·출처·신뢰도 비교", "Expected=정상 기대 반응, Review=PENDING, Defect/Unexpected=FAIL", "result.oracleEvents"],
  ["자동화미완료", "A", "케이스 ID", "미완료 항목이 속한 케이스", "테스트결과와 연결", "issue.caseId"],
  ["자동화미완료", "B", "화면번호", "미완료가 발생한 화면", "4자리 화면번호", "issue.screenNumber"],
  ["자동화미완료", "C", "컨트롤 종류", "대상 컨트롤 유형", "알 수 없으면 빈값", "issue.controlKind"],
  ["자동화미완료", "D", "컨트롤명", "대상 컨트롤 표시명", "알 수 없으면 빈값", "issue.controlName"],
  ["자동화미완료", "E", "선택지/입력값", "완료하지 못한 값", "수집 손상 문구는 정리해 표시", "issue.option"],
  ["자동화미완료", "F", "오류 코드", "기계 판독 가능한 미완료 사유", "예: CONTROL_STALE", "issue.errorCode"],
  ["자동화미완료", "G", "정리된 사유", "오류 코드를 한국어로 변환한 요약", "유형별 동일 문구로 그룹화", "incompleteLabel(errorCode)"],
  ["자동화미완료", "H", "상세 내용", "실행기가 기록한 상세 원인", "인코딩 손상 시 대체 설명", "issue.detail"],
  ["오류스크린샷", "A:B", "케이스 ID/화면", "오류 이미지가 속한 케이스와 화면", "FAIL/ERROR 케이스마다 블록 생성", "result.caseId / screenNumber"],
  ["오류스크린샷", "A:B", "상태/오류 코드/오류 메시지", "오류 판정 결과와 설명", "테스트결과 시트와 동일", "result.status / errorCode / errorMessage"],
  ["오류스크린샷", "A:B", "스크린샷 경로", "원본 이미지 파일의 상대 경로", "보고서 폴더 내부 경로만 허용", "result.screenshotPath"],
  ["오류스크린샷", "D:L", "이미지 영역", "오류 시점 HTS 화면 이미지를 문서에 직접 삽입", "파일이 없으면 이미지 없음 안내", "xlsx embedded image"],
  ["설치카탈로그", "A", "구분", "화면·연결·탭·컨트롤 타입·오류코드·무결성·마스터·로그 자료의 종류", "설치 파일별 활용 목적을 구분", "map-screen-models.json"],
  ["설치카탈로그", "B", "식별자", "화면번호·오류코드·타입코드·파일 경로 등 안정 식별자", "같은 설치 버전의 추적 키", "catalog item id"],
  ["설치카탈로그", "C", "대상·값", "원본에서 읽은 제목·메시지·연결 대상·레코드 수", "민감 로그 원문은 포함하지 않음", "catalog item value"],
  ["설치카탈로그", "D", "원본 파일·API", "근거가 된 HTS 설치 파일 또는 MAP 화면전환 API", `${targetInstallationRoot} 하위 자료`, "catalog source"],
  ["설치카탈로그", "E", "상태·분류", "무결성 MATCH·오류 분류·연결 존재 여부 등", "불일치·누락은 확인 필요", "catalog status"],
  ["설치카탈로그", "F", "테스트 활용 방법", "해당 자료를 컨트롤 계획·오류 판정·값별 기대 계약에 적용하는 방식", "정적 정보는 런타임 발생 증거와 분리하고 기대 출처·신뢰도를 함께 표시", "catalog usage"],
];

columnGuideRows.push(
  ["시나리오계획", "A:N", "화면·시나리오·준비상태·커버리지·생성출처", "프로그램 자동 생성 또는 외부 반환 시나리오를 결정론적으로 컴파일한 결과", "시나리오가 참조한 변수만 조합하고 생성기/버전을 추적", "compiled-plan.json"],
  ["컨트롤바인딩", "A:Q", "logicalName·실행가능성·후보 근거", "MAP 논리 컨트롤과 실제 런타임 컨트롤의 결합 결과", "유일한 RuntimeActionable 후보만 실행 허용", "binding-catalog.json"],
  ["승인및제외", "A:H", "검토·커버리지·실행승인", "필수 검토, 승인되지 않은 시나리오, 제외 사유", "미해결 필수 항목은 실행 차단", "scenario-review-items.json / physical-plan.json"],
  ["테스트결과", "Y:AE", "시나리오 추적 정보", "실행 케이스를 논리·물리 계획과 연결", "시나리오 모드에서만 값이 채워짐", "result.scenario* / logicalPlanId / physicalPlanId"],
  ["선택지테스트", "V:Z", "시나리오 단계 정보", "실제 컨트롤 조작이 어떤 시나리오 단계에서 발생했는지 기록", "단계 ID와 순번으로 원본 계획 추적", "controlTest.scenario*"],
);
writeGuideSheet(columnGuideSheet, "결과 엑셀 시트·컬럼 설명", ["시트", "열/영역", "컬럼·항목", "설명", "값·판정 기준", "원천 필드·수식"], columnGuideRows, [18, 14, 25, 46, 42, 32]);

const mapOracleGuideRows = [];
for (const screen of (Array.isArray(mapCatalog.screens) ? mapCatalog.screens : [])) {
  const oracle = screen.errorOracle ?? {};
  for (const message of (Array.isArray(oracle.messageBoxes) ? oracle.messageBoxes : [])) {
    const classInfo = ({
      Error: ["FAIL", "MAP_EXPLICIT_MESSAGE", "명시 오류"],
      InputValidation: ["관찰", "MAP_INPUT_VALIDATION", "입력 검증"],
      Warning: ["관찰", "MAP_WARNING_MESSAGE", "경고"],
      Info: ["관찰", "MAP_INFO_MESSAGE", "정보"],
    })[message.classification] ?? ["관찰", "MAP_MESSAGE", "정보"];
    mapOracleGuideRows.push([
      `MAP ${classInfo[2]} [${screen.screenNumber}]`,
      `현재 화면의 새 팝업 제목·본문을 MAP ${message.api} 원문과 정확히 대조: ${message.message}`,
      classInfo[0], `${classInfo[1]} / ${message.ruleId}`, "팝업관찰/map-screen-models.json/오류스크린샷",
      message.isExplicitError ? "오류로 판정하고 전체 HTS 화면을 캡처한 뒤 대화상자를 닫음" : "결함으로 과장하지 않고 분류·원문·핸들러를 기록한 뒤 안전하게 닫음",
      message.isExplicitError ? "MAP 코드 자체가 오류 의미를 명시한 문구일 때만 FAIL" : "입력 검증·경고·정보 문구는 발생 사실을 남기되 자동 FAIL 아님",
      `핸들러 ${message.handler}${message.title ? ` / 제목 ${message.title}` : ""}${(message.targetControls ?? []).length ? ` / 대상 ${(message.targetControls ?? []).join(", ")}` : ""}${message.conditionExpression ? ` / 조건 ${message.conditionExpression}` : ""}`,
    ]);
  }
  const handlers = Array.isArray(oracle.errorHandlers) ? oracle.errorHandlers : [];
  const tokens = [...(oracle.requestNames ?? []), ...(oracle.transactionCodes ?? [])];
  if (oracle.hasReceiveErrorParameters || handlers.length || tokens.length) {
    mapOracleGuideRows.push([
      `MAP 오류 처리 경로 [${screen.screenNumber}]`,
      `OnError=${handlers.join(", ") || "없음"}; 수신 오류 인자=${oracle.hasReceiveErrorParameters ? "있음" : "없음"}; 통신 식별자=${tokens.join(", ") || "없음"}`,
      "판정 보조", "MAP_ERROR_PATH_CONTEXT", "map-screen-models.json/단계결과/신규 로그 오류",
      "핸들러 존재만으로 실패시키지 않고 팝업·창·신규 로그의 실제 발생 신호를 보강",
      "정적 코드 경로는 발생 가능성·로그 귀속 근거이며 런타임 오류 발생 증거가 아님",
      "실제 오류 발생 시 RQ/TR 식별자로 해당 화면의 신규 로그 줄을 대조",
    ]);
  }
}

const errorGuideRows = [
  ["기대 입력 검증 발생", "현재 입력값 expectedOutcome의 messagePatterns/errorCodes와 신규 팝업·화면 문구를 대조", "PASS", "EXPECTED_VALIDATION_OBSERVED", "판정이벤트/선택지테스트/팝업관찰", "검증 이벤트를 증적으로 기록하고 다음 항목 계속", "잘못된 입력을 HTS가 의도대로 거부한 정상 동작", "제품 결함 수에 포함하지 않음"],
  ["필수 기대 반응 누락", "ValidationRequired/FailureRequired 입력 뒤 지정 문구·코드가 실제로 나타났는지 확인", "FAIL", "EXPECTED_OUTCOME_NOT_OBSERVED", "판정이벤트/테스트결과/오류스크린샷", "누락 시 화면 상태를 캡처", "검증되어야 할 잘못된 입력을 허용하거나 기대 실패가 발생하지 않은 결함", "입력 적용·조회 실행 증거와 함께 재현"],
  ["정상값의 예상 밖 검증", "Success 입력에서 InputValidation·NoData·Warning·GenericError가 나타났는지 확인", "FAIL", "UNEXPECTED_APPLICATION_EVENT", "판정이벤트/테스트결과/오류스크린샷", "관찰 문구와 입력값을 함께 저장", "정상으로 지정한 값을 HTS가 거부한 결함 후보", "데이터 유효기간·계좌 선행조건 확인"],
  ["기대 결과 미지정 이벤트", "Unspecified 입력에서 검증·자료 없음·경고·일반 오류가 나타났으나 시스템 실패 근거는 없는 경우", "PENDING", "OUTCOME_EXPECTATION_REQUIRED", "판정이벤트/자동화미완료", "결함으로 단정하지 않고 입력 데이터 보강 요청", "입력 의도를 모르면 정상 검증과 제품 결함을 구분할 수 없음", "해당 값에 expectedOutcome 추가"],
  ["설치 입력 사전 정상값", "exchange.ini·empcommon.ini의 의미가 확정된 입력 사전을 MAP 대상 컨트롤에 결합", "PASS 후보", "Success / InstallationInputOption / High", "설치카탈로그/선택지테스트", "각 공식 선택지를 실제 적용하고 조회", "설치 원문은 정상 입력 근거이며 런타임 성공을 대신하지 않음", "예상 밖 검증·시스템 실패는 FAIL"],
  ["설치 종목 마스터 정상값", "VST 무결성을 확인한 stkcode.cod·nxtcode.cod·etfcode.cod 표본을 종목 컨트롤에 결합", "PASS 후보", "Success / InstallationMaster / High", "설치카탈로그/선택지테스트", "공식 코드 표본과 자동 경계값을 함께 실행", "마스터 존재는 코드 형식·등록 근거이며 계좌 권한까지 보증하지 않음", "예상 밖 검증은 계좌·시장 선행조건과 함께 재현"],
  ["MAP 조건 기반 입력 검증", "MAP 메시지 대상 컨트롤과 가장 가까운 If/ElseIf/Else 조건식을 입력값에 대조", "PASS/FAIL", "ValidationRequired / MapValidation", "오류판정기준/판정이벤트", "조건 위반값은 지정 검증이 반드시 나타나야 함", "조건식 직접 연결은 High, 메시지만 연결되면 ValidationAllowed/Medium", "계산하지 못한 복합 조건은 PENDING 또는 데이터셋 계약으로 보강"],
  ["HTS 설치 파일 무결성 불일치", "screen_hts.vst/mst.vst의 MD5·크기와 실제 MAP·마스터 파일을 실행 전 대조", "PENDING", "INSTALLATION_MODEL_DRIFT", "설치카탈로그/단계결과/자동화미완료", "불일치한 정적 모델을 기준으로 PASS 판정하지 않음", "HTS 업무 오류가 아니라 테스트 기준 모델의 버전·파일 상태 문제", "HTS 패치 완료 여부와 설치 지문을 확인한 뒤 카탈로그 재생성"],
  ["HTS 공식 오류코드", "data/errcode.txt의 코드·메시지를 신규 팝업과 로그 줄에 대조하고 분류의 isFailure 정책 확인", "FAIL 또는 관찰", "HTS_ERROR_CODE_MATCH", "팝업관찰/설치카탈로그/단계결과", "실패 분류는 오류 증적으로 기록하고 Normal·NoData 등은 분류 정책에 따라 관찰", "코드 사전 일치는 공통 키워드보다 우선하되 실제 신규 발생 신호가 있어야 판정", "오류코드·문구·발생 동작을 함께 재현"],
  ["MAP 기준 모델 없음", `실행 전 ${targetScreenDirectory}의 화면별 MAP 파일 존재·파싱 여부 확인`, "PENDING", "MAP_MODEL_NOT_FOUND", "단계결과/자동화미완료/map-screen-models.json", "해당 화면은 런타임 발견만 유지하고 MAP 기준 완료로 간주하지 않음", "정적 기준 정보가 없으므로 전체 컨트롤 포괄성을 증명할 수 없음", "파일 경로·화면번호·HTS 배포 버전 확인"],
  ["MAP 컨트롤 실시간 미결합", "MAP 설계 좌표를 DPI·실시간 앵커로 변환한 뒤 종류와 중심 거리로 HWND/UIA/탭 포커스 매칭", "PENDING", "MAP_CONTROL_NOT_BOUND", "컨트롤계획/선택지테스트/자동화미완료", "미결합 좌표를 임의 클릭하지 않고 다음 항목으로 진행", "숨김·비활성·버전 불일치 또는 자동화 누락을 구분해야 함", "MAP 타입 매핑·좌표 허용치·활성 탭 상태 확인"],
  ...mapOracleGuideRows,
  ["HTS 메인 창 접근 불가", "환경 사전 점검에서 대상 프로세스·메인 HWND 탐색", "PENDING", "ENVIRONMENT_HTS_NOT_ACCESSIBLE", "테스트결과/단계결과/자동화미완료", "화면을 조작하지 않고 종료", "실행 환경 문제이므로 실제 오류 PASS로 기록하지 않음", "사용자가 HTS 로그인 후 재실행"],
  ["대상 화면 열기 실패", "화면번호 입력 후 제목·컨텐츠 창·HWND 생존 여부 확인", "FAIL", "SCREEN_NOT_VISIBLE", "테스트결과/단계결과/오류스크린샷", "화면 열기 직후", "업무 화면이 표시되지 않은 명시적 실패", "화면번호·권한·메뉴 제한 확인"],
  ["컨트롤 재식별 실패", "조작 직전 고정 controlId·locatorSignature·MAP·상태·종류로 유일 후보를 재탐색", "ERROR/PENDING", "CONTROL_STALE / CONTROL_AMBIGUOUS / PHYSICAL_BINDING_DRIFT", "선택지테스트/자동화미완료", "입력을 보내지 않고 물리 시나리오는 ERROR, 일반 탐색은 PENDING", "제품 결함과 자동화 계약 불일치를 분리", "Plan-only 재수집 후 1.1 물리계획 재생성"],
  ["체크 상태 검증 불가", "UIA Toggle 또는 BM_GETCHECK로 조작 전후 상태를 읽어 검증", "ERROR/PENDING", "CHECK_STATE_UNVERIFIABLE", "선택지테스트/자동화미완료", "상태를 읽을 수 없으면 클릭하지 않음", "owner-drawn Afx 컨트롤을 성공으로 추정하지 않음", "전용 UIA 어댑터 또는 상태 오라클 보강"],
  ["HTS 연결 장애", "접속 해제·재접속·프로그램 종료 문구와 버튼을 대화상자에서 식별", "ERROR", "HTS_CONNECTION_LOST", "팝업관찰/테스트결과", "재접속·종료·Escape를 선택하지 않고 실행 중단", "사용자 판단이 필요한 외부 상태", "사용자가 연결 상태를 확인한 뒤 새 실행 시작"],
  ["컨트롤 조작 실패", "SendMessage/키보드/마우스 조작 뒤 값·체크·포커스 상태 확인", "PENDING", "CONTROL_ACTION_FAILED", "선택지테스트/자동화미완료", "가능하면 상태 복원 후 계속", "명시적 HTS 오류와 자동화 실패를 분리", "컨트롤별 실행기 보강"],
  ["콤보 목록·선택 실패", "목록 HWND 표시, 항목 수집, 선택 후 표시값 변경 여부 확인", "PENDING", "COMBO_LIST_NOT_VISIBLE 등", "컨트롤계획/선택지테스트/자동화미완료", "다음 선택지 또는 컨트롤로 계속", "목록을 읽거나 적용했음을 증명하지 못한 상태", "데이터셋 Locator/Index/DisplayText 지정"],
  ["조회 버튼 미발견", "버튼 텍스트·탭오더·상대 위치에서 조회 역할 탐색", "PENDING", "QUERY_BUTTON_NOT_FOUND", "단계결과/자동화미완료", "F12 대체 조회를 시도하고 사실을 기록", "대체 키 실행을 PASS 증거로 과장하지 않음", "화면별 queryTrigger 또는 locator 지정"],
  ["입력 경계 차단", "모든 클릭 직전에 HTS 메인창·현재 대상 창·콘텐츠 안전 영역·자손 HWND를 재검증", "PENDING", "INPUT_SCOPE_BLOCKED", "선택지테스트/단계결과/자동화미완료", "마우스·키 입력을 보내지 않고 해당 항목만 중단", "HTS 외부 또는 다른 화면으로 향하는 입력은 절대 실행하지 않음", "로케이터·좌표·창 전환 원인 확인"],
  ["오류 팝업", "새 팝업 제목·본문을 공식 오류코드, MAP 분류, 현재 입력 expectedOutcome 순으로 평가", "조건부", "EXPLICIT_ERROR_DETECTED / EXPECTED_VALIDATION_OBSERVED", "팝업관찰/판정이벤트/오류스크린샷", "항상 내용을 기록하고 제품 결함일 때만 FAIL", "시스템 실패는 FAIL, 기대 입력 검증은 PASS, 미지정 검증은 PENDING", "입력값과 판정 근거를 함께 확인"],
  ["경고·확인·정보 팝업", "팝업 제목·본문·버튼 구조와 WarningAllowed/ObservationOnly 계약을 대조", "PASS/PENDING/FAIL", "EXPECTED_WARNING / OUTCOME_EXPECTATION_REQUIRED", "팝업관찰/판정이벤트", "내용을 기록하고 안전하게 닫기", "기대 경고는 PASS, 정상값의 예상 밖 경고는 FAIL, 미지정은 PENDING", "expectedOutcome을 값별로 보강"],
  ["화면 내 오류 문구", "조작 전 baseline과 조작 후 보이는 창 텍스트를 비교하고 현재까지 실행한 입력 기대 패턴과 대조", "조건부", "EXPLICIT_ERROR_DETECTED / EXPECTED_VALIDATION_OBSERVED", "테스트결과/판정이벤트/오류스크린샷", "신규 문구의 기대 여부와 제품 결함 여부를 분리", "'오류' 단어만으로 FAIL하지 않으며 시스템 실패 또는 기대 위반일 때만 FAIL", "입력값·문구·조회 시점을 함께 재현"],
  ["로그 신규 오류", "debugmain.log/SocketErr.log/Starter.log의 기준 오프셋 이후 추가 줄 검사", "FAIL", "EXPLICIT_ERROR_DETECTED", "테스트결과/단계결과/오류스크린샷", "케이스 종료 오라클에서 판정", "실행 전부터 있던 과거 오류는 제외", "신규 로그 줄과 발생 동작 대조"],
  ["화면 예기치 않은 종료", "각 조작 뒤 대상 화면 HWND 존재·가시성 확인", "FAIL", "SCREEN_CLOSED_UNEXPECTEDLY", "테스트결과/단계결과/오류스크린샷", "재열기 시도 후 남은 계획을 계속", "닫기 명령이 아닌데 화면이 사라지면 결함 후보", "해당 직전 컨트롤·선택지 확인"],
  ["HTS 무응답", "프로세스 응답 상태와 창 메시지 처리 상태 검사", "FAIL", "EXPLICIT_ERROR_DETECTED", "테스트결과/단계결과/오류스크린샷", "추가 입력을 중단하고 증적 저장", "응답 없음은 명시적 실행 오류", "HTS 로그 및 재현 단계 분석"],
  ["실행기 예외", "케이스 실행의 처리되지 않은 예외 포착", "ERROR/FAIL", "EXECUTOR_EXCEPTION", "테스트결과/단계결과/오류스크린샷", "예외 메시지를 정리하고 다음 케이스로 진행", "HTS 결함과 자동화 코드 결함을 구분", "스택 추적과 입력 조합으로 수정"],
  ["화면·대화상자 정리 실패", "정상 종료 단계에서 대상 HWND와 연계 번호 창의 소멸 여부 확인", "PENDING", "SCREEN_CLOSE_PENDING / SCREEN_SEQUENCE_CLOSE_PENDING", "단계결과/자동화미완료", "남은 창이 있으면 다음 화면 열기를 차단", "업무 오류가 아니라 실행 격리 미완료", "창 소유 관계·닫기 정책 확인"],
  ["픽셀 전용 오류 표현", "현재 Win32 텍스트·팝업·로그로 읽히지 않는 그래픽 메시지", "미탐 가능", "제한사항", "동영상/수동 관찰", "자동 판정 없음", "OCR·화면 비교가 없으므로 현재 자동 오라클 범위 밖", "향후 OCR/이미지 기준선 추가"],
];
writeGuideSheet(errorGuideSheet, "오류 유형별 발견·기록·대응 기준", ["오류 유형", "관찰·탐지 방법", "상태", "대표 오류 코드", "기록 위치", "실행 중 처리", "판정 원칙", "후속 확인"], errorGuideRows, [25, 48, 13, 30, 35, 40, 48, 40]);

const pipelineRows = [
  [1, "데이터셋 로드·검증", summary.datasetPath ?? "실행에 전달된 dataset.json", "targetProfile, 화면 ID, 선택적 계좌, 변수, 제한값 검증", "검증 결과", "잘못된 데이터면 실행 시작 전 중단"],
  [2, "케이스 조합 생성", "활성 화면 × 실행 컨텍스트 × 변수 값", "계좌가 없으면 기본 컨텍스트 한 건을 사용하고 화면 적용 범위를 반영해 결정론적 경우의 수 생성", "caseId 목록", "maxExpandedCases 초과 시 중단"],
  [3, "FlaUI UIA3·HTS 환경 사전 점검", "FlaUI bridge ping + 프로세스/클래스/창 제목", `FlaUI.UIA3 5.0.0 응답과 로그인된 ${targetDisplayName} 메인 창 상태 확인`, "엔진 버전·환경 단계 결과", "브리지 또는 HTS 접근 불가면 PENDING"],
  [4, "이전 창 정리", "열린 업무 화면·대화상자", "이전 케이스의 잔여 창을 닫아 케이스 격리", "정리 단계 결과", "정리 실패는 PENDING 기록"],
  [5, "오라클 기준선 수집", "가시 텍스트·로그 파일 오프셋", "조작 전 오류 문구와 로그 위치 저장", "baseline", "과거 오류를 신규 오류로 오판하지 않음"],
  [6, "화면 열기", "screenNumber", "메인 입력칸에 화면번호를 넣고 대상 화면 HWND 확인", "화면 제목·핸들", "표시 실패는 FAIL"],
  [7, "컨텐츠 영역·입력 경계 확정", "HTS 메인창·대상 화면·자식 HWND 구조", "프레임·창 버튼을 제외한 업무 컨텐츠 범위를 고정하고 모든 클릭·키 입력에 공통 경계 가드 적용", "main/content bounds", "경계 밖 좌표·포커스·HWND는 INPUT_SCOPE_BLOCKED"],
  [8, "계좌·비밀번호 조건 적용", "Prefilled 또는 Explicit 계좌 설정", "현재 기본값을 사용하거나 데이터셋 값을 안전하게 입력", "마스킹된 입력 이력", "비밀번호 원문은 결과에 남기지 않음"],
  [8.05, "HTS 설치 카탈로그 로드", "menu.dat·screen_number.dat·tabscreen.ini·sysctrl.ini·errcode.txt·VST·마스터·로그 위치", "화면 제목·별칭·탭 그룹·타입 사전·오류코드·무결성·공식 선택지·로그 소스를 하나의 기준 모델로 결합하고 공식 입력값에 기대 출처·신뢰도·근거를 부여", "설치카탈로그 / installationModel", "무결성 불일치는 INSTALLATION_MODEL_DRIFT로 PENDING"],
  [8.1, "MAP 기준 모델 추출", `${targetScreenDirectory}/${targetMapPattern}`, "화면명·논리 ID·타입·설계 좌표·이벤트 스크립트를 구조화", "map-screen-models.json", "파일이 없거나 해석 불가하면 MAP_MODEL_NOT_FOUND"],
  [8.2, "MAP과 실행 상태 결합", "MAP 모델 + FlaUI UIA3 + HWND + 실제 탭 포커스", "UIA3 RuntimeId·AutomationId·패턴·좌표와 MAP 설계 좌표를 현재 컨트롤에 일대일 결합", "MAP+Runtime/MAP/RuntimeOnly", "미결합 MAP 항목은 클릭하지 않고 MAP_CONTROL_NOT_BOUND"],
  [8.3, "MAP 오류 오라클 구성", "FormMsgBox·OnError·strErrCode/strErrMsg·RQ/TR", "화면별 메시지 원문은 런타임 팝업과 대조하고 오류 처리 경로와 통신 코드는 판정 보조 정보로 구조화", "errorOracle / MAP 규칙 ID", "오류 의미가 명시된 문구만 FAIL, 입력 검증·경고·정보는 관찰"],
  [8.4, "MAP 동작 그래프 구성", "이벤트 핸들러·CommRequest·컨트롤 읽기/쓰기·호출 관계", "조회·자동조회·페이지·내보내기·상태제어·입력·결과 컨트롤과 간접 RQ 경로를 계산", "behavior / semanticRole / affectedControls", "정적 경로는 실행 우선순위와 포괄성 검증에 사용하고 성공 응답으로 간주하지 않음"],
  [9, "물리 탭오더 순회", "Tab/Shift+Tab 포커스 이동", "첫 포커스로 돌아올 때까지 HWND와 순서를 수집", "tabOrder/tabStop/tabStatus", "미도달 컨트롤은 별도 발견과 병합"],
  [10, "컨트롤 유형 분류", "클래스·스타일·텍스트·포커스 반응", "Text/Date/Combo/Radio/CheckBox/Tab/Button 등으로 분류", "컨트롤계획", "불명확하면 Generic 또는 데이터 필요"],
  [11, "선택지·기대 계약 생성", "데이터셋 값 + 설치 입력 사전·마스터 + MAP 조건 + 런타임 옵션", "날짜·콤보·라디오·체크·탭·버튼별 실행 값과 source/confidence/evidence를 함께 생성", "option plan / expectedOutcome", "근거 우선순위로 병합하고 값을 정할 수 없으면 PENDING_DATA_REQUIRED"],
  [12, "결정론적 계획 큐 생성", "탭 순서·컨트롤 종류·옵션", "같은 입력은 같은 순서로 실행되도록 planItemId 부여", "계획 목록", "LLM 미사용"],
  [13, "FlaUI UIA3 컨트롤·선택지 실행", "planItem + physical resolvedBinding", "고정 controlId·locatorSignature·MAP·상태·종류의 유일 후보를 실행 직전 재식별하고 Value/Invoke/Toggle/Selection/Range 패턴을 실행", "재식별 mode·근거·자동화 엔진·선택지테스트 행", "물리 identity 불일치는 ERROR, UIA3와 fallback이 모두 실패하면 PENDING"],
  [14, "조회 연계 실행", "triggerQueryAfterChange/queryTrigger", "상태 변경 뒤 조회 버튼 또는 지정 트리거 실행", "queryInvoked", "조회 미발견은 PENDING으로 분리"],
  [15, "팝업 관찰", "새 최상위 창과 자식 텍스트", "제목·본문·버튼을 읽고 오류/경고/확인/정보 분류", "팝업관찰 행", "입력 계약과 불일치하거나 시스템 실패인 팝업은 FAIL"],
  [16, "화면 생존 확인·복구", "대상 화면 HWND", "각 조작 뒤 화면이 닫히지 않았는지 확인하고 필요 시 재열기", "reopen 단계", "예기치 않은 종료는 FAIL"],
  [17, "동적 컨트롤 재발견", "탭·토글 변경 후 HWND 트리 + MAP 영향 컨트롤", "새로 나타난 하위 항목을 수집하고 이전에 미결합이던 MAP 컨트롤도 런타임 상태로 승격해 선택지를 새 계획에 추가", "rediscoverMapControls / 추가 컨트롤계획", "MAP 조회 경로를 끝내 실행하지 못하면 MAP_QUERY_NOT_EXECUTED"],
  [18, "최종 조회", "조회 버튼/대체 트리거", "모든 가능한 값 조작 뒤 반드시 최종 조회 수행", "조회 단계 결과", "미실행이면 완료로 간주하지 않음"],
  [19, "기대 결과 오라클", "팝업·신규 화면 문구·신규 로그·응답 상태 + 입력값 expectedOutcome", "시스템 실패·기대 검증·자료 없음·경고·미지정 이벤트를 분류하고 입력 계약과 대조", "oracleEvents / productDefectDetected", "기대 검증은 PASS, 기대 위반·시스템 실패는 FAIL, 미지정은 PENDING"],
  [20, "최종 상태 결정", "완성된 TestResult 집합", "Core ResultEvaluator의 overallResult를 재판정 없이 사용", "testResult / test-results.json", "자동화 실패를 제품 결함으로 집계하지 않음"],
  [21, "오류 스크린샷", "오류 시점 전체 HTS 창", "오류 문구와 화면 상태를 이미지로 저장", "screenshots/*.png", "이미지 경로를 결과 JSON과 엑셀에 연결"],
  [22, "케이스 종료·순차 전환", "현재 업무 화면·연계 화면·팝업", "현재 대상과 연계 창을 닫고 번호 창 0개를 확인한 뒤에만 다음 화면을 엶", "close/verifySequentialClose 단계", "남은 창이 있으면 다음 화면 열기 차단 및 PENDING"],
  [23, "민감정보 정리", "계좌번호·비밀번호", "계좌는 마스킹/지문 처리, 비밀번호는 비밀 공급자 키만 기록", "보호된 결과", "평문 비밀번호 저장 금지"],
  [24, "JSON 결과 저장", "케이스·단계·컨트롤·팝업 자료", "summary.json과 case-results.json 직렬화", "원본 기계 판독 결과", "저장 실패는 실행기 오류"],
  [25, "Excel 생성·검증", "JSON 결과와 오류 이미지", "한국어 시트 작성, 수식 오류 검사, 전 시트 PNG 렌더링", "테스트결과-*.xlsx", "수식/렌더링 오류 시 재생성"],
  [26, "전체 HTS 창 녹화", "물리 픽셀 창 경계", "DPI-aware 캡처, 창 재생성 추적, 전체 창 비율 유지 후 MP4 인코딩", "전체과정-*.mp4 + metadata.json", "프레임 누락·창 잘림을 메타데이터로 검증"],
  [27, "결과 병합·인수", "화면별 실행 결과", "데이터셋에 등록된 대상 화면 결과·영상·워크북을 한 실행으로 병합", "최종 인수 폴더", "실제 실행 증적만 PASS로 유지"],
];
pipelineRows.unshift(
  [0.1, "MAP 기준 모델 생성", "HTS 설치본 MAP·설치 카탈로그", "대상 화면의 컨트롤 역할·이벤트·공식 선택지·오류 규칙을 추출하고 설치 지문을 기록", "map-catalog.json", "MAP 누락·설치 지문 불일치는 PENDING"],
  [0.2, "런타임 Plan-only 탐색", "현재 HTS + 기준 데이터셋", "화면별 탭오더와 실제 콤보·라디오·탭 선택 항목을 수집하되 시나리오 동작은 실행하지 않음", "runtime-discovery/control-plan.json", "HTS 미접근·권한 불일치는 PENDING"],
  [0.3, "프로그램 시나리오 자동 생성", "MAP + 런타임 컨트롤 계획 + 데이터셋", "컨트롤별 선택지 전수와 날짜·문자 경계값을 만들고 전역 카테시안 폭증은 차단", "generated-rule-scenarios.json", "Schema·참조·케이스 상한 오류는 INVALID"],
  [0.4, "정책 승인", "자동 생성기 서명 + 커버리지 제외", "현재 자동 생성기 버전 문서만 승인하고 종료·외부 저장 등 제외 항목은 AcceptedGap으로 기록", "automatic-approval.json", "외부 작성 문서는 자동 승인 금지"],
  [0.5, "시나리오 컴파일", "생성 원본 + 기준 데이터셋 + 승인", "시나리오가 참조한 변수만 조합해 논리 실행계획과 planHash를 생성", "compiled-plan.json", "조합 한도 초과·미해결 참조는 컴파일 중단"],
  [0.6, "동적 MAP 바인딩", "논리 계획 + Plan-only 컨트롤 계획", "MAP logicalName을 locator·종류·양수 좌표·24px 거리로 검증하고 유일 후보를 시나리오별 고정", "binding-catalog 1.1 / resolvedBindings / physical-plan 1.1", "유일한 RuntimeActionable 후보가 없으면 PENDING_BINDING"],
  [0.7, "선택적 외부 시나리오", "ChatGPT 요청 묶음 + 반환 JSON", "도메인 특화 시나리오가 필요할 때만 외부 생성·수입·사람 승인을 별도 경로로 사용", "scenario-pipeline inbox", "프로그램 자동 생성 경로와 승인 정책을 혼합하지 않음"],
);
writeGuideSheet(pipelineSheet, "룰 기반 HTS 테스트 모듈 전체 로직·동작 파이프라인", ["단계", "모듈", "입력", "핵심 처리", "관찰·출력", "실패·PENDING 기준"], pipelineRows, [9, 27, 39, 55, 40, 46]);

const inputGuideRows = [
  ["현재 데이터셋", summary.datasetPath ?? "실행에 전달된 dataset.json", "JSON", "복제 후 targetProfile과 screens[]를 대상에 맞게 수정", "다음 실행부터 자동 반영", "UTF-8, JSON 문법 유지"],
  ["참고 예시", "data/rule-tests/입력변수-예시.json", "JSON 예시", "계좌·화면·변수·로케이터 예제를 참고", "작성용 참고", "실행 파일과 분리되어 있음"],
  ["대상 프로필", "targetProfile.id/displayName/runLabel", "고유 문자열", "대상 화면군의 ID·표시명·실행 파일명 라벨 지정", "전체 파이프라인", "화면군마다 별도 데이터셋 권장"],
  ["대상 프로필", "targetProfile.screenIdPattern", "정규식", "예: ^[0-9]{4}$ 또는 ^8[0-9]{3}$", "화면 ID 검증·창 제목 인식", "현재 1Q MAP 어댑터는 숫자 4자리 화면 체계를 사용"],
  ["대상 창", "targetProfile.window.className/titlePrefix", "문자열", "대상 메인 창의 Win32 클래스와 제목 접두사 지정", "탐색·입력 경계·녹화", "둘 중 하나 이상 필수"],
  ["MAP", "targetProfile.map", "installationRoot/screenDirectory/filePattern", "설치 루트와 {screenNumber} 포함 MAP 패턴 지정", "정적 화면 모델", "screenDirectory 상대 경로는 설치 루트 기준"],
  ["계좌", "accounts[].id", "고유 문자열", "예: account-test-002", "결과의 계좌 ID", "계좌마다 중복되지 않게 지정"],
  ["계좌", "accounts[].accountNumber", "계좌번호 문자열", "Explicit 입력 때 실제 값 지정", "활성 화면 전체", "결과에는 마스킹·지문으로 저장"],
  ["계좌", "accounts[].owner", "문자열", "예금주 표시명 지정", "결과 문서", "테스트 계좌 식별용"],
  ["계좌", "accounts[].inputMode", "Prefilled | Explicit", "기본값 사용은 Prefilled, 자동 입력은 Explicit", "계좌·비밀번호 입력 방식", "Explicit에는 locator/secret 필요"],
  ["계좌", "accounts[].passwordSecret", "{provider,key}", "평문 대신 환경변수 이름 등 비밀 키 지정", "Explicit 비밀번호 입력", "JSON에 평문 비밀번호 저장 금지"],
  ["계좌", "accounts[].enabled", "true | false", "실행 포함 여부 지정", "케이스 조합", "false는 조합에서 제외"],
  ["계좌", "accounts[].metadata", "문자열 맵", "계좌 유형·비고 등 확장 정보 추가", "추적·향후 조건 분기", "임의 키 확장 가능"],
  ["화면", "screens[].screenNumber", "targetProfile 정규식과 맞는 문자열", `현재 실행 예: ${exampleScreenNumber}`, "대상 화면 ID", "실제 접근 권한과 MAP 존재 확인"],
  ["화면", "screens[].screenName", "문자열", "업무 화면명 지정", "리포트 표시", "실제 제목과 대응되게 작성"],
  ["화면", "screens[].enabled", "true | false", "실행 포함 여부 지정", "케이스 조합", "false는 실행하지 않음"],
  ["화면", "screens[].queryTrigger", "현재 지원값: F12", "조회 실행 트리거를 지정", "각 값 변경 후 조회", "활성 조회 버튼을 먼저 찾고, 미발견 시 F12 사용"],
  ["화면", "screens[].locators", "역할별 locator 객체", "account/password/query 등 역할에 로케이터 추가", "컨트롤 재식별", "가능한 한 텍스트+종류+상대영역을 조합"],
  ["화면", "screens[].fixedConditions", "이름-값 맵", "화면에서 항상 유지할 고정 조건 지정", "모든 해당 화면 케이스", "변수 조합과 충돌하지 않게 작성"],
  ["화면", "screens[].expectedPopupPatterns", "문자열/정규식 배열", "정상 안내 팝업 문구 패턴 지정", "팝업 예상 여부", "오류 문구를 정상 패턴으로 숨기지 않도록 주의"],
  ["변수", "variables[].name", "고유 문자열", "예: 기준일자, 거래구분, 전체선택", "결과의 변수명", "화면 내 의미가 드러나게 작성"],
  ["변수", "variables[].targetRole", "역할 문자열", "예: tradeDate, tradeType, selectAll", "로케이터 매칭", "화면 locator 역할과 일치"],
  ["변수", "variables[].controlKind", "Auto/Text/Date/ComboBox/RadioButton/CheckBox/Tab/Button/ListBox/ListView/TreeView/Slider/Spin", "실제 컨트롤 종류 지정", "종류별 실행기", "잘못 지정하면 PENDING 가능"],
  ["변수", "variables[].valueMatch", "Value | DisplayText | Index | Checked", "값 입력, 표시문자 선택, 순번 선택, 체크 상태 매칭 방식 지정", "입력·선택 방식", "콤보는 DisplayText/Index, 체크박스는 Checked 권장"],
  ["변수", "variables[].values[]", "{id,value,displayValue}", "가능한 값을 배열로 모두 추가", "각 값이 별도 테스트 조합", "id는 고유, 표시값은 사람이 읽는 값"],
  ["기대 결과", "values[].expectedOutcome.type", "Unspecified | Success | ValidationAllowed | ValidationRequired | FailureRequired | NoDataAllowed | WarningAllowed | ObservationOnly", "입력값의 의도와 정상 반응을 값마다 지정", "팝업·화면·로그 판정", "ValidationRequired/FailureRequired는 근거 패턴 또는 코드를 반드시 지정"],
  ["기대 결과", "values[].expectedOutcome.messagePatterns", "정규식 문자열 배열", "예: 종목코드오류|등록되지 않은 종목코드", "관찰 문구와 기대 반응 일치", "시스템 장애 문구는 ValidationAllowed로 숨겨지지 않음"],
  ["기대 결과", "values[].expectedOutcome.errorCodes", "오류코드 문자열 배열", "예: 90019", "HTS 공식 오류코드 기대값", "FailureRequired 같은 명시적 음성 시나리오에 사용"],
  ["기대 결과", "values[].expectedOutcome.queryShouldComplete", "true | false | 생략", "조회 완료 여부까지 계약할 때 지정", "입력 검증 후 조회 차단 확인", "true인데 조회를 실행하지 못하면 QUERY_EXPECTATION_NOT_EXECUTED PENDING"],
  ["자동 기대 근거", "expectedOutcome.source", "InstallationInputOption | InstallationMaster | MapValidation | MapBehavior | RuntimeChoice | GeneratedBoundary 등", "실행기가 설치 파일과 MAP에서 자동 기록", "선택지테스트·판정이벤트", "사용자가 보통 직접 작성하지 않으며 명시 Dataset 계약이 최우선"],
  ["자동 기대 근거", "expectedOutcome.confidence", "High | Medium | Low | Unspecified", "원문 입력 사전·조건식 연결 수준에 따라 자동 산정", "자동 판정 신뢰도", "Unspecified 반응은 PENDING 정책 적용"],
  ["자동 기대 근거", "expectedOutcome.evidence", "문자열 배열", "설치 파일·MAP 규칙 ID·조건식·런타임 선택지 출처를 기록", "감사·재현 근거", "자동 생성된 근거를 임의 삭제하지 않음"],
  ["변수", "variables[].appliesToScreens", "화면번호 배열", "해당 값이 적용될 화면만 나열", "케이스 조합 범위", "빈 배열의 의미는 스키마 정책 확인"],
  ["변수", "variables[].sensitive", "true | false", "민감 값이면 true", "리포트 마스킹", "비밀번호 등은 반드시 true"],
  ["변수", "variables[].required", "true | false", "필수 입력 여부 지정", "계획 검증", "필수 값 미지정은 실행 전 오류"],
  ["변수", "variables[].triggerQueryAfterChange", "true | false", "값 변경 직후 조회 실행 여부", "오라클 연결", "조회성 입력은 true 권장"],
  ["값 형식", "Date 값", "yyyyMMdd", "예: 20260803", "날짜 컨트롤", "년/월/일 8자리 형식"],
  ["값 형식", "CheckBox 값", "문자열 true/false, 1/0, Y/N, checked/unchecked", "체크/미체크 값을 문자열로 values[]에 추가", "두 상태 테스트", "RuleVariableValue.value는 항상 JSON 문자열"],
  ["값 형식", "RadioButton 값", "표시문자 또는 index", "전체/매도/매수처럼 모든 선택지를 추가", "선택지별 조회", "같은 그룹의 각 항목을 별도 값으로 지정"],
  ["값 형식", "ComboBox 값", "DisplayText | Index", "아래 목록을 열어 각 항목을 values[]에 추가", "목록 항목별 조회", "동적 항목은 실행기 발견값과 병합"],
  ["로케이터", "automationId/nameRegex/className/controlType", "문자열", "안정적인 속성을 아는 만큼 지정", "컨트롤 후보 필터", "하나만 믿지 말고 복합 조건 권장"],
  ["로케이터", "ordinal", "0 이상의 정수", "같은 조건의 몇 번째 컨트롤인지 지정", "후보 선택", "화면 변경 시 순번 변동 가능"],
  ["로케이터", "relativeRegion", "top | middle | bottom", "대상 화면 세로 비율 기반 탐색 구간 지정", "후보 창 필터", "top≤45%, middle=25~75%, bottom≥55%"],
  ["로케이터", "relativeX/relativeY/width/height", "0 이상의 정수 픽셀, width/height는 양수", "대상 화면 좌상단 기준 중심 좌표와 클릭 범위 지정", "위치 기반 보조 탐색", "relativeX와 relativeY는 반드시 함께 지정"],
  ["조합 규칙", "활성 화면 × 실행 컨텍스트 × 적용 변수 값", "카테시안 곱", "accounts가 비어 있으면 default 컨텍스트 한 건을 자동 사용", "caseId 생성", "폭증 방지를 위해 maxExpandedCases 점검"],
  ["검증 명령", "dotnet run --project .\\src\\HtsQa.Cli -c Release --no-build -- validate-rule-dataset --file <dataset.json>", "PowerShell", "저장소 루트에서 실행", "스키마·조합 오류 사전 확인", "실제 사용할 데이터셋 경로 지정"],
  ["예시", "정상 종목코드", "{\"id\":\"005930\",\"value\":\"005930\",\"expectedOutcome\":{\"type\":\"Success\"}}", "values[]에 추가", "정상 조회 시나리오", "입력 검증이 나타나면 FAIL"],
  ["예시", "잘못된 종목코드", "{\"id\":\"invalid\",\"value\":\"99999999\",\"expectedOutcome\":{\"type\":\"ValidationRequired\",\"messagePatterns\":[\"종목코드오류|등록되지 않은 종목코드\"],\"queryShouldComplete\":false}}", "values[]에 추가", "음성 입력 검증 시나리오", "지정 검증이 나타나면 PASS, 나타나지 않으면 FAIL"],
  ["예시", "CheckBox 변수", "{\"name\":\"전체선택\",\"controlKind\":\"CheckBox\",\"valueMatch\":\"Checked\",\"values\":[{\"id\":\"on\",\"value\":\"true\"},{\"id\":\"off\",\"value\":\"false\"}]}", "variables[]에 객체로 추가", "체크/미체크 모두 실행", "triggerQueryAfterChange 설정"],
];
inputGuideRows.unshift(
  ["자동 실행 진입점", "scripts/run-auto-scenario-pipeline.ps1", "PowerShell", "-AllowElevatedActionPrompt로 실행하고 UAC 한 번 승인", "MAP 추출부터 녹화 실행·Excel까지", "-StaticOnly는 HTS 미조작, -PrepareOnly는 실제 시나리오 동작 미실행"],
  ["자동 시나리오 원본", "<자동실행폴더>/generated-rule-scenarios.json", "프로그램 생성 계약 JSON", "MAP·런타임 탐색·데이터셋에서 자동 생성", "기본 시나리오 계획", "수동 편집 금지; 생성기/버전/SHA-256 추적"],
  ["선택적 외부 원본", "data/scenarios/inbox/<generationId>/generated-scenarios.json", "ChatGPT 등 외부 생성 계약 JSON", "import-generated-scenarios 명령으로 수입", "도메인 특화 확장 시나리오", "자동 정책 승인 대상이 아니며 사람 승인 필요"],
  ["승인 오버레이", "data/scenarios/approvals/*.approval.json", "Resolved/AcceptedGap/Approve/Reject/Deferred", "생성 원본 SHA-256에 연결해 결정만 기록", "컴파일·실행 허용 여부", "원본과 분리 유지"],
  ["컴파일 계획", "artifacts/plans/<planId>/compiled-plan.json", "자동 생성 JSON", "plan-scenarios 명령으로 생성", "Binding Plan-only와 실행기", "수동 편집 금지"],
  ["물리 계획", "artifacts/bindings/<planId>/physical-plan.json", "자동 생성 JSON", "plan-scenario-bindings.ps1로 생성", "실제 HTS 실행 허용 목록", "현재 설치 fingerprint와 일치해야 함"],
);
writeGuideSheet(inputGuideSheet, "추가 입력 데이터 작성·확장 안내", ["구분", "JSON 위치/필드", "형식·허용값", "입력 방법", "적용 범위", "주의사항"], inputGuideRows, [18, 58, 50, 47, 38, 46]);

// 저장 전에 수식 오류와 주요 범위를 검사해 손상된 보고서가 정상 산출물로 남지 않게 한다.
const inspect = await workbook.inspect({
  kind: "table",
  range: `테스트결과!A1:AE${Math.min(12, resultRows.length + 1)}`,
  include: "values,formulas",
  tableMaxRows: 12,
  tableMaxCols: 31,
  maxChars: 12000,
});
console.log(inspect.ndjson);
const installationInspect = await workbook.inspect({
  kind: "region",
  sheetId: "설치카탈로그",
  range: `A1:F${Math.min(24, installationCatalogRows.length + 4)}`,
  maxChars: 12000,
});
console.log(installationInspect.ndjson);
const errors = await workbook.inspect({
  kind: "match",
  searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A",
  options: { useRegex: true, maxResults: 100 },
  summary: "최종 수식 오류 검사",
});
console.log(errors.ndjson);

for (const [sheetName, range] of [
  ["요약", "A1:H21"],
  ["테스트결과", `A1:AE${Math.min(15, resultRows.length + 1)}`],
  ["단계결과", `A1:J${Math.min(15, actionRows.length + 1)}`],
  ["입력변수", `A1:E${Math.min(15, variableRows.length + 1)}`],
  ["컨트롤계획", `A1:AF${Math.min(15, controlRows.length + 1)}`],
  ["선택지테스트", `A1:Z${Math.min(15, controlTestRows.length + 1)}`],
  ["팝업관찰", `A1:Q${Math.min(15, popupRows.length + 1)}`],
  ["자동화미완료", `A1:H${Math.min(15, incompleteValues.length + 1)}`],
  ["오류스크린샷", errorResults.length ? "A1:L24" : "A1:L5"],
  ["컬럼설명", `A1:F${columnGuideRows.length + 4}`],
  ["오류판정기준", `A1:H${errorGuideRows.length + 4}`],
  ["테스트모듈로직", `A1:F${pipelineRows.length + 4}`],
  ["입력데이터안내", `A1:F${inputGuideRows.length + 4}`],
  ["설치카탈로그", `A1:F${Math.min(60, installationCatalogRows.length + 4)}`],
  ["판정이벤트", `A1:R${Math.min(15, oracleEventRows.length + 1)}`],
  ["시나리오계획", `A1:N${Math.min(20, scenarioRows.length + 4)}`],
  ["컨트롤바인딩", `A1:Q${Math.min(20, bindingRows.length + 4)}`],
  ["승인및제외", `A1:H${Math.min(20, approvalRows.length + 4)}`],
]) {
  const preview = await workbook.render({ sheetName, range, scale: 1, format: "png" });
  await outputManager.writePreview(sheetName, preview);
}

// 검사가 끝난 워크북만 XLSX로 내보내고 검사 로그를 곁에 보존한다.
const output = await SpreadsheetFile.exportXlsx(workbook);
const outputPath = await outputManager.saveXlsx(output);
await outputManager.finalizeInspection(outputPath);
return { outputPath, sheetNames: viewModel.sheetNames, statuses: results.map((result) => result.status) };
}
