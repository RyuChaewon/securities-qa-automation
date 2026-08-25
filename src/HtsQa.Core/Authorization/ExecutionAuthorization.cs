// 역할: 컨트롤 안정 계약과 비운영 환경 실행 scope를 canonical hash로 승인하고 실행 전 fail-closed로 판정한다.
// 경계: UI, 파일 시스템, PowerShell, verdict에 의존하지 않으며 실제 action을 전송하지 않는다.
using System.Globalization;

namespace HtsQa.Core;

public enum ControlTransactionalRole
{
    None,
    OpenConfirmation,
    FinalSubmit,
    AmendSubmit,
    CancelSubmit
}

public enum ExecutionEnvironmentClassification
{
    Unspecified,
    Test,
    Simulation,
    Production
}

public enum ExecutionAccountClassification
{
    Unspecified,
    Test,
    Real
}

public enum ExecutionAuthorizationStatus
{
    Authorized,
    ControlApprovalRequired,
    EnvironmentApprovalRequired,
    AuthorizationExpired,
    ScopeViolation,
    EnvironmentDrift,
    ControlContractDrift,
    ConfigurationRequired,
    InvalidAuthorization
}

public static class ExecutionAuthorizationVersions
{
    public const string ControlContractSchema = "1.0";
    public const string EnvironmentFingerprintSchema = "1.0";
    public const string AuthorizationSchema = "1.0";
    public const string AuthorizationHashAlgorithm = "2.0";
    public const string DecisionSchema = "1.0";
    public const double AnchorTolerance = 0.0025;
}

public sealed record ControlContractPayload
{
    public string SchemaVersion { get; init; } = ExecutionAuthorizationVersions.ControlContractSchema;
    public required string TargetProfileId { get; init; }
    public required string RepositoryKey { get; init; }
    public required string ExpectedControlKind { get; init; }
    public required string BusinessRole { get; init; }
    public ControlTransactionalRole TransactionalRole { get; init; }
    public LocatorTrustTier LocatorTier { get; init; }
    public ControlStableIdentity? StableIdentity { get; init; }
    public ControlMapRuntimeBinding? MapRuntimeBinding { get; init; }
    public AnchoredRelativeCoordinate? AnchoredRelativeCoordinate { get; init; }
    public ControlVisualSignature? VisualSignature { get; init; }
    public ControlRiskClass RiskClass { get; init; }
    public ControlRepositoryAction[] AllowedActions { get; init; } = [];
    public ControlRepositoryAction[] ForbiddenActions { get; init; } = [];
    public string[] PreflightRequirements { get; init; } = [];
}

public sealed record ControlContractObservation
{
    public required ControlRepositoryKey Key { get; init; }
    public string StateContext { get; init; } = "";
    public ControlStableIdentity? StableIdentity { get; init; }
    public ControlMapRuntimeBinding? MapRuntimeBinding { get; init; }
    public AnchoredRelativeCoordinate? AnchoredRelativeCoordinate { get; init; }
    public string ExpectedControlKind { get; init; } = "";
    public bool VisualSignatureMatched { get; init; }
    public string ProcessName { get; init; } = "";
    public string ProcessFingerprint { get; init; } = "";
    public string HostFingerprint { get; init; } = "";
    public int WindowWidth { get; init; }
    public int WindowHeight { get; init; }
    public int ClientWidth { get; init; }
    public int ClientHeight { get; init; }
    public double DpiScale { get; init; }
}

public static class ControlContractHasher
{
    public static bool IsContractReady(ControlRepositoryEntry entry) =>
        !string.IsNullOrWhiteSpace(entry.TargetProfileId) &&
        !string.IsNullOrWhiteSpace(entry.BusinessRole) &&
        !string.IsNullOrWhiteSpace(entry.ExpectedControlKind) &&
        TrustTier(entry) != LocatorTrustTier.Unresolved;

    public static ControlContractPayload CreatePayload(ControlRepositoryEntry entry)
    {
        if (!IsContractReady(entry))
            throw new InvalidDataException("Control contract requires targetProfileId, businessRole, control kind, and a configured locator.");
        var tier = TrustTier(entry);
        return new()
        {
            TargetProfileId = Normalize(entry.TargetProfileId),
            RepositoryKey = entry.Key.Canonical,
            ExpectedControlKind = Normalize(entry.ExpectedControlKind),
            BusinessRole = Normalize(entry.BusinessRole),
            TransactionalRole = entry.TransactionalRole,
            LocatorTier = tier,
            StableIdentity = tier == LocatorTrustTier.StableIdentity ? Normalize(entry.StableIdentity!) : null,
            MapRuntimeBinding = tier == LocatorTrustTier.MapRuntimeBinding ? Normalize(entry.MapRuntimeBinding!) : null,
            AnchoredRelativeCoordinate = tier == LocatorTrustTier.ApprovedAnchoredRelative ? Normalize(entry.AnchoredRelativeCoordinate!) : null,
            VisualSignature = tier is LocatorTrustTier.ApprovedAnchoredRelative or LocatorTrustTier.VisualObservationOnly ? Normalize(entry.VisualSignature) : null,
            RiskClass = entry.RiskClass,
            AllowedActions = entry.AllowedActions.Distinct().Order().ToArray(),
            ForbiddenActions = entry.ForbiddenActions.Distinct().Order().ToArray(),
            PreflightRequirements = PreflightRequirements(tier).Order(StringComparer.Ordinal).ToArray()
        };
    }

