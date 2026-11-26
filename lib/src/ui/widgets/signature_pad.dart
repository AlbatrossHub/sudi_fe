import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/uploads/image_pipeline.dart';
import '../theme/neu.dart';
import 'neu_box.dart';

/// Proof of delivery. The receiver's name and this are both required: tapping
/// "Mark delivered" opens the capture screen, and only a successful capture
/// completes the delivery.
class SignaturePad extends StatefulWidget {
  const SignaturePad({super.key, required this.controller, this.height});

  final SignatureController controller;

  /// Fixed height, or null for the default: the full width at a wide
  /// signing ratio, so a client can sign with the whole hand.
  final double? height;

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

  /// The strokes as plain numbers, so a half-signed delivery survives the app
  /// being killed. Kept in the encrypted draft store, never as an image file.
  Map<String, dynamic> toJson() => {
        'strokes': [
          for (final s in strokes) [for (final p in s) ...[p.dx, p.dy]],
        ],
      };

  void load(Map<String, dynamic>? json) {
    final raw = json?['strokes'];
    if (raw is! List) return;
    strokes
      ..clear()
      ..addAll([
        for (final s in raw.whereType<List>())
          [
            for (var i = 0; i + 1 < s.length; i += 2)
              Offset((s[i] as num).toDouble(), (s[i + 1] as num).toDouble()),
          ],
      ]);
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
    Offset inside(Offset point) => Offset(
          point.dx.clamp(0.0, size.width),
          point.dy.clamp(0.0, size.height),
        );
    for (final stroke in strokes) {
      if (stroke.length < 2) continue;
      final first = inside(stroke.first);
      final path = Path()..moveTo(first.dx, first.dy);
      for (final point in stroke.skip(1)) {
        final p = inside(point);
        path.lineTo(p.dx, p.dy);
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

/// Claims the pointer the moment it lands, so a stroke that happens to move
/// vertically can never become a page scroll: on this pad, a touch is ink,
/// and the page is scrolled from outside the pad.
class _InkFirstPanRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }

  @override
  void rejectGesture(int pointer) => acceptGesture(pointer);
}

class _SignaturePadState extends State<SignaturePad> {
  /// A finger that wanders past the edge keeps drawing along it instead of
  /// inking the rest of the screen: the stroke is clamped into the pad.
  Offset _inside(Offset point, Size size) => Offset(
        point.dx.clamp(0.0, size.width),
        point.dy.clamp(0.0, size.height),
      );

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final pad = NeuBox(
      style: NeuStyle.inset,
      radius: 20,
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          widget.controller.size = size;
          return RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              _InkFirstPanRecognizer:
                  GestureRecognizerFactoryWithHandlers<_InkFirstPanRecognizer>(
                () => _InkFirstPanRecognizer(),
                (recognizer) => recognizer
                  ..onStart = ((d) {
                    widget.controller.start(_inside(d.localPosition, size));
                  })
                  ..onUpdate = ((d) {
                    widget.controller.extend(_inside(d.localPosition, size));
                  }),
              ),
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: AnimatedBuilder(
                animation: widget.controller,
                builder: (context, _) => CustomPaint(
                  painter: _SignaturePainter(widget.controller.strokes, c.ink),
                  size: Size.infinite,
                ),
              ),
            ),
          );
        },
      ),
    );
    if (widget.height != null) return pad;
    return AspectRatio(aspectRatio: 1.2, child: pad);
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
