# site

`https://egasu.chanhyung.kim/` 랜딩 페이지.
Astro 정적 출력이며 소개 본문은 한국어.
앱 미리보기는 영어·한국어·일본어 지원.

화면 구성과 시연 조건은 [디자인](/site/docs/design.md) 참조.

## 실행

```sh
cd site
npm ci
npm run dev      # http://localhost:4321 — HMR, CSP 미적용
npm run build    # dist/
npm run preview  # dist/ 미리보기 — CSP·인라인 검사는 여기서만 유효
```

사이트 Node 의존성은 `site/package.json`에서 관리.
루트 npm 프로젝트는 Git 훅 설정용이며 사이트 의존성과 분리.
Node 22.23.4 이상 필요, CI는 Node 24 사용.
정적 검사에 필요한 Node 타입은 `@types/node` 개발 의존성으로 직접 선언.
`astro check`가 사용하는 compiler API와 호환되는 TypeScript 6.0.3 사용.
TypeScript 7은 해당 API를 제공하지 않아 설치·정적 검사 실패 — Astro 검사 도구의 지원 전까지 6.x 유지.
Astro CLI가 에이전트 환경에서 백그라운드 서버를 시작하면 `npx astro dev status`·`npx astro dev stop`으로 확인·종료.

## 페이지 이동

- 페이지 경계의 세로 입력은 다음·이전 섹션으로 즉시 이동.
- 스크립트가 페이지 이동을 맡는 동안 브라우저의 강제 스크롤 정렬 비활성화. 작은 입력 뒤 원래 위치로 되돌아가는 충돌 방지.
- 고정 내비게이션 아래를 기준으로 섹션마다 최소 한 화면 높이 확보.
- 화면보다 긴 섹션은 내용 끝까지 스크롤한 뒤 다음 화면으로 이동. 이전 화면으로 돌아갈 때는 내용 끝으로 진입.
- 조작 가능한 앱 미리보기 위의 스크롤·스와이프와 앱 내부에 초점이 있는 방향키는 앱 안에서만 처리. 내용 끝이나 고정 헤더·푸터에서도 페이지로 전달하지 않음.
- 앱 바깥에서 스크롤하면 페이지 이동. 기능 탭의 가로 스크롤은 유지.
- 주요 기능은 내비게이션 아래 한 화면 높이로 고정하고, 맥북·팝업 전체가 남는 공간 안에 들어오도록 확대 배율 계산.
- 탭을 바꿔도 기능 섹션의 높이와 페이지 스크롤 위치 유지.
- 주요 기능 안에서는 아래 스크롤로 다음 기능, 위 스크롤로 이전 기능 전환. 첫 기능에서 위로, 마지막 기능에서 아래로 이동할 때만 인접 섹션으로 이동.
- 작아진 휠·트랙패드 관성은 중복 전환 억제. 입력 강도가 유지되면 350ms 이후 다음 단계를 받아 연속 스크롤 진행.
- 약한 입력이 계속되는 경우에도 1.2초 뒤부터 입력 누적 재개. 잠금 해제를 위해 스크롤을 완전히 멈출 필요 없음.
- 애니메이션 완료를 기다리지 않고 다음·이전 기능으로 이동. 반대 방향 입력은 즉시 반영.
- 터치는 한 번의 세로 스와이프당 한 단계 이동. Page Up/Down·위아래 방향키를 누르고 있어도 순서대로 진행.
- 동작 줄이기 설정에서는 부드러운 이동 비활성화.
- 좁은 모바일에서는 상단 버튼 간격과 폭을 줄여 egasu 로고를 한 줄로 유지. 첫 화면 제목도 한 줄 표시.
- 첫 화면에 사용량·비용·초기화 예측 소개, 다운로드·기능 이동 링크, 지원 언어 표시.
- 첫 화면 앱 미리보기는 가시 폭이 340px보다 좁으면 전체를 같은 비율로 축소. 가로 스크롤 없이 전체 폭 표시.
- 모바일 미리보기 높이는 화면에 맞춰 300–420px로 제한하고 내용은 앱 안에서 스크롤.
- 마지막 화면은 다운로드와 푸터가 한 화면 높이를 나눠 사용. 푸터를 보기 위한 추가 스크롤 없이 함께 표시.
- 푸터 왼쪽 카피라이트 아래에 작은 글씨로 포크 출처와 AI provider 이름·로고 소유 고지 두 줄 표시.

