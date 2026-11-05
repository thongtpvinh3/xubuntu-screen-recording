#!/usr/bin/env python3
"""Benchmark running screenrec until XFCE logout, or summarize a journal export."""

import argparse
import csv
from datetime import datetime
import hashlib
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


MARKER = re.compile(r"\[screenrec-metrics\]\s+(\S+)\s+PERF\s+(.*)$")
UNIT = "screenrec-cpu-bench.service"


def parse_display_state(output):
    """DPMS disabled/unsupported is unknown, never permission to count CPU."""
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


def process_sample(pid, proc_root=Path("/proc")):
    """Return (start ticks, CPU ticks, parent PID); reject dead/reused processes."""
    try:
        fields = (proc_root / str(pid) / "stat").read_text().rsplit(")", 1)[1].split()
        if fields[0] in ("Z", "X"):
            return None
        return int(fields[19]), int(fields[11]) + int(fields[12]), int(fields[1])
    except (OSError, ValueError, IndexError):
        return None


def same_process(pid, start):
    sample = process_sample(pid)
    return sample is not None and sample[0] == start


def command_output(command):
    result = subprocess.run(command, text=True, capture_output=True, timeout=5)
    if result.returncode:
        raise ValueError(result.stderr.strip() or f"Lệnh thất bại: {command[0]}")
    return result.stdout.strip()


def find_session():
    pids = command_output(["pgrep", "-u", str(os.getuid()), "-x", "xfce4-session"]).split()
    if len(pids) != 1:
        raise ValueError("Cần đúng một phiên XFCE của user hiện tại")
    pid = int(pids[0])
    sample = process_sample(pid)
    if sample is None:
        raise ValueError("Phiên XFCE đã kết thúc")
    return pid, sample[0]


def find_ffmpeg():
    """Only inspect descendants of this user's screenrec.service MainPID."""
    try:
        main_pid = int(command_output([
            "systemctl", "--user", "show", "screenrec.service", "--property=MainPID", "--value",
        ]))
    except ValueError:
        return None
    if main_pid <= 0:
        return None
    pending, visited, candidates = [main_pid], set(), []
    while pending:
        pid = pending.pop()
        if pid in visited:
            continue
        visited.add(pid)
        root = Path("/proc") / str(pid)
        try:
            if root.stat().st_uid != os.getuid():
                continue
            sample = process_sample(pid)
            if sample and (root / "comm").read_text().strip() == "ffmpeg":
                candidates.append((pid, sample))
            pending.extend(int(value) for value in
                           (root / "task" / str(pid) / "children").read_text().split())
        except (OSError, ValueError):
            continue
    if len(candidates) > 1:
        raise ValueError("Có nhiều FFmpeg thuộc recorder; không xác định được đối tượng đo")
    return candidates[0] if candidates else None


def atomic_write(path, content):
    """Checkpoint the report so terminal closure/SIGKILL cannot truncate the old one."""
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


