import Foundation
import Observation
import PrismCore
import PrismPlayer
import SwiftUI

/// Shared across pages so starting real playback always releases the preview stream first.
@Observable
final class HeroPreviewSession {
    struct Entry {
        let owner: UUID
        let titleID: TitleID
        let player: HeroPreviewPlayer
    }

    private(set) var entry: Entry?

    func start(_ item: PlaybackItem, titleID: TitleID, owner: UUID) {
        stop()
        let player = HeroPreviewPlayer(item: item)
        player.onFinished = { [weak self, weak player] in
            guard let self, let player, self.entry?.player === player else { return }
            withAnimation(.easeInOut(duration: 0.5)) { self.entry = nil }
        }
        entry = Entry(owner: owner, titleID: titleID, player: player)
        player.start()
    }

    func stop(owner: UUID? = nil) {
        guard let entry, owner == nil || entry.owner == owner else { return }
        entry.player.stop()
        self.entry = nil
    }
}