## 기능 시연

- 처음에는 맥북 전체 화면 표시.
- 기능 영역에 처음 진입하면 메뉴 막대로 한 번 확대하고, 완료 후 두 줄 설명 표시.
- 설명은 넓은 화면에서 오른쪽, 좁은 세로 화면에서 그래픽 아래에 배치. 탭을 바꿔도 설명 공간 유지.
- 메뉴 막대: 오른쪽 위 사용량 표시로 확대.
- 대시보드: 같은 확대 위치에서 커서가 메뉴 막대를 클릭해 팝업 열기.
- 사용량 통계: 같은 팝업 상단의 `Cost` 요약에 옅은 하늘색이 잠깐 나타났다가 사라짐.
  테두리 없이 1.6초 동안 한 번만 표시.
  `TotalSpendCard`는 Cost·Cost/MTok·Tokens를 제공하므로 탭 이름은 사용량 통계.
- 초기화 예측: Codex 카드를 펼쳐 Reset Watch의 예측 확률·커뮤니티 투표율과 남은 초기화권 개수 표시.
  비공식 전역 예측이며 개인 계정의 초기화 보장과 구분.
- 한도 안내선: 주간 사용량 막대에 90% Soft Limit 예시 표시.
  현재 자동 취소 미지원 안내 포함.
- 계정: `Options → Accounts → Add Account`를 거쳐 빈 목록에 `Account 1 / In Use` 추가.
  마우스 이동·클릭·화면 전환·단계별 대기는 기본 시연의 절반 속도.
- 연동: CLI와 로컬 API 예시, 글자 확대 등으로 넘치는 내용은 키보드로도 내부 스크롤 가능.
  위아래 끝에 도달해도 페이지 이동으로 이어지지 않음.
- 시연은 언어만 첫 화면의 조작 가능한 미리보기와 공유하며 나머지 상태는 독립.
  실제 계정·로그인·저장소 변경 없음.
- 새 탭 선택 시 진행 중 시연 취소. 방향키·Home/End로 탭 이동, Escape로 현재 단계의 최종 상태 표시.
- 동작 줄이기에서는 커서·확대 애니메이션 없이 최종 상태 표시.

## 조작 가능한 앱 미리보기

- 대시보드·계정·설정은 공개 예시 데이터로 재현.
  기본 언어는 English이며 Language에서 한국어·일본어 선택 시 전체 미리보기에 즉시 적용.
  언어 변경에 새로고침·재시작 불필요.
- 이름 변경 전과 같은 출처에서 저장한 미리보기 설정을 이어 쓰도록 기존 `openusage.site.*` 저장 키 유지.
  더 이전 미리보기의 사용량·초기화 시간 표시 설정도 계속 읽음.
- Priority의 한도 링과 페이스 눈금은 **Show Usage As**에서 선택한 사용량 또는 잔량 기준으로 표시.
  경고 색은 두 모드 모두 잔량 기준.
- **Alerts → Show in Priority**에서 네 조건의 표시 여부를 각각 설정.
  모두 끄면 대시보드에 All Usage만 표시.
  하나라도 다시 켜면 이전에 선택한 탭으로 복귀.
  각 조건의 알림 수신은 별도 설정.
- Reset Watch는 사용량과 별도 확률 막대.
  Used/Left 전환에도 예측 확률과 커뮤니티 투표 눈금 유지.
  예측 시각은 다른 초기화 타이머와 함께 Countdown/Exact Time 및 12/24시간 설정 반영.
  공통 사용 이력·예측은 활성 계정에 표시.
