#!/usr/bin/env bash

# release.sh와 build_and_run.sh에서 사용할 번들 버전을 릴리스 태그에서 유도.

egasu_version_from_tag() {
  local tag="$1"

  if [[ ! "$tag" =~ ^v(0\.([7-9]|[1-9][0-9]+)|[1-9][0-9]*\.(0|[1-9][0-9]*))\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]*)?$ ]]; then
    echo "Release tag must be v0.7.0 or newer, optionally ending in -beta.N, without leading zeroes: $tag" >&2
    return 1
  fi

  printf '%s\n' "${tag#v}"
}

# 릴리스 버전은 실제 HEAD 태그에서만 유도하며 main에 포함된 소스만 허용.
egasu_release_version() {
  local repo_dir="${1:?egasu_release_version requires a repository directory}"
  local tag="$2" version tag_commit head_commit

  version="$(egasu_version_from_tag "$tag")" || return 1
  tag_commit="$(git -C "$repo_dir" rev-parse --verify "refs/tags/$tag^{commit}")" || return 2
  head_commit="$(git -C "$repo_dir" rev-parse --verify HEAD)" || return 2
  if [ "$tag_commit" != "$head_commit" ]; then
    echo "Release tag does not point to HEAD: $tag" >&2
    return 2
  fi
  if ! git -C "$repo_dir" merge-base --is-ancestor "$tag_commit" refs/remotes/origin/main; then
    echo "Release tag must point to a commit reachable from origin/main: $tag" >&2
    return 2
  fi
  printf '%s\n' "$version"
}

# 게시한 버전은 당시 번호 재사용. 동일 커밋의 다음 게시에만 순번 추가.
egasu_release_build() (
  set -eo pipefail
  local repo_dir="$1" tag="$2" ref="refs/remotes/origin/gh-pages" count version entry=""
  version="$(egasu_release_version "$repo_dir" "$tag")"
  count="$(git -C "$repo_dir" rev-list --count HEAD)"
  if git -C "$repo_dir" rev-parse --verify --quiet "$ref" >/dev/null; then
    entry="$(git -C "$repo_dir" ls-tree "$ref" -- appcast.xml)"
  fi
  if [[ -n "$entry" ]]; then
    git -C "$repo_dir" show "$ref:appcast.xml"
  else
    printf '%s\n' '<rss><channel/></rss>'
  fi | python3 "$(dirname "${BASH_SOURCE[0]}")/release_appcast.py" build - "$count" "$version"
)

# 호출자의 현재 디렉터리와 무관하게 전달받은 worktree의 가장 가까운 릴리스 태그 사용.
# shallow clone처럼 HEAD에서 도달할 수 있는 릴리스 태그가 없을 때만 0.0.0-dev로 fallback.
egasu_development_version() {
  local repo_dir="${1:?egasu_development_version requires a repository directory}"
  local tag version reachable_tags peer_tags peer

  git -C "$repo_dir" rev-parse --verify HEAD >/dev/null || return 2
  reachable_tags="$(git -C "$repo_dir" tag --merged HEAD --list 'v[0-9]*')" || return 2

  if [ -z "$reachable_tags" ]; then
    printf '%s\n' "0.0.0-dev"
    return
  fi

  tag="$(git -C "$repo_dir" describe --tags --match 'v[0-9]*' --abbrev=0)" || return 2
  peer_tags="$(git -C "$repo_dir" -c versionsort.suffix=-beta. tag --points-at "refs/tags/$tag^{commit}" --sort=-version:refname --list 'v[0-9]*')" || return 2
  while IFS= read -r peer; do
    if version="$(egasu_version_from_tag "$peer" 2>/dev/null)"; then
      printf '%s-dev\n' "$version"
      return
    fi
  done <<< "$peer_tags"
  egasu_version_from_tag "$tag"
}

# 로컬 개발 번들 버전 — 명시한 값, 전달받은 worktree의 `.env.local.dev-version`, 가장 가까운 릴리스 태그 순서.
# 명시·고정한 값도 릴리스 태그와 같은 형식 검증을 거치며, 릴리스 버전과 구분하도록 -dev 접미사 항상 유지.
egasu_local_development_version() {
  local repo_dir="${1:?egasu_local_development_version requires a repository directory}"
  local requested="${2:-}" version
  local pin="$repo_dir/.env.local.dev-version"

  if [ -z "$requested" ] && [ -f "$pin" ]; then
    requested="$(cat "$pin")"
    if [ -z "$requested" ]; then
      echo ".env.local.dev-version is empty; set a version or remove the file" >&2
      return 1
    fi
  fi
  if [ -z "$requested" ]; then
    egasu_development_version "$repo_dir"
    return
  fi

  requested="${requested#v}"
  version="$(egasu_version_from_tag "v${requested%-dev}")" || return 1
  printf '%s-dev\n' "$version"
}
