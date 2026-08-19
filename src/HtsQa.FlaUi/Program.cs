// 역할: FlaUI 자동화 엔진을 장기 실행 NDJSON 표준입출력 프로세스로 호스팅한다.
// 입력/출력: stdin의 요청 한 줄마다 stdout에 정확히 하나의 BridgeResponse JSON을 기록한다.
// 경계: stdout에는 프로토콜 JSON만 기록하고 진단 메시지는 stderr를 사용해 PowerShell 파서를 보호한다.
// 수정 지점: 프로토콜 수명주기 변경 시 Contracts와 PowerShell Invoke-FlaUiBridgeRequest를 함께 수정한다.
using System.Text;
using System.Text.Json;
using HtsQa.FlaUi;

// PowerShell 5.1에서도 한글 메시지가 깨지지 않도록 표준 입출력을 UTF-8로 고정한다.
Console.InputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
Console.OutputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

if (!args.Contains("--stdio", StringComparer.OrdinalIgnoreCase))
{
    Console.Error.WriteLine("사용법: HtsQa.FlaUi --stdio");
    return 2;
}

using var engine = new FlaUiAutomationEngine();
string? line;

// 한 요청당 반드시 한 응답을 출력해 상주 프로세스의 요청/응답 순서를 보장한다.
while ((line = Console.ReadLine()) is not null)
{
    if (string.IsNullOrWhiteSpace(line)) continue;

    BridgeRequest? request = null;
    BridgeResponse response;
    try
    {
        request = JsonSerializer.Deserialize(line, BridgeJsonContext.Default.BridgeRequest);
        response = request is null
            ? BridgeResponse.Failure(new BridgeRequest(), "INVALID_JSON", "요청 JSON을 해석할 수 없습니다.")
            : engine.Execute(request);
    }
    catch (Exception exception)
    {
        response = BridgeResponse.Failure(request ?? new BridgeRequest(), "BRIDGE_UNHANDLED_EXCEPTION", exception.Message);
    }

    Console.WriteLine(JsonSerializer.Serialize(response, BridgeJsonContext.Default.BridgeResponse));
    Console.Out.Flush();
}

return 0;
