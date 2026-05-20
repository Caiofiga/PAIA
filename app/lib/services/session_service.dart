import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:paia/models/pipeline_result.dart';
import 'package:paia/models/session_record.dart';

class SessionService {
  File?    _file;
  IOSink?  _sink;
  bool     _active      = false;
  int      _strideCount = 0;
  String   _label       = '';

  final _newSessionCtrl = StreamController<void>.broadcast();
  final _strideCtrl     = StreamController<StrideData>.broadcast();

  bool   get isActive    => _active;
  int    get strideCount => _strideCount;
  String get label       => _label;

  Stream<void>       get onNewSession => _newSessionCtrl.stream;
  Stream<StrideData> get strideStream => _strideCtrl.stream;

  bool isCurrentSession(String fileName) => _active && _label == fileName;

  Future<void> newSession({SessionMetadata? meta}) async {
    if (_active) {
      await _sink?.flush();
      await _sink?.close();
      _sink = null;
    }

    final dir = await getApplicationDocumentsDirectory();
    final ts  = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    _file = File('${dir.path}/session_$ts.csv');
    _sink = _file!.openWrite();

    // Metadata comment lines (parsed back by SessionsRepository)
    if (meta != null) {
      _sink!
        ..writeln('# athlete: ${meta.athleteName}')
        ..writeln('# pse: ${meta.pse}')
        ..writeln('# spasticity: ${meta.spasticity}');
    }

    _sink!.writeln('stride,time_s,omega_pico_degs,tau_st_pct,alpha_atq_deg');

    _active      = true;
    _strideCount = 0;
    _label       = 'session_$ts';

    await _sink!.flush();   // ensure header on disk before notifying
    _newSessionCtrl.add(null);
  }

  void logStride(StrideData s) {
    if (!_active || _sink == null) return;
    _strideCount++;
    _sink!.writeln(
      '$_strideCount,${s.elapsedS.toStringAsFixed(3)},'
      '${s.omegaPico},${s.tauStPct},${s.alphaAtq}'
    );
    _strideCtrl.add(s);
  }

  Future<void> close() async {
    _active = false;
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }

  Future<void> exportCurrent() async {
    if (_file == null || !await _file!.exists()) return;
    await Share.shareXFiles([XFile(_file!.path)], subject: 'PAIA session');
  }
}
