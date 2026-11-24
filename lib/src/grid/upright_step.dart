import 'dart:math';

const _step = pi / 4;
const _margin = 15 * pi / 180;

/// The 45° step, from 0 to 7, that raster tiles bake their labels right side
/// up for, given the map [rotation] in radians and the [previous] step.
///
/// Every step change renders every visible tile again —on a tilted map, a
/// hundred or more—, so a new step is only taken once the rotation is well
/// past the halfway point between two steps: labels may lean up to 37.5°
/// before they are turned. A map held near a boundary, or a heading that
/// jitters, would otherwise go back and forth.
int uprightStep(double rotation, int previous) {
  var delta = (rotation - previous * _step) % (2 * pi);
  if (delta > pi) delta -= 2 * pi;
  if (delta.abs() <= _step / 2 + _margin) {
    return previous;
  }
  return (rotation / _step).round() % 8;
}