def live_report(rows, started, reason, interval, scenario, context, missed, identities,
                display=None):
    display = display or {"state": "UNKNOWN", "off_checks": 0, "unknown_checks": 0,
                          "discarded_windows": 0}
    values = [row[3] for row in rows]
    elapsed = sum(row[2] for row in rows)
    mean = sum(row[2] * row[3] for row in rows) / elapsed if rows else None
    p95 = sorted(values)[math.ceil(.95 * len(values)) - 1] if rows else None
    maximum = max(values) if rows else None
    cell = lambda value: str(value).replace("|", "\\|").replace("\n", " ").replace("\r", " ")
    format_cpu = lambda value: "Chưa đủ dữ liệu" if value is None else f"{value:.2f}%"
    quality = "Đủ tối thiểu 20 mẫu" if len(rows) >= 20 else "Chưa đủ 20 mẫu; P95 chỉ mang tính tham khảo"
    return f"""# Báo cáo benchmark CPU — đo đến khi logout

| Nội dung | Giá trị |
|---|---|
| Trạng thái / lý do kết thúc | {cell(reason)} |
| Bắt đầu | {started} |
| Cập nhật gần nhất | {datetime.now().astimezone().isoformat()} |
| Kịch bản | {cell(scenario)} |
| Môi trường / cấu hình | {cell(context)} |
| Chu kỳ mục tiêu | {interval} giây |
| Số mẫu | {len(rows)} |
| Tổng thời gian có mẫu CPU | {elapsed:.2f} giây |
| Lần không lấy được mẫu (không gán CPU=0) | {missed} |
| Số instance FFmpeg đã quan sát | {len(identities)} |
| Trạng thái màn hình quan sát gần nhất | {display['state']} |
| Số lần quan sát màn hình tắt | {display['off_checks']} |
| Số lần không xác định được trạng thái màn hình | {display['unknown_checks']} |
| Số cửa sổ CPU bị hủy do OFF/UNKNOWN | {display['discarded_windows']} |
| Đánh giá dữ liệu | {quality} |

| Chỉ số | Giá trị |
|---|---:|
| CPU trung bình | {format_cpu(mean)} |
| CPU P95 | {format_cpu(p95)} |
| CPU cao nhất trong các mẫu | {format_cpu(maximum)} |

- Đọc CPU time từ `/proc/PID/stat` của FFmpeg thuộc `screenrec.service`.
- CPU mỗi mẫu = 100 × delta CPU ticks / CLK_TCK / delta monotonic time.
- CPU trung bình có trọng số theo thời gian thực tế của từng mẫu.
- P95 dùng nearest rank trên các mẫu; cao nhất là đỉnh trung bình theo khoảng.
- 100% tương ứng một logical CPU; không gồm CPU wrapper/helper/toàn máy.
- PID kèm starttime để phân biệt instance; không nối delta CPU qua restart.
- Chỉ thống kê thời gian FFmpeg đo được; khoảng dừng/restart không được gán 0%.
- Chỉ nhận mẫu khi DPMS là ON trong các lần kiểm tra của cửa sổ đo.
  OFF/Standby/Suspend hoặc UNKNOWN hủy baseline; khi bật lại lấy baseline mới.
  Mẫu bị loại không đưa vào trung bình, P95, cao nhất hoặc CSV; không gán 0%.
- Kiểm tra DPMS khoảng mỗi giây và trước/sau đọc CPU. Polling có thể bỏ sót
  chuyển trạng thái rất ngắn; không bảo đảm phát hiện mọi chuyển đổi dưới 1 giây.
- DPMS không phân biệt nguyên nhân tự tắt/thủ công: loại cả hai. Không phát hiện
  chắc chắn nút nguồn vật lý, screensaver chỉ làm đen hình hoặc trạng thái từng
  màn hình riêng trong hệ nhiều màn hình. Không suy ra trạng thái từ việc idle.
- Không tự warm-up; đo từ khi worker chạy. Không phụ thuộc chu kỳ metrics của recorder.
- Mẫu cuối có thể cách logout dưới một chu kỳ; không nội suy khoảng chưa đo.
- Report cập nhật sau mỗi mẫu. Nếu bị SIGKILL/mất điện, checkpoint có thể còn
  trạng thái đang đo; không được hiểu checkpoint đó là báo cáo logout hoàn tất.
- CSV cùng tên lưu các mẫu thô. Chưa có ngưỡng để kết luận đạt/chưa đạt.
"""


def collect_live(args):
    import fcntl  # Linux only; offline aggregation remains cross-platform.

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.with_suffix(".lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("Đã có benchmark ghi vào báo cáo này") from error
        return collect_locked(args)


def collect_locked(args):
    stopped = threading.Event()
    received = []

    def stop(signum, _frame):
        received.append(signum)
        stopped.set()

    previous_handlers = {}
    signals = [signal.SIGTERM, signal.SIGINT]
    if hasattr(signal, "SIGHUP"):
        signals.append(signal.SIGHUP)
    for signum in signals:
        previous_handlers[signum] = signal.signal(signum, stop)
    rows, identities, missed = [], set(), 0
    reason = "Đang đo"
    started = datetime.now().astimezone().isoformat()
    clk_tck = os.sysconf("SC_CLK_TCK")
    baseline = None
    display = {"state": "UNKNOWN", "off_checks": 0, "unknown_checks": 0,
               "discarded_windows": 0}

    def observe_display():
        nonlocal baseline
        state = display_state()
        if state != display["state"]:
            print(f"DISPLAY_STATE={state}", flush=True)
        display["state"] = state
        if state != "ON":
            key = "off_checks" if state == "OFF" else "unknown_checks"
            display[key] += 1
            if baseline is not None:
                display["discarded_windows"] += 1
                baseline = None
        return state

    def checkpoint():
        atomic_write(args.output, live_report(rows, started, reason, args.interval,
                                             args.scenario, args.context, missed, identities, display))

    try:
        checkpoint()
        with args.output.with_suffix(".csv").open("w", newline="", encoding="utf-8") as stream:
            writer = csv.writer(stream)
            writer.writerow(["timestamp", "ffmpeg_pid", "elapsed_seconds", "cpu_pct", "start_ticks",
                             "display_state"])
            while same_process(args.session_pid, args.session_start) and not stopped.is_set():
                screen_on = observe_display() == "ON"
                current = find_ffmpeg() if screen_on else None
                now = time.monotonic()
                if current is None:
                    baseline = None
                    if screen_on:
                        missed += 1
                else:
                    pid, sample = current
                    identity = (pid, sample[0])
                    identities.add(identity)
                    # Recheck after the process lookup; an OFF during lookup
                    # invalidates the whole CPU window, not just its endpoint.
                    still_on = observe_display() == "ON"
                    if still_on and baseline is not None and baseline[0] == identity:
                        elapsed, ticks = now - baseline[2], sample[1] - baseline[1]
                        if elapsed > 0 and ticks >= 0:
                            row = (datetime.now().astimezone().isoformat(), pid, elapsed,
                                   100 * ticks / clk_tck / elapsed, sample[0])
                            rows.append(row)
                            writer.writerow((*row, "ON"))
                            stream.flush()
                    baseline = (identity, sample[1], now) if still_on else None
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
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)


