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
      final lines  = await f.readAsLines();
      if (lines.isEmpty) return null;

      final strides = <StrideRow>[];
      for (final line in lines.skip(1)) {
        final cols = line.split(',');
        if (cols.length < 5) continue;
        strides.add(StrideRow(
          stride:    int.parse(cols[0].trim()),
          timeS:     double.parse(cols[1].trim()),
          omegaPico: double.parse(cols[2].trim()),
          tauStPct:  double.parse(cols[3].trim()),
          alphaAtq:  double.parse(cols[4].trim()),
        ));
      }

      final name = f.uri.pathSegments.last.replaceAll('.csv', '');
      return SessionRecord(fileName: name, filePath: f.path, strides: strides);
    } catch (_) {
      return null;
    }
  }
}
