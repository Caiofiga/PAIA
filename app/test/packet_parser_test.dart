import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:paia3_app/services/packet_parser.dart';

void main() {
  test('parseSensorPacket decodes 28-byte little-endian packet', () {
    final bd = ByteData(28);
    bd.setUint32(0, 1000, Endian.little);
    bd.setInt16(4,  100,  Endian.little);
    bd.setInt16(6, -200,  Endian.little);
    bd.setInt16(8,  300,  Endian.little);
    bd.setInt16(10, 400,  Endian.little);
    bd.setInt16(12, -500, Endian.little);
    bd.setInt16(14, 600,  Endian.little);
    bd.setInt16(16, 1,    Endian.little);
    bd.setInt16(18, 2,    Endian.little);
    bd.setInt16(20, 3,    Endian.little);
    bd.setInt16(22, 4,    Endian.little);
    bd.setInt16(24, 5,    Endian.little);
    bd.setInt16(26, 6,    Endian.little);

    final pkt = parseSensorPacket(bd.buffer.asUint8List());

    expect(pkt, isNotNull);
    expect(pkt!.tsMsRaw, 1000);
    expect(pkt.ax0, 100);
    expect(pkt.ay0, -200);
    expect(pkt.az0, 300);
    expect(pkt.gx0, 400);
    expect(pkt.gy0, -500);
    expect(pkt.gz0, 600);
    expect(pkt.ax1, 1);
    expect(pkt.gz1, 6);
  });

  test('parseSensorPacket returns null for short packets', () {
    expect(parseSensorPacket(Uint8List(10)), isNull);
    expect(parseSensorPacket(Uint8List(0)), isNull);
  });
}
