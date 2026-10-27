import SwiftUI

struct AppLockOverlay: View {
    @ObservedObject private var store = SessionLockStore.shared
    @State private var isAuthenticating = false

    var body: some View {
        if store.appIsLocked {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()

                VStack(spacing: 24) {
                    Image(systemName: BiometricAuth.biometryIconName)
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)

                    Text("mini-dsh is Locked")
                        .font(AppFont.sw(22, weight: .bold, category: .title))

                    Text("Tap to unlock with \(BiometricAuth.biometryDisplayName)")
                        .font(AppFont.sw(15, weight: .regular, category: .body))
                        .foregroundStyle(.secondary)

                    Button {
                        authenticate()
                    } label: {
                        Label("Unlock", systemImage: BiometricAuth.biometryIconName)
                            .font(AppFont.sw(17, weight: .semibold, category: .body))
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(.blue, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                    .disabled(isAuthenticating)
                }
            }
            .transition(.opacity)
            .onAppear {
                authenticate()
            }
        } else if store.showPrivacyScreen {
            Color(.systemBackground)
                .ignoresSafeArea()
        }
    }

    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task { @MainActor in
            let reason = AppLocalized("Unlock mini-dsh")
            let ok = await BiometricAuth.authenticate(reason: reason)
            if ok {
                withAnimation(.easeOut(duration: 0.25)) {
                    store.noteAppUnlock()
                }
            }
            isAuthenticating = false
        }
    }
}
