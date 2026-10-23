# TEST PLAN & TEST CASES — Xubuntu Screen Recorder

**Version:** 1.0 — 2026-10-23  
**Source baseline:** `xubuntu-screenrec-one-command-installer.zip`, gồm `install.sh`, `config/screenrec.conf`, `scripts/{check-env,session-start,record,session-watch,metrics,cleanup}.sh`, `systemd/screenrec.service`, `autostart/screenrec.desktop`, `cron/screenrec-cleanup`.

## 1. Phạm vi và nguyên tắc

Hệ thống được thiết kế cho **một user đăng nhập cục bộ vào một phiên XFCE/X11**, ghi hình H.264/MP4 không âm thanh, chia segment mục tiêu 1800 giây, `systemd --user` quản lý recorder, Cron cleanup lúc 03:00 và dọn bù khi login. Wayland và đa phiên XFCE đồng thời không nằm trong phạm vi cam kết. Kiểm thử chia thành unit/static, integration, E2E, negative/security và endurance.

**Ưu tiên:** P0 = điều kiện chặn nghiệm thu (mất/ghi sai dữ liệu, không khởi động/dừng); P1 = lỗi vận hành/bảo mật/khôi phục đáng kể; P2 = khả năng tương thích/biên.  **Trạng thái thực thi:** NOT RUN / PASS / FAIL / BLOCKED / NOT APPLICABLE. Các hàng dưới đây là *test cần thực hiện*, **không phải kết quả đã chạy trên máy Xubuntu của bạn**.

### 1.1. Môi trường thực hiện

- Máy thử nghiệm: Xubuntu + XFCE/X11, ít nhất hai đợt (một bản được hỗ trợ mới và một bản cũ nằm trong phạm vi triển khai). Có snapshot VM trước các test nguy hiểm.
- Tài khoản desktop thường được phép `sudo` cài đặt; một tài khoản phụ để thử phân quyền.
- FFmpeg có `x11grab` và `libx264`; `ffprobe`, `xdpyinfo`, `flock`, `find`, `cron`, `systemd --user` có sẵn.
- Máy ảo riêng cho lỗi mất điện/`SIGKILL`, ổ đầy, tắt X11/kill session. Không chạy kiểu phá hoại trên máy làm việc hoặc máy có dữ liệu quan trọng.
- Ghi trước thông tin: `cat /etc/os-release`, `ffmpeg -version | head -1`, `echo "$DISPLAY"`, `echo "$XDG_SESSION_TYPE"`, `date -Is`, `df -h /var/log`.
- Không kiểm thử xóa bằng file video thật còn cần lưu; luôn dùng thư mục lab độc lập và `--config` riêng.

### 1.2. Bằng chứng cho một test

Mỗi test cần lưu: ID, môi trường, dữ liệu đầu vào, thời gian thực thi, thao tác, **expected**, **actual**, mã thoát, ảnh/video/log và trạng thái. Với E2E, bổ sung `journalctl --user -u screenrec.service -b --no-pager`, `ffprobe`, số lượng/kích thước MP4 và danh sách PID/cgroup.

## 2. Danh sách Test Case

### A. Cài đặt — `install.sh`

| ID | P | Hành động / dữ liệu thử | Kết quả mong đợi |
|---|---|---|---|
| TC-INS-01 | P0 | Cài lần đầu từ source đầy đủ: `bash install.sh` trong Terminal XFCE/X11 | 6 script, config, unit, autostart, cron đúng đường dẫn; recorder chạy nếu preflight đạt |
| TC-INS-02 | P1 | `bash install.sh --dry-run`, so sánh file/package/service trước–sau | Không thay đổi host, không chạy FFmpeg, chỉ in kế hoạch |
| TC-INS-03 | P1 | `bash install.sh --no-start` | Cài đầy đủ, không bắt đầu ghi ngay; có thể ghi ở lần đăng nhập XFCE kế tiếp |
| TC-INS-04 | P1 | Cài lại sau khi sửa `SCREENREC_FPS` trong file cấu hình hệ thống | Giữ file cấu hình cũ; scripts/unit/cron cập nhật; tránh nhân đôi startup |
| TC-INS-05 | P1 | `--overwrite-config` sau khi sửa config cũ | Có bản `.bak.*`; file mới đúng bản phát hành; có thể phục hồi backup |
| TC-INS-06 | P1 | `--skip-apt` trên máy thiếu package; trên máy đủ package | Thiếu gói thì báo lỗi có tên gói; đủ gói thì không gọi `apt-get` |
| TC-INS-07 | P1 | Chạy `sudo bash install.sh` | Từ chối chạy với UID=0, không cài sai owner/service |
| TC-INS-08 | P1 | Bỏ một file bắt buộc hoặc cố ý phá cú pháp Bash trong bản source thử nghiệm | Dừng sớm, không cài bộ file hỏng |
| TC-INS-09 | P1 | Mất mạng/`apt-get` lỗi ở máy ảo | Cài đặt trả lỗi rõ; lần chạy lại phục hồi được; không coi là atomic rollback |
| TC-INS-10 | P2 | Chạy installer từ đường dẫn có khoảng trắng | Vẫn cài đúng vì biến path được quote |

