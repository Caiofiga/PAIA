import 'dart:io';
class SessionMetadata {
  final String athleteName;
  final int    pse;        // Perceived Subjective Effort: 1–10
  final int    spasticity; // Spasticity/Rigidity scale: 0–10

  const SessionMetadata({
    required this.athleteName,
    required this.pse,
    required this.spasticity,
  });
}

/// Calibration baseline saved in the _calib.csv companion file.
class CalibBaseline {
  final double omegaMean;    // °/s  — ωpico baseline mean
  final double tauMean;      // %    — τst% baseline mean
  final double dorsiMean;    // °    — dorsiflexion baseline mean
  final double omegaStd;     // °/s  — ωpico baseline std
  final double tauStd;       // %    — τst% baseline std
  final double dorsiStd;     // °    — dorsiflexion baseline std
  final double gravityG;     // g    — measured gravity magnitude
  final double thetaRefDeg;  // °    — tibia reference angle (static calibration)

  const CalibBaseline({
    required this.omegaMean,
    required this.tauMean,
    required this.dorsiMean,
    required this.omegaStd,
    required this.tauStd,
    required this.dorsiStd,
    required this.gravityG,
    required this.thetaRefDeg,
  });

  List<double> get mean => [omegaMean, tauMean, dorsiMean];
  List<double> get std  => [omegaStd,  tauStd,  dorsiStd];
}

class StrideRow {
  final int    stride;
  final double timeS;
  final double omegaPico;
  final double tauStPct;
  final double dorsiflex;   // deg — dorsiflexion angle at IC

  const StrideRow({
    required this.stride,
    required this.timeS,
    required this.omegaPico,
    required this.tauStPct,
    required this.dorsiflex,
  });
}

class SessionRecord {
  final String           fileName;   // e.g. "session_2026-05-20T14-30-00"
  final String           filePath;   // path to _strides.csv
  final List<StrideRow>  strides;
  final SessionMetadata? metadata;
  final CalibBaseline?   calib;      // null for sessions without _calib.csv

  const SessionRecord({
    required this.fileName,
    required this.filePath,
    required this.strides,
    this.metadata,
    this.calib,
  });

  int get strideCount => strides.length;

  String get displayLabel {
    try {
      final part = fileName.replaceFirst('session_', '');
      final dt   = DateTime.parse(
          part.replaceAll(RegExp(r'T(\d{2})-(\d{2})-(\d{2})'), r'T$1:$2:$3'));
      return '${dt.day} ${_month(dt.month)} '
             '${dt.hour.toString().padLeft(2, '0')}:'
             '${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return fileName;
    }
  }

  /// Returns all CSV file paths that exist for this session.
  List<String> allFilePaths() {
    final base = filePath
        .replaceAll('_strides.csv', '')
        .replaceAll('.csv', '');
    final candidates = [
      '${base}_strides.csv',
      '${base}_calib.csv',
      '${base}_raw.csv',
      '${base}_returns.csv',
      if (!filePath.contains('_strides') &&
          !filePath.contains('_calib') &&
          !filePath.contains('_raw') &&
          !filePath.contains('_returns')) filePath,
    ];
    return candidates
        .toSet()
        .where((p) => File(p).existsSync())
        .toList()
      ..sort();
  }

  static String _month(int m) => [
    'Jan','Feb','Mar','Apr','May','Jun',
    'Jul','Aug','Sep','Oct','Nov','Dec'
  ][m - 1];
}
