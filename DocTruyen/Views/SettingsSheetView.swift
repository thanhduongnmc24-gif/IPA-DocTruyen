import SwiftUI

struct SettingsSheetView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showApiKeyPlain: Bool = false
    @State private var showDriveAdvanced: Bool = false
    @State private var showAppsScriptGuide: Bool = false

    private let appsScriptSnippet = """
function doPost(e) {
  try {
    var data = JSON.parse(e.postData.contents);
    var file = DriveApp.getFileById(data.fileId);
    file.setContent(data.content);
    if (data.newName) {
      file.setName(data.newName);
    }
    return ContentService.createTextOutput(JSON.stringify({ok: true}))
      .setMimeType(ContentService.MimeType.JSON);
  } catch (err) {
    return ContentService.createTextOutput(JSON.stringify({ok: false, error: err.toString()}))
      .setMimeType(ContentService.MimeType.JSON);
  }
}
"""

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

                        Text("Bạn chỉ cần nhập Gemini API Key tại đây để dịch truyện. Lấy miễn phí tại aistudio.google.com.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Kết nối Gemini AI (Bắt buộc khi dịch)")
                }

                // SECTION MỚI: GHI ĐÈ LÊN GOOGLE DRIVE VĨNH VIỄN
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: viewModel.isCloudOverwriteConfigured ? "icloud.and.arrow.up.fill" : "icloud.slash")
                                .foregroundStyle(viewModel.isCloudOverwriteConfigured ? .green : .orange)
                            Text(viewModel.isCloudOverwriteConfigured
                                 ? "Đã bật tự động ghi đè lên Google Drive"
                                 : "Hiện chỉ ghi đè trên máy (Chưa bật ghi đè lên Drive)")
                                .font(.subheadline.weight(.bold))
                        }

                        Text("Vì Google không cho phép API Key thường (`AIzaSy...`) sửa file trên Drive, bạn chỉ cần dán **Link Web App Google Apps Script** (cài 1 lần dùng vĩnh viễn) vào ô dưới đây để mỗi khi dịch xong, app tự động ghi đè nội dung + tên chương mới lên thẳng Google Drive:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("Dán link https://script.google.com/macros/s/.../exec", text: $viewModel.driveAppsScriptUrl)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.caption)
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        DisclosureGroup("Cách tạo Link Apps Script trong 30 giây (Dùng vĩnh viễn)", isExpanded: $showAppsScriptGuide) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("1. Mở trang **script.google.com** -> Bấm **Dự án mới (New project)**.\n2. Xóa đoạn mã có sẵn và dán đoạn mã dưới đây vào:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(appsScriptSnippet)
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(.tertiarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                Button {
                                    UIPasteboard.general.string = appsScriptSnippet
                                    viewModel.showToast("Đã copy mã Apps Script!")
                                } label: {
                                    Label("Copy đoạn mã Apps Script", systemImage: "doc.on.doc")
                                        .font(.caption.weight(.bold))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Text("3. Bấm **Triển khai (Deploy)** -> **Tùy chọn triển khai mới (New deployment)** -> Chọn loại **Ứng dụng web (Web app)**.\n4. Mục *Thực thi dưới dạng*: chọn **Tôi (Me)**. Mục *Ai có quyền truy cập*: chọn **Bất kỳ ai (Anyone)** -> Bấm **Triển khai** rồi copy đường link `https://script.google.com/macros/s/.../exec` dán vào ô phía trên.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 6)
                        }
                        .font(.caption.weight(.semibold))

                        if viewModel.isCloudOverwriteConfigured && !viewModel.chapters.isEmpty {
                            Button {
                                Task {
                                    await viewModel.syncAllTranslatedChaptersToDrive()
                                }
                            } label: {
                                Label("Đồng bộ ghi đè các chương đã dịch trước đó lên Drive", systemImage: "icloud.and.arrow.up")
                                    .font(.caption.weight(.bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Tự động ghi đè file lên Google Drive")
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
                            Text("Nếu 3.5 Flash Lite hết hạn mức hoặc quá tải, ứng dụng sẽ tự động gọi 3.1 Flash Lite.")
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
                            .frame(minHeight: 150)
                            .font(.system(size: 14))
                            .padding(6)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
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
                                Text("3. OAuth Access Token (Tùy chọn nếu không dùng Apps Script):")
                                    .font(.caption.weight(.semibold))
                                TextField("ya29...", text: $viewModel.driveAccessToken)
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