    public static string Compute(ControlRepositoryEntry entry) => CanonicalJson.Sha256(CreatePayload(entry));

    // 신규 안정 계약은 ControlContractHash를 사용하고, metadata가 없는 구형 entry만 기존 payload hash로 읽는다.
    public static string ComputeApprovalHash(ControlRepositoryEntry entry) =>
        IsContractReady(entry) ? Compute(entry) : ControlRepositoryApprovalPayload.ComputeHash(entry);

    public static LocatorTrustTier TrustTier(ControlRepositoryEntry entry) =>
        entry.StableIdentity?.IsConfigured == true ? LocatorTrustTier.StableIdentity :
        entry.MapRuntimeBinding?.IsConfigured == true ? LocatorTrustTier.MapRuntimeBinding :
        entry.AnchoredRelativeCoordinate?.IsConfigured == true ? LocatorTrustTier.ApprovedAnchoredRelative :
        entry.VisualSignature?.IsConfigured == true ? LocatorTrustTier.VisualObservationOnly : LocatorTrustTier.Unresolved;

    public static bool ObservationMatches(ControlRepositoryEntry entry, ControlContractObservation observation, out string reason)
    {
        reason = "";
        if (!entry.Key.Canonical.Equals(observation.Key.Canonical, StringComparison.Ordinal) ||
            !entry.Key.StateContext.Equals(observation.StateContext, StringComparison.Ordinal))
            return Fail("stateContext or repository key changed.", out reason);
        if (!string.IsNullOrWhiteSpace(entry.ExpectedControlKind) &&
            !entry.ExpectedControlKind.Equals(observation.ExpectedControlKind, StringComparison.OrdinalIgnoreCase))
            return Fail("expected control kind changed.", out reason);
        var host = entry.HostFingerprint;
        if (host is null || string.IsNullOrWhiteSpace(observation.ProcessName) ||
            observation.WindowWidth <= 0 || observation.WindowHeight <= 0 ||
            observation.ClientWidth <= 0 || observation.ClientHeight <= 0 || observation.DpiScale <= 0)
            return Fail("process, host, bounds, and DPI preflight observation is incomplete.", out reason);
        if (!host.ProcessName.Equals(observation.ProcessName, StringComparison.OrdinalIgnoreCase) ||
            !host.ProcessFingerprint.Equals(observation.ProcessFingerprint, StringComparison.Ordinal) ||
            !host.HostFingerprint.Equals(observation.HostFingerprint, StringComparison.Ordinal))
            return Fail("process ownership or host fingerprint changed.", out reason);


        var tier = TrustTier(entry);
        if (tier == LocatorTrustTier.StableIdentity && !Equivalent(entry.StableIdentity, observation.StableIdentity))
            return Fail("stable UIA/native identity changed.", out reason);
        if (tier == LocatorTrustTier.MapRuntimeBinding && !Equivalent(entry.MapRuntimeBinding, observation.MapRuntimeBinding))
            return Fail("MAP/runtime binding contract changed.", out reason);
        if (tier == LocatorTrustTier.ApprovedAnchoredRelative)
        {
            if (!AnchorEquivalent(entry.AnchoredRelativeCoordinate, observation.AnchoredRelativeCoordinate))
                return Fail("approved anchor contract exceeded tolerance.", out reason);
            if (entry.VisualSignature?.IsConfigured == true && !observation.VisualSignatureMatched)
                return Fail("anchor visual signature did not match.", out reason);
        }
        return true;
    }

    public static bool AnchorEquivalent(AnchoredRelativeCoordinate? approved, AnchoredRelativeCoordinate? observed)
    {
        if (approved is null || observed is null) return approved is null && observed is null;
        return approved.CoordinateSpace == observed.CoordinateSpace &&
               approved.AnchorId.Equals(observed.AnchorId, StringComparison.Ordinal) &&
               Near(approved.RelativeX, observed.RelativeX) && Near(approved.RelativeY, observed.RelativeY) &&
               Near(approved.RelativeWidth, observed.RelativeWidth) && Near(approved.RelativeHeight, observed.RelativeHeight);
    }

    private static string[] PreflightRequirements(LocatorTrustTier tier) => tier switch
    {
        LocatorTrustTier.StableIdentity => ["active-state", "control-kind", "process-ownership", "stable-identity"],
        LocatorTrustTier.MapRuntimeBinding => ["active-state", "control-kind", "map-runtime-binding", "process-ownership"],
        LocatorTrustTier.ApprovedAnchoredRelative => ["active-state", "anchor", "bounds", "control-kind", "dpi-transform", "host-fingerprint", "process-ownership", "visual-signature"],
        LocatorTrustTier.VisualObservationOnly => ["active-state", "observation-only", "visual-signature"],
        _ => ["configuration-required"]
    };

