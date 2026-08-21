/**
 * 역할: 검증된 JSON source를 한국어 workbook의 순수 표시 모델로 변환한다.
 * 경계: TestResult status를 읽기만 하며 상태 집계나 재판정을 수행하지 않는다.
 */
import path from "node:path";

export const RULE_RESULTS_SHEET_NAMES = [
  "컬럼설명", "오류판정기준", "테스트모듈로직", "입력데이터안내", "설치카탈로그", "시나리오계획",
  "컨트롤바인딩", "승인및제외", "요약", "테스트결과", "단계결과", "입력변수", "컨트롤계획",
  "선택지테스트", "팝업관찰", "판정이벤트", "자동화미완료", "오류스크린샷",
];

const statusLabel = (status) => ({ PASS: "통과", FAIL: "실패", ERROR: "오류", PENDING: "대기" })[status] ?? status ?? "";
const scenarioReadinessLabel = (value) => ({ ReadyForBinding: "바인딩 준비", PendingBinding: "바인딩 대기", PendingApproval: "승인 대기", ManualReview: "수동 검토", Rejected: "실행 거부", Invalid: "무효" })[value] ?? value ?? "";
const bindingStatusLabel = (value) => ({ BoundHigh: "높은 신뢰도로 결합", BoundMedium: "중간 신뢰도로 결합", Ambiguous: "후보 모호", Unbound: "미결합" })[value] ?? value ?? "";
const confidenceLabel = (value) => ({ High: "높음", Medium: "중간", Low: "낮음", Unspecified: "미지정" })[value] ?? value ?? "";
const reviewSeverityLabel = (value) => ({ Required: "필수", Recommended: "권고", Informational: "참고" })[value] ?? value ?? "";
const physicalDispositionLabel = (value) => ({ READY: "실행 가능", EXECUTABLE: "실행 가능", PENDING_APPROVAL: "승인 대기", PENDING_BINDING: "바인딩 대기", REJECTED: "실행 거부" })[value] ?? value ?? "";
const approvalStatusLabel = (value) => ({ Approved: "승인 완료", Draft: "승인 초안", NotProvided: "승인 파일 없음" })[value] ?? value ?? "";
const inputModeLabel = (mode) => mode === "Explicit" || mode === "데이터셋 명시 입력" ? "데이터셋 명시 입력" : "화면 기본값";
const excelDate = (value) => value ? new Date(new Date(value).getTime() + (9 * 60 * 60 * 1000)) : null;

const actionLabel = (action) => ({
  openScreen: "화면 열기", usePrefilledInputs: "화면 기본 입력값 사용", setAccount: "계좌번호 입력", setPassword: "비밀번호 입력",
  setCondition: "조건값 입력", invokeQuery: "조회 실행", evaluateExplicitErrors: "명시적 오류 판정", closeScreen: "테스트 화면 닫기",
  dismissDialog: "HTS 대화상자 닫기", recoverMainWindow: "HTS 메인 창 복구", discoverControls: "콘텐츠 컨트롤 발견",
  bindMapModel: "MAP 기준 모델 결합", loadMapErrorOracle: "MAP 오류 오라클 적용", loadMapBehavior: "MAP 동작 모델 적용",
  loadInstallationCatalog: "HTS 설치 카탈로그 적용", rediscoverMapControls: "MAP 컨트롤 동적 재결합", evaluateMapBehavior: "MAP 조회 경로 검증",
  executeControlOptions: "컨트롤 선택지 실행", reopenScreen: "예기치 않은 화면 닫힘 후 다시 열기", restoreControlState: "컨트롤 초기 상태 복원",
  environmentPrecheck: "실행 환경 사전 점검", executor: "실행기",
})[action] ?? action ?? "";

const cleanCollectedLabel = (value, kind = "", index = 0) => {
  const text = String(value ?? "").trim();
  if (/^\?\?\s*\d+$/.test(text) && kind === "Tab") return `탭 ${text.match(/\d+/)?.[0] ?? index + 1} (표시문자 수집 불가)`;
  if (/^\?\?/.test(text)) return text.replace(/^\?\?\s*/, "표시문자 수집 불가: ");
  return text;
};
const hasLegacyEncodingDamage = (value) => (String(value ?? "").match(/\?/g) ?? []).length >= 2 || /[紐泥吏硫留吏吏吏]/.test(String(value ?? ""));
const cleanExecutionDetail = (value, fallback) => {
  const text = String(value ?? "").trim();
  return hasLegacyEncodingDamage(text) ? `${fallback} (기존 실행 상세문은 인코딩 손상으로 대체)` : text;
};
const compactNavigationTargets = (targets) => (Array.isArray(targets) ? targets : []).map((target) => {
  if (typeof target === "string") return target;
  const destination = target?.targetScreenCode || target?.targetMapFile || target?.targetExpression || "동적 대상";
  return `${target?.api || target?.kind || "화면전환"}:${destination}${target?.isDynamic ? "(동적)" : ""}`;
}).filter(Boolean).join(" | ");

