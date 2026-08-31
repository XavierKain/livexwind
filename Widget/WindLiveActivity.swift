import ActivityKit
import WidgetKit
import SwiftUI

struct WindLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WindActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let unit = state.unit
            let color = WindPalette.color(kmh: state.averageKmh)

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("moyen").font(.system(size: 10)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(unit.format(kmh: state.averageKmh))
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(color)
                            Text(unit.shortSymbol).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("rafales").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("\(unit.format(kmh: state.gustKmh)) \(unit.shortSymbol)")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 4) {
                        WindArrow(degrees: state.directionDegrees, color: color)
                            .frame(width: 13, height: 13)
                        Text("\(state.directionLabel) \(state.directionDegrees)°")
                            .font(.caption.weight(.bold))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        WindSparkline(values: state.trendKmh, color: color)
                            .frame(height: 20)
                        Text(state.readingDate, style: .time)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                HStack(spacing: 2) {
                    WindArrow(degrees: state.directionDegrees, color: color)
                        .frame(width: 10, height: 10)
                    Text(unit.format(kmh: state.averageKmh))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
            } compactTrailing: {
                Text(unit.format(kmh: state.gustKmh))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
            } minimal: {
                Text(unit.format(kmh: state.averageKmh))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            }
            .keylineTint(color)
            .widgetURL(AppConfig.pageURL)
        }
    }

    @ViewBuilder
    private func lockScreen(_ context: ActivityViewContext<WindActivityAttributes>) -> some View {
        let state = context.state
        let unit = state.unit
        let color = WindPalette.color(kmh: state.averageKmh)

        VStack(spacing: 6) {
            HStack {
                Label(context.attributes.baliseName, systemImage: "wind")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(state.readingDate, style: .time)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 14) {
                VStack(spacing: 0) {
                    WindArrow(degrees: state.directionDegrees, color: color)
                        .frame(width: 26, height: 26)
                    Text(state.directionLabel).font(.caption2.weight(.bold)).foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(unit.format(kmh: state.averageKmh))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(color)
                        Text(unit.symbol).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("rafales \(unit.format(kmh: state.gustKmh)) · mini \(unit.format(kmh: state.minKmh))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                WindSparkline(values: state.trendKmh, color: color)
                    .frame(width: 74, height: 34)
            }
        }
        .padding(14)
    }
}
