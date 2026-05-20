import 'dart:typed_data';
import 'package:paia/models/sensor_packet.dart';

const int _packetSize = 28; // 4 + 12*2

SensorPacket? parseSensorPacket(Uint8List data) {
  if (data.length < _packetSize) return null;
  final bd = ByteData.sublistView(data);
  return SensorPacket(
    tsMsRaw: bd.getUint32(0, Endian.little),
    ax0: bd.getInt16(4,  Endian.little),
    ay0: bd.getInt16(6,  Endian.little),
    az0: bd.getInt16(8,  Endian.little),
    gx0: bd.getInt16(10, Endian.little),
    gy0: bd.getInt16(12, Endian.little),
    gz0: bd.getInt16(14, Endian.little),
    ax1: bd.getInt16(16, Endian.little),
    ay1: bd.getInt16(18, Endian.little),
    az1: bd.getInt16(20, Endian.little),
    gx1: bd.getInt16(22, Endian.little),
    gy1: bd.getInt16(24, Endian.little),
    gz1: bd.getInt16(26, Endian.little),
  );
}
