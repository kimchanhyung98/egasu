# QwenCloud 개인 Token Plan

QwenCloud CLI에 로그인한 개인 구독의 기본 크레딧 사용률과 다음 초기화 시각 표시.

## 연결

1. [공식 CLI 안내](https://docs.qwencloud.com/api-reference/preparation/cli)에 따라 QwenCloud CLI 설치.
2. 터미널에서 `qwencloud auth login`으로 로그인.
3. egasu의 Accounts → Add New Account에서 QwenCloud를 선택한 뒤 **Turn On** 클릭.

자동 감지는 실행 가능한 CLI와 CLI 로그인 파일 또는 Keychain 항목의 존재를 로컬에서 확인.
CLI가 로그인 파일을 찾는 기본 위치는 `~/.qwencloud/credentials`이며 `QWENCLOUD_CONFIG_DIR`로 변경 가능.
키와 토큰은 CLI가 관리.
암호화 파일로만 로그인한 경우 같은 파일에서 조회한 사용률을 재사용.
CLI 실행 중 암호화 파일이 바뀌면 해당 조회 결과를 폐기.
파일이 바뀐 뒤 새 조회에 실패하면 이전 사용률 숨김.
Keychain 로그인이나 저장소 확인 실패 시에는 새로고침마다 CLI로 조회하고, 실패하면 이전 사용률 숨김.
CLI 실행 도중의 Keychain 로그인 교체는 확인할 수 없음.
Keychain에서도 조회에 성공하면 카드와 로컬 API `/v1/limits/qwencloud`에 현재 사용률 표시.
소프트 한도 기능을 켠 경우, CLI 사전 검사(`egasu soft-limit check qwencloud`)는 계정 신원을 확인할 수 없는 Keychain 로그인에서 `unknown` 반환.
CLI v1.7.0은 평문 로그인 파일을 조회 중에 이전하면서 원본을 삭제할 수 있음.
이 파일이 있으면 egasu가 조회를 중단하고 Keychain 또는 암호화 파일 로그인 안내를 표시. [공식 CLI의 로그인 파일 처리](https://github.com/QwenCloud/qwencloud-cli/blob/v1.7.0/src/auth/credentials.ts#L140-L159)

## 사용량

egasu는 새로고침할 때 다음 명령을 실행.

```sh
qwencloud subscription tokenplan status --edition individual --format json
```

CLI가 보고한 기간에 따라 주간 또는 월간 기본 크레딧 사용률 표시.
초기화 시각이 빠진 응답은 사용률만 표시.
구독 종료일은 갱신 카운트다운에 사용하지 않음.
기본 크레딧을 모두 써도 추가 팩이 남아 있으면 계속 사용 가능. [크레딧 차감 순서](https://docs.qwencloud.com/token-plan/token-plan-usage-quota)

CLI 미설치, 로그인 필요, 개인 구독 없음, 사용률 미제공, 조회 실패는 별도 안내.
팀 구독과 종량제 지출은 개인 구독 카드의 집계 범위에서 제외.
