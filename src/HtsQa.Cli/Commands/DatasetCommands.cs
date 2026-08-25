// Role: owns dataset validation, expansion, and the retired direct-run command.
// Inputs/outputs: preserves the existing CLI arguments, JSON protocol, and exit-code behavior.
// Boundary: delegates domain policy to HtsQa.Core and never starts HTS, FlaUI, or physical UI actions.
using System.Text.Json;
using HtsQa.Core;
using static HtsQa.Cli.CliArguments;

namespace HtsQa.Cli;

internal static class DatasetCommands
{
    // 기준 데이터셋의 형식과 예상 조합 수를 검사한다.
    internal static int ValidateRuleDataset(CliCommandContext context, string file)
    {
        var dataset = JsonFile.Read<RuleTestDataset>(context.Full(file));
        var validation = new RuleDatasetValidator().Validate(dataset);
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            validation.IsValid,
            combinationPolicy = dataset.CombinationPolicy,
            projectedCases = validation.IsValid ? new CombinationGenerator().CountCases(dataset) : 0,
            validation.Issues
        }, JsonDefaults.Options));
        return validation.IsValid ? 0 : 1;
    }

    // 활성 계정·화면·명시 변수를 실제 실행 케이스 목록으로 확장한다.
    internal static int ExpandRuleCases(CliCommandContext context, string[] argv)
    {
        var dataset = LoadValidatedDataset(context, Required(argv, "--file"));
        var expanded = new CombinationGenerator().Generate(dataset).Select(RuleCaseExpander.Sanitize).ToArray();
        var defaultPath = Path.Combine(context.RepositoryRoot, "reports", $"expanded-cases-{DateTimeOffset.Now:yyyyMMdd-HHmmss}.json");
        var outPath = context.Full(GetOpt(argv, "--out", defaultPath));
        JsonFile.Write(outPath, new
        {
            datasetId = dataset.DatasetId,
            generatedAt = DateTimeOffset.Now,
            caseCount = expanded.Length,
            cases = expanded
        });
        Console.WriteLine(outPath);
        return 0;
    }

    // 제품을 조작하지 않는 드라이런 결과와 기본 리포트 JSON을 생성한다.
    internal static int RunRuleDataset(CliCommandContext context, string[] argv)
    {
        return CliApplication.Unknown("run-rule-dataset은 승인되지 않은 Dataset 직접 실행을 막기 위해 지원 종료되었습니다. compile-test-pack 후 run-test-pack을 사용하세요.");
    }

    // 모든 명령이 동일한 데이터셋 검증 경계를 사용하도록 로드 과정을 통합한다.
    internal static RuleTestDataset LoadValidatedDataset(CliCommandContext context, string file)
    {
        var dataset = JsonFile.Read<RuleTestDataset>(context.Full(file));
        var validation = new RuleDatasetValidator().Validate(dataset);
        if (!validation.IsValid)
            throw new InvalidDataException(string.Join(Environment.NewLine, validation.Issues.Select(x => $"{x.Code}: {x.Message}")));
        return dataset;
    }
}
