#!/bin/bash
# 공개 가격 피드에서 번들 가격 스냅샷 재생성:
#
#   Sources/Egasu/Resources/pricing_litellm_snapshot.json      (LiteLLM model_prices)
#   Sources/Egasu/Resources/pricing_models_dev_snapshot.json   (models.dev api.json)
#
# 첫 실행·오프라인용 가격. 마지막 성공 후 1시간이 지난 뒤 첫 가격 조회에서 같은 피드의 갱신 시작.
# 갱신에 실패하면 30분이 지난 뒤 가격을 조회할 때 재시도.
# 릴리스 시 갱신해 첫 실행의 가격도 최신 상태로 유지. 저장소 루트에서 실행:
#
#   ./script/update_pricing_snapshots.sh
#
# 축약 형식은 앱 파서와 동일하게 유지: 백만 토큰당 단가, 캐시 쓰기 기본값은 입력 단가, 읽기는 그 1/10.
# 캐시 읽기 단가를 계산한 경우 cre:false로 표시해 공식 할인 단가와 구분.
# 재생성 후 swift test의 가격 결정 테스트로 스냅샷 확인.
set -euo pipefail

cd "$(dirname "$0")/.."
RESOURCES="Sources/Egasu/Resources"

LITELLM_URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
MODELS_DEV_URL="https://models.dev/api.json"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Fetching LiteLLM pricing..."
curl -fsSL --max-time 120 "$LITELLM_URL" -o "$tmpdir/litellm.json"
echo "Fetching models.dev pricing..."
curl -fsSL --max-time 120 "$MODELS_DEV_URL" -o "$tmpdir/models_dev.json"

python3 - "$tmpdir" "$RESOURCES" << 'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

tmpdir, resources = sys.argv[1], sys.argv[2]
retrieved_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def compact_model(input_pm, output_pm, cache_write_pm, cache_read_pm, cache_read_explicit,
                  ia=None, oa=None, cwa=None, cra=None, fast=None):
    model = {"i": input_pm, "o": output_pm, "cw": cache_write_pm, "cr": cache_read_pm}
    if not cache_read_explicit:
        model["cre"] = False
    for key, value in (("ia", ia), ("oa", oa), ("cwa", cwa), ("cra", cra), ("fast", fast)):
        if value is not None:
            model[key] = value
    return model

def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None

def retain_historical_models(filename, current):
    path = Path(resources) / filename
    if path.exists():
        previous = json.loads(path.read_text())["models"]
        return previous | current
    return current

# LiteLLM은 토큰당 단가. 입력·출력 중 단가가 없는 항목은 제외.
with open(f"{tmpdir}/litellm.json") as f:
    litellm = json.load(f)
models = {}
for key, entry in litellm.items():
    if not isinstance(entry, dict):
        continue
    i, o = number(entry.get("input_cost_per_token")), number(entry.get("output_cost_per_token"))
    if i is None or o is None:
        continue
    cw = number(entry.get("cache_creation_input_token_cost"))
    cr = number(entry.get("cache_read_input_token_cost"))
    provider_specific = entry.get("provider_specific_entry") or {}
    models[key] = compact_model(
        i * 1e6, o * 1e6,
        (cw if cw is not None else i) * 1e6,
        (cr if cr is not None else i * 0.1) * 1e6,
        cr is not None,
        ia=(lambda v: v * 1e6 if v is not None else None)(number(entry.get("input_cost_per_token_above_200k_tokens"))),
        oa=(lambda v: v * 1e6 if v is not None else None)(number(entry.get("output_cost_per_token_above_200k_tokens"))),
        cwa=(lambda v: v * 1e6 if v is not None else None)(number(entry.get("cache_creation_input_token_cost_above_200k_tokens"))),
        cra=(lambda v: v * 1e6 if v is not None else None)(number(entry.get("cache_read_input_token_cost_above_200k_tokens"))),
        fast=number(provider_specific.get("fast")) if isinstance(provider_specific, dict) else None,
    )
if not models:
    sys.exit("LiteLLM feed produced no usable entries - aborting.")
models = retain_historical_models("pricing_litellm_snapshot.json", models)
with open(f"{resources}/pricing_litellm_snapshot.json", "w") as f:
    json.dump({"retrieved_at": retrieved_at, "models": models}, f, sort_keys=True, separators=(",", ":"))
print(f"pricing_litellm_snapshot.json: {len(models)} models")

# models.dev는 백만 토큰당 단가. 모델 ID를 그대로 저장하며 중복은 프로바이더 이름순 첫 항목 우선.
with open(f"{tmpdir}/models_dev.json") as f:
    models_dev = json.load(f)
models = {}
for provider_name in sorted(models_dev):
    provider = models_dev[provider_name]
    if not isinstance(provider, dict):
        continue
    for model_id, model in (provider.get("models") or {}).items():
        if model_id in models or not isinstance(model, dict):
            continue
        cost = model.get("cost") or {}
        i, o = number(cost.get("input")), number(cost.get("output"))
        if i is None or o is None:
            continue
        cw, cr = number(cost.get("cache_write")), number(cost.get("cache_read"))
        models[model_id] = compact_model(
            i, o,
            cw if cw is not None else i,
            cr if cr is not None else i * 0.1,
            cr is not None,
        )
if not models:
    sys.exit("models.dev feed produced no usable entries - aborting.")
models = retain_historical_models("pricing_models_dev_snapshot.json", models)
with open(f"{resources}/pricing_models_dev_snapshot.json", "w") as f:
    json.dump({"retrieved_at": retrieved_at, "models": models}, f, sort_keys=True, separators=(",", ":"))
print(f"pricing_models_dev_snapshot.json: {len(models)} models")
PY

ls -lh "$RESOURCES"/pricing_*_snapshot.json
