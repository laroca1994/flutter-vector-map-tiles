import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:executor_lib/executor_lib.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' hide Image;
import 'package:flutter_map/flutter_map.dart' hide TileProvider;
import 'package:vector_tile_renderer/vector_tile_renderer.dart' hide TileLayer;

import '../../vector_map_tiles.dart';
import '../extensions.dart';
import '../grid/slippy_map_translator.dart';
import '../grid/tile_zoom.dart';
import '../rendering/tile_renderer.dart';
import '../stream/tile_supplier.dart';
import '../stream/tile_supplier_raster.dart';
import 'resubmit.dart';
import 'soft_tiles.dart';
import 'storage_image_cache.dart';
import 'tile_priority.dart';

class TileLoader {
  final Theme _theme;
  late final Set<String> _themeSources;
  late String _sourcesKey;
  final SpriteStyle? _sprites;
  final Future<Image> Function()? _spriteAtlas;
  final TileProvider _provider;
  final RasterTileProvider _rasterTileProvider;
  final StorageImageCache _imageCache;
  final TileOffset _tileOffset;
  final int _concurrency;
  final _scale = 2.0;
  late final RankedConcurrencyExecutor _jobQueue;

  /// Where the tiles that matter most are. See [TileFocus].
  final focus = TileFocus();

  /// The tiles drawn soft, to send again sharp. See [SoftTiles].
  late final _softTiles = SoftTiles(focus);

  TileLoader(
      this._theme,
      this._sprites,
      this._spriteAtlas,
      this._provider,
      this._rasterTileProvider,
      this._tileOffset,
      this._imageCache,
      this._concurrency) {
    _themeSources = _theme.tileSources;
    _sourcesKey = _theme.tileSources.toList().sorted().join(',');
    _jobQueue = RankedConcurrencyExecutor(
        delegate: ImmediateExecutor(),
        concurrencyLimit: _concurrency * 2,
        maxQueueSize: _maxOutstandingJobs);
  }

  /// The image of the tile at [coords]. Out of [TileFocus.sharpRadius] it is
  /// drawn soft, and [onSharper], when given, gets the sharp one later, once
  /// the focus comes near (see [SoftTiles]).
  Future<ImageInfo> loadTile(
      TileCoordinates coords, TileLayer options, bool Function() cancelled,
      [void Function(ImageInfo sharp)? onSharper]) async {
    final requestedTile =
        TileIdentity(coords.z.toInt(), coords.x.toInt(), coords.y.toInt());
    final tileSize = options.tileDimension.toDouble();
    final upStep = int.tryParse(options.additionalOptions['up'] ?? '') ?? 0;
    final sharp = focus.isSharp(
        requestedTile.x, requestedTile.y, requestedTile.z, tileSize);
    final info =
        await _load(requestedTile, tileSize, upStep, cancelled, sharp: sharp);
    if (!sharp && onSharper != null) {
      _softTiles.add(
          TileTicket(requestedTile.x, requestedTile.y, requestedTile.z,
              tileSize, focus, cancelled: cancelled),
          () => _load(requestedTile, tileSize, upStep, cancelled, sharp: true)
              .then(onSharper, onError: (Object _) {}));
    }
    return info;
  }

  Future<ImageInfo> _load(TileIdentity requestedTile, double tileSize,
      int upStep, bool Function() cancelled,
      {required bool sharp}) async {
    var requestZoom = requestedTile.z;
    if (_tileOffset.zoomOffset < 0) {
      requestZoom = max(
          1, min(requestZoom + _tileOffset.zoomOffset, _provider.maximumZoom));
    }
    final scale = sharp ? _scale : 1.0;
    if (tileProbe) {
      _TileProbe.addAsked();
    }
    // Its place in line is worked out at every turn, against where the
    // focus is then: in the pacer and in the queue (see [TileTicket]).
    final ticket = TileTicket(
        requestedTile.x, requestedTile.y, requestedTile.z, tileSize, focus,
        cancelled: cancelled);
    // A label step change asks for every visible tile at once; read and
    // decode them a few per frame instead of all in one.
    final asked = tileProbe ? (Stopwatch()..start()) : null;
    await _framePacer.turn(ticket);
    _Stages.lap(asked, 'turno');
    if (cancelled()) {
      throw CancellationException();
    }
    // Stored sharp; a soft tile decodes it straight at its size.
    final cached = await _imageCache.retrieve(
        requestedTile, upStep, sharp ? null : (tileSize * scale).round());
    _Stages.lap(asked, 'guardada');
    if (cached != null) {
      _Stages.count(sharp ? 'acierto' : 'acierto_suave');
      return ImageInfo(image: cached, scale: scale);
    }
    _Stages.count(sharp ? 'falla' : 'falla_suave');
    final job = _TileJob(
        requestedTile, requestZoom, tileSize, cancelled, upStep, scale);
    // A tile dropped by the full queue must be asked for again: otherwise it
    // stays blank while it is on screen.
    return submitUntilDone(
        _jobQueue.ranked(ticket),
        () => Job<_TileJob, ImageInfo>(
            'render $requestedTile up$upStep x$scale', _renderJob, job,
            deduplicationKey: 'render $requestedTile up$upStep x$scale '
                '${_theme.id}/$_sourcesKey'),
        cancelled);
  }