def launch_live(args):
    if sys.platform != "linux" or not Path("/proc/self/stat").exists():
        raise ValueError("Chế độ đo trực tiếp yêu cầu Linux/Xubuntu với /proc")
    if os.getuid() == 0:
        raise ValueError("Chạy bằng user desktop đang ghi hình, không dùng sudo")
    session_pid, session_start = find_session()
    target = find_ffmpeg()
    if target is None:
        raise ValueError("screenrec.service chưa có FFmpeg đang chạy")
    desktop_display = os.environ.get("DISPLAY", "")
    if not desktop_display or display_state() == "UNKNOWN":
        raise ValueError("Không đọc được DPMS. Chạy trong XFCE/X11, kiểm tra DISPLAY/XAUTHORITY "
                         "và xset -q (DPMS phải Enabled; xset thuộc x11-xserver-utils)")
    args.output = args.output.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Check destination permissions before starting the background service.
    with tempfile.TemporaryFile(dir=args.output.parent):
        pass
    if not args.context:
        cpu_info = Path("/proc/cpuinfo").read_text()
        model = next((line.split(":", 1)[1].strip() for line in cpu_info.splitlines()
                      if line.startswith("model name")), platform.machine())
        ffmpeg_command = (Path("/proc") / str(target[0]) / "cmdline").read_bytes()
        args.context = (f"CPU={model}; logical CPUs={os.cpu_count()}; kernel={platform.release()}; "
                        f"FFmpeg command={ffmpeg_command.replace(bytes([0]), b' ').decode(errors='replace')}")
    command_output([
        "systemd-run", "--user", f"--unit={UNIT}", "--collect", "--service-type=exec",
        f"--setenv=DISPLAY={desktop_display}",
        f"--setenv=XAUTHORITY={os.environ.get('XAUTHORITY', '')}",
        "--property=TimeoutStopSec=10s", "--", sys.executable, str(Path(__file__).resolve()),
        "--worker", "--session-pid", str(session_pid), "--session-start", str(session_start),
        "--interval", str(args.interval), "--output", str(args.output),
        "--scenario", args.scenario, "--context", args.context,
    ])
    print(f"Đã chạy benchmark nền đến khi logout. Báo cáo: {args.output}")
    print(f"Theo dõi: journalctl --user -u {UNIT} -f")
    print(f"Dừng sớm: systemctl --user stop {UNIT}")


def summarize(log):
    samples = []
    starts = 0
    for line_number, line in enumerate(log.splitlines(), 1):
        if "[screenrec-metrics]" in line and " START " in line:
            starts += 1
        if "[screenrec-metrics]" not in line or " PERF " not in line:
            continue
        match = MARKER.search(line)
        if not match:
            raise ValueError(f"Dòng {line_number}: log PERF sai định dạng")
        try:
            timestamp = datetime.fromisoformat(match[1])
            fields = dict(item.split("=", 1) for item in match[2].split())
            pid = int(fields["ffmpeg_pid"])
            cpu = float(fields["cpu_interval_pct"])
            interval = int(fields["interval_seconds"])
            if (timestamp.utcoffset() is None or pid <= 0 or interval <= 0
                    or not math.isfinite(cpu) or cpu < 0):
                raise ValueError("giá trị không hợp lệ")
        except (KeyError, ValueError) as error:
            raise ValueError(f"Dòng {line_number}: mẫu PERF không hợp lệ ({error})") from error
        samples.append((timestamp, pid, cpu, interval))
    if len(samples) < 20:
        raise ValueError("Cần ít nhất 20 mẫu PERF hợp lệ; khuyến nghị đo 30 phút ở chu kỳ 5 giây")
    if starts > 1 or len({item[1] for item in samples}) != 1:
        raise ValueError("Có restart/đổi PID FFmpeg; hãy đo lại một phiên liên tục")
    if len({item[3] for item in samples}) != 1:
        raise ValueError("Chu kỳ lấy mẫu thay đổi; hãy tách các lượt benchmark")
    interval = samples[0][3]
    for previous, current in zip(samples, samples[1:]):
        gap = (current[0] - previous[0]).total_seconds()
        if gap <= 0 or gap > interval * 2:
            raise ValueError("Timestamp trùng/đảo thứ tự hoặc khoảng trống lớn hơn hai chu kỳ")
    values = [item[2] for item in samples]
    return {
        "count": len(values), "pid": samples[0][1], "interval": interval,
        "first": samples[0][0].isoformat(), "last": samples[-1][0].isoformat(),
        "span": (samples[-1][0] - samples[0][0]).total_seconds(),
        "mean": statistics.fmean(values),
        "p95": sorted(values)[math.ceil(0.95 * len(values)) - 1],
        "maximum": max(values),
    }