- Soft Limit은 **General → Beta Updates**를 켜면 **Labs** 탭에서 설정 가능.
  베타 업데이트를 끄면 Soft Limit과 안내선이 꺼지고 기간·임계값은 유지.
  켜면 주간·월간을 함께 또는 따로 선택하고 1–100% 기준값 입력.
  Enter 또는 입력 종료 시 적용.
  잘못된 입력은 기존 값 유지와 안내, Used/Left 전환은 안내선 위치만 반전.
  선택한 기간의 구독 한도와 사용량이 있는 막대 안에 안내선 표시.
  5시간 세션·Reset Watch·최근 30일 비용·토큰 합계는 대상에서 제외.
  지원 지표는 [앱의 소프트 한도 설정](/docs/settings.md#지원하는-사용량) 참조.
  미리보기에서 설정한 안내선은 로컬 예시 화면에만 적용.
  Kiro 크레딧은 월간 구독 한도 예시이며, OpenCode Go는 로컬 추정 사용량 예시.
  설정 변경 안내가 떠 있는 동안에도 Options와 다른 컨트롤의 클릭·터치 조작 가능.
- **Settings → Alerts → Other Notifications**에서 **Codex Reset Watch** 설정.
  **Condition**의 네 **Receive Alerts** 스위치와 독립.
  알림 발송·권한 요청은 Mac 앱에서 수행.
- 계정 줄의 우클릭 또는 Shift+F10 메뉴에서 `Use …`를 고르면 확인 창을 거쳐 예시 활성 계정 전환.
  계정 줄은 Tab으로 초점 이동 가능.
  Today 같은 텍스트 지표만 표시돼도 같은 방법으로 메뉴 열기 가능.
  카드 메뉴를 Esc로 닫으면 해당 계정의 **Actions** 버튼으로 초점 복귀.
  전환 확인 창은 전환을 확인하거나 **Cancel**·Esc로 취소해도 같은 버튼으로 초점 복귀.
  Accounts의 계정 전환과 같은 상태 사용.
- 초기화권 개수에 포인터를 올리거나 클릭·키보드 조작으로 읽기 전용 만료 목록 팝오버 열기.
  팝오버를 열어도 카드 높이 유지.
  초기화권 사용 버튼과 실제 초기화 요청은 제공하지 않음.
  푸터 새로고침 버튼은 Mac 앱에서 실행하는 동작 안내.
  실제 계정·리셋 크레딧·로그인·프로바이더 API에는 접근하지 않음.

## 조립·검증

`npm run build`는 페이지만 만듦.
조립 전 `site/`에서 `npm ci` 실행 필요.
배포물은 `gh-pages`의 feed 파일을 보존해야 하므로 조립 스크립트로 출력 검증.
버전 태그를 푸시하면 `Publish landing page`가 그 태그의 사이트를 `gh-pages`에 게시.
앱 릴리스·가격표 게시도 같은 태그 푸시로 시작.
정식·베타 태그 모두 기존 버전 형식과 `main` 이력 포함 여부 확인.
수동 게시도 `tag` 입력 필수이며 검증·빌드·게시 모두 지정한 태그의 소스 사용.
자동·수동 사이트 게시 모두 재사용하는 `Site CI`의 정적 검사·단위 테스트·E2E·조립 검증을 통과해야 게시 시작.
사이트·조립 스크립트·앱 소스·배포 workflow 변경의 `main` push와 PR은 독립 `Site CI`에서 검증만 수행.
게시 전후 `appcast.xml`·`pricing_supplement.json`의 Git blob을 비교하고, 모두 같을 때 게시 커밋 기록.
게시 전에는 기존 `openusage.chanhyung.kim` 또는 새 `egasu.chanhyung.kim` 도메인 허용.
게시 후에는 새 도메인만 허용.
필수 파일 누락·심볼릭 링크 등 일반 파일이 아닌 항목·허용하지 않은 도메인·`gh-pages/.github` 존재 시 게시 전 실패.
Release·가격표·사이트 게시가 각각 기록한 게시 커밋·태그·소스 커밋을 `pages-publication-<실행 시도 번호>` 산출물로 전달.
`Deploy Pages`는 성공한 실행의 해당 산출물을 받아 그 커밋만 배포하므로, 대기 중 다른 게시가 시작돼도 배포 내용 고정.
자동·수동 배포 모두 원격 태그와 게시 소스 커밋이 같은지 확인.
산출물 누락·만료·잘못된 커밋 값은 실패 처리하며 최신 `gh-pages`로 대체하지 않음.

Release·가격표 게시와 `release-appcast` 실행 그룹 공유.
사이트는 검증을 마친 게시 작업만 이 그룹에 진입하며, 검증 작업은 호출 workflow별 별도 실행 그룹 사용.
게시 작업은 `queue: max`로 대기 작업을 보존하고 `cancel-in-progress: false`로 진행 중 작업 유지.
게시 실패 시 원인을 확인한 뒤 해당 workflow를 다시 실행하고, 후속 `Deploy Pages` 성공까지 확인.
사이트 수동 재게시 명령은 `gh workflow run publish-site.yml --repo kimchanhyung98/egasu --ref main -f tag=<버전 태그>`.
`--ref main`은 실행할 workflow를 선택하며, 게시 소스는 `tag` 입력으로 고정.
Pages 배포만 실패하면 해당 배포 실행을 재실행하여 같은 게시 커밋으로 재시도.
태그 기록이 없는 옛 산출물이나 만료된 산출물은 같은 태그로 새 게시 실행 필요.
Pages 수동 재배포 명령은 `gh workflow run deploy-pages.yml --repo kimchanhyung98/egasu --ref main -f tag=<버전 태그> -f publication_run_id=<성공한 게시 실행 ID>`.
지정한 실행이 성공한 게시 workflow인지 확인하고, 산출물의 태그가 입력 태그와 같을 때만 배포.
두 명령 모두 운영 배포를 실행하므로 로컬 검증용으로 사용하지 않음.
대기열 동작은 [GitHub concurrency 안내](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency) 기준.

`keep_files: true`로 이전 해시 자산과 삭제된 사이트 경로도 `gh-pages`에 보존.
현재 게시 과정에는 정리 단계가 없으므로 소스에서 파일을 삭제해도 공개 경로는 제거되지 않음.
페이지 내용 롤백은 해당 소스 변경을 revert한 뒤 새 버전 태그로 게시·배포 결과 확인.
사이트 완전 제거는 feed를 보존한 별도 정리 작업 필요.

```sh
cd .. # 저장소 루트에서 실행
WITH_FEED=1 ./script/site_assemble.sh /tmp/site-preview "$(git rev-parse --short HEAD)"
(cd site && npx astro preview --outDir /tmp/site-preview --host 127.0.0.1 --port 8080)
./script/site_smoke.sh http://127.0.0.1:8080 /tmp/site-preview
```

- `site_assemble.sh`: 빌드 후 stamp 치환, 출력 단언, 금지 문자열 검사. 인접 임시 폴더에서 모두 통과한 뒤 결과 교체.
- 앱 원문의 `official Claude sign-in`·`official Codex sign-in`은 provider 로그인 안내로만 허용. 사이트의 공식성 주장 차단은 유지.
- 기본 출력은 `.build/site-preview`. 빈 폴더 또는 `.egasu-site-output`·이전 `.openusage-site-output` 표식이 있는 결과만 교체 가능.
  새 조립 결과는 `.egasu-site-output` 표식 사용.
- 소스·상위 폴더·심볼릭 링크 출력과 무관한 기존 폴더는 거부. 빌드·검증 실패 시 이전 결과 보존.
- `WITH_FEED=1`은 라이브 `appcast.xml`·`pricing_supplement.json`을 미리보기용으로만 복사. 배포 경로는 이 파일들을 절대 쓰지 않음.
- `site_feed_snapshot.sh`: 게시 ref의 필수 파일이 일반 파일인지 확인하고 도메인 검사 후 피드 두 개의 blob ID 출력. publisher에서 게시 전후 결과 비교.
- `site_smoke.sh`: 배포 후 검증. 두 번째 인자로 해당 배포에 포함된 feed 두 개의 사본 폴더를 필수 지정. 응답이 기준 사본과 바이트 단위로 같은지, appcast에 유효한 정식 릴리스가 있는지, 링크·자산이 응답하는지 확인.
- 링크·자산 URL은 한 항목씩 그대로 요청. 로컬 파일명에 따른 와일드카드 확장 방지.
- 피드 불일치나 기준 누락은 실패. 캐시 전파가 끝난 뒤 같은 기준으로 다시 실행. 검사 중 새 릴리스가 생겨도 기준은 바뀌지 않으며 원격 브랜치를 조회하지 않음.
- 조립 결과는 Astro preview로 제공하여 알 수 없는 경로에도 사이트의 404 페이지 반환.
- 로컬 예제는 조립 결과의 라이브 feed 사본과 비교하는 HTTP 경로 점검. 운영 배포 검증은 검사 대상 서버에서 다시 받은 파일이 아닌 해당 배포 산출물의 원본 사본 사용.

## 제약

- **`/appcast.xml`과 `/pricing_supplement.json`은 어떤 경우에도 이 경로가 건드리지 않음.** Sparkle 업데이트와 가격표가 걸려 있음.
- 외부 요청 0. 폰트·스크립트·이미지 모두 같은 출처.
- 인라인 `<style>`·`style=`·인라인 `<script>` 금지. meta CSP가 막음.
  - 동적 값은 CSSOM(`el.style.setProperty`)이나 클래스로 처리.
- 트래커·쿠키·분석 없음.

## 구조

```text
src/data/         site.ts(브랜드·URL) copy.ts(페이지 문자열) providers.ts(지원 업체)
                  demo.ts(파생 규칙 · Total Spend · 스트립) dashboard.ts(카드 더미 값)
                  metrics.ts(지표 목록) settings.ts(Settings 화면 목록)
                  accounts.ts(공개용 계정 예시) preview-state.ts(설정·계정 상태 규칙) tour.ts(시연 화면 배치)
                  preview-locale.ts(앱 번역 해석) preview-translations.ts(웹 전용 번역)
src/styles/       tokens.css base.css + app-*.css(앱 재현 그래픽)
src/components/   페이지 섹션
src/components/app/  앱 화면 재현 파트. Popover.astro가 화면 여러 장을 담는 껍데기
src/utils/sprite.ts  provider 마크를 인라인 <symbol>로
src/scripts/app.ts   appcast 파서, 리빌, 내비
src/scripts/tour.ts  연속 기능 시연, 카메라 배율, 커서, 중단 처리
src/scripts/tour-scroll.ts  페이지·기능 스크롤·스와이프·키보드 이동과 내부 콘텐츠 경계
src/scripts/nav.ts   팝오버 화면 이동·계정·지표 조작
src/scripts/menus.ts  메뉴 표시 레이어와 화면 경계 배치
src/scripts/settings.ts  설정 저장·표시 반영·계정 전환
src/scripts/localization.ts  앱 번역 리소스 연결·언어 즉시 전환
scripts/og.html      OG 이미지 원본
```

`src/utils/`는 원래 `src/lib/`이었으나 루트 `.gitignore`의 `lib/` 규칙에 걸려 이름을 바꿈.

## 앱 화면 재현 그래픽

`Sources/Egasu/`의 SwiftUI 구성·문자열을 HTML/CSS로 재현.
화면 구성 기준은 [디자인](/site/docs/design.md) 참조.
Updates는 업데이트 피드가 포함된 배포판 기준으로 표시.

- 지표 목록은 각 프로바이더의 `widgetDescriptors` 선언 순서.
  모든 지표는 기본 표시, 고정은 사용자 선택이며 개수 제한 없음.
- 계정별 키는 등록 계정 ID, 공통 지표 키는 프로바이더 ID 사용.
  숨긴 지표는 고정 해제하며 공통 지표의 순서도 계정 간 공유.
- 앱의 영어 원문과 한국어·일본어 리소스를 재사용.
  웹 전용 안내는 별도 번역 표에서 관리.
- 메뉴·설정·대시보드·안내·날짜·접근성 이름에 언어 적용.
  소개 본문과 기능 탭·설명은 한국어 유지.
- 메뉴는 최상위 표시 레이어에 띄우고 브라우저 화면 안으로 위치 보정.
  클릭·우클릭·키보드로 메뉴 열기.
  **Options**와 설정 선택 메뉴를 Esc로 닫으면 각각 메뉴를 열었던 버튼으로 초점 복귀.
  설정 선택 메뉴에서 값을 고를 때도 해당 메뉴 버튼으로 초점 복귀.
  메뉴에서 Accounts·Settings 등의 화면을 열면 이동한 화면의 첫 컨트롤에 초점.
  Total Spend 기간은 방향키로도 선택하며 선택한 기간만 Tab 이동 대상.
- 화면·탭 전환 시 내부 스크롤을 처음으로 이동.
  계정·지표 설정 변경 뒤에도 키보드 초점 유지.
- 본문·페이지 스크롤, 외부 클릭·초점 이동, 창 크기 변경 시 메뉴 닫기.
- JavaScript가 없으면 All Usage, 비용 예시, 다운로드 링크 표시.
  Options와 탭 등 화면 이동 컨트롤은 숨김.
- 상태 조합은 빌드 시 준비하고 JavaScript가 표시·순서·계산값 갱신.
  페이지의 실제 사용량·인증 정보를 요청하지 않음.
- `app-scale.css` 유틸 이름은 `am-` 접두사 사용.
  사이트 제목 등의 전역 클래스와 충돌 방지.

- Options에서 Accounts·Settings로 이동.
  Accounts에서 계정 이름·순서와 계정별·공통 지표 순서·표시·고정을 관리.
  정렬 손잡이에 초점을 두고 위·아래 방향키로 같은 목록 안에서 순서 변경.
  설정과 이름·순서는 해당 브라우저에 저장하고 화면 위치는 미리보기마다 유지.
  활성 프로바이더 모두에 사용량 예시가 있고 표시할 지표가 없으면 All Usage에서 Accounts의 표시 설정을 확인하도록 안내.
  같은 프로바이더의 다른 계정과 이름이 같으면 변경을 거부.
  현재 언어로 표시한 기본 이름도 중복 검사에 포함.
  지표 설정을 바꿔도 입력 중인 이름과 중복 오류 안내 유지.
  언어 전환 후 번역된 기본 이름이 저장된 사용자 지정 이름과 같으면 해당 기본 이름을 영어로 표시.
  예시 사용량이 없는 항목은 로그인 안내를 표시하며 미리보기에서 제거 가능.
- Settings의 기본 탭은 General·Display·Alerts·Advanced.
  Beta Updates를 켜면 Labs 탭에 Soft Limit과 Terminal Helper 표시.
  Terminal Helper 설치·제거는 브라우저에 저장한 예시로 동작.
  Labs를 숨겨도 설치 상태를 유지하고 제거하려면 확인 필요.
  언어는 새로고침 없이 적용.
  이전에 저장한 Hide From Screen Share 설정값은 Privacy Mode로 이어받음.
  Privacy Mode에서는 대시보드의 계정 이름과 이메일을 가림.
  Accounts에서는 계정 이름을 확인하고 편집 가능.

## 데모 검증

```sh
cd site # 저장소 루트 기준
npm ci
npx playwright install chromium firefox webkit
npm run verify # 타입 검사 + Node 검사 + 빌드 + E2E
```

`npm run check`는 Astro·TypeScript 정적 검사, `npm test`는 Node 검사, `npm run test:e2e`는 새 프로덕션 빌드의 브라우저 검사.
E2E는 Chromium·Firefox·WebKit 데스크톱과 Chromium·WebKit 모바일 에뮬레이션 사용.
모바일 WebKit의 자동화 API는 휠 입력을 지원하지 않아, 두 휠 검사는 같은 390px 폭의 데스크톱 WebKit 프로젝트로 분리.
총 6개 프로젝트이며 실제 휴대폰 터치·트랙패드 하드웨어 검증은 별도.
독립 포트 4391에서 해당 실행의 새 서버를 띄우며 기존 개발 서버를 재사용하지 않음.
포트 충돌 시 `SITE_E2E_PORT`로 변경 가능.
각 검사는 새 브라우저 컨텍스트와 가짜 appcast 사용. 실제 다운로드·설치·사용자 저장소 변경 없음.
첫 화면 조작 전 폰트 준비를 기다리고 시작 위치를 원점으로 설정한 뒤 후속 렌더링 프레임까지 대기.
WebKit의 초기 화면 보정과 입력 검사 간 경합 방지.
기본 동작 줄이기 검사와 실제 계정 추가 애니메이션·빠른 취소 검사 병행.
실패 시 `test-results/`에 스크린샷·trace, `playwright-report/`에 HTML 보고서 저장.
런타임 오류와 예상하지 않은 CSP 오류는 실패 처리.
잘못된 XML 입력에서만 브라우저가 생성한 스타일의 CSP 진단을 최대 두 건 허용.
Chromium은 알려진 해시, WebKit은 해당 진단 문구로 확인.
`.github/workflows/site.yml`은 GitHub Actions의 Playwright 공식 Docker 이미지에서 같은 검증과 조립 수행. 배포 동작 없음.
`site/package-lock.json`에 기록된 `playwright-core` 버전으로 Ubuntu Noble 이미지 선택.
Node는 24 사용.
브라우저·시스템 라이브러리는 이미지에 포함되어 CI의 별도 `playwright install` 단계 생략. 버전 조회와 검증에 같은 커밋을 사용.
프로젝트 의존성은 `npm ci`로 설치.
컨테이너는 GitHub Actions 홈 디렉터리와 같은 UID 1001로 실행하여 Firefox의 root·홈 소유권 충돌 방지.
사이트 빌드·미리보기 서버·E2E가 같은 컨테이너 안에서 실행되므로 호스트 포트 공개 불필요.
Docker 안의 WebKit 검사는 Linux 환경이며 실제 macOS Safari·iPhone 검증과 별개.
구성 기준은 [Playwright Docker 안내](https://playwright.dev/docs/docker)와 [GitHub Actions 컨테이너 예제](https://playwright.dev/docs/ci#via-containers).

`npm test`로 앱 코드의 Settings 섹션·행·옵션과 데모 목록 대조.
번역 함수로 감싼 영어 원문도 추출하며, 필수 행·알림·로그 옵션을 찾지 못하면 실패.
계정 선택과 활성 계정의 분리, 카드 표시 방식 전환, 설정 저장·복원, 잘못된 저장값 거부, 시간 표시 회귀 검사 포함.
한국어·일본어·영어 즉시 전환, 날짜와 시간의 번역, 메뉴·안내·기능 시연 반영과 새로고침 복원 검사 포함.
기능 시연의 전체 화면·확대 화면이 짧거나 좁은 뷰포트를 벗어나지 않는 배치 검사 포함.
기능 앞뒤 이동, 관성 중복 전환 방지, 첫·마지막 단계 이탈, 섹션 진입과 터치 제스처 회귀 검사 포함.
작은 휠 입력의 페이지 이동, 연속 입력·키 누름 진행, 긴 페이지와 앱 내부 스크롤 경계 검사 포함.
메뉴의 화면 가장자리 정렬과 위아래 방향 전환 검사 포함.
브라우저에서는 섹션 정렬, 팝업 하단 잘림, 단계 간 확대 위치 유지, 빈 계정부터 추가 완료까지의 흐름, 빠른 탭 전환 취소와 키보드 이동 확인.
계정·설정·Options·지표 메뉴는 모서리 항목의 실제 클릭 가능 여부와 앱 높이 유지, 스크롤·Esc 닫힘 확인.
조립 실패·금지 문자열·feed 충돌 시 기존 결과 보존과 무관한 폴더 보호 검사 포함.
게시 workflow의 실제 검사 단계를 로컬 Git 저장소로 실행하여 정상 사이트 갱신과 feed 변경·누락·도메인 불일치 차단 확인.
E2E에 계정 이름 변경·복원, 지표 표시·고정·정렬, 설정 저장 차단·잘못된 저장값, 내부 스크롤 경계, 404 복귀, 로컬 자산·CSP·중복 ID 검사 포함.

## 다운로드 정보

같은 출처 `/appcast.xml`에서 채널이 없고 `숫자.숫자.숫자` 형식인 정식 버전만 선택.
양의 안전한 정수인 `sparkle:version`이 가장 큰 항목 우선, 동률이면 발행일 비교.
다운로드 URL은 원문과 정규화 결과가 모두 이 포크의 `releases/download/` 아래여야 함.
선택한 정식 릴리스의 버전을 마지막 다운로드 버튼 안에 표시.
응답 본문을 포함해 5초 제한 적용.
HTTP·XML·본문 시간 초과 등 실패는 콘솔에 기록하고 기본 GitHub 릴리스 페이지 링크 유지.
E2E는 정식 버전 선택·잘못된 빌드/URL과 각 실패 경로 검사.

## OG 이미지

`public/og.png`는 `scripts/og.html`을 1200×630으로 캡처한 결과.

- 재생성: 브라우저나 헤드리스 캡처 도구로 `scripts/og.html`을 열고 뷰포트 1200×630, DPR 1로 스크린샷.
- 시스템 폰트를 사용하므로 캡처 환경에 따라 글꼴 차이 발생 가능.
- provider 마크 path는 앱 리소스에서 붙여 넣은 값. 마크가 바뀌면 같이 갱신.
