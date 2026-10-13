# Nippon ColorLab AI

Nippon ColorLab AI is an advanced, AI-powered cross-platform application designed for professional interior and exterior paint visualization. Built for paint consultants, interior designers, and homeowners, it allows users to preview authentic Nippon Paint fandeck colors with photorealistic accuracy on real-world room and exterior photos.

The app combines high-performance on-device Neural Networks (MobileSAM and MobileCLIP via ONNX Runtime) with cloud-based Generative AI (FLUX via Replicate) to provide instant, precise, and edge-perfect paint simulations.

---

## ✨ Core Features

### 🎨 Photorealistic Paint Rendering
- **Authentic Paint Reflectance**: Accurately reproduces target Nippon Paint lightness and chromaticity in CIELAB space. Deep tones (e.g., Navy Blue, Forest Green) show true saturation on white walls instead of washing out into pastels, while light creams and whites provide crisp, authentic coverage over darker walls.
- **Lighting & Texture Preservation**: Intelligently maintains natural ambient room illumination, shadow folds, surface textures, and window light falloff while keeping deep shadow crevices (sockets, switch plates, architectural recesses) naturally dark.

### 🧠 Dual AI Segmentation & Editing Modes
- **AI Lite (Fast, Private & 100% Offline)**:
  - Powered by on-device **MobileSAM** (Tiny-ViT image encoder and mask decoder) and **MobileCLIP** text/vision models running via **ONNX Runtime**.
  - **Natural Language Editing**: Type natural prompts like *"change wall to green"* or *"paint the ceiling soft cream"* completely offline.
  - **Surface Disambiguation**: Employs spatial priors and targeted negative prompting to cleanly differentiate walls from ceilings.
  - **Connected-Component Filtering**: Ensures masks strictly follow contiguous surfaces, eliminating stray neural network activations across opposite walls or disconnected patches.
- **AI Pro (Generative Image Editing)**:
  - Powered by Replicate's **FLUX** model.
  - Translates natural language requests infused with exact Nippon Paint shade names and hex codes into photorealistic generative redraws under ambient lighting.

### 📐 Architectural Edge & Seam Protection
- **Wall vs. Ceiling Separation**: Context-aware negative prompts in MobileSAM decoder suppress bleed across low-contrast ceiling creases and wall corners.
- **Luminance Gradient Barriers**: Fallback tap-to-color flood fill detects structural edge gradients, stopping color expansion at crown moldings, baseboards, and corner joints.

### ☀️ Absolute Sky Protection
- **Intelligent Sky Detection**: Automatically identifies blue daylight and overcast white-grey skies in exterior photos and window views.
- **Paint Exclusion**: Sky pixels are permanently protected from recoloring across all modes (tap, brush, AI prompt, and flood fill). Direct taps and prompts targeting the sky are politely intercepted.

### 🔍 Interactive Before & After Client Comparison
- **Split Comparison Slider**: Toggle the interactive comparison mode (`Icons.compare`) to reveal a draggable split-view handle labeled *"Before"* and *"After"*, letting clients inspect the transformation in real time.

### 📚 Nippon Paint Colour Catalogue
- **Fandeck Browsing**: Browse thousands of authentic Nippon Paint colors categorized into color families (Reds, Blues, Greens, Neutrals, etc.).
- **Search by Name & HEX**: Instantly search colors by name or hex code.
- **Swatches & Details**: Inspect RGB, HEX, and color metrics with one-tap copy functionality.
- **CSV Export**: Export and share the entire Nippon Paint fandeck catalogue as a structured CSV file.

### 💻 Client Consultation Workflow
- **Surface-Aware Prompts**: Tapping a surface automatically detects whether it is a wall or ceiling, labeling the dialog (e.g., *"Paint Wall with Nippon Paint"* or *"Paint Ceiling with Nippon Paint"*).
- **Prioritized Swatches**: Your actively chosen fandeck swatch is presented first for one-tap application, accompanied by matching and popular designer recommendations.

---

## 🚀 Getting Started

### 1. Prerequisites
- **Flutter SDK** (3.47+ recommended)
- **Python 3** (required for downloading local ONNX neural network weights)
- **Android SDK & Command-line Tools** (for Android APK builds)
- **Visual Studio 2022/2026 with C++ Desktop Workload** (for Windows Desktop builds)

### 2. Download AI Models (Offline AI Lite Mode)
Before running the application, download the pre-exported MobileSAM and MobileCLIP ONNX models:
```powershell
python download_models.py
```
This automatically fetches and verifies the models into `assets/models/mobilesam/` and `assets/models/mobileclip/`.

### 3. Configure AI Pro (Optional)
To use cloud-based FLUX generative edits in AI Pro mode:
1. Launch the application and log in (Default credentials: `admin` / `umar18123`).
2. **Long-press the Nippon Paint Logo** on the login screen to open Developer Settings.
3. Paste your [Replicate API token](https://replicate.com/account/api-tokens) and save.

---

## 📦 Building & Distribution

### Android APK Build
Build the standalone universal Android release APK:
```powershell
flutter build apk --release
```
* The generated release APK will be located at:
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
* The standalone Windows application will be located at:
  `build/windows/x64/runner/Release/room_color_app.exe`
* *Note: When distributing on Windows, package the entire contents of the `Release/` directory (including DLLs and the `data/` asset folder).*

---

## 🛠️ Technology Stack

| Component | Technology |
|---|---|
| **Framework** | [Flutter](https://flutter.dev/) (Dart 3) |
| **Neural Inference Engine** | [ONNX Runtime](https://onnxruntime.ai/) (`onnxruntime` Flutter plugin) |
| **Edge Segmentation Model** | MobileSAM (`Acly/MobileSAM`) |
| **Zero-Shot Object Matching** | MobileCLIP (`Xenova/mobileclip_s0`) |
| **Generative Inpainting** | Replicate FLUX (`flux-kontext-dev`) |
| **Image & Color Processing** | Dart `image` package & CIELAB photometric transforms |
| **Typography** | Google Fonts (Outfit) |

---

*Developed for Nippon Paint ColorLab AI visualization workflows.*
