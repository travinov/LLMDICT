import Observation
import SwiftData
import SwiftUI

struct SettingsScreen: View {
    private enum Field: Hashable {
        case sberAuthKey
        case gigaChatAuthKey
        case openAIAPIKey
        case openAIBaseURL
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\PromptItem.title)]) private var prompts: [PromptItem]

    @Bindable var controller: AppController
    @State private var editingPrompt: PromptItem?
    @State private var creatingPrompt = false
    @FocusState private var focusedField: Field?

    var body: some View {
        ZStack {
            AppBackdrop().ignoresSafeArea()

            List {
                Section("Диктофон") {
                    NavigationLink {
                        RecorderCompanionScreen(controller: controller)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "waveform.badge.mic")
                                .foregroundStyle(Color(red: 0.94, green: 0.42, blue: 0.25))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("LLM Dict Recorder")
                                Text(controller.companion.connectionState.title)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("recorder-companion-link")
                }

                Section("Распознавание речи") {
                    Picker("Модель распознавания", selection: $controller.settings.provider) {
                        ForEach(TranscriptionProvider.productionCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if controller.settings.provider.normalized != .sberSalute {
                    Section("Оформление текста") {
                        Picker("Модель", selection: $controller.settings.processingModelProfile) {
                            ForEach(ProcessingModelProfile.allCases) { profile in
                                Text(profile.title).tag(profile)
                            }
                        }
                        .pickerStyle(.menu)

                        Text("Модель применяется только к оформлению уже распознанного текста и не запускает распознавание речи заново.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(controller.settings.provider == .sberSalute ? "Ключи Sber" : "OpenAI") {
                    if controller.settings.provider == .sberSalute {
                        SecureField("SaluteSpeech Authorization Key (Base64)", text: $controller.settings.sberAuthKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .sberAuthKey)
                        SecureField("GigaChat Authorization Key (Base64)", text: $controller.settings.gigaChatAuthKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .gigaChatAuthKey)
                        Text("Сюда нужен именно Authorization Key из developers.sber.ru. Не вставляйте access token и не добавляйте префиксы Basic/Bearer.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        SecureField("API Key", text: $controller.settings.openAIAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .openAIAPIKey)
                        TextField("Base URL", text: $controller.settings.openAIBaseURL, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .openAIBaseURL)
                    }

                    if let credentialStorageError = controller.settings.credentialStorageError {
                        Text("Не удалось сохранить ключ в Keychain: \(credentialStorageError)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.red.opacity(0.85))
                    }

                    Text("Ключи хранятся в Keychain этого устройства.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Запись") {
                    Toggle("Улучшение звука", isOn: $controller.settings.audioEnhancementEnabled)
                    Text("При включении используется голосовой режим аудиосессии iOS, что ближе к телефонной обработке речи и обычно лучше ведёт себя в шумной среде.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Обработка записей") {
                    Toggle("Использовать обработанный файл", isOn: $controller.settings.useEnhancedAudio)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Сила очистки")
                            Spacer()
                            Text(controller.settings.audioDenoiseStrength, format: .percent.precision(.fractionLength(0)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $controller.settings.audioDenoiseStrength, in: 0...1, step: 0.05)
                            .accessibilityIdentifier("audio-denoise-strength-slider")
                    }

                    Text("Очистка применяется на iPhone перед компрессором и нормализацией. Изменение силы повлияет на новые записи; существующую можно обработать заново. Оригинал всегда сохраняется.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Помощь") {
                    NavigationLink {
                        GuideScreen()
                    } label: {
                        Label("FAQ и инструкции", systemImage: "questionmark.bubble")
                    }
                }

                Section("Системные промпты") {
                    ForEach(prompts) { prompt in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Button {
                                    try? controller.setSelectedPrompt(prompt)
                                } label: {
                                    Image(systemName: prompt.isSelected ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(prompt.isSelected ? Color(red: 0.94, green: 0.42, blue: 0.25) : .secondary)
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(prompt.title)
                                    Text(prompt.content)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }

                            HStack {
                                Button("Редактировать") {
                                    editingPrompt = prompt
                                }
                                Spacer()
                                Button("Удалить", role: .destructive) {
                                    try? controller.deletePrompt(prompt)
                                }
                            }
                            .font(.subheadline.weight(.medium))
                        }
                        .padding(.vertical, 4)
                    }

                    Button {
                        creatingPrompt = true
                    } label: {
                        Label("Добавить промпт", systemImage: "plus.circle.fill")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .floatingTabBarClearance()
        }
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(item: $editingPrompt) { prompt in
            PromptEditorSheet(
                title: prompt.title,
                content: prompt.content,
                onSave: { title, content in
                    try? controller.savePrompt(editing: prompt, title: title, content: content)
                    editingPrompt = nil
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $creatingPrompt) {
            PromptEditorSheet(
                title: "",
                content: "",
                onSave: { title, content in
                    try? controller.savePrompt(editing: nil, title: title, content: content)
                    creatingPrompt = false
                }
            )
            .presentationDetents([.medium, .large])
        }
    }
}

private struct PromptEditorSheet: View {
    private enum Field: Hashable {
        case title
        case content
    }

    @Environment(\.dismiss) private var dismiss
    @State var title: String
    @State var content: String
    let onSave: (String, String) -> Void
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section("Название") {
                    TextField("Например, Протокол встречи", text: $title)
                        .focused($focusedField, equals: .title)
                }

                Section("Содержание") {
                    TextField("System / User prompt", text: $content, axis: .vertical)
                        .lineLimit(8 ... 16)
                        .textInputAutocapitalization(.sentences)
                        .focused($focusedField, equals: .content)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                focusedField = nil
            }
            .navigationTitle("Промпт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        onSave(title.trimmingCharacters(in: .whitespacesAndNewlines), content.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
