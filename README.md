# Nippon ColorLab AI

Nippon ColorLab AI is an advanced, AI-powered mobile application designed to revolutionize interior and exterior paint visualization. By leveraging both on-device Machine Learning and cloud-based Generative AI, it empowers users to seamlessly experiment with real-world Nippon Paint colors on their own photos.

## ✨ Core Features

- **Stunning Modern Aesthetic**: A custom-designed, breathtaking dark-mode interface utilizing glassmorphism, dynamic blur filters, vivid glowing accents (`#FF204E`), and elegant typography (Outfit font). 
- **Dual AI Modes**:
  - **AI Lite (Fast, Private & Offline)**: Powered by entirely on-device ONNX Runtime inference using MobileSAM and MobileCLIP. Allows for natural-language zero-shot segmentation (e.g. "change wall to green") entirely offline. Creates a precise mask and mathematically tints it with your selected Fandeck color.
  - **AI Pro (Generative Image Editing)**: Powered by Replicate's FLUX model. Sends natural language prompts infused with semantic color names and exact hex codes directly to a cloud AI to physically redraw and edit the image with perfect lighting.
- **Smart Color Suggestions**: Tap on any detected object in your photo! The app instantly identifies it using MobileSAM and opens a beautiful bottom sheet offering intelligent color recommendations.
- **Advanced Colour Catalogue**:
  - **Group by Family**: Filter thousands of Fandeck colors instantly by mathematically calculated color families (Reds, Blues, Greens, Neutrals, etc.).
  - **HEX Search**: Search the entire catalog effortlessly using color names or hex codes.
  - **Detailed Previews**: Tap any color to view a beautiful glassmorphic info sheet with Name, HEX, and RGB values (including instant Tap-to-Copy functionality).
  - **Share**: Export and share the entire Nippon Paint Colour Catalogue as a neatly formatted CSV file.
- **Gallery & Workspace**: View all your modified and saved visualizations in the unified Saved Images gallery.

## 🚀 Getting Started

### 1. Prerequisites
- Flutter SDK installed
- Python 3 installed (for downloading ONNX models)
- An active Replicate API token (for AI Pro features)

### 2. Initial Setup (Download AI Models)
Before running the app, you must download the local ONNX ML models for AI Lite mode. We have provided a Python script to do this automatically:
```bash
python download_models.py
```
This will download MobileSAM and MobileCLIP models directly into the `assets/models/` directory.

### 3. Configuration (API Token)
To use the advanced **AI Pro** natural language generative editing, you need to configure your Replicate API token.
1. Run the app and log in (Credentials: `admin` / `umar18123`).
2. **Long-press the Nippon Paint Logo** on the login screen to open the Developer Settings modal.
3. Paste your Replicate API key and press Save (persisted locally).

### 4. Running the Flutter App

1. Install Flutter dependencies:
   ```bash
   flutter pub get
   ```
2. Run the app:
   ```bash
   flutter run
   ```

## 💻 Technologies Used

- [Flutter](https://flutter.dev/) & [Dart](https://dart.dev/)
- [ONNX Runtime](https://pub.dev/packages/onnxruntime) (MobileSAM + MobileCLIP Zero-Shot Segmentation)
- [Replicate API](https://replicate.com/) (FLUX Generative Image Editing)
- Google Fonts (Outfit)

---
*Developed with a focus on immersive aesthetics and AI-driven workflows. Powered by prynivo.com.*
