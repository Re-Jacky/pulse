import SwiftUI

struct MetricRowView: View {
    let label: String
    let value: String
    let subtext: String
    let percent: Double
    let fillColors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 10, weight: .regular))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundColor(.appSecondaryText)
                    .frame(width: 36, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.appTrackBackground)
                            .frame(height: 4)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                LinearGradient(
                                    colors: fillColors,
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * CGFloat(min(1.0, max(0.0, percent / 100.0))), height: 4)
                            .animation(.easeInOut(duration: 0.4), value: percent)
                    }
                }
                .frame(height: 4)

                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(fillColors.first ?? .white)
                    .frame(width: 80, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Text(subtext)
                .font(.system(size: 10))
                .foregroundColor(.appTertiaryText)
                .padding(.leading, 44)
        }
    }
}
