import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:paia3_app/services/mahony_filter.dart';

void main() {
  test('MahonyFilter initializes with zero pitch', () {
    final f = MahonyFilter();
    // Feed pure gravity (0, 0, 1g) with zero gyro — pitch should converge to ~0
    double pitch = 0.0;
    for (int i = 0; i < 500; i++) {
      pitch = f.update(0.0, 0.0, 1.0, 0.0, 0.0, 0.0);
    }
    expect(pitch.abs(), lessThan(0.01)); // < 0.01 rad ≈ 0.57°
  });

  test('MahonyFilter returns pitch in radians within [-π/2, π/2]', () {
    final f = MahonyFilter();
    final pitch = f.update(0.5, 0.5, 0.707, 0.1, 0.0, 0.0);
    expect(pitch, greaterThanOrEqualTo(-math.pi / 2));
    expect(pitch, lessThanOrEqualTo(math.pi / 2));
  });
}
