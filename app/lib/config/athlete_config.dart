import 'package:shared_preferences/shared_preferences.dart';

class AthleteConfig {
  final int    gyroAxis;
  final double swingEntryOmega;
  final int    minSwingSamples;
  final int    stridesPerReturn;
  final int    calibStrides;
  final int    staticCalibSamples;
  final double accelSwingThresh;

  const AthleteConfig({
    this.gyroAxis           = 1,
    this.swingEntryOmega    = 0.35,
    this.minSwingSamples    = 10,
    this.stridesPerReturn   = 6,
    this.calibStrides       = 40,
    this.staticCalibSamples = 200,
    this.accelSwingThresh   = 0.15,
  });

  static Future<AthleteConfig> load() async {
    final p = await SharedPreferences.getInstance();
    return AthleteConfig(
      gyroAxis:           p.getInt('gyro_axis')              ?? 1,
      swingEntryOmega:    p.getDouble('swing_entry_omega')   ?? 0.35,
      minSwingSamples:    p.getInt('min_swing_samples')      ?? 10,
      stridesPerReturn:   p.getInt('strides_per_return')     ?? 6,
      calibStrides:       p.getInt('calib_strides')          ?? 40,
      staticCalibSamples: p.getInt('static_calib_samples')   ?? 200,
      accelSwingThresh:   p.getDouble('accel_swing_thresh')  ?? 0.15,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('gyro_axis',              gyroAxis);
    await p.setDouble('swing_entry_omega',   swingEntryOmega);
    await p.setInt('min_swing_samples',      minSwingSamples);
    await p.setInt('strides_per_return',     stridesPerReturn);
    await p.setInt('calib_strides',          calibStrides);
    await p.setInt('static_calib_samples',   staticCalibSamples);
    await p.setDouble('accel_swing_thresh',  accelSwingThresh);
  }
}
