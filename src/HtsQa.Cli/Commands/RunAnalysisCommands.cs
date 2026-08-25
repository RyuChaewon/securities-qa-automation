// Role: reads an existing run summary for display without recalculating results.
// Inputs/outputs: preserves the existing CLI arguments, JSON protocol, and exit-code behavior.
// Boundary: delegates domain policy to HtsQa.Core and never starts HTS, FlaUI, or physical UI actions.
using System.Text.Json;
using HtsQa.Core;
using static HtsQa.Cli.CliArguments;

namespace HtsQa.Cli;

internal static class RunAnalysisCommands
{
    // 기존 실행 폴더의 요약 JSON을 콘솔에 표시한다.
    internal static int AnalyzeRun(CliCommandContext context, string run)
    {
        if (string.IsNullOrWhiteSpace(run)) return CliApplication.Unknown("analyze-run에는 --run이 필요합니다.");
        var summaryPath = Path.Combine(context.Full(run), "summary.json");
        if (!File.Exists(summaryPath)) return CliApplication.Unknown($"summary.json을 찾을 수 없습니다: {summaryPath}");
        Console.WriteLine(File.ReadAllText(summaryPath));
        return 0;
    }
}