    private static bool Equivalent(ControlStableIdentity? left, ControlStableIdentity? right) =>
        left is not null && right is not null && CanonicalJson.SerializeToUtf8Bytes(Normalize(left)).SequenceEqual(CanonicalJson.SerializeToUtf8Bytes(Normalize(right)));

    private static bool Equivalent(ControlMapRuntimeBinding? left, ControlMapRuntimeBinding? right) =>
        left is not null && right is not null && CanonicalJson.SerializeToUtf8Bytes(Normalize(left)).SequenceEqual(CanonicalJson.SerializeToUtf8Bytes(Normalize(right)));

    private static ControlStableIdentity Normalize(ControlStableIdentity value) => value with
    {
        AutomationId = value.AutomationId.Trim(), NativeClass = value.NativeClass.Trim(),
        NativeControlId = value.NativeControlId.Trim(), NativeIdentityHash = value.NativeIdentityHash.Trim().ToLowerInvariant()
    };

    private static ControlMapRuntimeBinding Normalize(ControlMapRuntimeBinding value) => value with
    {
        MapScreenCode = Normalize(value.MapScreenCode), RuntimeBindingId = value.RuntimeBindingId.Trim()
    };

    private static AnchoredRelativeCoordinate Normalize(AnchoredRelativeCoordinate value) => value with { AnchorId = value.AnchorId.Trim() };

    private static ControlVisualSignature? Normalize(ControlVisualSignature? value) => value is null ? null : value with
    {
        Algorithm = Normalize(value.Algorithm), SignatureHash = value.SignatureHash.Trim().ToLowerInvariant()
    };

    private static string Normalize(string value) => value.Trim().ToUpperInvariant();
    private static bool Near(double left, double right) => double.IsFinite(left) && double.IsFinite(right) && Math.Abs(left - right) <= ExecutionAuthorizationVersions.AnchorTolerance;
    private static bool Fail(string value, out string reason) { reason = value; return false; }
}

public sealed record EnvironmentFingerprintInput
{
    public string TargetId { get; init; } = "";
    public string ProductClassification { get; init; } = "";
    public string ExecutableFingerprint { get; init; } = "";
    public string InstallationFingerprint { get; init; } = "";
    public string VersionFingerprint { get; init; } = "";
    public string HostClassification { get; init; } = "";
    public string MachineFingerprint { get; init; } = "";
    public ExecutionEnvironmentClassification EnvironmentClassification { get; init; }
    public string RoutingClassification { get; init; } = "";
    public ExecutionAccountClassification AccountClassification { get; init; }
    public string AdapterVersion { get; init; } = "";
    public string ExecutionPolicyVersion { get; init; } = "";
}

public sealed record EnvironmentFingerprint
{
    public string SchemaVersion { get; init; } = ExecutionAuthorizationVersions.EnvironmentFingerprintSchema;
    public required string Hash { get; init; }
    public required EnvironmentFingerprintInput Contract { get; init; }
}

public static class EnvironmentFingerprintFactory
{
    public static EnvironmentFingerprint Create(EnvironmentFingerprintInput input)
    {
        var contract = Normalize(input);
        if (new[] { contract.TargetId, contract.ProductClassification, contract.ExecutableFingerprint,
                contract.InstallationFingerprint, contract.VersionFingerprint, contract.HostClassification,
                contract.MachineFingerprint, contract.RoutingClassification, contract.AdapterVersion, contract.ExecutionPolicyVersion }
            .Any(string.IsNullOrWhiteSpace) ||
            contract.EnvironmentClassification == ExecutionEnvironmentClassification.Unspecified ||
            contract.AccountClassification == ExecutionAccountClassification.Unspecified)
            throw new InvalidDataException("Environment fingerprint requires target, product/install/version, host/machine, environment, routing, account, adapter and policy classifications.");
        return new() { Hash = CanonicalJson.Sha256(contract), Contract = contract };
    }

    private static EnvironmentFingerprintInput Normalize(EnvironmentFingerprintInput value) => value with
    {
        TargetId = Text(value.TargetId), ProductClassification = Text(value.ProductClassification),
        ExecutableFingerprint = Hash(value.ExecutableFingerprint), InstallationFingerprint = Hash(value.InstallationFingerprint),
        VersionFingerprint = Text(value.VersionFingerprint), HostClassification = Text(value.HostClassification),
        MachineFingerprint = Hash(value.MachineFingerprint), RoutingClassification = Text(value.RoutingClassification),
        AdapterVersion = Text(value.AdapterVersion), ExecutionPolicyVersion = Text(value.ExecutionPolicyVersion)
    };

