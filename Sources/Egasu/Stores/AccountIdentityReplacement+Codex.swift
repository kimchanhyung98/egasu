import Foundation

extension AccountIdentityReplacement {
    func hasSavedCodexReplacement(_ snapshot: AccountCredentialVault.Entry?, identity: String?) throws -> Bool {
        guard let generation = codexGeneration else {
            guard snapshot == nil || identity == previousIdentityKey || identity == replacementIdentityKey else {
                throw CodexAuthError.credentialsChanged
            }
            return identity == replacementIdentityKey
        }
        let fingerprint = snapshot.map(CodexGeneration.fingerprint)
        // 이전과 다른 워크스페이스의 대상 저장본은 앱 내부 회전 뒤에도 이어서 복구.
        if identity == replacementIdentityKey,
            fingerprint == generation.replacementFingerprint || previousIdentityKey != replacementIdentityKey
        {
            return true
        }
        guard fingerprint == generation.previousSnapshotFingerprint,
            snapshot == nil || identity == previousIdentityKey
        else { throw CodexAuthError.credentialsChanged }
        return false
    }

    /// 중단된 Codex 재로그인은 기록한 공유 홈과 변경 전·후 인증 세대에서만 복구.
    struct CodexGeneration: Codable, Equatable, Sendable {
        var sharedHome: String
        var previousSharedFingerprint: String?
        var previousSnapshotFingerprint: String?
        var replacementFingerprint: String

        init(
            sharedHome: String, previousShared: AccountCredentialVault.Entry?,
            previousSnapshot: AccountCredentialVault.Entry?, replacement: AccountCredentialVault.Entry
        ) {
            self.sharedHome = sharedHome
            previousSharedFingerprint = previousShared.map(Self.fingerprint)
            previousSnapshotFingerprint = previousSnapshot.map(Self.fingerprint)
            replacementFingerprint = Self.fingerprint(replacement)
        }

        static func fingerprint(_ entry: AccountCredentialVault.Entry) -> String {
            AccountSwitchJournal.fingerprint(entry.credential)
        }
    }
}
