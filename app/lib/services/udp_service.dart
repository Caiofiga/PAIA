import 'dart:async';
import 'dart:io';
import 'package:paia/models/pipeline_result.dart';
import 'package:paia/services/packet_parser.dart';
import 'package:paia/services/pipeline_service.dart';

class UdpService {
  static const int udpPort = 4210;

  final PipelineService _pipeline;
  RawDatagramSocket? _socket;
  final _controller = StreamController<PipelineResult>.broadcast();
  int? _firstTsMs;

  Stream<PipelineResult> get results => _controller.stream;

  UdpService(this._pipeline);

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort);
    _socket!.broadcastEnabled = true;
    _firstTsMs = null;
    _socket!.listen(_onEvent);
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;

    final pkt = parseSensorPacket(dg.data);
    if (pkt == null) return;

    _firstTsMs ??= pkt.tsMsRaw;
    final normTsMs = pkt.tsMsRaw - _firstTsMs!;

    final result = _pipeline.process(
      normTsMs / 1000.0,
      pkt.ax0, pkt.ay0, pkt.az0,
      pkt.gx0, pkt.gy0, pkt.gz0,
      pkt.ax1, pkt.ay1, pkt.az1,
      pkt.gx1, pkt.gy1, pkt.gz1,
    );
    _controller.add(result);
  }

  void stop() {
    _socket?.close();
    _socket = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
