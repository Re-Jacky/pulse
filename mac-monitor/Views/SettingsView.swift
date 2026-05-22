import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Appearance")
                .font(.headline)

            Picker("Theme", selection: $themeManager.currentTheme) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button("Done") { onDone() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 260, height: 110)
    }
}
