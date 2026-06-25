#!/usr/bin/env python3
"""
FitTrackr 训练数据准备脚本
下载健身动作数据集，整理成 Create ML Action Classification 需要的格式

用法：
    python3 prepare_training_data.py

输出目录结构（Create ML 需要的格式）：
    TrainingData/
    ├── inPlace/        # 原地运动
    │   ├── squat_001.mov
    │   ├── pushup_001.mov
    │   └── ...
    ├── moving/         # 移动中
    │   ├── walking_001.mov
    │   └── ...
    └── static/         # 静止
        ├── standing_001.mov
        └── ...
"""

import os
import sys
import shutil
import zipfile
import subprocess
from pathlib import Path
from urllib.request import urlretrieve
from tqdm import tqdm

# 配置
BASE_DIR = Path(__file__).parent.parent  # FitTrackr.1 目录
DATA_DIR = BASE_DIR / "MLTrainingData"
OUTPUT_DIR = DATA_DIR / "TrainingData"
TEMP_DIR = DATA_DIR / "temp"

# 标签映射：把具体动作映射到我们需要的三类
LABEL_MAP = {
    # 原地运动 (inPlace)
    'squat': 'inPlace',
    'squats': 'inPlace',
    'pushup': 'inPlace',
    'push_up': 'inPlace',
    'pushups': 'inPlace',
    'push-up': 'inPlace',
    'push-ups': 'inPlace',
    'jumping_jack': 'inPlace',
    'jumping_jacks': 'inPlace',
    'jumpingjack': 'inPlace',
    'plank': 'inPlace',
    'lunge': 'inPlace',
    'lunges': 'inPlace',
    'burpee': 'inPlace',
    'burpees': 'inPlace',
    'situp': 'inPlace',
    'sit_up': 'inPlace',
    'situps': 'inPlace',
    'crunch': 'inPlace',
    'crunches': 'inPlace',
    'deadlift': 'inPlace',
    'bench_press': 'inPlace',
    'pull_up': 'inPlace',
    'pullup': 'inPlace',
    'pullups': 'inPlace',
    'jumping': 'inPlace',
    'jump': 'inPlace',
    'boxing': 'inPlace',
    'punching': 'inPlace',

    # 移动 (moving)
    'walking': 'moving',
    'walk': 'moving',
    'running': 'moving',
    'run': 'moving',
    'jogging': 'moving',
    'jog': 'moving',
    'climbing': 'moving',
    'dancing': 'moving',
    'dance': 'moving',

    # 静止 (static)
    'standing': 'static',
    'stand': 'static',
    'sitting': 'static',
    'sit': 'static',
    'resting': 'static',
    'rest': 'static',
    'idle': 'static',
}


class DownloadProgressBar(tqdm):
    """下载进度条"""
    def update_to(self, b=1, bsize=1, tsize=None):
        if tsize is not None:
            self.total = tsize
        self.update(b * bsize - self.n)


def download_file(url: str, output_path: Path, desc: str = "下载中"):
    """下载文件，显示进度条"""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with DownloadProgressBar(unit='B', unit_scale=True, miniters=1, desc=desc) as t:
        urlretrieve(url, output_path, reporthook=t.update_to)


def try_kaggle_download() -> bool:
    """尝试用 Kaggle API 下载数据集"""
    try:
        import kaggle
        print("检测到 Kaggle API，尝试下载数据集...")

        # 下载健身动作数据集
        kaggle.api.dataset_download_files(
            'hasyimabdillah/workoutfitness-video',
            path=str(TEMP_DIR),
            unzip=True
        )
        return True
    except Exception as e:
        print(f"Kaggle 下载失败: {e}")
        return False


def download_ucf_subset():
    """下载 UCF101 数据集的子集（包含健身相关动作）"""
    print("\n正在下载 UCF101 健身动作子集...")

    # UCF101 的一些健身相关类别的视频示例
    # 注意：这是简化版，实际 UCF101 需要从官网下载

    # 备选方案：用 Kinetics 或其他公开数据
    urls = {
        # 这里用一些公开的示例视频 URL
        # 实际使用时需要替换为真实数据源
    }

    print("提示：UCF101 需要从官网下载")
    print("下载地址: https://www.crcv.ucf.edu/data/UCF101.php")
    return False


