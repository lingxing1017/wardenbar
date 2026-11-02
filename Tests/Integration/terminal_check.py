#!/usr/bin/env python3
"""Synthetic PTY checks for the local password prompt. Never use real credentials here."""
import errno
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time

binary = str(Path(sys.argv[1]).resolve())
source = Path(__file__).resolve().parents[1] / "WardenBarCoreTests/Fixtures/bw-fixture"


def setup(root):
    fixture = root / "bw"
    shutil.copyfile(source, fixture)
    fixture.chmod(0o700)
    data = root / "CLI"
    data.mkdir(mode=0o700)
    return [binary, "--exercise", "--cli", str(fixture), "--data-dir", str(data)], data


def check_pty(name, password=None, interrupt=None, delayed=False, piped=False):
    with tempfile.TemporaryDirectory(prefix="wardenbar-pty-") as directory:
        args, data = setup(Path(directory))
        if delayed:
            (data / "delay-sync").touch()
        pid, master = pty.fork()
        if pid == 0:
            if piped:
                read_end, write_end = os.pipe()
                os.write(write_end, b"synthetic-master\n")
                os.close(write_end)
                os.dup2(read_end, 0)
                os.close(read_end)
            os.execv(binary, args)
        transcript = bytearray()
        initial_flags = termios.tcgetattr(master)
        prompted = False
        sent_signal = False
        status = None
        deadline = time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.02)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        chunk = b""
                    transcript.extend(chunk)
                if b"Master password (hidden): " in transcript and not prompted:
                    assert not (termios.tcgetattr(master)[3] & termios.ECHO), "Password echo was enabled"
                    prompted = True
                    if password is not None:
                        os.write(master, password + b"\n")
                    elif interrupt:
                        if interrupt == signal.SIGINT:
                            os.write(master, b"\x03")
                        else:
                            os.kill(pid, interrupt)
                        sent_signal = True
                if delayed and prompted and not sent_signal and (data / "sync-started").exists():
                    if interrupt == signal.SIGINT:
                        os.write(master, b"\x03")
                    else:
                        os.kill(pid, interrupt)
                    sent_signal = True
                finished, current = os.waitpid(pid, os.WNOHANG | os.WUNTRACED)
                if finished:
                    if os.WIFSTOPPED(current):
                        raise AssertionError(f"PTY child stopped by signal {os.WSTOPSIG(current)}")
                    status = current
                    while select.select([master], [], [], 0)[0]:
                        try:
                            remaining = os.read(master, 65536)
                        except OSError as error:
                            if error.errno != errno.EIO:
                                raise
                            break
                        if not remaining:
                            break
                        transcript.extend(remaining)
                    break
            assert status is not None, f"PTY check timed out: synthetic transcript={bytes(transcript)!r}, markers={sorted(p.name for p in data.iterdir())}"
            assert prompted != piped, f"Unexpected prompt state: status={status}, synthetic transcript={bytes(transcript)!r}"
            assert termios.tcgetattr(master) == initial_flags, "Terminal settings were not restored"
            assert b"synthetic-master" not in transcript, "Synthetic password was echoed"
            assert b"secret" not in transcript, "Vault content was printed"
            assert os.WIFEXITED(status), "Command exited from a signal without cleanup"
            code = os.WEXITSTATUS(status)
            if piped:
                assert code == 1
                assert not (data / "unlock-started").exists()
            elif interrupt:
                assert code == 130, "Cancellation did not return exit 130"
                if delayed:
                    assert (data / "lock-called").exists(), "Interrupted workflow did not lock"
                    assert b"Lock: passed" in transcript, "No confirmed lock after interruption"
            elif not password or len(password) >= 1023:
                assert code == 1, "Invalid password input was not rejected"
                assert not (data / "unlock-started").exists(), "Invalid input reached unlock"
            else:
                assert code == 0, "Synthetic workflow failed"
                assert b"Check: passed" in transcript
                assert (data / "lock-called").exists()
            print(f"{name}: passed")
        finally:
            if status is None:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            os.close(master)


with tempfile.TemporaryDirectory(prefix="wardenbar-no-tty-") as directory:
    args, data = setup(Path(directory))
    result = subprocess.run(args, input=b"synthetic-master\n", capture_output=True, start_new_session=True, timeout=10)
    assert result.returncode == 1, "Piped password was not rejected without a controlling TTY"
    assert not (data / "unlock-started").exists()
    assert b"synthetic-master" not in result.stdout + result.stderr
    print("non-TTY password rejection: passed")

check_pty("hidden input and restoration", password=b"synthetic-master")
check_pty("pipe rejected even with controlling terminal", piped=True)
check_pty("UTF-8 backspace", password=b"synthetic-maste" + "错".encode() + b"\x7fr")
check_pty("line erase", password=b"discarded\x15synthetic-master")
check_pty("empty input rejection", password=b"")
check_pty("oversized input rejection", password=b"x" * 1100)
check_pty("Ctrl+C during input", interrupt=signal.SIGINT)
check_pty("Ctrl+C during sync cleanup", password=b"synthetic-master", interrupt=signal.SIGINT, delayed=True)
check_pty("SIGTERM during sync cleanup", password=b"synthetic-master", interrupt=signal.SIGTERM, delayed=True)
