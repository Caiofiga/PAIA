import 'dart:math' as math;

class MahonyFilter {
  final double kp;
  final double ki;
  final double dt;

  List<double> q    = [1.0, 0.0, 0.0, 0.0];
  List<double> eInt = [0.0, 0.0, 0.0];

  MahonyFilter({this.kp = 10.0, this.ki = 0.01, this.dt = 0.01});

  double update(double ax, double ay, double az,
                double gx, double gy, double gz) {
    final norm = math.sqrt(ax*ax + ay*ay + az*az);
    if (norm < 1e-6) return _pitch();
    ax /= norm; ay /= norm; az /= norm;

    final vx = 2*(q[1]*q[3] - q[0]*q[2]);
    final vy = 2*(q[0]*q[1] + q[2]*q[3]);
    final vz = q[0]*q[0] - q[1]*q[1] - q[2]*q[2] + q[3]*q[3];

    final ex = ay*vz - az*vy;
    final ey = az*vx - ax*vz;
    final ez = ax*vy - ay*vx;

    eInt[0] += ex * ki * dt;
    eInt[1] += ey * ki * dt;
    eInt[2] += ez * ki * dt;

    gx += kp*ex + eInt[0];
    gy += kp*ey + eInt[1];
    gz += kp*ez + eInt[2];

    final qa = q[0], qb = q[1], qc = q[2], qd = q[3];
    q[0] += 0.5*dt*(-qb*gx - qc*gy - qd*gz);
    q[1] += 0.5*dt*( qa*gx + qc*gz - qd*gy);
    q[2] += 0.5*dt*( qa*gy - qb*gz + qd*gx);
    q[3] += 0.5*dt*( qa*gz + qb*gy - qc*gx);

    final qn = math.sqrt(q[0]*q[0]+q[1]*q[1]+q[2]*q[2]+q[3]*q[3]);
    for (int i = 0; i < 4; i++) q[i] /= qn;
    return _pitch();
  }

  double _pitch() {
    final val = (2*(q[0]*q[2] - q[3]*q[1])).clamp(-1.0, 1.0);
    return math.asin(val);
  }

  void reset() {
    q    = [1.0, 0.0, 0.0, 0.0];
    eInt = [0.0, 0.0, 0.0];
  }
}
