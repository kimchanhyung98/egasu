import Foundation

/// 구형 Tauri 자동 실행 항목(`~/Library/LaunchAgents/OpenUsage.plist`) 제거 — 로그인 시 중복 실행 방지.
/// 실행 경로가 현재 앱 번들 내부일 때만 삭제 — 다른 경로는 보존하고 로그 기록.
/// 파일만 삭제 — `launchctl bootout`은 해당 항목이 실행한 현재 프로세스까지 종료할 위험.
enum LegacyLaunchAgentCleanup {
    /// 삭제 판정에 필요한 plist 정보 — `Program`이 문자열로 읽히지 않으면 `ProgramArguments`의 첫 요소 사용.
    struct Agent: Equatable {
        var programPath: String?
    }

    /// `tauri-plugin-autostart`가 제품 이름으로 생성한 plist 경로.
    static var defaultAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/OpenUsage.plist")
    }

    /// 앱 시작 시 1회 실행 — 매개변수는 테스트 주입용.
    static func removeLeftoverAgent(
        agentURL: URL = defaultAgentURL,
        bundlePath: String = Bundle.main.bundlePath
    ) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: agentURL.path) else { return }

        let agent: Agent
        do {
            agent = try parse(plistData: Data(contentsOf: agentURL))
        } catch {
            AppLog.error(.lifecycle, "found \(agentURL.path) but couldn't read it: \(error.localizedDescription)")
            return
        }

        guard shouldRemove(programPath: agent.programPath, bundlePath: bundlePath) else {
            AppLog.info(.lifecycle, "leaving \(agentURL.path) alone — its program (\(agent.programPath ?? "unset")) is outside this app bundle")
            return
        }

        do {
            try fileManager.removeItem(at: agentURL)
            AppLog.info(.lifecycle, "removed legacy Tauri autostart agent \(agentURL.path) — it pointed into this app bundle and double-launched the app at login (#874)")
        } catch {
            AppLog.error(.lifecycle, "couldn't delete legacy autostart agent \(agentURL.path): \(error.localizedDescription) — will retry next launch")
        }
    }

    /// 실행 경로가 현재 `.app` 번들 내부일 때만 삭제 허용.
    /// `.app` 접미사를 정확히 확인한 뒤 내부 경로는 대소문자 구분 없이 비교.
    static func shouldRemove(programPath: String?, bundlePath: String) -> Bool {
        guard let programPath else { return false }
        let bundle = (bundlePath as NSString).standardizingPath
        guard bundle.hasSuffix(".app") else { return false }
        let program = (programPath as NSString).standardizingPath
        return program.lowercased().hasPrefix(bundle.lowercased() + "/")
    }

    /// launchd plist의 실행 파일 경로 추출. 파싱 실패는 오류. 경로를 읽을 수 없으면 nil로 두어 파일 보존.
    static func parse(plistData: Data) throws -> Agent {
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil)
        guard let dict = plist as? [String: Any] else {
            return Agent(programPath: nil)
        }
        let program = dict["Program"] as? String
            ?? (dict["ProgramArguments"] as? [String])?.first
        return Agent(programPath: program)
    }
}
