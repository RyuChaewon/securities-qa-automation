// 역할: PowerShell 실행기와 FlaUI UIA3 자식 프로세스가 NDJSON으로 교환하는 요청·응답 계약을 정의한다.
// 입력/출력: 창·요소 selector와 동작 요청을 받고 재식별 정보, 지원 패턴, 검증 결과와 오류 코드를 반환한다.
// 경계: 계약은 UI 프레임워크 중립 데이터만 담고 FlaUI 객체나 HWND 수명 객체를 외부로 노출하지 않는다.
// 수정 지점: 필드 이름은 PowerShell 소비 코드와 호환되므로 양쪽 파서 및 브리지 테스트를 함께 변경한다.
using System.Text.Json.Serialization;

namespace HtsQa.FlaUi;

/// <summary>
/// PowerShell 실행기가 NDJSON 한 줄로 보내는 UIA3 요청이다.
/// 한 계약 안에서 상태 확인, 요소 탐색, 실제 패턴 동작을 구분한다.
/// </summary>
public sealed class BridgeRequest
{
    /// <summary>요청과 응답을 실행 로그에서 연결하는 식별자다.</summary>
    public string RequestId { get; set; } = Guid.NewGuid().ToString("N");

    /// <summary>ping, observeState, discover, action 중 실행할 연산이다.</summary>
    public string Operation { get; set; } = string.Empty;

    /// <summary>탐색과 조작을 이 HWND의 UIA 하위 트리로 제한한다.</summary>
    public long RootHwnd { get; set; }

    /// <summary>action 연산에서 동작 직전 요소를 다시 찾는 선택자다.</summary>
    public ElementSelector? Selector { get; set; }

    /// <summary>setText, invoke, setChecked, selectIndex 등의 의미 동작이다.</summary>
    public string? Action { get; set; }

    /// <summary>텍스트, 선택 표시값, 범위값처럼 문자열로 전달할 값이다.</summary>
    public string? Value { get; set; }

    /// <summary>민감 입력은 readback과 응답·snapshot 기록에서 평문을 제거한다.</summary>
    public bool Sensitive { get; set; }

    /// <summary>콤보·목록·탭 선택 순번이다.</summary>
    public int? Index { get; set; }

    /// <summary>체크박스의 목표 체크 상태다.</summary>
    public bool? Checked { get; set; }

    /// <summary>pressKey 계열 동작에서 사용할 키 이름이다.</summary>
    public string? Key { get; set; }

    /// <summary>captureCandidate에서 호출자가 읽은 현재 cursor 화면 점이다. 엔진은 cursor를 이동하거나 클릭하지 않는다.</summary>
    public CapturePoint? CapturePoint { get; set; }

    /// <summary>captureCandidate가 의미를 추정하지 않고 보존할 adapter 제공 상태 문맥이다.</summary>
    public string? StateContext { get; set; }

    /// <summary>captureCandidate가 의미를 추정하지 않고 보존할 adapter 제공 MAP 문맥이다.</summary>
    public string? MapScreenCode { get; set; }

    /// <summary>캡처 좌표의 승인 기준 host 종류다.</summary>
    public string? CoordinateSpace { get; set; }

    /// <summary>controlRepositoryPreflight에서 현재 client rect에 다시 적용할 승인 normalized 좌표다.</summary>
    public double? RelativeX { get; set; }
    public double? RelativeY { get; set; }
    public int TimeoutMs { get; set; } = 10000;
    public int MaxDepth { get; set; } = 16;
    public int MaxElements { get; set; } = 5000;
    public bool IncludeCurrentValues { get; set; }
    public bool IncludeValueMetadata { get; set; } = true;
    public bool IncludeOffscreen { get; set; }
    public bool IncludeInvisible { get; set; }
    public bool IncludeContainers { get; set; } = true;
    public IReadOnlyList<LayoutRegionHint> RegionHints { get; set; } = Array.Empty<LayoutRegionHint>();
    public IReadOnlyList<SensitiveControlHint> SensitiveControlHints { get; set; } = Array.Empty<SensitiveControlHint>();

}

