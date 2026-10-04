import 'dart:math';

import 'package:test/test.dart';
import 'package:vector_map_tiles/src/grid/upright_step.dart';

void main() {
  const deg = pi / 180;

  group('uprightStep', () {
    test('rounds to the nearest 45° step when the rotation moves far', () {
      expect(uprightStep(0, 0), 0);
      expect(uprightStep(45 * deg, 0), 1);
      expect(uprightStep(180 * deg, 0), 4);
      expect(uprightStep(-45 * deg, 0), 7);
      expect(uprightStep(-180 * deg, 2), 4);
    });

    test('keeps the previous step up to 5° past the halfway point', () {
      expect(uprightStep(22.6 * deg, 0), 0);
      expect(uprightStep(27.4 * deg, 0), 0);
      expect(uprightStep(-27.4 * deg, 0), 0);
      expect(uprightStep(17.6 * deg, 1), 1);
    });

    test('takes the next step once past the margin', () {
      expect(uprightStep(27.6 * deg, 0), 1);
      expect(uprightStep(-27.6 * deg, 0), 7);
      expect(uprightStep(17.4 * deg, 1), 0);
    });

    test('measures the distance across a full turn', () {
      // 350° is 10° away from step 0, not 350°.
      expect(uprightStep(350 * deg, 0), 0);
      expect(uprightStep(-350 * deg, 0), 0);
      expect(uprightStep(2 * pi + 10 * deg, 0), 0);
      // 340° is 25° away from step 7.
      expect(uprightStep(-20 * deg, 7), 7);
    });
  });
}
