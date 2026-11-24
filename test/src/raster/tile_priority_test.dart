import 'dart:async';
import 'dart:ui' show Offset;

import 'package:executor_lib/executor_lib.dart';
import 'package:flutter_map/flutter_map.dart' show Epsg3857;
import 'package:latlong2/latlong.dart';
import 'package:test/test.dart';
import 'package:vector_map_tiles/src/raster/tile_priority.dart';

void main() {
  const crs = Epsg3857();
  const z = 16;
  const here = LatLng(-34.88, -56.16);
  final at = crs.latLngToOffset(here, z.toDouble()) / 256;
  final x0 = at.dx.floor();
  final y0 = at.dy.floor();
  TileFocus focusAt(LatLng where) => TileFocus()
    ..at = where
    ..crs = crs;

  Job<int, int> gated(int value, Completer<void> gate, List<int> ran) =>
      Job('job $value', (int v) async {
        await gate.future;
        ran.add(v);
        return v;
      }, value, deduplicationKey: null);

  RankedConcurrencyExecutor oneAtATime({int maxQueueSize = 100}) =>
      RankedConcurrencyExecutor(
          delegate: ImmediateExecutor(),
          concurrencyLimit: 1,
          maxQueueSize: maxQueueSize);

  test('the focus measures in tiles of the asked zoom', () {
    final focus = focusAt(here);
    expect(focus.distanceTo(x0, y0, z, 256), lessThan(0.5));
    expect(focus.distanceTo(x0 + 3, y0, z, 256), greaterThan(6));
    expect(TileFocus().distanceTo(x0, y0, z, 256), 0);
  });

  test('the nearest to the focus runs first, whatever the order asked',
      () async {
    final focus = focusAt(here);
    final gate = Completer<void>();
    final ran = <int>[];
    final executor = oneAtATime();
    TileTicket east(int dx) => TileTicket(x0 + dx, y0, z, 256, focus);
    final done = [
      executor.submitRanked(gated(9, gate, ran), east(9)), // takes the slot
      executor.submitRanked(gated(3, gate, ran), east(3)),
      executor.submitRanked(gated(1, gate, ran), east(1)),
      executor.submitRanked(gated(2, gate, ran), east(2)),
    ];
    gate.complete();
    await Future.wait(done);
    expect(ran, [9, 1, 2, 3]);
  });

  test(
      'a tile still near goes before newer ones far away: newer updates '
      'do not leave it at the back (24-11)', () async {
    final focus = focusAt(here);
    final gate = Completer<void>();
    final ran = <int>[];
    final executor = oneAtATime();
    final first = executor.submitRanked(
        gated(0, gate, ran), TileTicket(x0 + 5, y0, z, 256, focus));
    final old = executor.submitRanked(
        gated(1, gate, ran), TileTicket(x0, y0, z, 256, focus));
    await Future<void>.delayed(Duration.zero);
    final newer = [
      for (var i = 2; i < 5; i++)
        executor.submitRanked(
            gated(i, gate, ran), TileTicket(x0 + 2 + i, y0, z, 256, focus)),
    ];
    gate.complete();
    await Future.wait([first, old, ...newer]);
    expect(ran, [0, 1, 2, 3, 4]);
  });

  test('the place in line follows the focus as it moves', () async {
    final focus = focusAt(here);
    final gate = Completer<void>();
    final ran = <int>[];
    final executor = oneAtATime();
    final busy = executor.submitRanked(
        gated(0, gate, ran), TileTicket(x0, y0, z, 256, focus));
    final west = executor.submitRanked(
        gated(1, gate, ran), TileTicket(x0 - 4, y0, z, 256, focus));
    final east = executor.submitRanked(
        gated(2, gate, ran), TileTicket(x0 + 1, y0, z, 256, focus));
    // The camera went west before their turn came.
    focus.at =
        crs.offsetToLatLng((at + const Offset(-4, 0)) * 256, z.toDouble());
    gate.complete();
    await Future.wait([busy, west, east]);
    expect(ran, [0, 1, 2]);
  });

  test('the cancelled leave the line without running', () async {
    final focus = focusAt(here);
    final gate = Completer<void>();
    final ran = <int>[];
    var gone = false;
    final executor = oneAtATime();
    final busy = executor.submitRanked(
        gated(0, gate, ran), TileTicket(x0, y0, z, 256, focus));
    final cancelled = executor.submitRanked(gated(1, gate, ran),
        TileTicket(x0, y0, z, 256, focus, cancelled: () => gone));
    final kept = executor.submitRanked(
        gated(2, gate, ran), TileTicket(x0 + 3, y0, z, 256, focus));
    gone = true;
    gate.complete();
    await busy;
    await expectLater(cancelled, throwsA(isA<CancellationException>()));
    await kept;
    expect(ran, [0, 2]);
  });

  test('a full queue drops what goes last in line', () async {
    final focus = focusAt(here);
    final gate = Completer<void>();
    final ran = <int>[];
    final executor = oneAtATime(maxQueueSize: 2);
    final results = [
      for (var i = 0; i < 5; i++)
        executor.submitRanked(
            gated(i, gate, ran), TileTicket(x0 + i, y0, z, 256, focus)),
    ];
    final outcomes = Future.wait(results.map((f) => f
        .then<Object>((v) => v)
        .catchError((Object e) => e is CancellationException ? 'cut' : e)));
    gate.complete();
    expect(await outcomes, [0, 1, 2, 'cut', 'cut']);
  });
}
