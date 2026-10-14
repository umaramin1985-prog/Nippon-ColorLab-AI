# Nippon ColorLab AI

Nippon ColorLab AI is a high-performance, AI-driven cross-platform application built for professional interior and exterior paint visualization. Designed for paint consultants, architects, interior designers, and homeowners, it enables real-time preview of authentic Nippon Paint fandeck colors with photorealistic accuracy on real-world room and building photos.

The application pairs on-device neural networks (**MobileSAM** and **MobileCLIP** via **ONNX Runtime**) for fast, private, and edge-perfect segmentation with cloud-based generative AI (**FLUX** via **Replicate**) for generative redesigns.

---

## ✨ Core Features

### 🎨 Photorealistic Paint Rendering
- **Authentic Paint Reflectance**: Accurately reproduces target Nippon Paint lightness and chromaticity in CIELAB photometric space. Deep tones (e.g., Navy Blue, Forest Green) retain true saturation on light walls without washing out into pastels, while light creams and whites provide crisp, authentic coverage over darker walls.
- **Lighting & Texture Preservation**: Intelligently preserves ambient room illumination, natural shadow gradients, wall textures, and window light falloff while keeping deep shadow crevices (electrical sockets, switch plates, architectural recesses) naturally intact.

### 🧠 Dual AI Segmentation & Editing Modes
- **AI Lite (Fast, Private & 100% Offline)**:
  - Powered by on-device **MobileSAM** (Tiny-ViT image encoder and mask decoder) and **MobileCLIP** text/vision models running locally via **ONNX Runtime**.
  - **Natural Language Editing**: Type natural prompts like *"change wall to red"* or *"paint the ceiling soft cream"* completely offline.
  - **Spatial Validation & Surface Disambiguation**: Uses spatial bounds and dual negative prompting to cleanly differentiate walls from ceilings, floors, and furniture (such as tables).
  - **Connected-Component Mask Filtering**: Restricts color application to contiguous, connected surfaces, eliminating stray neural network activations across opposite walls or disconnected patches.
- **AI Pro (Generative Cloud Editing)**:
  - Powered by Replicate's **FLUX** generative model.
  - Translates natural language requests infused with exact Nippon Paint shade names and hex codes into generative architectural redraws under ambient lighting.

### ⚡ Performance & Mobile Memory Optimization
- **Android Large Heap Support**: Configured with `android:largeHeap="true"` to ensure rock-solid stability and zero Out-Of-Memory (OOM) crashes across demanding mobile devices (e.g., Vivo v40e).
- **Background Isolate Normalization**: Automatically bakes EXIF orientation and downscales large camera captures to max 1280px within a background worker isolate before processing.
- **Zero-Jitter Inference**: Employs flat `Float32List` unboxed mask arrays and fused crop-embedding extraction to eliminate UI micro-stutters and frame drops during neural network inference.
- **Smooth Background Recoloring**: Recoloring executes silently in worker isolates with automatic job sequencing (`_recolorJobId`), eliminating modal progress flicker when switching shades.

### 🎯 Smart Color Selection & Differentiating Last Applied vs. Similar Colors
- **Interactive Filter Tabs**: Toggle between **All**, **Similar Colors**, and **Last Applied** with real-time count badges in the color selection sheet.
- **Segregated Sections**: Clearly separates the **`LAST APPLIED COLOR`** (highlighted with an accent red border, glow shadow, and history badge) from **`SIMILAR TO <SURFACE>`** (matching ambient room tones).
- **Surface Matching**: Automatically samples the tapped surface and calculates Euclidean color distances across the fandeck to suggest authentic matching shades.

### 🔍 Interactive Before & After Client Comparison
- **Draggable Split-Screen Slider**: Toggle the interactive comparison mode (`Icons.compare`) to reveal a draggable split-view handle labeled *"Before"* and *"After"*, letting clients inspect transformations in real time.
- **Persistent Non-Destructive Storage**: Saved projects store both the edited design (`<project>.png`) and the companion unedited photo (`<project>_orig.png`), enabling full Before/After comparison even when reopening projects from the Saved tab.
- **Automatic Storage Cleanup**: Deleting a project automatically cleans up both the edited and original companion files.

### 📚 Nippon Paint Colour Catalogue
- **Fandeck Browsing**: Browse thousands of authentic Nippon Paint colors categorized into color families (Reds, Blues, Greens, Neutrals, etc.).
- **Search by Name & HEX**: Instantly search colors by name or hex code.
- **Swatches & Details**: Inspect RGB, HEX, and color metrics with one-tap copy functionality.
- **CSV Export**: Export and share the entire Nippon Paint fandeck catalogue as a structured CSV file.

---

## 🚀 Getting Started

### 1. Prerequisites
- **Flutter SDK** (3.24+ recommended)
- **Python 3.8+** (required for downloading local ONNX neural network weights)
- **Android SDK & Command-line Tools** (for Android APK builds)
- **Visual Studio 2022 with C++ Desktop Workload** (for Windows Desktop builds)

### 2. Download AI Models (Offline AI Lite Mode)
Before running the application, download the pre-exported MobileSAM and MobileCLIP ONNX models:
```powershell
python download_models.py
```
This script downloads and verifies the model weights into:
- `assets/models/mobilesam/mobile_sam_image_encoder.onnx`
- `assets/models/mobilesam/sam_mask_decoder_single.onnx`
- `assets/models/mobileclip/onnx/vision_model.onnx`
- `assets/models/mobileclip/onnx/text_model.onnx`
- Associated tokenizer configurations

### 3. Configure AI Pro (Optional)
To use cloud-based FLUX generative edits in AI Pro mode:
1. Launch the application and log in (Default credentials: `admin` / `umar18123`).
2. **Long-press the Nippon Paint Logo** on the login screen to open Developer Settings.
3. Paste your [Replicate API token](https://replicate.com/account/api-tokens) and save.

---

## 📦 Building & Distribution

### Android APK Build
Build the universal Android release APK:
```powershell
flutter build apk --release
```
The generated release APK will be located at:
`build/app/outputs/flutter-apk/app-release.apk`

To generate smaller architecture-specific APKs:
```powershell
flutter build apk --split-per-abi
```

### Windows Desktop Build
Build the native Windows desktop release package:
```powershell
flutter build windows --release
```
The standalone Windows application will be located at:
`build/windows/x64/runner/Release/room_color_app.exe`

*(Note: When distributing on Windows, package the entire contents of the `Release/` directory, including DLLs and the `data/` asset directory).*

---

## 🛠️ Technology Stack

| Component | Technology |
|---|---|
| **Framework** | [Flutter](https://flutter.dev/) (Dart 3) |
| **Neural Inference Engine** | [ONNX Runtime](https://onnxruntime.ai/) (`onnxruntime` Flutter plugin) |
| **Edge Segmentation Model** | MobileSAM (`Acly/MobileSAM`) |
| **Zero-Shot Object Matching** | MobileCLIP (`Xenova/mobileclip_s0`) |
| **Generative Inpainting** | Replicate FLUX (`flux-kontext-dev`) |
| **Color & Image Processing** | Dart `image` package & CIELAB photometric transforms |
| **State & Navigation** | Flutter Material Design 3 |

---

*Developed for Nippon Paint ColorLab AI visualization workflows.*
