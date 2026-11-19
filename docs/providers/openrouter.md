# OpenRouter

계정 API 키로 [OpenRouter](https://openrouter.ai) 크레딧 잔액과 사용액 추적.

현행 Free·Standard·Business·Enterprise의 가격과 플랫폼 수수료는 [구독 요금제](/docs/pricing.md#구독-요금제) 참조.
API 키의 무료 여부만으로 유료 계약 등급을 구분하지 않음.

## 추적 항목

| 지표 | 의미 |
|---|---|
| Credits | 구매한 크레딧 대비 누적 사용액(달러 미터) |
| Balance | 계정 크레딧 잔액 — 초과 사용 시 음수 |
| Today | 오늘 현재까지의 사용액 |
| This Week | 이번 주 현재까지의 사용액 |
| This Month | 이번 달 현재까지의 사용액 |
| Key Limit | 현재 키 한도 기간의 사용액 — 키에 상한과 유효한 잔여액이 있는 경우 표시 |

반환된 등급(예: "Pay as you go" 또는 "Free tier")을 프로바이더 이름 옆에 표시.

일반 API 키의 Today·This Week·This Month는 해당 키의 OpenRouter 크레딧 사용액.
일반 키의 기간은 UTC 기준이며, 주간은 월요일 시작.
외부 제공자에 직접 결제하는 BYOK 추론 비용은 일반 키의 기간 사용액에서 제외.
관리 키를 연결하면 같은 항목에 계정 전체의 기간 사용액 표시.
관리 키 자체의 사용액 0을 계정 사용액으로 사용하지 않음.

## 상단 비용·토큰 통계

관리 키를 연결하면 상단의 Cost·Tokens·Cost/MTok 통계에 OpenRouter 포함.
[Analytics API](https://openrouter.ai/docs/api/api-reference/analytics/query-analytics-data)가 보고한 비용과 총 토큰 사용.
캐시·추론 토큰은 총 토큰에 이미 포함되므로 별도 가산하지 않음.
비용은 반환된 달러 값이며 모델 가격으로 다시 추정하지 않음.
Analytics의 `total_usage`는 OpenRouter 크레딧 사용액과 BYOK 추론 비용의 합계.
따라서 크레딧 잔액 감소분이나 일반 키의 기간 사용액과 비용 범위가 다름.

관리 키로 조회하는 오늘·어제·최근 30일의 시작과 끝은 Mac의 현지 시간 기준.
최근 30일은 오늘 및 이전 30일 포함.
이번 주·이번 달도 Mac의 달력 기준으로 조회.
UTC 일별 합계를 현지 날짜로 바꾸어 넣지 않고 각 기간의 시각 범위를 API에 전달.

비용만 있으면 Cost에만 포함.
토큰만 있으면 Tokens에만 포함.
Cost/MTok는 비용과 토큰이 모두 유효한 기간만 포함.
선택한 지표가 0이거나 없으면 상단 통계에서 제외.
일반 키의 기간 사용액은 계정 전체 통계와 범위가 달라 상단 합계에서 제외.

상단 합계에서 조회 실패·잘린 응답은 0 사용으로 처리하지 않음.
정상 조회된 잔액과 기간 값은 유지하고 실패한 기간은 경고와 함께 통계 집계에서 제외.
카드의 미보고 기간 표시와 상단 집계는 아래 내부 동작 규칙에 따라 구분.
계정 전체 값이므로 다른 Mac의 같은 계정 값과 다시 합산하지 않음.

## 인증 정보 출처

egasu의 OpenRouter 조회에는 사용자가 제공한 API 키 필요.
키별 크레딧 사용액과 키 한도는 [API Keys](https://openrouter.ai/keys)의 일반 키 사용 가능.
계정 잔액과 상단 비용·토큰 통계는 [Management Keys](https://openrouter.ai/settings/management-keys)에서 발급한 관리 키 필요.
egasu가 응답의 키 종류를 확인해 관리 키의 통계를 자동 조회.
앱은 관리 키로 잔액·등급·키 한도·사용 통계만 조회.
다른 키의 생성·수정·삭제는 수행하지 않음.
키의 만료 기간과 권한 범위는 [공식 관리 키 문서](https://openrouter.ai/docs/guides/overview/auth/management-api-keys) 참조.

1. [Accounts](/docs/accounts.md)에서 **Add New Account** 선택.
2. **OpenRouter** 선택.
3. 키 입력.
4. **Add Account** 선택.

운영 앱은 `~/.config/egasu/openrouter.json`에 키를 저장.
표준 개발 앱과 사용자 지정 설정 도메인은 [CLI 문서의 저장 위치 규칙](/docs/cli.md#path에-설치)에 따라 분리.
저장 위치를 이전할 때는 새 경로에 파일이 없으면 `~/.config/openusage/openrouter.json`을 복사.
이전 실패 시 다음 시작에서 재시도.
이미 추가한 계정에 키를 등록하거나 바꾸려면 아래 순서로 진행.

1. OpenRouter 계정 상세에서 **Add API Key…** 또는 **Replace API Key…** 선택.
2. 새 키 입력.
3. **Save** 선택.

다음 방법으로 직접 키를 제공할 수도 있으며, 아래 순서에서 처음 찾은 키 사용:

1. **설정 파일** — 먼저 현재 앱의 `openrouter.json`, 다음으로 `~/.config/openrouter/key.json`에서 키 확인.
   운영 앱의 첫 경로는 `~/.config/egasu/openrouter.json`.

   ```json
   { "apiKey": "sk-or-v1-..." }
   ```

   두 경로 모두 키만 담긴 일반 텍스트 파일도 지원.

2. **환경 변수** — 셸 프로필(예: `~/.zshrc` 또는 `~/.zprofile`)에 `OPENROUTER_API_KEY` 내보내기 설정 추가.
   `OPENROUTER_API_KEY`가 없으면 `OPENROUTER_KEY`도 지원.
   설정을 바꾼 뒤 egasu 종료 후 다시 실행.
   앱이 시작할 때 로그인 셸 환경을 읽으므로 Finder나 Dock에서 실행해도 해당 키 사용 가능.
   현재 터미널에서만 실행한 `export`는 이미 실행 중인 앱에 적용되지 않음.
   이 키만 쓰려면 **Add New Account → OpenRouter**에서 입력란을 비워 둔 채 **Add Account** 선택.
   환경 변수에서 키를 찾으면 계정 상세의 API 키 상태에 **From Your Environment** 표시.
   별도 키를 저장하려면 **Replace API Key…** 선택.

앱은 설정 파일의 키를 환경 변수보다 먼저 사용.
**Remove Account…**에서 제거를 확정하면 추적을 끔.
현재 앱의 `openrouter.json`과 대체 경로 `~/.config/openrouter/key.json`에서 확인한 키 제거.
JSON의 다른 설정은 유지하고 키만 담긴 파일은 삭제.
설정 파일을 읽거나 변경하지 못하면 오류를 표시하고 추적 유지.
환경 변수 키를 다시 쓰려면 **Add New Account**에서 OpenRouter를 선택하고 입력란을 비워 둔 채 **Add Account** 선택.
앱에서 키를 저장하면 적용 중인 키로 새로 조회하며, 이전 요청이 진행 중이면 완료를 기다리고 그 결과는 무시.
이전 요청이 대기 한도보다 오래 걸리면 다음 주기 새로 고침에서 현재 키로 재시도.
비활성 프로바이더는 다시 활성화될 때 조회.
새 요청이 진행 중이거나 조회 전체가 실패하면 이전에 표시하던 마지막 정상 값 유지.
일부 조회만 실패하면 정상 조회된 값을 표시하고, 예상된 권한 제한을 제외한 실패 항목은 경고와 함께 제외.
일반 키의 `/credits` 403은 예상된 권한 제한으로 처리하며 잔액만 생략하고 별도 경고는 표시하지 않음.
앱 재실행 시에도 현재 키로 조회하기 전 마지막 값 복원 가능.

## 문제 해결

- **"Couldn't read the saved API key"** — 설정 파일 권한을 확인하고 필요하면 계정 추가 시 새 키 입력.
- **"No OpenRouter API key"** — **Add New Account**에서 OpenRouter 키를 추가하거나 기존 계정 상세의 **Add API Key…** 사용.
  환경 변수를 사용하면 위 설정 절차에 따라 앱 재실행.
- **"API key invalid"** — 잔액과 키 정보 조회가 모두 401/403으로 거부된 상태.
  openrouter.ai/keys에서 확인하거나 다시 생성.
- **"Key Limit is unavailable"** — 키 한도의 잔여액을 확인할 수 없는 상태.
  Key Limit을 생략하고 조회에 성공한 잔액·기간 사용액은 계속 표시하며, 다음 정상 조회에서 경고 해제.
  표시할 다른 값이 하나도 없으면 경고 대신 조회 실패로 처리하고 마지막 정상 값 유지.
- **"Some OpenRouter statistics are unavailable. Other usage data is still available."** — 일부 잔액·기간 통계 조회 실패 또는 불완전한 응답.
  조회에 성공한 값은 유지하며 다음 새로 고침에서 재시도.

## 내부 동작

`https://openrouter.ai/api/v1`에 `Bearer` 토큰을 사용한 REST 조회 수행:

- `GET /credits` — 관리 키 전용. 계정 전체 `total_credits`와 `total_usage`로, Credits 미터와 Balance의 출처.
  이 호출이 실패해도 `/key`에서 조회한 사용액 표시 가능.
  일반 키의 403은 잔액 조회 권한 제한이며 키 오류로 처리하지 않음.
  필수 총액이 없거나 유효한 숫자가 아니면 잔액 0으로 대체하지 않고 조회 실패로 처리.
  Balance는 두 총액의 차이를 사용하며 음수 잔액도 유지.
- `GET /key` — 가능한 범위에서 등급, 일간/주간/월간 사용액, 설정된 경우 키별 상한 조회.
  이 호출이 실패해도 `/credits` 결과로 잔액 표시.
- 관리 키는 `POST /analytics/query`로 오늘·어제·최근 30일·이번 주·이번 달의 비용과 토큰 추가 조회.
  `total_usage`와 `tokens_total`을 요청하고 기간 전체의 합계를 사용.
  조회 범위가 같은 기간은 한 번만 요청.
  관리 키의 기간 값은 Analytics 결과만 사용하며 `/key`의 사용액으로 대체하지 않음.

일반 키의 기간 사용액은 API가 반환한 유효한 숫자를 사용하며 음수는 0으로 제한.
비용이 0으로 보고된 기간의 비용 행은 `$0.00` 표시.
요청에 실패했거나 유효한 비용값이 없는 기간의 비용 행은 **No data** 표시.
관리 키가 해당 기간에 토큰만 보고하면 상단의 Tokens에 보고된 토큰 반영.
Key Limit은 [키의 한도와 잔여 크레딧](https://openrouter.ai/docs/api_reference/limits)의 차이로 계산하며, 전체 기간 누적 사용액은 사용하지 않음.
현재 한도 기간의 초기화 이후에도 남은 한도에 맞는 사용액 표시.
상한이 있는데 잔여액이 누락되거나 유효하지 않으면 0 사용 또는 소진 상태로 추정하지 않음.
크레딧 값은 OpenRouter 측에서 최대 약 60초 지연될 수 있음.
