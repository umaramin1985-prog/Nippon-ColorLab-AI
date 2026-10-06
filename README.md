# Nippon ColorLab AI

Nippon ColorLab AI is an advanced, AI-powered Flutter application designed to revolutionize interior and exterior paint visualization. By leveraging both on-device Machine Learning and a powerful backend Segmentation API, it empowers users to seamlessly experiment with real-world paint colors on their own photos.

## ✨ Core Features

- **Dual AI Segmentation Modes**:
  - **AI Lite (Fast & Offline)**: Powered by Google ML Kit Subject Segmentation. Perfect for detecting foreground objects (furniture, people, etc.) strictly on-device without an internet connection.
  - **AI Pro (Meta SAM Backend)**: A live, production-ready PyTorch backend utilizing Google's OWL-ViT and Meta's Segment Anything Model (SAM) for zero-shot text-to-mask segmentation. It can accurately segment flat background surfaces like walls, floors, and ceilings.
- **Smart Color Suggestions on Tap**: Simply tap on any detected object in your photo! The app instantly identifies the object and opens a beautiful bottom sheet offering intelligent color recommendations.
- **Search & Apply**: Directly from the suggestion modal, you can search the massive dataset of official Nippon Paint colors and instantly apply your perfect shade.
- **Natural Language AI Assistant**: Talk to the app naturally! Type *"Change the colour of the left wall to blue"*, and the app will instantly match your request with real Nippon Fandeck shades, find the wall via AI Pro, and accurately paint it.
- **Smart Color Blending Algorithm**: Our custom HSL-based blending logic preserves 3D lighting, ambient shadows, and naturally compresses highlights. Even extremely bright glossy reflections (shine) are beautifully tinted with your chosen paint color.
- **Magic Flood Fill**: Instantly fill custom regions by tapping them. Includes a granular **Tolerance Slider** to fine-tune how aggressively the color spreads across similar pixels.
- **Premium Branded UI**: A sleek, custom-animated login screen and dark-mode aesthetic designed for Nippon Paint Pakistan, powered by prynivo.com.

## 🚀 Getting Started

### Prerequisites

- [Flutter SDK](https://flutter.dev/docs/get-started/install) (latest version)
- Python 3.9+ (For running the AI Pro backend)

### Running the AI Pro Backend (Optional but Recommended)

To use the advanced **AI Pro** segmentation, you must start the local PyTorch API:

1. Navigate to the backend directory:
   ```bash
   cd backend
   ```
2. Install the required Python dependencies:
   ```bash
   pip install -r requirements.txt
   ```
3. Run the FastAPI server:
   ```bash
   python main.py
   ```
   *(Note: The server will automatically use a GPU if available, or fall back to your CPU. The first run will take a few minutes to download the OWL-ViT and SAM models.)*

### Running the Flutter App

1. Ensure your backend is running, then open a new terminal at the project root.
2. Install Flutter dependencies:
   ```bash
   flutter pub get
   ```
3. Run the app:
   ```bash
   flutter run
   ```

## 🏗 Architecture

This project is built using Flutter (Frontend) and Python (Backend):
- **Editor Page**: The heavy-lifting workspace containing the interactive canvas, AI Assistant, Paint Tools, and Mode selectors.
- **AI Segmentation Services**: An abstraction layer (`AISegmentationService`) decoupling the `LiteSegmentationService` (Google ML Kit) and `ProSegmentationService` (HTTP requests to Python backend).
- **Image Processor**: A highly optimized Dart Isolate worker that executes Flood Fill algorithms and HSL color-space conversions.
- **Backend API**: A `FastAPI` instance hosting a zero-shot grounded segmentation pipeline (OWL-ViT + SAM) capable of responding to natural language spatial prompts ("left wall", "ceiling").

## 💻 Technologies Used

- [Flutter](https://flutter.dev/) & [Dart](https://dart.dev/)
- [FastAPI](https://fastapi.tiangolo.com/) & Python
- [PyTorch](https://pytorch.org/) & [HuggingFace Transformers](https://huggingface.co/) (OWL-ViT, Meta SAM)
- [Google ML Kit Subject Segmentation](https://pub.dev/packages/google_mlkit_subject_segmentation)
- [Image (Dart Package)](https://pub.dev/packages/image)

---
*Developed with a focus on immersive aesthetics and AI-driven workflows. Powered by prynivo.com.*
