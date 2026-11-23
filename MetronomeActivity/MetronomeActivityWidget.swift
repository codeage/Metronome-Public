import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MetronomeActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MetronomeActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "metronome.fill")
                    .font(.title2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("节拍器").font(.headline)
                    PlaybackDetails(state: context.state)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(context.state.bpm)").font(.title2.monospacedDigit().bold())
                    Text("BPM").font(.caption2.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.13, green: 0.26, blue: 0.20))
            .foregroundStyle(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "metronome.fill")
                        .accessibilityLabel("节拍器")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.meter).font(.headline.monospacedDigit())
                        .accessibilityLabel("拍号 \(context.state.meter)")
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("\(context.state.bpm)")
                        .font(.title2.monospacedDigit().bold())
                        .accessibilityLabel("每分钟 \(context.state.bpm) 拍")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PlaybackDetails(state: context.state, showMeter: false)
                        .padding(.top, 4)
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "metronome.fill").accessibilityHidden(true)
                    Text("\(context.state.bpm)").monospacedDigit()
                }
                .font(.caption.weight(.semibold))
                .accessibilityLabel("\(context.state.bpm) BPM")
            } compactTrailing: {
                Text(context.state.meter).font(.caption.monospacedDigit().weight(.semibold))
                    .accessibilityLabel("拍号 \(context.state.meter)")
            } minimal: {
                Text("\(context.state.bpm)").font(.caption.monospacedDigit().weight(.semibold))
                    .accessibilityLabel("\(context.state.bpm) BPM")
            }
        }
    }
}

private struct PlaybackDetails: View {
    let state: MetronomeActivityAttributes.ContentState
    var showMeter = true

    var body: some View {
        HStack(spacing: 8) {
            if showMeter { Text(state.meter).monospacedDigit() }
            Text(state.rhythmName ?? (state.subdivision == 1 ? "无细分" : "每拍 \(state.subdivision) 等分"))
            Text(state.accent ? "有首拍重音" : "无首拍重音")
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}
