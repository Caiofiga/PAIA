import 'package:flutter/material.dart';
import 'package:paia/config/athlete_config.dart';
import 'package:paia/screens/dashboard_screen.dart';
import 'package:paia/screens/sessions_screen.dart';
import 'package:paia/services/pipeline_service.dart';
import 'package:paia/services/session_service.dart';
import 'package:paia/services/udp_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cfg      = await AthleteConfig.load();
  final pipeline = PipelineService(
    sampleRate:          100,
    gyroAxis:            cfg.gyroAxis,
    swingEntryOmega:     cfg.swingEntryOmega,
    minSwingSamples:     cfg.minSwingSamples,
    stridesPerReturn:    cfg.stridesPerReturn,
    calibStrides:        cfg.calibStrides,
    staticCalibSamples:  cfg.staticCalibSamples,
    accelSwingThresh:    cfg.accelSwingThresh,
  );
  final udp     = UdpService(pipeline);
  final session = SessionService();
  session.attachRawStream(udp.rawPackets);
  runApp(Paia3App(udp: udp, session: session, pipeline: pipeline));
}

class Paia3App extends StatelessWidget {
  final UdpService      udp;
  final SessionService  session;
  final PipelineService pipeline;

  const Paia3App({
    super.key,
    required this.udp,
    required this.session,
    required this.pipeline,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PAIA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF111111),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF42A5F5),
        ),
      ),
      home: _RootScreen(udp: udp, session: session, pipeline: pipeline),
    );
  }
}

class _RootScreen extends StatefulWidget {
  final UdpService      udp;
  final SessionService  session;
  final PipelineService pipeline;

  const _RootScreen({
    required this.udp,
    required this.session,
    required this.pipeline,
  });

  @override
  State<_RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<_RootScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          DashboardScreen(udp: widget.udp, session: widget.session, pipeline: widget.pipeline),
          SessionsScreen(session: widget.session),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tab,
        onTap: (i) => setState(() => _tab = i),
        backgroundColor: const Color(0xFF1E1E1E),
        selectedItemColor: const Color(0xFF42A5F5),
        unselectedItemColor: const Color(0xFF546E7A),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.monitor_heart), label: 'Dashboard'),
          BottomNavigationBarItem(icon: Icon(Icons.folder_open), label: 'Sessões'),
        ],
      ),
    );
  }
}
