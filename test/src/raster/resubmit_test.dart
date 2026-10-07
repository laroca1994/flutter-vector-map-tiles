import 'dart:async';

import 'package:executor_lib/executor_lib.dart';
import 'package:test/test.dart';
import 'package:vector_map_tiles/src/raster/resubmit.dart';

void main() {
  late ConcurrencyExecutor executor;

  setUp(() {
    executor = ConcurrencyExecutor(
        delegate: ImmediateExecutor(), concurrencyLimit: 1, maxQueueSize: 1);
  });

  tearDown(() => executor.dispose());

  Job<String, String> jobOf(String value, Completer<void> gate) =>
      Job<String, String>(value, (dynamic v) async {
        await gate.future;
        return v as String;
      }, value, deduplicationKey: null);

  test('a job pushed out of the full queue is submitted again', () async {
    final gate = Completer<void>();
    final running = executor.submit(jobOf('running', gate));
    Future<String> wanted(String value) =>
        submitUntilDone(executor, () => jobOf(value, gate), () => false,
            backoff: const Duration(milliseconds: 1));
    // Three jobs for one queue slot: each one pushes the other out, and both
    // come back until there is room.
    final first = wanted('first');
    final second = wanted('second');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    gate.complete();
    expect(await running, 'running');
    expect(await second, 'second');
    expect(await first, 'first');
  });

  test('a job no longer wanted is not submitted again', () async {
    final gate = Completer<void>();
    final running = executor.submit(jobOf('running', gate));
    final first = submitUntilDone(
        executor, () => jobOf('first', gate), () => true,
        backoff: Duration.zero);
    final second = executor.submit(jobOf('second', gate));
    await expectLater(first, throwsA(isA<CancellationException>()));
    gate.complete();
    await running;
    await second;
  });
}
