import SwiftUI

struct SettingsSheetView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showApiKeyPlain: Bool = false
    @State private var showDriveAdvanced: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.orange)
                            Text("Gemini API Key")
                                .font(.headline)
                            Spacer()
                            Button(showApiKeyPlain ? "Ẩn" : "Hiện") {
                                showApiKeyPlain.toggle()
                            }
                            .font(.caption.weight(.semibold))
                        }

                        if showApiKeyPlain {
                            TextField("Dán mã AIzaSy...", text: $viewModel.geminiApiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.subheadline, design: .monospaced))
                                .padding(10)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            SecureField("Dán mã AIzaSy...", text: $viewModel.geminiApiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.subheadline, design: .monospaced))
                                .padding(10)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        Text("Bạn chỉ cần nhập duy nhất Gemini API Key tại đây để dịch truyện. Lấy miễn phí tại aistudio.google.com.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Kết nối Gemini AI (Bắt buộc khi dịch)")
                }

                Section {
                    Picker("Model dịch truyện", selection: $viewModel.selectedGeminiModel) {
                        ForEach(GeminiModelChoice.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    Toggle(isOn: $viewModel.autoSwitchTo31OnQuota) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tự động chuyển sang 3.1 Flash Lite khi hết Quota")
                                .font(.subheadline.weight(.medium))
                            Text("Nếu 3.5 Flash Lite hết hạn mức, ứng dụng sẽ tự động gọi 3.1 Flash Lite để không bị ngắt quãng.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Cấu hình Model AI")
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Câu lệnh biên tập & dịch truyện (Prompt)")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button {
                                viewModel.resetPromptToDefault()
                            } label: {
                                Label("Mặc định", systemImage: "arrow.counterclockwise")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        TextEditor(text: $viewModel.translationPrompt)
                            .frame(minHeight: 160)
                            .font(.system(size: 14))
                            .padding(6)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        Text("Câu lệnh này đã được thiết lập sẵn để sắp xếp lại câu từ tiếng Trung convert sang văn phong tiểu thuyết mượt mà, dễ đọc.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Phong cách dịch & Cover truyện")
                }

                Section {
                    Picker("Chủ đề màu sắc", selection: $viewModel.readerTheme) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }

                    HStack {
                        Text("Cỡ chữ đọc truyện")
                        Spacer()
                        Text("\(Int(viewModel.storyFontSize)) pt")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                        Stepper("", value: $viewModel.storyFontSize, in: 14...32, step: 1)
                            .labelsHidden()
                    }
                } header: {
                    Text("Giao diện đọc truyện")
                }

                Section {
                    HStack(spacing: 10) {
                        Image(systemName: viewModel.isDriveConfiguredViaSecrets ? "checkmark.seal.fill" : "info.circle.fill")
                            .foregroundStyle(viewModel.isDriveConfiguredViaSecrets ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.isDriveConfiguredViaSecrets
                                 ? "Đã kết nối sẵn Google Drive từ GitHub Secrets"
                                 : "Chưa có khóa Google Drive mặc định")
                                .font(.subheadline.weight(.semibold))
                            Text(viewModel.isDriveConfiguredViaSecrets
                                 ? "Bạn KHÔNG cần nhập mục bên dưới trừ khi muốn đổi sang thư mục Google Drive khác."
                                 : "Hãy nhập Google Drive API Key và Link thư mục Google Drive bên dưới.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    DisclosureGroup("Đổi thư mục Google Drive khác (Không bắt buộc)", isExpanded: $showDriveAdvanced) {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("1. Link thư mục hoặc Folder ID:")
                                    .font(.caption.weight(.semibold))
                                TextField("Dán nguyên link drive.google.com/drive/folders/... hoặc ID", text: $viewModel.driveFolderIdOverride)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.caption)
                                    .padding(9)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text("Mẹo: Bạn có thể copy nguyên đường link thư mục Google Drive rồi dán vào đây, ứng dụng sẽ tự động tách lấy mã ID.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("2. Google Drive API Key (Để trống nếu dùng mặc định):")
                                    .font(.caption.weight(.semibold))
                                TextField("AIzaSy... (Bỏ trống để dùng key có sẵn trong app)", text: $viewModel.driveApiKeyOverride)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.caption)
                                    .padding(9)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("3. OAuth Access Token (Bỏ trống - chỉ dùng nếu muốn ghi đè lên đám mây):")
                                    .font(.caption.weight(.semibold))
                                TextField("ya29... (Không bắt buộc, mặc định app đã ghi đè file trong máy)", text: $viewModel.driveAccessToken)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.caption)
                                    .padding(9)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            Button {
                                Task {
                                    await viewModel.applyCustomDriveSettingsAndReload()
                                }
                            } label: {
                                Label("Áp dụng & Tải lại thư viện Drive", systemImage: "arrow.clockwise.circle.fill")
                                    .font(.caption.weight(.bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 6)
                    }
                } header: {
                    Text("Nguồn dữ liệu Google Drive")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Cài đặt AI & Giao diện")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Ẩn bàn phím") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") {
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}
