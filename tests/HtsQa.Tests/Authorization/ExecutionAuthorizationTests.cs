// 역할: 안정 ControlContractHash와 환경 실행 승인 재사용, drift, scope, zero-action 계약을 순수 synthetic 데이터로 검증한다.
// 경계: HTS, FlaUI, UI, 파일 시스템, ResultEvaluator를 호출하지 않는다.
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using HtsQa.Core;

namespace HtsQa.Tests;

public sealed class ExecutionAuthorizationTests
{
    private static readonly DateTimeOffset ApprovedAt = DateTimeOffset.Parse("2026-08-25T09:00:00+09:00");
    private static readonly DateTimeOffset CheckedAt = ApprovedAt.AddMinutes(5);

    [Fact]
    public void Same_Control_Contract_Reuses_Approval_And_Excludes_Session_Geometry()
    {
        var approved = ApprovedStableEntry();
        var restarted = approved with
        {
            HostFingerprint = approved.HostFingerprint! with
            {
                CapturedWindowWidth = 1800, CapturedWindowHeight = 1000,
                CapturedClientWidth = 1750, CapturedClientHeight = 920, CapturedDpiScale = 1.5
            },
            CreatedAt = ApprovedAt.AddDays(1), ReviewedAt = ApprovedAt.AddDays(1)
        };

        Assert.Equal(approved.ControlContractHash, ControlContractHasher.Compute(restarted));
        Assert.DoesNotContain(ControlRepositoryValidator.Validate(Repository(restarted)), issue => issue.Code.Contains("HASH", StringComparison.Ordinal));
    }