  Future<ImageInfo> _renderJob(job) async {
    _Stages.lap(job.queued, 'cola');
    final slot = tileProbe ? (Stopwatch()..start()) : null;
    try {
      final info = await _renderTile(job.requestedTile, job.requestZoom,
          job.tileSize, job.cancelled, job.upStep, job.scale);
      _Stages.lap(slot, 'puesto_ok');
      return info;
    } on CancellationException {
      _Stages.lap(slot, 'puesto_cancelada');
      rethrow;
    } catch (_) {
      _Stages.lap(slot, 'puesto_error');
      rethrow;
    }
  }

  Future<ImageInfo> _renderTile(
      TileIdentity requestedTile,
      int requestZoom,
      double tileSize,
      bool Function() cancelled,
      int upStep,
      double scale) async {
    if (cancelled()) {
      throw CancellationException();
    }
    final tileRequest = TileRequest(
        tileId: requestedTile,
        tileSources: _themeSources,
        zoom: requestedTile.z.toDouble(),
        zoomDetail: requestedTile.z.toDouble(),
        cancelled: cancelled);
    final stage = tileProbe ? (Stopwatch()..start()) : null;
    final spriteAtlas = await _spriteAtlas?.call();
    final tileResponseFuture = _provider.provide(tileRequest);
    final rasterTile = await _rasterTileProvider
        .retrieve(requestedTile.normalize(), skipMissing: true);
    try {
      final tileResponse = await tileResponseFuture;
      _Stages.lap(stage, 'datos');
      final tileset = tileResponse.tileset;
      if (tileset == null) {
        throw 'No tile: $requestedTile';
      }
      final translator = SlippyMapTranslator(_provider.maximumZoom);
      final translation = translator.specificZoomTranslation(requestedTile,
          zoom: tileResponse.identity.z);

      final renderer = TileRenderer(
          theme: _theme,
          textPainterProvider: const DefaultTextPainterProvider(),
          tileState: TileState(
              zoom: requestedTile.z.toDouble(),
              zoomDetail: requestedTile.z.toDouble(),
              zoomScale: 0.0,
              rotation: -upStep * pi / 4),
          translation: translation,
          tileset: tileset,
          rasterTileset: rasterTile,
          spriteImage: spriteAtlas,
          sprites: _sprites);

      final size = Size.square(tileSize * scale);
      final rect = Offset.zero & size;
      if (cancelled()) {
        throw CancellationException();
      }
      final watch = tileProbe ? (Stopwatch()..start()) : null;
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder, rect);
      canvas.scale(scale);
      renderer.render(canvas, size / scale);

      final picture = recorder.endRecording();
      if (watch != null) {
        _TileProbe.add(watch.elapsedMicroseconds, upStep,
            '${requestedTile.z}/${requestedTile.x}/${requestedTile.y}/$upStep');
      }
      _Stages.lap(stage, 'dibujo');
      final image =
          await picture.toImage(size.width.toInt(), size.height.toInt());
      _Stages.lap(stage, 'imagen');
      // Shown now and stored after: see [_storeLater]. A soft tile is stored
      // as soft: unstored, every one of them was drawn again each time the
      // labels changed step.
      _storeLater(translation.original, image, upStep, soft: scale != _scale);
      return ImageInfo(image: image, scale: scale);
    } finally {
      rasterTile.dispose();
    }
  }

  /// **A drawn tile is stored after it is shown, one at a time.** Storing
  /// encodes it as a PNG, and on a low-end phone that took 250–950 ms a tile
  /// (up to 6 s queued behind others): with the tile waiting for it, a
  /// tilted map filled at a dozen tiles a second even with the map
  /// downloaded, and every tile held a render slot the whole time. It is
  /// only a cache, so past [_maxPendingPixels] the oldest waiting are
  /// skipped: they get drawn again if they are ever asked for. The limit is
  /// in pixels because each one waiting holds its image, and a soft tile is
  /// a quarter of a sharp one.
  final _pendingStores = <(TileIdentity, Image, int, bool)>[];
  var _pendingPixels = 0;
  var _storing = false;

  void _storeLater(TileIdentity tile, Image image, int upStep,
      {required bool soft}) {
    _pendingStores.add((tile, image.clone(), upStep, soft));
    _pendingPixels += image.width * image.height;
    while (_pendingPixels > _maxPendingPixels && _pendingStores.length > 1) {
      final dropped = _pendingStores.removeAt(0).$2;
      _pendingPixels -= dropped.width * dropped.height;
      dropped.dispose();
      _Stages.count('guardar_tirada');
    }
    if (!_storing) {
      unawaited(_storePending());
    }
  }

  Future<void> _storePending() async {
    _storing = true;
    try {
      while (_pendingStores.isNotEmpty) {
        final (tile, image, upStep, soft) = _pendingStores.removeLast();
        _pendingPixels -= image.width * image.height;
        final watch = tileProbe ? (Stopwatch()..start()) : null;
        try {
          final bytes = await _imageCache.encode(image);
          _Stages.lap(watch, 'g_codificar');
          if (bytes != null) {
            _Stages.value('g_kb', bytes.length ~/ 1024);
            await _imageCache.putBytes(tile, bytes, upStep, soft);
            _Stages.lap(watch, 'g_escribir');
          }
        } catch (_) {
          // nothing to do
        } finally {
          image.dispose();
        }
      }
    } finally {
      _storing = false;
    }
  }
}

