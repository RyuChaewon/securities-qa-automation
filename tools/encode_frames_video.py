"""PowerShell 녹화기가 저장한 PNG 프레임을 MP4 영상으로 인코딩한다.

한글 경로를 안정적으로 읽기 위해 NumPy 바이트 배열을 거쳐 OpenCV로 디코딩한다.
"""

import argparse
import shutil
import tempfile
from pathlib import Path

import cv2
import numpy as np


def read_image(path: Path):
    """Windows의 비 ASCII 경로에서도 PNG를 읽을 수 있도록 바이트 기반으로 디코딩한다."""
    data = np.fromfile(path, dtype=np.uint8)
    return cv2.imdecode(data, cv2.IMREAD_COLOR)


def main() -> int:
    """프레임 크기를 정규화하고 임시 ASCII 경로에서 인코딩한 뒤 목적지로 옮긴다."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames-dir", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--fps", type=float, default=5.0)
    args = parser.parse_args()

    frames_dir = Path(args.frames_dir)
    out_path = Path(args.out)
    frame_paths = sorted(frames_dir.glob("frame_*.png"))
    if not frame_paths:
        raise SystemExit(f"no frames found in {frames_dir}")

    first = read_image(frame_paths[0])
    if first is None:
        raise SystemExit(f"cannot read first frame {frame_paths[0]}")

    height, width = first.shape[:2]
    out_path.parent.mkdir(parents=True, exist_ok=True)
    written = 0
    # OpenCV 코덱이 한글 출력 경로를 처리하지 못하는 경우를 피해 임시 경로에서 먼저 쓴다.
    with tempfile.TemporaryDirectory(prefix="hts-qa-video-") as temp_dir:
        temp_output = Path(temp_dir) / "encoded.mp4"
        fourcc = cv2.VideoWriter_fourcc(*"mp4v")
        writer = cv2.VideoWriter(str(temp_output), fourcc, args.fps, (width, height))
        if not writer.isOpened():
            raise SystemExit(f"cannot open video writer for {out_path}")

        try:
            for frame_path in frame_paths:
                frame = read_image(frame_path)
                if frame is None:
                    continue
                if frame.shape[:2] != (height, width):
                    frame = cv2.resize(frame, (width, height))
                writer.write(frame)
                written += 1
        finally:
            writer.release()

        if written:
            shutil.copyfile(temp_output, out_path)

    if written == 0:
        raise SystemExit("no readable frames were encoded")

    print(str(out_path))
    print(f"frames={written}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
