#!/usr/bin/env python3
"""
动作分类器训练脚本 - 修复版
"""

import os
import json
import random
from pathlib import Path
from collections import defaultdict

import cv2
import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import Dataset, DataLoader
from tqdm import tqdm

# 配置
BASE_DIR = Path(__file__).parent.parent
DATA_DIR = BASE_DIR / "MLTrainingData" / "TrainingData"
OUTPUT_DIR = BASE_DIR / "MLTrainingData" / "output"
FEATURES_DIR = BASE_DIR / "MLTrainingData" / "features"

# 训练参数
SEQUENCE_LENGTH = 20  # 降低到20帧
FEATURE_DIM = 99
HIDDEN_SIZE = 64
NUM_CLASSES = 3
BATCH_SIZE = 32
EPOCHS = 30
LEARNING_RATE = 0.001

LABEL_MAP = {'inPlace': 0, 'moving': 1, 'static': 2}
LABEL_NAMES = ['inPlace', 'moving', 'static']


def extract_features_from_video(video_path: Path, max_frames: int = 200) -> list:
    """从视频提取帧特征"""
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


def extract_all_features():
    """从所有视频提取特征"""
    print("\n" + "="*60)
    print("步骤 1/3: 从视频提取特征")
    print("="*60)

    FEATURES_DIR.mkdir(parents=True, exist_ok=True)
    all_features = {}

    for label in LABEL_NAMES:
        label_dir = DATA_DIR / label
        if not label_dir.exists():
            print(f"警告: {label_dir} 不存在")
            continue

        videos = list(label_dir.glob("*.*"))
        print(f"\n处理 {label}: {len(videos)} 个视频")

        label_features = []
        for video_path in tqdm(videos, desc=f"提取 {label}"):
            try:
                features = extract_features_from_video(video_path)
                if len(features) >= SEQUENCE_LENGTH:
                    label_features.append({
                        'video': video_path.name,
                        'features': [f.tolist() for f in features]
                    })
            except Exception as e:
                pass

        all_features[label] = label_features

        # 保存特征
        output_file = FEATURES_DIR / f"{label}.json"
        with open(output_file, 'w') as f:
            json.dump(label_features, f)
        print(f"  保存 {label}: {len(label_features)} 个样本")

    return all_features


def load_features():
    """加载已提取的特征"""
    all_features = {}
    for label in LABEL_NAMES:
        feature_file = FEATURES_DIR / f"{label}.json"
        if feature_file.exists():
            with open(feature_file) as f:
                all_features[label] = json.load(f)
            print(f"加载 {label}: {len(all_features[label])} 个样本")
    return all_features


