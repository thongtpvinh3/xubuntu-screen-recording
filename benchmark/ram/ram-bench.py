#!/usr/bin/env python3
"""Measure FFmpeg RSS while the X11 display is on, until the XFCE session ends.

Standalone, Python standard library only. Run without sudo from XFCE:
    python3 benchmark/ram/ram-bench.py
"""

import argparse
import csv
from datetime import datetime
import math
import os
from pathlib import Path
import platform
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time


UNIT = "screenrec-ram-bench.service"


def command_output(command):
    result = subprocess.run(command, text=True, capture_output=True, timeout=5)
    if result.returncode:
        raise ValueError(result.stderr.strip() or f"Lệnh thất bại: {command[0]}")
    return result.stdout.strip()


def parse_display_state(output):
    if not re.search(r"\bDPMS is Enabled\b", output, re.IGNORECASE):
        return "UNKNOWN"
    match = re.search(r"\bMonitor is (On|Off|Standby|Suspend)\b", output, re.IGNORECASE)
    if match is None:
        return "UNKNOWN"
    return "ON" if match[1].lower() == "on" else "OFF"


def display_state():
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    try:
        result = subprocess.run(["xset", "-q"], env=environment, text=True,
                                capture_output=True, timeout=2)
        return parse_display_state(result.stdout) if result.returncode == 0 else "UNKNOWN"
    except (OSError, UnicodeError, subprocess.SubprocessError):
        return "UNKNOWN"


def process_identity(pid, proc_root=Path("/proc")):
    try:
        fields = (proc_root / str(pid) / "stat").read_text().rsplit(")", 1)[1].split()
        return int(fields[19]) if fields[0] not in ("Z", "X") else None
    except (OSError, ValueError, IndexError):
        return None


def same_process(pid, start):
    return process_identity(pid) == start


def read_rss(pid, start, proc_root=Path("/proc")):
    """RSS in KiB, with identity checks on both sides of the proc read.

    Never use VmHWM: its lifetime peak could include screen-off periods.
    """
    if process_identity(pid, proc_root) != start:
        return None
    try:
        status = (proc_root / str(pid) / "status").read_text()
    except OSError:
        return None
    match = re.search(r"^VmRSS:\s+(\d+)\s+kB\s*$", status, re.MULTILINE)
    if match is None or process_identity(pid, proc_root) != start:
        return None
    return int(match[1])


def find_session():
    pids = command_output(["pgrep", "-u", str(os.getuid()), "-x", "xfce4-session"]).split()
    if len(pids) != 1:
        raise ValueError("Cần đúng một phiên XFCE của user hiện tại")
    pid = int(pids[0])
    start = process_identity(pid)
    if start is None:
        raise ValueError("Phiên XFCE đã kết thúc")
    return pid, start


def find_ffmpeg():
    """Find FFmpeg only within the current user's screenrec.service tree."""
    try:
        main_pid = int(command_output([
            "systemctl", "--user", "show", "screenrec.service", "--property=MainPID", "--value",
        ]))
    except ValueError:
        return None
    if main_pid <= 0:
        return None
    pending, visited, found = [main_pid], set(), []
    while pending:
        pid = pending.pop()
        if pid in visited:
            continue
        visited.add(pid)
        root = Path("/proc") / str(pid)
        try:
            if root.stat().st_uid != os.getuid():
                continue
            start = process_identity(pid)
            if start is not None and (root / "comm").read_text().strip() == "ffmpeg":
                found.append((pid, start))
            pending.extend(int(value) for value in
                           (root / "task" / str(pid) / "children").read_text().split())
        except (OSError, ValueError):
            continue
    if len(found) > 1:
        raise ValueError("Có nhiều FFmpeg trong service; không xác định được đối tượng đo")
    return found[0] if found else None


def summarize(rows):
    values = [row[2] for row in rows]
    if not values:
        return None
    return {
        "mean": statistics.fmean(values) / 1024,
        "p95": sorted(values)[math.ceil(.95 * len(values)) - 1] / 1024,
        "maximum": max(values) / 1024,
    }


