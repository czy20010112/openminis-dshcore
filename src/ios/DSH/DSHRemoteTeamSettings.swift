import Foundation
import Combine

/// Settings → DSH → teammate dispatch (contract `verify/DSH-REMOTE-TEAM-CONTRACT.md` §3).
///
/// GLOBAL, not per-Session: the paired computer is a property of THIS DEVICE —
/// one pairing, one roster on that host — so a per-chat copy would let two chats
/// disagree about whether the same machine has teammates, and the policy
/// paragraph would appear in one turn and vanish in the next.
///
/// This type owns exactly one decision: may the local agent dispatch WITHOUT
/// being asked. Everything else about the feature has a single owner already —
/// `DSHRemoteTeamTools.availability` says whether the paired host can serve
/// teammates at all, and `AIChatViewModel.remoteTeamToolsEnabled` /
/// `remoteTeamPromptFragment` turn both answers into the tool catalog and one
/// prompt paragraph.
final class DSHRemoteTeamSettings: ObservableObject {

    static let shared = DSHRemoteTeamSettings()

    private enum Keys {
        static let autoDispatch = "minis.dshRemote.remoteTeamAutoDispatch"
    }

    /// Let the LOCAL agent hand work to the paired computer on its own.
    ///
    /// Default ON (contract §3). Turning it OFF removes the policy paragraph from
    /// the system prompt — the model then only dispatches when the user asks for
    /// it — but it does NOT unregister the tools: "off" means "do not do this
    /// unprompted", not "this cannot be done" (contract §3, acceptance 9).
    @Published var autoDispatch: Bool {
        didSet {
            guard autoDispatch != oldValue else { return }
            UserDefaults.standard.set(autoDispatch, forKey: Keys.autoDispatch)
        }
    }

    init() {
        let stored = UserDefaults.standard.object(forKey: Keys.autoDispatch) as? Bool
        autoDispatch = stored ?? true
    }
}