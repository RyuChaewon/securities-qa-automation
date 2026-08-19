/** TC_ID를 최상위 키로 실행 결과와 단계 증거를 별도 XLSX로 만든다. */
import fs from "node:fs/promises";
import path from "node:path";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const [reportDirArg, outputFileArg = "TC실행결과.xlsx"] = process.argv.slice(2);
if (!reportDirArg) throw new Error("사용법: node build-tc-results-workbook.mjs <리포트-폴더> [출력파일명]");
const reportDir = path.resolve(reportDirArg);
const xmlSafeText = (value) => String(value ?? "").replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/g, "");
const readJson = async (name, fallback = null) => {
  try { return JSON.parse((await fs.readFile(path.join(reportDir, name), "utf8")).replace(/^\uFEFF/, ""), (_key, value) => typeof value === "string" ? xmlSafeText(value) : value); }
  catch (error) { if (fallback !== null) return fallback; throw error; }
};
const asArray = (value) => Array.isArray(value) ? value : value ? [value] : [];
const summary = await readJson("summary.json", {});
const results = asArray(await readJson("case-results.json", []));
const compiledPlan = await readJson("compiled-plan.json", { cases: [] });
const tcResults = results.filter((result) => result.sourceTestCaseId);
const resultCaseIds = new Set(tcResults.map((result) => result.caseId));
const notRun = asArray(compiledPlan.cases).filter((item) => item.sourceTestCaseId && !resultCaseIds.has(item.caseId));
if (!tcResults.length && !notRun.length) throw new Error("TC_ID가 있는 실행 결과 또는 컴파일 계획이 없습니다.");

const workbook = Workbook.create();
const overview = workbook.worksheets.add("요약");
const resultSheet = workbook.worksheets.add("TC실행결과");
const stepSheet = workbook.worksheets.add("TC단계결과");
const notRunSheet = workbook.worksheets.add("미실행TC");
const analysisSheet = workbook.worksheets.add("결과분석");
const visualSheet = workbook.worksheets.add("시각화");
const colors = { navy: "#17324D", teal: "#0F766E", pale: "#E6F2F2", line: "#CBD5E1", white: "#FFFFFF", text: "#17202A", pass: "#DCFCE7", fail: "#FEE2E2", pending: "#FEF3C7" };

function columnName(index) {
  let value = index + 1;
  let name = "";
  while (value > 0) { value -= 1; name = String.fromCharCode(65 + (value % 26)) + name; value = Math.floor(value / 26); }
  return name;
}

function writeTable(sheet, headers, rows, tableName, widths) {
  const lastColumn = columnName(headers.length - 1);
  sheet.showGridLines = false;
  sheet.getRange(`A1:${lastColumn}1`).values = [headers];
  sheet.getRange(`A1:${lastColumn}1`).format = { fill: colors.navy, font: { bold: true, color: colors.white }, verticalAlignment: "center", wrapText: true, borders: { preset: "outside", style: "thin", color: colors.line } };
  sheet.getRange(`A1:${lastColumn}1`).format.rowHeight = 32;
  if (rows.length) {
    sheet.getRangeByIndexes(1, 0, rows.length, headers.length).values = rows;
    sheet.getRange(`A2:${lastColumn}${rows.length + 1}`).format = { font: { color: colors.text, size: 10 }, verticalAlignment: "top", wrapText: true, borders: { insideHorizontal: { style: "thin", color: "#E2E8F0" } } };
    sheet.tables.add(`A1:${lastColumn}${rows.length + 1}`, true, tableName).style = "TableStyleMedium2";
  } else {
    sheet.getRange("A2").values = [["해당 항목이 없습니다."]];
  }
  widths.forEach((width, index) => { sheet.getRange(`${columnName(index)}:${columnName(index)}`).format.columnWidth = width; });
  sheet.freezePanes.freezeRows(1);
  sheet.freezePanes.freezeColumns(1);
}

