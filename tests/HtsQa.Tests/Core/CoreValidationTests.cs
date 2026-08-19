// 역할: 데이터셋 검증, MAP 파싱, 설치 카탈로그와 민감정보 보호의 핵심 회귀를 검증한다.
// 범위: 파일 형식과 결정론적 변환만 검증하며 실제 HTS 창을 열거나 조작하지 않는다.
// 수정 지점: Core 계약 필드나 설치 파서를 변경할 때 성공·거부 사례를 같은 책임 영역에 추가한다.
using HtsQa.Core;
using System.Text;
using System.Text.RegularExpressions;

namespace HtsQa.Tests;

public sealed class CoreValidationTests
{
    [Fact]
    public void Active_Dataset_Is_Valid_And_Contains_Only_Requested_Screens()
    {
        var dataset = LoadDataset();
        var validation = new RuleDatasetValidator().Validate(dataset);

        Assert.True(validation.IsValid, string.Join("\n", validation.Issues.Select(x => x.Message)));
        Assert.Equal(dataset.Screens.Length, RuleCaseExpander.CountCases(dataset));
        var configuredScreenPattern = new Regex(dataset.TargetProfile.ScreenIdPattern);
        Assert.All(dataset.Screens, screen => Assert.Matches(configuredScreenPattern, screen.ScreenNumber));
        Assert.All(dataset.AutoExploration.DefaultDateValues, x => Assert.True(DateOnly.TryParseExact(x.Value, "yyyyMMdd", out _)));
        var boundary = Assert.Single(dataset.AutoExploration.DefaultTextValues, x => x.Id == "최대경계");
        Assert.Equal(RuleExpectedOutcomeType.ValidationAllowed, boundary.ExpectedOutcome.Type);
        Assert.Contains(boundary.ExpectedOutcome.MessagePatterns, x => x.Contains("종목코드오류"));
    }

    [Fact]
    public void Expanded_Cases_Are_Sanitized()
    {
        var cases = RuleCaseExpander.Expand(LoadDataset());
        Assert.Equal(LoadDataset().Screens.Length, cases.Length);
        Assert.All(cases.Select(RuleCaseExpander.Sanitize), item =>
        {
            Assert.DoesNotContain("12345678", item.AccountMasked);
            Assert.Equal(12, item.AccountFingerprint.Length);
            Assert.Equal(RuleInputMode.Prefilled, item.InputMode);
            Assert.Equal("화면 기본값", item.PasswordSource);
        });
    }

    [Fact]
    public void Variables_Use_Cartesian_Product_And_Respect_Case_Limit()
    {
        var source = LoadDataset();
        var dataset = source with
        {
            Screens = source.Screens.Take(2).ToArray(),
            Variables =
            [
                new RuleVariableDimension
                {
                    Name = "period",
                    Values = [new() { Id = "d1", Value = "1" }, new() { Id = "d2", Value = "2" }]
                },
                new RuleVariableDimension
                {
                    Name = "market",
                    Values = [new() { Id = "all", Value = "all" }, new() { Id = "domestic", Value = "domestic" }]
                }
            ],
            MaxExpandedCases = 8
        };

        Assert.Equal(8, RuleCaseExpander.CountCases(dataset));
        Assert.True(new RuleDatasetValidator().Validate(dataset).IsValid);
        Assert.Contains(new RuleDatasetValidator().Validate(dataset with { MaxExpandedCases = 7 }).Issues, x => x.Code == "POLICY.CASE_LIMIT");
    }