/// <summary>
/// UIA RuntimeId를 우선 사용하고 HWND·AutomationId·좌표를 차례로 보완하는 재식별 정보다.
/// </summary>
public sealed class ElementSelector
{
    public string? RuntimeId { get; set; }
    public long NativeWindowHandle { get; set; }
    public string? AutomationId { get; set; }
    public string? Name { get; set; }
    public string? ClassName { get; set; }
    public string? ControlType { get; set; }
    public ElementRectangle? Bounds { get; set; }

}

/// <summary>hover 보조 도구가 읽은 일회성 cursor 화면 점이다. repository locator에는 저장되지 않는다.</summary>
public sealed class CapturePoint
{
    public int X { get; set; }
    public int Y { get; set; }
}

/// <summary>PowerShell과 좌표 체계를 공유하는 화면 절대 좌표 사각형이다.</summary>
public sealed class ElementRectangle
{
    public int Left { get; set; }
    public int Top { get; set; }
    public int Right { get; set; }
    public int Bottom { get; set; }
    public int Width => Math.Max(0, Right - Left);
    public int Height => Math.Max(0, Bottom - Top);
}

/// <summary>탐색 시점의 UIA3 요소 속성과 사용 가능한 의미 동작을 보존한다.</summary>
public sealed class ElementSnapshot
{
    public string RuntimeId { get; set; } = string.Empty;
    public long NativeWindowHandle { get; set; }
    public string AutomationId { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string ClassName { get; set; } = string.Empty;
    public string ControlType { get; set; } = string.Empty;
    public string FrameworkType { get; set; } = string.Empty;
    public bool IsEnabled { get; set; }
    public bool IsOffscreen { get; set; }
    public bool IsKeyboardFocusable { get; set; }
    public ElementRectangle Bounds { get; set; } = new();
    public IReadOnlyList<string> SupportedActions { get; set; } = Array.Empty<string>();
    public IReadOnlyList<ElementOptionSnapshot> Options { get; set; } = Array.Empty<ElementOptionSnapshot>();
    public int? SelectedIndex { get; set; }
    public string CurrentValue { get; set; } = string.Empty;
    public double? Minimum { get; set; }
    public double? Maximum { get; set; }
}

/// <summary>콤보·목록·탭에서 FlaUI가 읽은 실제 선택 후보 한 건이다.</summary>
public sealed class ElementOptionSnapshot
{
    public int Index { get; set; }
    public string Name { get; set; } = string.Empty;
    public string RuntimeId { get; set; } = string.Empty;
    public bool IsSelected { get; set; }
}

/// <summary>상태 의미를 추정하지 않고 현재 루트 창의 소유권, DPI와 fingerprint만 기록하는 읽기 전용 snapshot이다.</summary>
public sealed class StateWindowSnapshot
{
    public string ProcessName { get; set; } = string.Empty;
    public long RootHwnd { get; set; }
    public int ProcessId { get; set; }
    public string RuntimeId { get; set; } = string.Empty;
    public string AutomationId { get; set; } = string.Empty;
    public string ClassName { get; set; } = string.Empty;
    public string FrameworkType { get; set; } = string.Empty;
    public bool IsEnabled { get; set; }
    public bool IsOffscreen { get; set; }
    public ElementRectangle Bounds { get; set; } = new();
    public uint Dpi { get; set; }
    public string WindowFingerprint { get; set; } = string.Empty;
    public DateTimeOffset ObservedAt { get; set; }
}

/// <summary>cursor 이동·click 없이 만든 redacted Control Repository 검토 후보다.</summary>
public sealed class ControlCaptureSnapshot
{
    public string SchemaVersion { get; set; } = "1.0";
    public string Status { get; set; } = "ReviewRequired";
    public long RootHwnd { get; set; }
    public int ProcessId { get; set; }
    public string ProcessName { get; set; } = string.Empty;
    public string ProcessFingerprint { get; set; } = string.Empty;
    public string HostFingerprint { get; set; } = string.Empty;
    public string StateContext { get; set; } = string.Empty;
    public string MapScreenCode { get; set; } = string.Empty;
    public string CoordinateSpace { get; set; } = "ScreenClient";
    public int ClientWidth { get; set; }
    public int WindowWidth { get; set; }
    public int WindowHeight { get; set; }
    public int ClientHeight { get; set; }
    public double RelativeX { get; set; }
    public double RelativeY { get; set; }
    public uint Dpi { get; set; }
    public double DpiScale { get; set; }
    public IReadOnlyList<string> RedactedIdentityCandidates { get; set; } = Array.Empty<string>();
    public string ExpectedControlKindCandidate { get; set; } = string.Empty;
    public string VisualSignatureHash { get; set; } = string.Empty;
    public IReadOnlyList<string> RedactionsApplied { get; set; } = Array.Empty<string>();
    public bool CursorMoved { get; set; }
    public bool ClickSent { get; set; }
    public bool AutomaticallyApproved { get; set; }
    public DateTimeOffset CapturedAt { get; set; }
}

/// <summary>
/// 모든 브리지 응답의 공통 모양이다. FallbackRequired가 true이면 호출자가 기록 후
/// 기존 Win32 경로를 사용할 수 있지만, UIA3 성공을 가장하지는 않는다.
/// </summary>
/// <summary>물리 action 전에 현재 client rect/DPI와 hit-test를 다시 읽은 read-only 증거다.</summary>
public sealed class ControlRepositoryPreflightSnapshot
{
    public string SchemaVersion { get; set; } = "1.0";
    public string Status { get; set; } = "Observed";
    public long RootHwnd { get; set; }
    public int ProcessId { get; set; }
    public string ProcessName { get; set; } = string.Empty;
    public string ProcessFingerprint { get; set; } = string.Empty;
    public string HostFingerprint { get; set; } = string.Empty;
    public string StateContext { get; set; } = string.Empty;
    public string MapScreenCode { get; set; } = string.Empty;
    public double RelativeX { get; set; }
    public double RelativeY { get; set; }
    public ElementRectangle CurrentClientRect { get; set; } = new();
    public CapturePoint ResolvedScreenPoint { get; set; } = new();
    public uint Dpi { get; set; }
    public double DpiScale { get; set; }
    public IReadOnlyList<string> ObservedAnchorIds { get; set; } = Array.Empty<string>();
    public string ObservedControlKind { get; set; } = string.Empty;
    public string ObservedVisualSignatureHash { get; set; } = string.Empty;
    public bool CursorMoved { get; set; }
    public bool ClickSent { get; set; }
    public DateTimeOffset ObservedAt { get; set; }
}

public sealed class BridgeResponse
{

