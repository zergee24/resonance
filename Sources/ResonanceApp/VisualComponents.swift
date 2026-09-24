import SwiftUI

enum Palette {
    static let accent = Color(red: 0.42, green: 0.88, blue: 0.75)
    static let base = Color(red: 0.064, green: 0.075, blue: 0.085)
    static let panel = Color(red: 0.096, green: 0.11, blue: 0.123)
    static let muted = Color(red: 0.58, green: 0.64, blue: 0.67)
}

struct PlotLine: Identifiable {
    var id: String
    var values: [(Double, Double)]
    var color: Color
}

struct FrequencyPlot: View {
    var lines: [PlotLine]
    var minDB: Double = -30
    var maxDB: Double = 30
    var maxFrequency: Double = 50_000

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 38, right: CGFloat = 12, top: CGFloat = 12, bottom: CGFloat = 25
            let width = size.width - left - right, height = size.height - top - bottom
            func x(_ hz: Double) -> CGFloat { left + CGFloat((log10(max(20, hz)) - log10(20)) / (log10(maxFrequency) - log10(20))) * width }
            func y(_ db: Double) -> CGFloat { top + CGFloat((maxDB - db) / (maxDB - minDB)) * height }
            for hz in [20.0, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000, 40_000] where hz <= maxFrequency {
                var p = Path(); p.move(to: CGPoint(x: x(hz), y: top)); p.addLine(to: CGPoint(x: x(hz), y: top + height))
                context.stroke(p, with: .color(.white.opacity(hz == 20_000 ? 0.2 : 0.06)), style: StrokeStyle(lineWidth: 1, dash: hz == 20_000 ? [3, 3] : []))
                context.draw(Text(frequencyLabel(hz)).font(.system(size: 9, design: .monospaced)).foregroundColor(Palette.muted), at: CGPoint(x: x(hz), y: top + height + 13))
            }
            for db in stride(from: minDB, through: maxDB, by: (maxDB - minDB) / 4) {
                var p = Path(); p.move(to: CGPoint(x: left, y: y(db))); p.addLine(to: CGPoint(x: left + width, y: y(db)))
                context.stroke(p, with: .color(.white.opacity(db == 0 ? 0.16 : 0.06)), lineWidth: 1)
                context.draw(Text(String(format: "%g", db)).font(.system(size: 9, design: .monospaced)).foregroundColor(Palette.muted), at: CGPoint(x: 15, y: y(db)))
            }
            context.clip(to: Path(CGRect(x: left, y: top, width: width, height: height)))
            for line in lines {
                var p = Path(); var started = false
                for (hz, db) in line.values where hz >= 20 && hz <= maxFrequency && hz.isFinite && db.isFinite {
                    let point = CGPoint(x: x(hz), y: y(db))
                    if started { p.addLine(to: point) } else { p.move(to: point); started = true }
                }
                context.stroke(p, with: .color(line.color), lineWidth: 1.6)
            }
        }
        .accessibilityLabel("对数频率图，20 Hz 至 \(frequencyLabel(maxFrequency)) Hz")
    }
}

struct EmptyPanel: View {
    var icon: String
    var title: String
    var detail: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 35, weight: .ultraLight)).foregroundStyle(Palette.accent)
            Text(title).font(.title3.weight(.medium))
            Text(detail).font(.callout).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 430)
        }.frame(maxWidth: .infinity, minHeight: 240).padding(24)
    }
}

struct TinyBadge: View {
    var text: String
    var color: Color = Palette.muted
    var body: some View { Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 4).background(color.opacity(0.09), in: Capsule()) }
}

struct SectionCaption: View {
    var title: String
    var trailing: String = ""
    var body: some View { HStack { Text(title).font(.system(size: 12, weight: .semibold)); Spacer(); Text(trailing).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted) }.padding(.bottom, 8) }
}