### B. Cấu hình — `screenrec.conf` + `check-env.sh --config-only`

| ID | P | Hành động / dữ liệu thử | Kết quả mong đợi |
|---|---|---|---|
| TC-CFG-01 | P0 | File config mặc định (FPS=25, segment=1800, retention=10) | Exit 0; in giá trị đúng |
| TC-CFG-02 | P1 | `SCREENREC_FPS=abc`, `0`, `61`, `08` | Giá trị sai lỗi 10; `08` được hiểu là 8 theo hệ thập phân |
| TC-CFG-03 | P1 | `SCREENREC_SEGMENT_SECONDS=9`, `86401`, không chia hết cho GOP | Ngoài miền lỗi 10; không chia hết cho GOP có WARN |
| TC-CFG-04 | P1 | `SCREENREC_RETENTION_DAYS=0`, `366`, `10` | 0/366 bị chặn, 10 được chấp nhận |
| TC-CFG-05 | P1 | Bitrate thiếu hậu tố, `MAXRATE < BITRATE`, `BUFSIZE < MAXRATE` | Exit 10, nêu tham số sai |
| TC-CFG-06 | P1 | `SCREENREC_PRESET` không hợp lệ | Exit 10 |
| TC-CFG-07 | P1 | Config không tồn tại, symlink, mode `0666`, owner trái phép | Không `source` file, trả lỗi 10 |
| TC-CFG-08 | P1 | `SCREENREC_DIR` rỗng, không tuyệt đối, `/`, chứa `/../` | Exit 10 |
| TC-CFG-09 | P2 | Các giá trị biên hợp lệ FPS=1/60, interval=5/3600 | Hợp lệ nếu các quan hệ còn lại đúng |

### C. Preflight X11/FFmpeg/storage — `check-env.sh`

| ID | P | Hành động / dữ liệu thử | Kết quả mong đợi |
|---|---|---|---|
| TC-ENV-01 | P0 | Chạy full preflight trong XFCE/X11 hợp lệ | Exit 0; nhận ra `DISPLAY`, `libx264`, `x11grab`, thư mục ghi riêng tư |
| TC-ENV-02 | P1 | `env -u DISPLAY .../check-env.sh` trong phiên desktop | Exit 30, không cho bắt đầu |
| TC-ENV-03 | P1 | Đặt `XDG_SESSION_TYPE=wayland` ở môi trường test | Exit 30 |
| TC-ENV-04 | P1 | DISPLAY trỏ đến X server không có quyền truy cập | Exit 30, không ghi hình |
| TC-ENV-05 | P1 | FFmpeg không có `x11grab`/`libx264` (test PATH/mock an toàn) | Exit 20; không chạy recorder |
| TC-ENV-06 | P1 | Đổi thư mục thử nghiệm thành mode `0755`/`0777` | Exit 40, chỉ ra thư mục không riêng tư |
| TC-ENV-07 | P1 | Thư mục đầu ra không tồn tại / không writable / symlink | Exit 40 |
| TC-ENV-08 | P1 | Thực thi full preflight bằng root trên VM | Exit 50 |
| TC-ENV-09 | P2 | Dung lượng trống dưới 1 GiB nhưng còn lớn hơn 0 (VM filesystem thử nghiệm) | Có WARN; đúng với hành vi hiện tại: chưa hard-stop |
| TC-ENV-10 | P2 | `XAUTHORITY` không đọc được | Exit 30 |

