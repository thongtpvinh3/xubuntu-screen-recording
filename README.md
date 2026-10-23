scripts/: chứa logic Bash.
config/: lưu cấu hình dùng chung.
systemd/: khai báo cách quản lý tiến trình.
autostart/: kích hoạt chương trình khi XFCE desktop sẵn sàng.
cron/: lập lịch dọn dẹp video.
docs/: hướng dẫn cài đặt, vận hành và kiểm thử.

| File               | Trách nhiệm chính                                                  |
|--------------------|--------------------------------------------------------------------|
| `check-env.sh`     | Kiểm tra hệ điều hành, X11, FFmpeg, quyền truy cập và dung lượng   |
| `session-start.sh` | Chuẩn bị môi trường desktop và yêu cầu systemd khởi động recorder  |
| `record.sh`        | Gọi FFmpeg, ghi hình liên tục, chia MP4 và xử lý dừng an toàn      |
| `session-watch.sh` | Theo dõi XFCE session để phát hiện logout                          |
| `cleanup.sh`       | Xóa video đã quá thời hạn 10 ngày                                  |
| `metrics.sh`       | Thu thập số liệu CPU, RAM, FPS và dung lượng để đánh giá hiệu năng |


Luồng hoạt động:
XFCE Login -> screenrec.desktop -> session-start.sh -> systemd --user -> record.sh


| Thành phần     | Đường dẫn trên Xubuntu                     |
|----------------|--------------------------------------------|
| Bash scripts   | `/usr/local/libexec/screenrec/`            |
| Cấu hình       | `/etc/screenrec/screenrec.conf`            |
| User service   | `~/.config/systemd/user/screenrec.service` |
| XFCE Autostart | `~/.config/autostart/screenrec.desktop`    |
| Cron Job       | `/etc/cron.d/screenrec-cleanup`            |
| Video          | `/var/log/screenrecordings/`               |
| Log service    | systemd Journal                            |
| Metrics        | `~/.local/state/screenrec/`                |

chạy tổng thể:
```
bash install.sh
```