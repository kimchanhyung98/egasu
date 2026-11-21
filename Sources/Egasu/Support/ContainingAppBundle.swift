import Foundation

/// 실행 파일이 속한 .app 탐색 — PATH의 심볼릭 링크로 호출한 보조 실행 파일도 지원.
public enum ContainingAppBundle {
    public static func url(for executableURL: URL) -> URL? {
        var candidate = executableURL.resolvingSymlinksInPath().standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}