### D. Video và segmentation — `record.sh` + FFmpeg

| ID | P | Hành động / dữ liệu thử | Kết quả mong đợi |
|---|---|---|---|
| TC-REC-01 | P0 | Ghi tối thiểu 1 segment trên XFCE/X11 | MP4 tồn tại, codec `h264`, `ffprobe`/decode thành công |
| TC-REC-02 | P0 | Dùng cấu hình thử `SEGMENT_SECONDS=10`, chạy >25 s | Có ≥2 segment đã đóng, mỗi file giải mã được; thời lượng gần 10 s ngoài segment cuối |
| TC-REC-03 | P0 | Ghi một đoạn, dừng bình thường rồi kiểm tra đoạn cuối | Đoạn cuối có metadata MP4 hợp lệ, không có `moov atom not found` |
| TC-REC-04 | P1 | Đổi FPS 25 -> 15 với config test | Stream và FPS đo qua ffprobe gần thông số; không giả định mọi máy đều giữ FPS tuyệt đối |
| TC-REC-05 | P1 | Kiểm tra các tên file được tạo trong cùng một lần và sau restart | Tên có timestamp+run_id; không ghi đè segment cũ |
| TC-REC-06 | P1 | Ghi màn hình tĩnh 15 phút và desktop thay đổi nhanh 15 phút | Bitrate/kích thước khác nhau; chất lượng chấp nhận được; không coi 3M là bitrate đo chính xác |
| TC-REC-07 | P1 | Hai lời gọi `record.sh` dùng **cùng** thư mục | Lời gọi thứ hai từ chối vì lock; chỉ một recorder trên thư mục đó |
| TC-REC-08 | P1 | Ghi khi dual monitor / độ phân giải thay đổi giữa phiên | Ban đầu quay đủ virtual desktop; sự kiện đổi resolution được ghi thành giới hạn/lỗi nếu chưa hỗ trợ tự reconfigure |
| TC-REC-09 | P1 | FFmpeg mất X11 giữa lúc ghi (VM thử nghiệm) | Service không ghi tiếp file hỏng; hành vi restart/log có thể chẩn đoán |
| TC-REC-10 | P2 | Ghi 1 h với cấu hình 1800 s | Segment khoảng 30 phút; không kỳ vọng khớp tuyệt đối theo đồng hồ vì keyframe/timestamp |
| TC-REC-11 | P2 | Đặt lại thời gian đồng hồ lùi trong **một** phiên dài (VM) | Xác minh không bị ghi đè tên; đây là rủi ro hiện còn trong code nếu timestamp trùng |

### E. Signal, systemd và dừng an toàn

| ID | P | Hành động / dữ liệu thử | Kết quả mong đợi |
|---|---|---|---|
| TC-SIG-01 | P0 | `systemctl --user stop screenrec.service` khi đang ghi | Bash nhận SIGTERM; FFmpeg hoàn thiện MP4; service `inactive` |
| TC-SIG-02 | P0 | Dừng vào khoảng giữa segment (không chờ đủ 1800 s) | File cuối ngắn nhưng giải mã được |
| TC-SIG-03 | P0 | Dừng khi vừa chuyển sang segment mới | Segment cuối và trước cuối hợp lệ, không để FFmpeg còn sống |
| TC-SIG-04 | P1 | `systemctl --user restart screenrec.service` | Đóng file cũ, start recorder mới, run_id khác, không trùng tiến trình |
| TC-SIG-05 | P1 | FFmpeg bị kill bất ngờ trong VM | User service restart khi `record.sh` thoát lỗi; segment bị kill không được kỳ vọng hoàn chỉnh |
| TC-SIG-06 | P1 | Stop khi `metrics.sh` và `session-watch.sh` đang sleep | Hai helper cũng dừng; không orphan process trong cgroup |
| TC-SIG-07 | P1 | Thử nghiệm timeout stop/hang FFmpeg trong VM | `TimeoutStopSec=60s` kết thúc sau ngưỡng; lỗi shutdown được ghi rõ; file cuối có thể hỏng |
| TC-SIG-08 | P2 | Stop lặp lại 2–3 lần | Không lỗi nghiêm trọng, không restart ngoài ý muốn |

### F. XFCE logout watcher — `session-watch.sh`

