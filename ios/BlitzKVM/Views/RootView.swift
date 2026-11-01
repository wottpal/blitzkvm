import ApprovalKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.session {
            MainTabs()
                .environment(session)
                .environmentObject(session.center)
        } else {
            KeysUnavailableView(message: model.keysError ?? "The approval keys aren't loaded.") { model.loadKeys() }
        }
    }
}

private struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(ApproverSession.self) private var session
    @EnvironmentObject private var center: ApprovalCenter

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.screen) {
            Tab("Requests", systemImage: "checkmark.shield", value: AppModel.Screen.requests) {
                RequestsView()
            }
            .badge(center.requests.filter(\.isPending).count)
            Tab("Devices", systemImage: "rectangle.connected.to.line.below", value: AppModel.Screen.devices) {
                DevicesView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppModel.Screen.settings) {
                SettingsView()
            }
        }
        .sheet(item: $model.pairingSheet) { sheet in
            PairView(invite: sheet.invite)
                .environment(model)
                .environment(session)
                .environmentObject(center)
        }
    }
}

private struct KeysUnavailableView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Keys Unavailable", systemImage: "lock.trianglebadge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry).buttonStyle(.borderedProminent)
        }
    }
}
