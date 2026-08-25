// Role: composes the immutable command context, routes public command names, and owns top-level errors.
// Inputs/outputs: preserves command stdout/stderr and exit-code contracts while delegating domain work.
// Boundary: contains no business JSON transformation, hash policy, verdict logic, or UI execution.
using static HtsQa.Cli.CliArguments;

namespace HtsQa.Cli;

internal static class CliApplication
{
    internal static int Run(string[] args)
    {
        var context = CliCommandContext.Create();
        var command = args.FirstOrDefault()?.ToLowerInvariant() ?? "help";

        try
        {
            return command switch
            {
                "help" => CliHelp.Write(),
                "validate-rule-dataset" => DatasetCommands.ValidateRuleDataset(context, Required(args, "--file")),
                "expand-rule-cases" => DatasetCommands.ExpandRuleCases(context, args),
                "run-rule-dataset" => DatasetCommands.RunRuleDataset(context, args),
                "compile-test-pack" => TestPackCommands.CompileTestPack(context, args),
                "create-test-pack-approval" => TestPackCommands.CreateTestPackApproval(context, args),
                "validate-test-pack" => TestPackCommands.ValidateTestPack(context, args),
                "run-test-pack" => TestPackCommands.RunTestPack(context, args),
                "extract-map-models" => MapCommands.ExtractMapModels(context, args),
                "generate-rule-scenarios" => ScenarioCommands.GenerateRuleScenarios(context, args),
                "create-rule-scenario-approval" => ScenarioCommands.CreateRuleScenarioApproval(context, args),
                "validate-generated-scenarios" => ScenarioCommands.ValidateGeneratedScenarios(context, args),
                "import-generated-scenarios" => ScenarioCommands.ImportGeneratedScenarios(context, args),
                "create-scenario-approval" => ScenarioCommands.CreateScenarioApproval(context, args),
                "compile-scenarios" => ScenarioCommands.CompileScenarios(context, args),
                "plan-scenarios" => ScenarioCommands.PlanScenarios(context, args),
                "validate-control-repository" => ControlRepositoryCommands.ValidateControlRepository(context, args),
                "create-control-repository-approval" => ControlRepositoryCommands.CreateControlRepositoryApproval(context, args),
                "apply-control-repository-approval" => ControlRepositoryCommands.ApplyControlRepositoryApproval(context, args),
                "create-control-repository-review" => ControlRepositoryCommands.CreateControlRepositoryReview(context, args),
                "resolve-control-repository" => ControlRepositoryCommands.ResolveControlRepository(context, args),
                "create-execution-authorization-approval" => AuthorizationCommands.CreateExecutionAuthorizationApproval(context, args),
                "apply-execution-authorization-approval" => AuthorizationCommands.ApplyExecutionAuthorizationApproval(context, args),
                "check-execution-authorization" => AuthorizationCommands.CheckExecutionAuthorization(context, args),
                "create-calibration-session" => CalibrationCommands.CreateCalibrationSession(context, args),
                "validate-calibration-session" => CalibrationCommands.ValidateCalibrationSession(context, args),
                "create-calibration-review" => CalibrationCommands.CreateCalibrationReview(context, args),
                "register-control-repository-entry" => CalibrationCommands.RegisterControlRepositoryEntry(context, args),
                "finalize-calibration-session" => CalibrationCommands.FinalizeCalibrationSession(context, args),
                "validate-order-scenario" => OrderScenarioCommands.ValidateOrderScenario(context, args),
                "compile-order-scenario" => OrderScenarioCommands.CompileOrderScenario(context, args),
                "dry-run-order-scenario" => OrderScenarioCommands.DryRunOrderScenario(context, args),
                "materialize-scenario-bindings" => ScenarioCommands.MaterializeScenarioBindings(context, args),
                "build-physical-scenario-plan" => ScenarioCommands.BuildPhysicalScenarioPlan(context, args),
                "evaluate-results" => EvaluationCommands.EvaluateResults(context, args),
                "analyze-run" => RunAnalysisCommands.AnalyzeRun(context, GetOpt(args, "--run", "")),
                _ => Unknown($"알 수 없는 명령: {command}")
            };
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"오류: {ex.Message}");
            return 2;
        }
    }

    internal static int Unknown(string message)
    {
        Console.Error.WriteLine(message);
        return 1;
    }
}
