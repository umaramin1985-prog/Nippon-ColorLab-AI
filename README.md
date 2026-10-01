# Nippon ColorLab AI

Nippon ColorLab AI is an advanced, AI-powered Flutter application designed to revolutionize interior and exterior paint visualization. By leveraging on-device Machine Learning and high-fidelity image processing, it empowers users to seamlessly experiment with real-world paint colors on their own photos.

## ✨ Core Features

- **Local AI Object Detection (Google ML Kit)**: Automatically detects distinct subjects in your room—such as walls, ceilings, and floors—without needing an internet connection.
- **Natural Language AI Assistant**: Talk to the app naturally! Type *"Change the colour of the ceiling to blue"*, and the app will instantly match your request with real Nippon Fandeck shades and accurately paint the ceiling.
- **Smart Color Blending Algorithm**: Our custom HSL-based blending logic preserves 3D lighting, ambient shadows, and naturally compresses highlights. Even extremely bright glossy reflections (shine) are beautifully tinted with your chosen paint color.
- **Magnetic Selection Boundaries**: Tap the Eye icon to view faint bounding outlines of detected room structures. Resize the global selection box, which magnetically snaps to object boundaries, allowing you to crop and isolate precisely where the paint is applied.
- **Magic Flood Fill**: Instantly fill custom regions by simply tapping them. Includes a granular **Tolerance Slider** to fine-tune how aggressively the color spreads across similar pixels.
- **Comprehensive Nippon Fandeck**: Browse and search through the massive dataset of official Nippon Paint colors to find your perfect shade.
- **Offline & Private**: Built with privacy in mind. All image processing and ML Kit segmentation happens strictly on-device.

## 🚀 Getting Started

### Prerequisites

- [Flutter SDK](https://flutter.dev/docs/get-started/install) (latest version)
- Dart SDK

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/umaramin1985-prog/Nippon-ColorLab-AI.git
   ```
2. Navigate to the project directory:
   ```bash
   cd Nippon-ColorLab-AI
   ```
3. Install dependencies:
   ```bash
   flutter pub get
   ```
4. Run the app:
   ```bash
   flutter run
   ```

## 🏗 Architecture

This project is built using Flutter and organized around key features, including:
- **Home Page**: The sleek entry point of the app where users can visualize photos, browse color inspiration, and access their gallery.
- **Editor Page**: The heavy-lifting workspace containing the AI Text Prompt, Interactive Canvas, ML Segmentation overlays, and Paint Tools.
- **Image Processor**: A highly optimized Dart Isolate worker that executes Flood Fill algorithms, HSL color-space conversions, and intelligent highlight blending without freezing the UI.
- **Models & Globals**: Contains the statically parsed global Fandeck JSON/CSV dataset initialized at startup.

## 💻 Technologies Used

- [Flutter](https://flutter.dev/) & [Dart](https://dart.dev/)
- [Google ML Kit Subject Segmentation](https://pub.dev/packages/google_mlkit_subject_segmentation)
- [Image (Dart Package)](https://pub.dev/packages/image)

---
*Developed with a focus on immersive aesthetics and AI-driven workflows.*
