import 'package:shared_preferences/shared_preferences.dart';

class AthleteConfig {
  final int    gyroAxis;
  final double swingEntryOmega;
  final int    minSwingSamples;
  final int    stridesPerReturn;
  final int    nWindow;
  final int    calibStrides;

  const AthleteConfig({
    this.gyroAxis         = 1,
    this.swingEntryOmega  = 0.35,
    this.minSwingSamples  = 10,
    this.stridesPerReturn = 6,
    this.nWindow          = 4,
    this.calibStrides     = 40,
  });

  static Future<AthleteConfig> load() async {
    final p = await SharedPreferences.getInstance();
    return AthleteConfig(
      gyroAxis:         p.getInt('gyro_axis')            ?? 1,
      swingEntryOmega:  p.getDouble('swing_entry_omega') ?? 0.35,
      minSwingSamples:  p.getInt('min_swing_samples')    ?? 10,
      stridesPerReturn: p.getInt('strides_per_return')   ?? 6,
      nWindow:          p.getInt('n_window')             ?? 4,
      calibStrides:     p.getInt('calib_strides')        ?? 40,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('gyro_axis',            gyroAxis);
    await p.setDouble('swing_entry_omega', swingEntryOmega);
    await p.setInt('min_swing_samples',    minSwingSamples);
    await p.setInt('strides_per_return',   stridesPerReturn);
    await p.setInt('n_window',             nWindow);
    await p.setInt('calib_strides',        calibStrides);
  }
}
