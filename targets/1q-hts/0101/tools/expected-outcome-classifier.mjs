/**
 * 0101 workbook 행을 Core의 기존 RuleExpectedOutcomeType 계약으로 분류한다.
 * 구조화된 mode를 우선하며, 텍스트는 이전 데이터 마이그레이션을 위한 보수적 fallback으로만 사용한다.
 */

export const RULE_EXPECTED_OUTCOME_TYPES = Object.freeze([
  "Unspecified",
  "Success",
  "ValidationAllowed",
  "ValidationRequired",
  "FailureRequired",
  "NoDataAllowed",
  "WarningAllowed",
  "ObservationOnly",
]);

const canonicalModes = new Map(RULE_EXPECTED_OUTCOME_TYPES.map((type) => [type.toLowerCase(), type]));
canonicalModes.set("pending", "Unspecified");
canonicalModes.set("review", "Unspecified");

const text = (value) => String(value ?? "").trim();

export function isStructuredErrorCode(value) {
  const candidate = text(value);
  return /^(?:[A-Z][A-Z0-9]*(?:[_-][A-Z0-9]+)+|[A-Z]{1,10}[-_.]?\d[A-Z0-9_.-]*|-?\d{2,10})$/i.test(candidate);
}

function structuredClassification(structuredMode) {
  const supplied = text(structuredMode);
  if (!supplied) return null;
  const type = canonicalModes.get(supplied.toLowerCase());
  if (!type) {
    return {
      type: "Unspecified",
      method: "StructuredMode",
      reason: `unsupported-structured-mode:${supplied}`,
      confidence: "Unspecified",
    };
  }
  return {
    type,
    method: "StructuredMode",
    reason: type === "Unspecified" ? `explicit-${supplied.toLowerCase()}` : `explicit-${type}`,
    confidence: type === "Unspecified" ? "Unspecified" : "High",
  };
}

export function classifyExpectedOutcome(input = {}) {
  const structured = structuredClassification(input.structuredMode);
  if (structured) return structured;

  const expectedResult = text(input.expectedResult);
  const rawInput = text(input.rawInput);
  const context = [input.title, input.category, input.subcategory, input.procedure, rawInput, expectedResult]
    .map(text)
    .filter(Boolean)
    .join(" ");
  const errorCodes = Array.isArray(input.errorCodes) ? input.errorCodes.filter(isStructuredErrorCode) : [];
  const placeholders = rawInput.match(/<[^>]+>/g) ?? [];
  const nonPlaceholderInput = rawInput.replace(/<[^>]+>/g, "").trim();
  const compositePlaceholder = placeholders.length > 0 &&
    (placeholders.length > 1 || nonPlaceholderInput.length > 0 || placeholders.some((value) => /[\/,]/.test(value)));
  if (compositePlaceholder) {
    return {
      type: "Unspecified", method: "TextFallback", reason: "composite-placeholder-requires-expansion", confidence: "Unspecified",
    };
  }

  const invalidIntent = /(?:<[^>]*(?:공백|미선택|min\s*-\s*1|max\s*\+\s*1|허용\s*길이\s*[+-]\s*1|invalid|유효하지)[^>]*>|무입력|미입력|공백\s*(?:입력|값|제출)?|필수[^ ]*\s*(?:누락|미선택)|형식[^ ]*\s*(?:오류|위반|불일치)|길이[^ ]*\s*(?:초과|미달|위반)|허용\s*범위[^ ]*\s*(?:초과|밖)|범위[^ ]*\s*(?:초과|밖|미달)|유효하지\s*않|잘못된|미등록|존재하지\s*않|없는\s*코드|invalid\s*(?:code|value)?|min\s*-\s*1|max\s*\+\s*1)/i.test(context);
  const validationExpected = /(?:차단|거부|불가|허용하지|검증|오류|에러|경고|팝업|메시지|미실행|실행되지|전송되지|진행되지)/i.test(expectedResult);
  if (invalidIntent && (validationExpected || errorCodes.length > 0)) {
    return { type: "ValidationRequired", method: "TextFallback", reason: "explicit-invalid-input-requires-validation", confidence: errorCodes.length > 0 ? "High" : "Medium" };
  }

  const boundaryIntent = /(?:경계|최소|최대|하한|상한|임계|min|max)/i.test(context);
  const genuinelyAlternative = /(?:허용|성공|정상)\s*(?:또는|혹은|\/)\s*(?:거부|차단|검증|오류)|(?:거부|차단|검증|오류)\s*(?:또는|혹은|\/)\s*(?:허용|성공|정상)|(?:조건|환경|정책)에\s*따라\s*(?:허용|거부|성공|검증)|어느\s*쪽(?:도|이든)/i.test(context);
  if (boundaryIntent && genuinelyAlternative) {
    return { type: "ValidationAllowed", method: "TextFallback", reason: "genuinely-ambiguous-boundary", confidence: "Medium" };
  }

  const observationIntent = /(?:관찰|확인만|초기\s*상태|기본\s*(?:상태|렌더링)|렌더링|표시\s*상태|활성\s*\/\s*비활성|노출\s*\/\s*숨김|UI\s*상태|MAP[^ ]*\s*일치)/i.test(context);
  const businessOutcome = /(?:RQ|TR|조회|주문|결과\s*반영|호출|전송|정상\s*처리|성공|완료)/i.test(expectedResult);
  if (observationIntent && !businessOutcome) {
    return { type: "ObservationOnly", method: "TextFallback", reason: "observation-purpose-only", confidence: "Medium" };
  }

  const explicitNormalInput = /(?:정상|유효한|승인된)\s*(?:값|입력|데이터|계좌|계좌비밀번호|응답|종목)?/i.test([rawInput, input.procedure].map(text).join(" "));
  const explicitBusinessSuccess = /(?:정상(?:적으로|\s*입력|\s*응답|\s*처리|\s*진행|\s*조회(?:가)?\s*완료)|성공(?:적으로)?|조회(?:가)?\s*완료|처리\s*완료|업무\s*(?:처리|결과)[^.;]*(?:완료|반영))/i.test(expectedResult);
  const normalInputBusinessResult = explicitNormalInput && /(?:결과\s*(?:반영|표시)|조회\s*완료|처리\s*완료|정상\s*응답)/i.test(expectedResult);
  const successIntent = explicitBusinessSuccess || normalInputBusinessResult;
  if (!invalidIntent && successIntent) {
    return { type: "Success", method: "TextFallback", reason: "explicit-normal-business-outcome", confidence: "Medium" };
  }

  return {
    type: "Unspecified",
    method: "TextFallback",
    reason: expectedResult ? "insufficient-expectation-evidence" : "missing-expected-result",
    confidence: "Unspecified",
  };
}
