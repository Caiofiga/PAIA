# PAIA — Biomechanical Running Monitor

Real-time running gait analysis system. ESP32 with dual MPU-6050 IMUs broadcasts raw sensor data over UDP. Flutter mobile app (iOS + Android) receives data, runs full biomechanical pipeline on-device, stores session CSVs.

## Architecture

```
ESP32 (MPU-6050 × 2)
  └── UDP broadcast :4210 (28-byte packets @ 100 Hz)
        └── Flutter app
              ├── Mahony filter → pitch angle
              ├── Swing/stance FSM → stride segmentation
              ├── Calibration (40 strides walk-in)
              ├── Return aggregation (6 strides → mean)
              ├── OLS trend regression → Normalized Trend Index (IT)
              └── CSV session storage
```

## Packet Format

28-byte little-endian:
```
uint32  ts_ms       — timestamp (ms)
int16   ax0, ay0, az0  — accel IMU 0 (raw, ÷8192 → g)
int16   gx0, gy0, gz0  — gyro  IMU 0 (raw, ÷65.5 → °/s)
int16   ax1, ay1, az1  — accel IMU 1
int16   gx1, gy1, gz1  — gyro  IMU 1
```

## Mobile App

**Location:** `app/`

### Requirements
- Flutter 3.32+
- Dart SDK 3.11+
- Android: API 21+ / iOS: 12+

### Build

```bash
cd app
flutter pub get

# Debug
flutter build apk --debug
flutter build ios --debug --no-codesign

# Release (requires signing setup)
flutter build apk --release
flutter build ipa --release
```

### Android — Samsung / Broadcast UDP

Samsung and other Android devices filter UDP broadcast by default. The app requires:

1. **Multicast lock** — add `multicast_lock` package (see [Known Issues](#known-issues))
2. **Manifest permissions:**
   ```xml
   <uses-permission android:name="android.permission.INTERNET"/>
   <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE"/>
   <uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
   ```
3. **Disable Smart Network Switch** on device: Settings → Connections → WiFi → [network] → disable "Switch to mobile data"

## Simulator (`sim.py`)

Replays pre-recorded sensor data over UDP for testing without hardware.

```bash
cd python
pip install -r requirements.txt

# Broadcast on specific interface
python sim.py --host <broadcast_address>

# Examples
python sim.py --host 127.0.0.1          # localhost
python sim.py --host 10.42.0.255        # Linux hotspot
python sim.py --host 192.168.4.255      # ESP32 AP subnet
```

Find your hotspot broadcast address: `ip addr show` — look for the AP interface inet address, replace last octet with 255.

## Firmware

**Location:** `firmware/PAIA3.ino`

ESP32 SoftAP mode. Broadcasts 28-byte sensor packets at ~100 Hz to `192.168.4.255:4210`. Supports up to 4 simultaneous client connections (configurable in firmware).

## Known Issues

- **Android broadcast UDP** — requires `WifiManager.MulticastLock`. Add `multicast_lock: ^1.0.0` to `pubspec.yaml` and acquire lock in `UdpService.start()` before binding socket.
- **Hotspot forwarding** — when testing via laptop hotspot, ensure `net.ipv4.ip_forward=1` and iptables FORWARD chain allows traffic on the hotspot interface.
- **Axis labels (fl_chart)** — labels at chart min/max positions overlap borders; workaround: skip `meta.min`/`meta.max` in `getTitlesWidget`.