| ID | P | Hành động / dữ liệu thử | Kết quả mong đợi |
|---|---|---|---|
| TC-SES-01 | P0 | Login → bắt đầu ghi → logout qua XFCE | Watcher phát hiện session hết, signal tới `record.sh`, FFmpeg đóng MP4 |
| TC-SES-02 | P1 | Khóa màn hình (không logout) | Recorder tiếp tục, không xem lock là logout |
| TC-SES-03 | P1 | `session-watch.sh` nhận PID/starttime sai (lab) | Không gửi signal sang tiến trình khác |
| TC-SES-04 | P1 | Tiến trình FFmpeg kết thúc trước watcher | Watcher tự thoát, không kill PID khác |
| TC-SES-05 | P2 | User switch/mở phiên XFCE thứ hai (VM) | Ghi nhận hành vi; multi-session hiện ngoài phạm vi hỗ trợ, không nghiệm thu như tính năng đã có |

### G. XFCE Autostart — `session-start.sh` và desktop entry

| ID | P | Hành động / dữ liệu thử | Kết quả mong đợi |
|---|---|---|---|
| TC-STA-01 | P0 | Login XFCE/X11 sau khi cài | Autostart gọi launcher; `screenrec.service` active, tạo video |
| TC-STA-02 | P0 | Reboot VM rồi login XFCE | Recorder tự bắt đầu lại, không cần lệnh thủ công |
| TC-STA-03 | P1 | Chạy `session-start.sh --check-only` | Chỉ kiểm tra; không thay đổi manager env, không cleanup, không start service |
| TC-STA-04 | P1 | Chạy launcher hai lần trong cùng session | Không spawn hai FFmpeg (service/lock ngăn trùng) |
| TC-STA-05 | P1 | `systemctl --user show-environment` sau launcher | Có DISPLAY và XAUTHORITY (nếu phiên có biến này), dùng đúng session |
| TC-STA-06 | P1 | X11 chưa sẵn trong một vài lượt poll | Chờ theo số lần/giây cấu hình rồi start khi sẵn sàng |
| TC-STA-07 | P1 | X11 hoàn toàn không sẵn hoặc phiên Wayland | Launcher trả lỗi, không ghi hình |
| TC-STA-08 | P1 | Login qua SSH nhưng không login XFCE | Service không auto-start từ `default.target`, trừ khi đang chạy từ phiên desktop khác |
| TC-STA-09 | P1 | Máy tắt lúc 03:00, bật và login muộn hơn | Launcher gọi cleanup bù trước khi bắt đầu ghi |
| TC-STA-10 | P2 | Cleanup bù lỗi (thư mục không sẵn) | Launcher ghi WARN; preflight sau đó có thể chặn nếu điều kiện lưu trữ không đạt |

### H. Dọn dẹp và lịch Cron — `cleanup.sh`

| ID | P | Hành động / dữ liệu thử | Kết quả mong đợi |
|---|---|---|---|
| TC-CLN-01 | P0 | File có `mtime` 11 ngày trước, khớp `screen_*.mp4` | Chạy thật thì file bị xóa |
| TC-CLN-02 | P0 | File có `mtime` 9 ngày trước | Giữ file |
| TC-CLN-03 | P0 | File vừa đủ dưới/trên 10 ngày (thử biên theo phút) | Xóa chính xác theo ngưỡng `-mmin +14399`, độ phân giải phút |
| TC-CLN-04 | P0 | FFmpeg đang ghi segment mới, đồng thời chạy cleanup | File đang ghi không bị xóa (trường hợp bình thường mtime được cập nhật) |
| TC-CLN-05 | P1 | `cleanup.sh --dry-run` với file 11 ngày | Log `WOULD_DELETE`, không file nào bị xóa |
| TC-CLN-06 | P1 | File không khớp mẫu, `.log`, `.mkv`, file trong subdirectory, symlink | Không xóa file ngoài phạm vi |
| TC-CLN-07 | P1 | Hai cleanup chạy đồng thời | Chỉ một tiến trình lấy lock; tiến trình còn lại skip |
| TC-CLN-08 | P1 | Đọc `/etc/cron.d/screenrec-cleanup` sau cài | Đã thay username, có cú pháp 0 3 * * *, mode 0644, owner root |
| TC-CLN-09 | P1 | Cron chạy thực tế trong VM ở thời điểm đã điều chỉnh có kiểm soát | User đúng, cleanup thực thi và có log `screenrec-cleanup` |
| TC-CLN-10 | P1 | Thư mục video sai owner/mode hoặc là symlink | Cleanup dừng an toàn, không xóa |
| TC-CLN-11 | P2 | Nhiều file lớn, tên có khoảng trắng | Xóa/ghi log đúng file, không lỗi tách chuỗi |

