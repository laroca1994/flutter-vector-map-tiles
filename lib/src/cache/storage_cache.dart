import 'dart:typed_data';

import '../extensions.dart';
import 'byte_storage.dart';
import 'cache_stats.dart';

class StorageCache with CacheStats {
  final ByteStorage _storage;
  final Duration _ttl;
  final int _maxSizeInBytes;

  /// What the storage holds, in bytes, as far as this cache knows: counted
  /// once and kept up with every [put]. Listing the storage to find out
  /// costs seconds with thousands of entries, and it used to be done every
  /// 20 writes: tiles waiting to be stored piled up behind it.
  int? _knownSize;

  StorageCache(this._storage, this._ttl, this._maxSizeInBytes);

  Future<void> remove(String key) async {
    await _storage.delete(key);
  }

  Future<Uint8List?> retrieve(String key) async {
    try {
      final bytes = await _storage.read(key);
      if (bytes == null) {
        cacheMiss();
      } else {
        cacheHit();
      }
      return bytes;
    } catch (e) {
      // ignore, file was likely deleted
      return null;
    }
  }

  Future<void> put(String key, Uint8List data) async {
    await _storage.write(key, data);
    // An entry written over counts twice: it only brings the next count
    // forward, and that one is exact.
    final size = (_knownSize ?? await _countSize()) + data.length;
    _knownSize = size;
    if (size > _maxSizeInBytes) {
      // With room to spare, so that the next writes do not list it again.
      await _applyMaxSize(target: _maxSizeInBytes * 4 ~/ 5);
    }
  }

  Future<int> _countSize() async {
    try {
      final entries = await _storage.list();
      return entries.fold<int>(0, (sum, e) => sum + e.size);
    } catch (e) {
      // ignore, race condition directory may have been deleted
      return 0;
    }
  }

  Future<bool> exists(String key) => _storage.exists(key);

  Future<void> applyConstraints() async {
    try {
      await _applyMaxAge();
      await _applyMaxSize();
    } catch (e) {
      // ignore, race condition directory may have been deleted
    }
  }

  Future<void> _applyMaxAge() async {
    final entries = await _storage.list();
    for (final entry in entries) {
      await _expireIfExceedsTtl(entry);
    }
  }

  /// Removes the entries used longest ago until the storage is down to
  /// [target] bytes, when it holds more than the maximum.
  Future<void> _applyMaxSize({int? target}) async {
    final entries = await _storage.list();
    int size = entries.isEmpty
        ? 0
        : entries.map((e) => e.size).reduce((a, b) => a + b);
    if (size > _maxSizeInBytes) {
      final entriesByAccessed =
          entries.sorted((a, b) => a.accessed.compareTo(b.accessed));
      for (final entry in entriesByAccessed) {
        try {
          await _storage.delete(entry.path);
          size -= entry.size;
          if (size <= (target ?? _maxSizeInBytes)) {
            break;
          }
        } catch (e) {
          // ignore, race condition file was deleted
        }
      }
    }
    _knownSize = size;
  }

  Future<void> _expireIfExceedsTtl(ByteStorageEntry entity) async {
    final exceeds = _exceedsTtl(entity);
    if (exceeds) {
      await _storage.delete(entity.path);
    }
  }

  bool _exceedsTtl(ByteStorageEntry entry) {
    final now = DateTime.now();
    final age =
        now.millisecondsSinceEpoch - entry.modified.millisecondsSinceEpoch;
    return (age >= _ttl.inMilliseconds);
  }
}