const resultHeaders = ["TC_ID", "시나리오ID", "케이스ID", "상태", "우선순위", "분류", "내부화면코드", "주문/전송", "계좌", "단계수", "PASS", "FAIL", "PENDING", "기대결과", "실제결과", "오류코드", "자동화계약오류", "외부중단", "오류메시지", "스크린샷", "시작", "종료", "경과(ms)", "조작전략", "좌표포커스단계", "좌표포커스검증"];
const resultRows = tcResults.map((result) => {
  const steps = asArray(result.controlTests);
  return [
    result.sourceTestCaseId, result.scenarioId, result.caseId, result.status, result.scenarioPriority, result.scenarioCategory,
    result.mapScreenCode, result.transactional ? "Y" : "N", result.accountMasked ?? "", steps.length,
    steps.filter((step) => step.status === "PASS").length, steps.filter((step) => step.status === "FAIL").length,
    steps.filter((step) => step.status === "PENDING").length, result.expectedResult ?? "", result.outputSummary ?? "",
    result.errorCode ?? "", result.automationContractFailure ? "Y" : "N", result.externalInterruption ? "Y" : "N",
    result.errorMessage ?? "", result.screenshotPath ?? "", result.startedAt ? new Date(result.startedAt) : null,
    result.endedAt ? new Date(result.endedAt) : null, Number(result.elapsedMs ?? 0), result.interactionStrategy ?? "",
    steps.filter((step) => step.coordinateFocusUsed).length, steps.filter((step) => step.coordinateFocusVerified).length,
  ];
});
writeTable(resultSheet, resultHeaders, resultRows, "TcExecutionResults", [18, 24, 20, 11, 10, 18, 16, 11, 15, 9, 9, 9, 10, 48, 48, 24, 14, 12, 48, 32, 20, 20, 13, 19, 15, 15]);
if (resultRows.length) {
  resultSheet.getRange(`D2:D${resultRows.length + 1}`).conditionalFormats.add("containsText", { text: "PASS", format: { fill: colors.pass, font: { bold: true, color: "#166534" } } });
  resultSheet.getRange(`D2:D${resultRows.length + 1}`).conditionalFormats.add("containsText", { text: "FAIL", format: { fill: colors.fail, font: { bold: true, color: "#991B1B" } } });
  resultSheet.getRange(`D2:D${resultRows.length + 1}`).conditionalFormats.add("containsText", { text: "ERROR", format: { fill: "#F3E8FF", font: { bold: true, color: "#6B21A8" } } });
  resultSheet.getRange(`D2:D${resultRows.length + 1}`).conditionalFormats.add("containsText", { text: "PENDING", format: { fill: colors.pending, font: { bold: true, color: "#92400E" } } });
  resultSheet.getRange(`U2:V${resultRows.length + 1}`).format.numberFormat = "yyyy-mm-dd hh:mm:ss";
  resultSheet.getRange(`J2:M${resultRows.length + 1}`).format.numberFormat = "#,##0";
  resultSheet.getRange(`W2:W${resultRows.length + 1}`).format.numberFormat = "#,##0";
  resultSheet.getRange(`Y2:Z${resultRows.length + 1}`).format.numberFormat = "#,##0";
}

