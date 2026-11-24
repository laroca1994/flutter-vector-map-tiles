import 'dart:async';

import 'package:executor_lib/executor_lib.dart';
import 'package:flutter_map/flutter_map.dart' show Crs;
import 'package:latlong2/latlong.dart';

/// **Where a raster tile request stands in line.**
///
/// flutter_map asks for the tiles of one camera update all at once, already
/// sorted from the centre of the view outwards. Two things matter, in this
/// order:
///
/// 1. **The newest update first**: what was asked for last is the most likely
///    to still be on screen (the reason the queues used to be LIFO).
/// 2. **Within one update, the nearest to the [TileFocus] first**, and then
///    the order it was asked in — flutter_map's, from the centre of the range
///    outwards. A plain LIFO queue ran each update backwards — the corner
///    tiles first and the one under the user last.
///
/// An update is every request made before the event loop turns: flutter_map
/// asks for them in one synchronous pass.
class TileTicket implements Comparable<TileTicket> {
  const TileTicket._(this.batch, this.distance, this.order);

  final int batch;

  /// From the focus, in tiles squared; 0 without a focus.
  final double distance;
  final int order;

  static int _batch = 0;
  static int _order = 0;
  static bool _open = false;

  /// The ticket of a request made now, [distance] from the focus.
  factory TileTicket.next({double distance = 0}) {
    if (!_open) {
      _open = true;
      _batch++;
      _order = 0;
      scheduleMicrotask(() => _open = false);
    }
    return TileTicket._(_batch, distance, _order++);
  }

  /// Negative when this one goes before [other].
  @override
  int compareTo(TileTicket other) => batch != other.batch
      ? other.batch.compareTo(batch)
      : distance != other.distance
          ? distance.compareTo(other.distance)
          : order.compareTo(other.order);
}

/// **The point the tiles load around** (`VectorTileLayer.tileFocus`), kept
/// by the layer as the camera moves and read by the loader when a tile is
/// asked for. It is not a tile option: changing one makes flutter_map ask
/// for every tile again.
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

/// The index of the entry of [entries] that goes first, by [ticketOf]; `-1`
/// when there is none.
int firstInLine<T>(List<T> entries, TileTicket Function(T) ticketOf) {
  var best = -1;
  for (var i = 0; i < entries.length; i++) {
    if (best < 0 ||
        ticketOf(entries[i]).compareTo(ticketOf(entries[best])) < 0) {
      best = i;
    }
  }
  return best;
}

/// **A [ConcurrencyExecutor] that runs by [TileTicket]** instead of LIFO.
///
/// Same contract otherwise: at most [concurrencyLimit] jobs at once, and past
/// [maxQueueSize] the jobs that go **last** in line are completed with a
/// [CancellationException] (the old executor dropped the oldest, which on a
/// fresh update were the nearest to the centre).
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
  Future<R> submit<Q, R>(Job<Q, R> job) => submitRanked(job, TileTicket.next());

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
    while (_inProgress < concurrencyLimit && _queue.isNotEmpty) {
      _startJob(_queue.removeAt(firstInLine(_queue, (j) => j.ticket)));
    }
  }

  void _applyQueueLimit() {
    while (_queue.length > maxQueueSize || (disposed && _queue.isNotEmpty)) {
      var last = 0;
      for (var i = 1; i < _queue.length; i++) {
        if (_queue[i].ticket.compareTo(_queue[last].ticket) > 0) {
          last = i;
        }
      }
      _queue.removeAt(last).cancel();
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
