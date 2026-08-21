/**
 * 역할: canonical JSON 로드, workbook view model 구성, XLSX 렌더링과 출력 관리를 순서대로 호출한다.
 * 경계: 이 진입점과 하위 reporter 모듈은 TestResult 판정을 생성하거나 변경하지 않는다.
 */
import { loadRuleResults } from "./reporting/rule-results-loader.mjs";
import { createRuleResultsWorkbookViewModel } from "./reporting/rule-results-view-model.mjs";
import { createRuleReportOutputManager } from "./reporting/rule-report-output-manager.mjs";
import { renderRuleResultsWorkbook } from "./reporting/rule-results-xlsx-renderer.mjs";

const [reportDirArg, outputFileArg = "테스트결과.xlsx"] = process.argv.slice(2);
if (!reportDirArg) throw new Error("사용법: node build-rule-results-workbook.mjs <리포트-폴더> [출력파일]");

const outputManager = createRuleReportOutputManager(reportDirArg, outputFileArg);
const sources = await loadRuleResults(outputManager.reportDir);
const viewModel = createRuleResultsWorkbookViewModel(sources);
const rendered = await renderRuleResultsWorkbook(viewModel, outputManager);
console.log(rendered.outputPath);
process.exit(0);
