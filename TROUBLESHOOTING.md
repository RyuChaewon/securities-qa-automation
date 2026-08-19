# 문제 해결

- `HTS_NOT_ACCESSIBLE`: HTS와 PowerShell의 권한 수준을 맞추고 로그인·표시 상태를 확인한다.
- UAC 사용자 취소: `-AllowElevatedActionPrompt`로 다시 실행하고 `예`를 누른다.
- `SCREEN_NOT_VISIBLE`: 화면번호가 현재 계정·메뉴에서 제공되는지 확인한다.
- `CONTROL_STALE`: 탭 또는 토글 뒤 컨트롤이 사라진 경우다. 결과는 FAIL이 아니라 PENDING으로 기록된다.
- `PENDING_DATA_REQUIRED`: 화면별 유효 입력값을 데이터셋 변수나 기본 텍스트 값에 추가한다.
- 영상 한글 경로 오류: 현재 인코더는 Unicode 입력과 ASCII 임시 출력을 사용한다.
- Excel 의존성 오류: `HTS_QA_NODE_MODULES`를 번들 `node_modules`로 지정한다.
