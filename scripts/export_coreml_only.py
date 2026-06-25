#!/usr/bin/env python3
"""仅导出 CoreML 模型"""
import torch
import torch.nn as nn
import coremltools as ct
from pathlib import Path

BASE_DIR = Path(__file__).parent.parent
OUTPUT_DIR = BASE_DIR / "MLTrainingData" / "output"

SEQUENCE_LENGTH = 20
FEATURE_DIM = 99
HIDDEN_SIZE = 64
NUM_CLASSES = 3

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

# 加载模型
model = ActionClassifier()
model.load_state_dict(torch.load(OUTPUT_DIR / "ActionClassifier.pth", weights_only=True))
model.eval()
model.cpu()

print("模型加载成功，开始转换...")

# 导出 CoreML
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
print(f"✅ CoreML 模型已保存: {output_path}")
