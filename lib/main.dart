import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:audio_streamer/audio_streamer.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const MaterialApp(
      home: VoiceHomePage(),
      debugShowCheckedModeBanner: false,
    ));

class VoiceHomePage extends StatefulWidget {
  const VoiceHomePage({super.key});
  @override
  State<VoiceHomePage> createState() => _VoiceHomePageState();
}

class _VoiceHomePageState extends State<VoiceHomePage> {
  Interpreter? _interpreter;
  StreamSubscription<List<double>>? _audioSub;

  String _statusText = "Press Start to Record";
  bool _isRecording = false;
  bool _isSafe = false;
  double _currentAmplitude = 0.0;
  String _debugInfo = "";
  List<bool> _safeHistory = []; // store safe/not safe for entire session

  static const int _requiredSamples = 15600;
  final List<double> _buffer = [];
  DateTime _lastRun = DateTime.now();

  // Safe class indices (Speech + minor background sounds, breathing removed)
  final Set<int> _safeClasses = {
    0, 1, 2, 3, 4, 5, 12, 13, 14, 19, 62, 63, 104, 132
  };

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    var status = await Permission.microphone.request();
    if (status.isGranted) {
      try {
        _interpreter = await Interpreter.fromAsset('assets/models/yamnet.tflite');
        print("✅ YAMNet READY");
      } catch (e) {
        setState(() {
          _statusText = "❌ Model Error: $e";
        });
      }
    } else {
      setState(() {
        _statusText = "❌ Microphone Permission Denied";
      });
    }
  }

  void _startRecording() {
    setState(() {
      _isRecording = true;
      _statusText = "Recording...";
      _debugInfo = "";
      _safeHistory.clear();
      _buffer.clear();
    });

    _audioSub = AudioStreamer().audioStream.listen((List<double> samples) {
      double maxAmp = samples.fold(0.0, (prev, e) => max(prev, e.abs()));
      setState(() => _currentAmplitude = maxAmp);

      _buffer.addAll(samples);

      if (_buffer.length >= _requiredSamples) {
        final now = DateTime.now();
        if (now.difference(_lastRun).inMilliseconds > 150) {
          final input = Float32List.fromList(
              _buffer.sublist(_buffer.length - _requiredSamples));
          _runInference(input);
          _lastRun = now;
        }
        if (_buffer.length > _requiredSamples * 2) {
          _buffer.removeRange(0, _buffer.length - _requiredSamples);
        }
      }
    });
  }

  void _stopRecording() {
    _audioSub?.cancel();
    _audioSub = null;
    setState(() {
      _isRecording = false;

      // Calculate overall session safety
      if (_safeHistory.isNotEmpty) {
        int safeCount = _safeHistory.where((s) => s).length;
        double safeRatio = safeCount / _safeHistory.length;
        _isSafe = safeRatio > 0.5; // >50% of session is safe
        _statusText = _isSafe ? "✅ OVERALL SAFE" : "❌ OVERALL NOT SAFE";
      } else {
        _statusText = "❌ NO AUDIO DETECTED";
        _isSafe = false;
      }
    });
  }

  void _runInference(Float32List input) {
    if (_interpreter == null) return;

    // Normalize input
    double maxVal = input.fold(0.0, (m, e) => max(m, e.abs()));
    for (int i = 0; i < input.length; i++) {
      input[i] = input[i] / (maxVal > 0.001 ? maxVal : 1.0);
      input[i] = input[i].clamp(-1.0, 1.0);
    }

    var output = [List.filled(521, 0.0)];
    try {
      _interpreter!.run(input, output);
      List<double> scores = output[0];

      double maxProb = scores.reduce(max);
      int maxIndex = scores.indexOf(maxProb);
      double speechScore = scores[0];

      bool isSilence = maxProb < 0.08 || _currentAmplitude < 0.01;
      bool isSafeNow = !isSilence &&
          (_safeClasses.contains(maxIndex) || (speechScore > 0.05 && maxProb < 0.85));

      _safeHistory.add(isSafeNow);

      // Update UI for live recording
      if (_isRecording) {
        setState(() {
          _debugInfo =
              "Class:$maxIndex ${_getClassName(maxIndex)} ${(maxProb*100).toStringAsFixed(0)}% "
              "Speech:${(speechScore*100).toStringAsFixed(0)}%";
          _statusText = isSilence
              ? "❌ SILENCE"
              : (isSafeNow ? "✅ SAFE" : "❌ NOT SAFE");
        });
      }

      print(
          "🎯 $maxIndex (${_getClassName(maxIndex)}) ${maxProb.toStringAsFixed(2)} "
          "Speech:${speechScore.toStringAsFixed(3)} "
          "${isSilence ? '🔇SILENCE' : isSafeNow ? '✅SAFE' : '❌NOT SAFE'} "
          "Amp:${(_currentAmplitude*100).toStringAsFixed(0)}%");
    } catch (e) {
      print("Error: $e");
    }
  }

  String _getClassName(int index) {
    Map<int, String> classNames = {
      0: "Speech",
      1: "Child speech",
      2: "Conversation",
      3: "Narration",
      4: "Babbling",
      5: "Speech Synth",
      12: "Whispering",
      13: "Laughter",
      14: "Baby laughter",
      19: "Crying",
      62: "Hubbub",
      63: "Children playing",
      104: "Water",
      132: "Click",
      34: "Breathing",
      294: "Breathing",
    };
    return classNames[index] ?? "Class $index";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _isSafe ? Colors.green.shade400 : Colors.red.shade500,
      body: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isSafe ? Icons.check_circle : Icons.mic_off,
              size: 160,
              color: Colors.white,
            ),
            const SizedBox(height: 40),
            Text(
              _statusText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 30),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(25),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  Text(
                    "📊 Vol: ${(_currentAmplitude*100).toStringAsFixed(0)}%",
                    style: const TextStyle(color: Colors.white, fontSize: 20),
                  ),
                  const SizedBox(height: 15),
                  Text(
                    _debugInfo,
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed:
                        _isRecording ? _stopRecording : _startRecording,
                    style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 50, vertical: 15),
                        backgroundColor: Colors.blueAccent),
                    child: Text(
                      _isRecording ? "Stop Recording" : "Start Recording",
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    "✅ SAFE = Voice / minor background\n❌ NOT SAFE = All others (incl. Breathing)",
                    style: TextStyle(
                      color: Color(0xFFFFD700),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _audioSub?.cancel();
    _interpreter?.close();
    super.dispose();
  }
}
