# PAIA — Project Guide for Claude

## Structure

```
PAIA3/
├── app/                    # Flutter mobile app (iOS + Android)
│   ├── lib/
│   │   ├── main.dart
│   │   ├── config/athlete_config.dart     # SharedPreferences config
│   │   ├── models/
│   │   │   ├── pipeline_result.dart
│   │   │   ├── sensor_packet.dart
│   │   │   └── session_record.dart        # StrideRow, SessionRecord
│   │   ├── services/
│   │   │   ├── udp_service.dart           # RawDatagramSocket :4210, feeds pipeline
│   │   │   ├── packet_parser.dart         # 28-byte little-endian parser
│   │   │   ├── mahony_filter.dart         # Quaternion complementary filter → pitch
│   │   │   ├── pipeline_service.dart      # Full biomech pipeline, has reset()
│   │   │   ├── session_service.dart       # CSV write, onNewSession/strideStream
│   │   │   └── sessions_repository.dart   # Scans docs dir for session_*.csv
│   │   ├── screens/
│   │   │   ├── dashboard_screen.dart      # Live view, intro+calib overlays
│   │   │   └── sessions_screen.dart       # Session list + detail, batch select
│   │   └── widgets/
│   │       ├── live_chart.dart
│   │       ├── readout_card.dart
│   │       └── return_table.dart
│   ├── android/app/src/main/AndroidManifest.xml
│   ├── ios/Runner/Info.plist
│   └── pubspec.yaml                       # name: paia
├── firmware/
│   ├── PAIA3.ino                          # ESP32 SoftAP, UDP broadcast :4210
│   └── ShittyIMU.{cpp,h}                 # MPU-6050 driver
├── python/
│   ├── sim.py                             # UDP replay simulator
│   ├── pipeline.py                        # Python reference pipeline
│   └── backend.py                        # Legacy Flask backend (unused)
├── .github/workflows/build.yml           # CI: 4 jobs (android/ios × debug/release)
└── README.md
```

## No Git — Never Run Git Commands

User has no git repo. Never run `git`, `git commit`, `git init`, etc.

## Key Constants

| Constant | Value |
|----------|-------|
| UDP port | 4210 |
| Packet size | 28 bytes |
| ACCEL_SCALE | 1/8192.0 (→ g) |
| GYRO_SCALE | (π/180)/65.5 (→ rad/s) |
| Calibration strides | 40 |
| Strides per return | 6 |
| nWindow (OLS) | 4 |
| Sample rate | 100 Hz |

## Packet Format (little-endian)

```
uint32  ts_ms
int16   ax0,ay0,az0, gx0,gy0,gz0   (IMU 0)
int16   ax1,ay1,az1, gx1,gy1,gz1   (IMU 1)
```

## Pipeline Flow

```
UDP packet → MahonyFilter → theta (pitch), omega (gyro axis 1)
           → _segment() FSM: swing entry (|ω|>0.35) / exit (|ω|<0.245)
           → stride: omegaPico, tauStPct, alphaAtq
           → [40 strides] _finishCalibration() → _thetaRef, _baselineMean
           → [6 strides] _aggregateReturn() → ReturnData
           → [≥2 returns] _computeTrend() → OLS slopes → IT index
           → alert if ≥2 normSlopes > 2σ
```

## App Flow

1. Launch → intro overlay ("PAIA" + START button)
2. Press START → `session.newSession()` + `pipeline.reset()` → calib overlay
3. 40 strides → calibration done → live dashboard
4. "⊕ New Session" → same as step 2 (recalibrates)

## Sessions

- CSVs stored in `getApplicationDocumentsDirectory()` as `session_YYYY-MM-DDTHH-MM-SS.csv`
- `SessionService` streams: `onNewSession` (void), `strideStream` (StrideData)
- `SessionsScreen` polls every 3s via `Timer.periodic` + listens to `onNewSession`
- Header flushed (`await _sink!.flush()`) before `onNewSession` fires

## fl_chart Axis Labels

Known issue: labels crowd at edges. Fix pattern in all charts:
```dart
getTitlesWidget: (v, meta) {
  if (v == meta.min || v == meta.max) return const SizedBox.shrink();
  return SideTitleWidget(axisSide: meta.axisSide, child: Text(...));
},
```

## Android UDP Broadcast

Requires `WifiManager.MulticastLock` — not yet implemented. Add `multicast_lock: ^1.0.0` to pubspec + acquire in `UdpService.start()`. Samsung also needs "Smart Network Switch" disabled.

## CI Secrets Needed

Android: `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`
iOS: `IOS_CERTIFICATE_BASE64`, `IOS_CERTIFICATE_PASSWORD`, `IOS_KEYCHAIN_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`

## share_plus Version

Using v10.1.4. API is `Share.shareXFiles([XFile(path)], subject: '...')`. NOT `SharePlus.instance.share(ShareParams(...))` (that's v11+).
