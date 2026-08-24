// 역할: UI 공급자 없이 SetText action 전달과 readback 검증 의미를 고정한다.
// 안전: 민감값은 응답이나 직렬화 결과에 평문으로 남지 않아야 한다.
using System.Text.Json;
using HtsQa.FlaUi;

namespace HtsQa.Tests;

public sealed class FlaUiTextActionSemanticsTests
{
    [Theory]
    [InlineData("ABC", true, "ABC", true)]
    [InlineData("ABC", true, "XYZ", false)]
    [InlineData("ABC", true, "", false)]
    [InlineData("ABC", false, "", false)]
    public void SetText_Readback_Truth_Table(
        string expected,
        bool readbackAvailable,
        string observed,
        bool verified)
    {
        var response = FlaUiAutomationEngine.CompleteSetTextAction(
            new BridgeRequest { RequestId = "text", Value = expected },
            "ValuePattern.SetValue",
            readbackAvailable,
            observed,
            sensitive: false);

        Assert.True(response.Success);
        Assert.True(response.ActionSent);
        Assert.Equal(verified, response.Verified);
        Assert.Equal(verified, response.ActionVerified);
        Assert.Equal(observed, response.ObservedValue);
    }

    [Fact]
    public void SetText_Action_Failure_Is_Not_Sent_Or_Verified()
    {
        var response = BridgeResponse.Failure(
            new BridgeRequest { RequestId = "failed", Value = "not-recorded" },
            "UIA3_ACTION_FAILED",
            "action failed");

        Assert.False(response.Success);
        Assert.False(response.Verified);
        Assert.False(response.ActionSent);
        Assert.False(response.ActionVerified);
    }

    [Fact]
    public void Password_SetText_Is_Delivery_Only_And_Does_Not_Serialize_Plaintext()
    {
        const string secret = "plain-password-value";
        var response = FlaUiAutomationEngine.CompleteSetTextAction(
            new BridgeRequest { RequestId = "password", Value = secret, Sensitive = true },
            "ValuePattern.SetValue",
            readbackAvailable: true,
            observedValue: secret,
            sensitive: true);

        Assert.True(response.ActionSent);
        Assert.False(response.ActionVerified);
        Assert.True(response.Success);
        Assert.False(response.Verified);
        Assert.Empty(response.ObservedValue);
        Assert.DoesNotContain(secret, JsonSerializer.Serialize(response), StringComparison.Ordinal);
        Assert.DoesNotContain(secret, response.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Legacy_Success_And_Verified_Fields_Remain_Serialized()
    {
        var response = FlaUiAutomationEngine.CompleteSetTextAction(
            new BridgeRequest { RequestId = "compatible", Value = "ABC" },
            "ValuePattern.SetValue",
            readbackAvailable: true,
            observedValue: "ABC",
            sensitive: false);

        var json = JsonSerializer.Serialize(response);

        Assert.Contains("\"success\":true", json, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("\"verified\":true", json, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("\"actionSent\":true", json, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("\"actionVerified\":true", json, StringComparison.OrdinalIgnoreCase);
    }
}
