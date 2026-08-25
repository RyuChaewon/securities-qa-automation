// Role: owns MAP and installation catalog extraction adapters.
// Inputs/outputs: preserves the existing CLI arguments, JSON protocol, and exit-code behavior.
// Boundary: delegates domain policy to HtsQa.Core and never starts HTS, FlaUI, or physical UI actions.
using System.Text.Json;
using HtsQa.Core;
using static HtsQa.Cli.CliArguments;

namespace HtsQa.Cli;

internal static class MapCommands
{
    // 설치본 MAP과 보조 설치 자료를 구조화된 화면 카탈로그로 추출한다.
    internal static int ExtractMapModels(CliCommandContext context, string[] argv)
    {
        var screenDirectory = context.Full(Required(argv, "--screen-dir"));
        var screenNumbers = Required(argv, "--screens")
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var filePattern = GetOpt(argv, "--file-pattern", "ht{screenNumber}00.map");
        var familyFiles = GetOpt(argv, "--family-files", "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var installationRoot = GetOpt(argv, "--installation-context.RepositoryRoot", "");
        if (string.IsNullOrWhiteSpace(installationRoot))
        {
            var parent = Directory.GetParent(screenDirectory)?.FullName ?? string.Empty;
            if (File.Exists(Path.Combine(parent, "screen_hts.vst"))) installationRoot = parent;
        }
        var catalog = string.IsNullOrWhiteSpace(installationRoot)
            ? familyFiles.Length > 0
                ? new HtsMapParser().ParseFamilyCatalog(screenDirectory, screenNumbers, familyFiles, filePattern)
                : new HtsMapParser().ParseCatalog(screenDirectory, screenNumbers, filePattern)
            : new HtsInstallationCatalogBuilder().Build(context.Full(installationRoot), screenNumbers, filePattern, familyFiles);
        var json = JsonSerializer.Serialize(catalog, JsonDefaults.Options);
        var outPath = GetOpt(argv, "--out", "");
        if (string.IsNullOrWhiteSpace(outPath))
        {
            Console.WriteLine(json);
        }
        else
        {
            outPath = context.Full(outPath);
            Directory.CreateDirectory(Path.GetDirectoryName(outPath)!);
            File.WriteAllText(outPath, json, new System.Text.UTF8Encoding(false));
            Console.WriteLine(outPath);
        }
        return 0;
    }
}
