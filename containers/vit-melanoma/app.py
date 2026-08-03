import os
import io
import torch
from fastapi import FastAPI, UploadFile, File, HTTPException
from PIL import Image
from model import build_model, get_inference_transform

# Read environment variables with sensible defaults
CHECKPOINT_PATH = os.getenv("CHECKPOINT_PATH", "/app/model-fold-5.pt")
THRESHOLD_RAW = os.getenv("THRESHOLD", "0.75")
PARSED_THRESHOLD = float(THRESHOLD_RAW)

# Module-level global variables initialized to None (populated at startup)
model = None
transform = None
threshold = None

app = FastAPI(title="ViT-B16 Skin Lesion Classifier API")


@app.on_event("startup")
def startup_event():
    """
    Startup handler to initialize model, transforms, and threshold ONCE when the app starts.
    """
    global model, transform, threshold

    print("[*] Starting up application: Building ViT-B16 model...")
    loaded_model = build_model(pretrained=False)
    
    state_dict = torch.load(CHECKPOINT_PATH, map_location="cpu")
    loaded_model.load_state_dict(state_dict)
    
    loaded_model.eval()

    # Assign to global variables
    model = loaded_model
    transform = get_inference_transform()
    threshold = PARSED_THRESHOLD

    print(f"[+] Startup complete. Model loaded into memory. Threshold set to {threshold}.")


@app.get("/health")
def health_check():
    """
    Kubernetes readinessProbe endpoint.
    Returns 200 OK only if the model and transforms are fully loaded into memory.
    """
    if model is None or transform is None:
        raise HTTPException(status_code=503, detail="Model is not ready or still loading")
    return {"status": "ok", "model_loaded": True}


@app.post("/predict")
def predict(file: UploadFile = File(...)):
    """
    Predict endpoint for single skin lesion image classification.
    Synchronous 'def' enables FastAPI to offload CPU-bound PIL processing and 
    PyTorch inference to a worker thread pool, keeping the main event loop unblocked.
    """
    if model is None or transform is None:
        raise HTTPException(status_code=503, detail="Model is not ready")

    # Read uploaded bytes and open PIL image synchronously
    try:
        contents = file.file.read()
        raw_img = Image.open(io.BytesIO(contents)).convert("RGB")
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid or corrupt image file uploaded.")

    # Apply transform and add batch dimension [1, 3, 224, 224]
    img_tensor = transform(raw_img).unsqueeze(0)

    # Perform inference inside torch.no_grad()
    with torch.no_grad():
        output = model(img_tensor)
        prob = torch.sigmoid(output).item()

    # Determine 0/1 binary label using global threshold
    label = 1 if prob >= threshold else 0

    return {
        "probability": float(prob),
        "label": label
    }
