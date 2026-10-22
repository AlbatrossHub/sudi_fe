import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../config/env.dart';

/// Capture and compression.
///
/// The numbers are not arbitrary: a jangad is a handwritten slip and the digits
/// on it are the entire point of the photograph. **Do not go below 1600 px** —
/// losing a `3` that reads as an `8` costs more than every byte it saves.
class ImagePipeline {
  ImagePipeline([ImagePicker? picker]) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  Future<File?> capture({bool fromGallery = false}) async {
    final shot = await _picker.pickImage(
      source: fromGallery ? ImageSource.gallery : ImageSource.camera,
      // A max constraint that preserves aspect: the long edge lands here.
      maxWidth: Env.imageLongEdge.toDouble(),
      maxHeight: Env.imageLongEdge.toDouble(),
      imageQuality: 90,
      requestFullMetadata: false,
      // A jangad is a slip on a table, never a selfie; the camera app otherwise
      // reopens on whichever lens it last used (found on the M31: the front one).
      preferredCameraDevice: CameraDevice.rear,
    );
    if (shot == null) return null;
    return compress(File(shot.path));
  }

  /// Re-encode at q80 and strip EXIF (orientation is already baked in by the
  /// picker). Expect 250–400 KB per page.
  Future<File> compress(File source) async {
    final dir = await stagingDirectory();
    final target = p.join(
      dir.path,
      'page_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    try {
      final result = await FlutterImageCompress.compressAndGetFile(
        source.absolute.path,
        target,
        quality: Env.imageQuality,
        keepExif: false,
        format: CompressFormat.jpeg,
      );
      if (result != null) {
        return File(result.path);
      }
    } catch (_) {
      // Fall through: an uncompressed page beats a page we refused to take.
    }
    final copy = await source.copy(target);
    return copy;
  }

  /// Kept in the app's private directory and deleted only once the *intent*
  /// is acknowledged — not when the upload is. An upload nothing claims is
  /// collected server-side after seven days.
  static Future<Directory> stagingDirectory() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'staged'));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<String> digest(File file) async {
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  static Future<int> stagedBytes() async {
    final dir = await stagingDirectory();
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  /// Warn *before* capture when close to the cap. A full disk in the middle of
  /// a round is worse than a photo the app politely declined to take.
  static Future<bool> hasRoom() async =>
      (await stagedBytes()) < Env.stagedImageCapBytes;
}
