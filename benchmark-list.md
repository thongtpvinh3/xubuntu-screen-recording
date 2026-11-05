## Các khía cạnh đánh giá benchmark

* Tài nguyên tiêu thụ
* Chất lượng ghi hình
* Dung lượng lưu trữ và độ ổn định

### 1. Thông tin môi trường đo

| Thông tin         | Nội dung cần ghi                                         |
|-------------------|----------------------------------------------------------|
| Phần cứng         | Model CPU, số core/thread, RAM, loại ổ đĩa               |
| Môi trường        | Phiên bản Xubuntu, kernel, FFmpeg; máy thật hay VM       |
| Màn hình          | Độ phân giải desktop, số màn hình                        |
| Cấu hình recorder | FPS, preset, bitrate/maxrate, GOP, thời lượng segment    |
| Kịch bản          | Desktop tĩnh, thao tác văn phòng, cuộn trang, phát video |
| Thời gian đo      | Thời lượng mỗi lần đo và số lần lặp                      |

### 2. Các chỉ số benchmark chính

| Nhóm             | Chỉ số                                             | Cách trình bày / mục đích                                                                     |
|------------------|----------------------------------------------------|-----------------------------------------------------------------------------------------------|
| CPU              | CPU trung bình, P95, cao nhất                      | Đánh giá mức tải thường xuyên và tải đột biến. Ghi rõ quy ước 100% tương ứng một logical CPU. |
| RAM              | RSS trung bình, P95, cao nhất                      | Đánh giá bộ nhớ sử dụng; theo dõi xu hướng tăng khi chạy lâu.                                 |
| Tốc độ ghi hình  | FPS thực tế, tỷ lệ frame bị drop/duplicate         | So sánh với FPS cấu hình và đánh giá khả năng theo kịp chuyển động.                           |
| Tính liên tục    | Khoảng gián đoạn giữa các segment                  | Phát hiện mất nội dung tại thời điểm chuyển file hoặc khởi động lại.                          |
| Dung lượng       | MB/segment, GB/giờ, bitrate thực tế                | Phục vụ dự toán ổ đĩa và thời gian lưu trữ.                                                   |
| I/O              | Tốc độ ghi đĩa trung bình, đỉnh                    | Đánh giá tải lên ổ đĩa, nhất là khi hoàn tất segment.                                         |
| Chất lượng video | Độ rõ chữ, chuyển động, lỗi hình                   | Kiểm tra khả năng đọc nội dung và xem lại thao tác.                                           |
| Toàn vẹn dữ liệu | Tỷ lệ file giải mã được, số file lỗi               | Xác nhận video thực sự sử dụng được.                                                          |
| Khởi động        | Thời gian từ kích hoạt đến frame đầu tiên          | Đánh giá phần đầu phiên làm việc bị bỏ lỡ.                                                    |
| Dừng             | Thời gian hoàn tất dừng, tình trạng segment cuối   | Đo khi stop, logout và shutdown bình thường.                                                  |
| Phục hồi         | Thời gian khôi phục sau lỗi FFmpeg, số lần restart | Đánh giá cơ chế tự khởi động lại.                                                             |
| Cleanup          | Thời gian chạy, số file và dung lượng đã xóa       | Đánh giá hiệu quả dọn dữ liệu và ảnh hưởng khi đang ghi.                                      |
| Chạy dài hạn     | Số lỗi, thời gian ngừng ghi, tăng trưởng RAM       | Đánh giá độ ổn định qua nhiều giờ hoặc nhiều ngày.                                            |

