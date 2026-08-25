// 역할: 사용자가 직접 수행한 mouse interaction과 전후 native frame을 Discovery 전용 계약으로 표현한다.
// 입력/출력: low-level hook event, WinEvent, HWND inventory, hit-test, visual hash와 suggestion을 NDJSON으로 교환한다.
// 경계: keyboard 문자열, 현재 control 값, screenshot pixel, 자동 action, verdict 또는 repository 승인을 담지 않는다.
// 수정 지점: recorder PowerShell adapter, JSON schema와 PassiveInteractionRecorderTests를 함께 변경한다.
namespace HtsQa.FlaUi;

public sealed class PassivePointerObservation
{
    public long Sequence { get; set; }
    public DateTimeOffset ObservedAt { get; set; }
    public string Button { get; set; } = string.Empty;
    public string Phase { get; set; } = string.Empty;
    public int X { get; set; }
    public int Y { get; set; }
    public bool Injected { get; set; }
}

public sealed class PassiveWindowEventObservation
{
    public long Sequence { get; set; }
    public DateTimeOffset ObservedAt { get; set; }
    public string EventName { get; set; } = string.Empty;
    public uint EventId { get; set; }
    public long Hwnd { get; set; }
    public int ObjectId { get; set; }
    public int ChildId { get; set; }
    public int ProcessId { get; set; }
    public int ThreadId { get; set; }
}

public sealed class PassiveVisualSignature
{
    public bool Available { get; set; }
    public string ErrorCode { get; set; } = string.Empty;
    public int Columns { get; set; }
    public int Rows { get; set; }
    public string PerceptualHash { get; set; } = string.Empty;
    public IReadOnlyList<string> BlockHashes { get; set; } = Array.Empty<string>();
    public bool PixelDataStored { get; set; }
}

public sealed class NativeInteractionWindowSnapshot
{
    public long Hwnd { get; set; }
    public long ParentHwnd { get; set; }
    public long OwnerHwnd { get; set; }
    public long RootHwnd { get; set; }
    public int ProcessId { get; set; }
    public int ThreadId { get; set; }
    public int Depth { get; set; }
    public int ZOrder { get; set; }
    public string ClassName { get; set; } = string.Empty;
    public int ControlId { get; set; }
    public long Style { get; set; }
    public long ExtendedStyle { get; set; }
    public bool IsVisible { get; set; }
    public bool IsEnabled { get; set; }
    public bool IsDescendant { get; set; }
    public bool IsOwnedPopup { get; set; }
    public bool IsPopup { get; set; }
    public ElementRectangle Bounds { get; set; } = new();
    public NormalizedRectangle NormalizedBounds { get; set; } = new();
    public string SpatialRegion { get; set; } = "Unclassified";
    public string NativeTextHash { get; set; } = string.Empty;
    public int NativeTextLength { get; set; }
    public string NativeSignature { get; set; } = string.Empty;
    public IReadOnlyList<long> AncestorHwnds { get; set; } = Array.Empty<long>();
}

public sealed class InteractionHitTargetSnapshot
{
    public bool InsideTarget { get; set; }
    public long WindowFromPointHwnd { get; set; }
    public long ChildWindowFromPointHwnd { get; set; }
    public long RealChildWindowFromPointHwnd { get; set; }
    public long PrimaryHwnd { get; set; }
    public long ParentHwnd { get; set; }
    public string NativeSignature { get; set; } = string.Empty;
    public string ClassName { get; set; } = string.Empty;
    public int ControlId { get; set; }
    public CapturePoint ScreenPoint { get; set; } = new();
    public CapturePoint RootClientPoint { get; set; } = new();
    public CapturePoint RegionRelativePoint { get; set; } = new();
    public CapturePoint ParentClientPoint { get; set; } = new();
    public double NormalizedRootX { get; set; }
    public double NormalizedRootY { get; set; }
    public double NormalizedRegionX { get; set; }
    public double NormalizedRegionY { get; set; }
    public double NormalizedParentX { get; set; }
    public double NormalizedParentY { get; set; }
    public string SpatialRegion { get; set; } = "Unclassified";
    public IReadOnlyList<long> CandidateHwnds { get; set; } = Array.Empty<long>();
    public IReadOnlyList<long> AncestorHwnds { get; set; } = Array.Empty<long>();
}

public sealed class NativeInteractionFrameSnapshot
{
    public string SchemaVersion { get; set; } = "1.0";
    public string ArtifactRole { get; set; } = "Discovery";
    public string InteractionRole { get; set; } = "ObservedManualInteraction";
    public bool TestExecution { get; set; }
    public bool VerdictEligible { get; set; }
    public bool ResultEvaluatorInvoked { get; set; }
    public string? CanonicalVerdict { get; set; }
    public string? ScenarioId { get; set; }
    public string? CaseId { get; set; }
    public long RootHwnd { get; set; }
    public int ProcessId { get; set; }
    public long ForegroundHwnd { get; set; }
    public long FocusHwnd { get; set; }
    public ElementRectangle RootBounds { get; set; } = new();
    public ElementRectangle RootClientBounds { get; set; } = new();
    public uint Dpi { get; set; }
    public IReadOnlyList<LayoutRegionHint> RegionHints { get; set; } = Array.Empty<LayoutRegionHint>();
    public DateTimeOffset ObservedAt { get; set; }
    public string LayoutFingerprint { get; set; } = string.Empty;
    public string StateFingerprint { get; set; } = string.Empty;
    public IReadOnlyList<long> PopupHwnds { get; set; } = Array.Empty<long>();
    public IReadOnlyList<NativeInteractionWindowSnapshot> Windows { get; set; } = Array.Empty<NativeInteractionWindowSnapshot>();
    public InteractionHitTargetSnapshot? HitTarget { get; set; }
    public PassiveVisualSignature VisualSignature { get; set; } = new();
    public int ActionSentCount { get; set; }
    public int TransactionalActionCount { get; set; }
}

