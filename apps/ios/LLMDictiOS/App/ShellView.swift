import Combine
import Observation
import SwiftUI
import UIKit

struct RootTabView: View {
    @Bindable var controller: AppController
    @State private var isKeyboardVisible = false

    var body: some View {
        TabView {
            NavigationStack {
                RecordScreen(controller: controller)
            }
            .tabItem {
                Label("Запись", systemImage: "waveform.badge.mic")
            }

            NavigationStack {
                HistoryScreen(controller: controller)
            }
            .tabItem {
                Label("История", systemImage: "waveform.path.ecg.rectangle")
            }

            NavigationStack {
                LiveTranscribeScreen(controller: controller)
            }
            .tabItem {
                Label("Live", systemImage: "captions.bubble")
            }

            NavigationStack {
                SettingsScreen(controller: controller)
            }
            .tabItem {
                Label("Настройки", systemImage: "slider.horizontal.3")
            }
        }
        .tint(Color(red: 0.94, green: 0.44, blue: 0.25))
        .background(AppBackdrop().ignoresSafeArea())
        .toolbar(isKeyboardVisible ? .hidden : .visible, for: .tabBar)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
    }
}
