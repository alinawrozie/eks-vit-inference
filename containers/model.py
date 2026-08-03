import torch
import torch.nn as nn
from torchvision import transforms
import timm

# ImageNet normalization constants
IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD = [0.229, 0.224, 0.225]

class TransferModel(nn.Module):
    """
    PyTorch implementation of the transfer learning model with GELU head.
    Matches the exact training architecture for ViT-B16.
    """
    def __init__(self, base_model, num_features, num_classes=1):
        super(TransferModel, self).__init__()
        self.base_model = base_model
        self.bn1 = nn.BatchNorm1d(num_features)
        self.fc1 = nn.Linear(num_features, 32)
        self.gelu = nn.GELU()
        self.bn2 = nn.BatchNorm1d(32)
        self.fc2 = nn.Linear(32, num_classes)

    def forward(self, x):
        features = self.base_model(x)
        if isinstance(features, (list, tuple)):
            features = features[-1]
        features = features.view(features.size(0), -1)
        
        x = self.bn1(features)
        x = self.fc1(x)
        x = self.gelu(x)
        x = self.bn2(x)
        x = self.fc2(x)
        return x

def build_model(dim=224, pretrained=True):
    """
    Factory function returning the ViT-B16 TransferModel matching training architecture.
    """
    base_vit = timm.create_model('vit_base_patch16_224', pretrained=pretrained, num_classes=0)
    model = TransferModel(base_vit, num_features=768)
    return model

def get_inference_transform(dim=224):
    """
    Returns torchvision transforms for preprocessing a single PIL image for inference.
    Pipeline: Resize to (dim, dim) -> ToTensor -> Normalize with ImageNet constants.
    Applied to one PIL Image at a time.
    """
    return transforms.Compose([
        transforms.Resize((dim, dim)),
        transforms.ToTensor(),
        transforms.Normalize(mean=IMAGENET_MEAN, std=IMAGENET_STD)
    ])
