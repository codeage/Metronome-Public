// ActivityKit SDK headers do not declare Activity as Sendable.
@preconcurrency import ActivityKit
import OSLog
import UIKit

@MainActor
final class MetronomeLiveActivity {
    private typealias PlaybackActivity = Activity<MetronomeActivityAttributes>
    private let logger = Logger(subsystem: "app.music.metronome", category: "LiveActivity")
    private var desired: MetronomeActivityAttributes.ContentState?
    private var needsUpdate = false
    private var worker: Task<Void, Never>?

    func sync(playing: Bool, settings: BeatSettings) {
        desired = playing ? .init(bpm: settings.bpm, beats: settings.beats, unit: settings.unit,
                                  subdivision: settings.subdivision,
                                  rhythmName: settings.rhythm.rawValue > 3 ? settings.rhythm.title : nil,
                                  accent: settings.accent) : nil
        needsUpdate = true
        guard worker == nil else { return }
        worker = Task { await reconcile() }
    }

    private func reconcile() async {
        defer { worker = nil }
        while needsUpdate {
            needsUpdate = false
            let activities = PlaybackActivity.activities
            guard let desired = desired else {
                for activity in activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                continue
            }

            let content = ActivityContent(state: desired, staleDate: nil)
            let activity = activities.first { $0.activityState == .active || $0.activityState == .stale }
            if let activity = activity {
                if activity.content.state != desired {
                    await activity.update(content)
                }
                for duplicate in activities where duplicate.id != activity.id {
                    await duplicate.end(nil, dismissalPolicy: .immediate)
                }
            } else if ActivityAuthorizationInfo().areActivitiesEnabled,
                      UIApplication.shared.applicationState == .active {
                do {
                    _ = try PlaybackActivity.request(attributes: MetronomeActivityAttributes(),
                                                     content: content, pushType: nil)
                } catch {
                    logger.error("Unable to start metronome Live Activity: \(error.localizedDescription)")
                }
            }
        }
    }
}
