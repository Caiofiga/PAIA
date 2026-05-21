import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:paia/models/session_record.dart';

class SessionsRepository {
  /// Returns all saved sessions, newest first.
  /// A "session" is identified by its _strides.csv file; the _calib.csv
  /// and _raw.csv companions are loaded automatically if they exist.
  static Future<List<SessionRecord>> loadAll() async {
    final dir   = await getApplicationDocumentsDirectory();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('_strides.csv'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path)); // newest first

    // Also handle legacy files (session_*.csv without suffix)
    final legacy = dir
        .listSync()
        .whereType<File>()
        .where((f) {
          final name = f.uri.pathSegments.last;
          return name.startsWith('session_') &&
                 name.endsWith('.csv') &&
                 !name.contains('_strides') &&
                 !name.contains('_calib') &&
                 !name.contains('_raw') &&
                 !name.contains('_returns');
        })
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));

    final records = <SessionRecord>[];
    for (final f in [...files, ...legacy]) {
      final record = await _parse(f);
      if (record != null) records.add(record);
    }
    return records;
  }

  static Future<SessionRecord?> _parse(File stridesFile) async {
    try {
      final lines = await stridesFile.readAsLines();
      if (lines.isEmpty) return null;

      String? athleteName;
      int?    pse;
      int?    spasticity;

      final strides = <StrideRow>[];
      for (final line in lines) {
        if (line.startsWith('#')) {
          final colon = line.indexOf(':');
          if (colon == -1) continue;
          final key = line.substring(1, colon).trim();
          final val = line.substring(colon + 1).trim();
          if (key == 'athlete')         athleteName = val;
          else if (key == 'pse')        pse         = int.tryParse(val);
          else if (key == 'spasticity') spasticity  = int.tryParse(val);
          continue;
        }
        if (line.startsWith('stride')) continue; // header row
        final cols = line.split(',');
        if (cols.length < 5) continue;
        try {
          strides.add(StrideRow(
            stride:    int.parse(cols[0].trim()),
            timeS:     double.parse(cols[1].trim()),
            omegaPico: double.parse(cols[2].trim()),
            tauStPct:  double.parse(cols[3].trim()),
            alphaAtq:  double.parse(cols[4].trim()),
          ));
        } catch (_) { continue; }
      }

      // Try to load calibration companion file
      CalibBaseline? calib;
      final calibFile = File(
        stridesFile.path.endsWith('_strides.csv')
            ? stridesFile.path.replaceFirst('_strides.csv', '_calib.csv')
            : stridesFile.path.replaceFirst('.csv', '_calib.csv'),
      );
      if (await calibFile.exists()) {
        calib = await _parseCalib(calibFile);
      }

      SessionMetadata? metadata;
      if (athleteName != null && pse != null && spasticity != null) {
        metadata = SessionMetadata(
          athleteName: athleteName,
          pse:         pse,
          spasticity:  spasticity,
        );
      }

      final rawName = stridesFile.uri.pathSegments.last;
      final name = rawName
          .replaceAll('_strides.csv', '')
          .replaceAll('.csv', '');

      return SessionRecord(
        fileName:     name,
        filePath:     stridesFile.path,
        strides:      strides,
        metadata:     metadata,
        calib:        calib,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<CalibBaseline?> _parseCalib(File f) async {
    try {
      final lines = await f.readAsLines();
      for (final line in lines) {
        if (line.startsWith('#') || line.startsWith('omega_mean')) continue;
        final cols = line.split(',');
        if (cols.length < 8) continue;
        return CalibBaseline(
          omegaMean:   double.parse(cols[0].trim()),
          tauMean:     double.parse(cols[1].trim()),
          alphaMean:   double.parse(cols[2].trim()),
          omegaStd:    double.parse(cols[3].trim()),
          tauStd:      double.parse(cols[4].trim()),
          alphaStd:    double.parse(cols[5].trim()),
          gravityG:    double.parse(cols[6].trim()),
          thetaRefDeg: double.parse(cols[7].trim()),
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
