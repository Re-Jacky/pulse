import SwiftUI

struct SearchableSelectorOption: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
}

struct SearchableSelectorView: View {
    let label: String
    let placeholder: String
    let selectedTitle: String
    let options: [SearchableSelectorOption]
    let onSelect: (SearchableSelectorOption) -> Void

    @State private var isPresented = false
    @State private var query = ""

    private var filteredOptions: [SearchableSelectorOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return options }

        return options.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) ||
            $0.subtitle.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appSecondaryText)

            Button {
                query = ""
                isPresented = true
            } label: {
                HStack(spacing: 8) {
                    Text(selectedTitle.isEmpty ? placeholder : selectedTitle)
                        .foregroundColor(selectedTitle.isEmpty ? .appTertiaryText : .appPrimaryText)
                        .lineLimit(1)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.appSecondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.appFieldBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.appFieldBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(spacing: 10) {
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder)

                    List(filteredOptions) { option in
                        Button {
                            onSelect(option)
                            isPresented = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .foregroundColor(.appPrimaryText)

                                Text(option.subtitle)
                                    .font(.system(size: 11))
                                    .foregroundColor(.appSecondaryText)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .buttonStyle(.plain)
                    }
                    .frame(width: 360, height: 220)
                }
                .padding(12)
            }
        }
    }
}
