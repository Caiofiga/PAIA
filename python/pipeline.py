import json
import os
import collections
import numpy as np
from scipy.signal import butter, sosfilt, sosfilt_zi

_CONFIG_PATH = os.path.join(os.path.dirname(__file__), 'athlete.json')


def _load_cfg():
    try:
        with open(_CONFIG_PATH) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


# ── Filter helpers ────────────────────────────────────────────────────────────

def _butter_lowpass_sos(cutoff_hz, fs, order=4):
    """Return second-order sections for a Butterworth low-pass filter."""
    nyq = 0.5 * fs
    return butter(order, cutoff_hz / nyq, btype='low', output='sos')


class MedianFilter:
    """Running median over a fixed-length window (no delay beyond window/2)."""

    def __init__(self, window=5):
        self.window = window
        self.buf = collections.deque(maxlen=window)

    def update(self, value):
        self.buf.append(value)
        return float(np.median(self.buf))

    def reset(self):
        self.buf.clear()


class ButterworthFilter:
    """Online (sample-by-sample) Butterworth low-pass filter using SOS."""

    def __init__(self, cutoff_hz, fs, order=4):
        self.sos = _butter_lowpass_sos(cutoff_hz, fs, order)
        self.zi  = sosfilt_zi(self.sos)   # shape (n_sections, 2)
        self.zi  = self.zi * 0.0          # zero initial state

    def update(self, value):
        out, self.zi = sosfilt(self.sos, [value], zi=self.zi)
        return float(out[0])

    def reset(self):
        self.zi = sosfilt_zi(self.sos) * 0.0


# ── Mahony complementary filter ───────────────────────────────────────────────

class MahonyFilter:
    """
    Mahony complementary filter.
    Inputs : accel (any unit — normalised internally), gyro (rad/s)
    Output : pitch angle in radians (sagittal plane)
    """

    def __init__(self, kp=10.0, ki=0.01, dt=0.01):
        self.kp   = kp
        self.ki   = ki
        self.dt   = dt
        self.q    = np.array([1.0, 0.0, 0.0, 0.0])
        self.eInt = np.zeros(3)

    def reset(self):
        self.q    = np.array([1.0, 0.0, 0.0, 0.0])
        self.eInt = np.zeros(3)

    def update(self, ax, ay, az, gx, gy, gz):
        q = self.q

        norm = np.sqrt(ax*ax + ay*ay + az*az)
        if norm < 1e-6:
            return self._pitch()
        ax, ay, az = ax/norm, ay/norm, az/norm

        vx = 2*(q[1]*q[3] - q[0]*q[2])
        vy = 2*(q[0]*q[1] + q[2]*q[3])
        vz = q[0]*q[0] - q[1]*q[1] - q[2]*q[2] + q[3]*q[3]

        ex = ay*vz - az*vy
        ey = az*vx - ax*vz
        ez = ax*vy - ay*vx

        self.eInt += np.array([ex, ey, ez]) * self.ki * self.dt

        gx += self.kp*ex + self.eInt[0]
        gy += self.kp*ey + self.eInt[1]
        gz += self.kp*ez + self.eInt[2]

        qa, qb, qc, qd = q
        q[0] += 0.5*self.dt*(-qb*gx - qc*gy - qd*gz)
        q[1] += 0.5*self.dt*( qa*gx + qc*gz - qd*gy)
        q[2] += 0.5*self.dt*( qa*gy - qb*gz + qd*gx)
        q[3] += 0.5*self.dt*( qa*gz + qb*gy - qc*gx)

        self.q = q / np.linalg.norm(q)
        return self._pitch()

    def _pitch(self):
        q = self.q
        return float(np.arcsin(np.clip(2*(q[0]*q[2] - q[3]*q[1]), -1.0, 1.0)))


# ── Pipeline ──────────────────────────────────────────────────────────────────