### I. Monitoring — `metrics.sh`

| ID | P | Hành động / dữ liệu thử | Kết quả mong đợi |
|---|---|---|---|
| TC-MET-01 | P1 | Ghi ≥ 2 chu kỳ `SCREENREC_METRICS_INTERVAL_SECONDS` | Có ≥ 2 log `PERF` chứa timestamp, ffmpeg_pid, CPU, RSS, disk free |
| TC-MET-02 | P1 | Cho desktop biến động CPU cao và ít biến động | `cpu_interval_pct` phản ánh biến động, chấp nhận vượt 100% trên CPU đa lõi |
| TC-MET-03 | P1 | Ngừng FFmpeg rồi quan sát metrics | Helper tự dừng, không tiếp tục lấy mẫu PID đã mất |
| TC-MET-04 | P1 | Truyền PID FFmpeg có starttime không đúng | Helper từ chối / dừng, không giám sát nhầm PID |
| TC-MET-05 | P2 | Đổi chu kỳ từ 60 xuống 5 giây trong config thử | Log xuất hiện theo chu kỳ mới (sai số do scheduling) |
| TC-MET-06 | P1 | Chủ động làm `metrics.sh` tự thoát trong VM | Phát hiện thiếu PERF; xác nhận hạn chế hiện tại: không có restart helper riêng |
| TC-MET-07 | P2 | Kiểm tra FPS hiệu dụng của FFmpeg | Chưa có metric FPS realtime độc lập; có thể phân tích `ffprobe` sau khi file đóng, cần phát triển thêm |

### J. Bảo mật — filesystem, quyền user và cấu hình

| ID | P | Hành động / dữ liệu thử | Kết quả mong đợi |
|---|---|---|---|
| TC-SEC-01 | P0 | `stat -c '%a %U' /var/log/screenrecordings`; thử truy cập bằng user thứ hai | Directory `0700`, user thứ hai không đọc được video |
| TC-SEC-02 | P1 | `stat` quyền file MP4 mới | File chỉ user recorder được đọc/ghi; không mở group/others |
| TC-SEC-03 | P1 | Kiểm tra owner script/config trong `/usr/local/libexec/screenrec` và `/etc/screenrec` | Các file hệ thống root-owned, user thường không sửa được |
| TC-SEC-04 | P1 | Đặt config thành symlink đến file tùy ý | `check-env` từ chối, không source file |
| TC-SEC-05 | P1 | Service chạy thực tế | FFmpeg không chạy UID=0; `NoNewPrivileges=yes` theo unit |
| TC-SEC-06 | P2 | Tài khoản XFCE khác đăng nhập (VM) | Không truy cập dữ liệu của user ghi ban đầu; giới hạn single-user được nêu rõ |

### K. End-to-end, độ bền và các sự cố

| ID | P | Hành động / dữ liệu thử | Kết quả mong đợi |
|---|---|---|---|
| TC-E2E-01 | P0 | Login → Record → Logout → Login | Không có tiến trình sót; phiên mới tạo segment mới; các MP4 đã đóng phát được |
| TC-E2E-02 | P0 | Login → Record → Reboot → Login | Dừng và tiếp tục đúng; video trước reboot hợp lệ khi shutdown bình thường |
| TC-E2E-03 | P1 | Ghi liên tục ≥ 24 giờ trên VM hoặc máy thử nghiệm riêng | Không crash, không leak tiến trình, không mất hàng loạt segment |
| TC-E2E-04 | P1 | Ghi liên tục ≥ 10 ngày, cleanup hàng ngày | Chỉ giữ dữ liệu trong cửa sổ retention theo mtime; đủ dung lượng hệ thống |
| TC-E2E-05 | P1 | Giới hạn dung lượng phân vùng riêng (VM) đến lúc đầy | FFmpeg báo lỗi và service/log nhận lỗi; hiện chưa có cơ chế tự giải phóng ổ theo ngưỡng |
| TC-E2E-06 | P1 | Suspend/Resume trên laptop/VM | Quan sát gián đoạn và resume; không mặc định cam kết video liên tục xuyên suspend |
| TC-E2E-07 | P1 | Mất điện hoặc `SIGKILL` FFmpeg trong VM | Các segment đã đóng vẫn đọc được; segment đang mở **không được bảo đảm** hợp lệ |
| TC-E2E-08 | P2 | So sánh CPU/RSS và GB/h khi desktop đứng yên vs thao tác liên tục | Có baseline và số liệu thực đo để quyết định bitrate/preset, không gán ngưỡng hiệu năng tùy tiện |