    [Fact]
    public void Expected_Outcomes_Are_Validated_And_Propagated_To_Cases()
    {
        var source = LoadDataset();
        var expected = new RuleExpectedOutcome
        {
            Type = RuleExpectedOutcomeType.ValidationRequired,
            MessagePatterns = ["종목코드오류|등록되지 않은 종목코드"],
            QueryShouldComplete = false,
            Source = RuleExpectationSource.Dataset,
            Confidence = RuleExpectationConfidence.High,
            Evidence = ["테스트 데이터셋의 명시적 음성 입력"]
        };
        var dataset = source with
        {
            Screens = [source.Screens[0]],
            Variables =
            [
                new RuleVariableDimension
                {
                    Name = "stockCode",
                    Values = [new() { Id = "invalid", Value = "99999999", ExpectedOutcome = expected }]
                }
            ]
        };

        Assert.True(new RuleDatasetValidator().Validate(dataset).IsValid);
        var testCase = Assert.Single(RuleCaseExpander.Expand(dataset));
        Assert.Equal(RuleExpectedOutcomeType.ValidationRequired, testCase.VariableExpectedOutcomes["stockCode"].Type);
        Assert.False(testCase.VariableExpectedOutcomes["stockCode"].QueryShouldComplete);
        Assert.Equal(RuleExpectationSource.Dataset, testCase.VariableExpectedOutcomes["stockCode"].Source);
        Assert.Equal(RuleExpectationConfidence.High, testCase.VariableExpectedOutcomes["stockCode"].Confidence);

        var invalid = dataset with
        {
            Variables =
            [
                dataset.Variables[0] with
                {
                    Values = [new() { Id = "invalid", Value = "99999999", ExpectedOutcome = new() { Type = RuleExpectedOutcomeType.ValidationRequired } }]
                }
            ]
        };
        Assert.Contains(new RuleDatasetValidator().Validate(invalid).Issues, x => x.Code == "RULE.EXPECTED_VALIDATION_EVIDENCE");
    }

    [Fact]
    public void Invalid_Screen_And_Missing_Secret_Are_Rejected()
    {
        var source = LoadDataset();
        var invalid = source with
        {
            Screens = [source.Screens[0] with { ScreenNumber = "invalid-screen" }],
            Accounts = [source.Accounts[0] with { InputMode = RuleInputMode.Explicit, PasswordSecret = null }]
        };
        var issues = new RuleDatasetValidator().Validate(invalid).Issues;

        Assert.Contains(issues, x => x.Code == "RULE.SCREEN_FORMAT");
        Assert.Contains(issues, x => x.Code == "RULE.SECRET_REQUIRED");
    }

    [Fact]
    public void Custom_Target_Profile_Allows_Configured_Screen_Family_Without_Accounts()
    {
        var source = LoadDataset();
        var dataset = source with
        {
            DatasetId = "custom-target",
            TargetProfile = source.TargetProfile with
            {
                Id = "custom-screen-family",
                DisplayName = "사용자 지정 화면군",
                RunLabel = "custom-screen-family",
                ScreenIdPattern = "^8[0-9]{3}$"
            },
            Accounts = [],
            Screens = [new RuleScreenInput { ScreenNumber = "8101", ScreenName = "사용자 지정 화면" }]
        };

        var validation = new RuleDatasetValidator().Validate(dataset);
        var testCase = Assert.Single(RuleCaseExpander.Expand(dataset));

        Assert.True(validation.IsValid, string.Join("\n", validation.Issues.Select(x => x.Message)));
        Assert.Equal(1, RuleCaseExpander.CountCases(dataset));
        Assert.Equal("8101", testCase.ScreenNumber);
        Assert.Equal("default", testCase.AccountId);
        Assert.Empty(testCase.AccountNumber);
    }

    [Fact]
    public void Invalid_Control_Values_And_Limits_Are_Rejected()
    {
        var source = LoadDataset();
        var invalid = source with
        {
            Variables =
            [
                new RuleVariableDimension
                {
                    Name = "flag",
                    ControlKind = RuleControlKind.CheckBox,
                    Values = [new() { Id = "bad", Value = "maybe" }]
                }
            ],
            AutoExploration = source.AutoExploration with
            {
                InteractionStrategy = "ScreenGuess",
                MaxActionsPerScreen = 0,
                DefaultDateValues = [new() { Id = "bad-date", Value = "2026/08/01" }]
            }
        };
        var issues = new RuleDatasetValidator().Validate(invalid).Issues;

        Assert.Contains(issues, x => x.Code == "RULE.VARIABLE_CHECKED_VALUE");
        Assert.Contains(issues, x => x.Code == "RULE.AUTO_ACTION_LIMIT");
        Assert.Contains(issues, x => x.Code == "RULE.AUTO_DATE_FORMAT");
        Assert.Contains(issues, x => x.Code == "RULE.INTERACTION_STRATEGY");
    }

