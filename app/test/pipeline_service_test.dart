import 'package:flutter_test/flutter_test.dart';
import 'package:paia3_app/models/pipeline_result.dart';
import 'package:paia3_app/services/pipeline_service.dart';

void main() {
  group('PipelineService calibration', () {
    test('returns calibrating type until CALIB_STRIDES reached', () {
      final p = PipelineService(sampleRate: 100);

      PipelineResult? last;
      for (int i = 0; i < 500; i++) {
        last = p.process(
          i * 0.01,
          0, 0, 8192, 0, 0, 0,
          0, 0, 8192, 0, 0, 0,
        );
      }
      expect(last!.type, PipelineType.calibrating);
      expect(last.calibProgress, lessThanOrEqualTo(1.0));
      expect(last.calibProgress, greaterThanOrEqualTo(0.0));
    });
  });

  group('PipelineService stride segmentation', () {
    test('detects a stride from a simulated swing burst', () {
      final p = PipelineService(sampleRate: 100);
      _forceCalibration(p);

      // GYRO_SCALE = (π/180)/65.5 ≈ 2.663e-4 rad/s per LSB
      // 0.5 rad/s needs ~1878 LSB; using 1900
      const int swingGyroLSB = 1900;
      const int stanceLSB    = 0;

      StrideData? detected;
      double ts = 0.0;

      // First stride (no stride_time yet — needs two ICs)
      for (int i = 0; i < 20; i++) { p.process(ts, 0, 0, 8192, 0, stanceLSB, 0, 0, 0, 8192, 0, 0, 0); ts += 0.01; }
      for (int i = 0; i < 30; i++) { p.process(ts, 0, 0, 8192, 0, swingGyroLSB, 0, 0, 0, 8192, 0, 0, 0); ts += 0.01; }
      for (int i = 0; i < 20; i++) {
        final r = p.process(ts, 0, 0, 8192, 0, stanceLSB, 0, 0, 0, 8192, 0, 0, 0);
        if (r.stride != null) detected = r.stride;
        ts += 0.01;
      }

      // Second stride (this one will have a valid stride_time)
      for (int i = 0; i < 20; i++) { p.process(ts, 0, 0, 8192, 0, stanceLSB, 0, 0, 0, 8192, 0, 0, 0); ts += 0.01; }
      for (int i = 0; i < 30; i++) { p.process(ts, 0, 0, 8192, 0, swingGyroLSB, 0, 0, 0, 8192, 0, 0, 0); ts += 0.01; }
      for (int i = 0; i < 20; i++) {
        final r = p.process(ts, 0, 0, 8192, 0, stanceLSB, 0, 0, 0, 8192, 0, 0, 0);
        if (r.stride != null) detected = r.stride;
        ts += 0.01;
      }

      expect(detected, isNotNull);
      expect(detected!.omegaPico, greaterThan(0));
      expect(detected.tauStPct, greaterThanOrEqualTo(0));
      expect(detected.tauStPct, lessThanOrEqualTo(100));
    });
  });
}

void _forceCalibration(PipelineService p) {
  p.forceCalibrated(
    thetaRef: 0.0,
    baselineMean: [200.0, 60.0, 0.0],
    baselineStd:  [20.0,  5.0,  2.0],
  );
}
