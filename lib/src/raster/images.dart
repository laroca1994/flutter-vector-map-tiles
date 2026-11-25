import 'dart:typed_data';
import 'dart:ui';

/// The image in [bytes], at [size] pixels square when given: decoding it
/// smaller costs less memory than decoding it whole and drawing it smaller.
Future<Image> imageFrom({required Uint8List bytes, int? size}) async {
  final codec =
      await instantiateImageCodec(bytes, targetWidth: size, targetHeight: size);
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
  }
}
