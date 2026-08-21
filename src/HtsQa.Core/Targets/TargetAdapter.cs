// 역할: generic engine이 대상별 화면, 상태형 컨트롤, 확인 대화상자를 읽는 순수 계약을 정의한다.
// 경계: UI, 파일 시스템, PowerShell에 의존하지 않으며 대상별 literal은 이 형식의 외부 config에만 둔다.
using System.Text.RegularExpressions;

namespace HtsQa.Core;

public sealed record RuleTargetNavigationEntry
{
    public string ScreenId { get; init; } = "";
    public string MenuId { get; init; } = "";
}

public sealed record RuleTargetAutomationId
{
    public string SemanticId { get; init; } = "";
    public string Value { get; init; } = "";
}

public sealed record RuleTargetStateOption
{
    public string Id { get; init; } = "";
    public string Value { get; init; } = "";
    public string DisplayValue { get; init; } = "";
    public string StateContext { get; init; } = "";
    public int X { get; init; }
    public string[] VerificationControls { get; init; } = [];
    public string[] CommandControls { get; init; } = [];
}

public sealed record RuleTargetStatefulControl
{
    public string SemanticId { get; init; } = "";
    public string ScreenId { get; init; } = "";
    public string MapScreenCode { get; init; } = "";
    public string LogicalName { get; init; } = "";
    public string StateContextPattern { get; init; } = "";
    public string CoordinateSpace { get; init; } = "";
    public string DefaultValue { get; init; } = "";
    public string SelectionRequiredErrorCode { get; init; } = "TARGET_STATE_NOT_SELECTED";
    public string ProfileValueMissingErrorCode { get; init; } = "TARGET_STATE_PROFILE_VALUE_MISSING";
    public string StateMismatchErrorCode { get; init; } = "TARGET_STATE_MISMATCH";
    public int Y { get; init; }
    public RuleTargetStateOption[] Options { get; init; } = [];
}

public sealed record RuleTargetCommandMessageMatcher
{
    public string LogicalName { get; init; } = "";
    public string MessagePattern { get; init; } = "";
}

public sealed record RuleTargetTransactionalDialogs
{
    public string ConfirmationClassification { get; init; } = "";
    public string FallbackMessagePattern { get; init; } = "";
    public string PositiveButtonPattern { get; init; } = "";
    public string PriorityButtonPattern { get; init; } = "";
    public RuleTargetCommandMessageMatcher[] Commands { get; init; } = [];
}

public sealed record RuleTargetMapHost
{
    public string ScreenId { get; init; } = "";
    public string MapScreenCode { get; init; } = "";
    public string ContainerScreenCode { get; init; } = "";
    public string HostRole { get; init; } = "";
    public int? TabIndex { get; init; }
    public int MapOriginX { get; init; }
    public int MapOriginY { get; init; }
    public int? ClipMapHeight { get; init; }
    public double Scale { get; init; } = 1.0;
    public int MatchTolerancePx { get; init; } = 8;
    public int MaxDimensionDeltaPx { get; init; } = 12;
    public bool AllowOwnerDrawnKindOverride { get; init; }
}

public sealed record RuleTargetImportProfile
{
    public string[] CandidateSheetNames { get; init; } = [];
    public int RequiredMapFamilyCount { get; init; }
    public string ActiveStateMapScreenCode { get; init; } = "";
}

/// <summary>대상별 업무 의미를 generic engine에 전달하는 versioned adapter 계약이다.</summary>
public sealed record RuleTargetAdapterProfile
{
    public string SchemaVersion { get; init; } = "1.0";
    public string Id { get; init; } = "";
    public string[] ScreenIds { get; init; } = [];
    public RuleTargetNavigationEntry[] Navigation { get; init; } = [];
    public RuleTargetAutomationId[] AutomationIds { get; init; } = [];
    public RuleTargetStatefulControl[] StatefulControls { get; init; } = [];
    public RuleTargetTransactionalDialogs? TransactionalDialogs { get; init; }
    public RuleTargetMapHost[] MapHosts { get; init; } = [];
    public Dictionary<string, string> MapAliases { get; init; } = [];
    public RuleTargetImportProfile? Import { get; init; }
}

/// <summary>Core 계획기가 adapter의 map alias와 state-context 의미를 동일하게 적용하게 한다.</summary>
public static class RuleTargetAdapterMatcher
{
    public static string ResolveMapScreenCode(RuleTargetAdapterProfile? adapter, string? mapScreenCode)
    {
        var value = mapScreenCode ?? "";
        if (adapter is null) return value;
        return adapter.MapAliases.TryGetValue(value, out var resolved) ? resolved : value;
    }

