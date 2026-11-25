---
name: pricing-update
description: Sync egasu's pricing supplement with official provider prices and Cursor-specific rates. Update prices, aliases, Fast multipliers, and long-context tiers, validate against the publish workflow, and prepare a PR when models change or usage prices are unresolved.
---

# Pricing Update

`Sources/Egasu/Resources/pricing_supplement.json`은 공개 카탈로그에 없는 Cursor 전용 모델(`auto`, `composer-*`, `github_bugbot`) 단가·fast 배수·프로바이더 로그와 CSV slug의 가격 키 매핑 제공.
버전 태그 푸시 또는 대상 태그의 수동 실행 시 `.github/workflows/pricing-supplement.yml`이 검증 후 GitHub Pages에 게시.
게시 전 태그의 버전 형식과 `main` 이력 포함 여부 확인.
설치된 앱은 앱 업데이트 없이 다음 가격표 갱신에서 반영.
상세 설명은 [모델 가격](/docs/pricing.md) 참조.

앱은 마지막 성공 후 1시간이 지나면 LiteLLM·models.dev·보충 파일을 다시 확인.
일반 API 모델은 카탈로그 단가를 사용하되, 공식 정가와 다르거나 별칭·Fast·장문 처리가 필요하면 보충 파일에서 보정.

## Steps

### 매 릴리스의 확인 범위

1. 릴리스 후보의 `ProviderCatalog.make()`와 추가 예정 프로바이더 목록에서 대상을 확정.
2. 변경 이력이 없는 프로바이더도 구독료·포함 크레딧·사용량의 단위를 공식 자료와 대조.
3. 토큰 추정 경로는 입력·출력·캐시·Fast·장문 정가를 확인하고, 크레딧 환산 경로는 크레딧당 단가를 확인.
4. 서버가 비용이나 잔액을 제공하는 경로는 통화·정밀도·기간을 확인.
5. 아래 절차로 번들 스냅샷을 갱신한 뒤 과거 모델과 새 모델의 실제 이름으로 계산을 검증.
6. 대상별 공식 출처·단위·변경 여부와 실제 계정에서 확인하지 못한 조건을 릴리스 검토 기록에 남김.

### 1. Pull the source of truth into context

