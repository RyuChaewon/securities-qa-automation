"""여러 HTS 녹화 영상을 순서대로 이어 붙이고 결과 메타데이터를 JSON으로 출력한다.

입력 영상의 해상도와 FPS가 같아야 하며, 원본 파일은 변경하지 않는다.
"""

import argparse
import json
from pathlib import Path

import cv2


def main() -> None:
    """입력 영상을 검증한 뒤 프레임 순서를 보존해 하나의 MP4로 기록한다."""
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("inputs", nargs="+", type=Path)
    args = parser.parse_args()

    captures = [cv2.VideoCapture(str(path)) for path in args.inputs]
    try:
        if any(not capture.isOpened() for capture in captures):
            raise RuntimeError("One or more input videos could not be opened.")

        width = int(captures[0].get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(captures[0].get(cv2.CAP_PROP_FRAME_HEIGHT))
        fps = captures[0].get(cv2.CAP_PROP_FPS)
        if width <= 0 or height <= 0 or fps <= 0:
            raise RuntimeError("The first input video has invalid metadata.")

        # 첫 영상의 포맷을 출력 계약으로 사용하고 나머지 영상이 호환되는지 확인한다.
        for capture in captures[1:]:
            actual = (
                int(capture.get(cv2.CAP_PROP_FRAME_WIDTH)),
                int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT)),
                capture.get(cv2.CAP_PROP_FPS),
            )
            if actual[:2] != (width, height) or abs(actual[2] - fps) > 0.001:
                raise RuntimeError(f"Input video format mismatch: {actual}")

        args.output.parent.mkdir(parents=True, exist_ok=True)
        writer = cv2.VideoWriter(
            str(args.output),
            cv2.VideoWriter_fourcc(*"mp4v"),
            fps,
            (width, height),
        )
        if not writer.isOpened():
            raise RuntimeError("The output video writer could not be opened.")

        frames_per_input = []
        try:
            for capture in captures:
                frame_count = 0
                while True:
                    ok, frame = capture.read()
                    if not ok:
                        break
                    writer.write(frame)
                    frame_count += 1
                frames_per_input.append(frame_count)
        finally:
            writer.release()

        total_frames = sum(frames_per_input)
        print(
            json.dumps(
                {
                    "output": str(args.output.resolve()),
                    "framesPerInput": frames_per_input,
                    "totalFrames": total_frames,
                    "fps": fps,
                    "durationSeconds": total_frames / fps,
                    "width": width,
                    "height": height,
                },
                ensure_ascii=False,
            )
        )
    finally:
        for capture in captures:
            capture.release()


if __name__ == "__main__":
    main()
