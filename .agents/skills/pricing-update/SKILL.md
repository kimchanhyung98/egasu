---
name: pricing-update
description: Sync egasu's pricing supplement with Cursor's published model pricing. Pulls https://cursor.com/docs/models-and-pricing.md, diffs it against pricing_supplement.json, updates entries/aliases/multipliers, validates, and opens a PR. Use when Cursor adds or re-prices models, a spend tile shows a warning triangle for an unpriced model, or a periodic pricing check is due.
---

# Pricing Update

`Sources/Egasu/Resources/pricing_supplement.json`은 공개 카탈로그에 없는 Cursor 전용 모델(`auto`, `composer-*`, `github_bugbot`) 단가·fast 배수·프로바이더 로그와 CSV slug의 가격 키 매핑 제공.
버전 태그 푸시 또는 대상 태그의 수동 실행 시 `.github/workflows/pricing-supplement.yml`이 검증 후 GitHub Pages에 게시.
게시 전 태그의 버전 형식과 `main` 이력 포함 여부 확인.
설치된 앱은 앱 업데이트 없이 다음 가격표 갱신에서 반영.
상세 설명은 [모델 가격](/docs/pricing.md) 참조.

Only the supplement needs manual care. Normal API models (new Claude/GPT/Gemini/Grok releases) are priced automatically by the daily LiteLLM and models.dev fetches — do not add them to the supplement unless they need an alias rule or the catalogs are wrong.

## Steps

### 1. Pull the source of truth into context

Fetch https://cursor.com/docs/models-and-pricing.md and read the whole thing. This is the canonical source for:

- Cursor-native model prices (`auto`, `composer-*`, Bugbot) — input, cache write, cache read, output, all USD per million tokens.
- Which models have a fast variant and what the fast pricing is.
- Long-context tiers (e.g. Sonnet 1M) that bill the whole request at the >200k rate.
- Model names/slugs as Cursor spells them (needed for alias rules).

### 2. Diff against the current supplement

Read `Sources/Egasu/Resources/pricing_supplement.json` and compare:

- **Price changes** on existing `pricing` entries.
- **New Cursor-native models** missing from `pricing`.
- **Removed/renamed models** — never delete an entry that old usage data may still reference; keep it so historical days keep their dollars. Only remove an entry if it was outright wrong.
- **`fast_multipliers`** — for API models whose fast variant is priced as a multiplier of the base rate. Only needed when the catalogs don't carry a `-fast` key themselves.
- **`alias_rules`** — a new model usually needs one, because Cursor CSV slugs and Codex/Claude log names rarely match catalog keys exactly (thinking suffixes, effort levels like `-low`/`-high`/`-xhigh`, dot vs dash versions). Follow the existing patterns: anchored regex, escaped dots, optional effort/thinking groups. `-fast` variants need their own rule ordered BEFORE the base rule (first match wins).

Where a model exists in LiteLLM or models.dev, prefer an alias to that canonical key over duplicating prices in the supplement.

### 3. Edit the supplement

- Update `updated_at` to now as a UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`). The publish workflow rejects any other spelling, including date-only.
- Keep the file's style: 2-space indent, rates as plain numbers, `$comment` explanations for non-obvious entries.
- Rates are USD per million tokens; cache read defaults matter — copy the exact numbers from the Cursor page, don't infer.

### 4. Validate

Run the same checks CI runs, plus the pricing tests:

```sh
python3 - << 'PY'
import json, re, sys
from datetime import datetime
with open("Sources/Egasu/Resources/pricing_supplement.json") as f:
    s = json.load(f)
problems = []
u = s.get("updated_at")
if not isinstance(u, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", u):
    problems.append("updated_at must use YYYY-MM-DDTHH:MM:SSZ UTC format")
else:
    try: datetime.strptime(u, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError: problems.append("updated_at must be a valid UTC date and time")
for m, e in s["pricing"].items():
    for f_ in ("input_per_million", "output_per_million"):
        if not isinstance(e.get(f_), (int, float)):
            problems.append(f"pricing[{m}].{f_} missing or not a number")
for r in s["alias_rules"]:
    try: re.compile(r["pattern"])
    except re.error as err: problems.append(f"{r['pattern']!r}: {err}")
    if not r.get("canonical"): problems.append(f"{r['pattern']!r} has no canonical")
for m, x in (s.get("fast_multipliers") or {}).items():
    if not isinstance(x, (int, float)) or x <= 0:
        problems.append(f"fast_multipliers[{m}] must be positive")
sys.exit("FAILED:\n" + "\n".join(problems)) if problems else print("Supplement OK")
PY

swift test --filter "ModelPricing|PricingBundledResource"
```

If a new alias rule maps a slug that appears in real usage, add a resolution test case in `Tests/EgasuTests/ModelPricingTests.swift`.

### 5. Open a PR

Branch from `main`, commit (`fix(pricing): ...` or `feat(pricing): ...`), and open a PR following the repo's PR description structure (TL;DR / What was happening / What this changes). Cite the Cursor doc as the source and list each price or alias change explicitly so the owner can verify numbers at a glance. Never push pricing changes directly to `main`.

### 6. 태그 게시 결과 확인

승인된 버전 태그를 푸시하거나 `Publish pricing supplement`를 대상 태그로 수동 실행한 뒤 게시 결과 확인.

```sh
gh run list --repo kimchanhyung98/egasu --workflow=pricing-supplement.yml --limit 1
curl -s https://egasu.chanhyung.kim/pricing_supplement.json | python3 -c "import json,sys; print(json.load(sys.stdin)['updated_at'])"
```

라이브 `updated_at`은 게시한 태그의 파일과 일치해야 함.
가격표 workflow의 `gh-pages` 게시 후 `deploy-pages.yml`이 검증된 게시 커밋을 실제 사이트에 배포.
수동 가격표 게시도 `gh workflow run pricing-supplement.yml --repo kimchanhyung98/egasu --ref main -f tag=<버전 태그>`처럼 대상 태그 필수.
Pages 배포가 실패하면 해당 실행을 재시도하거나 `gh workflow run deploy-pages.yml --repo kimchanhyung98/egasu --ref main -f tag=<버전 태그> -f publication_run_id=<성공한 게시 실행 ID>`로 같은 게시 결과 재배포.

## Optional: refresh bundled snapshots

The bundled LiteLLM/models.dev snapshots (`pricing_*_snapshot.json`) are a separate concern — offline fallbacks refreshed with `./script/update_pricing_snapshots.sh`, typically before a release. Staleness is harmless; only regenerate them if asked or as part of release prep, in their own commit.

## Rules

- USD per million tokens everywhere; exact numbers from the Cursor page, never inferred.
- Prefer aliasing to LiteLLM/models.dev keys over duplicating prices in the supplement.
- Never delete pricing entries that historical usage may reference.
- `-fast` alias rules come before their base-model rules.
- Always bump `updated_at`; always go through a PR.