def render(result, source, digest, scenario, context):
    def cell(value):
        return str(value).replace("|", "\\|").replace("\r", " ").replace("\n", " ")

    return f"""# Báo cáo benchmark CPU

Trạng thái: đã tổng hợp dữ liệu đo từ log; không tự kết luận đạt/chưa đạt.

**Chế độ offline không lọc màn hình tắt vì log PERF không có trạng thái DPMS.
Không dùng báo cáo này để đánh giá CPU chỉ trong thời gian màn hình bật.**

## Điều kiện đo

| Nội dung | Giá trị |
|---|---|
| Kịch bản | {cell(scenario)} |
| Môi trường và cấu hình | {cell(context)} |
| Dữ liệu đầu vào | {cell(source)} |
| SHA-256 log | `{digest}` |
| PID FFmpeg | {result['pid']} |
| Số mẫu | {result['count']} |
| Chu kỳ cấu hình | {result['interval']} giây |
| Timestamp mẫu đầu | {result['first']} |
| Timestamp mẫu cuối | {result['last']} |
| Khoảng thời gian giữa mẫu đầu/cuối | {result['span']:.0f} giây |

## Kết quả

| Chỉ số | Giá trị |
|---|---:|
| CPU trung bình | {result['mean']:.2f}% |
| CPU P95 | {result['p95']:.2f}% |
| CPU cao nhất trong các mẫu | {result['maximum']:.2f}% |

## Phương pháp và giới hạn

- Nguồn: `cpu_interval_pct` do `scripts/metrics.sh` ghi vào journal.
- Mỗi mẫu = 100 × chênh lệch CPU time / thời gian thực của khoảng lấy mẫu.
- 100% tương ứng một logical CPU; kết quả có thể vượt 100%.
- Trung bình = tổng giá trị các mẫu / số mẫu, không phải trung bình có trọng số thời gian.
- P95 dùng nearest rank: sắp xếp tăng dần, lấy phần tử thứ ceil(0.95 × N).
- Cao nhất là giá trị lớn nhất của các khoảng lấy mẫu, không phải đỉnh tức thời.
- Chỉ đo FFmpeg, không bao gồm wrapper, helper, cleanup hoặc CPU toàn máy.
- Khoảng giữa timestamp đầu/cuối không bao gồm thời gian của mẫu đầu.
- Log đã làm tròn CPU tới một chữ số thập phân; hai chữ số trong bảng chỉ là định dạng.
- Công cụ kiểm tra tối thiểu 20 mẫu, một PID, chu kỳ cố định và không có khoảng trống lớn.
  Các kiểm tra này không chứng minh log đầy đủ hoặc loại trừ mọi trường hợp tái sử dụng PID.
- Quy trình chuẩn bị và xuất log: xem `benchmark/cpu/README.md`.
"""


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, help="Offline UNFILTERED journal export; omit for screen-aware live mode")
    parser.add_argument("--scenario", default="Ghi hình phiên desktop đến khi logout")
    parser.add_argument("--context", default="", help="CPU/OS/VM, resolution, recorder settings")
    parser.add_argument("--output", type=Path, default=Path(__file__).with_name("cpu-bench.md"))
    parser.add_argument("--interval", type=float, default=5, help="Live sampling interval in seconds (1-3600)")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--session-pid", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--session-start", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        if not math.isfinite(args.interval) or not 1 <= args.interval <= 3600:
            raise ValueError("Chu kỳ benchmark phải nằm trong 1–3600 giây")
        if args.worker:
            if args.input or not args.session_pid or args.session_start is None:
                raise ValueError("Thiếu thông tin phiên cho worker")
            if not os.environ.get("XAUTHORITY"):
                os.environ.pop("XAUTHORITY", None)
            collect_live(args)
            return
        if args.input is None:
            launch_live(args)
            return
        raw = args.input.read_bytes()
        result = summarize(raw.decode("utf-8-sig"))
        report = render(result, args.input, hashlib.sha256(raw).hexdigest(), args.scenario, args.context)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report, encoding="utf-8")
    except (OSError, UnicodeError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Không tạo báo cáo: {error}\n")
    print(f"Đã ghi {args.output} ({result['count']} mẫu)")


if __name__ == "__main__":
    main()