class _TileJob {
  final TileIdentity requestedTile;
  final int requestZoom;
  final double tileSize;
  final bool Function() cancelled;
  final int upStep;
  final double scale;

  /// Since it went into the queue, for the probe ([_Stages]).
  final Stopwatch? queued = tileProbe ? (Stopwatch()..start()) : null;

  _TileJob(this.requestedTile, this.requestZoom, this.tileSize, this.cancelled,
      this.upStep, this.scale);
}

// A tilted map with labels baked for each 45° step asks for many more tiles
// than a flat one: 100 dropped tiles near the camera.
int _maxOutstandingJobs = 200;

/// How many pixels of drawn tiles may wait to be stored: 48 sharp tiles of
/// 512 px, some 50 MB of images. See `TileLoader._storeLater`.
const _maxPendingPixels = 48 * 512 * 512;

/// Whether to log how long drawing each raster tile takes on the main
/// isolate: `--dart-define=TILE_PROBE=true`.
const bool tileProbe = bool.fromEnvironment('TILE_PROBE');

/// Once a second, how many raster tiles were drawn, the slowest and the
/// total time spent drawing them on the main isolate, and which label
/// rotation steps they were for.
/// How long sending a tileset to the preprocessing isolate took on the main
/// isolate, for [_TileProbe].
void tileProbeSend(int sendMicros, int _) => _TileProbe.addSend(sendMicros);

/// How long the geometry of a tileset took to set up on the main isolate.
void tileProbeUi(int micros) => _TileProbe.addUi(micros);

/// One stage of a tile's data, for the `[etapas]` line (see [_Stages]).
void tileProbeLap(Stopwatch? watch, String name) => _Stages.lap(watch, name);

/// One more of [name], for the `[etapas]` line.
void tileProbeCount(String name) => _Stages.count(name);

class _TileProbe {
  static int _uis = 0;
  static int _uiTotal = 0;
  static int _uiWorst = 0;

  static int _asked = 0;

  static void addAsked() {
    _asked++;
    _timer ??= Timer(const Duration(seconds: 1), _flush);
  }

  static void addUi(int micros) {
    _uis++;
    _uiTotal += micros;
    _uiWorst = max(_uiWorst, micros);
    _timer ??= Timer(const Duration(seconds: 1), _flush);
  }

  static int _sends = 0;
  static int _sendTotal = 0;
  static int _sendWorst = 0;

  static void addSend(int micros) {
    _sends++;
    _sendTotal += micros;
    _sendWorst = max(_sendWorst, micros);
    _timer ??= Timer(const Duration(seconds: 1), _flush);
  }

  static int _count = 0;
  static int _worst = 0;
  static int _total = 0;
  static final Set<int> _steps = {};
  static Timer? _timer;

  static final Set<String> _ever = {};
  static int _again = 0;
  static final Set<int> _zooms = {};