    [Fact]
    public void Runtime_Identity_And_Window_Values_Are_Not_Control_Contract_Inputs()
    {
        var entry = ApprovedStableEntry();
        var payload = ControlContractHasher.CreatePayload(entry);
        var json = JsonSerializer.Serialize(payload, JsonDefaults.Options);

        Assert.DoesNotContain("runtimeId", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("hwnd", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("capturedWindow", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("capturedDpi", json, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Physical_Preflight_Allows_Window_Resize_And_Dpi_Change_Without_Reapproval()
    {
        var request = Request();
        request = request with
        {
            ControlObservations = [Observation(request.Repository.Entries[0]) with
            {
                WindowWidth = 1600, WindowHeight = 900, ClientWidth = 1500, ClientHeight = 820, DpiScale = 1.5
            }]
        };

        var decision = Service().Authorize(request, CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.Authorized, decision.Status);
        Assert.Equal(0, decision.ActualActionCallCount);
    }

    [Fact]
    public void Physical_Preflight_Rejects_Wrong_Process_Or_Invalid_Geometry()
    {
        var request = Request();
        var entry = request.Repository.Entries[0];
        var wrongProcess = request with { ControlObservations = [Observation(entry) with { ProcessName = "other-process" }] };
        var invalidGeometry = request with { ControlObservations = [Observation(entry) with { ClientWidth = 0 }] };

        var wrongProcessDecision = Service().Authorize(wrongProcess, CheckedAt);
        var invalidGeometryDecision = Service().Authorize(invalidGeometry, CheckedAt);

        Assert.Equal("AUTH.CONTROL_PREFLIGHT_DRIFT", Assert.Single(wrongProcessDecision.Issues).Code);
        Assert.Equal("AUTH.CONTROL_PREFLIGHT_DRIFT", Assert.Single(invalidGeometryDecision.Issues).Code);
        Assert.Equal(0, wrongProcessDecision.ActualActionCallCount);
        Assert.Equal(0, invalidGeometryDecision.ActualActionCallCount);
    }

    [Theory]
    [InlineData("stable-2", "state:a", "Edit", ControlRiskClass.Transactional, ControlRepositoryAction.FinalSubmit)]
    [InlineData("stable-1", "state:b", "Edit", ControlRiskClass.Transactional, ControlRepositoryAction.FinalSubmit)]
    [InlineData("stable-1", "state:a", "Edit", ControlRiskClass.Transactional, ControlRepositoryAction.FinalSubmit)]
    [InlineData("stable-1", "state:a", "Edit", ControlRiskClass.General, ControlRepositoryAction.FinalSubmit)]
    [InlineData("stable-1", "state:a", "Edit", ControlRiskClass.Transactional, ControlRepositoryAction.Click)]
    public void Stable_Identity_State_Kind_Risk_Or_Action_Change_Requires_Reapproval(
        string identity, string state, string kind, ControlRiskClass risk, ControlRepositoryAction action)
    {
        var entry = ApprovedStableEntry();
        var changed = entry with
        {
            Key = entry.Key with { StateContext = state },
            StableIdentity = entry.StableIdentity! with { NativeIdentityHash = identity },
            ExpectedControlKind = kind,
            RiskClass = risk,
            AllowedActions = [action]
        };

        Assert.NotEqual(entry.ControlContractHash, ControlContractHasher.Compute(changed));
    }

    [Fact]
    public void Anchor_Tolerance_Distinguishes_Normal_Transform_From_Drift()
    {
        var entry = ApprovedCoordinateEntry();
        var within = Observation(entry) with
        {
            AnchoredRelativeCoordinate = entry.AnchoredRelativeCoordinate! with { RelativeX = 0.501 }
        };
        var beyond = within with
        {
            AnchoredRelativeCoordinate = entry.AnchoredRelativeCoordinate! with { RelativeX = 0.51 }
        };

        Assert.True(ControlContractHasher.ObservationMatches(entry, within, out _));
        Assert.False(ControlContractHasher.ObservationMatches(entry, beyond, out var reason));
        Assert.Contains("tolerance", reason, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Approval_Payload_Tamper_Is_Blocked()
    {
        var entry = ApprovedStableEntry();
        var tampered = entry with { StableIdentity = entry.StableIdentity! with { AutomationId = "changed" } };
        var decision = Service().Authorize(Request(entry: tampered), CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.ControlContractDrift, decision.Status);
        Assert.Equal("AUTH.CONTROL_CONTRACT_DRIFT", Assert.Single(decision.Issues).Code);
        Assert.Equal(0, decision.ActualActionCallCount);
    }

    [Fact]
    public void Missing_Control_Approval_Provenance_Is_Blocked()
    {
        var entry = ApprovedStableEntry();
        var tampered = entry with { Approval = entry.Approval with { ApprovedBy = null } };
        var decision = Service().Authorize(Request(entry: tampered), CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.ControlApprovalRequired, decision.Status);
        Assert.Equal("AUTH.CONTROL_APPROVAL_REQUIRED", Assert.Single(decision.Issues).Code);
        Assert.Equal(0, decision.ActualActionCallCount);
    }

    [Fact]
    public void Run_Plan_Must_Pin_The_Control_Contract_Hash()
    {
        var entry = ApprovedStableEntry();
        var requirement = Requirement(entry) with { ControlContractHash = "" };
        var decision = Service().Authorize(Request(entry: entry, requirement: requirement), CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.ControlApprovalRequired, decision.Status);
        Assert.Equal("AUTH.CONTROL_CONTRACT_HASH_REQUIRED", Assert.Single(decision.Issues).Code);
        Assert.Equal(0, decision.ActualActionCallCount);
    }

    [Fact]
    public void Repository_Target_Must_Match_The_Current_Environment()
    {
        var request = Request();
        request = request with { Repository = request.Repository with { TargetProfileId = "other-target" } };
        var decision = Service().Authorize(request, CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.ControlContractDrift, decision.Status);
        Assert.Equal("AUTH.REPOSITORY_TARGET_MISMATCH", Assert.Single(decision.Issues).Code);
        Assert.Equal(0, decision.ActualActionCallCount);
    }

    [Fact]
    public void Same_Environment_And_Scope_Are_Reused_Across_Plan_Hash_Changes()
    {
        var first = Service().Authorize(Request(planHash: "plan-a"), CheckedAt);
        var second = Service().Authorize(Request(planHash: "plan-b"), CheckedAt);

        Assert.True(first.IsAuthorized);
        Assert.True(second.IsAuthorized);
        Assert.Equal(first.ExecutionAuthorizationHash, second.ExecutionAuthorizationHash);
        Assert.Equal(0, first.ActualActionCallCount);
        Assert.Equal(0, second.ActualActionCallCount);
    }

    [Fact]
    public void Environment_Fingerprint_Excludes_Login_Session_Test_Data_And_Secrets()
    {
        var fingerprint = EnvironmentFingerprintFactory.Create(Environment());
        var json = JsonSerializer.Serialize(fingerprint, JsonDefaults.Options);

        Assert.DoesNotContain("login", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("session", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("testData", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("endpoint", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("accountNumber", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("password", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("token", json, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("version")]
    [InlineData("host")]
    [InlineData("routing")]
    [InlineData("account")]
    [InlineData("adapter")]
    [InlineData("policy")]
    public void Environment_Drift_Requires_Reapproval(string field)
    {
        var current = Environment();
        current = field switch
        {
            "version" => current with { VersionFingerprint = "2.0" },
            "host" => current with { HostClassification = "other-host" },
            "routing" => current with { RoutingClassification = "other-routing" },
            "account" => current with { AccountClassification = ExecutionAccountClassification.Real },
            "adapter" => current with { AdapterVersion = "2.0" },
            _ => current with { ExecutionPolicyVersion = "2.0" }
        };

        var decision = Service().Authorize(Request(currentEnvironment: current), CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.EnvironmentDrift, decision.Status);
        Assert.Equal("AUTH.ENVIRONMENT_DRIFT", Assert.Single(decision.Issues).Code);
    }

    [Fact]
    public void Test_Approval_Cannot_Be_Reused_For_Production()
    {
        var production = Environment() with { EnvironmentClassification = ExecutionEnvironmentClassification.Production };

        var decision = Service().Authorize(Request(currentEnvironment: production), CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.EnvironmentDrift, decision.Status);
    }

    [Fact]
    public void Even_A_Matching_Production_Authorization_Cannot_Enable_Transactional_Automation()
    {
        var production = Environment() with { EnvironmentClassification = ExecutionEnvironmentClassification.Production };
        var authorization = ApprovedAuthorization(environment: production);

        var decision = Service().Authorize(Request(authorization: authorization, currentEnvironment: production), CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.ScopeViolation, decision.Status);
        Assert.Equal("AUTH.PRODUCTION_TRANSACTION_FORBIDDEN", Assert.Single(decision.Issues).Code);
        Assert.Equal(0, decision.ActualActionCallCount);
    }

    [Fact]
    public void Equivalent_Expiry_Offsets_Share_Canonical_Timestamp_And_Authorization_Hash()
    {
        var timestamps = new[]
        {
            DateTimeOffset.Parse("2026-09-25T09:00:00+09:00", CultureInfo.InvariantCulture),
            DateTimeOffset.Parse("2026-09-25T00:00:00Z", CultureInfo.InvariantCulture),
            DateTimeOffset.Parse("2026-09-25T00:00:00+00:00", CultureInfo.InvariantCulture),
            DateTimeOffset.Parse("2026-09-24T19:00:00-05:00", CultureInfo.InvariantCulture)
        };

        var canonical = timestamps.Select(timestamp => ExecutionAuthorizationCanonicalTimestamp.Format(timestamp)).ToArray();
        var hashes = timestamps.Select(timestamp => ExecutionAuthorizationWorkflow.ComputeHash(new ExecutionAuthorizationDraft
        {
            Environment = Environment(), Scope = Scope() with { ExpiresAt = timestamp }
        })).ToArray();

        Assert.All(canonical, value => Assert.Equal("2026-09-25T00:00:00.0000000Z", value));
        Assert.Single(hashes.Distinct(StringComparer.Ordinal));
    }

    [Fact]
    public void Different_Expiry_Instants_Keep_Full_Tick_Precision_And_Different_Hashes()
    {
        var boundary = DateTimeOffset.Parse("2026-09-25T00:00:00Z", CultureInfo.InvariantCulture);
        var timestamps = new[] { boundary, boundary.AddSeconds(1), boundary.AddTicks(1), boundary.AddTicks(-1) };
        var hashes = timestamps.Select(timestamp => ExecutionAuthorizationWorkflow.ComputeHash(new ExecutionAuthorizationDraft
        {
            Environment = Environment(), Scope = Scope() with { ExpiresAt = timestamp }
        })).ToArray();

        Assert.Equal("2026-09-25T00:00:00.0000001Z", ExecutionAuthorizationCanonicalTimestamp.Format(boundary.AddTicks(1)));
        Assert.Equal("2026-09-24T23:59:59.9999999Z", ExecutionAuthorizationCanonicalTimestamp.Format(boundary.AddTicks(-1)));
        Assert.Equal(timestamps.Length, hashes.Distinct(StringComparer.Ordinal).Count());
    }

    [Fact]
    public void Canonical_Expiry_Is_Culture_Invariant_And_Null_Remains_Null()
    {
        var originalCulture = CultureInfo.CurrentCulture;
        var originalUiCulture = CultureInfo.CurrentUICulture;
        try
        {
            foreach (var cultureName in new[] { "ko-KR", "en-US", "tr-TR" })
            {
                CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo(cultureName);
                CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo(cultureName);
                Assert.Equal("2026-09-25T00:00:00.1234567Z", ExecutionAuthorizationCanonicalTimestamp.Format(
                    DateTimeOffset.Parse("2026-09-25T09:00:00.1234567+09:00", CultureInfo.InvariantCulture)));
            }
        }
        finally
        {
            CultureInfo.CurrentCulture = originalCulture;
            CultureInfo.CurrentUICulture = originalUiCulture;
        }

        Assert.Null(ExecutionAuthorizationCanonicalTimestamp.Format(null));
    }

    [Fact]
    public void DotNet_Json_RoundTrip_And_Utc_Representation_Preserve_Authorization_Hash()
    {
        var authorization = ApprovedAuthorization(Scope() with
        {
            ExpiresAt = DateTimeOffset.Parse("2026-09-25T09:00:00+09:00", CultureInfo.InvariantCulture)
        });
        var json = JsonSerializer.Serialize(authorization, JsonDefaults.Options);
        var roundTrip = JsonSerializer.Deserialize<ExecutionAuthorizationDocument>(json, JsonDefaults.Options)!;
        var utcRepresentation = roundTrip with
        {
            Scope = roundTrip.Scope with { ExpiresAt = roundTrip.Scope.ExpiresAt!.Value.ToUniversalTime() }
        };

        Assert.Equal(authorization.AuthorizationHash, ExecutionAuthorizationWorkflow.ComputeHash(
            utcRepresentation.EnvironmentFingerprint, utcRepresentation.Scope));
        Assert.Equal(ExecutionAuthorizationStatus.Authorized,
            Service().Authorize(Request(authorization: utcRepresentation), CheckedAt).Status);
    }

    [Fact]
    public void Expiry_Uses_The_Utc_Instant_At_Before_Exact_And_After_Boundaries()
    {
        var expiresAt = DateTimeOffset.Parse("2026-09-25T09:00:00+09:00", CultureInfo.InvariantCulture);
        var authorization = ApprovedAuthorization(Scope() with { ExpiresAt = expiresAt });

        var before = Service().Authorize(Request(authorization: authorization), expiresAt.ToUniversalTime().AddTicks(-1));
        var exact = Service().Authorize(Request(authorization: authorization), expiresAt.ToOffset(TimeSpan.FromHours(-5)));
        var after = Service().Authorize(Request(authorization: authorization), expiresAt.ToUniversalTime().AddTicks(1));
        var noExpiry = Service().Authorize(Request(authorization: ApprovedAuthorization(Scope() with { ExpiresAt = null })),
            DateTimeOffset.Parse("2100-01-01T00:00:00Z", CultureInfo.InvariantCulture));

        Assert.Equal(ExecutionAuthorizationStatus.Authorized, before.Status);
        Assert.Equal(ExecutionAuthorizationStatus.AuthorizationExpired, exact.Status);
        Assert.Equal("AUTH.AUTHORIZATION_EXPIRED", Assert.Single(exact.Issues).Code);
        Assert.Equal(ExecutionAuthorizationStatus.AuthorizationExpired, after.Status);
        Assert.Equal(ExecutionAuthorizationStatus.Authorized, noExpiry.Status);
    }

    [Fact]
    public void Changing_Expiry_Instant_Invalidates_The_Existing_Approval_Hash()
    {
        var authorization = ApprovedAuthorization();
        var tampered = authorization with
        {
            Scope = authorization.Scope with { ExpiresAt = authorization.Scope.ExpiresAt!.Value.AddTicks(1) }
        };

        var decision = Service().Authorize(Request(authorization: tampered), CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.InvalidAuthorization, decision.Status);
        Assert.Equal("AUTH.HASH_MISMATCH", Assert.Single(decision.Issues).Code);
    }

    [Theory]
    [InlineData("target", "AUTH.SCOPE_TARGET")]
    [InlineData("screen", "AUTH.SCOPE_SCREEN")]
    [InlineData("map", "AUTH.SCOPE_MAP")]
    [InlineData("action", "AUTH.SCOPE_ACTION")]
    [InlineData("risk", "AUTH.SCOPE_RISK")]
    [InlineData("order", "AUTH.SCOPE_ORDER_TYPE")]
    public void Scope_Violations_Are_Fail_Closed(string field, string code)
    {
        var scope = Scope();
        scope = field switch
        {
            "target" => scope with { TargetIds = ["other-target"] },
            "screen" => scope with { Screens = ["OTHER"] },
            "map" => scope with { Maps = ["OTHER"] },
            "action" => scope with { AllowedActions = [ControlRepositoryAction.Assert] },
            "risk" => scope with { AllowedRiskClasses = [ControlRiskClass.General] },
            _ => scope with { AllowedOrderTypes = ["MARKET"] }
        };
        var authorization = ApprovedAuthorization(scope);

        var decision = Service().Authorize(Request(authorization: authorization), CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.ScopeViolation, decision.Status);
        Assert.Equal(code, Assert.Single(decision.Issues).Code);
    }

    [Fact]
    public void Scope_Widening_Without_Reapproval_Is_Invalid()
    {
        var authorization = ApprovedAuthorization();
        var tampered = authorization with
        {
            Scope = authorization.Scope with { Screens = [.. authorization.Scope.Screens, "OTHER"] }
        };

        var decision = Service().Authorize(Request(authorization: tampered), CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.InvalidAuthorization, decision.Status);
        Assert.Equal("AUTH.HASH_MISMATCH", Assert.Single(decision.Issues).Code);
    }
    [Fact]
    public void Optional_Case_Quantity_And_Amount_Limits_Are_Enforced()
    {
        var scope = Scope() with { MaximumCaseCount = 1, MaximumQuantity = 10, MaximumAmount = 1000 };
        var authorization = ApprovedAuthorization(scope);
        var accepted = Request(authorization: authorization) with
        {
            RequestedCaseCount = 1, RequestedQuantity = 10, RequestedAmount = 1000
        };
        var exceeded = accepted with { RequestedCaseCount = 2 };

        var acceptedDecision = Service().Authorize(accepted, CheckedAt);
        var exceededDecision = Service().Authorize(exceeded, CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.Authorized, acceptedDecision.Status);
        Assert.Equal(ExecutionAuthorizationStatus.ScopeViolation, exceededDecision.Status);
        Assert.Equal("AUTH.SCOPE_CASE_LIMIT", Assert.Single(exceededDecision.Issues).Code);
        Assert.Equal(0, acceptedDecision.ActualActionCallCount);
        Assert.Equal(0, exceededDecision.ActualActionCallCount);
    }


    [Fact]
    public void Control_Approval_Without_Environment_Authorization_Blocks_Transaction()
    {
        var decision = Service().Authorize(Request() with { Authorization = null }, CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.EnvironmentApprovalRequired, decision.Status);
    }

    [Fact]
    public void Environment_Authorization_Without_Control_Approval_Blocks_Transaction()
    {
        var entry = ApprovedStableEntry() with
        {
            Status = ControlRepositoryEntryStatus.ReviewRequired,
            Approval = new(), ApprovalPayloadHash = "", ControlContractHash = ""
        };

        var decision = Service().Authorize(Request(entry: entry), CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.ControlApprovalRequired, decision.Status);
    }

    [Fact]
    public void Both_Approvals_Authorize_A_Fake_Transactional_Plan_Without_Action()
    {
        var decision = Service().Authorize(Request(), CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.Authorized, decision.Status);
        Assert.True(decision.IsAuthorized);
        Assert.Empty(decision.Issues);
        Assert.Equal(0, decision.ActualActionCallCount);
        Assert.Single(decision.ControlContractHashes);
    }

    [Fact]
    public void Unapproved_Coordinate_Transactional_And_Image_Physical_Are_Blocked()
    {
        var coordinate = ApprovedCoordinateEntry() with
        {
            RiskClass = ControlRiskClass.Transactional,
            TransactionalRole = ControlTransactionalRole.FinalSubmit,
            AllowedActions = [ControlRepositoryAction.FinalSubmit],
            Approval = new(), ApprovalPayloadHash = "", ControlContractHash = "",
            Status = ControlRepositoryEntryStatus.ReviewRequired
        };
        var coordinateDecision = Service().Authorize(Request(entry: coordinate), CheckedAt);

        var visual = ApprovedVisualEntry();
        var visualDecision = Service().Authorize(Request(entry: visual, requirement: Requirement(visual) with
        {
            Action = ControlRepositoryAction.Click, RiskClass = ControlRiskClass.ObservationOnly,
            PhysicalAction = true, TransactionalAction = false, OrderType = ""
        }, authorization: ApprovedAuthorization(Scope() with
        {
            AllowedActions = [ControlRepositoryAction.Click], AllowedRiskClasses = [ControlRiskClass.ObservationOnly]
        })), CheckedAt);

        Assert.Equal(ExecutionAuthorizationStatus.ControlApprovalRequired, coordinateDecision.Status);
        Assert.Equal("AUTH.IMAGE_ONLY_PHYSICAL_FORBIDDEN", Assert.Single(visualDecision.Issues).Code);
    }

    [Fact]
    public void Legacy_Authorization_Without_Hash_Version_Is_Deserializable_But_Requires_Reapproval()
    {
        var current = ApprovedAuthorization();
        var node = JsonNode.Parse(JsonSerializer.Serialize(current, JsonDefaults.Options))!.AsObject();
        Assert.True(node.Remove("authorizationHashVersion"));
        var legacy = node.Deserialize<ExecutionAuthorizationDocument>(JsonDefaults.Options)!;

        var decision = Service().Authorize(Request(authorization: legacy), CheckedAt);

        Assert.Empty(legacy.AuthorizationHashVersion);
        Assert.Equal(ExecutionAuthorizationStatus.InvalidAuthorization, decision.Status);
        Assert.Equal("AUTH.HASH_VERSION_UNSUPPORTED", Assert.Single(decision.Issues).Code);
        Assert.Equal(0, decision.ActualActionCallCount);
    }

    [Fact]
    public void Legacy_Optional_Fields_Remain_Deserializable_But_Do_Not_Grant_New_Authorization()
    {
        var legacy = JsonSerializer.Deserialize<ControlRepositoryEntry>(
            """{"key":{"screen":"F001","map":"FAKE-MAP","logicalName":"legacy","stateContext":"state:a"}}""",
            JsonDefaults.Options)!;

        Assert.Empty(legacy.ControlContractHash);
        Assert.Empty(legacy.TargetProfileId);
        Assert.Equal(ControlTransactionalRole.None, legacy.TransactionalRole);
    }

    private static IExecutionAuthorizationService Service() => new ExecutionAuthorizationService();

    private static ExecutionAuthorizationRequest Request(ControlRepositoryEntry? entry = null,
        ExecutionAuthorizationDocument? authorization = null, EnvironmentFingerprintInput? currentEnvironment = null,
        ExecutionControlRequirement? requirement = null, string planHash = "plan-a")
    {
        entry ??= ApprovedStableEntry();
        authorization ??= ApprovedAuthorization();
        requirement ??= Requirement(entry);
        return new()
        {
            CurrentEnvironment = currentEnvironment ?? Environment(), Authorization = authorization,
            Repository = Repository(entry), Requirements = [requirement], ControlObservations = [Observation(entry)],
            RequestedCaseCount = 1, PlanHash = planHash
        };
    }

    private static ExecutionControlRequirement Requirement(ControlRepositoryEntry entry) => new()
    {
        RepositoryKey = entry.Key.Canonical, ControlContractHash = entry.ControlContractHash,
        Action = ControlRepositoryAction.FinalSubmit, RiskClass = ControlRiskClass.Transactional,
        PhysicalAction = true, TransactionalAction = true, OrderType = "LIMIT"
    };

    private static ControlContractObservation Observation(ControlRepositoryEntry entry) => new()
    {
        Key = entry.Key, StateContext = entry.Key.StateContext, StableIdentity = entry.StableIdentity,
        MapRuntimeBinding = entry.MapRuntimeBinding, AnchoredRelativeCoordinate = entry.AnchoredRelativeCoordinate,
        ExpectedControlKind = entry.ExpectedControlKind, VisualSignatureMatched = true,
        ProcessName = entry.HostFingerprint!.ProcessName, ProcessFingerprint = entry.HostFingerprint.ProcessFingerprint,
        HostFingerprint = entry.HostFingerprint.HostFingerprint,
        WindowWidth = 1200, WindowHeight = 800, ClientWidth = 1100, ClientHeight = 700, DpiScale = 1
    };

    private static ControlRepositoryDocument Repository(ControlRepositoryEntry entry) => new()
    {
        RepositoryId = "fixture-repository", TargetProfileId = "fixture-target",
        Status = ControlRepositoryStatus.Ready, Entries = [entry]
    };

    private static ControlRepositoryEntry ApprovedStableEntry() => Approve(new()
    {
        Key = Key(), TargetProfileId = "fixture-target", BusinessRole = "order-final-submit",
        TransactionalRole = ControlTransactionalRole.FinalSubmit, Status = ControlRepositoryEntryStatus.ReviewRequired,
        StableIdentity = new() { AutomationId = "fixture-order-button", NativeClass = "Button", NativeControlId = "100", NativeIdentityHash = "stable-1" },
        HostFingerprint = Host(), ExpectedControlKind = "Button", RiskClass = ControlRiskClass.Transactional,
        AllowedActions = [ControlRepositoryAction.FinalSubmit], ForbiddenActions = [],
        CreatedAt = ApprovedAt.AddDays(-1), Source = "fixture:synthetic", EvidenceRefs = ["fixture:redacted"]
    });

    private static ControlRepositoryEntry ApprovedCoordinateEntry() => Approve(new()
    {
        Key = Key(), TargetProfileId = "fixture-target", BusinessRole = "non-transactional-input",
        Status = ControlRepositoryEntryStatus.ReviewRequired,
        AnchoredRelativeCoordinate = new()
        {
            CoordinateSpace = ControlRepositoryCoordinateSpace.MapHostClient,
            RelativeX = 0.5, RelativeY = 0.5, RelativeWidth = 0.1, RelativeHeight = 0.1, AnchorId = "fixture-anchor"
        },
        HostFingerprint = Host(), ExpectedControlKind = "Edit",
        VisualSignature = new() { Algorithm = "fixture", SignatureHash = "redacted-signature", MinimumSimilarity = 1 },
        RiskClass = ControlRiskClass.LimitedNonTransactional, AllowedActions = [ControlRepositoryAction.Input],
        ForbiddenActions = [ControlRepositoryAction.FinalSubmit, ControlRepositoryAction.AmendSubmit, ControlRepositoryAction.CancelSubmit],
        CreatedAt = ApprovedAt.AddDays(-1), Source = "fixture:synthetic", EvidenceRefs = ["fixture:redacted"]
    });

    private static ControlRepositoryEntry ApprovedVisualEntry() => Approve(new()
    {
        Key = Key(), TargetProfileId = "fixture-target", BusinessRole = "visual-observation",
        Status = ControlRepositoryEntryStatus.ReviewRequired, HostFingerprint = Host(), ExpectedControlKind = "Text",
        VisualSignature = new() { Algorithm = "fixture", SignatureHash = "redacted-signature", MinimumSimilarity = 1 },
        RiskClass = ControlRiskClass.ObservationOnly, AllowedActions = [ControlRepositoryAction.Click], ForbiddenActions = [],
        CreatedAt = ApprovedAt.AddDays(-1), Source = "fixture:synthetic", EvidenceRefs = ["fixture:redacted"]
    });

    private static ControlRepositoryEntry Approve(ControlRepositoryEntry review)
    {
        var template = ControlRepositoryApprovalWorkflow.CreateTemplate(review);
        return ControlRepositoryApprovalWorkflow.Apply(review, template with
        {
            Status = TestPackApprovalStatus.Approved, ApprovedBy = "fixture-reviewer",
            ApprovedAt = ApprovedAt, EvidenceRefs = ["fixture:human-approval"]
        });
    }

    private static ExecutionAuthorizationDocument ApprovedAuthorization(ExecutionAuthorizationScope? scope = null, EnvironmentFingerprintInput? environment = null)
    {
        var draft = new ExecutionAuthorizationDraft { Environment = environment ?? Environment(), Scope = scope ?? Scope() };
        var template = ExecutionAuthorizationWorkflow.CreateTemplate(draft);
        return ExecutionAuthorizationWorkflow.Apply(draft, template with
        {
            Status = TestPackApprovalStatus.Approved, ApprovedBy = "fixture-environment-reviewer",
            ApprovedAt = ApprovedAt, EvidenceRefs = ["fixture:classified-environment"]
        });
    }

    private static EnvironmentFingerprintInput Environment() => new()
    {
        TargetId = "fixture-target", ProductClassification = "synthetic-hts",
        ExecutableFingerprint = "exe-redacted-hash", InstallationFingerprint = "install-redacted-hash",
        VersionFingerprint = "1.0", HostClassification = "isolated-test-host", MachineFingerprint = "machine-redacted-hash",
        EnvironmentClassification = ExecutionEnvironmentClassification.Test, RoutingClassification = "simulation-routing",
        AccountClassification = ExecutionAccountClassification.Test, AdapterVersion = "fixture-adapter/1.0",
        ExecutionPolicyVersion = "fixture-policy/1.0"
    };

    private static ExecutionAuthorizationScope Scope() => new()
    {
        PolicyVersion = "fixture-policy/1.0", TargetIds = ["fixture-target"], Screens = ["F001"], Maps = ["FAKE-MAP"],
        AllowedActions = [ControlRepositoryAction.FinalSubmit], AllowedRiskClasses = [ControlRiskClass.Transactional],
        TransactionalActionsAllowed = true, AllowedOrderTypes = ["LIMIT"], ExpiresAt = ApprovedAt.AddDays(30)
    };

    private static ControlRepositoryKey Key() => new() { Screen = "F001", Map = "FAKE-MAP", LogicalName = "order-submit", StateContext = "state:a" };

    private static ControlHostFingerprint Host() => new()
    {
        ProcessName = "fixture-process", ProcessFingerprint = "fixture-process-hash", HostFingerprint = "fixture-host-hash",
        CapturedWindowWidth = 1200, CapturedWindowHeight = 800, CapturedClientWidth = 1100, CapturedClientHeight = 700, CapturedDpiScale = 1
    };
}
