import SwiftUI

struct BodyPartIcon: View {
    let bodyPart: String
    var size: CGFloat = 52

    var body: some View {
        Image(systemName: Self.symbol(for: bodyPart))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: size, height: size)
            .background(Theme.cardInner, in: .rect(cornerRadius: size * 0.23))
            .accessibilityHidden(true)
    }

    static func symbol(for bodyPart: String) -> String {
        switch bodyPart {
        case "chest": "figure.strengthtraining.traditional"
        case "back": "figure.rower"
        case "shoulders": "figure.arms.open"
        case "upper arms": "dumbbell"
        case "lower arms": "hand.raised"
        case "upper legs": "figure.step.training"
        case "lower legs": "figure.walk"
        case "waist": "figure.core.training"
        case "cardio": "heart"
        case "neck": "person.bust"
        default: "figure.mixed.cardio"
        }
    }
}
