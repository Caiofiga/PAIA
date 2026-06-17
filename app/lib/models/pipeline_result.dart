class StrideData {
  final double omegaPico;   // deg/s
  final double tauStPct;    // %
  final double dorsiflex;   // deg — tibia minus foot pitch at IC
  final int strideNum;
  final double elapsedS;

  const StrideData({
    required this.omegaPico,
    required this.tauStPct,
    required this.dorsiflex,
    required this.strideNum,
    required this.elapsedS,
  });
}

class ReturnData {
  final int n;
  final double omegaPico;
  final double tauStPct;
  final double dorsiflex;                // deg — dorsiflexion angle
  final List<double>? deviations;        // [Δω, Δτ, ΔDF] positive = worse
  final bool alert;

  const ReturnData({
    required this.n,
    required this.omegaPico,
    required this.tauStPct,
    required this.dorsiflex,
    this.deviations,
    required this.alert,
  });
}

enum PipelineType { staticCalib, calibrating, live }

class PipelineResult {
  final PipelineType type;

  // staticCalib / calibrating
  final double calibProgress;  // 0..1
  final double thetaDeg;
  final String message;

  // live
  final double ts;
  final double theta;
  final double omega;
  final double accelNorm;
  final StrideData? stride;
  final ReturnData? returnData;

  const PipelineResult.staticCalib({
    required this.calibProgress,
    required this.message,
  })  : type = PipelineType.staticCalib,
        thetaDeg = 0,
        ts = 0, theta = 0, omega = 0, accelNorm = 0,
        stride = null, returnData = null;

  const PipelineResult.calibrating({
    required this.calibProgress,
    required this.thetaDeg,
  })  : type = PipelineType.calibrating,
        message = '',
        ts = 0, theta = 0, omega = 0, accelNorm = 0,
        stride = null, returnData = null;

  const PipelineResult.live({
    required this.ts,
    required this.theta,
    required this.omega,
    required this.accelNorm,
    this.stride,
    this.returnData,
  })  : type = PipelineType.live,
        calibProgress = 0, thetaDeg = 0, message = '';
}
