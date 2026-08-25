// 역할: scenario pipeline의 canonical ID hash helper를 제공한다.
// 경계: ID 생성 외 validation, compilation, binding 책임을 갖지 않는다.

namespace HtsQa.Core;

public static class ScenarioIds
{
    public static string Hash(string value, int length) => RuleCaseExpander.Fingerprint(value, length);
}
