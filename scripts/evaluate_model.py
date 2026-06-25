#!/usr/bin/env python3
"""评估动作分类器在验证集上的准确性"""
import torch
import torch.nn as nn
import numpy as np
import cv2
from pathlib import Path
from collections import defaultdict
from tqdm import tqdm

BASE_DIR = Path(__file__).parent.parent
VAL_DIR = BASE_DIR / "MLTrainingData" / "ValidationData"
OUTPUT_DIR = BASE_DIR / "MLTrainingData" / "output"

SEQUENCE_LENGTH = 20
FEATURE_DIM = 99
HIDDEN_SIZE = 64
NUM_CLASSES = 3
LABEL_MAP = {'inPlace': 0, 'moving': 1, 'static': 2}
LABEL_NAMES = ['inPlace', 'moving', 'static']

class ActionClassifier(nn.Module):
    def __init__(self, input_size=FEATURE_DIM, hidden_size=HIDDEN_SIZE, num_classes=NUM_CLASSES):
        super().__init__()
        self.lstm = nn.LSTM(input_size, hidden_size, num_layers=2,
                           batch_first=True, dropout=0.2, bidirectional=True)
        self.fc = nn.Sequential(
            nn.Linear(hidden_size * 2, 32),
            nn.ReLU(),
            nn.Dropout(0.2),
            nn.Linear(32, num_classes)
        )
        
    def forward(self, x):
        out, _ = self.lstm(x)
        out = out[:, -1, :]
        return self.fc(out)

def extract_features_from_video(video_path, max_frames=200):
    """从视频提取帧特征 - 与训练脚本相同"""
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        return []
    
    features = []
    prev_gray = None
    frame_count = 0
    
    while cap.isOpened() and frame_count < max_frames:
        ret, frame = cap.read()
        if not ret:
            break
        
        # 每隔2帧采样
        if frame_count % 2 != 0:
            frame_count += 1
            continue
        
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        resized = cv2.resize(gray, (32, 32))
        curr = resized.flatten().astype(np.float32) / 255.0
        
        if prev_gray is not None:
            # 计算帧差（运动特征）
            motion = np.abs(curr - prev_gray)
            
            # 汇总特征
            feature = np.concatenate([
                [np.mean(motion), np.std(motion), np.max(motion)],  # 运动统计 3
                [np.mean(curr[:512]), np.mean(curr[512:])],  # 空间分布 2
                curr[:94]  # 像素采样 94
            ])  # 总共 99 维
            
            features.append(feature.astype(np.float32))
        
        prev_gray = curr
        frame_count += 1
    
    cap.release()
    return features

def prepare_sequences(features_dict):
    """准备序列数据"""
    X, y = [], []
    
    for label, features_list in features_dict.items():
        label_id = LABEL_MAP[label]
        for video_features in features_list:
            if len(video_features) < SEQUENCE_LENGTH:
                continue
            # 滑动窗口
            for i in range(0, len(video_features) - SEQUENCE_LENGTH + 1, SEQUENCE_LENGTH // 2):
                seq = video_features[i:i + SEQUENCE_LENGTH]
                if len(seq) == SEQUENCE_LENGTH:
                    X.append(seq)
                    y.append(label_id)
    
    return np.array(X, dtype=np.float32), np.array(y)

def evaluate():
    print("=" * 60)
    print("动作分类器验证集评估")
    print("=" * 60)
    
    # 加载模型
    model = ActionClassifier()
    model.load_state_dict(torch.load(OUTPUT_DIR / "ActionClassifier.pth", weights_only=True))
    model.eval()
    
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    model = model.to(device)
    print(f"设备: {device}")
    
    # 提取验证集特征
    print("\n提取验证集特征...")
    val_features = defaultdict(list)
    
    for label in LABEL_NAMES:
        label_dir = VAL_DIR / label
        if not label_dir.exists():
            print(f"  {label}: 目录不存在")
            continue
        
        videos = list(label_dir.glob("*.*"))
        # 过滤非视频文件
        videos = [v for v in videos if v.suffix.lower() in ['.mov', '.mp4', '.avi', '.m4v']]
        print(f"  {label}: {len(videos)} 个视频")
        
        for video_path in tqdm(videos, desc=f"处理 {label}", leave=False):
            features = extract_features_from_video(video_path)
            if features and len(features) >= SEQUENCE_LENGTH:
                val_features[label].append(features)
    
    # 准备序列
    X_val, y_val = prepare_sequences(val_features)
    print(f"\n验证样本总数: {len(X_val)}")
    
    for label in LABEL_NAMES:
        count = (y_val == LABEL_MAP[label]).sum() if len(y_val) > 0 else 0
        print(f"  {label}: {count}")
    
    if len(X_val) == 0:
        print("错误: 没有有效的验证数据")
        return
    
    # 评估
    X_tensor = torch.FloatTensor(X_val).to(device)
    y_tensor = torch.LongTensor(y_val).to(device)
    
    with torch.no_grad():
        outputs = model(X_tensor)
        _, predicted = torch.max(outputs, 1)
        
    predicted = predicted.cpu().numpy()
    y_val = y_tensor.cpu().numpy()
    
    # 计算指标
    accuracy = (predicted == y_val).mean() * 100
    
    print("\n" + "=" * 60)
    print("评估结果")
    print("=" * 60)
    print(f"\n✅ 总体准确率: {accuracy:.1f}%")
    
    # 混淆矩阵
    print("\n混淆矩阵 (行=真实, 列=预测):")
    print(f"{'':12} | {'inPlace':>8} | {'moving':>8} | {'static':>8} | 召回率")
    print("-" * 60)
    
    for true_label in range(NUM_CLASSES):
        mask = y_val == true_label
        row = []
        for pred_label in range(NUM_CLASSES):
            count = ((predicted == pred_label) & mask).sum()
            row.append(count)
        
        total = sum(row)
        recall = row[true_label] / total * 100 if total > 0 else 0
        print(f"{LABEL_NAMES[true_label]:12} | {row[0]:>8} | {row[1]:>8} | {row[2]:>8} | {recall:.1f}%")
    
    # 每类精确率
    print("\n各类精确率:")
    for pred_label in range(NUM_CLASSES):
        mask = predicted == pred_label
        if mask.sum() > 0:
            precision = (y_val[mask] == pred_label).mean() * 100
            print(f"  {LABEL_NAMES[pred_label]}: {precision:.1f}%")
        else:
            print(f"  {LABEL_NAMES[pred_label]}: N/A (无预测)")

if __name__ == "__main__":
    evaluate()
