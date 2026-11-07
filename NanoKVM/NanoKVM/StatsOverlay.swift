import SwiftUI
import Charts

/// Floating live chart of the last minute of bitrate and frame rate.
struct StatsOverlay: View {
    let stream: VideoStream
    @AppStorage("showStats") private var show = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button { show.toggle() } label: {
                Image(systemName: "chart.xyaxis.line")
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stream statistics")
            if show { panel }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var panel: some View {
        let h = stream.history
        let last = h.last
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(Int(stream.videoSize.width))×\(Int(stream.videoSize.height)) · \(stream.codec.rawValue.uppercased())")
                .font(.caption.bold())
            chart(h, title: "Bitrate", value: last.map { formatBitrate($0.kbps) } ?? "–", color: .red) { $0.kbps }
            chart(h, title: "FPS", value: last.map { String(format: "%.0f", $0.fps) } ?? "–", color: .green) { $0.fps }
            Text("avg \(formatBitrate(h.averageKbps)) · peak \(formatBitrate(h.peakKbps)) · keyframes \(stream.meter.keyframes)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 260)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func chart(_ h: [StatSample], title: String, value: String, color: Color,
                       y: @escaping (StatSample) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.caption); Spacer(); Text(value).font(.caption.monospacedDigit().bold()) }
            Chart(h) { LineMark(x: .value("t", $0.id), y: .value(title, y($0))).foregroundStyle(color) }
                .chartXAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: true))
                .frame(height: 50)
        }
    }
}
