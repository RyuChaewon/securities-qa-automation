// Role: adapts observation documents to the canonical Core ResultEvaluator and writes results.
// Inputs/outputs: preserves the existing CLI arguments, JSON protocol, and exit-code behavior.
// Boundary: delegates domain policy to HtsQa.Core and never starts HTS, FlaUI, or physical UI actions.
using System.Text.Json;
using HtsQa.Core;
using static HtsQa.Cli.CliArguments;

namespace HtsQa.Cli;

internal static class EvaluationCommands
{
    // TestPack과 원시 Observation 파일을 읽고 순수 ResultEvaluator가 만든 완성 TestResult만 출력한다.
    internal static int EvaluateResults(CliCommandContext context, string[] argv)
    {
        var testPackPath = context.Full(Required(argv, "--test-pack"));
        var observationsPath = context.Full(Required(argv, "--observations"));
        var outputPath = context.Full(Required(argv, "--output"));
        if (!File.Exists(testPackPath)) throw new FileNotFoundException("TestPack 파일을 찾을 수 없습니다.", testPackPath);
        if (!File.Exists(observationsPath)) throw new FileNotFoundException("Observation 파일을 찾을 수 없습니다.", observationsPath);

        var input = JsonFile.Read<ResultEvaluationDocument>(observationsPath);
        var evaluator = new ResultEvaluator();
        var results = input.Cases.Select(evaluator.Evaluate).Concat(input.CompletedResults).ToArray();
        var testPackId = string.IsNullOrWhiteSpace(input.TestPackId)
            ? Path.GetFileNameWithoutExtension(testPackPath)
            : input.TestPackId;
        var output = new TestResultDocument
        {
            TestPackId = testPackId,
            TestPackSha256 = JsonFile.Sha256Bytes(testPackPath),
            Results = results,
            Summary = evaluator.Summarize(results),
            OverallResult = evaluator.Aggregate(string.IsNullOrWhiteSpace(input.AggregateId) ? testPackId : input.AggregateId, results)
        };
        JsonFile.Write(outputPath, output);
        Console.WriteLine(outputPath);
        return 0;
    }
}
