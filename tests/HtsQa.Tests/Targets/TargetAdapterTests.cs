// 역할: generic TargetAdapter 계약의 하위 호환성, Fake 입력 검증, 실제 target config 역직렬화를 검증한다.
// 경계: 파일을 읽는 테스트 외에는 순수 객체만 사용하며 UI나 HTS 프로세스를 시작하지 않는다.
using System.Text.Json;
using HtsQa.Core;

namespace HtsQa.Tests;

public sealed class TargetAdapterTests
{
    [Fact]
    public void Generic_Profile_Without_Adapter_Remains_Valid()
    {
        var dataset = MinimalDataset(new RuleTargetProfile
        {
            Id = "fake-target",
            DisplayName = "Fake target",
            RunLabel = "fake",
            ScreenIdPattern = "^F[0-9]{3}$",
            Window = new() { ClassName = "FakeWindow" }
        });

        var result = new RuleDatasetValidator().Validate(dataset);

        Assert.True(result.IsValid, string.Join(Environment.NewLine, result.Issues.Select(x => x.Message)));
        Assert.Null(dataset.TargetProfile.Adapter);
    }

    [Fact]
    public void Fake_Adapter_Contract_Is_Validated_Without_Target_Literals()
    {
        var profile = FakeProfile();
        var dataset = MinimalDataset(profile);

        var result = new RuleDatasetValidator().Validate(dataset);

        Assert.True(result.IsValid, string.Join(Environment.NewLine, result.Issues.Select(x => x.Message)));
        Assert.Equal("mode-a", profile.Adapter!.StatefulControls[0].Options[0].StateContext);
        Assert.Equal("FAKE_ACTION", profile.Adapter.TransactionalDialogs!.Commands[0].LogicalName);
    }

    [Fact]
    public void Invalid_Fake_Adapter_Is_Rejected_Before_Execution()
    {
        var profile = FakeProfile() with
        {
            Adapter = FakeProfile().Adapter! with
            {
                Id = "different-target",
                ScreenIds = [],
                StatefulControls =
                [
                    FakeProfile().Adapter!.StatefulControls[0] with
                    {
                        StateContextPattern = "[",
                        Options = [new() { Id = "a", Value = "0", StateContext = "not-matching" }]
                    }
                ]
            }
        };

        var issues = new RuleDatasetValidator().Validate(MinimalDataset(profile)).Issues;

        Assert.Contains(issues, x => x.Code == "RULE.ADAPTER_ID");
        Assert.Contains(issues, x => x.Code == "RULE.ADAPTER_SCREEN_ID");
        Assert.Contains(issues, x => x.Code == "RULE.ADAPTER_STATE_PATTERN");
        Assert.Contains(issues, x => x.Code == "RULE.ADAPTER_STATE_CONTEXT");
    }

    [Fact]
    public void Checked_In_Target_Profile_Satisfies_The_Generic_Contract()
    {
        var path = FindRepositoryFile("targets", "1q-hts", "0101", "target-profile.json");
        var profile = JsonSerializer.Deserialize<RuleTargetProfile>(File.ReadAllText(path), JsonDefaults.Options);

        Assert.NotNull(profile);
        var issues = RuleTargetAdapterValidator.Validate(profile!, profile!.Adapter!.ScreenIds);
        Assert.Empty(issues);
        Assert.Equal(19, profile.Map.FamilyFiles.Length);
        Assert.Equal(3, Assert.Single(profile.Adapter.StatefulControls).Options.Length);
        Assert.Equal(4, profile.Adapter.TransactionalDialogs!.Commands.Length);
    }

    private static RuleTargetProfile FakeProfile() => new()
    {
        Id = "fake-target",
        DisplayName = "Fake target",
        RunLabel = "fake",
        ScreenIdPattern = "^F[0-9]{3}$",
        Window = new() { ClassName = "FakeWindow" },
        Adapter = new()
        {
            Id = "fake-target",
            ScreenIds = ["F001"],
            Navigation = [new() { ScreenId = "F001", MenuId = "MENU_A" }],
            AutomationIds = [new() { SemanticId = "modeSelector", Value = "FAKE_MODE" }],
            StatefulControls =
            [
                new()
                {
                    SemanticId = "modeSelector",
                    ScreenId = "F001",
                    MapScreenCode = "MAP_A",
                    LogicalName = "FAKE_MODE",
                    StateContextPattern = "^mode-(a|b)$",
                    CoordinateSpace = "boundControlClient",
                    Options =
                    [
                        new() { Id = "a", Value = "0", StateContext = "mode-a", VerificationControls = ["FAKE_ACTION"] },
                        new() { Id = "b", Value = "1", StateContext = "mode-b", VerificationControls = ["FAKE_ACTION"] }
                    ]
                }
            ],
            TransactionalDialogs = new()
            {
                ConfirmationClassification = "confirm",
                FallbackMessagePattern = "action",
                PositiveButtonPattern = "^(ok|yes)$",
                PriorityButtonPattern = "^yes$",
                Commands = [new() { LogicalName = "FAKE_ACTION", MessagePattern = "action-a" }]
            }
        }
    };

    private static RuleTestDataset MinimalDataset(RuleTargetProfile profile) => new()
    {
        SchemaVersion = "2.0",
        DatasetId = "fake-dataset",
        TargetProfile = profile,
        ExecutionPolicy = new(),
        Screens = [new() { ScreenNumber = "F001", ScreenName = "Fake screen" }]
    };

    private static string FindRepositoryFile(params string[] segments)
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var candidate = Path.Combine([directory.FullName, .. segments]);
            if (File.Exists(candidate)) return candidate;
        }
        throw new FileNotFoundException($"Repository file was not found: {Path.Combine(segments)}");
    }
}
