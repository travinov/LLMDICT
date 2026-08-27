import SwiftUI

struct LiveTranslateScreen: View {
    @Bindable var controller: AppController
    @State private var viewModel: LiveTranslateViewModel?

    var body: some View {
        ZStack {
            AppBackdrop().ignoresSafeArea()

            if let viewModel {
                LiveTranslateContent(viewModel: viewModel, settings: controller.settings)
            } else {
                ProgressView("Подготовка Live Translate")
                    .tint(.white)
            }
        }
        .navigationTitle("Live")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            guard viewModel == nil else { return }
            viewModel = LiveTranslateViewModel(settings: controller.settings)
        }
    }
}

private struct LiveTranslateContent: View {
    @Bindable var viewModel: LiveTranslateViewModel
    @Bindable var settings: AppSettings

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    dialogueCard
                    controls
                }
                .padding(20)
            }
            .floatingTabBarClearance()
            .onChange(of: viewModel.turns.count) { _, _ in
                guard let last = viewModel.turns.last?.id else { return }
                withAnimation(.easeInOut(duration: 0.24)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var statusCard: some View {
        GlassPanel(cornerRadius: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Operator mode", systemImage: "translate")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)

                    Spacer()

                    Text(settings.liveTranslateModel)
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(.white.opacity(0.58))
                }

                HStack(spacing: 12) {
                    languageMenuPill(
                        title: "Я",
                        value: LiveTranslateLanguage.language(for: settings.liveTranslateOwnerLanguageCode).title,
                        selection: $settings.liveTranslateOwnerLanguageCode,
                        languages: LiveTranslateLanguage.supported.filter { $0.id != "auto" }
                    )
                    languageMenuPill(
                        title: "Собеседник",
                        value: otherLanguageTitle,
                        selection: $settings.liveTranslateOtherLanguageCode,
                        languages: LiveTranslateLanguage.supported
                    )
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(Color(red: 1, green: 0.78, blue: 0.58))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dialogueCard: some View {
        GlassPanel(cornerRadius: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Диалог")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)

                    Spacer()

                    if viewModel.turns.isEmpty == false {
                        Button {
                            viewModel.clearDialogue()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.72))
                    }
                }

                if viewModel.turns.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Удерживайте кнопку нужной стороны, говорите и отпускайте для перевода.")
                            .font(.system(.body, design: .rounded, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))

                        Text("Телефон остаётся у владельца: для собеседника просто направьте микрофон в его сторону.")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.turns) { turn in
                            LiveDialogueTurnRow(
                                turn: turn,
                                onReplay: { Task { await viewModel.replay(turn) } }
                            )
                                .id(turn.id)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            LivePushToTalkButton(
                speaker: .owner,
                state: viewModel.ownerButtonState,
                routeText: ownerRouteText,
                level: viewModel.micLevel,
                actionColor: Color(red: 0.95, green: 0.42, blue: 0.22),
                onPress: { Task { await viewModel.press(.owner) } },
                onRelease: { Task { await viewModel.release(.owner) } }
            )

            LivePushToTalkButton(
                speaker: .other,
                state: viewModel.otherButtonState,
                routeText: otherRouteText,
                level: viewModel.micLevel,
                actionColor: Color(red: 0.2, green: 0.66, blue: 0.82),
                onPress: { Task { await viewModel.press(.other) } },
                onRelease: { Task { await viewModel.release(.other) } }
            )
        }
        .task {
            while Task.isCancelled == false {
                viewModel.refreshMicLevel()
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private var otherLanguageTitle: String {
        if let detected = viewModel.detectedOtherLanguageCode, settings.liveTranslateOtherLanguageCode == "auto" {
            return "Auto -> \(detected.uppercased())"
        }
        return LiveTranslateLanguage.language(for: settings.liveTranslateOtherLanguageCode).title
    }

    private var ownerRouteText: String {
        let owner = LiveTranslateLanguage.language(for: settings.liveTranslateOwnerLanguageCode).title
        let other = LiveTranslateLanguage.language(for: settings.liveTranslateOtherLanguageCode).title
        return "\(owner) -> \(other)"
    }

    private var otherRouteText: String {
        let owner = LiveTranslateLanguage.language(for: settings.liveTranslateOwnerLanguageCode).title
        return "\(otherLanguageTitle) -> \(owner)"
    }

    private func languageMenuPill(
        title: String,
        value: String,
        selection: Binding<String>,
        languages: [LiveTranslateLanguage]
    ) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(languages) { language in
                    Text(language.title).tag(language.id)
                }
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.48))
                    Text(value)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.56))
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
