class StrideData {
  final double omegaPico;   // deg/s
  final double tauStPct;    // %
  final double alphaAtq;    // deg
  final int strideNum;
  final double elapsedS;

  const StrideData({
    required this.omegaPico,
    required this.tauStPct,
    required this.alphaAtq,
    required this.strideNum,
    required this.elapsedS,
  });
}

class ReturnData {
  final int n;
  final double omegaPico;
  final double tauStPct;
  final double alphaAtq;
  final double? it;
  final List<double>? normSlopes; // length 3
  final bool alert;

  const ReturnData({
    required this.n,
    required this.omegaPico,
    required this.tauStPct,
    required this.alphaAtq,
    this.it,
    this.normSlopes,
    required this.alert,
  });
}

enum PipelineType { calibrating, live }

class PipelineResult {
  final PipelineType type;

  // calibrating
  final double calibProgress;  // 0..1
  final double thetaDeg;       // always present

  // live
  final double ts;
  final double theta;
  final double omega;
  final StrideData? stride;
  final ReturnData? returnData;

  const PipelineResult.calibrating({
    required this.calibProgress,
    required this.thetaDeg,
  })  : type = PipelineType.calibrating,
        ts = 0, theta = 0, omega = 0,
        stride = null, returnData = null;

  const PipelineResult.live({
    required this.ts,
    required this.theta,
    required this.omega,
    this.stride,
    this.returnData,
  })  : type = PipelineType.live,
        calibProgress = 0, thetaDeg = 0;
}