  static void add(int micros, int upStep, String key) {
    _count++;
    if (!_ever.add(key)) {
      _again++;
    }
    _zooms.add(int.parse(key.split('/').first));
    _total += micros;
    _worst = max(_worst, micros);
    _steps.add(upStep);
    _timer ??= Timer(const Duration(seconds: 1), _flush);
  }

  static void _flush() {
    _timer = null;
    // ignore: avoid_print
    print('[teselas] n=$_count peor=${_worst ~/ 1000} '
        'suma=${_total ~/ 1000} giros=${_steps.toList()..sort()} '
        'repetidas=$_again z=${_zooms.toList()..sort()} '
        'envios=$_sends envio_peor=${_sendWorst ~/ 1000} '
        'envio_suma=${_sendTotal ~/ 1000} '
        'geom=$_uis geom_peor=${_uiWorst ~/ 1000} '
        'geom_suma=${_uiTotal ~/ 1000} pedidas=$_asked');
    _asked = 0;
    _uis = 0;
    _uiTotal = 0;
    _uiWorst = 0;
    _sends = 0;
    _sendTotal = 0;
    _sendWorst = 0;
    _again = 0;
    _zooms.clear();
    _count = 0;
    _worst = 0;
    _total = 0;
    _steps.clear();
  }
}

final _framePacer = _FramePacer(perFrame: 6);

/// **Lets a few raster tile loads through per frame.** A tilted map has a
/// couple of hundred tiles in play, and a label step change reloads every one
/// of them in the same frame: each one read from storage and decoded at
/// once, one long stall in the middle of a turn. Paced, they arrive over a
/// fraction of a second, and the old tile stays on screen meanwhile.
class _FramePacer {
  _FramePacer({required this.perFrame});

  final int perFrame;
  final _waiting = <(TileTicket, Completer<void>)>[];
  var _scheduled = false;
  var _releasedThisFrame = 0;

  Future<void> turn(TileTicket ticket) {
    if (!_scheduled && _releasedThisFrame < perFrame) {
      _releasedThisFrame++;
      _schedule();
      return Future.value();
    }
    final done = Completer<void>();
    _waiting.add((ticket, done));
    _schedule();
    return done.future;
  }

  void _schedule() {
    if (_scheduled) {
      return;
    }
    _scheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _scheduled = false;
      _releasedThisFrame = 0;
      // In ticket order, like the render queue: the nearest to the focus
      // now (see [TileTicket]). The cancelled leave without using a turn.
      while (_releasedThisFrame < perFrame) {
        final next = takeTurn(_waiting, (w) => w.$1, (w) => w.$2.complete());
        if (next < 0) {
          break;
        }
        _releasedThisFrame++;
        _waiting.removeAt(next).$2.complete();
      }
      if (_waiting.isNotEmpty) {
        _schedule();
      }
    });
  }
}

/// **Where a raster tile's time goes** (`TILE_PROBE`, 24-11): per second, the
/// mean and worst of each stage in ms —waiting for a turn, the stored image,
/// the queue, the data, drawing, the GPU image, storing it (encoding, its
/// size in KB, writing)— and how many tiles were found stored, how many had
/// to be drawn and how many were dropped unstored.
class _Stages {
  static final Map<String, (int, int, int)> _laps = {};
  static final Map<String, int> _counts = {};
  static Timer? _timer;

  static void lap(Stopwatch? watch, String name) {
    if (watch == null) {
      return;
    }
    final ms = watch.elapsedMilliseconds;
    watch.reset();
    final (n, sum, worst) = _laps[name] ?? (0, 0, 0);
    _laps[name] = (n + 1, sum + ms, ms > worst ? ms : worst);
    _start();
  }

  /// A measure that is not a time: mean and worst like a lap.
  static void value(String name, int value) {
    if (!tileProbe) {
      return;
    }
    final (n, sum, worst) = _laps[name] ?? (0, 0, 0);
    _laps[name] = (n + 1, sum + value, value > worst ? value : worst);
    _start();
  }

  static void count(String name) {
    if (!tileProbe) {
      return;
    }
    _counts[name] = (_counts[name] ?? 0) + 1;
    _start();
  }

  static void _start() {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (_laps.isEmpty && _counts.isEmpty) {
        return;
      }
      final laps = [
        for (final e in _laps.entries)
          '${e.key}=${e.value.$2 ~/ e.value.$1}/${e.value.$3}',
      ];
      final counts = [for (final e in _counts.entries) '${e.key}=${e.value}'];
      debugPrint('[etapas] ${[...counts, ...laps].join(' ')}');
      _laps.clear();
      _counts.clear();
    });
  }
}