    private static string Text(string value) => value.Trim().ToUpperInvariant();
    private static string Hash(string value) => value.Trim().ToLowerInvariant();
}

public sealed record ExecutionAuthorizationScope
{
    public string SchemaVersion { get; init; } = ExecutionAuthorizationVersions.AuthorizationSchema;
    public string PolicyVersion { get; init; } = "";
    public string[] TargetIds { get; init; } = [];
    public string[] Screens { get; init; } = [];
    public string[] Maps { get; init; } = [];
    public ControlRepositoryAction[] AllowedActions { get; init; } = [];
    public ControlRiskClass[] AllowedRiskClasses { get; init; } = [];
    public bool TransactionalActionsAllowed { get; init; }
    public string[] AllowedOrderTypes { get; init; } = [];
    public int? MaximumCaseCount { get; init; }
    public decimal? MaximumQuantity { get; init; }
    public decimal? MaximumAmount { get; init; }
    public DateTimeOffset? ExpiresAt { get; init; }
}

public sealed record ExecutionAuthorizationDraft
{
    public required EnvironmentFingerprintInput Environment { get; init; }
    public required ExecutionAuthorizationScope Scope { get; init; }
}

public static class ExecutionAuthorizationCanonicalTimestamp
{
    public const string UtcFormat = "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'";

    public static string? Format(DateTimeOffset? value) => value is null
        ? null
        : value.Value.ToUniversalTime().ToString(UtcFormat, CultureInfo.InvariantCulture);
}

internal sealed record ExecutionAuthorizationCanonicalScope
{
    public string SchemaVersion { get; init; } = "";
    public string PolicyVersion { get; init; } = "";
    public string[] TargetIds { get; init; } = [];
    public string[] Screens { get; init; } = [];
    public string[] Maps { get; init; } = [];
    public ControlRepositoryAction[] AllowedActions { get; init; } = [];
    public ControlRiskClass[] AllowedRiskClasses { get; init; } = [];
    public bool TransactionalActionsAllowed { get; init; }
    public string[] AllowedOrderTypes { get; init; } = [];
    public int? MaximumCaseCount { get; init; }
    public decimal? MaximumQuantity { get; init; }
    public decimal? MaximumAmount { get; init; }
    public string? ExpiresAtUtc { get; init; }
}

public sealed record ExecutionAuthorizationDocument
{
    public string SchemaVersion { get; init; } = ExecutionAuthorizationVersions.AuthorizationSchema;
    public string AuthorizationHashVersion { get; init; } = "";
    public required string AuthorizationId { get; init; }
    public required EnvironmentFingerprint EnvironmentFingerprint { get; init; }
    public required ExecutionAuthorizationScope Scope { get; init; }
    public required string AuthorizationHash { get; init; }
    public TestPackApprovalInfo Approval { get; init; } = new();
}

public static class ExecutionAuthorizationWorkflow
{
    public static TestPackApprovalOverlay CreateTemplate(ExecutionAuthorizationDraft draft)
    {
        var hash = ComputeHash(draft);
        return new() { TestPackContentHash = hash, Status = TestPackApprovalStatus.PendingApproval };
    }