    [Fact]
    public void Date_Variables_Require_Compact_Year_Month_Day_Format()
    {
        var source = LoadDataset();
        var invalid = source with
        {
            Variables =
            [
                new RuleVariableDimension
                {
                    Name = "date",
                    ControlKind = RuleControlKind.Date,
                    Values = [new() { Id = "bad", Value = "20261340" }]
                }
            ]
        };

        Assert.Contains(new RuleDatasetValidator().Validate(invalid).Issues, x => x.Code == "RULE.VARIABLE_DATE_VALUE");
    }

    [Fact]
    public void Coordinate_Locators_Are_Validated()
    {
        var source = LoadDataset();
        var invalid = source with
        {
            DefaultLocators = new Dictionary<string, RuleLocatorStrategy[]>
            {
                ["query"] = [new() { RelativeX = 10 }]
            }
        };

        Assert.Contains(new RuleDatasetValidator().Validate(invalid).Issues, x => x.Code == "RULE.LOCATOR_COORDINATE_PAIR");
    }

    [Fact]
    public void Initially_Active_Map_Codes_Must_Be_Unique_And_In_Family()
    {
        var source = LoadDataset();
        var invalid = source with
        {
            TargetProfile = source.TargetProfile with
            {
                Map = source.TargetProfile.Map with
                {
                    FamilyFiles = ["ht010101.map"],
                    InitiallyActiveMapScreenCodes = ["HT010102", "bad", "HT010102"]
                }
            }
        };

        var issues = new RuleDatasetValidator().Validate(invalid).Issues;

        Assert.Contains(issues, x => x.Code == "RULE.MAP_ACTIVE_CODE");
        Assert.Contains(issues, x => x.Code == "RULE.MAP_ACTIVE_DUPLICATE");
        Assert.Contains(issues, x => x.Code == "RULE.MAP_ACTIVE_NOT_IN_FAMILY");
    }

    [Fact]
    public void Dry_Run_Is_Always_Pending()
    {
        var testCase = RuleCaseExpander.Expand(LoadDataset())[0];
        var result = new RuleDryRunExecutor().Execute("unit-dry", testCase);

        Assert.Equal(TestStatus.PENDING, result.Status);
        Assert.False(result.ErrorDetected);
        Assert.All(result.Actions, action => Assert.Equal(TestStatus.PENDING, action.Status));
    }

