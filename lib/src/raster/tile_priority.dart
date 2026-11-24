import 'dart:async';
import 'dart:ui' show Offset;

import 'package:executor_lib/executor_lib.dart';
import 'package:flutter_map/flutter_map.dart' show Crs;
import 'package:latlong2/latlong.dart';

/// **A raster tile request waiting for its turn.**
///
/// Its place in line is decided **when a turn comes up, not when it was
/// asked for**: the tile nearest to where the [focus] is *now* goes first,
/// whichever camera update asked for it, and between two equally near the
/// newer one. Deciding it at request time let a tile still on screen sit at
/// the back for as long as newer updates kept coming —which a map following
/// a bus does several times a second— until a hand moved the map.
///
/// Without a focus yet, the newest goes first, as the queues always did.
class TileTicket {
  TileTicket(this.x, this.y, this.z, this.tileSize, this.focus,
      {bool Function()? cancelled})
      : order = _next++,
        cancelled = cancelled ?? _never;

  final int x;
  final int y;
  final int z;
  final double tileSize;
  final TileFocus focus;

  /// Whether the tile is no longer wanted: it leaves the line at the next
  /// turn, before anything is picked.
  final bool Function() cancelled;

  /// The order it was asked in: higher is newer.
  final int order;

  static int _next = 0;
  static bool _never() => false;
}

/// **The point the tiles load around** (`VectorTileLayer.tileFocus`), kept
/// by the layer as the camera moves and read every time a turn comes up. It
/// is not a tile option: changing one makes flutter_map ask for every tile
/// again.
class TileFocus {
  LatLng? at;
  Crs? crs;

  /// How far the tile [x], [y] at [z] is from the focus, in tiles squared;
  /// 0 without a focus.
  double distanceTo(int x, int y, int z, double tileSize) {
    final at = this.at;
    final crs = this.crs;
    if (at == null || crs == null) {
      return 0;
    }
    final focus = crs.latLngToOffset(at, z.toDouble()) / tileSize;
    final dx = x + 0.5 - focus.dx;
    final dy = y + 0.5 - focus.dy;
    return dx * dx + dy * dy;
  }
}

double _distanceOf(TileTicket t) =>
    t.focus.distanceTo(t.x, t.y, t.z, t.tileSize);

/// Whether [a], [da] from its focus, goes before [b], [db] from its own.
bool _before(TileTicket a, double da, TileTicket b, double db) =>
    da != db ? da < db : a.order > b.order;

/// **Takes the cancelled out of [entries]** —each one handed to [drop]— and
/// returns the index of the one that goes first now, or `-1` if none is
/// left.
int takeTurn<T>(
    List<T> entries, TileTicket Function(T) ticketOf, void Function(T) drop) {
  for (var i = entries.length - 1; i >= 0; i--) {
    if (ticketOf(entries[i]).cancelled()) {
      drop(entries.removeAt(i));
    }
  }
  var best = -1;
  var bestDistance = 0.0;
  for (var i = 0; i < entries.length; i++) {
    final t = ticketOf(entries[i]);
    final d = _distanceOf(t);
    if (best < 0 || _before(t, d, ticketOf(entries[best]), bestDistance)) {
      best = i;
      bestDistance = d;
    }
  }
  return best;
}

/// The index of the entry of [entries] that goes last now; `-1` when empty.
int lastInLine<T>(List<T> entries, TileTicket Function(T) ticketOf) {
  var worst = -1;
  var worstDistance = 0.0;
  for (var i = 0; i < entries.length; i++) {
    final t = ticketOf(entries[i]);
    final d = _distanceOf(t);
    if (worst < 0 || _before(ticketOf(entries[worst]), worstDistance, t, d)) {
      worst = i;
      worstDistance = d;
    }
  }
  return worst;
}