    public string RequestId { get; set; } = string.Empty;
    public bool Success { get; set; }
    public bool Verified { get; set; }
    public bool ActionSent { get; set; }
    public bool ActionVerified { get; set; }
    public bool FallbackRequired { get; set; }
    public string Engine { get; set; } = FlaUiAutomationEngine.EngineName;
    public string EngineVersion { get; set; } = FlaUiAutomationEngine.EngineVersion;
    public string Pattern { get; set; } = string.Empty;
    public string ErrorCode { get; set; } = string.Empty;
    public string Message { get; set; } = string.Empty;
    public string ObservedValue { get; set; } = string.Empty;
    public IReadOnlyList<ElementSnapshot> Elements { get; set; } = Array.Empty<ElementSnapshot>();
    public StateWindowSnapshot? StateObservation { get; set; }
    public ControlCaptureSnapshot? CaptureCandidate { get; set; }
    public ControlRepositoryPreflightSnapshot? ControlRepositoryPreflight { get; set; }
    public LayoutDiscoverySnapshot? LayoutDiscovery { get; set; }

    /// <summary>프로토콜 수준 예외를 일관된 실패 응답으로 변환한다.</summary>
    public static BridgeResponse Failure(BridgeRequest request, string code, string message, bool fallback = false) => new()
    {
        RequestId = request.RequestId,
        Success = false,
        Verified = false,
        ActionSent = false,
        ActionVerified = false,
        FallbackRequired = fallback,
        ErrorCode = code,
        Message = message
    };
}

/// <summary>프로토콜의 JSON 이름을 camelCase로 고정하는 소스 생성 컨텍스트다.</summary>
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = true,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(BridgeRequest))]
[JsonSerializable(typeof(BridgeResponse))]
internal partial class BridgeJsonContext : JsonSerializerContext;
