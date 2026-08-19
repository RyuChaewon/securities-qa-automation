// 역할: 단위 테스트가 사용하는 합성 대상의 화면 식별 규약을 한곳에서 정의한다.
// 범위: 실제 HTS 데이터셋과 무관한 메모리·임시 파일 테스트에만 사용한다.
// 수정 지점: MAP 파일명 규약을 시험할 때 이 fixture만 바꾸고 개별 테스트에 화면번호를 직접 쓰지 않는다.
namespace HtsQa.Tests;

internal static class TestTargetFixture
{
    internal const string ScreenNumber = "0102";
    internal const string ShortScreenNumber = "102";
    internal const string MissingScreenNumber = "0103";
    internal const string TabSiblingScreenNumber = "0100";
    internal const string RegistryAliasScreenNumber = "0132";
    internal const string ScreenCode = "HT010200";
    internal const string ChildScreenCode = "HT010201";
    internal const string ScreenName = "합성 조회 화면";
    internal const string ChildScreenName = "합성 조회 상세";
    internal const string InstallationRoot = @"C:\TestHts";

    internal static string MapFileName => $"ht{ScreenNumber}00.map";
    internal static string ChildMapFileName => $"ht{ScreenNumber}01.map";
}