API 모델은 해당 프로바이더의 공식 가격 문서에서 정가·캐시·Fast·장문 조건 확인.
Cursor 전용 항목은 [Cursor 모델 및 가격](https://cursor.com/docs/models-and-pricing.md)에서 별도 확인.
확인 항목:

- Cursor-native model prices (`auto`, `composer-*`, Bugbot) — input, cache write, cache read, output, all USD per million tokens.
- Which models have a fast variant and what the fast pricing is.
- Long-context tiers (e.g. Sonnet 1M) that bill the whole request at the >200k rate.
- Model names/slugs as Cursor spells them (needed for alias rules).

### 2. Diff against the current supplement

Read `Sources/Egasu/Resources/pricing_supplement.json` and compare:

- **현재 단가** — `pricing_v2`를 `pricing` 위에 병합하며 중복 키는 v2 우선.
  새 단가·장문·공급 경로별 보정은 `pricing_v2`에 등록.
- **구버전 호환** — 기존 `pricing`·`alias_rules`는 구버전 앱이 계속 사용하므로 호환성을 확인한 경우에만 수정.
  Cursor 전용 단가는 `cursor/` 키로 API 정가와 구분.
- **Removed/renamed models** — never delete an entry that old usage data may still reference; keep it so historical days keep their dollars. Only remove an entry if it was outright wrong.
- **Fast 배율** — 새 배율은 `fast_multipliers_exact`에 등록.
  등록 모델·별칭·날짜 변형에만 적용되며, 기존 `fast_multipliers`의 넓은 이름 매칭은 구버전 호환용으로 유지.
  명시적 Fast 단가와 카탈로그 배율을 확인해 중복 적용 방지.
- **별칭** — 새 규칙은 `alias_rules_v2`에 등록하며, 앱은 v2 규칙 뒤에 기존 `alias_rules` 적용.
  실제 Cursor 모델명·Codex/Claude 로그 이름과 카탈로그 키를 대조하고 기존 정규식 패턴 유지.
  처음 일치한 규칙을 사용하므로 `-fast` 규칙은 기본 모델 규칙보다 앞에 배치.

카탈로그 단가가 공식 정가와 일치하면 가격 복제보다 해당 키의 별칭 우선.
토큰 기반 추정은 API 정가 기준이며 Batch·Flex 할인과 로그로 식별할 수 없는 지역 할증은 반영하지 않음.
공급자 보고 비용에 별도의 보충 단가·배율을 다시 적용하지 않음.

### 3. Edit the supplement

- Update `updated_at` to now as a UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`). The publish workflow rejects any other spelling, including date-only.
- Keep the file's style: 2-space indent, rates as plain numbers, `$comment` explanations for non-obvious entries.
- 단가는 USD/100만 토큰이며 공식 문서의 정가와 캐시 조건 사용.
- 장문 요율은 `long_context`의 `threshold_tokens`와 입력·출력·캐시 쓰기·캐시 읽기 네 단가로 등록.
  경계는 양의 Int64, 네 단가는 유한한 비음수 필수.
  기본 입력·출력도 유한한 비음수 필수이며 불리언은 거부.
  기본 캐시 단가만 누락·`null` 허용.

### 4. Validate

게시 workflow의 Python 검증 블록을 그대로 실행한 뒤 가격 테스트 실행.
검증 규칙의 기준은 `.github/workflows/pricing-supplement.yml`이며 스킬에 별도 사본을 유지하지 않음.

```sh
python3 - << 'PY'
from pathlib import Path
from textwrap import dedent

path = Path(".github/workflows/pricing-supplement.yml")
workflow = path.read_text()
step = workflow.split("      - name: 가격표 JSON 검증\n", 1)[1]
validator = step.split("          python3 - << 'PY'\n", 1)[1].split("\n          PY", 1)[0]
exec(compile(dedent(validator), str(path), "exec"))
PY

swift test --filter "Pricing|ModelRates|CopilotPersonalCreditsTests|KiroUsageScannerTests"
```

If a new alias rule maps a slug that appears in real usage, add a resolution test case in `Tests/EgasuTests/ModelPricingTests.swift`.

### 5. Open a PR

`main`에서 브랜치를 만들고 `fix(pricing): ...` 또는 `feat(pricing): ...` 형식으로 커밋.
저장소의 PR 설명 구조(TL;DR / What was happening / What this changes)에 맞춰 PR 작성.
사용한 프로바이더·Cursor 공식 문서를 인용하고 가격·별칭 변경 항목을 각각 명시.
가격 변경을 `main`에 직접 푸시하지 않음.

### 6. 태그 게시 결과 확인

대상 태그의 가격표 게시와 후속 Pages 배포가 끝나면 해당 태그의 파일과 앱이 읽는 공개 파일을 바이트 단위로 비교.
`tag`는 검증할 승인된 버전 태그로 설정.

```sh
python3 - "$tag" <<'PYTHON'
import subprocess
import sys
from urllib.request import urlopen

tag = sys.argv[1]
path = "Sources/Egasu/Resources/pricing_supplement.json"
expected = subprocess.check_output(["git", "show", f"refs/tags/{tag}:{path}"])
with urlopen("https://egasu.chanhyung.kim/pricing_supplement.json", timeout=30) as response:
    published = response.read()
if published != expected:
    sys.exit(f"{tag}: published pricing does not match the tagged file")
print(f"{tag}: published pricing matches")
PYTHON
```

가격표 workflow의 `gh-pages` 게시 후 `deploy-pages.yml`이 검증된 게시 커밋을 실제 사이트에 배포.
수동 가격표 게시도 `gh workflow run pricing-supplement.yml --repo kimchanhyung98/egasu --ref main -f tag=<버전 태그>`처럼 대상 태그 필수.
Pages 배포가 실패하면 해당 실행을 재시도하거나 `gh workflow run deploy-pages.yml --repo kimchanhyung98/egasu --ref main -f tag=<버전 태그> -f publication_run_id=<성공한 게시 실행 ID>`로 같은 게시 결과 재배포.

## 번들 스냅샷 갱신

번들 LiteLLM/models.dev 스냅샷(`pricing_*_snapshot.json`)은 `./script/update_pricing_snapshots.sh`로 갱신하는 별도 항목.
오프라인·원격 갱신 실패 시 번들 가격을 사용하므로 오래된 단가는 추정값에 영향.
베타·정식 릴리스 후보마다 재생성한 뒤 기존 키 보존과 달라진 단가 확인.

## Rules

- USD/100만 토큰 단위와 해당 공식 가격 문서의 정확한 수치 사용.
- Prefer aliasing to LiteLLM/models.dev keys over duplicating prices in the supplement.
- Never delete pricing entries that historical usage may reference.
- `-fast` alias rules come before their base-model rules.
- Always bump `updated_at`; always go through a PR.
