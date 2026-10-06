import os
import io
import base64
import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI, UploadFile, File, Form, HTTPException
from fastapi.responses import JSONResponse
from PIL import Image
import torch
import numpy as np
from transformers import OwlViTProcessor, OwlViTForObjectDetection, SamModel, SamProcessor

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Global models
owl_processor = None
owl_model = None
sam_processor = None
sam_model = None
device = "cuda" if torch.cuda.is_available() else "cpu"
if device == "cpu":
    logger.warning("=========================================================")
    logger.warning("NO GPU (CUDA) DETECTED! Running heavily on CPU.")
    logger.warning("Inference will be significantly slower (10-30s per image).")
    logger.warning("=========================================================")
    # Optimize CPU threads for PyTorch
    import multiprocessing
    torch.set_num_threads(multiprocessing.cpu_count())
else:
    logger.info(f"GPU detected: {torch.cuda.get_device_name(0)}. Running optimized inference.")

@asynccontextmanager
async def lifespan(app: FastAPI):
    global owl_processor, owl_model, sam_processor, sam_model
    logger.info(f"Loading models on {device} (this may take a few minutes the first time)...")
    
    try:
        # Load OWL-ViT for zero-shot text-to-bbox
        owl_processor = OwlViTProcessor.from_pretrained("google/owlvit-base-patch32")
        owl_model = OwlViTForObjectDetection.from_pretrained("google/owlvit-base-patch32").to(device)
        
        # Load SAM for bbox-to-mask
        sam_processor = SamProcessor.from_pretrained("facebook/sam-vit-base")
        sam_model = SamModel.from_pretrained("facebook/sam-vit-base").to(device)
        
        logger.info("Models loaded successfully.")
    except Exception as e:
        logger.error(f"Failed to load models: {e}")
        
    yield
    # Clean up on shutdown
    owl_model = None
    sam_model = None

app = FastAPI(lifespan=lifespan)

@app.get("/")
async def root():
    return {"status": "online", "message": "Nippon ColorLab AI - Pro Segmentation Backend is Running!"}

@app.post("/api/v1/segment")
async def segment_image(
    image: UploadFile = File(...),
    object: str = Form(...),
    position: str = Form(None)
):
    try:
        contents = await image.read()
        img = Image.open(io.BytesIO(contents)).convert("RGB")
        width, height = img.size
        
        if owl_model is None or sam_model is None:
            return JSONResponse(status_code=503, content={"success": False, "error": "Models are not loaded."})
        
        # 1. Detect bounding boxes using OWL-ViT
        texts = [[f"a photo of a {object}"]]
        inputs = owl_processor(text=texts, images=img, return_tensors="pt").to(device)
        
        with torch.no_grad():
            outputs = owl_model(**inputs)
            
        target_sizes = torch.tensor([img.size[::-1]])
        results = owl_processor.post_process_grounded_object_detection(outputs=outputs, target_sizes=target_sizes, threshold=0.1)[0]
        
        if len(results["scores"]) == 0:
            return JSONResponse(status_code=404, content={"success": False, "error": f"Could not detect '{object}' in the image."})
            
        # Get boxes and scores
        boxes = results["boxes"].cpu().numpy()
        scores = results["scores"].cpu().numpy()
        
        # Filter logic based on position (if specified)
        selected_idx = 0
        if position:
            pos = position.lower()
            if 'left' in pos:
                centers_x = (boxes[:, 0] + boxes[:, 2]) / 2
                selected_idx = np.argmin(centers_x)
            elif 'right' in pos:
                centers_x = (boxes[:, 0] + boxes[:, 2]) / 2
                selected_idx = np.argmax(centers_x)
            elif 'top' in pos:
                centers_y = (boxes[:, 1] + boxes[:, 3]) / 2
                selected_idx = np.argmin(centers_y)
            elif 'bottom' in pos:
                centers_y = (boxes[:, 1] + boxes[:, 3]) / 2
                selected_idx = np.argmax(centers_y)
            elif 'center' in pos:
                centers_x = (boxes[:, 0] + boxes[:, 2]) / 2
                centers_y = (boxes[:, 1] + boxes[:, 3]) / 2
                dist_sq = (centers_x - width/2)**2 + (centers_y - height/2)**2
                selected_idx = np.argmin(dist_sq)
            else:
                areas = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
                selected_idx = np.argmax(areas)
        else:
            areas = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
            selected_idx = np.argmax(areas)
            
        best_box = boxes[selected_idx].tolist()
        best_score = float(scores[selected_idx])
        
        # 2. Segment using SAM
        # SAM expects boxes in format [[[xmin, ymin, xmax, ymax]]]
        input_boxes = [[[best_box]]] 
        sam_inputs = sam_processor(img, input_boxes=[input_boxes], return_tensors="pt").to(device)
        
        with torch.no_grad():
            sam_outputs = sam_model(**sam_inputs)
            
        # Extract masks
        masks = sam_processor.image_processor.post_process_masks(
            sam_outputs.pred_masks.cpu(),
            sam_inputs["original_sizes"].cpu(),
            sam_inputs["reshaped_input_sizes"].cpu()
        )[0]
        
        # SAM returns 3 masks per prompt, usually ordered by quality score
        mask_np = masks[0][0].numpy()  # shape (H, W) boolean
        
        # Create PIL Image from boolean mask
        mask_img = Image.fromarray((mask_np * 255).astype(np.uint8), mode='L')
        
        # Crop mask to bounding box for efficiency (as expected by Flutter)
        x1, y1, x2, y2 = [int(v) for v in best_box]
        x1, y1 = max(0, x1), max(0, y1)
        x2, y2 = min(width, x2), min(height, y2)
        
        cropped_mask = mask_img.crop((x1, y1, x2, y2))
        
        # Encode cropped mask to PNG base64
        mask_io = io.BytesIO()
        cropped_mask.save(mask_io, format="PNG")
        mask_base64 = base64.b64encode(mask_io.getvalue()).decode('utf-8')
        
        return {
            "success": True,
            "width": width,
            "height": height,
            "mask": mask_base64,
            "bbox": {
                "x1": x1,
                "y1": y1,
                "x2": x2,
                "y2": y2
            },
            "confidence": best_score
        }
        
    except Exception as e:
        logger.error(f"Error processing segmentation: {e}", exc_info=True)
        return JSONResponse(status_code=500, content={"success": False, "error": str(e)})

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
