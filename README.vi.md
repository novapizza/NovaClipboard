# NovaClipboard

[English](README.md) · **Tiếng Việt**

Trang web: [novasuite.coding4pizza.com/novaclipboard](https://novasuite.coding4pizza.com/novaclipboard)

Trình quản lý clipboard chạy trên thanh menu (menu-bar) của macOS, viết native. Nhấn phím tắt, chọn một mục vừa sao chép gần đây, dán vào ứng dụng đang mở — không có biểu tượng ở Dock, không có máy chủ, mọi dữ liệu đều nằm trên máy Mac của bạn.

## Tính năng

- Ứng dụng thanh menu (không hiện ở Dock, `LSUIElement`).
- Phím tắt toàn cục để mở bảng lịch sử, neo cạnh con trỏ nhập liệu, con trỏ chuột, hoặc một vị trí cố định.
- Thu thập **văn bản, văn bản định dạng (rich text), liên kết, hình ảnh và tham chiếu tệp** từ `NSPasteboard`.
- **Tự động thu thập ảnh chụp màn hình từ đĩa** — các tệp `⌘⇧3/4/5` được ghi vào `~/Desktop` (hoặc thư mục ảnh chụp bạn cấu hình) sẽ vào lịch sử qua FSEvents, kể cả khi không có gì được đưa lên clipboard.
- Tuỳ chọn "bỏ qua ảnh xem trước của macOS" để ảnh chụp lưu ngay ra đĩa (chuyển đổi `com.apple.screencapture show-thumbnail`), và tuỳ chọn "sao chép ảnh chụp mới lên clipboard" để bạn dán ảnh vừa chụp bằng `⌘V`.
- Ghim (pin), dán nhanh (`⌘⌥1..⌘⌥9` mặc định, có thể đổi phím bổ trợ), và các hành động trên hàng khi rê chuột (ghim / xoá).
- Menu trên thanh trạng thái: Hiện lịch sử, Cài đặt, Xoá tất cả (giữ mục đã ghim), Thoát (kèm mục "Accessibility Permission…" hiện có điều kiện khi chưa được cấp quyền).
- Cài đặt cho phím tắt, phím bổ trợ dán nhanh, vị trí bảng, giới hạn lịch sử, giới hạn kích thước ảnh, thời gian lưu (Vĩnh viễn / 7 ngày / 30 ngày), khởi động cùng đăng nhập, ứng dụng bị chặn, thu thập ảnh chụp màn hình, và ngôn ngữ giao diện.
- Quyền riêng tư: danh sách chặn theo nguồn ứng dụng (đã có sẵn 1Password, LastPass, Bitwarden, Keychain Access) và bộ lọc UTI kiểu ẩn — các mục được đánh dấu `org.nspasteboard.ConcealedType` sẽ bị bỏ qua.
- Khôi phục clipboard: nội dung clipboard trước đó được khôi phục ngay sau khi dán, nên bản sao chép đang dở của bạn được giữ nguyên.
- Loại trùng lặp bằng checksum SHA-256; các blob ảnh ≥ 128 KB được ghi ra tệp trong container của ứng dụng thay vì lưu trong cơ sở dữ liệu.
- Đã bản địa hoá **Tiếng Anh** và **Tiếng Việt** (tự động theo ngôn ngữ hệ thống, hoặc chọn cố định trong Cài đặt → General).
- Tự động cập nhật qua [Sparkle](https://sparkle-project.org).

## Phím tắt mặc định

`⌘ ⇧ V` — có thể thay đổi trong Cài đặt → General.

Trong bảng lịch sử:
- `↑` / `↓` di chuyển lựa chọn
- `↵` dán mục đang chọn
- `⌘⌥1..⌘⌥9` dán nhanh chín hàng đầu tiên (mục ghim trước, rồi tới mục gần đây) — phím bổ trợ khớp với phím đặt trong Cài đặt
- `⌘P` bật/tắt ghim mục đang chọn
- `⌫` xoá mục đang chọn
- `Esc` hoặc bấm ra ngoài để đóng bảng

Dán nhanh cũng hoạt động toàn cục (không cần mở bảng): `⌘⌥1..⌘⌥9` dán thẳng mục gần đây thứ N vào ứng dụng đang mở. Bật/tắt và đổi phím bổ trợ trong Cài đặt → General.

> Phím bổ trợ dán nhanh mặc định là `⌘⌥` (không phải `⌘⇧`) là có chủ đích: `⌘⇧3/4/5` trùng với chính các phím tắt chụp màn hình của macOS.

## Build & chạy từ Xcode

Yêu cầu:
- macOS 14 Sonoma trở lên
- Xcode 15+ (Swift 5.10, SwiftUI, SwiftData)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (dự án Xcode được sinh ra từ `project.yml`)
- Một Apple ID đã đăng nhập vào Xcode (Personal Team là đủ — không cần tài khoản Developer Program trả phí)

Các bước:
1. Chạy `xcodegen generate` sau khi pull, hoặc bất cứ khi nào bạn thêm/xoá tệp Swift.
2. Mở `NovaClipboard.xcodeproj` trong Xcode.
3. Chọn scheme `NovaClipboard`, target "My Mac".
4. `⌘R` để build và chạy. Biểu tượng clipboard sẽ xuất hiện trên thanh menu.

`⌘U` chạy các bài kiểm thử đơn vị và tích hợp (`NovaClipboardTests`).

Để build nhanh từ dòng lệnh mà không cần ký mã (code signing):

```
xcodebuild -project NovaClipboard.xcodeproj -scheme NovaClipboard -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Và để chạy kiểm thử từ dòng lệnh (ứng dụng được build trước — target kiểm thử liên kết qua `BUNDLE_LOADER`/`TEST_HOST`):

```
xcodebuild -project NovaClipboard.xcodeproj -scheme NovaClipboard -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

> **Giữ nguyên signing team giữa các lần build lại.** macOS gắn quyền Accessibility với chữ ký mã. Đổi team (hoặc xoá/thêm chứng chỉ) sẽ vô hiệu hoá quyền và bạn phải cấp lại.

## Cấp quyền Accessibility

Ứng dụng cần quyền Accessibility để (1) mô phỏng `⌘V` vào ứng dụng đang mở, và (2) đọc vị trí con trỏ nhập liệu để đặt bảng.

1. Ở lần chạy đầu tiên, cửa sổ onboarding sẽ mở ra. Bấm **Open System Settings**.
2. Trong **Privacy & Security → Accessibility**, bật công tắc cho `NovaClipboard.app`.
3. Nếu trước đó bạn đã cấp quyền cho một bản build cũ, hãy xoá mục đó trước, rồi thêm bản `.app` vừa build (Xcode → Product → Show Build Folder in Finder).
4. Khởi động lại ứng dụng. Cửa sổ onboarding tự đóng khi quyền được bật.

Nếu biểu tượng thanh menu chuyển thành hình tam giác cảnh báo, quyền đã bị thu hồi — bấm vào menu vẫn hoạt động, nhưng việc phát hiện con trỏ và dán sẽ suy giảm một cách an toàn. Biểu tượng được kiểm tra lại mỗi 3 giây và trở lại bình thường khi quyền được khôi phục.

## Khởi động cùng đăng nhập

Được bật mặc định ở lần chạy đầu qua `SMAppService`. Trạng thái ở cấp hệ điều hành được đồng bộ với công tắc để giao diện không bao giờ hiển thị sai về việc login item đã được đăng ký hay chưa. Tắt trong Cài đặt → General nếu bạn muốn tự khởi động ứng dụng.

## Lưu trữ dữ liệu

- Kho SwiftData: `~/Library/Containers/io.haunc.NovaClipboard/Data/Library/Application Support/`
- Các blob ảnh ≥ 128 KB được ghi thành tệp PNG trong `NovaClipboard/Images/` cùng container; blob nhỏ hơn được lưu inline trong cơ sở dữ liệu qua external storage của SwiftData.
- Không có gì rời khỏi máy. Ứng dụng không chạy sandbox và không kèm entitlement network-client; lưu lượng ra ngoài duy nhất là việc lấy favicon cho phần xem trước liên kết và lần kiểm tra cập nhật của Sparkle.

Để đặt lại mọi thứ: thoát NovaClipboard, xoá container ở trên, rồi khởi động lại.

## Cấu trúc dự án

```
NovaClipboard/
  App/            NSApplicationDelegate (composition root), gắn kết scene
  Models/         Kiểu @Model của SwiftData, AppSettings, KeyCombo
  Services/       ClipboardMonitor, ScreenshotWatcher, HotKeyManager,
                  PasteEngine, PanelController, PanelAnchorResolver,
                  HistoryStore, UpdateController (Sparkle)
  Features/       Bảng lịch sử (hàng + view bảng), các tab Cài đặt, Onboarding
  Design/         View modifier dùng chung LiquidGlass và button style
  Utilities/      Checksum, ImageStore, FaviconCache, LaunchAtLogin,
                  ScreenshotPreviewPreference
  Resources/      Info.plist, Assets.xcassets, Localizable.xcstrings (en/vi)
NovaClipboardTests/   Target XCTest
.docs/                PRD, Spec, Plan
project.yml           Đặc tả XcodeGen
```
