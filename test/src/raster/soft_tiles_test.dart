import 'dart:ui' show Offset;

import 'package:flutter_map/flutter_map.dart' show Epsg3857;
import 'package:latlong2/latlong.dart';
import 'package:test/test.dart';
import 'package:vector_map_tiles/src/raster/soft_tiles.dart';
import 'package:vector_map_tiles/src/raster/tile_priority.dart';

void main() {
  const crs = Epsg3857();
  const z = 17;
  const here = LatLng(-34.88, -56.16);
  final at = crs.latLngToOffset(here, z.toDouble()) / 256;
  final x0 = at.dx.floor();
  final y0 = at.dy.floor();
  TileFocus focusAt(LatLng where, {double? radius}) => TileFocus()
    ..at = where
    ..crs = crs
    ..sharpRadius = radius;
  TileTicket ticket(TileFocus focus, int x, int y, {bool Function()? gone}) =>
      TileTicket(x, y, z, 256, focus, cancelled: gone);

  group('sharp or soft', () {
    test('without a radius every tile is sharp', () {
      final focus = focusAt(here);
      expect(focus.isSharp(x0 + 20, y0 + 20, z, 256), isTrue);
    });

    test('with a radius, only the tiles within it', () {
      final focus = focusAt(here, radius: 4);
      expect(focus.isSharp(x0, y0, z, 256), isTrue);
      expect(focus.isSharp(x0 + 3, y0, z, 256), isTrue);
      expect(focus.isSharp(x0 + 6, y0, z, 256), isFalse);
      expect(focus.isSharp(x0 + 4, y0 + 4, z, 256), isFalse);
    });

    test('without a focus every tile is sharp', () {
      final focus = TileFocus()..sharpRadius = 4;
      expect(focus.isSharp(x0 + 20, y0, z, 256), isTrue);
    });
  });

  group('soft tiles', () {
    test('a soft tile is sent sharp once the focus comes near', () {
      final focus = focusAt(here, radius: 4);
      final soft = SoftTiles(focus);
      var sharpened = 0;
      final far = x0 + 10;
      soft.add(ticket(focus, far, y0), () => sharpened++);

      soft.check();
      expect(sharpened, 0);
      expect(soft.length, 1);

      // The user walks up to it.
      final there = crs.offsetToLatLng(
          Offset((far + 0.5) * 256, (y0 + 0.5) * 256), z.toDouble());
      focus.at = there;
      soft.check();
      expect(sharpened, 1);
      expect(soft.length, 0);

      // Once.
      soft.check();
      expect(sharpened, 1);
      soft.dispose();
    });

    test('a cancelled tile is dropped, never sharpened', () {
      final focus = focusAt(here, radius: 4);
      final soft = SoftTiles(focus);
      var gone = false;
      var sharpened = 0;
      soft.add(ticket(focus, x0 + 10, y0, gone: () => gone), () => sharpened++);

      gone = true;
      focus.sharpRadius = null;
      soft.check();
      expect(sharpened, 0);
      expect(soft.length, 0);
      soft.dispose();
    });

    test('leaving the tilted map sharpens every soft tile', () {
      final focus = focusAt(here, radius: 4);
      final soft = SoftTiles(focus);
      var sharpened = 0;
      soft
        ..add(ticket(focus, x0 + 10, y0), () => sharpened++)
        ..add(ticket(focus, x0, y0 + 12), () => sharpened++);

      focus.sharpRadius = null;
      soft.check();
      expect(sharpened, 2);
      soft.dispose();
    });
  });
}
