// Role: owns order-scenario validation, immutable compilation, and action-free dry-run adapters.
// Inputs/outputs: preserves the existing CLI arguments, JSON protocol, and exit-code behavior.
// Boundary: delegates domain policy to HtsQa.Core and never starts HTS, FlaUI, or physical UI actions.
using System.Text.Json;
using HtsQa.Core;
using static HtsQa.Cli.CliArguments;

namespace HtsQa.Cli;

internal static class OrderScenarioCommands
{
    // Core 정적 validator 결과를 그대로 직렬화하며 판정이나 UI 실행을 하지 않는다.
    internal static int ValidateOrderScenario(CliCommandContext context, string[] argv)
    {
        var input = JsonFile.Read<OrderScenarioValidationInput>(context.Full(Required(argv, "--input")));
        var report = OrderScenarioValidator.Validate(input);
        WriteOptionalJson(context, argv, report);
        return report.IsValid ? 0 : 3;
    }

    // 정적 검증을 통과한 입력만 hash로 고정된 DryRun 계획으로 컴파일한다.
    internal static int CompileOrderScenario(CliCommandContext context, string[] argv)
    {
        var input = JsonFile.Read<OrderScenarioValidationInput>(context.Full(Required(argv, "--input")));
        var atText = GetOpt(argv, "--compiled-at", "");
        var compiledAt = string.IsNullOrWhiteSpace(atText)
            ? DateTimeOffset.Now
            : DateTimeOffset.TryParse(atText, out var parsed) ? parsed : throw new ArgumentException("--compiled-at은 ISO8601 시각이어야 합니다.");
        var result = OrderScenarioRunPlanCompiler.Compile(input, compiledAt);
        if (!result.Validation.IsValid || result.Plan is null)
        {
            Console.WriteLine(JsonSerializer.Serialize(result.Validation, JsonDefaults.Options));
            return 3;
        }
        var outPath = context.Full(Required(argv, "--out"));
        if (File.Exists(outPath)) throw new IOException($"컴파일 출력이 이미 존재합니다: {outPath}");
        JsonFile.Write(outPath, result.Plan);
        Console.WriteLine(outPath);
        return 0;
    }

    // 계획 무결성과 계약만 확인하며 실제 UI Action과 transactional Action을 모두 0으로 유지한다.
    internal static int DryRunOrderScenario(CliCommandContext context, string[] argv)
    {
        var plan = JsonFile.Read<OrderScenarioRunPlan>(context.Full(Required(argv, "--plan")));
        var result = OrderScenarioDryRun.Execute(plan);
        WriteOptionalJson(context, argv, result);
        var checks = new[]
        {
            result.PlanHashValid, result.RepositoryResolutionChecked, result.StateOrderChecked,
            result.RequiredCheckpointChecked, result.ExpectedOutcomeChecked, result.VariableBindingChecked,
            result.RiskPolicyChecked, result.AuthorizationChecked, result.RestorePlanChecked, result.ResultAndEvidenceSchemaChecked,
            result.ActualUiActionCount == 0, result.TransactionalActionCount == 0
        };
        return checks.All(x => x) ? 0 : 3;
    }
}
