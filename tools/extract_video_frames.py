"""오류가 발생한 시점의 지정 프레임을 HTS 녹화 영상에서 PNG로 추출한다."""

import argparse
import json
from pathlib import Path

import cv2


def main() -> None:
    """요청한 프레임 번호로 이동해 보고서가 참조할 증거 이미지를 생성한다."""
    parser = argparse.ArgumentParser()
    parser.add_argument("video", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("frame_numbers", nargs="+", type=int)
    args = parser.parse_args()

    capture = cv2.VideoCapture(str(args.video))
    if not capture.isOpened():
        raise RuntimeError("The video could not be opened.")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    outputs = []
    try:
        for frame_number in args.frame_numbers:
            capture.set(cv2.CAP_PROP_POS_FRAMES, frame_number)
            ok, frame = capture.read()
            if not ok:
                raise RuntimeError(f"Frame {frame_number} could not be decoded.")
            path = args.output_dir / f"frame_{frame_number:06d}.png"
            encoded_ok, encoded = cv2.imencode(".png", frame)
            if not encoded_ok:
                raise RuntimeError(f"Frame {frame_number} could not be written.")
            encoded.tofile(str(path))
            outputs.append(str(path.resolve()))
    finally:
        capture.release()

    print(json.dumps({"frames": outputs}, ensure_ascii=False))


if __name__ == "__main__":
    main()
