import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/uploads/image_pipeline.dart';
import '../theme/neu.dart';
import 'neu_box.dart';

/// Proof of delivery. The receiver's name and this are both required: tapping
/// "Mark delivered" opens the capture screen, and only a successful capture
/// completes the delivery.
class SignaturePad extends StatefulWidget {
  const SignaturePad({super.key, required this.controller, this.height = 150});

  final SignatureController controller;
  final double height;

  @override
  State<SignaturePad> createState() => _SignaturePadState();
}

class SignatureController extends ChangeNotifier {
  final List<List<Offset>> strokes = [];
  Size size = Size.zero;

  bool get isEmpty => strokes.every((s) => s.length < 2);

  void start(Offset point) {
    strokes.add([point]);
    notifyListeners();
  }

  void extend(Offset point) {
    if (strokes.isEmpty) strokes.add([]);
    strokes.last.add(point);
    notifyListeners();
  }

  void clear() {
    strokes.clear();
    notifyListeners();
  }

  /// Renders to a PNG in the staging directory. Returns null when nothing was
  /// drawn — the caller must not let the delivery through in that case.
  Future<File?> render({Color ink = const Color(0xFF1F2A4D)}) async {
    if (isEmpty || size == Size.zero) return null;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final paint = Paint()
      ..color = ink
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final stroke in strokes) {
      if (stroke.length < 2) continue;
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (final point in stroke.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, paint);
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.round() * 2, size.height.round() * 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return null;

    final dir = await ImagePipeline.stagingDirectory();
    final file = File(p.join(dir.path, 'signature_${DateTime.now().microsecondsSinceEpoch}.png'));
    await file.writeAsBytes(bytes.buffer.asUint8List());
    return file;
  }
}

class _SignaturePadState extends State<SignaturePad> {
  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return NeuBox(
      style: NeuStyle.inset,
      radius: 20,
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          widget.controller.size = Size(constraints.maxWidth, constraints.maxHeight);
          return GestureDetector(
            onPanStart: (d) => widget.controller.start(d.localPosition),
            onPanUpdate: (d) => widget.controller.extend(d.localPosition),
            behavior: HitTestBehavior.opaque,
            child: AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) => CustomPaint(
                painter: _SignaturePainter(widget.controller.strokes, c.ink),
                size: Size.infinite,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  _SignaturePainter(this.strokes, this.ink);

  final List<List<Offset>> strokes;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = ink
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final stroke in strokes) {
      if (stroke.length < 2) continue;
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (final point in stroke.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_SignaturePainter old) => true;
}

/// In-memory only: a jangad is a customer's handwritten slip, so it never goes
/// into a shared on-disk image cache.
class JangadImage extends StatelessWidget {
  const JangadImage({super.key, required this.bytes, this.height = 248});

  final Uint8List? bytes;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    if (bytes == null) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text('Page not on this phone', style: NeuText.body_(c.inkFaint)),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(bytes!, height: height, fit: BoxFit.contain),
    );
  }
}
