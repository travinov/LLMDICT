import Observation
import SwiftUI

struct RecorderCompanionScreen: View {
    @Bindable var controller: AppController

    private var companion: RecorderCompanionService { controller.companion }

    var body: some View {
        ZStack {
            AppBackdrop().ignoresSafeArea()

            List {
                Section("Соединение") {
                    LabeledContent("Устройство", value: RecorderCompanionService.deviceName)
                    LabeledContent("Статус", value: companion.connectionState.title)

                    if companion.connectionState == .connected {
                        Button("Отключить", role: .destructive) {
                            companion.disconnect()
                        }
                    } else {
                        Button {
                            companion.startScanning()
                        } label: {
                            Label(
                                companion.connectionState == .scanning ? "Идёт поиск…" : "Найти и подключить",
                                systemImage: "antenna.radiowaves.left.and.right"
                            )
                        }
                        .disabled(companion.connectionState == .scanning || companion.connectionState == .connecting)
                        .accessibilityIdentifier("recorder-connect-button")
                    }
                }

                if let info = companion.deviceInfo {
                    Section("На устройстве") {
                        LabeledContent("Состояние", value: info.stateTitle)
                        LabeledContent("Чувствительность", value: "\(info.microphoneGain)")
                        LabeledContent("Запись", value: recordingSize(info.wavSize))

                        Button {
                            Task { await controller.syncLatestCompanionRecording() }
                        } label: {
                            Label("Синхронизировать запись", systemImage: "arrow.down.circle.fill")
                        }
                        .disabled(info.hasRecording == false || companion.isTransferring)
                        .accessibilityIdentifier("recorder-sync-button")

                        if companion.isTransferring {
                            ProgressView(value: companion.transferProgress) {
                                Text("Передача записи")
                            } currentValueLabel: {
                                Text(companion.transferProgress, format: .percent.precision(.fractionLength(0)))
                            }
                        }
                    }
                }

                if companion.lastImportedAt != nil {
                    Section {
                        Label("Запись добавлена в историю", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if let error = companion.lastError {
                    Section("Ошибка") {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Text("Завершите запись второй кнопкой на диктофоне, затем подключитесь и перенесите WAV. Во время передачи новая запись недоступна.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Диктофон")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func recordingSize(_ bytes: UInt32) -> String {
        guard bytes > 0 else { return "Нет завершённой записи" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
