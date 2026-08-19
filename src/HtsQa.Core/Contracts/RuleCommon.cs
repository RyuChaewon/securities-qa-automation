// 역할: 모든 Core 책임이 공유하는 JSON 직렬화 규칙과 최소 상태·검증 계약을 정의한다.
// 입력/출력: 도메인 객체를 안정적인 JSON 문자열 열거형과 ValidationResult 형태로 교환한다.
// 경계: 이 폴더에는 특정 HTS나 특정 실행 단계의 정책을 두지 않는다.
// 수정 지점: 열거형 이름은 저장된 JSON 계약이므로 변경 시 데이터 마이그레이션과 회귀 테스트가 필요하다.
using System.Text.Json;
using System.Text.Json.Serialization;

namespace HtsQa.Core;

public static class JsonDefaults
{
    public static readonly JsonSerializerOptions Options = Create();

    private static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            WriteIndented = true,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
        };
        options.Converters.Add(new JsonStringEnumConverter());
        return options;
    }
}

public enum TestStatus { PASS, FAIL, ERROR, PENDING }

public sealed record ValidationIssue(
    string Code,
    string Message,
    string? StepId = null,
    string? Field = null,
    string Severity = "ERROR",
    string? Remediation = null);

public sealed record ValidationResult(bool IsValid, IReadOnlyList<ValidationIssue> Issues)
{
    public static ValidationResult Pass() => new(true, Array.Empty<ValidationIssue>());
    public static ValidationResult Fail(params ValidationIssue[] issues) => new(false, issues);
}
