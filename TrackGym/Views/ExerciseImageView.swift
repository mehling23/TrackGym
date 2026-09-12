import SwiftUI

struct ExerciseImageView: View {
    let exercise: Exercise
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url = validatedRemoteImageURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholderIcon
                }
            } else {
                placeholderIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private var validatedRemoteImageURL: URL? {
        guard let urlString = exercise.imageURL,
              let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private var placeholderIcon: some View {
        ZStack {
            Color(.systemGray6)
            Image(systemName: exercise.muscleGroup.icon)
                .foregroundStyle(.secondary)
        }
    }
}