/// **A [ConcurrencyExecutor] that runs by [TileTicket]** instead of LIFO.
///
/// Same contract otherwise: at most [concurrencyLimit] jobs at once, and past
/// [maxQueueSize] the cancelled go first and then the one that goes **last**
/// in line, completed with a [CancellationException].
class RankedConcurrencyExecutor extends ExecutorDelegate {
  RankedConcurrencyExecutor({
    required this.delegate,
    required this.concurrencyLimit,
    required this.maxQueueSize,
  });

  final Executor delegate;
  final int concurrencyLimit;
  final int maxQueueSize;

  int _inProgress = 0;
  final _queue = <_RankedJob>[];
  final _executing = <_RankedJob>[];

  int get queueSize => _queue.length;

  /// This executor, submitting every job with [ticket].
  Executor ranked(TileTicket ticket) => _RankedView(this, ticket);

  /// Submits [job] in the place of [ticket].
  Future<R> submitRanked<Q, R>(Job<Q, R> job, TileTicket ticket) {
    if (disposed) {
      return Future.error(CancellationException());
    }
    final ranked = _RankedJob<Q, R>(job, ticket);
    _queue.add(ranked);
    _applyQueueLimit();
    _startJobs();
    return ranked.completer.future;
  }

  @override
  Future<R> submit<Q, R>(Job<Q, R> job) =>
      submitRanked(job, TileTicket(0, 0, 0, 256, TileFocus()));

  @override
  List<Future<R>> submitAll<Q, R>(Job<Q, R> job) => delegate.submitAll(job);

  @override
  void dispose() {
    delegate.dispose();
    _applyQueueLimit();
  }

  @override
  bool get disposed => delegate.disposed;

  void _startJobs() {
    while (_inProgress < concurrencyLimit) {
      final next = takeTurn(_queue, (j) => j.ticket, (j) => j.cancel());
      if (next < 0) {
        return;
      }
      _startJob(_queue.removeAt(next));
    }
  }

  void _applyQueueLimit() {
    if (_queue.length <= maxQueueSize && !disposed) {
      return;
    }
    _queue.removeWhere((j) {
      final gone = j.ticket.cancelled();
      if (gone) {
        j.cancel();
      }
      return gone;
    });
    while (_queue.length > maxQueueSize || (disposed && _queue.isNotEmpty)) {
      _queue.removeAt(lastInLine(_queue, (j) => j.ticket)).cancel();
    }
  }

  void _startJob(_RankedJob job) {
    ++_inProgress;
    _executing.add(job);
    job.runOn(delegate).whenComplete(() {
      _executing.remove(job);
      --_inProgress;
      _startJobs();
    });
  }

  @override
  bool hasJobWithDeduplicationKey(Job job) =>
      job.deduplicationKey != null &&
      (_queue.any((j) => j.job.deduplicationKey == job.deduplicationKey) ||
          _executing
              .any((j) => j.job.deduplicationKey == job.deduplicationKey));

  @override
  int get outstanding => _executing.length + _queue.length;
}

class _RankedJob<Q, R> {
  _RankedJob(this.job, this.ticket);

  final completer = Completer<R>();
  final Job<Q, R> job;
  final TileTicket ticket;

  void cancel() => completer.completeError(CancellationException());

  /// Runs on [executor] with its own types: through a `_RankedJob<dynamic,
  /// dynamic>` the job's function would not match what the executor expects.
  Future<void> runOn(Executor executor) => executor
      .submit<Q, R>(job)
      .then((value) => completer.complete(value))
      .onError((error, stackTrace) =>
          completer.completeError(error ?? '', stackTrace));
}

/// [RankedConcurrencyExecutor.ranked]: what `submitUntilDone` sees.
class _RankedView extends Executor {
  _RankedView(this._executor, this._ticket);

  final RankedConcurrencyExecutor _executor;
  final TileTicket _ticket;

  @override
  Future<R> submit<Q, R>(Job<Q, R> job) => _executor.submitRanked(job, _ticket);

  @override
  List<Future<R>> submitAll<Q, R>(Job<Q, R> job) => _executor.submitAll(job);

  @override
  bool get disposed => _executor.disposed;

  @override
  void dispose() {}
}