const stepHeaders = ["TC_ID", "케이스ID", "순서", "동작", "내부화면코드", "상태컨텍스트", "주문/전송", "컨트롤ID", "종류", "이름", "상태", "입력값", "표시값", "기대관찰", "실제관찰", "오류코드", "검증엔진", "재식별근거", "스크린샷", "경과(ms)", "조작전략", "좌표포커스사용", "좌표포커스검증"];
const stepRows = tcResults.flatMap((result) => asArray(result.controlTests).map((step) => [
  result.sourceTestCaseId, result.caseId, Number(step.scenarioSequence ?? 0), step.scenarioAction ?? "", step.mapScreenCode ?? result.mapScreenCode ?? "",
  step.stateContext ?? "", step.transactional ? "Y" : "N", step.controlId ?? "", step.controlKind ?? "", step.controlName ?? "", step.status ?? "",
  step.inputValue ?? "", step.displayValue ?? "", step.expectedObservation ?? "", step.output ?? "", step.errorCode ?? "", step.automationEngine ?? "",
  step.bindingResolution ? `${step.bindingResolution.mode ?? ""}: ${asArray(step.bindingResolution.evidence).join(" | ")}` : "",
  step.screenshotPath ?? "", Number(step.elapsedMs ?? 0), step.interactionStrategy ?? result.interactionStrategy ?? "",
  step.coordinateFocusUsed ? "Y" : "N", step.coordinateFocusVerified ? "Y" : "N",
]));
writeTable(stepSheet, stepHeaders, stepRows, "TcStepResults", [18, 20, 9, 18, 16, 24, 11, 28, 14, 24, 11, 22, 22, 48, 48, 26, 20, 52, 32, 13, 19, 15, 15]);
if (stepRows.length) {
  stepSheet.getRange(`K2:K${stepRows.length + 1}`).conditionalFormats.add("containsText", { text: "PASS", format: { fill: colors.pass, font: { color: "#166534" } } });
  stepSheet.getRange(`K2:K${stepRows.length + 1}`).conditionalFormats.add("containsText", { text: "FAIL", format: { fill: colors.fail, font: { color: "#991B1B" } } });
  stepSheet.getRange(`K2:K${stepRows.length + 1}`).conditionalFormats.add("containsText", { text: "PENDING", format: { fill: colors.pending, font: { color: "#92400E" } } });
  stepSheet.getRange(`C2:C${stepRows.length + 1}`).format.numberFormat = "#,##0";
  stepSheet.getRange(`T2:T${stepRows.length + 1}`).format.numberFormat = "#,##0";
}

const notRunHeaders = ["TC_ID", "시나리오ID", "케이스ID", "준비상태", "차단사유", "내부화면코드", "주문/전송", "기대결과"];
const notRunRows = notRun.map((item) => [item.sourceTestCaseId, item.scenarioId, item.caseId, item.readiness, asArray(item.blockingReasons).join(" | "), item.mapScreenCode, item.transactional ? "Y" : "N", item.expectedResult ?? ""]);
writeTable(notRunSheet, notRunHeaders, notRunRows, "TcNotRunResults", [18, 24, 20, 18, 52, 16, 11, 52]);

const statusOrder = ["PASS", "FAIL", "ERROR", "PENDING"];
const stepStatusOrder = ["PASS", "FAIL", "PENDING"];
const actionNames = [...new Set(stepRows.map((row) => String(row[3] ?? "")).filter(Boolean))]
  .sort((left, right) => stepRows.filter((row) => row[3] === right).length - stepRows.filter((row) => row[3] === left).length || left.localeCompare(right, "ko"));
const mapStats = new Map();
for (const item of asArray(compiledPlan.cases)) {
  const code = String(item.mapScreenCode ?? "미지정");
  const current = mapStats.get(code) ?? { planned: 0 };
  current.planned += 1;
  mapStats.set(code, current);
}
const errorStats = new Map();
for (const result of tcResults) {
  if (result.errorCode) errorStats.set(result.errorCode, (errorStats.get(result.errorCode) ?? 0) + 1);
  for (const step of asArray(result.controlTests)) {
    if (step.errorCode) errorStats.set(step.errorCode, (errorStats.get(step.errorCode) ?? 0) + 1);
  }
}
const topErrors = [...errorStats.entries()].sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0])).slice(0, 10);

