# ColorVision AI

ColorVision AI (formerly Nippon ColorLab AI) is an advanced, AI-powered mobile application designed to revolutionize interior and exterior paint visualization. By leveraging both on-device Machine Learning and cloud-based Generative AI, it empowers users to seamlessly experiment with real-world paint colors on their own photos.

## 📁 Project Structure

This project is a Flutter application (iOS, Android). The entire codebase is contained within the root directory.

## ✨ Core Features

- **Dual AI Modes**:
  - **AI Lite (Fast, Private & Offline)**: Powered by Google ML Kit Subject Segmentation. Perfect for detecting foreground objects strictly on-device without an internet connection. Creates a precise mask and mathematically tints it with your selected Fandeck color.
  - **AI Pro (Generative Image Editing)**: Powered by Replicate's FLUX model (`black-forest-labs/flux-kontext-dev`). Sends natural language prompts (e.g., "change gate color to #C8102E") directly to a cloud AI to physically redraw and edit the image with perfect lighting and shadows.
- **Smart Color Suggestions on Tap**: Simply tap on any detected object in your photo! The app instantly identifies the object (in Lite mode) and opens a beautiful bottom sheet offering intelligent color recommendations.
- **Search & Apply**: Directly from the suggestion modal, you can search the massive dataset of official Fandeck colors and instantly apply your perfect shade.
- **Natural Language AI Assistant**: Talk to the app naturally! Type *"Change the colour of the left wall to red"*, and the app will instantly match your request with real Fandeck shades and use AI Pro to realistically paint it using the exact hex code of your selected shade.
- **Smart Color Blending Algorithm**: (Used in Lite and Manual modes) Our custom HSL-based blending logic preserves 3D lighting, ambient shadows, and naturally compresses highlights.
- **Magic Flood Fill**: Instantly fill custom regions by tapping them. Includes a granular **Tolerance Slider** to fine-tune how aggressively the color spreads across similar pixels.

## 🚀 Getting Started

### 1. Prerequisites
- Flutter SDK installed
- An active Replicate API token (for AI Pro features)

### 2. Configuration
To use the advanced **AI Pro** natural language generative editing, you need to configure your Replicate API token.
1. Open `lib/services/pro_segmentation_service.dart`.
2. Locate the `_apiToken` variable and replace it with your active Replicate API key.

### 3. Running the Flutter App

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
- [Replicate API](https://replicate.com/) (FLUX Generative Image Editing)
- [Google ML Kit Subject Segmentation](https://pub.dev/packages/google_mlkit_subject_segmentation)
- [Image (Dart Package)](https://pub.dev/packages/image)

---
*Developed with a focus on immersive aesthetics and AI-driven workflows. Powered by prynivo.com.*
