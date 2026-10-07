import os
from huggingface_hub import hf_hub_download

def download():
    models = [
        ("Acly/MobileSAM", "mobile_sam_image_encoder.onnx", "assets/models/mobilesam"),
        ("Acly/MobileSAM", "sam_mask_decoder_single.onnx", "assets/models/mobilesam"),
        ("Xenova/mobileclip_s0", "onnx/vision_model.onnx", "assets/models/mobileclip"),
        ("Xenova/mobileclip_s0", "onnx/text_model.onnx", "assets/models/mobileclip"),
        ("Xenova/mobileclip_s0", "tokenizer.json", "assets/models/mobileclip"),
        ("Xenova/mobileclip_s0", "tokenizer_config.json", "assets/models/mobileclip"),
        ("Xenova/mobileclip_s0", "config.json", "assets/models/mobileclip"),
        ("Xenova/mobileclip_s0", "preprocessor_config.json", "assets/models/mobileclip"),
    ]

    for repo_id, filename, local_dir in models:
        print(f"Downloading {filename}...")
        hf_hub_download(repo_id=repo_id, filename=filename, local_dir=local_dir)

if __name__ == "__main__":
    download()
