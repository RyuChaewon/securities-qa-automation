// Role: owns common option parsing and optional JSON-output mechanics used by CLI handlers.
// Inputs/outputs: reads argv values and writes an explicitly requested JSON output or stdout value.
// Boundary: contains no domain-specific validation, command routing, or verdict policy.
using System.Text.Json;
using HtsQa.Core;

namespace HtsQa.Cli;

internal static class CliArguments
{
    internal static string Required(string[] argv, string name)
    {
        var value = GetOpt(argv, name, "");
        if (string.IsNullOrWhiteSpace(value)) throw new ArgumentException($"{name}이 필요합니다.");
        return value;
    }

    internal static string GetOpt(string[] argv, string name, string defaultValue)
    {
        for (var index = 0; index < argv.Length; index++)
        {
            if (argv[index].Equals(name, StringComparison.OrdinalIgnoreCase) && index + 1 < argv.Length) return argv[index + 1];
            if (argv[index].StartsWith(name + "=", StringComparison.OrdinalIgnoreCase)) return argv[index].Split('=', 2)[1];
        }
        return defaultValue;
    }

    internal static T[] ParseEnumList<T>(string value, string option) where T : struct, Enum =>
        value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Select(item => Enum.TryParse<T>(item, true, out var parsed)
                ? parsed
                : throw new ArgumentException($"{option}에 지원하지 않는 값이 있습니다: {item}"))
            .Distinct().ToArray();

    internal static void WriteOptionalJson<T>(CliCommandContext context, string[] argv, T value)
    {
        var outValue = GetOpt(argv, "--out", "");
        if (string.IsNullOrWhiteSpace(outValue)) Console.WriteLine(JsonSerializer.Serialize(value, JsonDefaults.Options));
        else
        {
            var outPath = context.Full(outValue);
            if (File.Exists(outPath)) throw new IOException($"출력 파일이 이미 존재합니다: {outPath}");
            JsonFile.Write(outPath, value);
            Console.WriteLine(outPath);
        }
    }
}