    [Fact]
    public void Map_Parser_Extracts_Design_Controls_And_Events()
    {
        var path = Path.Combine(Path.GetTempPath(), $"{TestTargetFixture.MapFileName}-{Guid.NewGuid():N}.map");
        try
        {
            File.WriteAllBytes(path, CreateSyntheticMap());

            var model = new HtsMapParser().Parse(path);

            Assert.Equal("1.4", model.SchemaVersion);
            Assert.Equal(TestTargetFixture.ScreenNumber, model.ScreenNumber);
            Assert.Equal(TestTargetFixture.ScreenCode, model.ScreenCode);
            Assert.Equal(TestTargetFixture.ScreenName, model.ScreenName);
            Assert.Equal(5, model.Controls.Length);
            Assert.Equal(4, model.ActionableControlCount);
            var account = Assert.Single(model.Controls, x => x.LogicalName == "ACCT_No");
            Assert.Equal(HtsMapControlKind.Account, account.Kind);
            Assert.Equal("Text", account.RuleControlKind);
            Assert.Equal(new HtsMapRect { X = 60, Y = 3, Width = 200, Height = 21 }, account.Rect);
            var query = Assert.Single(model.Controls, x => x.LogicalName == "BTN_Comm");
            Assert.Equal(HtsMapControlKind.Button, query.Kind);
            Assert.Contains("Click", query.Events);
            Assert.Equal("Query", query.SemanticRole);
            Assert.Contains("RQ_OTS0002Q00", query.TriggeredRequestNames);
            Assert.Contains("ACCT_No", query.ReadControls);
            Assert.Contains("GRID_Data", query.ResultControls);
            var autoQuery = Assert.Single(model.Controls, x => x.LogicalName == "CAL_Date");
            Assert.Equal("AutoQuery", autoQuery.SemanticRole);
            Assert.Contains("RQ_OTS0002Q00", autoQuery.TriggeredRequestNames);
            var stateController = Assert.Single(model.Controls, x => x.LogicalName == "CHK_Mode");
            Assert.Equal("StateController", stateController.SemanticRole);
            Assert.Contains("CAL_Date", stateController.AffectedControls);
            Assert.Contains("BTN_Comm", model.Behavior.QueryControls);
            Assert.Contains("CAL_Date", model.Behavior.AutoQueryControls);
            Assert.Contains("CHK_Mode", model.Behavior.StateControllerControls);
            Assert.Contains("ACCT_No", model.Behavior.InputControls);
            Assert.Contains("GRID_Data", model.Behavior.ResultControls);
            Assert.True(model.ErrorOracle.HasReceiveErrorParameters);
            Assert.True(model.ErrorOracle.HasOnErrorHandler);
            Assert.Contains("ACCT_No_OnError", model.ErrorOracle.ErrorHandlers);
            Assert.Contains("RQ_OTS0002Q00", model.ErrorOracle.RequestNames);
            Assert.Contains("OTS0002Q00", model.ErrorOracle.TransactionCodes);
            var validationMessage = Assert.Single(model.ErrorOracle.MessageBoxes, x => x.Message == "계좌번호를 확인하십시오.");
            Assert.Equal("InputValidation", validationMessage.Classification);
            Assert.False(validationMessage.IsExplicitError);
            var errorMessage = Assert.Single(model.ErrorOracle.MessageBoxes, x => x.Message == "처리 오류가 발생했습니다.");
            Assert.Equal("Error", errorMessage.Classification);
            Assert.True(errorMessage.IsExplicitError);
            var businessValidation = Assert.Single(model.ErrorOracle.MessageBoxes, x => x.Message == "일괄매도할 주문이 없습니다");
            Assert.Equal("InputValidation", businessValidation.Classification);
            Assert.False(businessValidation.IsExplicitError);
            var variableValidation = Assert.Single(model.ErrorOracle.MessageBoxes, x => x.Message == "선택 항목을 확인하십시오.");
            Assert.Equal("InputValidation", variableValidation.Classification);
            Assert.Contains("CAL_Date", variableValidation.TargetControls);
            Assert.Contains("CHK_Mode", variableValidation.ConditionExpression);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void Map_Catalog_Reports_Missing_Screens_Without_Faking_A_Model()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"hts-map-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            File.WriteAllBytes(Path.Combine(directory, TestTargetFixture.MapFileName), CreateSyntheticMap());

            var catalog = new HtsMapParser().ParseCatalog(
                directory,
                [TestTargetFixture.ShortScreenNumber, TestTargetFixture.MissingScreenNumber],
                "ht{screenNumber}00.map");

            Assert.Equal("1.4", catalog.SchemaVersion);
            Assert.Single(catalog.Screens);
            Assert.Equal(TestTargetFixture.ScreenNumber, catalog.RequestedScreens[0]);
            Assert.Equal([TestTargetFixture.MissingScreenNumber], catalog.MissingScreens);
        }
        finally
        {
            Directory.Delete(directory, true);
        }
    }

    [Fact]
    public void Map_Family_Allows_Container_And_Alpha_Suffix_Screen_Codes()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"hts-map-family-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            File.WriteAllBytes(Path.Combine(directory, "ht010100.map"), Encoding.ASCII.GetBytes("HT010100\0Container\0"));
            File.WriteAllBytes(Path.Combine(directory, "ht01010h.map"), Encoding.ASCII.GetBytes("HT01010H\0Alpha child\0"));

