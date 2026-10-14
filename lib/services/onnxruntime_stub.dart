class OrtEnv {
  static final OrtEnv instance = OrtEnv();
  void init() {}
  void release() {}
}

class OrtSessionOptions {
  void release() {}
  void setIntraOpNumThreads(int threads) {}
  void setSessionGraphOptimizationLevel(int level) {}
}

class OrtSession {
  static OrtSession fromBuffer(dynamic buffer, OrtSessionOptions options) => OrtSession();
  List<String> get inputNames => [];
  List<dynamic> run(OrtRunOptions options, Map<String, OrtValueTensor> inputs) => [];
  Future<List<dynamic>?> runAsync(OrtRunOptions options, Map<String, OrtValueTensor> inputs) async => [];
  void release() {}
}

class OrtValueTensor {
  static OrtValueTensor createTensorWithDataList(dynamic data, List<int> shape) => OrtValueTensor();
  void release() {}
  dynamic get value => null;
}

class OrtRunOptions {
  void release() {}
}