**Tổng cộng: 10 + 9 + 10 + 11 + 8 + 5 + 10 + 11 + 7 + 6 + 8 = 95 test cases.**

## 3. Lệnh hỗ trợ kiểm thử an toàn

### 3.1. Kiểm tra source, file cài đặt và systemd

```bash
# Từ thư mục dự án
for f in scripts/*.sh install.sh; do bash -n "$f" || exit 1; done
bash install.sh --dry-run

# Sau khi cài
systemctl --user status screenrec.service --no-pager
systemctl --user show screenrec.service -p ActiveState -p MainPID -p Restart
systemd-analyze --user verify "$HOME/.config/systemd/user/screenrec.service"
systemctl --user show-environment | grep -E '^(DISPLAY|XAUTHORITY|XDG_SESSION_TYPE)='
journalctl --user -u screenrec.service -n 100 --no-pager
pgrep -af 'record.sh|session-watch.sh|metrics.sh|ffmpeg'
```

### 3.2. Tạo **lab cleanup** tách khỏi video thật

Chỉ dùng file giả trong `$HOME`, không tạo/đụng vào video thật ở `/var/log/screenrecordings`:

```bash
LAB=$(mktemp -d "$HOME/screenrec-lab.XXXXXX")
chmod 700 "$LAB"
mkdir -m 700 "$LAB/videos"
cp /etc/screenrec/screenrec.conf "$LAB/screenrec.conf"
sed -i "s|^SCREENREC_DIR=.*|SCREENREC_DIR=\"$LAB/videos\"|" "$LAB/screenrec.conf"
chmod 600 "$LAB/screenrec.conf"

# Dữ liệu giả chỉ tồn tại trong lab
touch -d '11 days ago' "$LAB/videos/screen_old.mp4"
touch -d '9 days ago'  "$LAB/videos/screen_new.mp4"
touch -d '11 days ago' "$LAB/videos/other_old.mp4"

# Xem trước (không xóa)
/usr/local/libexec/screenrec/cleanup.sh --config "$LAB/screenrec.conf" --dry-run

# Chạy thật (CHỈ xóa file trong lab)
/usr/local/libexec/screenrec/cleanup.sh --config "$LAB/screenrec.conf"
test ! -e "$LAB/videos/screen_old.mp4"
test -e "$LAB/videos/screen_new.mp4"
test -e "$LAB/videos/other_old.mp4"
```

Không thực hiện `rm -rf` theo biến `$LAB` một cách mù quáng. Sau test, kiểm tra rõ đường dẫn trước khi xóa thủ công môi trường thử.

### 3.3. Ghi thử segment ngắn trong thư mục lab

Dừng service đang ghi nếu cần tránh chạy hai encoder trên cùng desktop. Chỉ thực hiện ở terminal XFCE/X11 của user ghi hình:

```bash
# Dùng LAB từ mục 3.2 (nếu chưa có, tạo lại trước)
sed -i 's/^SCREENREC_SEGMENT_SECONDS=.*/SCREENREC_SEGMENT_SECONDS=10/' "$LAB/screenrec.conf"
sed -i 's/^SCREENREC_METRICS_INTERVAL_SECONDS=.*/SCREENREC_METRICS_INTERVAL_SECONDS=5/' "$LAB/screenrec.conf"
/usr/local/libexec/screenrec/check-env.sh --config "$LAB/screenrec.conf"

/usr/local/libexec/screenrec/record.sh --config "$LAB/screenrec.conf" &
REC_PID=$!
sleep 27
kill -TERM "$REC_PID"
wait "$REC_PID"

find "$LAB/videos" -maxdepth 1 -type f -name 'screen_*.mp4' -print
find "$LAB/videos" -maxdepth 1 -type f -name 'screen_*.mp4' \
    -exec ffprobe -v error -show_entries format=duration \
          -of default=noprint_wrappers=1 {} \;
```

