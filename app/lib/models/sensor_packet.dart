class SensorPacket {
  final int tsMsRaw;
  final int ax0, ay0, az0;
  final int gx0, gy0, gz0;
  final int ax1, ay1, az1;
  final int gx1, gy1, gz1;

  const SensorPacket({
    required this.tsMsRaw,
    required this.ax0, required this.ay0, required this.az0,
    required this.gx0, required this.gy0, required this.gz0,
    required this.ax1, required this.ay1, required this.az1,
    required this.gx1, required this.gy1, required this.gz1,
  });
}