analysisSheet.showGridLines = false;
analysisSheet.mergeCells("A1:L2");
analysisSheet.getRange("A1").values = [["0101 실행 결과 분석"]];
analysisSheet.getRange("A1:L2").format = { fill: colors.navy, font: { bold: true, color: colors.white, size: 18 }, verticalAlignment: "center" };
analysisSheet.getRange("A4:B4").values = [["핵심 지표", "값"]];
analysisSheet.getRange("A4:B4").format = { fill: colors.teal, font: { bold: true, color: colors.white } };
analysisSheet.getRange("A5:A10").values = [["전체 계획 TC"], ["실행 TC"], ["실행률"], ["TC 통과율"], ["단계 통과율"], ["미실행 TC"]];
analysisSheet.getRange("B5:B10").formulas = [
  [`=${asArray(compiledPlan.cases).length}`],
  [resultRows.length ? `=COUNTA('TC실행결과'!$A$2:$A$${resultRows.length + 1})` : "=0"],
  ["=IFERROR(B6/B5,0)"],
  [resultRows.length ? `=IFERROR(COUNTIF('TC실행결과'!$D$2:$D$${resultRows.length + 1},\"PASS\")/B6,0)` : "=0"],
  [stepRows.length ? `=IFERROR(COUNTIF('TC단계결과'!$K$2:$K$${stepRows.length + 1},\"PASS\")/COUNTA('TC단계결과'!$K$2:$K$${stepRows.length + 1}),0)` : "=0"],
  [notRunRows.length ? `=COUNTA('미실행TC'!$A$2:$A$${notRunRows.length + 1})` : "=0"],
];
analysisSheet.getRange("A5:B10").format = { borders: { insideHorizontal: { style: "thin", color: colors.line }, bottom: { style: "thin", color: colors.line } } };
analysisSheet.getRange("B5:B6").format.numberFormat = "#,##0";
analysisSheet.getRange("B7:B9").format.numberFormat = "0.0%";
analysisSheet.getRange("B10").format.numberFormat = "#,##0";

analysisSheet.getRange("D4:E4").values = [["좌표 포커스", "값"]];
analysisSheet.getRange("D4:E4").format = { fill: colors.teal, font: { bold: true, color: colors.white } };
analysisSheet.getRange("D5:D7").values = [["사용 단계"], ["검증 성공"], ["검증률"]];
analysisSheet.getRange("E5:E7").formulas = [
  [stepRows.length ? `=COUNTIF('TC단계결과'!$V$2:$V$${stepRows.length + 1},"Y")` : "=0"],
  [stepRows.length ? `=COUNTIFS('TC단계결과'!$V$2:$V$${stepRows.length + 1},"Y",'TC단계결과'!$W$2:$W$${stepRows.length + 1},"Y")` : "=0"],
  ["=IFERROR(E6/E5,0)"],
];
analysisSheet.getRange("E5:E6").format.numberFormat = "#,##0";
analysisSheet.getRange("E7").format.numberFormat = "0.0%";

analysisSheet.getRange("A12:B12").values = [["TC 상태", "건수"]];
analysisSheet.getRange("A12:B12").format = { fill: "#334155", font: { bold: true, color: colors.white } };
analysisSheet.getRange("A13:A16").values = statusOrder.map((status) => [status]);
analysisSheet.getRange("B13:B16").formulas = statusOrder.map((status) => [resultRows.length ? `=COUNTIF('TC실행결과'!$D$2:$D$${resultRows.length + 1},\"${status}\")` : "=0"]);
analysisSheet.getRange("D12:E12").values = [["단계 상태", "건수"]];
analysisSheet.getRange("D12:E12").format = { fill: "#334155", font: { bold: true, color: colors.white } };
analysisSheet.getRange("D13:D15").values = stepStatusOrder.map((status) => [status]);
analysisSheet.getRange("E13:E15").formulas = stepStatusOrder.map((status) => [stepRows.length ? `=COUNTIF('TC단계결과'!$K$2:$K$${stepRows.length + 1},\"${status}\")` : "=0"]);

analysisSheet.getRange("A19:E19").values = [["주요 동작", "전체", "PASS", "FAIL", "PENDING"]];
analysisSheet.getRange("A19:E19").format = { fill: colors.teal, font: { bold: true, color: colors.white } };
const topActions = actionNames.slice(0, 12);
if (topActions.length) {
  analysisSheet.getRangeByIndexes(19, 0, topActions.length, 1).values = topActions.map((name) => [name]);
  analysisSheet.getRangeByIndexes(19, 1, topActions.length, 4).values = topActions.map((name) => {
    const matching = stepRows.filter((row) => row[3] === name);
    return [
      matching.length,
      matching.filter((row) => row[10] === "PASS").length,
      matching.filter((row) => row[10] === "FAIL").length,
      matching.filter((row) => row[10] === "PENDING").length,
    ];
  });
} else {
  analysisSheet.getRange("A20").values = [["실행 단계 없음"]];
}

