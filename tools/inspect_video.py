"""생성된 HTS 녹화 영상이 실제로 열리고 유효한 프레임을 포함하는지 검사한다."""

import argparse
import shutil
import tempfile
from pathlib import Path

import cv2


def main() -> int:
    """비디오 메타데이터를 출력하고 디코딩 불가능하거나 빈 영상이면 실패 코드를 반환한다."""
    parser = argparse.ArgumentParser()
    parser.add_argument("video")
    args = parser.parse_args()

    path = Path(args.video)
    # 한글·긴 경로에 따른 코덱 오차를 피하려고 임시 ASCII 경로에서 동일 파일을 검사한다.
    with tempfile.TemporaryDirectory(prefix="hts-qa-inspect-") as temp_dir:
        inspection_path = Path(temp_dir) / "inspection.mp4"
        shutil.copyfile(path, inspection_path)
        cap = cv2.VideoCapture(str(inspection_path))
        opened = cap.isOpened()
        frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) if opened else 0
        fps = float(cap.get(cv2.CAP_PROP_FPS)) if opened else 0.0
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)) if opened else 0
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)) if opened else 0
        duration = frames / fps if fps else 0.0
        cap.release()

    print(f"opened={opened}")
    print(f"frames={frames}")
    print(f"fps={fps}")
    print(f"width={width}")
    print(f"height={height}")
    print(f"duration={duration}")
    if not opened or frames <= 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
