// 역할: UI provider 없이 FlaUI 내부 action 결과 계약을 테스트 어셈블리에서 검증할 수 있게 한다.
// 범위: 제품 런타임 동작이나 외부 소비자 공개 API는 변경하지 않는다.
// 수정 지점: 테스트 어셈블리 이름이 바뀔 때만 friend assembly 선언을 함께 갱신한다.
using System.Runtime.CompilerServices;

[assembly: InternalsVisibleTo("HtsQa.Tests")]