    public static ExecutionAuthorizationDocument Apply(ExecutionAuthorizationDraft draft, TestPackApprovalOverlay overlay)
    {
        if (overlay.SchemaVersion != TestPackVersions.ApprovalSchema)
            throw new InvalidDataException($"Unsupported approval schemaVersion: {overlay.SchemaVersion}.");
        var fingerprint = EnvironmentFingerprintFactory.Create(draft.Environment);
        var scope = NormalizeScope(draft.Scope);
        ValidateScope(scope, fingerprint.Contract);
        var hash = ComputeHash(fingerprint, scope);
        if (!hash.Equals(overlay.TestPackContentHash, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Execution authorization approval hash does not match the reviewed environment and scope.");
        if (overlay.Status == TestPackApprovalStatus.Approved &&
            (string.IsNullOrWhiteSpace(overlay.ApprovedBy) || overlay.ApprovedAt is null || overlay.EvidenceRefs.Length == 0))
            throw new InvalidDataException("Approved execution authorization requires approvedBy, approvedAt, and evidence.");
        var approved = overlay.Status == TestPackApprovalStatus.Approved;
        return new()
        {
            AuthorizationHashVersion = ExecutionAuthorizationVersions.AuthorizationHashAlgorithm,
            AuthorizationId = $"execution-auth-{hash[..16]}", EnvironmentFingerprint = fingerprint, Scope = scope, AuthorizationHash = hash,
            Approval = new()
            {
                Status = overlay.Status, ApprovedBy = approved ? overlay.ApprovedBy : null,
                ApprovedAt = approved ? overlay.ApprovedAt : null, EvidenceRefs = overlay.EvidenceRefs,
                ApprovedContentHash = approved ? hash : ""
            }
        };
    }

    public static string ComputeHash(ExecutionAuthorizationDraft draft)
    {
        var fingerprint = EnvironmentFingerprintFactory.Create(draft.Environment);
        var scope = NormalizeScope(draft.Scope);
        ValidateScope(scope, fingerprint.Contract);
        return ComputeHash(fingerprint, scope);
    }

    public static string ComputeHash(EnvironmentFingerprint fingerprint, ExecutionAuthorizationScope scope) => CanonicalJson.Sha256(new
    {
        AuthorizationHashVersion = ExecutionAuthorizationVersions.AuthorizationHashAlgorithm,
        fingerprint.SchemaVersion,
        EnvironmentFingerprintHash = fingerprint.Hash,
        Scope = CanonicalScope(scope)
    });

    private static ExecutionAuthorizationCanonicalScope CanonicalScope(ExecutionAuthorizationScope value)
    {
        var scope = NormalizeScope(value);
        return new()
        {
            SchemaVersion = scope.SchemaVersion, PolicyVersion = scope.PolicyVersion,
            TargetIds = scope.TargetIds, Screens = scope.Screens, Maps = scope.Maps,
            AllowedActions = scope.AllowedActions, AllowedRiskClasses = scope.AllowedRiskClasses,
            TransactionalActionsAllowed = scope.TransactionalActionsAllowed,
            AllowedOrderTypes = scope.AllowedOrderTypes,
            MaximumCaseCount = scope.MaximumCaseCount, MaximumQuantity = scope.MaximumQuantity,
            MaximumAmount = scope.MaximumAmount,
            ExpiresAtUtc = ExecutionAuthorizationCanonicalTimestamp.Format(scope.ExpiresAt)
        };
    }

    internal static ExecutionAuthorizationScope NormalizeScope(ExecutionAuthorizationScope value) => value with
    {
        PolicyVersion = value.PolicyVersion.Trim().ToUpperInvariant(),
        TargetIds = Strings(value.TargetIds), Screens = Strings(value.Screens), Maps = Strings(value.Maps),
        AllowedActions = value.AllowedActions.Distinct().Order().ToArray(),
        AllowedRiskClasses = value.AllowedRiskClasses.Distinct().Order().ToArray(),
        AllowedOrderTypes = Strings(value.AllowedOrderTypes)
    };

    internal static void ValidateScope(ExecutionAuthorizationScope scope, EnvironmentFingerprintInput environment)
    {
        if (scope.SchemaVersion != ExecutionAuthorizationVersions.AuthorizationSchema || string.IsNullOrWhiteSpace(scope.PolicyVersion) ||
            scope.TargetIds.Length == 0 || scope.Screens.Length == 0 || scope.Maps.Length == 0 ||
            scope.AllowedActions.Length == 0 || scope.AllowedRiskClasses.Length == 0)
            throw new InvalidDataException("Execution authorization scope requires schema/policy, target, screen, MAP, action and risk allowlists.");
        if (!scope.PolicyVersion.Equals(environment.ExecutionPolicyVersion, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Execution authorization scope policyVersion must match the environment execution policy version.");
        if (scope.MaximumCaseCount is <= 0 || scope.MaximumQuantity is <= 0 || scope.MaximumAmount is <= 0)
            throw new InvalidDataException("Optional execution authorization limits must be positive.");
    }

    private static string[] Strings(IEnumerable<string> values) => values.Where(x => !string.IsNullOrWhiteSpace(x))
        .Select(x => x.Trim().ToUpperInvariant()).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
}

public sealed record ExecutionControlRequirement
{
    public required string RepositoryKey { get; init; }
    public string ControlContractHash { get; init; } = "";
    public ControlRepositoryAction Action { get; init; }
    public ControlRiskClass RiskClass { get; init; }
    public bool PhysicalAction { get; init; }
    public bool TransactionalAction { get; init; }
    public string OrderType { get; init; } = "";
}

public sealed record ExecutionAuthorizationRequest
{
    public required EnvironmentFingerprintInput CurrentEnvironment { get; init; }
    public ExecutionAuthorizationDocument? Authorization { get; init; }
    public required ControlRepositoryDocument Repository { get; init; }
    public ExecutionControlRequirement[] Requirements { get; init; } = [];
    public ControlContractObservation[] ControlObservations { get; init; } = [];
    public int RequestedCaseCount { get; init; } = 1;
    public decimal? RequestedQuantity { get; init; }
    public decimal? RequestedAmount { get; init; }
    public string PlanHash { get; init; } = "";
}

public sealed record ExecutionAuthorizationIssue
{
    public required string Code { get; init; }
    public required string Message { get; init; }
    public required string Remediation { get; init; }
    public string Target { get; init; } = "";
}

public sealed record ExecutionAuthorizationDecision
{
    public string SchemaVersion { get; init; } = ExecutionAuthorizationVersions.DecisionSchema;
    public ExecutionAuthorizationStatus Status { get; init; } = ExecutionAuthorizationStatus.ConfigurationRequired;
    public bool IsAuthorized { get; init; }
    public string EnvironmentFingerprintHash { get; init; } = "";
    public string ExecutionAuthorizationHash { get; init; } = "";
    public string[] ControlContractHashes { get; init; } = [];
    public ExecutionAuthorizationIssue[] Issues { get; init; } = [];
    public int ActualActionCallCount { get; init; }
}

public interface IExecutionAuthorizationService
{
    ExecutionAuthorizationDecision Authorize(ExecutionAuthorizationRequest request, DateTimeOffset now);
}

public sealed class ExecutionAuthorizationService : IExecutionAuthorizationService
{
    public ExecutionAuthorizationDecision Authorize(ExecutionAuthorizationRequest request, DateTimeOffset now)
    {
        EnvironmentFingerprint current;
        try { current = EnvironmentFingerprintFactory.Create(request.CurrentEnvironment); }
        catch (Exception ex) { return Decision(ExecutionAuthorizationStatus.ConfigurationRequired, "AUTH.CONFIGURATION_REQUIRED", ex.Message, "Provide classified, redacted environment fingerprint inputs."); }

        var authorization = request.Authorization;
        if (authorization is null)
            return Decision(ExecutionAuthorizationStatus.EnvironmentApprovalRequired, "AUTH.ENVIRONMENT_APPROVAL_REQUIRED", "No environment execution authorization was supplied.", "Create and obtain human approval for this exact environment and scope.", environmentHash: current.Hash);
        if (authorization.SchemaVersion != ExecutionAuthorizationVersions.AuthorizationSchema)
            return Decision(ExecutionAuthorizationStatus.InvalidAuthorization, "AUTH.SCHEMA_VERSION", "Execution authorization schema is unsupported.", "Regenerate the authorization with the supported schema.", environmentHash: current.Hash);
        if (!authorization.AuthorizationHashVersion.Equals(ExecutionAuthorizationVersions.AuthorizationHashAlgorithm, StringComparison.Ordinal))
            return Decision(ExecutionAuthorizationStatus.InvalidAuthorization, "AUTH.HASH_VERSION_UNSUPPORTED", "Execution authorization hash version is missing or unsupported.",
                "Regenerate the authorization with the current UTC canonicalization and obtain a new human approval.", current.Hash, authorization.AuthorizationHash);

        string expectedAuthorizationHash;
        try
        {
            expectedAuthorizationHash = ExecutionAuthorizationWorkflow.ComputeHash(authorization.EnvironmentFingerprint, authorization.Scope);
            ExecutionAuthorizationWorkflow.ValidateScope(ExecutionAuthorizationWorkflow.NormalizeScope(authorization.Scope), authorization.EnvironmentFingerprint.Contract);
        }
        catch (Exception ex)
        {
            return Decision(ExecutionAuthorizationStatus.InvalidAuthorization, "AUTH.INVALID_AUTHORIZATION", ex.Message, "Regenerate and reapprove the unchanged authorization payload.", environmentHash: current.Hash);
        }
        if (!authorization.EnvironmentFingerprint.Hash.Equals(EnvironmentFingerprintFactory.Create(authorization.EnvironmentFingerprint.Contract).Hash, StringComparison.OrdinalIgnoreCase) ||
            !authorization.AuthorizationHash.Equals(expectedAuthorizationHash, StringComparison.OrdinalIgnoreCase) ||
            authorization.Approval.Status != TestPackApprovalStatus.Approved ||
            !authorization.Approval.ApprovedContentHash.Equals(expectedAuthorizationHash, StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(authorization.Approval.ApprovedBy) || authorization.Approval.ApprovedAt is null || authorization.Approval.EvidenceRefs.Length == 0)
            return Decision(ExecutionAuthorizationStatus.InvalidAuthorization, "AUTH.HASH_MISMATCH", "Execution authorization approval payload is missing or was modified.", "Regenerate and obtain a new human approval.", current.Hash, authorization.AuthorizationHash);
        if (authorization.Scope.ExpiresAt is { } expiresAt && now.ToUniversalTime() >= expiresAt.ToUniversalTime())
            return Decision(ExecutionAuthorizationStatus.AuthorizationExpired, "AUTH.AUTHORIZATION_EXPIRED", "Execution authorization has expired.", "Obtain a new time-bounded authorization.", current.Hash, authorization.AuthorizationHash);
        if (!authorization.EnvironmentFingerprint.Hash.Equals(current.Hash, StringComparison.OrdinalIgnoreCase))
            return Decision(ExecutionAuthorizationStatus.EnvironmentDrift, "AUTH.ENVIRONMENT_DRIFT", "Current environment fingerprint differs from the approved environment.", "Review the changed version, host, routing, account, adapter, or policy classification and reapprove.", current.Hash, authorization.AuthorizationHash);

        var scope = ExecutionAuthorizationWorkflow.NormalizeScope(authorization.Scope);
        var environment = current.Contract;
        var hashes = new List<string>();
        if (!Contains(scope.TargetIds, environment.TargetId)) return Scope("AUTH.SCOPE_TARGET", "Target is outside the approved scope.", environment.TargetId);
        if (!request.Repository.TargetProfileId.Equals(environment.TargetId, StringComparison.OrdinalIgnoreCase))
            return Decision(ExecutionAuthorizationStatus.ControlContractDrift, "AUTH.REPOSITORY_TARGET_MISMATCH", "Control repository target differs from the current environment target.", "Use the repository approved for this exact target.", current.Hash, authorization.AuthorizationHash, target: request.Repository.TargetProfileId);
        if (request.RequestedCaseCount <= 0 || scope.MaximumCaseCount is { } maximumCases && request.RequestedCaseCount > maximumCases)
            return Scope("AUTH.SCOPE_CASE_LIMIT", "Requested case count exceeds the approved limit.", request.RequestedCaseCount.ToString());
        if (scope.MaximumQuantity is { } maximumQuantity && (request.RequestedQuantity is null || request.RequestedQuantity > maximumQuantity))
            return Scope("AUTH.SCOPE_QUANTITY_LIMIT", "Requested quantity is missing or exceeds the approved limit.", "quantity");
        if (scope.MaximumAmount is { } maximumAmount && (request.RequestedAmount is null || request.RequestedAmount > maximumAmount))
            return Scope("AUTH.SCOPE_AMOUNT_LIMIT", "Requested amount is missing or exceeds the approved limit.", "amount");

        foreach (var requirement in request.Requirements)
        {
            var entries = request.Repository.Entries.Where(x => x.Key.Canonical.Equals(requirement.RepositoryKey, StringComparison.Ordinal)).ToArray();
            if (entries.Length != 1)
                return Decision(entries.Length == 0 ? ExecutionAuthorizationStatus.ControlApprovalRequired : ExecutionAuthorizationStatus.InvalidAuthorization,
                    entries.Length == 0 ? "AUTH.CONTROL_APPROVAL_REQUIRED" : "AUTH.AMBIGUOUS_CONTROL",
                    entries.Length == 0 ? "Required control is not registered." : "Required control key is ambiguous.",
                    "Capture, review, approve and register exactly one control contract.", current.Hash, authorization.AuthorizationHash, target: requirement.RepositoryKey);
            var entry = entries[0];
            if (!entry.TargetProfileId.Equals(environment.TargetId, StringComparison.OrdinalIgnoreCase) || !ControlContractHasher.IsContractReady(entry) ||
                entry.Status != ControlRepositoryEntryStatus.Approved || entry.Approval.Status != TestPackApprovalStatus.Approved || string.IsNullOrWhiteSpace(entry.ControlContractHash) ||
                string.IsNullOrWhiteSpace(entry.Approval.ApprovedBy) || entry.Approval.ApprovedAt is null || entry.Approval.EvidenceRefs.Length == 0)
                return Decision(ExecutionAuthorizationStatus.ControlApprovalRequired, "AUTH.CONTROL_APPROVAL_REQUIRED", "Control lacks a reusable stable contract approval.", "Review and approve the stable ControlContractHash.", current.Hash, authorization.AuthorizationHash, target: requirement.RepositoryKey);
            var expectedControlHash = ControlContractHasher.Compute(entry);
            if (string.IsNullOrWhiteSpace(requirement.ControlContractHash))
                return Decision(ExecutionAuthorizationStatus.ControlApprovalRequired, "AUTH.CONTROL_CONTRACT_HASH_REQUIRED", "Run plan does not pin the approved ControlContractHash.", "Recompile the run plan from the approved control repository.", current.Hash, authorization.AuthorizationHash, hashes, requirement.RepositoryKey);
            if (!entry.ControlContractHash.Equals(expectedControlHash, StringComparison.OrdinalIgnoreCase) ||
                !entry.ApprovalPayloadHash.Equals(expectedControlHash, StringComparison.OrdinalIgnoreCase) ||
                !entry.Approval.ApprovedContentHash.Equals(expectedControlHash, StringComparison.OrdinalIgnoreCase) ||
                !requirement.ControlContractHash.Equals(expectedControlHash, StringComparison.OrdinalIgnoreCase))
                return Decision(ExecutionAuthorizationStatus.ControlContractDrift, "AUTH.CONTROL_CONTRACT_DRIFT", "Control contract or its approval hash changed.", "Stop and obtain approval for only the changed control contract.", current.Hash, authorization.AuthorizationHash, hashes, requirement.RepositoryKey);

            if (!Contains(scope.Screens, entry.Key.Screen)) return Scope("AUTH.SCOPE_SCREEN", "Screen is outside the approved scope.", entry.Key.Screen);
            if (!Contains(scope.Maps, entry.Key.Map)) return Scope("AUTH.SCOPE_MAP", "MAP is outside the approved scope.", entry.Key.Map);
            if (!scope.AllowedActions.Contains(requirement.Action)) return Scope("AUTH.SCOPE_ACTION", "Physical action is outside the approved scope.", requirement.Action.ToString());
            if (!scope.AllowedRiskClasses.Contains(requirement.RiskClass)) return Scope("AUTH.SCOPE_RISK", "Risk class is outside the approved scope.", requirement.RiskClass.ToString());
            if (!entry.AllowedActions.Contains(requirement.Action) || entry.ForbiddenActions.Contains(requirement.Action) || entry.RiskClass != requirement.RiskClass)
                return Scope("AUTH.CONTROL_SCOPE_VIOLATION", "Requested action/risk conflicts with the approved control contract.", requirement.RepositoryKey);

            var tier = ControlContractHasher.TrustTier(entry);
            var transactional = requirement.TransactionalAction || entry.TransactionalRole != ControlTransactionalRole.None ||
                requirement.RiskClass == ControlRiskClass.Transactional || IsTransactional(requirement.Action);
            if (requirement.PhysicalAction && tier == LocatorTrustTier.VisualObservationOnly)
                return Scope("AUTH.IMAGE_ONLY_PHYSICAL_FORBIDDEN", "Image-only locator cannot perform a physical action.", requirement.RepositoryKey);
            if (transactional && tier != LocatorTrustTier.StableIdentity)
                return Scope("AUTH.TRANSACTION_STABLE_IDENTITY_REQUIRED", "Transactional action requires stable UIA/native identity.", requirement.RepositoryKey);
            if (transactional && !scope.TransactionalActionsAllowed)
                return Scope("AUTH.TRANSACTION_SCOPE_REQUIRED", "Transactional action is not allowed by the environment scope.", requirement.RepositoryKey);
            if (transactional && environment.EnvironmentClassification == ExecutionEnvironmentClassification.Production ||
                transactional && environment.AccountClassification == ExecutionAccountClassification.Real)
                return Scope("AUTH.PRODUCTION_TRANSACTION_FORBIDDEN", "Automation cannot submit transactional actions in production or a real account.", requirement.RepositoryKey);
            if (transactional && (string.IsNullOrWhiteSpace(requirement.OrderType) || !Contains(scope.AllowedOrderTypes, requirement.OrderType)))
                return Scope("AUTH.SCOPE_ORDER_TYPE", "Transactional order type is missing or outside the approved scope.", requirement.OrderType);

            if (requirement.PhysicalAction)
            {
                var observations = request.ControlObservations.Where(x => x.Key.Canonical.Equals(requirement.RepositoryKey, StringComparison.Ordinal)).ToArray();
                if (observations.Length != 1)
                    return Decision(ExecutionAuthorizationStatus.ConfigurationRequired, "AUTH.CONTROL_PREFLIGHT_REQUIRED", "Exactly one current control preflight observation is required.", "Observe the control read-only immediately before execution.", current.Hash, authorization.AuthorizationHash, hashes, requirement.RepositoryKey);
                if (!ControlContractHasher.ObservationMatches(entry, observations[0], out var reason))
                    return Decision(ExecutionAuthorizationStatus.ControlContractDrift, "AUTH.CONTROL_PREFLIGHT_DRIFT", reason, "Stop without self-healing; review and reapprove only if the stable contract changed.", current.Hash, authorization.AuthorizationHash, hashes, requirement.RepositoryKey);
            }
            hashes.Add(expectedControlHash);
        }

        return new()
        {
            Status = ExecutionAuthorizationStatus.Authorized, IsAuthorized = true,
            EnvironmentFingerprintHash = current.Hash, ExecutionAuthorizationHash = authorization.AuthorizationHash,
            ControlContractHashes = hashes.Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.Ordinal).ToArray(),
            ActualActionCallCount = 0
        };

        ExecutionAuthorizationDecision Scope(string code, string message, string target) =>
            Decision(ExecutionAuthorizationStatus.ScopeViolation, code, message, "Narrow the run or obtain a new explicit authorization for the changed scope.", current.Hash, authorization.AuthorizationHash, hashes, target);
    }

    private static bool Contains(IEnumerable<string> values, string value) => values.Contains(value.Trim().ToUpperInvariant(), StringComparer.Ordinal);
    private static bool IsTransactional(ControlRepositoryAction action) => action is ControlRepositoryAction.OpenConfirmation or ControlRepositoryAction.FinalSubmit or ControlRepositoryAction.AmendSubmit or ControlRepositoryAction.CancelSubmit;

    private static ExecutionAuthorizationDecision Decision(ExecutionAuthorizationStatus status, string code, string message, string remediation,
        string environmentHash = "", string authorizationHash = "", IEnumerable<string>? controlHashes = null, string target = "") => new()
    {
        Status = status, IsAuthorized = false, EnvironmentFingerprintHash = environmentHash,
        ExecutionAuthorizationHash = authorizationHash, ControlContractHashes = controlHashes?.Distinct(StringComparer.OrdinalIgnoreCase).ToArray() ?? [],
        Issues = [new() { Code = code, Message = message, Remediation = remediation, Target = target }], ActualActionCallCount = 0
    };
}
