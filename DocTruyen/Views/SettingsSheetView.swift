import SwiftUI

struct SettingsSheetView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showApiKeyPlain: Bool = false
    @State private var showDriveAdvanced: Bool = false
    @State private var showAppsScriptGuide: Bool = false

    /// Mã Apps Script nâng cấp: Hỗ trợ cả đọc chương/danh sách file (doGet + doPost read) VÀ ghi đè + đổi tên file có LockService chống nghẽn
    private let appsScriptSnippet = """
function doGet(e) {
  try {
    var action = (e && e.parameter && e.parameter.action) ? e.parameter.action : "read";
    if (action === "read" && e.parameter.fileId) {
      var file = DriveApp.getFileById(e.parameter.fileId);
      var content = file.getBlob().getDataAsString("UTF-8");
      return ContentService.createTextOutput(JSON.stringify({ok: true, name: file.getName(), content: content}))
        .setMimeType(ContentService.MimeType.JSON);
    }
    if (action === "list" && e.parameter.folderId) {
      var folder = DriveApp.getFolderById(e.parameter.folderId);
      var list = [];
      var folders = folder.getFolders();
      while (folders.hasNext()) {
        var f = folders.next();
        list.push({id: f.getId(), name: f.getName(), mimeType: "application/vnd.google-apps.folder"});
      }
      var files = folder.getFiles();
      while (files.hasNext()) {
        var fl = files.next();
        list.push({id: fl.getId(), name: fl.getName(), mimeType: fl.getMimeType()});
      }
      list.sort(function(a, b) { return a.name.localeCompare(b.name, undefined, {numeric: true}); });
      return ContentService.createTextOutput(JSON.stringify({ok: true, files: list}))
        .setMimeType(ContentService.MimeType.JSON);
    }
    return ContentService.createTextOutput(JSON.stringify({ok: true, status: "active"}))
      .setMimeType(ContentService.MimeType.JSON);
  } catch (err) {
    return ContentService.createTextOutput(JSON.stringify({ok: false, error: err.toString()}))
      .setMimeType(ContentService.MimeType.JSON);
  }
}

function doPost(e) {
  var lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    var data = JSON.parse(e.postData.contents);
    if (data.action === "read" && data.fileId) {
      var readFile = DriveApp.getFileById(data.fileId);
      var text = readFile.getBlob().getDataAsString("UTF-8");
      return ContentService.createTextOutput(JSON.stringify({ok: true, name: readFile.getName(), content: text}))
        .setMimeType(ContentService.MimeType.JSON);
    }
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
  } finally {
    lock.releaseLock();
  }
}
"""

    var body: some View {
        let _ = viewModel.translatedRevisionTrigger
        let totalTranslated = LocalChapterStorage.shared.translatedCount(in: viewModel.chapters)
        let totalDriveSynced = LocalChapterStorage.shared.driveSyncedCount(in: viewModel.chapters)
        let unsyncedCount = LocalChapterStorage.shared.unsyncedTranslatedChapters(in: viewModel.chapters).count

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

                        Text("Nhập Gemini API Key tại đây để dịch truyện. Lấy miễn phí tại aistudio.google.com.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Kết nối Gemini AI (Bắt buộc khi dịch)")
                }

                // SECTION: GHI ĐÈ & ĐỌC DỰ PHÒNG QUA GOOGLE APPS SCRIPT
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

                        Text("Dán **Link Web App Google Apps Script** (`https://script.google.com/macros/s/.../exec`) vào ô dưới đây để tự động ghi đè bản đã dịch + tên chương mới lên thẳng Google Drive và hỗ trợ tải chương không bị giới hạn:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("Dán link https://script.google.com/macros/s/.../exec", text: $viewModel.driveAppsScriptUrl)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.caption)
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        if !viewModel.chapters.isEmpty {
                            HStack(spacing: 8) {
                                Text("📱 Đã dịch: \(totalTranslated)")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.green.opacity(0.15))
                                    .foregroundStyle(.green)
                                    .clipShape(Capsule())

                                Text("☁️ Đã lên Drive: \(totalDriveSynced)")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.15))
                                    .foregroundStyle(.blue)
                                    .clipShape(Capsule())

                                if unsyncedCount > 0 {
                                    Text("⏳ Chưa lên Drive: \(unsyncedCount)")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.orange.opacity(0.16))
                                        .foregroundStyle(.orange)
                                        .clipShape(Capsule())
                                }
                            }
                        }

                        if viewModel.isSyncingToDrive || !viewModel.driveSyncStatusNote.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                if viewModel.isSyncingToDrive {
                                    ProgressView(
                                        value: Double(viewModel.driveSyncProgressCount),
                                        total: Double(max(viewModel.driveSyncTotalCount, 1))
                                    )
                                    .tint(.blue)
                                }
                                Text(viewModel.driveSyncStatusNote)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(viewModel.driveSyncStatusNote.hasPrefix("⚠️") ? .orange : .primary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        if viewModel.isCloudOverwriteConfigured && !viewModel.chapters.isEmpty {
                            if viewModel.isSyncingToDrive {
                                Button(role: .destructive) {
                                    viewModel.cancelDriveSync()
                                } label: {
                                    Label("Dừng đồng bộ Google Drive", systemImage: "stop.circle.fill")
                                        .font(.caption.weight(.bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                if unsyncedCount > 0 {
                                    Button {
                                        Task {
                                            await viewModel.syncAllTranslatedChaptersToDrive(onlyUnsynced: true)
                                        }
                                    } label: {
                                        Label("Đẩy bù \(unsyncedCount) chương đã dịch chưa lên Drive (Chạy ngầm)", systemImage: "icloud.and.arrow.up.fill")
                                            .font(.caption.weight(.bold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.orange)
                                }

                                Button {
                                    Task {
                                        await viewModel.syncAllTranslatedChaptersToDrive(onlyUnsynced: false)
                                    }
                                } label: {
                                    Label("Ghi đè lại toàn bộ \(totalTranslated) chương đã dịch lên Drive (Chạy ngầm)", systemImage: "arrow.triangle.2.circlepath.icloud.fill")
                                        .font(.caption.weight(.bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        DisclosureGroup("Mã Google Apps Script chuẩn (Hỗ trợ cả Đọc & Ghi đè không giới hạn)", isExpanded: $showAppsScriptGuide) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("1. Mở **script.google.com** -> Mở dự án của bạn (hoặc tạo dự án mới).\n2. Dán đoạn mã dưới đây vào (đã tích hợp `LockService` chống nghẽn khi ghi đè liên tiếp và hỗ trợ đọc chương):")
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
                                    viewModel.showToast("Đã copy mã Apps Script nâng cấp!")
                                } label: {
                                    Label("Copy đoạn mã Apps Script", systemImage: "doc.on.doc")
                                        .font(.caption.weight(.bold))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Text("3. Bấm **Triển khai (Deploy)** -> **Tùy chọn triển khai mới (New deployment)** -> Loại: **Ứng dụng web (Web app)**.\n4. *Thực thi dưới dạng*: **Tôi (Me)**. *Ai có quyền truy cập*: **Bất kỳ ai (Anyone)** -> Copy link `.../exec` dán vào ô phía trên.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 6)
                        }
                        .font(.caption.weight(.semibold))
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
                            Text("Nếu nhánh chính chạm giới hạn hoặc quá tải, ứng dụng tự động chuyển đổi và chờ hồi hạn mức.")
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
                                Text("1. Link thư mục Google Drive hoặc Folder ID (Không dán link Apps Script vào đây):")
                                    .font(.caption.weight(.semibold))
                                TextField("Bỏ trống để dùng thư mục mặc định, hoặc dán link drive.google.com/drive/folders/...", text: $viewModel.driveFolderIdOverride)
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
