---
name: release-swift
description: "Cut a release of egasu (Swift menu-bar app): pick a version, generate a categorized changelog, tag from `main`, and publish the GitHub Release with notes. Use to ship an Early Access beta or a stable release."
---

# Release Swift

`main` 이력에 포함된 `v*` 태그를 푸시하면 `.github/workflows/release.yml`이 빌드·서명·공증.
태그의 소스에 `Sources/Egasu`가 있으면 `egasu-<version>.dmg`, 이름 변경 전 태그는 `OpenUsage-<version>.dmg` 게시.
GitHub 자동 생성 릴리스 노트도 게시.
Sparkle `appcast.xml`은 `gh-pages`에 기록한 뒤 Pages로 배포.
이 스킬은 승인된 변경 내역을 `CHANGELOG.md`에 기록하고, CI 완료 후 자동 생성 릴리스 노트를 승인된 노트로 교체.

## Channels

- **Beta (Early Access):** suffixed tag like `v0.10.0-beta.1`. Marked a GitHub pre-release and added to Sparkle's `beta` channel. Only users with Early Access enabled get it; GitHub "Latest" is untouched.
- **Stable:** plain tag like `v0.10.0`. Marked non-prerelease, becomes GitHub "Latest", and ships to everyone.

표시 버전은 태그에서 추출.
예를 들어 `v0.10.0-beta.1`의 `CFBundleShortVersionString`은 `0.10.0-beta.1`.
`CFBundleVersion`은 Git 커밋 수이며 같은 커밋에서 후속 버전을 게시하면 점과 순번 추가(예: `1899.1`).
같은 버전의 재게시에는 appcast에 기록된 번호 재사용.

## Cutting a release

### 1. Choose the version

Next number in the current lane (default bump: patch). Beta builds add a `-beta.N` suffix. Confirm with the owner before proceeding.

### 2. Generate the changelog

Collect commits since the **previous release in the same channel** and categorize each:

