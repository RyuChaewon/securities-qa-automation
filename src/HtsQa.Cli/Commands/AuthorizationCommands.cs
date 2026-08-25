// Role: adapts approval templates and canonical Core authorization decisions to JSON CLI I/O.
// Boundary: contains no hash, scope, risk, verdict, HTS, FlaUI, or physical-action logic.
using System.Text.Json;
using HtsQa.Core;
using static HtsQa.Cli.CliArguments;

namespace HtsQa.Cli;

internal static class AuthorizationCommands
{
    internal static int CreateExecutionAuthorizationApproval(CliCommandContext context, string[] argv)
    {
        var requestPath = context.Full(Required(argv, "--request"));
        var request = JsonFile.Read<ExecutionAuthorizationDraft>(requestPath);
        var template = ExecutionAuthorizationWorkflow.CreateTemplate(request);
        var outPath = context.Full(GetOpt(argv, "--out", Path.ChangeExtension(requestPath, ".approval.json")));
        if (File.Exists(outPath)) throw new IOException($"승인 template이 이미 존재합니다: {outPath}");
        JsonFile.Write(outPath, template);
        Console.WriteLine(outPath);
        return 0;
    }

    internal static int ApplyExecutionAuthorizationApproval(CliCommandContext context, string[] argv)
    {
        var requestPath = context.Full(Required(argv, "--request"));
        var request = JsonFile.Read<ExecutionAuthorizationDraft>(requestPath);
        var overlay = JsonFile.Read<TestPackApprovalOverlay>(context.Full(Required(argv, "--approval")));
        var authorization = ExecutionAuthorizationWorkflow.Apply(request, overlay);
        var outPath = context.Full(GetOpt(argv, "--out", Path.ChangeExtension(requestPath, ".authorization.json")));
        if (File.Exists(outPath)) throw new IOException($"실행 승인 결과가 이미 존재합니다: {outPath}");
        JsonFile.Write(outPath, authorization);
        Console.WriteLine(outPath);
        return authorization.Approval.Status == TestPackApprovalStatus.Approved ? 0 : 3;
    }

    internal static int CheckExecutionAuthorization(CliCommandContext context, string[] argv)
    {
        var request = JsonFile.Read<ExecutionAuthorizationRequest>(context.Full(Required(argv, "--request")));
        var atText = Required(argv, "--checked-at");
        if (!DateTimeOffset.TryParse(atText, out var checkedAt))
            throw new ArgumentException("--checked-at은 ISO8601 시각이어야 합니다.");
        var decision = new ExecutionAuthorizationService().Authorize(request, checkedAt);
        var output = GetOpt(argv, "--out", "");
        if (string.IsNullOrWhiteSpace(output)) Console.WriteLine(JsonSerializer.Serialize(decision, JsonDefaults.Options));
        else
        {
            var outPath = context.Full(output);
            JsonFile.Write(outPath, decision);
            Console.WriteLine(outPath);
        }
        return decision.IsAuthorized ? 0 : 3;
    }
}