def atomic_write(path, content):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def render(rows, started, reason, args, counters, identities):
    result = summarize(rows)
    def cell(value):
        return str(value).replace("|", "\\|").replace("\r", " ").replace("\n", " ")
    def value(key):
        return "Chưa đủ dữ liệu" if result is None else f"{result[key]:.2f} MiB"
    quality = "Đủ tối thiểu 20 mẫu" if len(rows) >= 20 else "Dưới 20 mẫu; P95 chỉ mang tính tham khảo"
    return f"""# Báo cáo benchmark RAM — chỉ khi màn hình bật

| Nội dung | Giá trị |
|---|---|
| Trạng thái / lý do kết thúc | {cell(reason)} |
| Bắt đầu | {started} |
| Cập nhật | {datetime.now().astimezone().isoformat()} |
| Kịch bản | {cell(args.scenario)} |
| Môi trường / cấu hình | {cell(args.context)} |
| Chu kỳ lấy mẫu mục tiêu | {args.interval} giây |
| Số mẫu hợp lệ | {len(rows)} |
| Timestamp mẫu đầu | {rows[0][0] if rows else 'Chưa có'} |
| Timestamp mẫu cuối | {rows[-1][0] if rows else 'Chưa có'} |
| Màn hình quan sát gần nhất | {counters['state']} |
| Số lượt lấy mẫu bị loại do OFF/UNKNOWN | {counters['excluded']} |
| Số lượt không có FFmpeg/RSS hợp lệ | {counters['missing']} |
| Số instance FFmpeg quan sát được | {len(identities)} |
| Đánh giá dữ liệu | {quality} |

| Chỉ số | Giá trị |
|---|---:|
| RAM RSS trung bình | {value('mean')} |
| RAM RSS P95 | {value('p95')} |
| RAM RSS cao nhất trong các mẫu | {value('maximum')} |

- Nguồn: VmRSS từ `/proc/PID/status`, đổi KiB sang MiB bằng cách chia 1024.
- Chỉ FFmpeg thuộc `screenrec.service`, không gồm wrapper/helper/benchmark hoặc RAM toàn máy.
- Trung bình cộng các snapshot hợp lệ; P95 nearest rank; cao nhất là max snapshot.
- Không dùng VmHWM: đỉnh tích lũy của tiến trình có thể xảy ra lúc màn hình tắt.
- Chỉ nhận snapshot khi DPMS ON trước/sau đọc RSS và PID/starttime còn khớp.
- OFF/Standby/Suspend hoặc UNKNOWN: bỏ mẫu, không ghi CSV, không gán RAM=0.
- RSS là snapshot, không có delta/baseline như CPU; bật lại chỉ lấy snapshot mới.
- RSS gồm cả trang chia sẻ; không phải bộ nhớ riêng hay PSS. VmRSS là ước lượng
  của kernel; có thể khác smaps_rollup. Không suy ra memory leak từ một đỉnh RSS.
- Polling khoảng 1 giây cộng thời gian truy vấn; có thể bỏ sót chuyển đổi rất ngắn.
- DPMS không phân biệt tự tắt/thủ công. Không bảo đảm phát hiện screensaver chỉ
  làm đen hình, nút nguồn vật lý hoặc trạng thái từng màn hình riêng.
- Không nội suy các khoảng tắt màn hình, không tự warm-up và không sửa recorder.
- Báo cáo checkpoint được thay nguyên tử. SIGKILL/mất điện có thể để lại trạng
  thái đang đo; đó không phải xác nhận đã kết thúc logout bình thường.
- CSV cùng tên chỉ chứa snapshot được chấp nhận. Chưa có ngưỡng đạt/chưa đạt.
"""


def collect_locked(args):
    stopped = threading.Event()
    received = []
    rows, identities = [], set()
    counters = {"state": "UNKNOWN", "excluded": 0, "missing": 0}
    started = datetime.now().astimezone().isoformat()
    reason = "Đang đo"
    previous = {}

    def stop(signum, _frame):
        received.append(signum)
        stopped.set()

    def observe_display():
        state = display_state()
        if state != counters["state"]:
            print(f"DISPLAY_STATE={state}", flush=True)
        counters["state"] = state
        return state

    def checkpoint():
        atomic_write(args.output, render(rows, started, reason, args, counters, identities))

    signals = [signal.SIGTERM, signal.SIGINT]
    if hasattr(signal, "SIGHUP"):
        signals.append(signal.SIGHUP)
    for signum in signals:
        previous[signum] = signal.signal(signum, stop)
    try:
        checkpoint()
        with args.output.with_suffix(".csv").open("w", newline="", encoding="utf-8") as stream:
            writer = csv.writer(stream)
            writer.writerow(["timestamp", "ffmpeg_pid", "rss_kib", "start_ticks", "rss_mib", "display_state"])
            stream.flush()
            while same_process(args.session_pid, args.session_start) and not stopped.is_set():
                if observe_display() != "ON":
                    counters["excluded"] += 1
                else:
                    target = find_ffmpeg()
                    rss = None
                    if target is not None:
                        identities.add(target)
                        rss = read_rss(*target)
                    if observe_display() != "ON":
                        counters["excluded"] += 1
                    elif rss is None:
                        counters["missing"] += 1
                    elif not stopped.is_set() and same_process(args.session_pid, args.session_start):
                        pid, start = target
                        row = (datetime.now().astimezone().isoformat(), pid, rss, start)
                        rows.append(row)
                        writer.writerow((*row, f"{rss / 1024:.6f}", "ON"))
                        stream.flush()
                checkpoint()
                deadline = time.monotonic() + args.interval
                while not stopped.is_set() and same_process(args.session_pid, args.session_start):
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    stopped.wait(min(1, remaining))
                    observe_display()
            if not same_process(args.session_pid, args.session_start):
                reason = "Hoàn tất: phiên XFCE đã kết thúc (logout)"
            elif received:
                reason = f"Đã dừng bởi signal {received[-1]} (có thể user manager đang kết thúc)"
    except Exception as error:
        reason = f"Lỗi thu thập: {error}"
        raise
    finally:
        try:
            checkpoint()
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)