analysisSheet.getRange("G4:L4").values = [["MAP", "계획", "실행", "PASS", "FAIL/ERROR", "PENDING"]];
analysisSheet.getRange("G4:L4").format = { fill: colors.teal, font: { bold: true, color: colors.white } };
const mapRows = [...mapStats.entries()].sort((left, right) => left[0].localeCompare(right[0]));
if (mapRows.length) {
  analysisSheet.getRangeByIndexes(4, 6, mapRows.length, 2).values = mapRows.map(([code, stat]) => [code, stat.planned]);
  analysisSheet.getRangeByIndexes(4, 8, mapRows.length, 4).formulas = mapRows.map((_entry, index) => {
    const row = index + 5;
    return [
      resultRows.length ? `=COUNTIF('TC실행결과'!$G$2:$G$${resultRows.length + 1},G${row})` : "=0",
      resultRows.length ? `=COUNTIFS('TC실행결과'!$G$2:$G$${resultRows.length + 1},G${row},'TC실행결과'!$D$2:$D$${resultRows.length + 1},\"PASS\")` : "=0",
      resultRows.length ? `=COUNTIFS('TC실행결과'!$G$2:$G$${resultRows.length + 1},G${row},'TC실행결과'!$D$2:$D$${resultRows.length + 1},\"FAIL\")+COUNTIFS('TC실행결과'!$G$2:$G$${resultRows.length + 1},G${row},'TC실행결과'!$D$2:$D$${resultRows.length + 1},\"ERROR\")` : "=0",
      resultRows.length ? `=COUNTIFS('TC실행결과'!$G$2:$G$${resultRows.length + 1},G${row},'TC실행결과'!$D$2:$D$${resultRows.length + 1},\"PENDING\")` : "=0",
    ];
  });
}

analysisSheet.getRange("G27:H27").values = [["오류/보류 코드", "발생"]];
analysisSheet.getRange("G27:H27").format = { fill: "#7C2D12", font: { bold: true, color: colors.white } };
if (topErrors.length) analysisSheet.getRangeByIndexes(27, 6, topErrors.length, 2).values = topErrors;
else analysisSheet.getRange("G28:H28").values = [["감지 없음", 0]];

const insightRows = [];
if (!resultRows.length) insightRows.push(["실행 결과", "실행된 TC가 없어 통과율 분석은 보류합니다."]);
else {
  const passCount = tcResults.filter((result) => result.status === "PASS").length;
  const pendingCount = tcResults.filter((result) => result.status === "PENDING").length;
  const defectCount = tcResults.filter((result) => ["FAIL", "ERROR"].includes(result.status)).length;
  insightRows.push(["TC 판정", `실행 ${resultRows.length}건 중 PASS ${passCount}건, FAIL/ERROR ${defectCount}건, PENDING ${pendingCount}건입니다.`]);
  insightRows.push(["실행 범위", `전체 ${asArray(compiledPlan.cases).length}건 중 ${resultRows.length}건을 실행했고 ${notRunRows.length}건은 미실행으로 분리했습니다.`]);
  insightRows.push(["주문/전송", `실행 결과에 주문/전송 TC ${tcResults.filter((result) => result.transactional).length}건이 포함됐습니다.`]);
}
analysisSheet.getRange("A34:F34").values = [["분석 항목", "해석", "", "", "", ""]];
analysisSheet.getRange("A34:F34").format = { fill: "#334155", font: { bold: true, color: colors.white } };
insightRows.forEach((row, index) => {
  const excelRow = 35 + index;
  analysisSheet.mergeCells(`B${excelRow}:F${excelRow}`);
  analysisSheet.getRange(`A${excelRow}:B${excelRow}`).values = [[row[0], row[1]]];
});
analysisSheet.getRange("A1:L40").format.wrapText = true;
analysisSheet.getRange("A:A").format.columnWidth = 21;
analysisSheet.getRange("B:B").format.columnWidth = 15;
analysisSheet.getRange("C:F").format.columnWidth = 13;
analysisSheet.getRange("G:G").format.columnWidth = 18;
analysisSheet.getRange("H:L").format.columnWidth = 13;
analysisSheet.freezePanes.freezeRows(2);

