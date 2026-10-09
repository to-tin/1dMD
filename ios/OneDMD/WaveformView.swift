import SwiftUI
import QuartzCore

struct WaveformView: View {
    var samples: [AudioSample]
    var velocity: CGFloat = 110
    var barWidth: CGFloat = 2.5
    var barColor: Color = .primary
    var fadeWidth: CGFloat = 32

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    _ = timeline.date
                    let now = CACurrentMediaTime()
                    let centerY = size.height / 2

                    for s in samples {
                        let age = CGFloat(now - s.time)
                        let x = size.width - age * velocity
                        if x < -barWidth || x > size.width { continue }
                        let v = CGFloat(s.level)
                        let h = max(2, v * size.height * 0.95)
                        let y = centerY - h / 2
                        let rect = CGRect(x: x, y: y, width: barWidth, height: h)
                        let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                        ctx.fill(path, with: .color(barColor.opacity(0.9)))
                    }
                }
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: min(0.25, fadeWidth / geo.size.width)),
                        .init(color: .black, location: 1 - min(0.25, fadeWidth / geo.size.width)),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }
}

#Preview {
    struct Demo: View {
        @State private var samples: [AudioSample] = []
        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0/30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let _ = {
                    let a = 0.3 * sin(t * 4)
                    let b = 0.2 * sin(t * 11)
                    let level = Float(0.3 + a + b)
                    samples.append(AudioSample(time: CACurrentMediaTime(), level: max(0.05, min(1, level))))
                    if samples.count > 400 { samples.removeFirst(samples.count - 400) }
                }()
                WaveformView(samples: samples)
                    .frame(height: 44)
                    .padding()
            }
        }
    }
    return Demo()
}
