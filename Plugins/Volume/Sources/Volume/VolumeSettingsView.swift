import SwiftUI

/// The plugin's page in Settings: what it does with the keys and whether it may.
struct VolumeSettingsView: View {
    let isTrusted: Bool
    let requestAccessibility: () -> Void

    var body: some View {
        LabeledContent {
            if !isTrusted {
                Button("권한 열기", action: requestAccessibility)
            }
        } label: {
            Text("볼륨·음소거 키")
            Text(isTrusted ? "노치에서 처리해요." : "손쉬운 사용 권한을 켜기 전까지 키가 원래대로 동작해요.")
        }
    }
}