visualSheet.showGridLines = false;
visualSheet.mergeCells("A1:L2");
visualSheet.getRange("A1").values = [["0101 실행 결과 시각화"]];
visualSheet.getRange("A1:L2").format = { fill: colors.navy, font: { bold: true, color: colors.white, size: 18 }, verticalAlignment: "center" };
visualSheet.getRange("A4:B4").values = [["TC 상태", "건수"]];
visualSheet.getRange("A5:A8").formulas = statusOrder.map((_status, index) => [`='결과분석'!A${13 + index}`]);
visualSheet.getRange("B5:B8").formulas = statusOrder.map((_status, index) => [`='결과분석'!B${13 + index}`]);
visualSheet.getRange("D4:E4").values = [["실행 범위", "건수"]];
visualSheet.getRange("D5:D6").values = [["실행"], ["미실행"]];
visualSheet.getRange("E5:E6").formulas = [["='결과분석'!B6"], ["='결과분석'!B10"]];
visualSheet.getRange("G4:H4").values = [["단계 상태", "건수"]];
visualSheet.getRange("G5:G7").formulas = stepStatusOrder.map((_status, index) => [`='결과분석'!D${13 + index}`]);
visualSheet.getRange("H5:H7").formulas = stepStatusOrder.map((_status, index) => [`='결과분석'!E${13 + index}`]);
visualSheet.getRange("J4:K4").values = [["주요 동작", "건수"]];
const visualActionCount = Math.min(8, topActions.length);
if (visualActionCount) {
  visualSheet.getRangeByIndexes(4, 9, visualActionCount, 1).formulas = Array.from({ length: visualActionCount }, (_unused, index) => [`='결과분석'!A${20 + index}`]);
  visualSheet.getRangeByIndexes(4, 10, visualActionCount, 1).formulas = Array.from({ length: visualActionCount }, (_unused, index) => [`='결과분석'!B${20 + index}`]);
} else {
  visualSheet.getRange("J5:K5").values = [["실행 단계 없음", 0]];
}
for (const range of ["A4:B8", "D4:E6", "G4:H7", `J4:K${Math.max(5, visualActionCount + 4)}`]) {
  visualSheet.getRange(range).format = { borders: { preset: "all", style: "thin", color: colors.line }, wrapText: true };
}
for (const range of ["A4:B4", "D4:E4", "G4:H4", "J4:K4"]) visualSheet.getRange(range).format = { fill: colors.teal, font: { bold: true, color: colors.white }, borders: { preset: "all", style: "thin", color: colors.line } };
const statusChart = visualSheet.charts.add("bar", visualSheet.getRange("A4:B8"));
statusChart.title = "TC 상태 분포 (건)";
statusChart.hasLegend = false;
statusChart.setPosition("A11", "F23");
const scopeChart = visualSheet.charts.add("bar", visualSheet.getRange("D4:E6"));
scopeChart.title = "전체 계획 대비 실행 범위 (건)";
scopeChart.hasLegend = false;
scopeChart.setPosition("G11", "L23");
const stepChart = visualSheet.charts.add("bar", visualSheet.getRange("G4:H7"));
stepChart.title = "검증 단계 상태 (건)";
stepChart.hasLegend = false;
stepChart.setPosition("A25", "F37");
const actionChart = visualSheet.charts.add("bar", visualSheet.getRange(`J4:K${Math.max(5, visualActionCount + 4)}`));
actionChart.title = "주요 자동화 동작 빈도 (건)";
actionChart.hasLegend = false;
actionChart.setPosition("G25", "L37");
visualSheet.getRange("A:L").format.columnWidth = 12;
visualSheet.freezePanes.freezeRows(2);

