# Changelog

This changelog starts with v0.8.0, the first release of this fork.

## v1.0.0

### 새 기능

- Z.ai 기간별 토큰·추정 비용 통계 추가 ([#140](https://github.com/kimchanhyung98/egasu/pull/140)) by @kimchanhyung98.
- Kimi CLI 토큰·추정 비용 통계 추가 ([#141](https://github.com/kimchanhyung98/egasu/pull/141)) by @kimchanhyung98.
- Devin CLI 사용량 기반 기간별 통계 추가 ([#142](https://github.com/kimchanhyung98/egasu/pull/142)) by @kimchanhyung98.
- Kiro 로컬 크레딧·토큰 추정 통계 추가 ([#143](https://github.com/kimchanhyung98/egasu/pull/143)) by @kimchanhyung98.
- 여러 도구의 사용 기록을 함께 처리하는 공통 수집 모듈 추가 ([#155](https://github.com/kimchanhyung98/egasu/pull/155)) by @kimchanhyung98.
- Gemini CLI·Qwen CLI 세션 사용량 수집 추가 ([#158](https://github.com/kimchanhyung98/egasu/pull/158)) by @kimchanhyung98.
- OpenClaw·Hermes Agent·DeepSeek Harness 사용 기록 수집 추가 ([#159](https://github.com/kimchanhyung98/egasu/pull/159)) by @kimchanhyung98.
- Kilo Code·Kilo CLI·Junie 및 Kimi·Kiro 보충 기록 수집 추가 ([#160](https://github.com/kimchanhyung98/egasu/pull/160)) by @kimchanhyung98.

### 오류 수정

- 스냅샷 갱신 시 공개 피드에서 삭제된 과거 모델의 단가 보존 ([#162](https://github.com/kimchanhyung98/egasu/pull/162)) by @kimchanhyung98.
- Claude·Codex 사용량 알림에 계정명 표시 ([#133](https://github.com/kimchanhyung98/egasu/pull/133)) by @kimchanhyung98.
- 상단 통계 안내문의 프로바이더 이름 중복 제거 ([#134](https://github.com/kimchanhyung98/egasu/pull/134)) by @kimchanhyung98.
- Codex 재로그인·계정 전환 시 인증 충돌 방지 ([#139](https://github.com/kimchanhyung98/egasu/pull/139)) by @kimchanhyung98.
- Codex 압축·중단 응답 사용량의 누락과 중복 수정 ([#144](https://github.com/kimchanhyung98/egasu/pull/144)) by @kimchanhyung98.
- OpenCode fork 사용량 중복 집계 수정 ([#145](https://github.com/kimchanhyung98/egasu/pull/145)) by @kimchanhyung98.
- Grok 세션 간 모델 혼동에 따른 비용 집계 오류 수정 ([#146](https://github.com/kimchanhyung98/egasu/pull/146)) by @kimchanhyung98.
- Pi 사용량의 독립 집계 및 압축 호출 모델 오귀속 수정 ([#147](https://github.com/kimchanhyung98/egasu/pull/147)) by @kimchanhyung98.
- 배포 앱에 필요한 리소스 번들만 포함 ([#149](https://github.com/kimchanhyung98/egasu/pull/149)) by @kimchanhyung98.
- 현재 요금제 정보와 모델 가격 매칭 갱신 ([#150](https://github.com/kimchanhyung98/egasu/pull/150)) by @kimchanhyung98.
- 프로바이더별 인증·할당량·잔액 처리 수정 ([#151](https://github.com/kimchanhyung98/egasu/pull/151)) by @kimchanhyung98.
- 백그라운드 작업 순차 실행 및 갱신 대기 상태 표시 ([#152](https://github.com/kimchanhyung98/egasu/pull/152)) by @kimchanhyung98.
- 가격이 없는 모델의 토큰 보존 및 불완전한 총비용 표시 방지 ([#153](https://github.com/kimchanhyung98/egasu/pull/153)) by @kimchanhyung98.
- 프로바이더 내부 분석 요청을 순차 실행하도록 수정 ([#154](https://github.com/kimchanhyung98/egasu/pull/154)) by @kimchanhyung98.
- 기존 CLI 원장과 특수 사용량 기록 보존 ([#157](https://github.com/kimchanhyung98/egasu/pull/157)) by @kimchanhyung98.
- 수집 실패 시 정상 사용 이력 보존 및 조치가 필요 없는 경고 축소 ([#161](https://github.com/kimchanhyung98/egasu/pull/161)) by @kimchanhyung98.

### 구조 개선

- 앱·CLI·사이트 이름을 egasu로 변경. 기존 계정·설정·iCloud 이력과 이전 CLI 명령 유지, 업데이트 시 앱 이름 이전 및 중단 후 복구 지원 ([#148](https://github.com/kimchanhyung98/egasu/pull/148)) by @kimchanhyung98.

### 유지보수

- Node.js 타입 정의 26.6.6으로 갱신 ([#135](https://github.com/kimchanhyung98/egasu/pull/135)) by @dependabot[bot].
- Astro 7.4.4로 갱신 ([#136](https://github.com/kimchanhyung98/egasu/pull/136)) by @dependabot[bot].
- PostHog 3.92.7로 갱신 ([#137](https://github.com/kimchanhyung98/egasu/pull/137)) by @dependabot[bot].
- Sparkle 2.10.1로 갱신 ([#138](https://github.com/kimchanhyung98/egasu/pull/138)) by @dependabot[bot].
- 오래된 조사 문서 정리 ([#156](https://github.com/kimchanhyung98/egasu/pull/156)) by @kimchanhyung98.
- 동작 설명과 공식 근거 링크 정리 ([e25e935](https://github.com/kimchanhyung98/egasu/commit/e25e935b3c6431208a778a91018e34e081c168c7)) by @kimchanhyung98.
- 오프라인 가격 조회용 LiteLLM·models.dev 스냅샷 갱신 by @kimchanhyung98.

---

### 변경 이력

**전체 변경 이력**: [v0.14.3...v1.0.0](https://github.com/kimchanhyung98/egasu/compare/aad6ff61e2a07ed58499c9843059aff7d1ccf103...0158a488cc2c68e5a006fb3f7f9430ae0d7e0979)

## v0.11.3

### New Features

- feat(codex): show scheduled resets as 99% forecasts ([#35](https://github.com/kimchanhyung98/openusage/pull/35)) by @kimchanhyung98.
- feat(site): add an interactive Korean landing page ([#34](https://github.com/kimchanhyung98/openusage/pull/34)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.11.2...v0.11.3](https://github.com/kimchanhyung98/openusage/compare/v0.11.2...v0.11.3)

## v0.11.2

### Bug Fixes

- fix(codex): show zero reset chance when no active signal exists ([#25](https://github.com/kimchanhyung98/openusage/pull/25)) by @kimchanhyung98.
- fix(telemetry): harden diagnostics, consent, and account isolation ([#24](https://github.com/kimchanhyung98/openusage/pull/24)) by @kimchanhyung98.
- fix(git-hooks): isolate repository environment in pre-commit ([#26](https://github.com/kimchanhyung98/openusage/pull/26)) by @kimchanhyung98.
- fix(local-api): handle empty paths and peer disconnects ([#27](https://github.com/kimchanhyung98/openusage/pull/27)) by @kimchanhyung98.
- fix(accounts): guard cache and refreshes across credential changes ([#28](https://github.com/kimchanhyung98/openusage/pull/28)) by @kimchanhyung98.
- fix(usage-logs): preserve failure state until confirmed recovery ([#29](https://github.com/kimchanhyung98/openusage/pull/29)) by @kimchanhyung98.
- fix(telemetry): retain crash locations and Swift exception types ([#30](https://github.com/kimchanhyung98/openusage/pull/30)) by @kimchanhyung98.
- fix(diagnostics): classify installer, updater, and pricing failures ([#31](https://github.com/kimchanhyung98/openusage/pull/31)) by @kimchanhyung98.
- fix(accounts): show actual session status in settings ([#32](https://github.com/kimchanhyung98/openusage/pull/32)) by @kimchanhyung98.
- fix(tokscale): add result dismissal and sync cooldown ([#33](https://github.com/kimchanhyung98/openusage/pull/33)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.11.1...v0.11.2](https://github.com/kimchanhyung98/openusage/compare/v0.11.1...v0.11.2)

## v0.11.1

### Bug Fixes

- fix(accounts): hide unregistered shared-home account cards ([#23](https://github.com/kimchanhyung98/openusage/pull/23)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.11.0...v0.11.1](https://github.com/kimchanhyung98/openusage/compare/v0.11.0...v0.11.1)

## v0.11.0

### New Features

- feat(release): derive bundle versions from git tags ([#16](https://github.com/kimchanhyung98/openusage/pull/16)) by @kimchanhyung98.
- feat(codex): add Reset Watch forecast ([#17](https://github.com/kimchanhyung98/openusage/pull/17)) by @kimchanhyung98.
- feat(tokscale): add CLI sync settings ([#19](https://github.com/kimchanhyung98/openusage/pull/19)) by @kimchanhyung98.
- feat(status): add provider server status indicators ([#20](https://github.com/kimchanhyung98/openusage/pull/20)) by @kimchanhyung98.
- feat(accounts): add shared card modes and account ordering ([#21](https://github.com/kimchanhyung98/openusage/pull/21)) by @kimchanhyung98.
### Bug Fixes

- fix(codex): show Reset Watch only on the main account card ([#22](https://github.com/kimchanhyung98/openusage/pull/22)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.9.5...v0.11.0](https://github.com/kimchanhyung98/openusage/compare/v0.9.5...v0.11.0)

## v0.9.5

### Bug Fixes

- Retry durable iCloud usage-history deletions after a transient failure ([#15](https://github.com/kimchanhyung98/openusage/pull/15)) by @kimchanhyung98.
- Conceal menu-bar usage while the screen is being captured ([#14](https://github.com/kimchanhyung98/openusage/pull/14)) by @kimchanhyung98.
- Reject symlinked account sign-in workspaces ([#11](https://github.com/kimchanhyung98/openusage/pull/11)) by @kimchanhyung98.
- Bind Cursor SQLite values instead of interpolating authentication tokens ([#12](https://github.com/kimchanhyung98/openusage/pull/12)) by @kimchanhyung98.
- Redact account names at the local HTTP API boundary ([#13](https://github.com/kimchanhyung98/openusage/pull/13)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.9.4...v0.9.5](https://github.com/kimchanhyung98/openusage/compare/cf33dbd890b9b9b3e2d78e1cfd0774616e29cb3c...ade70bb8e24955cd50de4572337311b63d73450d)

## v0.9.4

### Bug Fixes

- Update GPT-5.6 pricing and aliases ([#10](https://github.com/kimchanhyung98/openusage/pull/10)) by @kimchanhyung98.
- Map Daybreak Blue usage to GPT-5.6 Sol ([219e88c](https://github.com/kimchanhyung98/openusage/commit/219e88cab0a3d12a4b9840383d9621718499f269)) by @kimchanhyung98.

### Chores

- Optimize bundled images ([#2](https://github.com/kimchanhyung98/openusage/pull/2)) by @imgbot[bot].

---

### Changelog

**Full Changelog**: [v0.9.3...v0.9.4](https://github.com/kimchanhyung98/openusage/compare/a5ee0028817e617db1dd501912c5e2a5b3b413fe...cf33dbd890b9b9b3e2d78e1cfd0774616e29cb3c)

## v0.9.3

### Bug Fixes

- Keep one shared customizable card for each provider across managed accounts ([#9](https://github.com/kimchanhyung98/openusage/pull/9)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.9.2...v0.9.3](https://github.com/kimchanhyung98/openusage/compare/edfee95e71fa1c5b835386266595cb11fa2da868...a5ee0028817e617db1dd501912c5e2a5b3b413fe)

## v0.9.2

### Bug Fixes

- Keep account-card layout, notifications, and menu-bar pins scoped to their provider ([d25f6dc](https://github.com/kimchanhyung98/openusage/commit/d25f6dcf344988a0fb716d3506bd78f00fb66b43)) by @kimchanhyung98.
- Store layout per provider and hide unregistered logins ([076871f](https://github.com/kimchanhyung98/openusage/commit/076871f55be91c6dc2dd7d78658afb2a56239629)) by @kimchanhyung98.
- Harden Claude reauthentication reconciliation ([e8403f3](https://github.com/kimchanhyung98/openusage/commit/e8403f3abdb4b61a265cae9eb1a52dfdda5544eb)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.9.1...v0.9.2](https://github.com/kimchanhyung98/openusage/compare/21427211078a7a31ab8e2d4bd160115647e12c3c...edfee95e71fa1c5b835386266595cb11fa2da868)

## v0.9.1

### Bug Fixes

- Reconcile Claude terminal reauthentication without mixing account identities ([#8](https://github.com/kimchanhyung98/openusage/pull/8)) by @kimchanhyung98.

### Documentation

- Standardize documentation and code-comment style ([#7](https://github.com/kimchanhyung98/openusage/pull/7)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.9.0...v0.9.1](https://github.com/kimchanhyung98/openusage/compare/5ed3693ced27839379f1eb35659be3a02613718f...21427211078a7a31ab8e2d4bd160115647e12c3c)

## v0.9.0

### New Features

- Add managed Claude and Codex account switching, per-account dashboard cards, and read-only account CLI commands ([#6](https://github.com/kimchanhyung98/openusage/pull/6)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.8.2...v0.9.0](https://github.com/kimchanhyung98/openusage/compare/e6ec605d77d12243ebfb16f947c72bfff139968b...5ed3693ced27839379f1eb35659be3a02613718f)

## v0.8.2

### Bug Fixes

- Unblock the release pipeline and retarget telemetry ([#5](https://github.com/kimchanhyung98/openusage/pull/5)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.8.1...v0.8.2](https://github.com/kimchanhyung98/openusage/compare/aee49294353255825585fc88cb1548ec2ea74c03...e6ec605d77d12243ebfb16f947c72bfff139968b)

## v0.8.1

### Chores

- Retarget app identifiers, signing, iCloud containers, and the update feed ([#4](https://github.com/kimchanhyung98/openusage/pull/4)) by @kimchanhyung98.
- Make compact density the default dashboard layout ([0865c1f](https://github.com/kimchanhyung98/openusage/commit/0865c1f0159778d23538d9b6822f8d3a282ca702)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.8.0...v0.8.1](https://github.com/kimchanhyung98/openusage/compare/3fdbef4e0076e8493a4be634dcf51d0917166ead...aee49294353255825585fc88cb1548ec2ea74c03)

## v0.8.0

### New Features

- Add Kimi and Kiro usage tracking ([#1](https://github.com/kimchanhyung98/openusage/pull/1)) by @kimchanhyung98.

### Bug Fixes

- Add Claude Opus 5 pricing and native fast-mode pricing ([#3](https://github.com/kimchanhyung98/openusage/pull/3)) by @kimchanhyung98.

---

### Changelog

**Release Commit**: [3fdbef4e](https://github.com/kimchanhyung98/openusage/commit/3fdbef4e0076e8493a4be634dcf51d0917166ead)
