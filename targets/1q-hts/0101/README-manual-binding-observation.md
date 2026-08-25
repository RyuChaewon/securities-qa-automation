# 0101 수동 바인딩 관찰 순서

기존 `scripts/record-order-screen-interactions.ps1`를 실행한 뒤 사용자가 직접 다음 순서로 조작한다. recorder는 관찰만 하며 자동 입력·클릭·포커스 이동·주문 전송을 수행하지 않는다.

1. 매수 탭 선택
2. 매도 탭 선택
3. 정정/취소 탭 선택
4. 좌측 호가 한 칸 선택
5. 우측 주문조건의 비거래 컨트롤 조작
6. 하단 거래정보 탭을 왼쪽부터 순서대로 선택
7. 각 탭의 조회·필터 등 비거래 컨트롤 조작
8. 매수·매도·정정·취소 버튼은 선택 여부를 먼저 확인하고, 선택하더라도 recorder는 관찰만 수행

산출물은 `BindingDiscovery` 자료로만 취급한다. 계좌·비밀번호·입력값·pixel crop은 저장하지 않으며, `verdictEligible=false`, `canonicalVerdict=null`, `testExecution=false`, `uiActionCount=0`, `transactionalActionCount=0`을 유지한다. 후보는 승인 전 `ReviewRequired`로 남긴다.

실행 예:

```powershell
.\targets\1q-hts\0101\scripts\record-order-screen-interactions.ps1 -OutputDirectory artifacts\local\passive-interactions\0101-manual -MaxDurationSeconds 1800
```
