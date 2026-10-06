# ColorVision AI

ColorVision AI (formerly Nippon ColorLab AI) is an advanced, AI-powered full-stack application designed to revolutionize interior and exterior paint visualization. By leveraging both on-device Machine Learning and a powerful backend Segmentation API, it empowers users to seamlessly experiment with real-world paint colors on their own photos.

## 📁 Project Structure

This project is a monorepo containing both the Flutter application and the Python AI server:
- `frontend/` - The Flutter application code (iOS, Android).
- `backend/` - The FastAPI Python server powering the AI Pro segmentation models.

## ✨ Core Features

- **Dual AI Segmentation Modes**:
  - **AI Lite (Fast & Offline)**: Powered by Google ML Kit Subject Segmentation. Perfect for detecting foreground objects strictly on-device without an internet connection.
  - **AI Pro (Meta SAM Backend)**: A live, production-ready PyTorch backend utilizing Google's OWL-ViT and Meta's Segment Anything Model (SAM) for zero-shot text-to-mask segmentation. Automatically disables itself safely if the backend server is unreachable.
- **Smart Color Suggestions on Tap**: Simply tap on any detected object in your photo! The app instantly identifies the object and opens a beautiful bottom sheet offering intelligent color recommendations.
- **Search & Apply**: Directly from the suggestion modal, you can search the massive dataset of official Fandeck colors and instantly apply your perfect shade.
- **Natural Language AI Assistant**: Talk to the app naturally! Type *"Change the colour of the left wall to blue"*, and the app will instantly match your request with real Fandeck shades, find the wall via AI Pro, and accurately paint it.
- **Smart Color Blending Algorithm**: Our custom HSL-based blending logic preserves 3D lighting, ambient shadows, and naturally compresses highlights.
- **Magic Flood Fill**: Instantly fill custom regions by tapping them. Includes a granular **Tolerance Slider** to fine-tune how aggressively the color spreads across similar pixels.
- **Memory Optimized**: Uses native OS-level image compression limits to process massive 24MP smartphone camera photos instantly without out-of-memory crashes.

## 🚀 Getting Started

### 1. Running the AI Pro Backend

To use the advanced **AI Pro** natural language segmentation, start the local PyTorch API. We've included a fully automated script for Windows!

1. Navigate to the backend directory:
   ```bash
   cd backend
   ```
2. Simply double-click or run the startup script:
   ```bash
   .\start.bat
   ```
   *(This script automatically creates a Python virtual environment, safely installs the CUDA-enabled versions of PyTorch so it runs lightning-fast on your GPU, installs all dependencies, and starts the server!)*

### 2. Running the Flutter App (Frontend)

1. Open a new terminal and navigate to the frontend directory:
   ```bash
   cd frontend
   ```
2. Install Flutter dependencies:
   ```bash
   flutter pub get
   ```
3. Run the app:
   ```bash
   flutter run
   ```

*(Note: The Flutter app has a built-in health check. If you don't start the Python backend, the app will still work perfectly, but the "AI Pro" features will gracefully grey themselves out!)*

## 💻 Technologies Used

- [Flutter](https://flutter.dev/) & [Dart](https://dart.dev/)
- [FastAPI](https://fastapi.tiangolo.com/) & Python
- [PyTorch](https://pytorch.org/) & [HuggingFace Transformers](https://huggingface.co/) (OWL-ViT, Meta SAM)
- [Google ML Kit Subject Segmentation](https://pub.dev/packages/google_mlkit_subject_segmentation)
- [Image (Dart Package)](https://pub.dev/packages/image)

---
*Developed with a focus on immersive aesthetics and AI-driven workflows. Powered by prynivo.com.*