def prepare_sequences(all_features: dict) -> tuple:
    """准备训练序列"""
    X, y = [], []

    for label, features in all_features.items():
        if not features:
            continue
        label_id = LABEL_MAP[label]

        for item in features:
            frames = item['features']
            # 滑动窗口
            for i in range(0, len(frames) - SEQUENCE_LENGTH + 1, SEQUENCE_LENGTH // 2):
                seq = frames[i:i + SEQUENCE_LENGTH]
                if len(seq) == SEQUENCE_LENGTH:
                    X.append(seq)
                    y.append(label_id)

    return np.array(X, dtype=np.float32), np.array(y)


class ActionDataset(Dataset):
    def __init__(self, features, labels):
        self.features = torch.FloatTensor(features)
        self.labels = torch.LongTensor(labels)

    def __len__(self):
        return len(self.features)

    def __getitem__(self, idx):
        return self.features[idx], self.labels[idx]


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
        lstm_out, _ = self.lstm(x)
        return self.fc(lstm_out[:, -1, :])


def train_model(X, y):
    """训练模型"""
    print("\n" + "="*60)
    print("步骤 2/3: 训练分类器")
    print("="*60)

    # 划分数据
    indices = list(range(len(X)))
    random.shuffle(indices)
    split = int(0.8 * len(indices))
    train_idx, val_idx = indices[:split], indices[split:]

    X_train, y_train = X[train_idx], y[train_idx]
    X_val, y_val = X[val_idx], y[val_idx]

    print(f"训练集: {len(X_train)}, 验证集: {len(X_val)}")

    train_loader = DataLoader(ActionDataset(X_train, y_train),
                             batch_size=BATCH_SIZE, shuffle=True)
    val_loader = DataLoader(ActionDataset(X_val, y_val),
                           batch_size=BATCH_SIZE)

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    print(f"设备: {device}")

    model = ActionClassifier().to(device)
    criterion = nn.CrossEntropyLoss()
    optimizer = torch.optim.Adam(model.parameters(), lr=LEARNING_RATE)

    best_acc = 0
    best_state = None

    for epoch in range(EPOCHS):
        model.train()
        train_loss = 0
        for X_batch, y_batch in train_loader:
            X_batch, y_batch = X_batch.to(device), y_batch.to(device)
            optimizer.zero_grad()
            outputs = model(X_batch)
            loss = criterion(outputs, y_batch)
            loss.backward()
            optimizer.step()
            train_loss += loss.item()

        model.eval()
        correct, total = 0, 0
        with torch.no_grad():
            for X_batch, y_batch in val_loader:
                X_batch, y_batch = X_batch.to(device), y_batch.to(device)
                outputs = model(X_batch)
                _, predicted = outputs.max(1)
                total += y_batch.size(0)
                correct += predicted.eq(y_batch).sum().item()

        val_acc = 100.0 * correct / total if total > 0 else 0

        if val_acc > best_acc:
            best_acc = val_acc
            best_state = model.state_dict().copy()

        if (epoch + 1) % 5 == 0:
            print(f"Epoch {epoch+1}/{EPOCHS} - Loss: {train_loss/len(train_loader):.4f} - Val: {val_acc:.1f}%")

    print(f"\n最佳准确率: {best_acc:.1f}%")

    if best_state:
        model.load_state_dict(best_state)
    return model


def export_coreml(model):
    """导出 Core ML"""
    print("\n" + "="*60)
    print("步骤 3/3: 导出模型")
    print("="*60)

    import coremltools as ct

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    model.eval()
    model.cpu()

    example = torch.randn(1, SEQUENCE_LENGTH, FEATURE_DIM)
    traced = torch.jit.trace(model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="features", shape=(1, SEQUENCE_LENGTH, FEATURE_DIM))],
        outputs=[ct.TensorType(name="logits")],
        minimum_deployment_target=ct.target.iOS15
    )

    output_path = OUTPUT_DIR / "ActionClassifier.mlpackage"
    mlmodel.save(str(output_path))
    print(f"Core ML 模型: {output_path}")

    torch_path = OUTPUT_DIR / "ActionClassifier.pth"
    torch.save(model.state_dict(), torch_path)
    print(f"PyTorch 模型: {torch_path}")

    return output_path


def main():
    print("="*60)
    print("FitTrackr 动作分类器训练")
    print("="*60)

    # 提取或加载特征
    existing = all((FEATURES_DIR / f"{l}.json").exists() for l in LABEL_NAMES)
    if existing:
        print("\n加载已有特征...")
        all_features = load_features()
    else:
        all_features = extract_all_features()

    # 检查数据
    total = sum(len(v) for v in all_features.values())
    if total == 0:
        print("错误: 没有特征数据")
        return

    # 准备序列
    print("\n准备训练数据...")
    X, y = prepare_sequences(all_features)
    print(f"总样本: {len(X)}")
    for label, label_id in LABEL_MAP.items():
        count = (y == label_id).sum()
        print(f"  {label}: {count}")

    if len(X) < 10:
        print("错误: 样本太少")
        return

    # 训练
    model = train_model(X, y)

    # 导出
    export_coreml(model)

    print("\n" + "="*60)
    print("完成！模型已保存到:")
    print(f"  {OUTPUT_DIR}")
    print("="*60)


if __name__ == "__main__":
    main()
