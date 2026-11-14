import SwiftUI

struct TranslationRangeSheetView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPromptEditor: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Header Card
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [Color.orange, Color.red.opacity(0.85)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .frame(width: 48, height: 48)
                            Image(systemName: "sparkles")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Dịch & Biên tập lại truyện")
                                .font(.headline)
                            Text("Thay thế nội dung convert khó đọc và ghi đè trực tiếp vào file chương.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // Range Picker Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Chọn phạm vi chương cần dịch")
                            .font(.subheadline.weight(.bold))

                        HStack(spacing: 12) {
                            Button {
                                let idx = max(0, viewModel.currentChapterIndex)
                                viewModel.translateFromChapterIndex = idx
                                viewModel.translateToChapterIndex = idx
                            } label: {
                                Text("Chỉ chương này")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.accentColor.opacity(0.14))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                            }

                            Button {
                                let idx = max(0, viewModel.currentChapterIndex)
                                viewModel.translateFromChapterIndex = idx
                                viewModel.translateToChapterIndex = min(viewModel.chapters.count - 1, idx + 4)
                            } label: {
                                Text("5 chương tiếp")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.accentColor.opacity(0.14))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                            }

                            Button {
                                let idx = max(0, viewModel.currentChapterIndex)
                                viewModel.translateFromChapterIndex = idx
                                viewModel.translateToChapterIndex = min(viewModel.chapters.count - 1, idx + 9)
                            } label: {
                                Text("10 chương tiếp")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.accentColor.opacity(0.14))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                            }
                        }

                        if !viewModel.chapters.isEmpty {
                            VStack(spacing: 10) {
                                HStack {
                                    Text("Từ chương:")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Picker("Từ chương", selection: $viewModel.translateFromChapterIndex) {
                                        ForEach(Array(viewModel.chapters.enumerated()), id: \.offset) { idx, chap in
                                            Text("\(idx + 1). \(chap.cleanChapterName)").tag(idx)
                                        }
                                    }
                                    .labelsHidden()
                                }

                                Divider()

                                HStack {
                                    Text("Đến chương:")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Picker("Đến chương", selection: $viewModel.translateToChapterIndex) {
                                        ForEach(Array(viewModel.chapters.enumerated()), id: \.offset) { idx, chap in
                                            Text("\(idx + 1). \(chap.cleanChapterName)").tag(idx)
                                        }
                                    }
                                    .labelsHidden()
                                }
                            }
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

                        let totalSelected = abs(viewModel.translateToChapterIndex - viewModel.translateFromChapterIndex) + 1
                        Text("Tổng cộng: **\(totalSelected) chương** sẽ được biên tập lại và ghi đè file gốc.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Model & API Key Quick Config
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Model AI & Khóa kết nối")
                            .font(.subheadline.weight(.bold))

                        Picker("Chọn Model", selection: $viewModel.selectedGeminiModel) {
                            ForEach(GeminiModelChoice.allCases) { model in
                                Text(model.shortBadge).tag(model)
                            }
                        }
                        .pickerStyle(.segmented)

                        Toggle("Tự chuyển sang 3.1 Flash Lite nếu hết quota", isOn: $viewModel.autoSwitchTo31OnQuota)
                            .font(.caption)

                        if viewModel.geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Nhập nhanh Gemini API Key:")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.red)
                                SecureField("Dán Gemini API Key (AIzaSy...)", text: $viewModel.geminiApiKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(10)
                                    .background(Color(.tertiarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // Prompt Customization Accordion
                    DisclosureGroup("Xem / Chỉnh sửa câu lệnh dịch (Prompt)", isExpanded: $showPromptEditor) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: $viewModel.translationPrompt)
                                .frame(minHeight: 130)
                                .font(.caption)
                                .padding(6)
                                .background(Color(.systemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                            HStack {
                                Spacer()
                                Button("Khôi phục câu lệnh mặc định") {
                                    viewModel.resetPromptToDefault()
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // Progress / Status Section
                    if viewModel.isTranslatingBatch || !viewModel.translationStatusNote.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            if viewModel.isTranslatingBatch {
                                ProgressView(
                                    value: Double(viewModel.translationProgressCount),
                                    total: Double(max(viewModel.translationTotalCount, 1))
                                )
                                .tint(.orange)
                            }

                            Text(viewModel.translationStatusNote)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(viewModel.translationStatusNote.hasPrefix("❌") ? .red : .primary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    // Action Buttons
                    VStack(spacing: 10) {
                        if viewModel.isTranslatingBatch {
                            Button(role: .destructive) {
                                viewModel.cancelBatchTranslation()
                            } label: {
                                HStack {
                                    ProgressView()
                                        .tint(.white)
                                        .padding(.trailing, 6)
                                    Text("Dừng dịch")
                                        .fontWeight(.bold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.red)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        } else {
                            Button {
                                viewModel.startBatchTranslation()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "wand.and.stars")
                                    Text("Bắt đầu Dịch & Ghi đè File")
                                        .fontWeight(.bold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(
                                    LinearGradient(
                                        colors: [Color.orange, Color(red: 0.85, green: 0.35, blue: 0.12)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }

                        if let selected = viewModel.selectedChapter,
                           LocalChapterStorage.shared.isChapterTranslated(selected.id),
                           !viewModel.isTranslatingBatch {
                            Button {
                                Task {
                                    await viewModel.restoreOriginalFromDrive(for: selected)
                                }
                            } label: {
                                Label("Khôi phục chương hiện tại về bản gốc trên Drive", systemImage: "arrow.uturn.backward.circle")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(18)
            }
            .navigationTitle("Dịch Truyện AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") {
                        dismiss()
                    }
                }
            }
        }
    }
}
