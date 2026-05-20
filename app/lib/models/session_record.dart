class StrideRow {
  final int    stride;
  final double timeS;
  final double omegaPico;
  final double tauStPct;
  final double alphaAtq;

  const StrideRow({
    required this.stride,
    required this.timeS,
    required this.omegaPico,
    required this.tauStPct,
    required this.alphaAtq,
  });
}

class SessionRecord {
  final String       fileName;   // e.g. "session_2026-05-20T14-30-00"
  final String       filePath;
  final List<StrideRow> strides;

  const SessionRecord({
    required this.fileName,
    required this.filePath,
    required this.strides,
  });

  int get strideCount => strides.length;

  /// Display label: "20 May 14:30" extracted from ISO timestamp in filename
  String get displayLabel {
    try {
      // filename like "session_2026-05-20T14-30-00"
      final part = fileName.replaceFirst('session_', '');
      final dt   = DateTime.parse(part.replaceAll(RegExp(r'T(\d{2})-(\d{2})-(\d{2})'), 'T\$1:\$2:\$3'));
      return '${dt.day} ${_month(dt.month)} ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
    } catch (_) {
      return fileName;
    }
  }

  static String _month(int m) => ['Jan','Feb','Mar','Apr','May','Jun',
    'Jul','Aug','Sep','Oct','Nov','Dec'][m - 1];
}