public sealed class InteractionPropertyChange
{
    public long Hwnd { get; set; }
    public string Property { get; set; } = string.Empty;
    public string Before { get; set; } = string.Empty;
    public string After { get; set; } = string.Empty;
}

public sealed class InteractionVisualDiff
{
    public bool Available { get; set; }
    public int ChangedBlockCount { get; set; }
    public int TotalBlockCount { get; set; }
    public double ChangedPixelRatioEstimate { get; set; }
    public NormalizedRectangle ChangedRectangle { get; set; } = new();
    public string BeforePerceptualHash { get; set; } = string.Empty;
    public string AfterPerceptualHash { get; set; } = string.Empty;
}

public sealed class InteractionFrameDelta
{
    public IReadOnlyList<long> NewHwnds { get; set; } = Array.Empty<long>();
    public IReadOnlyList<long> DisappearedHwnds { get; set; } = Array.Empty<long>();
    public IReadOnlyList<long> PopupCreatedHwnds { get; set; } = Array.Empty<long>();
    public IReadOnlyList<long> PopupClosedHwnds { get; set; } = Array.Empty<long>();
    public IReadOnlyList<InteractionPropertyChange> Changes { get; set; } = Array.Empty<InteractionPropertyChange>();
    public bool ForegroundChanged { get; set; }
    public bool FocusChanged { get; set; }
    public bool StateFingerprintChanged { get; set; }
    public bool SelectionEventObserved { get; set; }
    public bool UnstablePostState { get; set; }
    public InteractionVisualDiff VisualDiff { get; set; } = new();
}

public sealed class InteractionSuggestion
{
    public string InferredRole { get; set; } = "other-selectable-control";
    public string InferredActionKind { get; set; } = "ObserveClick";
    public double Confidence { get; set; }
    public bool Ambiguous { get; set; } = true;
    public bool TransactionalRiskCandidate { get; set; }
    public IReadOnlyList<string> Evidence { get; set; } = Array.Empty<string>();
}

public sealed class ObservedInteractionSnapshot
{
    public string SchemaVersion { get; set; } = "1.0";
    public string ArtifactRole { get; set; } = "Discovery";
    public string InteractionRole { get; set; } = "ObservedManualInteraction";
    public bool UserPerformed { get; set; } = true;
    public bool Automated { get; set; }
    public bool TestExecution { get; set; }
    public bool VerdictEligible { get; set; }
    public bool ResultEvaluatorInvoked { get; set; }
    public string? CanonicalVerdict { get; set; }
    public string? ScenarioId { get; set; }
    public string? CaseId { get; set; }
    public string InteractionId { get; set; } = string.Empty;
    public int Sequence { get; set; }
    public DateTimeOffset StartedAt { get; set; }
    public DateTimeOffset CompletedAt { get; set; }
    public string Button { get; set; } = string.Empty;
    public bool DoubleClick { get; set; }
    public CapturePoint ClickPoint { get; set; } = new();
    public InteractionHitTargetSnapshot HitTarget { get; set; } = new();
    public string PreStateFingerprint { get; set; } = string.Empty;
    public string PostStateFingerprint { get; set; } = string.Empty;
    public string PreFrameReference { get; set; } = string.Empty;
    public string PostFrameReference { get; set; } = string.Empty;
    public InteractionFrameDelta Delta { get; set; } = new();
    public IReadOnlyList<PassiveWindowEventObservation> WindowEvents { get; set; } = Array.Empty<PassiveWindowEventObservation>();
    public InteractionSuggestion Suggestion { get; set; } = new();
    public int ActionSentCount { get; set; }
    public int TransactionalActionCount { get; set; }
}

public sealed class InteractionZoneCandidate
{
    public string ZoneId { get; set; } = string.Empty;
    public string Status { get; set; } = "ReviewRequired";
    public long ParentHwnd { get; set; }
    public string NativeSignature { get; set; } = string.Empty;
    public string ClassName { get; set; } = string.Empty;
    public string SpatialRegion { get; set; } = "Unclassified";
    public double CenterX { get; set; }
    public double CenterY { get; set; }
    public int ObservationCount { get; set; }
    public string RoleSuggestion { get; set; } = string.Empty;
    public string ActionKindSuggestion { get; set; } = string.Empty;
    public double Confidence { get; set; }
    public bool AutomaticallyApproved { get; set; }
    public bool Executable { get; set; }
    public IReadOnlyList<string> InteractionIds { get; set; } = Array.Empty<string>();
}
