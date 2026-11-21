"""Sparkle 게시 피드에 기록된 빌드 번호 선택과 새 피드 검증."""

import json
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from typing import NamedTuple


NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


class Item(NamedTuple):
    build: str
    version: str
    channel: str
    url: str
    signature: str


def read_feed(source):
    channel = ET.parse(source).find("channel")
    if channel is None:
        raise SystemExit("Appcast has no channel")
    items = []
    for entry in channel.findall("item"):
        enclosure = entry.find("enclosure")
        if enclosure is None:
            raise SystemExit("Appcast item has no enclosure")
        build = entry.findtext(NS + "version") or enclosure.get(NS + "version")
        version = entry.findtext(NS + "shortVersionString") or enclosure.get(NS + "shortVersionString")
        if not build or not version:
            raise SystemExit("Appcast item has no build or release version")
        items.append(Item(build, version, (entry.findtext(NS + "channel") or "stable").strip(),
                          enclosure.get("url"), enclosure.get(NS + "edSignature")))
    return items


def parts(build):
    values = build.split(".")
    if len(values) > 2 or not all(v.isascii() and v.isdecimal() and not v.startswith("0") for v in values):
        raise SystemExit(f"Invalid appcast build number: {build}")
    return tuple(map(int, values))


def release_order(version):
    core, _, beta = version.partition("-beta.")
    return tuple(map(int, core.split("."))), not beta, int(beta or 0)


def published_release(previous, version):
    # 같은 표시 버전으로 여러 빌드를 게시한 옛 피드는 Sparkle이 선택하는 최신 번호 재사용.
    return max((item for item in previous if item.version == version),
               key=lambda item: parts(item.build), default=None)


def check_public_peers(previous, version, tags, release_pages):
    if published_release(previous, version):
        return
    missing = set(tags) - {f"v{version}"} - {f"v{row.version}" for row in previous}
    for page in release_pages:
        for release in page:
            tag = release["tag_name"]
            if tag not in missing or release["draft"]:
                continue
            dmg_names = {f"{name}-{tag[1:]}.dmg" for name in ("egasu", "OpenUsage")}
            if any(asset["state"] == "uploaded" and asset["name"] in dmg_names for asset in release["assets"]):
                raise SystemExit(f"Public DMG for {tag} is missing from the appcast. Rerun {tag} first.")


def select_build(previous, count, version):
    published = published_release(previous, version)
    if published:
        return published.build

    # 게시가 끝난 번호만 예약. 같은 커밋에 나중에 태그가 추가돼도 기존 번호 유지.
    suffixes = []
    for item in previous:
        build = parts(item.build)
        if build[0] == count:
            if release_order(item.version) > release_order(version):
                raise SystemExit("Cannot publish an older version after a newer one on this build")
            suffixes.append(build[1] if len(build) == 2 else 0)
    return f"{count}.{max(suffixes) + 1}" if suffixes else str(count)


def verify(previous, current, build, version, channel, url):
    """재게시 대상의 서명·URL은 교체 가능. 나머지 피드 항목은 모두 보존."""
    matching = [row for row in current if row.build == build]
    if len(matching) != 1 or matching[0][:4] != (build, version, channel, url) or not (matching[0].signature or "").strip():
        raise SystemExit("New appcast build, version, channel, download URL or signature mismatch")
    published = published_release(previous, version)
    if published and (published.build != build or published.channel != channel):
        raise SystemExit("Published appcast identity changed on retry")
    retained = Counter(previous)
    if published:
        retained.subtract([published])
    if +retained != Counter(current) - Counter(matching):
        raise SystemExit("Other appcast items lost, added or changed")
    # 베타 채널은 정식판도 받으므로 이미 공개된 정식판보다 낮은 빌드는 게시 불가.
    if not published and any(parts(row.build) >= parts(build) for row in previous
                            if row.channel == channel or row.channel == "stable"):
        raise SystemExit("New appcast build must advance its channel")
    return matching[0].signature


if __name__ == "__main__":
    command, source, *args = sys.argv[1:]
    previous = read_feed(sys.stdin.buffer if source == "-" else source)
    if command == "build":
        count, version = args
        print(select_build(previous, int(count), version))
    elif command == "check-peers":
        version, tag_path, releases_path = args
        with open(tag_path) as tags, open(releases_path) as releases:
            check_public_peers(previous, version, tags.read().splitlines(), json.load(releases))
    elif command == "verify":
        current, build, version, channel, url = args
        print(verify(previous, read_feed(current), build, version, channel, url))
    else:
        raise SystemExit(f"Unknown appcast command: {command}")