class Pipeline:
    """
    Biomechanical pipeline — PAIA approach:

      Phase 0 — Static gravity calibration
                 Athlete stands still for ~STATIC_CALIB_SAMPLES samples.
                 Measures gravity vector magnitude from accelerometer to set
                 ACCEL_GRAVITY and ACCEL_STANCE_THRESHOLD for swing detection.
                 Also captures theta_ref from Mahony during quiet standing.

      Task 1  — Signal filtering
                 Median filter (window=5) on raw accel/gyro before Mahony
                 to remove impulse noise / comms spikes.
                 Butterworth low-pass (10 Hz, order=4) on the Mahony pitch
                 output to smooth the angle estimate.

      Task 2  — Swing detection (dual-criterion)
                 Primary  : |ω_sagittal| > SWING_ENTRY_OMEGA  (gyroscope)
                 Secondary: |a_total - 1g| > ACCEL_SWING_THRESHOLD (accel)
                 Either criterion alone can open the swing window.
                 Both must be absent (with hysteresis) to close it.

      Task 3  — Stride segmentation → ωpico, τst%, αatq per stride
                 Strides with physiologically impossible values are rejected.

      Task 4  — Return aggregation (STRIDES_PER_RETURN strides, median)
                 Uses median instead of mean for outlier robustness.

      Task 5  — 2σ alert criterion on raw parameter values vs. baseline.

    MPU1 args are accepted for API/hardware compatibility but ignored.
    """

    ACCEL_SCALE = 1.0 / 8192.0           # ±4 g  → g
    GYRO_SCALE  = (np.pi / 180) / 65.5   # ±500 °/s → rad/s

    # Hard technical limits — sensor/algorithm failures only, not biology.
    TAU_ST_HARD_MAX      = 98.0   # % — swing phase never detected (algorithm error)
    STRIDE_TIME_HARD_MIN =  0.3   # s — physically impossible for any human

    # Adaptive MAD-based outlier filter multiplier.
    MAD_K = 6.0

    def __init__(self, sample_rate=100):
        cfg = _load_cfg()
        self.dt          = 1.0 / sample_rate
        self.sample_rate = sample_rate

        # Gyro axis for sagittal angular velocity — 0=X 1=Y 2=Z
        self.gyro_axis = int(cfg.get('gyro_axis', 1))

        # Swing detection thresholds
        self.SWING_ENTRY_OMEGA  = float(cfg.get('swing_entry_omega', 0.35))  # rad/s
        self.SWING_EXIT_RATIO   = 0.6    # hysteresis on gyro criterion
        self.MIN_SWING_SAMPLES  = int(cfg.get('min_swing_samples', 10))

        # Accel-based swing threshold (set during static calibration, default fallback)
        self.ACCEL_SWING_THRESH = float(cfg.get('accel_swing_thresh', 0.15))  # g deviation from 1g

        # Butterworth low-pass for Mahony pitch output
        lp_cutoff = float(cfg.get('lp_cutoff_hz', 10.0))
        self.butter = ButterworthFilter(lp_cutoff, sample_rate, order=4)

        # Median filters for raw accel and gyro axes
        med_win = int(cfg.get('median_window', 5))
        # One median filter per channel (ax, ay, az, gx, gy, gz)
        self.med = [MedianFilter(med_win) for _ in range(6)]

        # Return aggregation
        self.STRIDES_PER_RETURN = int(cfg.get('strides_per_return', 6))
        self.N_WINDOW           = int(cfg.get('n_window', 4))

        # Static calibration phase
        self.STATIC_CALIB_SAMPLES = int(cfg.get('static_calib_samples', 200))  # ~2 s at 100 Hz
        self.static_phase         = True
        self.static_buf           = []      # list of (accel_norm, theta)
        self.gravity_magnitude    = 1.0     # g — updated after static calib
        self.theta_ref            = 0.0     # deg — tibia pitch during quiet standing

        # Dynamic calibration (walking, 40 strides)
        self.CALIB_STRIDES = int(cfg.get('calib_strides', 40))
        self.calibrated    = False
        self.calib_data    = []             # list of (omega_pico_deg, tau_st_pct, alpha_atq_deg)
        self.baseline_mean = None
        self.baseline_std  = None

        self.f0 = MahonyFilter(dt=self.dt)

        # Stride state machine
        self.in_swing       = False
        self.swing_start_ts = None
        self.prev_ic_ts     = None
        self.omega_buf      = []
        self.swing_samples  = 0

        # Return aggregation
        self.return_stride_buf = []
        self.returns           = []
        self.return_index      = 0

        self.strides = []

        # Circular buffer of recent raw stride values for adaptive MAD filter.
        self._recent_omega = collections.deque(maxlen=20)
        self._recent_tau   = collections.deque(maxlen=20)

    # ── Public entry point ────────────────────────────────────────────────────

    def process(self, ts,
                ax0, ay0, az0, gx0, gy0, gz0,
                ax1, ay1, az1, gx1, gy1, gz1):
        """
        ts  : timestamp in seconds
        ax* : raw int16 accel LSB
        gx* : raw int16 gyro  LSB
        Returns dict for dashboard.
        """
        # Scale raw values
        raw_a = np.array([ax0, ay0, az0], dtype=float) * self.ACCEL_SCALE
        raw_g = np.array([gx0, gy0, gz0], dtype=float) * self.GYRO_SCALE

        # ── Layer 1: Median filter on raw signals ──────────────────────────
        a0 = np.array([self.med[i].update(raw_a[i]) for i in range(3)])
        g0 = np.array([self.med[i+3].update(raw_g[i]) for i in range(3)])

        # ── Layer 2: Mahony fusion → pitch angle ───────────────────────────
        theta_raw = self.f0.update(*a0, *g0)

        # ── Layer 3: Butterworth low-pass on angle ─────────────────────────
        theta = self.butter.update(theta_raw)

        omega = float(g0[self.gyro_axis])          # sagittal ω (rad/s)
        accel_norm = float(np.linalg.norm(a0))     # total accel magnitude (g)

        # ── Phase 0: Static gravity calibration ───────────────────────────
        if self.static_phase:
            self.static_buf.append((accel_norm, theta))
            progress = len(self.static_buf) / self.STATIC_CALIB_SAMPLES
            if len(self.static_buf) >= self.STATIC_CALIB_SAMPLES:
                self._finish_static_calibration()
            return {
                'type':     'static_calib',
                'progress': round(progress, 2),
                'message':  'Stand still — static calibration',
            }

        # ── Phase 1: Dynamic calibration (walking to track) ───────────────
        if not self.calibrated:
            stride = self._segment(ts, theta, omega, accel_norm)
            if stride is not None:
                self.calib_data.append(
                    (stride['omega_pico'], stride['tau_st_pct'], stride['alpha_atq'])
                )
                if len(self.calib_data) >= self.CALIB_STRIDES:
                    self._finish_dynamic_calibration()
            return {
                'type':      'calibrating',
                'progress':  round(len(self.calib_data) / self.CALIB_STRIDES, 2),
                'theta_deg': round(np.degrees(theta), 2),
            }

        # ── Phase 2: Normal operation ─────────────────────────────────────
        stride = self._segment(ts, theta, omega, accel_norm)
        return_result = None
        if stride is not None:
            pub = {k: v for k, v in stride.items() if not k.startswith('_')}
            self.return_stride_buf.append(pub)
            if len(self.return_stride_buf) >= self.STRIDES_PER_RETURN:
                return_result = self._aggregate_return()

        payload = {
            'type':        'live',
            'ts':          round(ts, 3),
            'theta':       round(np.degrees(theta), 2),
            'omega':       round(np.degrees(omega), 2),
            'accel_norm':  round(accel_norm, 3),
        }
        if stride is not None:
            payload['stride'] = {k: v for k, v in stride.items()
                                 if not k.startswith('_')}
        if return_result is not None:
            payload['return'] = return_result

        return payload

    # ── Phase 0: Static calibration ───────────────────────────────────────────

    def _finish_static_calibration(self):
        """
        Compute gravity magnitude and theta_ref from quiet standing.
        The last 50% of the buffer is used (first samples may still be
        settling the Mahony filter).
        """
        buf = np.array(self.static_buf)
        half = len(buf) // 2
        stable = buf[half:]                       # use only settled portion

        self.gravity_magnitude = float(stable[:, 0].mean())

        # Accel swing threshold: deviation from gravity that signals foot-off
        # Measured as 3 × std of accel_norm during quiet standing
        accel_std = float(stable[:, 0].std())
        self.ACCEL_SWING_THRESH = max(3.0 * accel_std, 0.05)

        # theta_ref: mean pitch during quiet standing = anatomical neutral (degrees)
        self.theta_ref = float(np.degrees(stable[:, 1].mean()))

        self.static_phase = False
        print(f'[CALIB-STATIC] gravity={self.gravity_magnitude:.4f}g  '
              f'accel_thresh={self.ACCEL_SWING_THRESH:.4f}g  '
              f'theta_ref={self.theta_ref:.2f}°')

    # ── Phase 1: Dynamic calibration ──────────────────────────────────────────

    def _finish_dynamic_calibration(self):
        data = np.array(self.calib_data)           # (N, 3): omega, tau, alpha
        self.baseline_mean = data.mean(axis=0)
        self.baseline_std  = np.maximum(data.std(axis=0), 1e-6)
        self.calibrated    = True
        print(f'[CALIB-DYNAMIC] mean={self.baseline_mean}  std={self.baseline_std}')

    # ── Task 2: Swing detection (dual-criterion) ──────────────────────────────

    def _is_swing_entry(self, omega, accel_norm):
        gyro_crit  = abs(omega) > self.SWING_ENTRY_OMEGA
        accel_dev  = abs(accel_norm - self.gravity_magnitude)
        accel_crit = accel_dev > self.ACCEL_SWING_THRESH
        return gyro_crit or accel_crit

    def _is_swing_exit(self, omega, accel_norm):
        exit_thresh   = self.SWING_ENTRY_OMEGA * self.SWING_EXIT_RATIO
        gyro_settled  = abs(omega) < exit_thresh
        accel_settled = abs(accel_norm - self.gravity_magnitude) < self.ACCEL_SWING_THRESH * 0.7
        return gyro_settled and accel_settled

    # ── Task 3: Stride segmentation ───────────────────────────────────────────

    def _segment(self, ts, theta, omega, accel_norm):
        if not self.in_swing and self._is_swing_entry(omega, accel_norm):
            self.in_swing       = True
            self.swing_start_ts = ts
            self.omega_buf      = []
            self.swing_samples  = 0

        if self.in_swing:
            self.omega_buf.append(abs(omega))
            self.swing_samples += 1

            if self._is_swing_exit(omega, accel_norm) \
                    and self.swing_samples > self.MIN_SWING_SAMPLES:

                omega_pico_deg = float(np.degrees(max(self.omega_buf)))
                swing_time  = ts - self.swing_start_ts
                stride_time = (ts - self.prev_ic_ts) if self.prev_ic_ts is not None else None

                self.in_swing   = False
                self.prev_ic_ts = ts

                if stride_time is None or stride_time < 1e-6:
                    return None

                stance_time = max(stride_time - swing_time, 0.0)
                tau_st_pct  = float(np.clip(stance_time / stride_time * 100.0, 0.0, 100.0))
                alpha_atq   = float(np.degrees(theta) - self.theta_ref)

                # ── Physiological validity gate ────────────────────────────
                if not self._is_valid_stride(omega_pico_deg, tau_st_pct, stride_time):
                    return None

                entry = {
                    'omega_pico': round(omega_pico_deg, 2),
                    'tau_st_pct': round(tau_st_pct, 2),
                    'alpha_atq':  round(alpha_atq, 2),
                }
                self._register_stride(omega_pico_deg, tau_st_pct)
                self.strides.append(entry)
                return entry

        return None

    def _is_valid_stride(self, omega_pico, tau_st_pct, stride_time):
        # --- Layer A: hard technical limits ---
        if tau_st_pct > self.TAU_ST_HARD_MAX:
            return False
        if stride_time < self.STRIDE_TIME_HARD_MIN:
            return False

        # --- Layer B: adaptive MAD ---
        if len(self._recent_omega) >= 5:
            def _mad_ok(value, buf):
                arr    = np.array(buf)
                median = np.median(arr)
                mad    = np.median(np.abs(arr - median))
                if mad < 1e-6:
                    return True
                return abs(value - median) <= self.MAD_K * mad

            if not _mad_ok(omega_pico, self._recent_omega):
                return False
            if not _mad_ok(tau_st_pct, self._recent_tau):
                return False

        return True

    def _register_stride(self, omega_pico, tau_st_pct):
        self._recent_omega.append(omega_pico)
        self._recent_tau.append(tau_st_pct)

    # ── Task 4: Return aggregation ────────────────────────────────────────────

    def _aggregate_return(self):
        data = np.array([
            (s['omega_pico'], s['tau_st_pct'], s['alpha_atq'])
            for s in self.return_stride_buf
        ])
        median_vec = np.median(data, axis=0)
        self.returns.append(median_vec.tolist())
        self.return_stride_buf = []
        self.return_index += 1

        deviations = None
        alert = False
        if self.baseline_mean is not None:
            raw_dev    = (median_vec - self.baseline_mean) / self.baseline_std
            # Directional: positive = worse (omega↓, tau↑, alpha↓)
            deviations = [-float(raw_dev[0]), float(raw_dev[1]), -float(raw_dev[2])]
            alert      = sum(abs(d) > 2.0 for d in deviations) >= 2

        return {
            'n':          self.return_index,
            'omega_pico': round(float(median_vec[0]), 2),
            'tau_st_pct': round(float(median_vec[1]), 2),
            'alpha_atq':  round(float(median_vec[2]), 2),
            'deviations': [round(d, 3) for d in deviations] if deviations else None,
            'alert':      alert,
        }

    # ── Reset ─────────────────────────────────────────────────────────────────

    def reset(self):
        self.f0.reset()
        for f in self.med:
            f.reset()
        self.butter.reset()

        self.static_phase      = True
        self.static_buf        = []
        self.gravity_magnitude = 1.0
        self.theta_ref         = 0.0

        self.calibrated    = False
        self.calib_data    = []
        self.baseline_mean = None
        self.baseline_std  = None

        self.in_swing       = False
        self.swing_start_ts = None
        self.prev_ic_ts     = None
        self.omega_buf      = []
        self.swing_samples  = 0

        self.return_stride_buf = []
        self.returns           = []
        self.return_index      = 0
        self.strides           = []

        self._recent_omega.clear()
        self._recent_tau.clear()