overview.showGridLines = false;
overview.mergeCells("A1:H2");
overview.getRange("A1").values = [["0101 TC 중심 테스트 실행결과"]];
overview.getRange("A1:H2").format = { fill: colors.navy, font: { bold: true, color: colors.white, size: 18 }, verticalAlignment: "center" };
overview.getRange("A4:B4").values = [["지표", "값"]];
overview.getRange("A4:B4").format = { fill: colors.teal, font: { bold: true, color: colors.white } };
overview.getRange("A5:A11").values = [["실행 TC"], ["PASS"], ["FAIL"], ["ERROR"], ["PENDING"], ["주문/전송 TC"], ["미실행 TC"]];
const resultEnd = Math.max(2, resultRows.length + 1);
const resultFormulas = resultRows.length ? [
  `=COUNTA('TC실행결과'!$A$2:$A$${resultEnd})`,
  `=COUNTIF('TC실행결과'!$D$2:$D$${resultEnd},"PASS")`,
  `=COUNTIF('TC실행결과'!$D$2:$D$${resultEnd},"FAIL")`,
  `=COUNTIF('TC실행결과'!$D$2:$D$${resultEnd},"ERROR")`,
  `=COUNTIF('TC실행결과'!$D$2:$D$${resultEnd},"PENDING")`,
  `=COUNTIF('TC실행결과'!$H$2:$H$${resultEnd},"Y")`,
] : ["=0", "=0", "=0", "=0", "=0", "=0"];
const notRunFormula = notRunRows.length ? `=COUNTA('미실행TC'!$A$2:$A$${notRunRows.length + 1})` : "=0";
overview.getRange("B5:B11").formulas = [...resultFormulas, notRunFormula].map((formula) => [formula]);
overview.getRange("A5:B11").format = { borders: { insideHorizontal: { style: "thin", color: colors.line }, bottom: { style: "thin", color: colors.line } } };
overview.getRange("B5:B11").format.numberFormat = "#,##0";
overview.getRange("A13:H16").merge();
overview.getRange("A13").values = [[`실행 ID: ${summary.runId ?? "미실행"}\n데이터셋: ${summary.datasetId ?? compiledPlan.datasetId ?? ""}\n좌표 포커스 검증: ${Number(summary.coordinateFocusVerified ?? 0)}/${Number(summary.coordinateFocusSteps ?? 0)}단계\n판정은 각 TC의 실제 Assert 단계와 실행 로그를 기준으로 집계합니다.`]];
overview.getRange("A13:H16").format = { fill: colors.pale, font: { color: colors.text }, wrapText: true, verticalAlignment: "center", rowHeight: 20, borders: { preset: "outside", style: "thin", color: colors.line } };
overview.getRange("A:A").format.columnWidth = 22;
overview.getRange("B:B").format.columnWidth = 14;
overview.getRange("C:H").format.columnWidth = 14;
const chart = overview.charts.add("bar", overview.getRange("A5:B9"));
chart.title = "TC 상태 분포";
chart.hasLegend = false;
chart.setPosition("D4", "H11");

const formulaErrors = await workbook.inspect({ kind: "match", searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A", options: { useRegex: true, maxResults: 100 }, summary: "TC report formula scan" });
if (/"matchCount"\s*:\s*[1-9]/.test(formulaErrors.ndjson)) throw new Error(`수식 오류가 있습니다: ${formulaErrors.ndjson}`);
const previewRanges = { "요약": "A1:H17", "TC실행결과": "A1:Z25", "TC단계결과": "A1:W25", "미실행TC": "A1:H25", "결과분석": "A1:L40", "시각화": "A1:L38" };
for (const sheetName of ["요약", "TC실행결과", "TC단계결과", "미실행TC", "결과분석", "시각화"]) {
  const preview = await workbook.render({ sheetName, range: previewRanges[sheetName], scale: sheetName === "요약" ? 1.2 : 0.7, format: "png" });
  await fs.writeFile(path.join(reportDir, `tc-report-preview-${sheetName}.png`), new Uint8Array(await preview.arrayBuffer()));
}
const outputPath = path.join(reportDir, outputFileArg);
const output = await SpreadsheetFile.exportXlsx(workbook);
await output.save(outputPath);
console.log(outputPath);
