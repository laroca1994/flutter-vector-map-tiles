import 'dart:async';

import 'package:executor_lib/executor_lib.dart';

/// Submits the job made by [job] to [executor], and submits it again when the
/// executor drops it to keep its queue under its limit — unless [cancelled]
/// says the result is no longer wanted, or the executor has been disposed.
///
/// A [ConcurrencyExecutor] completes its oldest queued jobs with a
/// [CancellationException] when the queue overflows. For a raster tile that
/// cancellation is silent: the image never completes, and the tile stays blank
/// for as long as it is on screen. Resubmitting puts it back as the newest
/// job, which the LIFO queue runs next.
Future<R> submitUntilDone<Q, R>(
  Executor executor,
  Job<Q, R> Function() job,
  bool Function() cancelled, {
  Duration backoff = const Duration(milliseconds: 16),
}) async {
  while (true) {
    try {
      return await executor.submit(job());
    } on CancellationException {
      if (cancelled() || executor.disposed) {
        rethrow;
      }
    }
    // Let the jobs that pushed this one out make some progress first.
    await Future<void>.delayed(backoff);
    if (cancelled() || executor.disposed) {
      throw CancellationException();
    }
  }
}