    public static bool IsStateContext(RuleTargetAdapterProfile? adapter, string? stateContext)
    {
        if (adapter is null || string.IsNullOrWhiteSpace(stateContext)) return false;
        foreach (var control in adapter.StatefulControls)
        {
            try
            {
                if (!string.IsNullOrWhiteSpace(control.StateContextPattern) &&
                    Regex.IsMatch(stateContext, control.StateContextPattern, RegexOptions.CultureInvariant)) return true;
            }
            catch (ArgumentException) { return false; }
        }
        return false;
    }
}

/// <summary>adapter의 구조와 정규식을 UI 실행 전에 검증한다.</summary>
public static class RuleTargetAdapterValidator
{
    public static IReadOnlyList<ValidationIssue> Validate(RuleTargetProfile targetProfile, IEnumerable<string> datasetScreenIds)
    {
        var adapter = targetProfile.Adapter;
        if (adapter is null) return [];

        var issues = new List<ValidationIssue>();
        if (adapter.SchemaVersion != "1.0")
            issues.Add(new("RULE.ADAPTER_SCHEMA_VERSION", "targetProfile.adapter.schemaVersion must be 1.0.", Field: "targetProfile.adapter.schemaVersion"));
        if (string.IsNullOrWhiteSpace(adapter.Id) || !adapter.Id.Equals(targetProfile.Id, StringComparison.Ordinal))
            issues.Add(new("RULE.ADAPTER_ID", "targetProfile.adapter.id must match targetProfile.id.", Field: "targetProfile.adapter.id"));
        AddRequiredUnique(adapter.ScreenIds, "RULE.ADAPTER_SCREEN_ID", "targetProfile.adapter.screenIds", issues);

        var adapterScreens = adapter.ScreenIds.ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var screenId in datasetScreenIds.Where(x => !adapterScreens.Contains(x)))
            issues.Add(new("RULE.ADAPTER_SCREEN_MISSING", $"Adapter does not declare dataset screen {screenId}.", Field: "targetProfile.adapter.screenIds"));

        AddUnique(adapter.Navigation.Select(x => x.ScreenId), "RULE.ADAPTER_NAVIGATION_DUPLICATE", "targetProfile.adapter.navigation", issues);
        foreach (var entry in adapter.Navigation)
        {
            if (string.IsNullOrWhiteSpace(entry.ScreenId) || string.IsNullOrWhiteSpace(entry.MenuId))
                issues.Add(new("RULE.ADAPTER_NAVIGATION", "Adapter navigation requires screenId and menuId.", Field: "targetProfile.adapter.navigation"));
            else if (!adapterScreens.Contains(entry.ScreenId))
                issues.Add(new("RULE.ADAPTER_NAVIGATION_SCREEN", $"Navigation screen {entry.ScreenId} is not declared by the adapter.", Field: "targetProfile.adapter.navigation"));
        }

        AddUnique(adapter.AutomationIds.Select(x => x.SemanticId), "RULE.ADAPTER_AUTOMATION_ID_DUPLICATE", "targetProfile.adapter.automationIds", issues);
        if (adapter.AutomationIds.Any(x => string.IsNullOrWhiteSpace(x.SemanticId) || string.IsNullOrWhiteSpace(x.Value)))
            issues.Add(new("RULE.ADAPTER_AUTOMATION_ID", "Adapter automationIds require semanticId and value.", Field: "targetProfile.adapter.automationIds"));

        AddUnique(adapter.StatefulControls.Select(StatefulKey), "RULE.ADAPTER_STATEFUL_DUPLICATE", "targetProfile.adapter.statefulControls", issues);
        foreach (var control in adapter.StatefulControls)
        {
            if (string.IsNullOrWhiteSpace(control.SemanticId) || string.IsNullOrWhiteSpace(control.ScreenId) ||
                string.IsNullOrWhiteSpace(control.MapScreenCode) || string.IsNullOrWhiteSpace(control.LogicalName) || control.Options.Length == 0)
                issues.Add(new("RULE.ADAPTER_STATEFUL_CONTROL", "Stateful controls require identity, host and at least one option.", Field: "targetProfile.adapter.statefulControls"));
            if (!adapterScreens.Contains(control.ScreenId))
                issues.Add(new("RULE.ADAPTER_STATEFUL_SCREEN", $"Stateful control screen {control.ScreenId} is not declared by the adapter.", Field: "targetProfile.adapter.statefulControls"));
            if (string.IsNullOrWhiteSpace(control.SelectionRequiredErrorCode) || string.IsNullOrWhiteSpace(control.ProfileValueMissingErrorCode) ||
                string.IsNullOrWhiteSpace(control.StateMismatchErrorCode))
                issues.Add(new("RULE.ADAPTER_STATE_ERROR_CODE", "Stateful controls require non-empty compatibility error codes.", Field: "targetProfile.adapter.statefulControls"));
            AddRegex(control.StateContextPattern, "RULE.ADAPTER_STATE_PATTERN", "targetProfile.adapter.statefulControls.stateContextPattern", issues);
            AddRequiredUnique(control.Options.Select(x => x.Id), "RULE.ADAPTER_STATE_OPTION_ID", "targetProfile.adapter.statefulControls.options.id", issues);
            AddRequiredUnique(control.Options.Select(x => x.Value), "RULE.ADAPTER_STATE_OPTION_VALUE", "targetProfile.adapter.statefulControls.options.value", issues);
            foreach (var option in control.Options)
            {
                if (string.IsNullOrWhiteSpace(option.StateContext) || !Matches(control.StateContextPattern, option.StateContext))
                    issues.Add(new("RULE.ADAPTER_STATE_CONTEXT", $"State option {option.Id} does not match the configured stateContextPattern.", Field: "targetProfile.adapter.statefulControls.options.stateContext"));
            }
        }

