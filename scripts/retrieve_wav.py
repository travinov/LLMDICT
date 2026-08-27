#!/usr/bin/env python3
"""Download the latest finalized WAV from the XIAO over USB CDC."""

from __future__ import annotations

import argparse
import fcntl
import os
from pathlib import Path
import re
import select
import struct
import sys
import termios
import time
import tty


MARKER = re.compile(rb"WAV_BEGIN ([0-9]+)\r?\n")


def wait_readable(fd: int, deadline: float) -> None:
    remaining = deadline - time.monotonic()
    if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
        raise TimeoutError("timeout while waiting for the recorder")


def read_chunk(fd: int, deadline: float) -> bytes:
    while True:
        wait_readable(fd, deadline)
        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            continue
        if chunk:
            return chunk


def receive_wav(fd: int, timeout: float) -> bytes:
    deadline = time.monotonic() + timeout
    pending = bytearray()
    while True:
        pending.extend(read_chunk(fd, deadline))
        match = MARKER.search(pending)
        if match:
            wav_size = int(match.group(1))
            if wav_size < 44 or wav_size > 2 * 1024 * 1024:
                raise ValueError(f"device reported invalid WAV size: {wav_size}")
            payload = bytearray(pending[match.end() :])
            break
        if b"ERROR:" in pending:
            line = bytes(pending).decode("utf-8", errors="replace").strip()
            raise RuntimeError(line)
        if len(pending) > 65536:
            del pending[:-4096]

    while len(payload) < wav_size:
        payload.extend(read_chunk(fd, deadline))
    return bytes(payload[:wav_size])


def validate_wav(data: bytes) -> float:
    if len(data) < 44:
        raise ValueError("download is shorter than a WAV header")
    if data[0:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("download does not contain a RIFF/WAVE header")
    if data[12:16] != b"fmt " or data[36:40] != b"data":
        raise ValueError("unexpected WAV chunk layout")

    riff_size = struct.unpack_from("<I", data, 4)[0]
    audio_format, channels = struct.unpack_from("<HH", data, 20)
    sample_rate = struct.unpack_from("<I", data, 24)[0]
    bits_per_sample = struct.unpack_from("<H", data, 34)[0]
    data_size = struct.unpack_from("<I", data, 40)[0]
    if riff_size + 8 != len(data) or data_size + 44 != len(data):
        raise ValueError("WAV length fields do not match the download")
    if (audio_format, channels, sample_rate, bits_per_sample) != (1, 1, 16000, 16):
        raise ValueError(
            "unexpected WAV format: "
            f"format={audio_format}, channels={channels}, "
            f"rate={sample_rate}, bits={bits_per_sample}"
        )
    return data_size / 32000.0


def configure_serial(fd: int) -> None:
    tty.setraw(fd, when=termios.TCSANOW)
    attributes = termios.tcgetattr(fd)
    attributes[4] = termios.B115200
    attributes[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, attributes)
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)


def drain_input(fd: int) -> None:
    while select.select([fd], [], [], 0)[0]:
        os.read(fd, 4096)


def default_output() -> Path:
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    return Path("recordings") / f"recording-{timestamp}.wav"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("port", help="USB CDC port, for example /dev/cu.usbmodem101")
    parser.add_argument("output", nargs="?", type=Path, default=default_output())
    parser.add_argument("--timeout", type=float, default=30.0)
    arguments = parser.parse_args()

    fd = os.open(arguments.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        configure_serial(fd)
        drain_input(fd)
        os.write(fd, b"G\n")
        wav = receive_wav(fd, arguments.timeout)
    finally:
        os.close(fd)

    duration = validate_wav(wav)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_bytes(wav)
    print(f"Saved: {arguments.output.resolve()}")
    print(f"Bytes: {len(wav)}")
    print(f"Duration: {duration:.3f} s")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, TimeoutError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        raise SystemExit(1)
