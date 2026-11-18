#!/usr/bin/env bash
set -euo pipefail

# 대상 GitHub 저장소에 브랜치·태그 보호 규칙 적용.
#
#   ./script/apply_github_protections.sh
#
# 전제 조건: 저장소 관리자 계정으로 gh CLI 인증 완료.

REPO="${REPO:-kimchanhyung98/egasu}"

# 저장소 공개 여부와 관계없이 GitHub API에 요청하고 실패 응답 전달.
echo "==> Branch protection on main (required CI check, 2 approvals, code owners, conversation resolution; admins exempt)"
BRANCH_PROTECTION='{
  "required_status_checks": {"strict": true, "contexts": ["Build and Test"]},
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "require_last_push_approval": false,
    "required_approving_review_count": 2
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}'
if ! echo "$BRANCH_PROTECTION" | gh api -X PUT "repos/$REPO/branches/main/protection" --input - >/dev/null; then
  echo "    Could not apply — GitHub's error above says why. The usual cause: these features are"
  echo "    unavailable on private free-plan repos. Make the repo public (or upgrade), then re-run."
  exit 1
fi
echo "    applied."

# 규칙이 없으면 생성, 있으면 ID로 갱신해 재실행 시에도 같은 설정 유지.
apply_ruleset() {
  local name="$1" payload="$2"
  local existing_id
  existing_id="$(gh api "repos/$REPO/rulesets" --jq "[.[] | select(.name==\"$name\") | .id] | first // empty")"
  if [[ -n "$existing_id" ]]; then
    echo "$payload" | gh api -X PUT "repos/$REPO/rulesets/$existing_id" --input - >/dev/null
    echo "    \"$name\" updated to match."
  else
    echo "$payload" | gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null
    echo "    \"$name\" created."
  fi
}

# 태그 보호의 예외 대상은 저장소 관리자 역할.
echo "==> Tag ruleset: only the repo owner can create/update/delete v* release tags"
apply_ruleset "Release tags owner only" '{
  "name": "Release tags owner only",
  "target": "tag",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
  "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}],
  "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]
}'

echo "==> Branch ruleset: automatic Copilot review on PRs to main"
apply_ruleset "Copilot review for default branch" '{
  "name": "Copilot review for default branch",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [{"type": "deletion"}, {"type": "non_fast_forward"}, {"type": "copilot_code_review", "parameters": {"review_on_push": false, "review_draft_pull_requests": false}}],
  "bypass_actors": []
}'

echo "Done."