const incompleteLabels = {
  PLAN_ONLY: "계획 전용 실행", CONTROL_STALE: "컨트롤 재탐색 실패", CONTROL_AMBIGUOUS: "컨트롤 재탐색 후보 모호",
  PHYSICAL_BINDING_DRIFT: "물리 바인딩 identity 불일치", CHECK_STATE_UNVERIFIABLE: "체크 상태 검증 불가", HTS_CONNECTION_LOST: "HTS 연결 장애로 중단",
  CONTROL_ACTION_FAILED: "컨트롤 동작 검증 실패", COMBO_NATIVE_LIST_REQUIRED: "콤보 목록 창 확인 불가", COMBO_LIST_NOT_VISIBLE: "콤보 목록 표시 실패",
  COMBO_SELECTION_NOT_APPLIED: "콤보 항목 선택 검증 실패", OPTIONS_NOT_DISCOVERED: "선택지 수집 실패", PENDING_DATA_REQUIRED: "입력 데이터 필요",
  QUERY_BUTTON_NOT_FOUND: "조회 버튼 미발견", INPUT_SCOPE_BLOCKED: "HTS 대상 창 경계 밖 입력 차단", INPUT_GUARD_BLOCKED: "전경·입력 범위 안전 검증 차단",
  SCREEN_SEQUENCE_CLOSE_PENDING: "순차 화면 닫기 미완료", SCREEN_CLOSE_PENDING: "화면 닫기 미완료", PRECONDITION_PENDING: "선행 조건 미완료",
  MAP_MODEL_NOT_FOUND: "MAP 기준 모델 없음", MAP_CONTROL_NOT_BOUND: "MAP 컨트롤 실행 상태 미결합", MAP_QUERY_NOT_EXECUTED: "MAP 조회 경로 미실행",
  MAP_BEHAVIOR_NOT_FOUND: "MAP 동작 모델 없음", INSTALLATION_MODEL_DRIFT: "HTS 설치 파일 무결성 불일치",
};
const incompleteLabel = (code) => incompleteLabels[String(code ?? "")] ?? (String(code ?? "").trim() || "자동화 확인 필요");

function createIncompleteModel(results) {
  const incompleteRows = [];
  const incompleteByCase = new Map();
  for (const result of results) {
    const caseRows = [];
    for (const item of (Array.isArray(result.controlTests) ? result.controlTests : [])) {
      if (item.status !== "PENDING") continue;
      caseRows.push({ caseId: result.caseId ?? "", screenNumber: result.screenNumber ?? "", controlKind: item.controlKind ?? "", controlName: item.controlName ?? "", option: cleanCollectedLabel(item.displayValue ?? item.inputValue, item.controlKind), errorCode: item.errorCode ?? "", reason: incompleteLabel(item.errorCode), detail: cleanExecutionDetail(item.output, incompleteLabel(item.errorCode)) });
    }
    for (const detail of (Array.isArray(result.automationIssues) ? result.automationIssues : [])) {
      const code = String(detail).match(/([A-Z][A-Z0-9_]{2,})\s*$/)?.[1] ?? "AUTOMATION_ISSUE";
      if (caseRows.some((row) => row.errorCode === code && String(detail).includes(row.controlName))) continue;
      caseRows.push({ caseId: result.caseId ?? "", screenNumber: result.screenNumber ?? "", controlKind: "", controlName: "", option: "", errorCode: code, reason: incompleteLabel(code), detail: cleanExecutionDetail(detail, incompleteLabel(code)) });
    }
    incompleteByCase.set(result.caseId ?? "", caseRows);
    incompleteRows.push(...caseRows);
  }
  const incompleteSummary = (caseId) => {
    const groups = new Map();
    for (const row of (incompleteByCase.get(caseId) ?? [])) groups.set(row.reason, (groups.get(row.reason) ?? 0) + 1);
    return [...groups.entries()].map(([reason, count]) => `${reason} ${count}건`).join(" / ");
  };
  return { incompleteRows, incompleteByCase, incompleteSummary };
}

