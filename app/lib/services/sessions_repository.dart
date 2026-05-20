import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:paia/models/session_record.dart';

class SessionsRepository {
  /// Returns all saved sessions, newest first.
  static Future<List<SessionRecord>> loadAll() async {
    final dir   = await getApplicationDocumentsDirectory();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('session_') && f.path.endsWith('.csv'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path)); // newest first

    final records = <SessionRecord>[];
    for (final f in files) {
      final record = await _parse(f);
      if (record != null) records.add(record);
    }
    return records;
  }

  static Future<SessionRecord?> _parse(File f) async {
    try {
      final lines = await f.readAsLines();
      if (lines.isEmpty) return null;

      // Parse metadata from leading '# key: value' comment lines
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
          if (key == 'athlete')    athleteName = val;
          else if (key == 'pse')   pse         = int.tryParse(val);
          else if (key == 'spasticity') spasticity = int.tryParse(val);
          continue;
        }
        if (line.startsWith('stride')) continue; // CSV header
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

      SessionMetadata? metadata;
      if (athleteName != null && pse != null && spasticity != null) {
        metadata = SessionMetadata(
          athleteName: athleteName,
          pse:         pse,
          spasticity:  spasticity,
        );
      }

      final name = f.uri.pathSegments.last.replaceAll('.csv', '');
      return SessionRecord(
        fileName: name,
        filePath: f.path,
        strides:  strides,
        metadata: metadata,
      );
    } catch (_) {
      return null;
    }
  }
}
