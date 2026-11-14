# Đọc Truyện AI (SwiftUI Native iOS)

Ứng dụng đọc truyện kết nối Google Drive được viết hoàn toàn bằng **Swift & SwiftUI**, tích hợp **Google Gemini AI (3.5 Flash Lite & 3.1 Flash Lite)** để dịch và biên tập lại truyện convert tiếng Trung sang văn phong tiểu thuyết tiếng Việt mượt mà.

## Tính năng nổi bật

1. **Chuyển đổi hoàn toàn sang ngôn ngữ Swift (SwiftUI Native)**:
   - Tốc độ phản hồi tức thì, cuộn mượt mà, hỗ trợ 4 chủ đề đọc truyện (**Giấy cổ**, **Trắng ngọc**, **Đêm tối**, **Xanh dịu**) và tùy chỉnh cỡ chữ linh hoạt.
   - Tự động lưu vị trí chương đang đọc cho từng bộ truyện.

2. **Tích hợp Gemini AI Biên tập & Cover Truyện Convert**:
   - Ô nhập **Gemini API Key** lưu trực tiếp trên thiết bị.
   - Hỗ trợ chọn model **Gemini 3.5 Flash Lite** và **Gemini 3.1 Flash Lite** kèm chế độ **tự động chuyển đổi sang 3.1 Flash Lite khi hết hạn mức (Quota)**.
   - Tích hợp sẵn **câu lệnh (Prompt) chuẩn biên tập tiểu thuyết tiên hiệp/cổ trang** và cho phép người dùng tự do chỉnh sửa hoặc khôi phục mặc định bất cứ lúc nào.

3. **Dịch hàng loạt theo dải chương & Ghi đè file**:
   - Nút **Dịch truyện** ngay trên thanh công cụ khi đọc chương.
   - Popup chọn dịch **Từ chương ... Đến chương ...** (hoặc chọn nhanh: *Chỉ chương này*, *5 chương tiếp*, *10 chương tiếp*).
   - Khi dịch xong từng chương, ứng dụng tự động **thay thế nội dung gốc đang hiển thị bằng nội dung đã dịch** và **ghi đè trực tiếp vào file chương cũ** để lần sau mở lại không cần dịch lại.

## Cách Build IPA tự động qua GitHub Actions

1. Đẩy toàn bộ mã nguồn lên nhánh `main` của repository GitHub.
2. Đảm bảo trong mục **Settings -> Secrets and variables -> Actions** đã có:
   - `GOOGLE_DRIVE_API_KEY`
   - `GOOGLE_DRIVE_FOLDER_ID`
3. GitHub Actions (`.github/workflows/build-ipa-no-sign.yml`) sẽ tự động chạy `xcodegen` + `xcodebuild` trên `macos-15` và xuất bản file `Doc-truyen.ipa` trong mục **Releases**.