            var catalog = new HtsMapParser().ParseFamilyCatalog(
                directory,
                ["0101"],
                ["ht010100.map", "ht01010h.map"]);

            Assert.Equal(2, catalog.Screens.Length);
            Assert.Contains(catalog.Screens, x => x.ScreenCode == "HT01010H");
            Assert.All(catalog.Screens, x => Assert.Empty(x.Controls));
            Assert.Contains(catalog.Screens[0].Warnings, x => x.Contains("컨테이너 MAP"));
        }
        finally
        {
            Directory.Delete(directory, true);
        }
    }

    [Fact]
    public void Invalid_Map_Baseline_Policy_Is_Rejected()
    {
        var source = LoadDataset();
        var invalid = source with
        {
            TargetProfile = source.TargetProfile with
            {
                Map = source.TargetProfile.Map with
                {
                    InstallationRoot = "",
                    ScreenDirectory = "",
                    FilePattern = "ht.map"
                }
            },
            AutoExploration = source.AutoExploration with
            {
                MapBaseline = new RuleMapBaselinePolicy
                {
                    Enabled = true,
                    MatchTolerancePx = 2
                }
            }
        };

        var issues = new RuleDatasetValidator().Validate(invalid).Issues;
        Assert.Contains(issues, x => x.Code == "RULE.MAP_FILE_PATTERN");
        Assert.Contains(issues, x => x.Code == "RULE.MAP_ROOT_REQUIRED");
        Assert.Contains(issues, x => x.Code == "RULE.MAP_SCREEN_DIR_REQUIRED");
        Assert.Contains(issues, x => x.Code == "RULE.MAP_MATCH_TOLERANCE");
    }

    [Fact]
    public void Installation_Catalog_Combines_Official_Metadata_And_Verifies_Files()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var root = Path.Combine(Path.GetTempPath(), $"hts-install-{Guid.NewGuid():N}");
        var screenDir = Path.Combine(root, "screen");
        var dataDir = Path.Combine(root, "data");
        var systemDir = Path.Combine(root, "system");
        var menuDir = Path.Combine(systemDir, "menu");
        Directory.CreateDirectory(screenDir);
        Directory.CreateDirectory(dataDir);
        Directory.CreateDirectory(menuDir);
        try
        {
            var topPath = Path.Combine(screenDir, TestTargetFixture.MapFileName);
            var childPath = Path.Combine(screenDir, TestTargetFixture.ChildMapFileName);
            File.WriteAllBytes(topPath, CreateSyntheticMap(TestTargetFixture.ScreenCode, TestTargetFixture.ScreenName, includeNavigation: true, includeExchangeReference: true));
            File.WriteAllBytes(childPath, CreateSyntheticMap(TestTargetFixture.ChildScreenCode, TestTargetFixture.ChildScreenName, includeNavigation: false));
            WriteKoreanText(
                Path.Combine(menuDir, "menu.dat"),
                $"P       합성화면\r\nNN{TestTargetFixture.ScreenNumber}  {TestTargetFixture.ScreenName}                  합성조회 {TestTargetFixture.ScreenCode}.map        NNR A\r\n");
            WriteKoreanText(
                Path.Combine(systemDir, "tabscreen.ini"),
                $"[LIST_51]\r\nTAB={TestTargetFixture.TabSiblingScreenNumber}|{TestTargetFixture.ScreenNumber}|\r\n");
            WriteKoreanText(Path.Combine(systemDir, "defaultctrlinfo.ini"), "[CONTROL INFO]\r\nCTRL_COUNT=6\r\n05=34,21,BTN_,BUTTON\r\n09=100,21,CB_,COMBO\r\n10=140,21,ACCT_,ACCOUNTCOMBO\r\n11=90,21,CAL_,CALENDAR\r\n13=50,21,CHK_,CHECK\r\n15=300,150,GRID_,GRID\r\n");
            WriteKoreanText(Path.Combine(systemDir, "sysctrl.ini"), "[RunControl]\r\n5=RunButton.dll\r\n9=RunCombo.dll\r\n10=RunAccountCombo.dll\r\n11=RunCalendar.dll\r\n13=RunCheck.dll\r\n15=RunGrid.dll\r\n");
            WriteKoreanText(
                Path.Combine(dataDir, "screen_number.dat"),
                $"{TestTargetFixture.RegistryAliasScreenNumber},{TestTargetFixture.ScreenName},{TestTargetFixture.ScreenNumber},{TestTargetFixture.ScreenName}\r\n");
            WriteKoreanText(Path.Combine(dataDir, "errcode.txt"), "00000 정상적으로 처리되었습니다.\r\n90006 조회시간이 초과 되었습니다.\r\n99999 해당 자료가 없습니다.\r\n");
            WriteKoreanText(Path.Combine(dataDir, "exchange.ini"), "[잔고]\r\n통합=03\r\nKRX=01\r\nNXT=02\r\n");
            File.WriteAllText(
                Path.Combine(root, "screen_hts.vst"),
                string.Join("\r\n", ManifestLine(root, $"screen/{TestTargetFixture.MapFileName}"), ManifestLine(root, $"screen/{TestTargetFixture.ChildMapFileName}")));

            var catalog = new HtsInstallationCatalogBuilder().Build(root, [TestTargetFixture.ScreenNumber]);

            Assert.Equal("1.4", catalog.SchemaVersion);
            Assert.NotEmpty(catalog.InstallationFingerprint);
            Assert.Single(catalog.Screens);
            Assert.Single(catalog.DependencyScreens);
            Assert.Contains(catalog.Dependencies, x => x.TargetScreenCode == TestTargetFixture.ChildScreenCode && x.TargetExists);
            Assert.All(catalog.IntegrityEntries, x => Assert.Equal("MATCH", x.Status));
            Assert.Equal(TestTargetFixture.ScreenName, catalog.Screens[0].Registry?.Title);
            Assert.Contains(TestTargetFixture.TabSiblingScreenNumber, catalog.Screens[0].TabSiblings);
            Assert.Contains(catalog.ErrorCodes, x => x.Code == "90006" && x.IsFailure);
            Assert.Contains(catalog.ErrorCodes, x => x.Code == "99999" && !x.IsFailure && x.Classification == "NoData");
            var exchange = Assert.Single(catalog.Screens[0].Controls, x => x.LogicalName == "CB__ExchConfAts");
            Assert.Equal(3, exchange.StaticOptions.Length);
            Assert.Contains("exchange.ini", exchange.OptionSource);
            Assert.All(exchange.StaticOptions, option =>
            {
                Assert.Equal(RuleExpectedOutcomeType.Success, option.ExpectedOutcome.Type);
                Assert.Equal(RuleExpectationSource.InstallationInputOption, option.ExpectedOutcome.Source);
                Assert.Equal(RuleExpectationConfidence.High, option.ExpectedOutcome.Confidence);
                Assert.True(option.ExpectedOutcome.QueryShouldComplete);
            });
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    private static byte[] CreateSyntheticMap(
        string screenCode = TestTargetFixture.ScreenCode,
        string screenName = TestTargetFixture.ScreenName,
        bool includeNavigation = false,
        bool includeExchangeReference = false)
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        using var stream = new MemoryStream();
        stream.Write([0x41, 0x01, 0x00, 0x03, 0x00, (byte)'0', (byte)'1', 0x00]);
        stream.Write(Encoding.ASCII.GetBytes($"HHTHA\0{screenCode}\0\0"));
        stream.Write(Encoding.GetEncoding(949).GetBytes(screenName + "\0"));
        while (stream.Length < 0x50) stream.WriteByte(0);
        WriteControl(stream, "10", 60, 3, 200, 21, "root", "ACCT_No");
        WriteControl(stream, "11", 440, 3, 90, 21, "root", "CAL_Date");
        WriteControl(stream, "05", 534, 3, 67, 21, "root", "BTN_Comm");
        WriteControl(stream, "13", 60, 32, 120, 21, "root", "CHK_Mode");
        if (includeNavigation)
            WriteControl(stream, "05", 610, 60, 80, 21, "root", "BTN_Link");
        if (includeExchangeReference)
            WriteControl(stream, "09", 190, 32, 120, 21, "root", "CB__ExchConfAts");
        WriteControl(stream, "15", 60, 60, 540, 180, "root", "GRID_Data");
        var navigationScript = includeNavigation ? $"Call Form.OpenScreen(\"{TestTargetFixture.ChildScreenCode}\", False, False)" : string.Empty;
        var exchangeReference = includeExchangeReference ? "' data\\exchange.ini 잔고" : string.Empty;
        stream.Write(Encoding.GetEncoding(949).GetBytes($$"""
            Sub Form_OnReceiveAfter(strRQName, strTRCode, nNexttp, nErrFlag, strErrCode, strErrMsg, strTrScd, strDumy)
            End Sub
            Sub ACCT_No_OnError(strTRCode, strErrCode, strErrMsg)
            End Sub
            Function IsValidAccPw(strAccNm, strPwNm)
                Call Form.FormMsgBox2("계좌번호를 확인하십시오.", "", 0, 0)
                Call Form.FormMsgBox2("처리 오류가 발생했습니다.", "오류", 0, 0)
                Call Form.FormMsgBox(0, "일괄매도할 주문이 없습니다", "일괄매도 오류", 0, 0)
            End Function
            Sub CAL_Date_SelSelected()
                Call BTN_Comm_Click()
            End Sub
            Sub CHK_Mode_ChangeCheckStateBefore(iCheckState)
                If CHK_Mode.GetCheckState() = 0 Then
                    strMsg = "선택 항목을 확인하십시오."
                    Call Form.FormMsgBox(1, strMsg, "", 0, 0)
                    CAL_Date.SetFocus()
                End If
            End Sub
            Sub CHK_Mode_ChangeCheckState(iCheckState)
                CAL_Date.Enabled = True
            End Sub
            Sub BTN_Comm_Click()
                strAccount = ACCT_No.GetCaptionCtrl()
                Call GRID_Data.ClearAllData(1, "")
                Call Form.CommRequest("RQ_OTS0002Q00", "", 0, "Q")
            End Sub
            Sub BTN_Link_Click()
                {{navigationScript}}
            End Sub
            {{exchangeReference}}
            """));
        return stream.ToArray();
    }

    private static void WriteKoreanText(string path, string value) =>
        File.WriteAllText(path, value, Encoding.GetEncoding(949));

    private static string ManifestLine(string root, string relativePath)
    {
        var path = Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar));
        var md5 = Convert.ToHexString(System.Security.Cryptography.MD5.HashData(File.ReadAllBytes(path)));
        var size = new FileInfo(path).Length.ToString("D12");
        return $"hanadt  {relativePath.PadRight(130)}0000000000002026080912000000100{md5}{size}";
    }

    private static void WriteControl(Stream stream, string typeCode, ushort x, ushort y, ushort width, ushort height, string parent, string name)
    {
        stream.WriteByte(0xff);
        stream.Write(Encoding.ASCII.GetBytes(typeCode + "\0"));
        WriteUInt16(stream, x);
        WriteUInt16(stream, y);
        WriteUInt16(stream, width);
        WriteUInt16(stream, height);
        WriteFixedAscii(stream, parent, 21);
        WriteFixedAscii(stream, name, 21);
    }

    private static void WriteUInt16(Stream stream, ushort value)
    {
        stream.WriteByte((byte)(value & 0xff));
        stream.WriteByte((byte)(value >> 8));
    }

    private static void WriteFixedAscii(Stream stream, string value, int length)
    {
        var bytes = Encoding.ASCII.GetBytes(value);
        stream.Write(bytes, 0, Math.Min(bytes.Length, length - 1));
        for (var index = Math.Min(bytes.Length, length - 1); index < length; index++) stream.WriteByte(0);
    }

    private static string Root => Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
    private static RuleTestDataset LoadDataset() => JsonFile.Read<RuleTestDataset>(Path.Combine(Root, "data", "rule-tests", "1q-hts-account-inquiry.dataset.json"));
}