        if (adapter.TransactionalDialogs is { } dialogs)
        {
            AddRegex(dialogs.FallbackMessagePattern, "RULE.ADAPTER_DIALOG_FALLBACK_PATTERN", "targetProfile.adapter.transactionalDialogs.fallbackMessagePattern", issues);
            AddRegex(dialogs.PositiveButtonPattern, "RULE.ADAPTER_DIALOG_BUTTON_PATTERN", "targetProfile.adapter.transactionalDialogs.positiveButtonPattern", issues);
            AddRegex(dialogs.PriorityButtonPattern, "RULE.ADAPTER_DIALOG_PRIORITY_PATTERN", "targetProfile.adapter.transactionalDialogs.priorityButtonPattern", issues);
            AddRequiredUnique(dialogs.Commands.Select(x => x.LogicalName), "RULE.ADAPTER_DIALOG_COMMAND", "targetProfile.adapter.transactionalDialogs.commands.logicalName", issues);
            foreach (var command in dialogs.Commands)
                AddRegex(command.MessagePattern, "RULE.ADAPTER_DIALOG_MESSAGE_PATTERN", "targetProfile.adapter.transactionalDialogs.commands.messagePattern", issues);
        }

        AddUnique(adapter.MapHosts.Select(x => $"{x.ScreenId}|{x.MapScreenCode}"), "RULE.ADAPTER_MAP_HOST_DUPLICATE", "targetProfile.adapter.mapHosts", issues);
        if (adapter.MapHosts.Any(x => string.IsNullOrWhiteSpace(x.ScreenId) || string.IsNullOrWhiteSpace(x.MapScreenCode) ||
                                      string.IsNullOrWhiteSpace(x.ContainerScreenCode) || string.IsNullOrWhiteSpace(x.HostRole) || x.Scale <= 0))
            issues.Add(new("RULE.ADAPTER_MAP_HOST", "Adapter map hosts require screen, map, container, role and positive scale.", Field: "targetProfile.adapter.mapHosts"));
        if (adapter.MapAliases.Any(x => string.IsNullOrWhiteSpace(x.Key) || string.IsNullOrWhiteSpace(x.Value)))
            issues.Add(new("RULE.ADAPTER_MAP_ALIAS", "Adapter map aliases require non-empty source and target values.", Field: "targetProfile.adapter.mapAliases"));

        return issues;
    }

    private static string StatefulKey(RuleTargetStatefulControl control) => $"{control.ScreenId}|{control.MapScreenCode}|{control.LogicalName}";

    private static void AddRegex(string pattern, string code, string field, List<ValidationIssue> issues)
    {
        if (string.IsNullOrWhiteSpace(pattern))
        {
            issues.Add(new(code, $"{field} is required.", Field: field));
            return;
        }
        try { _ = new Regex(pattern, RegexOptions.CultureInvariant); }
        catch (ArgumentException) { issues.Add(new(code, $"{field} must be a valid regular expression.", Field: field)); }
    }

    private static bool Matches(string pattern, string value)
    {
        try { return Regex.IsMatch(value, pattern, RegexOptions.CultureInvariant); }
        catch (ArgumentException) { return false; }
    }

    private static void AddRequiredUnique(IEnumerable<string> values, string code, string field, List<ValidationIssue> issues)
    {
        var items = values.ToArray();
        if (items.Length == 0 || items.Any(string.IsNullOrWhiteSpace))
            issues.Add(new(code, $"{field} requires non-empty values.", Field: field));
        AddUnique(items, code, field, issues);
    }

    private static void AddUnique(IEnumerable<string> values, string code, string field, List<ValidationIssue> issues)
    {
        var items = values.Where(x => !string.IsNullOrWhiteSpace(x)).ToArray();
        if (items.Distinct(StringComparer.OrdinalIgnoreCase).Count() != items.Length)
            issues.Add(new(code, $"{field} contains duplicate values.", Field: field));
    }
}
