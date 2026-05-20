import json
import os
import numpy as np

_CONFIG_PATH = os.path.join(os.path.dirname(__file__), 'athlete.json')


def _load_cfg():
    try:
        with open(_CONFIG_PATH) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


class MahonyFilter:
    """
    Mahony complementary filter.
    Inputs : accel (any unit — normalized internally), gyro (rad/s)
    Output : pitch angle in radians (sagittal plane)
    """

    def __init__(self, kp=10.0, ki=0.01, dt=0.01):
        self.kp = kp
        self.ki = ki
        self.dt = dt
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


class Pipeline:
    """
    Biomechanical pipeline — "Nova Ideia G4" (PDF) approach:
      Task 1 — Mahony sensor fusion (shank/tibia, MPU0 only) → θ_tibia, ω
      Task 2 — Stride segmentation → ωpico, τst%, αatq per stride
      Task 3 — Return aggregation (STRIDES_PER_RETURN strides) → mean params
      Task 4 — Sliding-window OLS regression (N=4 returns) → trend slopes
      Task 5 — Normalised Trend Index (IT) + 2σ alert criterion

    MPU1 args are accepted for API/hardware compatibility but ignored.
    """

    ACCEL_SCALE = 1.0 / 8192.0          # ±4 g  → g
    GYRO_SCALE  = (np.pi / 180) / 65.5  # ±500 °/s → rad/s

    def __init__(self, sample_rate=100):
        cfg = _load_cfg()
        self.dt = 1.0 / sample_rate

        # Gyro axis for sagittal angular velocity — 0=X 1=Y 2=Z
        self.gyro_axis = int(cfg.get('gyro_axis', 1))

        # Swing detection
        self.SWING_ENTRY_OMEGA = float(cfg.get('swing_entry_omega', 0.35))  # rad/s
        self.SWING_EXIT_RATIO  = 0.7   # hysteresis factor
        self.MIN_SWING_SAMPLES = int(cfg.get('min_swing_samples', 10))

        # Return aggregation
        self.STRIDES_PER_RETURN = int(cfg.get('strides_per_return', 6))
        self.N_WINDOW           = int(cfg.get('n_window', 4))

        # Calibration — collect this many strides during the walk-in
        self.CALIB_STRIDES = int(cfg.get('calib_strides', 40))

        self.f0 = MahonyFilter(dt=self.dt)   # shank (MPU0 0x68)

        # Stride state machine
        self.in_swing       = False
        self.swing_start_ts = None
        self.prev_ic_ts     = None   # timestamp of previous initial contact
        self.omega_buf      = []     # |ω| samples during swing
        self.swing_samples  = 0

        # Calibration state
        self.calibrated    = False
        self.calib_data    = []          # list of (omega_pico_deg, tau_st_pct, theta_ic_rad)
        self.theta_ref     = 0.0         # mean θ at IC during calibration (rad)
        self.baseline_mean = None        # [ωpico, τst%, αatq] means
        self.baseline_std  = None
        self.slope_std     = np.array([1.0, 1.0, 1.0])   # normalisation denominator

        # Return aggregation
        self.return_stride_buf = []   # strides in current return window
        self.returns           = []   # list of mean param vectors [ωpico, τst%, αatq]
        self.return_index      = 0

        self.strides = []

    # ── Public entry point ──────────────────────────────────────────────────

    def process(self, ts,
                ax0, ay0, az0, gx0, gy0, gz0,
                ax1, ay1, az1, gx1, gy1, gz1):
        """
        ts  : timestamp in seconds
        ax* : raw int16 accel LSB
        gx* : raw int16 gyro  LSB
        Returns dict for dashboard.
        """
        a0 = np.array([ax0, ay0, az0], dtype=float) * self.ACCEL_SCALE
        g0 = np.array([gx0, gy0, gz0], dtype=float) * self.GYRO_SCALE

        theta = self.f0.update(*a0, *g0)      # tibia pitch (rad)
        omega = float(g0[self.gyro_axis])     # sagittal ω (rad/s)

        if not self.calibrated:
            stride = self._segment(ts, theta, omega)
            if stride is not None:
                self.calib_data.append(
                    (stride['omega_pico'], stride['tau_st_pct'], stride['_theta_ic_rad'])
                )
                if len(self.calib_data) >= self.CALIB_STRIDES:
                    self._finish_calibration()
            return {
                'type':      'calibrating',
                'progress':  round(len(self.calib_data) / self.CALIB_STRIDES, 2),
                'theta_deg': round(np.degrees(theta), 2),
            }

        stride = self._segment(ts, theta, omega)
        return_result = None
        if stride is not None:
            pub = {k: v for k, v in stride.items() if not k.startswith('_')}
            self.return_stride_buf.append(pub)
            if len(self.return_stride_buf) >= self.STRIDES_PER_RETURN:
                return_result = self._aggregate_return()

        payload = {
            'type':  'live',
            'ts':    round(ts, 3),
            'theta': round(np.degrees(theta), 2),
            'omega': round(np.degrees(omega), 2),
        }
        if stride is not None:
            payload['stride'] = {k: v for k, v in stride.items() if not k.startswith('_')}
        if return_result is not None:
            payload['return'] = return_result

        return payload

    # ── Calibration ─────────────────────────────────────────────────────────

    def _finish_calibration(self):
        data = np.array(self.calib_data)       # (N, 3): [ωpico_deg, τst%, θ_ic_rad]
        self.theta_ref = float(data[:, 2].mean())
        # Recompute αatq relative to theta_ref (≈0 ± noise during calib)
        alpha_atq_cal = np.degrees(data[:, 2] - self.theta_ref)
        params = np.column_stack([data[:, 0], data[:, 1], alpha_atq_cal])  # (N, 3)
        self.baseline_mean = params.mean(axis=0)
        self.baseline_std  = np.maximum(params.std(axis=0), 1e-6)
        self.slope_std     = self.baseline_std.copy()
        self.calibrated    = True

    # ── Task 2 — stride segmentation ────────────────────────────────────────

    def _segment(self, ts, theta, omega):
        """
        STANCE → SWING (toe-off) → STANCE (initial contact) state machine.
        Returns stride dict at each IC, or None.
        """
        exit_thresh = self.SWING_ENTRY_OMEGA * self.SWING_EXIT_RATIO

        if not self.in_swing and abs(omega) > self.SWING_ENTRY_OMEGA:
            # Toe-off: enter swing
            self.in_swing       = True
            self.swing_start_ts = ts
            self.omega_buf      = []
            self.swing_samples  = 0

        if self.in_swing:
            self.omega_buf.append(abs(omega))
            self.swing_samples += 1

            if abs(omega) < exit_thresh and self.swing_samples > self.MIN_SWING_SAMPLES:
                # Initial Contact: exit swing
                omega_pico_deg = float(np.degrees(max(self.omega_buf)))

                swing_time  = ts - self.swing_start_ts
                stride_time = (ts - self.prev_ic_ts) if self.prev_ic_ts is not None else None

                self.in_swing   = False
                self.prev_ic_ts = ts

                if stride_time is None or stride_time < 1e-6:
                    return None

                stance_time = max(stride_time - swing_time, 0.0)
                tau_st_pct  = float(np.clip(stance_time / stride_time * 100.0, 0.0, 100.0))
                alpha_atq   = float(np.degrees(theta - self.theta_ref))

                entry = {
                    'omega_pico':    round(omega_pico_deg, 2),   # deg/s
                    'tau_st_pct':    round(tau_st_pct, 2),        # %
                    'alpha_atq':     round(alpha_atq, 2),          # deg
                    '_theta_ic_rad': theta,                        # internal only
                }
                self.strides.append({k: v for k, v in entry.items() if not k.startswith('_')})
                return entry

        return None

    # ── Task 3 — return aggregation ─────────────────────────────────────────

    def _aggregate_return(self):
        data = np.array([
            (s['omega_pico'], s['tau_st_pct'], s['alpha_atq'])
            for s in self.return_stride_buf
        ])
        mean_vec = data.mean(axis=0)
        self.returns.append(mean_vec)
        self.return_stride_buf = []
        self.return_index += 1

        result = {
            'n':          self.return_index,
            'omega_pico': round(float(mean_vec[0]), 2),
            'tau_st_pct': round(float(mean_vec[1]), 2),
            'alpha_atq':  round(float(mean_vec[2]), 2),
        }
        if len(self.returns) >= 2:
            result.update(self._compute_trend())

        return result

    # ── Task 4+5 — sliding OLS regression + Trend Index ─────────────────────

    def _compute_trend(self):
        window = np.array(self.returns[-self.N_WINDOW:])   # (m, 3)
        m = len(window)
        x = np.arange(m, dtype=float)
        x_bar = x.mean()
        denom  = np.sum((x - x_bar) ** 2) + 1e-12

        slopes = np.array([
            float(np.sum((x - x_bar) * (window[:, i] - window[:, i].mean())) / denom)
            for i in range(3)
        ])

        # Invert so positive always means deterioration:
        #   ωpico ↓ = worse  →  negate
        #   τst%  ↑ = worse  →  keep
        #   αatq  ↓ = worse  →  negate
        signed = np.array([-slopes[0], slopes[1], -slopes[2]])
        norm   = signed / self.slope_std

        IT    = float(norm.mean())
        alert = bool(np.sum(np.abs(norm) > 2.0) >= 2)

        return {
            'IT':          round(IT, 3),
            'norm_slopes': [round(float(v), 3) for v in norm],
            'alert':       alert,
        }