const resultHeaders = [
  "실행 ID", "케이스 ID", "화면번호", "화면명", "입력 방식", "계좌 ID", "계좌번호(마스킹)", "계좌 지문", "예금주", "입력 변수", "상태",
  "제품 결함 여부", "오류 코드", "오류 메시지", "출력 요약", "스크린샷", "시작 시각", "종료 시각", "소요시간(ms)", "미완료 건수",
  "미완료 요약", "상세 시트", "기대 반응 건수", "판정 보류 건수", "시나리오 ID", "시나리오 제목", "우선순위", "분류", "논리 계획 ID", "물리 계획 ID", "시나리오 모드",
];

const portablePath = (value, fallback) => value && !path.isAbsolute(String(value)) ? String(value) : fallback;

export function createRuleResultsWorkbookViewModel(sources) {
  const { summary, results, mapCatalog } = sources;
  const incomplete = createIncompleteModel(results);
  const summaryRows = [
    ["실행 ID", summary.runId ?? ""], ["데이터셋", summary.datasetId ?? ""], ["종합 상태", statusLabel(summary.status)],
    ["실행 구분", summary.executionMode ?? (summary.dryRun ? "드라이런" : "실제 HTS")], ["입력 방식", summary.inputMode ?? "화면 기본값 또는 데이터셋 명시 입력"],
    ["계획 방식", summary.planner ?? "결정론적 규칙"], ["완료 시각", excelDate(summary.finishedAt) ?? ""], ["원본 결과 파일", sources.canonicalSource],
    ["자동화 엔진", `${summary.automationEngine ?? "미기록"} ${summary.automationEngineVersion ?? ""} / 탐색 ${Number(summary.flaUiDiscoveryCalls ?? 0)}회 / 동작 ${Number(summary.flaUiActionSuccesses ?? 0)}/${Number(summary.flaUiActionAttempts ?? 0)}회 / fallback ${Number(summary.flaUiFallbackRequests ?? 0)}회`],
  ];
  const resultRows = results.map((r) => [
    r.runId ?? "", r.caseId ?? "", Number(r.screenNumber ?? 0), r.screenName ?? "", inputModeLabel(r.inputMode), r.accountId ?? "", r.accountMasked ?? "", r.accountFingerprint ?? "", r.accountOwner ?? "",
    JSON.stringify(r.inputVariables ?? {}), statusLabel(r.status), (r.productDefectDetected ?? r.errorDetected) ? "예" : "아니요", r.errorCode ?? "", r.errorMessage ?? "", r.outputSummary ?? "", r.screenshotPath ?? "", excelDate(r.startedAt), excelDate(r.endedAt),
    Number(r.elapsedMs ?? 0), (incomplete.incompleteByCase.get(r.caseId ?? "") ?? []).length, incomplete.incompleteSummary(r.caseId ?? ""), "자동화미완료/판정이벤트", (r.oracleEvents ?? []).filter((item) => item.disposition === "Expected").length,
    (r.oracleEvents ?? []).filter((item) => item.requiresReview).length, r.scenarioId ?? "", r.scenarioTitle ?? "", r.scenarioPriority ?? "", r.scenarioCategory ?? "", r.logicalPlanId ?? "", r.physicalPlanId ?? "", r.scenarioMode ? "예" : "아니요",
  ]);
  const targetInstallationRoot = portablePath(mapCatalog.installationRoot, "targetProfile.map.installationRoot");
  return {
    ...sources, ...incomplete, summaryRows, resultHeaders, resultRows, sheetNames: RULE_RESULTS_SHEET_NAMES,
    targetDisplayName: summary.targetDisplayName ?? "대상 HTS", targetInstallationRoot,
    targetScreenDirectory: portablePath(mapCatalog.screenDirectory, path.join(targetInstallationRoot, "screen")),
    targetMapPattern: mapCatalog.filePattern ?? "targetProfile.map.filePattern",
    exampleScreenNumber: String(results[0]?.screenNumber ?? mapCatalog.requestedScreens?.[0] ?? "0000"),
    statusLabel, scenarioReadinessLabel, bindingStatusLabel, confidenceLabel, reviewSeverityLabel, physicalDispositionLabel,
    approvalStatusLabel, inputModeLabel, actionLabel, cleanCollectedLabel, cleanExecutionDetail, compactNavigationTargets, incompleteLabel, excelDate,
  };
}