def download_sample_videos():
    """下载一些示例视频用于测试（数量很少，仅用于验证流程）"""
    print("\n创建示例数据结构...")

    # 创建目录结构
    for label in ['inPlace', 'moving', 'static']:
        (OUTPUT_DIR / label).mkdir(parents=True, exist_ok=True)

    print(f"""
示例目录已创建: {OUTPUT_DIR}

由于版权原因，脚本无法自动下载视频。请手动添加视频：

1. 原地运动视频 → {OUTPUT_DIR / 'inPlace'}/
   - 深蹲、俯卧撑、开合跳、平板支撑等

2. 移动视频 → {OUTPUT_DIR / 'moving'}/
   - 走路、跑步、跳跃移动等

3. 静止视频 → {OUTPUT_DIR / 'static'}/
   - 站立、坐着等

推荐数据来源：
- Kaggle: https://www.kaggle.com/datasets/hasyimabdillah/workoutfitness-video
- UCF101: https://www.crcv.ucf.edu/data/UCF101.php
- 自己用手机录制（最推荐，匹配真实使用场景）
""")
    return True


def organize_videos(source_dir: Path):
    """整理下载的视频到 Create ML 格式"""
    print(f"\n整理视频到 {OUTPUT_DIR}...")

    # 创建输出目录
    for label in ['inPlace', 'moving', 'static']:
        (OUTPUT_DIR / label).mkdir(parents=True, exist_ok=True)

    # 统计
    stats = {'inPlace': 0, 'moving': 0, 'static': 0, 'skipped': 0}

    # 遍历源目录
    video_extensions = {'.mp4', '.mov', '.avi', '.mkv', '.m4v'}

    for video_file in source_dir.rglob('*'):
        if video_file.suffix.lower() not in video_extensions:
            continue

        # 从路径或文件名推断标签
        path_lower = str(video_file).lower()
        mapped_label = None

        for keyword, label in LABEL_MAP.items():
            if keyword in path_lower:
                mapped_label = label
                break

        if mapped_label:
            # 复制到对应目录
            dest = OUTPUT_DIR / mapped_label / video_file.name
            if not dest.exists():
                shutil.copy2(video_file, dest)
                stats[mapped_label] += 1
        else:
            stats['skipped'] += 1

    print(f"\n整理完成:")
    print(f"  原地运动 (inPlace): {stats['inPlace']} 个视频")
    print(f"  移动 (moving): {stats['moving']} 个视频")
    print(f"  静止 (static): {stats['static']} 个视频")
    print(f"  跳过 (未识别): {stats['skipped']} 个视频")


def verify_data():
    """验证数据集"""
    print("\n验证数据集...")

    total = 0
    for label in ['inPlace', 'moving', 'static']:
        label_dir = OUTPUT_DIR / label
        if label_dir.exists():
            count = len(list(label_dir.glob('*')))
            total += count
            status = "✅" if count >= 20 else "⚠️ 建议至少 20 个"
            print(f"  {label}: {count} 个视频 {status}")
        else:
            print(f"  {label}: 目录不存在 ❌")

    if total == 0:
        print("\n❌ 没有找到任何视频，请手动添加视频到对应目录")
        return False
    elif total < 60:
        print(f"\n⚠️ 总共 {total} 个视频，建议每类至少 20 个以获得较好效果")
        return True
    else:
        print(f"\n✅ 总共 {total} 个视频，数据量足够")
        return True


def print_next_steps():
    """打印下一步操作"""
    print(f"""
{'='*60}
下一步：用 Create ML 训练模型
{'='*60}

1. 打开 Xcode

2. 菜单: Xcode → Open Developer Tool → Create ML

3. 新建项目: File → New → Project → Action Classification

4. 拖入训练数据:
   将 {OUTPUT_DIR} 文件夹拖到 Training Data 区域

5. 点击 Train 开始训练

6. 训练完成后，点击 Output 导出 .mlmodel 文件

7. 将 .mlmodel 拖入 FitTrackr.1 项目

{'='*60}
""")


def main():
    print("="*60)
    print("FitTrackr 训练数据准备工具")
    print("="*60)

    # 创建目录
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    TEMP_DIR.mkdir(parents=True, exist_ok=True)

    # 尝试各种下载方式
    downloaded = False

    # 方式1: Kaggle
    if not downloaded:
        kaggle_config = Path.home() / '.kaggle' / 'kaggle.json'
        if kaggle_config.exists():
            downloaded = try_kaggle_download()
            if downloaded:
                organize_videos(TEMP_DIR)

    # 方式2: 创建示例结构，提示手动下载
    if not downloaded:
        download_sample_videos()

    # 验证
    verify_data()

    # 下一步
    print_next_steps()


if __name__ == "__main__":
    main()
