import 'dart:async';

import 'package:executor_lib/executor_lib.dart';
import 'package:flutter_map/flutter_map.dart' show Epsg3857;
import 'package:latlong2/latlong.dart';
import 'package:test/test.dart';
import 'package:vector_map_tiles/src/raster/tile_priority.dart';

void main() {
  test('within one update, the nearest to the focus goes first', () async {
    // Una tanda en el orden de flutter_map —lejos primero, como en el mapa
    // inclinado—: el foco la reordena.
    final far = TileTicket.next(distance: 9);
    final near = TileTicket.next(distance: 1);
    final mid = TileTicket.next(distance: 4);
    final line = [far, near, mid]..sort();
    expect(line, [near, mid, far]);
    await Future<void>.delayed(Duration.zero);
    // Una tanda más nueva sigue yendo antes, aunque esté más lejos.
    final newer = TileTicket.next(distance: 100);
    expect(newer.compareTo(near), lessThan(0));
  });

  test('the focus measures in tiles of the asked zoom', () {
    const crs = Epsg3857();
    final focus = TileFocus()
      ..at = const LatLng(-34.88, -56.16)
      ..crs = crs;
    final at = crs.latLngToOffset(focus.at!, 16) / 256;
    final x = at.dx.floor();
    final y = at.dy.floor();
    expect(focus.distanceTo(x, y, 16, 256), lessThan(0.5));
    expect(focus.distanceTo(x + 3, y, 16, 256), greaterThan(6));
    expect(TileFocus().distanceTo(x, y, 16, 256), 0);
  });

  test('one update runs in the order it was asked: nearest first', () async {
    final gate = Completer<void>();
    final executor = RankedConcurrencyExecutor(
        delegate: ImmediateExecutor(), concurrencyLimit: 1, maxQueueSize: 100);
    final ran = <int>[];
    Job<int, int> job(int value) => Job('job $value', (int v) async {
          await gate.future;
          ran.add(v);
          return v;
        }, value, deduplicationKey: null);

    // The first one takes the only slot; the rest wait in line.
    final done = [for (var i = 0; i < 5; i++) executor.submit(job(i))];
    gate.complete();
    await Future.wait(done);
    expect(ran, [0, 1, 2, 3, 4]);
  });

  test('a newer update goes before what is left of an older one', () async {
    final gate = Completer<void>();
    final executor = RankedConcurrencyExecutor(
        delegate: ImmediateExecutor(), concurrencyLimit: 1, maxQueueSize: 100);
    final ran = <int>[];
    Job<int, int> job(int value) => Job('job $value', (int v) async {
          await gate.future;
          ran.add(v);
          return v;
        }, value, deduplicationKey: null);

    final first = [for (var i = 0; i < 3; i++) executor.submit(job(i))];
    await Future<void>.delayed(Duration.zero);
    final second = [for (var i = 10; i < 13; i++) executor.submit(job(i))];
    gate.complete();
    await Future.wait([...first, ...second]);
    expect(ran, [0, 10, 11, 12, 1, 2]);
  });

  test('a full queue drops what goes last in line', () async {
    final gate = Completer<void>();
    final executor = RankedConcurrencyExecutor(
        delegate: ImmediateExecutor(), concurrencyLimit: 1, maxQueueSize: 2);
    Job<int, int> job(int value) => Job('job $value', (int v) async {
          await gate.future;
          return v;
        }, value, deduplicationKey: null);

    final results = [for (var i = 0; i < 5; i++) executor.submit(job(i))];
    final outcomes = Future.wait(results.map((f) => f
        .then<Object>((v) => v)
        .catchError((Object e) => e is CancellationException ? 'cut' : e)));
    gate.complete();
    expect(await outcomes, [0, 1, 2, 'cut', 'cut']);
  });
}