def collect(args):
    import fcntl

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.with_suffix(".lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("Đã có benchmark ghi vào báo cáo này") from error
        collect_locked(args)


def launch(args):
    if sys.platform != "linux" or not Path("/proc/self/stat").exists():
        raise ValueError("Cần Linux/Xubuntu với /proc")
    if os.getuid() == 0:
        raise ValueError("Chạy bằng user desktop đang ghi hình, không dùng sudo")
    session_pid, session_start = find_session()
    target = find_ffmpeg()
    if target is None:
        raise ValueError("screenrec.service chưa có FFmpeg đang chạy")
    if read_rss(*target) is None:
        raise ValueError("Không đọc được VmRSS của FFmpeg; kiểm tra quyền truy cập /proc")
    display = os.environ.get("DISPLAY", "")
    if not display or display_state() == "UNKNOWN":
        raise ValueError("Không đọc được DPMS. Kiểm tra xset -q, DISPLAY/XAUTHORITY; "
                         "DPMS phải Enabled. xset thuộc gói x11-xserver-utils")
    args.output = args.output.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryFile(dir=args.output.parent):
        pass
    if not args.context:
        mem_total = next((line.strip() for line in Path("/proc/meminfo").read_text().splitlines()
                          if line.startswith("MemTotal:")), "MemTotal: unknown")
        cmdline = (Path("/proc") / str(target[0]) / "cmdline").read_bytes()
        args.context = (f"kernel={platform.release()}; {mem_total}; "
                        f"FFmpeg command={cmdline.replace(bytes([0]), b' ').decode(errors='replace')}")
    command_output([
        "systemd-run", "--user", f"--unit={UNIT}", "--collect", "--service-type=exec",
        f"--setenv=DISPLAY={display}", f"--setenv=XAUTHORITY={os.environ.get('XAUTHORITY', '')}",
        "--property=TimeoutStopSec=10s", "--", sys.executable, str(Path(__file__).resolve()),
        "--worker", "--session-pid", str(session_pid), "--session-start", str(session_start),
        "--interval", str(args.interval), "--output", str(args.output),
        "--scenario", args.scenario, "--context", args.context,
    ])
    print(f"Đã chạy benchmark RAM nền đến khi logout. Báo cáo: {args.output}")
    print(f"Theo dõi: journalctl --user -u {UNIT} -f")
    print(f"Dừng sớm: systemctl --user stop {UNIT}")


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interval", type=float, default=5, help="Snapshot interval, seconds (1-3600)")
    parser.add_argument("--output", type=Path, default=Path(__file__).with_name("ram-bench.md"))
    parser.add_argument("--scenario", default="Ghi hình phiên desktop đến khi logout")
    parser.add_argument("--context", default="")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--session-pid", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--session-start", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        if not math.isfinite(args.interval) or not 1 <= args.interval <= 3600:
            raise ValueError("Chu kỳ phải nằm trong 1–3600 giây")
        if args.worker:
            if not args.session_pid or args.session_start is None:
                raise ValueError("Thiếu thông tin phiên cho worker")
            if not os.environ.get("XAUTHORITY"):
                os.environ.pop("XAUTHORITY", None)
            collect(args)
        else:
            launch(args)
    except (OSError, UnicodeError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Không chạy được benchmark RAM: {error}\n")


if __name__ == "__main__":
    main()
