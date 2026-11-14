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
                            TextField("Nhập khóa AIzaSy...", text: $viewModel.geminiApiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.subheadline, design: .monospaced))
                                .padding(10)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            SecureField("Nhập khóa AIzaSy...", text: $viewModel.geminiApiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.subheadline, design: .monospaced))
                                .padding(10)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        Text("Khóa API được lưu an toàn ngay trên máy của bạn để dịch và biên tập lại chương truyện.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Kết nối Gemini AI")
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
                            Text("Nếu 3.5 Flash Lite hết hạn mức, ứng dụng sẽ tự động gọi 3.1 Flash Lite để không làm gián đoạn quá trình dịch.")
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
                            .frame(minHeight: 165)
                            .font(.system(size: 14))
                            .padding(6)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        Text("Câu lệnh này giúp AI sắp xếp lại câu từ tiếng Trung convert sang văn phong tiểu thuyết tiếng Việt mượt mà, dễ đọc.")
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
                    DisclosureGroup("Cấu hình Google Drive nâng cao (Tùy chọn)", isExpanded: $showDriveAdvanced) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Mặc định ứng dụng dùng khóa Google Drive tích hợp khi build. Bạn chỉ cần điền nếu muốn đổi sang kho truyện khác.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextField("Google Drive API Key tùy chỉnh", text: $viewModel.driveApiKeyOverride)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.caption)

                            TextField("Root Folder ID tùy chỉnh", text: $viewModel.driveFolderIdOverride)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.caption)

                            TextField("Drive OAuth Access Token (để ghi đè cả trên đám mây)", text: $viewModel.driveAccessToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Nguồn dữ liệu")
                }
            }
            .navigationTitle("Cài đặt AI & Giao diện")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
