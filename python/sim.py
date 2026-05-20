"""
sim.py — fake UDP sender for testing without hardware.

Simulates 2x MPU-6050 on a running ankle at ~100Hz.
Models a sinusoidal ankle gait with periodic terminal-swing deceleration.

Usage:
    python sim.py [--host 127.0.0.1] [--port 4210] [--rate 100] [--noise 200]
"""

import argparse
import math
import socket
import struct
import time

# ── Packet format must match PAIA3.ino and backend.py ──────────────────────
PACKET_FMT = '<I' + 'h' * 12

# MPU-6050 scale factors (±4g / ±500°/s) — inverse of pipeline.py
ACCEL_LSB_PER_G    = 8192
GYRO_LSB_PER_DEGS  = 65.5


def to_accel(g_val):
    return int(g_val * ACCEL_LSB_PER_G)


def to_gyro(degs_val):
    return int(degs_val * GYRO_LSB_PER_DEGS)


def clamp16(v):
    return max(-32768, min(32767, int(v)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host',  default='127.0.0.1')
    parser.add_argument('--port',  type=int, default=4210)
    parser.add_argument('--rate',  type=int, default=100,  help='samples/s')
    parser.add_argument('--noise', type=int, default=200,  help='accel LSB noise amplitude')
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    dt   = 1.0 / args.rate
    t    = 0.0
    ts_ms = 0

    # Gait parameters
    STRIDE_PERIOD = 0.6    # s per stride
    ANKLE_AMP_DEG = 20.0   # peak ankle angle amplitude (degrees)
    SHANK_AMP_DEG = 5.0    # shank rocks slightly less

    import random
    rng = random.Random(42)

    print(f'[SIM] Sending to {args.host}:{args.port} at {args.rate} Hz  (Ctrl-C to stop)')

    interval = dt

    while True:
        loop_start = time.perf_counter()

        phase = 2 * math.pi * (t / STRIDE_PERIOD)

        # Foot angle — sinusoidal with sharp deceleration at terminal swing
        foot_angle_deg   = ANKLE_AMP_DEG * math.sin(phase)
        foot_omega_degs  = ANKLE_AMP_DEG * (2*math.pi / STRIDE_PERIOD) * math.cos(phase)
        foot_alpha_degs2 = -ANKLE_AMP_DEG * (2*math.pi / STRIDE_PERIOD)**2 * math.sin(phase)

        # Shank follows with smaller amplitude, slight phase lag
        shank_angle_deg   = SHANK_AMP_DEG * math.sin(phase - 0.3)
        shank_omega_degs  = SHANK_AMP_DEG * (2*math.pi / STRIDE_PERIOD) * math.cos(phase - 0.3)

        # ── Build fake accel/gyro for each MPU ──────────────────────────────

        # Gravity projection from pitch angle
        def gravity_xyz(pitch_rad):
            # Returns (ax_g, ay_g, az_g) for a sensor rotated by pitch
            return (-math.sin(pitch_rad), 0.0, math.cos(pitch_rad))

        foot_pitch_rad  = math.radians(foot_angle_deg)
        shank_pitch_rad = math.radians(shank_angle_deg)

        gx_f, gy_f, gz_f = gravity_xyz(foot_pitch_rad)
        gx_s, gy_s, gz_s = gravity_xyz(shank_pitch_rad)

        noise = args.noise

        # MPU0 = shank
        ax0 = clamp16(to_accel(gx_s) + rng.randint(-noise, noise))
        ay0 = clamp16(to_accel(gy_s) + rng.randint(-noise, noise))
        az0 = clamp16(to_accel(gz_s) + rng.randint(-noise, noise))
        gx0 = clamp16(to_gyro(0.0))
        gy0 = clamp16(to_gyro(shank_omega_degs) + rng.randint(-20, 20))
        gz0 = clamp16(to_gyro(0.0))

        # MPU1 = foot
        ax1 = clamp16(to_accel(gx_f) + rng.randint(-noise, noise))
        ay1 = clamp16(to_accel(gy_f) + rng.randint(-noise, noise))
        az1 = clamp16(to_accel(gz_f) + rng.randint(-noise, noise))
        gx1 = clamp16(to_gyro(0.0))
        gy1 = clamp16(to_gyro(foot_omega_degs) + rng.randint(-20, 20))
        gz1 = clamp16(to_gyro(0.0))

        pkt = struct.pack(PACKET_FMT,
                          ts_ms,
                          ax0, ay0, az0, gx0, gy0, gz0,
                          ax1, ay1, az1, gx1, gy1, gz1)

        sock.sendto(pkt, (args.host, args.port))

        t     += dt
        ts_ms += int(dt * 1000)

        elapsed = time.perf_counter() - loop_start
        sleep_t = interval - elapsed
        if sleep_t > 0:
            time.sleep(sleep_t)


if __name__ == '__main__':
    main()
