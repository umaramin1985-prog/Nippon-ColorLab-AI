# ColorVision AI

ColorVision AI (formerly Nippon ColorLab AI) is an advanced, AI-powered mobile application designed to revolutionize interior and exterior paint visualization. By leveraging both on-device Machine Learning and cloud-based Generative AI, it empowers users to seamlessly experiment with real-world paint colors on their own photos.

## 📁 Project Structure

This project is a Flutter application (iOS, Android). The entire codebase is contained within the root directory.

## ✨ Core Features

- **Dual AI Modes**:
  - **AI Lite (Fast, Private & Offline)**: Powered by entirely on-device ONNX Runtime inference using MobileSAM and MobileCLIP. Allows for natural-language zero-shot segmentation (e.g. "change wall to green") entirely offline without any server. Creates a precise mask and mathematically tints it with your selected Fandeck color.
  - **AI Pro (Generative Image Editing)**: Powered by Replicate's FLUX model (`black-forest-labs/flux-kontext-dev`). Sends natural language prompts infused with semantic color names and exact hex codes directly to a cloud AI to physically redraw and edit the image with perfect lighting and shadows.
- **Smart Color Suggestions on Tap**: Simply tap on any detected object in your photo! The app instantly identifies the object using MobileSAM and opens a beautiful bottom sheet offering intelligent color recommendations.
- **Search & Apply**: Directly from the suggestion modal, you can search the massive dataset of official Fandeck colors and instantly apply your perfect shade.
- **Natural Language AI Assistant**: Talk to the app naturally! Type *"Change the colour of the left wall to red"*, and the app will instantly match your request with real Fandeck shades.
- **Smart Color Blending Algorithm**: (Used in Lite and Manual modes) Our custom LAB-based blending logic preserves 3D lighting, ambient shadows, and naturally compresses highlights.
- **Magic Flood Fill**: Instantly fill custom regions by tapping them. Includes a granular **Tolerance Slider** to fine-tune how aggressively the color spreads across similar pixels.

## 🚀 Getting Started

### 1. Prerequisites
- Flutter SDK installed
- Python 3 installed (for downloading ONNX models)
- An active Replicate API token (for AI Pro features)

### 2. Initial Setup (Download AI Models)
Before running the app, you must download the local ONNX ML models for AI Lite mode. We have provided a python script to do this automatically:
```bash
python download_models.py
```
This will download MobileSAM and MobileCLIP models directly into the `assets/models/` directory.

### 3. Configuration (API Token)
To use the advanced **AI Pro** natural language generative editing, you need to configure your Replicate API token.
1. Run the app and go to the Login screen.
2. **Long-press the Nippon Paint Logo** to open the hidden Developer Settings modal.
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
- [Image (Dart Package)](https://pub.dev/packages/image)

---
*Developed with a focus on immersive aesthetics and AI-driven workflows. Powered by prynivo.com.*