- **Stable cut:** span from the **last stable tag** to this one (e.g. `v0.9.5...v0.10.0`), so the notes roll up the entire beta series plus any post-beta commits. Never start a stable changelog at the last beta — that would omit every beta in the lane.
- **Beta cut:** span from the previous tag (the prior beta, or the last stable if it's the first beta in a lane) to this one.

| Commit prefix | Category |
|---|---|
| `feat`, `feature`, or starts with "Add" | New Features |
| `fix` or starts with "Fix" | Bug Fixes |
| `refactor`, `enhance` | Refactor |
| `chore`, `style`, `docs`, `perf`, `test`, `ci`, `build` | Chores |
| Uncategorized | Bug Fixes |

Author attribution (required on every entry):

- With a PR number `(#123)`: `gh pr view 123 --repo kimchanhyung98/egasu --json author -q '.author.login'`.
- Without a PR number: `gh api /repos/kimchanhyung98/egasu/commits/{full_hash} -q '.author.login'`.
- If the API returns null, fall back to the git author name.

Output the changelog in a code block (template below) for review.

### 3. Owner approval

Wait for explicit approval of the changelog before changing any files. Accept edits if offered.

### 4. Record it in CHANGELOG.md

Prepend the approved section right after the `# Changelog` header and the preamble line under it. Commit on `main`:

```sh
git switch main && git pull
git add CHANGELOG.md && git commit -m "docs: changelog for v{version}"
```

### 5. Tag and push

```sh
git tag -a v{version} -m "v{version}"
git push origin main
git push origin v{version}
```

### 6. Publish the notes

CI가 `generate_release_notes: true`로 릴리스 노트 생성.
CI 완료 후 승인된 노트로 교체:

```sh
gh run watch
gh release view v{version} >/dev/null 2>&1   # confirm CI created the release
gh release edit v{version} --notes-file /tmp/notes-v{version}.md
```

Never leave a release blank.

### 7. Verify (never leave a draft)

검증할 태그의 소스로 산출물 이름 결정. 이름 변경 전 태그는 `OpenUsage-<version>.dmg` 유지.
`{feed_url}`은 해당 릴리스 번들의 `SUFeedURL`로 설정. 태그의 `script/release.sh` 기본값과 빌드 시 `FEED_URL` 재정의 여부 확인.
`v0.8.1`~`v0.14.3`의 기본 주소는 `https://openusage.chanhyung.kim/appcast.xml`, 이름 변경 후 기본 주소는 `https://egasu.chanhyung.kim/appcast.xml`.

```sh
tag="v{version}"
git rev-parse --verify "refs/tags/$tag^{commit}" >/dev/null || exit 1
app_name=OpenUsage
if git cat-file -e "refs/tags/$tag:Sources/Egasu" 2>/dev/null; then app_name=egasu; fi
asset_name="$app_name-${tag#v}.dmg"
feed_url="{feed_url}"
gh release view "$tag" --json isDraft,isPrerelease,assets,body \
  --jq '{isDraft, isPrerelease, assets:[.assets[].name], bodyLen:(.body|length)}'
git fetch origin gh-pages && git show origin/gh-pages:appcast.xml | grep -F "$asset_name"
curl -fsSL "$feed_url" | grep -F "$asset_name"
```

앱·사이트·가격표의 자동 게시 기준은 버전 태그 푸시.
수동 게시도 대상 태그 필수.
게시 workflow가 게시 커밋·태그·소스 커밋을 `pages-publication-<실행 시도 번호>` 산출물로 전달.
`main`의 `deploy-pages.yml`이 `workflow_run`으로 이 산출물을 받아 검증 후 배포.
브랜치에 버전이 있어도 실제 URL이 갱신되지 않으면 `gh run list --repo kimchanhyung98/egasu --workflow=deploy-pages.yml`로 실패 확인.
실패한 배포 실행 재시도는 같은 게시 커밋 사용.
별도 수동 재배포는 `gh workflow run deploy-pages.yml --repo kimchanhyung98/egasu --ref main -f tag=<버전 태그> -f publication_run_id=<성공한 게시 실행 ID>` 사용.
최신 `gh-pages`를 임의로 배포하지 않으며, 태그 기록이 없는 옛 산출물·만료된 산출물은 대상 태그로 새 게시 필요.
Sparkle의 실제 반영 확인은 라이브 URL 기준.

Require `isDraft=false`, `isPrerelease=true` for beta or `false` for stable, the selected `$asset_name` asset, `bodyLen>0`, and the version present in the appcast. If a draft was left behind, migrate its notes/assets onto the published release, then delete it — but only once a separate PUBLISHED release for the tag already exists:

```sh
tag="v{version}"
if [ "$(gh release view "$tag" --json isDraft --jq '.isDraft')" = "false" ]; then
  gh api repos/kimchanhyung98/egasu/releases --paginate \
    --jq '.[] | select(.draft and .tag_name=="'"$tag"'") | .id' \
    | xargs -I{} gh api -X DELETE repos/kimchanhyung98/egasu/releases/{}
else
  echo "No published release for $tag yet - publish it first; do NOT delete the draft."
fi
```

## Changelog template

Only include category sections that have entries.

~~~markdown
## v{version}

### New Features
- {message} ([#{pr}](https://github.com/kimchanhyung98/egasu/pull/{pr})) by @{author}

### Bug Fixes
- {message} ([#{pr}](https://github.com/kimchanhyung98/egasu/pull/{pr})) by @{author}

### Refactor
- {message} by @{author}

### Chores
- {message} by @{author}

---

### Changelog
**Full Changelog**: [{prev_tag}...v{version}](https://github.com/kimchanhyung98/egasu/compare/{prev_commit}...{full_hash})
~~~

`{prev_tag}` is the previous release **in the same channel**: last stable for a stable cut, last beta (or last stable for the first beta in a lane) for a beta cut.

The compare **link text** uses tag names, but the **URL** uses the two full commit SHAs the tags point at. Some fork tags exist only locally and were never pushed, so a tag-name URL would 404 for them; SHAs always resolve. A commit whose section has no earlier release to compare against uses `**Release Commit**: [{short_hash}](https://github.com/kimchanhyung98/egasu/commit/{full_hash})` instead.

## Rules

- 7-char short commit hashes; tags always prefixed with `v`.
- Stable changelogs span last-stable → this-stable (roll up the whole beta series); beta changelogs span previous-tag → this-beta.
- Never push or tag automatically — ask the owner first.
- Always publish notes to the GitHub Release — never blank.
- The release artifact version is derived from the tag. Never edit `AppInfo` or `script/build_and_run.sh` for a release version.
- The appcast is append-only: older installs and the other channel's latest build must keep working, so the workflow aborts rather than shrink it.

## 최초 설정 확인

태그 생성 전에 저장소 Actions secrets와 Pages 설정 확인.
필수 값이 없으면 태그 생성 전에 누락 항목 보고.
Secret 이름·사용처의 기준은 [릴리스 워크플로](/.github/workflows/release.yml)와 [릴리스 스크립트](/script/release.sh).

| Actions secret | 필요한 값 |
|---|---|
| `APPLE_CERTIFICATE` | 개인 키를 포함한 Developer ID Application `.p12` 인증서의 base64 값 |
| `APPLE_CERTIFICATE_PASSWORD` | 해당 `.p12` 내보내기 비밀번호 |
| `APPLE_DEVELOPER_ID_ICLOUD_PROFILE` | 운영 앱 `com.kimchanhyung98.openusage`와 `iCloud.com.kimchanhyung98.openusage` 컨테이너를 허용하는 Developer ID provisioning profile의 base64 값 |
| `SPARKLE_PRIVATE_KEY` · `SPARKLE_PUBLIC_KEY` | 기존 앱의 `SUPublicEDKey`와 일치하는 Sparkle EdDSA 키 쌍 |
| `APPLE_ID` · `APPLE_PASSWORD` · `APPLE_TEAM_ID` | 공증용 Apple ID·앱 전용 비밀번호·개발자 팀 ID |
| `POSTHOG_CLI_API_KEY` · `POSTHOG_CLI_PROJECT_ID` | 선택 항목인 dSYM 업로드용 PostHog 인증·프로젝트 값 |

`POSTHOG_CLI_API_KEY`가 없으면 경고 후 dSYM 업로드만 생략.
키가 있으면 업로드 실패가 릴리스 실행을 중단.
`GITHUB_TOKEN`은 Actions가 제공하며 별도 secret 등록 불필요.
기존 설치의 업데이트 연결을 유지하도록 `SPARKLE_PUBLIC_KEY`와 `script/release.sh`의 `FEED_URL` 기본값 변경 금지.

저장소 **Settings → Pages → Build and deployment → Source**는 **GitHub Actions** 사용.
[Pages 배포 워크플로](/.github/workflows/deploy-pages.yml)는 기본 브랜치에 유지하고 `github-pages` 환경으로 배포.
사용자 도메인은 `egasu.chanhyung.kim`이며, DNS·HTTPS와 라이브 appcast 응답을 게시 결과와 별도로 확인.