`wait` có thể trả mã khác 0 nếu FFmpeg lỗi; khi đó phải xem log và chạy kiểm tra file. Khi `record.sh` được khởi động dưới nền từ Shell, không đóng Terminal trước khi hoàn tất bài thử.

### 3.4. Kiểm tra dừng bình thường và Cron

```bash
systemctl --user stop screenrec.service
systemctl --user is-active screenrec.service # mong đợi inactive
sudo cat /etc/cron.d/screenrec-cleanup
sudo systemctl status cron --no-pager
journalctl -t screenrec-cleanup -n 50 --no-pager
```

Không dùng `kill -9` với service đang tạo video quan trọng. Đối với Cron, chỉ sửa giờ chạy trên **VM test** và phải khôi phục cấu hình chính xác sau khi kiểm tra.

## 4. Tiêu chí nghiệm thu dự kiến (Release Gate)

1. **100% P0 PASS trên ít nhất một máy Xubuntu/XFCE/X11 thật**; không còn lỗi phá hỏng hoặc xóa nhầm video trong các đường đi bình thường.
2. Các thử nghiệm `stop/logout/shutdown/reboot` đều tạo segment cuối đọc được bằng `ffprobe`/giải mã; không yêu cầu segment đang mở vẫn hợp lệ sau mất điện hoặc `SIGKILL`.
3. Retention vượt qua các test trước/sau 10 ngày, dry-run, loại trừ file khác mẫu và không làm ảnh hưởng segment đang ghi.
4. Có logs `START`, `STOP`, `PERF`, stderr FFmpeg (nếu lỗi), đủ dữ liệu phân tích khi có incident.
5. **P1 quan trọng về bảo mật, cài đặt lại và tự khởi động** phải PASS hoặc có tài liệu rủi ro được chấp nhận; P2 có thể đưa vào backlog.
6. Hiệu năng cần baseline theo từng máy (CPU/RAM, GB/giờ, FPS đo được); chưa áp chỉ tiêu CPU/RAM cố định nếu chưa đo thực tế.

## 5. Các giới hạn/mức rủi ro cần theo dõi khi test

- `check-env.sh` chỉ **cảnh báo** khi còn dưới 1 GiB dung lượng; chưa có quota hay cơ chế kiểm soát liên tục khi gần đầy.
- `metrics.sh` ghi CPU/RSS/disk, **chưa báo FPS tức thời**. Nếu helper này chết riêng, `record.sh` hiện **không restart nó tự động**.
- `session-watch.sh` dựa vào phiên `xfce4-session` xác định qua PID/starttime; multi-session không được hỗ trợ.
- Lock nằm trong `SCREENREC_DIR`, nên hai lần chạy với **hai thư mục khác nhau** không bị khóa chung; phạm vi chống trùng hiện là *một directory*, không phải toàn hệ thống/display.
- Tên file chứa timestamp + run_id, giảm va chạm qua restart, nhưng đổi đồng hồ lùi mạnh trong một lần ghi vẫn có thể tạo tên trùng.
- `cleanup.sh` dựa vào `mtime`, không phải thời điểm tạo (`birthtime`); file mở lâu, đồng hồ thay đổi, hoặc thao tác copy/restore có thể ảnh hưởng quy tắc xóa.
- Bộ cài không có **transactional rollback** toàn phần khi sự cố xảy ra giữa các bước.

## 6. Tài liệu tham chiếu

- [FFmpeg Segment Muxer](https://ffmpeg.org/ffmpeg-formats.html#segment)
- [FFmpeg x11grab](https://ffmpeg.org/ffmpeg-devices.html#x11grab)
- [systemd.kill(5)](https://www.man7.org/linux/man-pages/man5/systemd.kill.5.html)
- [systemd.service — TimeoutStopSec](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html)
- [GNU Findutils — Age Ranges](https://www.gnu.org/software/findutils/manual/html_node/find_html/Age-Ranges.html)
- [GNU Findutils — Delete](https://www.gnu.org/software/findutils/manual/html_node/find_html/Delete-Files.html)
- [cron(5)](https://man7.org/linux/man-pages/man5/crontab.5.html)
