import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/rust/api/engine_api.dart' as rust_engine;

final _log = Logger();

enum LlmStatus { notDownloaded, downloading, ready, loading, loaded, error }

/// Manages the on-device LLM lifecycle: download, load, infer, unload.
///
/// Uses SmolLM2 1.7B Instruct (Q4_K_M, ~1.06 GB) for intent classification
/// and contextual understanding. Downloads on first use.
class LlmService {
  LlmService._();
  static final instance = LlmService._();

  static const _prefKey = 'llm_downloaded_v3';

  // HuggingFace direct download URLs (official HuggingFace repo)
  static const _modelUrl =
      'https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF/resolve/main/smollm2-1.7b-instruct-q4_k_m.gguf';
  static const _tokenizerUrl =
      'https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct/resolve/main/tokenizer.json';

  LlmStatus _status = LlmStatus.notDownloaded;
  LlmStatus get status => _status;

  double _downloadProgress = 0;
  double get downloadProgress => _downloadProgress;

  String? _error;
  String? get error => _error;

  final _statusController = StreamController<LlmStatus>.broadcast();
  Stream<LlmStatus> get statusStream => _statusController.stream;

  void _setStatus(LlmStatus s) {
    _status = s;
    _statusController.add(s);
  }

  /// Check if the model files exist on disk.
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final downloaded = prefs.getBool(_prefKey) ?? false;
    if (!downloaded) {
      _setStatus(LlmStatus.notDownloaded);
      return;
    }
    final paths = await _paths();
    if (paths.$1.existsSync() && paths.$2.existsSync()) {
      _setStatus(LlmStatus.ready);
    } else {
      _setStatus(LlmStatus.notDownloaded);
    }
  }

  /// Download the model and tokenizer. Streams progress (0.0 – 1.0).
  Future<void> download({
    void Function(double progress)? onProgress,
  }) async {
    if (_status == LlmStatus.downloading) return;
    _setStatus(LlmStatus.downloading);
    _downloadProgress = 0;

    try {
      final paths = await _paths();
      final modelFile = paths.$1;
      final tokenizerFile = paths.$2;

      // Create directory
      final dir = modelFile.parent;
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      // Download tokenizer first (small, <2MB)
      _log.i('[LLM] Downloading tokenizer...');
      final tokResp = await http.get(Uri.parse(_tokenizerUrl));
      if (tokResp.statusCode != 200) {
        throw Exception('Tokenizer download failed: ${tokResp.statusCode}');
      }
      await tokenizerFile.writeAsBytes(tokResp.bodyBytes);
      _log.i('[LLM] Tokenizer saved (${tokResp.bodyBytes.length} bytes)');

      // Download model (large, ~1.1GB) with progress
      _log.i('[LLM] Downloading model...');
      final request = http.Request('GET', Uri.parse(_modelUrl));
      final streamedResp = await http.Client().send(request);
      if (streamedResp.statusCode != 200) {
        throw Exception('Model download failed: ${streamedResp.statusCode}');
      }

      final totalBytes = streamedResp.contentLength ?? 1060000000;
      var receivedBytes = 0;
      final sink = modelFile.openWrite();

      await for (final chunk in streamedResp.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        _downloadProgress = receivedBytes / totalBytes;
        onProgress?.call(_downloadProgress);
      }
      await sink.close();
      _log.i('[LLM] Model saved ($receivedBytes bytes)');

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, true);

      _setStatus(LlmStatus.ready);
    } catch (e) {
      _error = '$e';
      _setStatus(LlmStatus.error);
      _log.e('[LLM] Download failed: $e');
    }
  }

  /// Load the model into memory. Takes ~2-5 seconds.
  Future<void> loadModel() async {
    if (_status == LlmStatus.loaded) return;
    _setStatus(LlmStatus.loading);

    try {
      final paths = await _paths();
      await rust_engine.engineLlmLoad(
        modelPath: paths.$1.path,
        tokenizerPath: paths.$2.path,
      );
      _setStatus(LlmStatus.loaded);
      _log.i('[LLM] Model loaded');
    } catch (e) {
      _error = '$e';
      _setStatus(LlmStatus.error);
      _log.e('[LLM] Load failed: $e');
    }
  }

  /// Unload the model to free memory.
  Future<void> unloadModel() async {
    try {
      await rust_engine.engineLlmUnload();
    } catch (_) {}
    _setStatus(LlmStatus.ready);
  }

  /// Run inference for intent classification.
  /// Returns the raw JSON string from the model.
  ///
  /// [context] is optional recent conversation state (e.g., last shown markets)
  /// that helps the model resolve ambiguous references like "bet on the first one".
  Future<String> classifyIntent(String userInput, {String? context}) async {
    if (_status != LlmStatus.loaded) {
      throw Exception('Model not loaded');
    }
    final prompt = await rust_engine.engineLlmBuildIntentPrompt(
      userInput: context != null ? '$context\nUser: $userInput' : userInput,
    );
    final result = await rust_engine.engineLlmInfer(
      prompt: prompt,
      maxTokens: 64,
      temperature: 0.0,
    );
    return result;
  }

  /// Run free-form inference (for conversational follow-ups).
  Future<String> chat(String prompt, {int maxTokens = 256}) async {
    if (_status != LlmStatus.loaded) {
      throw Exception('Model not loaded');
    }
    return rust_engine.engineLlmInfer(
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: 0.7,
    );
  }

  /// Generate a helpful suggestion when the user's intent is unknown.
  Future<String?> suggestForUnknown(String userInput) async {
    if (_status != LlmStatus.loaded) return null;
    try {
      final prompt = '<|im_start|>system\n'
          'You are a helpful wallet assistant. The user said something you don\'t understand. '
          'Briefly suggest what they might mean or list 2-3 things you can help with. '
          'Keep it under 2 sentences. Do not use emojis.<|im_end|>\n'
          '<|im_start|>user\n$userInput<|im_end|>\n'
          '<|im_start|>assistant\n';
      final result = await rust_engine.engineLlmInfer(
        prompt: prompt,
        maxTokens: 64,
        temperature: 0.3,
      );
      return result.isNotEmpty ? result : null;
    } catch (_) {
      return null;
    }
  }

  /// Generate a one-sentence market summary for bet confirmation.
  Future<String?> summarizeMarket({
    required String title,
    required List<Map<String, dynamic>> outcomes,
  }) async {
    if (_status != LlmStatus.loaded) return null;
    try {
      final outcomeStr = outcomes.map((o) {
        final name = o['title'] ?? '?';
        final price = ((o['price'] as num?)?.toDouble() ?? 0) * 100;
        return '$name: ${price.toStringAsFixed(0)}%';
      }).join(', ');

      final prompt = '<|im_start|>system\n'
          'Summarize this prediction market in one plain-English sentence for a non-technical user. '
          'No jargon. No emojis. Just the key question and current odds.<|im_end|>\n'
          '<|im_start|>user\n'
          'Market: "$title"\nOutcomes: $outcomeStr<|im_end|>\n'
          '<|im_start|>assistant\n';
      final result = await rust_engine.engineLlmInfer(
        prompt: prompt,
        maxTokens: 48,
        temperature: 0.2,
      );
      return result.isNotEmpty ? result : null;
    } catch (_) {
      return null;
    }
  }

  /// Delete downloaded model files.
  Future<void> deleteModel() async {
    try {
      await unloadModel();
    } catch (_) {}
    final paths = await _paths();
    if (paths.$1.existsSync()) paths.$1.deleteSync();
    if (paths.$2.existsSync()) paths.$2.deleteSync();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
    _setStatus(LlmStatus.notDownloaded);
  }

  Future<(File, File)> _paths() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/llm');
    return (
      File('${dir.path}/model.gguf'),
      File('${dir.path}/tokenizer.json'),
    );
  }

  void dispose() {
    _statusController.close();
  }
}
