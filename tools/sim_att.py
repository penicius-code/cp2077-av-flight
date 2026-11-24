"""Offline check of the attitude controller + axis calibration of Flight.reds against a rigid body.
The 'engine' stores angular velocity in one of four conventions (world/body axes, right-handed or mirrored);
the DLL torque law torque = (w_target - w_now) * gain runs in that convention at 60 Hz. The controller only sees
the entity vectors and GetAngularVelocity, exactly like the redscript. Checks: calibration picks the truth,
the hull levels from a 20 deg tilt, a right-turn command turns the heading clockwise, banking is right-side down.
Usage: python -I -X utf8 sim_att.py
"""
import math
import sys

# --mode2: the DLL writes the angular-velocity target straight into the body (mode 2) instead of the torque law.
# --inertia X: real inertia = X times the box estimate (the 2026-11-22 16:02 tumble: far smaller than assumed).
MODE2 = '--mode2' in sys.argv
ISCALE = float(sys.argv[sys.argv.index('--inertia') + 1]) if '--inertia' in sys.argv else 1.0


def add(a, b): return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
def sub(a, b): return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
def mul(a, s): return [a[0] * s, a[1] * s, a[2] * s]
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def cross(a, b): return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
def norm(a):
    l = math.sqrt(dot(a, a))
    return mul(a, 1.0 / l)


def rot(v, axis, ang):
    # Rodrigues, right-handed
    k = norm(axis)
    c, s = math.cos(ang), math.sin(ang)
    return add(add(mul(v, c), mul(cross(k, v), s)), mul(k, dot(k, v) * (1 - c)))


class Body:
    """Orientation as right/forward/up world vectors, true world angular velocity w (right-handed)."""
    def __init__(self, tilt_deg, heading_deg):
        self.r, self.f, self.u = [1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]
        h = math.radians(heading_deg)
        for name in ('r', 'f', 'u'):
            setattr(self, name, rot(getattr(self, name), [0, 0, 1], h))
        t = math.radians(tilt_deg)
        axis = add(self.r, self.f)  # tilt about a diagonal: pitch + roll error
        for name in ('r', 'f', 'u'):
            setattr(self, name, rot(getattr(self, name), axis, t))
        self.w = [0.0, 0.0, 0.0]
        # box inertia (body axes x right, y forward, z up), 10.5 x 3.8 x 2.5 m, per kg
        L, W, H = 10.5, 3.8, 2.5
        self.I = [ISCALE * (L * L + H * H) / 12.0, ISCALE * (W * W + H * H) / 12.0, ISCALE * (L * L + W * W) / 12.0]

    def to_body(self, v): return [dot(v, self.r), dot(v, self.f), dot(v, self.u)]
    def to_world(self, b): return add(add(mul(self.r, b[0]), mul(self.f, b[1])), mul(self.u, b[2]))

    def engine_w(self, conv):
        local, sign = conv
        v = self.to_body(self.w) if local else self.w
        return mul(v, sign)

    def step(self, conv, target_engine, gain, dt):
        local, sign = conv
        if MODE2:
            t = mul(target_engine, sign)
            self.w = self.to_world(t) if local else t
            ang = math.sqrt(dot(self.w, self.w)) * dt
            if ang > 1e-9:
                for name in ('r', 'f', 'u'):
                    setattr(self, name, rot(getattr(self, name), self.w, ang))
            return
        torque_engine = mul(sub(target_engine, self.engine_w(conv)), gain)
        # engine convention -> true world torque
        t = mul(torque_engine, sign)
        t_world = self.to_world(t) if local else t
        # angular acceleration in body frame (diagonal inertia), back to world
        tb = self.to_body(t_world)
        ab = [tb[0] / self.I[0], tb[1] / self.I[1], tb[2] / self.I[2]]
        self.w = add(self.w, mul(self.to_world(ab), dt))
        ang = math.sqrt(dot(self.w, self.w)) * dt
        if ang > 1e-9:
            for name in ('r', 'f', 'u'):
                setattr(self, name, rot(getattr(self, name), self.w, ang))


class Controller:
    def __init__(self):
        self.sigma, self.local, self.locked = 1.0, False, False
        self.err = [0.0] * 4
        self.n = 0
        self.prev = None
        self.yaw = 0.0

    def target(self, b, yaw_cmd, bank, pitch):
        fl = math.hypot(b.f[0], b.f[1])
        fx, fy = b.f[0] / fl, b.f[1] / fl
        rx, ry = fy, -fx
        tb, tp = math.tan(bank), math.tan(pitch)
        ud = norm([tb * rx + tp * fx, tb * ry + tp * fy, 1.0])
        e = cross(b.u, ud)
        w = [max(-1.5, min(1.5, 4.0 * e[0])), max(-1.5, min(1.5, 4.0 * e[1])), max(-1.5, min(1.5, 4.0 * e[2])) - yaw_cmd]
        if self.local:
            w = [dot(w, b.r), dot(w, b.f), dot(w, b.u)]
        return mul(w, self.sigma)

    def calibrate(self, b, w3, dt):
        if self.locked:
            return
        if self.prev is None:
            self.prev = (b.u[:], b.f[:])
            return
        up, fp = self.prev
        if math.sqrt(dot(w3, w3)) > 0.08:
            du, df = sub(b.u, up), sub(b.f, fp)
            bw = add(add(mul(b.r, w3[0]), mul(b.f, w3[1])), mul(b.u, w3[2]))
            for c in range(4):
                s = -1.0 if c in (1, 3) else 1.0
                o = mul(w3, s) if c < 2 else mul(bw, s)
                eu = sub(du, mul(cross(o, up), dt))
                ef = sub(df, mul(cross(o, fp), dt))
                self.err[c] += dot(eu, eu) + dot(ef, ef)
            self.n += 1
        self.prev = (b.u[:], b.f[:])
        if self.n < 25:
            return
        if not getattr(self, 'sign_locked', False):
            plus, minus = min(self.err[0], self.err[2]), min(self.err[1], self.err[3])
            if plus < 0.4 * minus or minus < 0.4 * plus:
                self.sigma = -1.0 if minus < plus else 1.0
                self.sign_locked = True
                self.sign_at = self.n
            return
        ew = self.err[0] if self.sigma > 0 else self.err[1]
        eb = self.err[2] if self.sigma > 0 else self.err[3]
        if eb < 0.4 * ew or ew < 0.4 * eb:
            self.local = eb < ew
            self.locked = True


def tilt_deg(b):
    return math.degrees(math.acos(max(-1, min(1, b.u[2]))))


def heading(b):
    return math.degrees(math.atan2(b.f[1], b.f[0]))


CONVS = {'world, right-handed': (False, 1.0), 'world, mirrored': (False, -1.0),
         'body, right-handed': (True, 1.0), 'body, mirrored': (True, -1.0)}

dt = 1.0 / 60.0
gain = (10.5 ** 2 + 3.8 ** 2) / 12.0 / 0.3   # gainPerKg of the Excalibur (mass cancels: inertia is per kg here)
ok_all = True
for name, conv in CONVS.items():
    for head in (0.0, 37.0, 90.0, 200.0):
        b = Body(20.0, head)
        c = Controller()
        t = 0.0
        tilt_max = 0.0
        locked_at = None
        h0 = heading(b)
        # 3 s leveling, then 3 s right turn at 0.4 rad/s with 15 deg bank
        while t < 6.0:
            yaw_cmd = 0.4 if t >= 3.0 else 0.0
            bank = math.radians(15.0) if t >= 3.0 else 0.0
            w3 = b.engine_w(conv)
            c.calibrate(b, w3, dt)
            if c.locked and locked_at is None:
                locked_at = t
            tgt = c.target(b, yaw_cmd, bank, 0.0)
            b.step(conv, tgt, gain, dt)
            t += dt
            if t > 1.5 and t < 3.0:
                tilt_max = max(tilt_max, tilt_deg(b))
            if abs(t - 3.0) < dt / 2:
                h_turn0 = heading(b)
        dh = (heading(b) - h_turn0 + 540.0) % 360.0 - 180.0
        # bank sign: right wing down = up vector leans towards the right side of the heading
        fl = math.hypot(b.f[0], b.f[1])
        rx, ry = b.f[1] / fl, -b.f[0] / fl
        lean_right = b.u[0] * rx + b.u[1] * ry
        right_conv = (c.local == conv[0]) and (c.sigma == conv[1])
        ok = right_conv and tilt_max < 20.0 and dh < -40.0 and lean_right > 0.15
        ok_all &= ok
        print('%-20s heading %5.0f: picked %-5s %s (at %.2f s), tilt 1.5-3 s max %4.1f deg (from 20), '
              'right turn 3 s: heading %+6.1f deg, bank lean %+.2f  %s' % (
                  name, head, 'body' if c.local else 'world', 'R' if c.sigma > 0 else 'M',
                  locked_at if locked_at is not None else -1, tilt_max, dh, lean_right, 'OK' if ok else 'FAIL'))

# level start: only yaw happens for the first 4 s (right turn, no bank), then a 15 deg bank appears.
# The sign must lock from the yaw alone, and a right turn must already go clockwise after the lock.
print('-- level start, yaw only')
for name, conv in CONVS.items():
    b = Body(0.0, 37.0)
    c = Controller()
    t, h_lock, sign_t = 0.0, None, None
    while t < 8.0:
        bank = math.radians(15.0) if t >= 4.0 else 0.0
        w3 = b.engine_w(conv)
        c.calibrate(b, w3, dt)
        if getattr(c, 'sign_locked', False) and sign_t is None:
            sign_t, h_lock = t, heading(b)
        b.step(conv, c.target(b, 0.4, bank, 0.0), gain, dt)
        t += dt
    dh = (heading(b) - h_lock + 540.0) % 360.0 - 180.0 if h_lock is not None else 0.0
    ok = sign_t is not None and c.sigma == conv[1] and dh < -60.0 and (c.locked and c.local == conv[0])
    ok_all &= ok
    print('%-20s sign locked at %s s (%s), heading after the lock %+6.1f deg, axes %s  %s' % (
        name, '%.2f' % sign_t if sign_t is not None else '-', 'R' if c.sigma > 0 else 'M', dh,
        ('body' if c.local else 'world') if c.locked else 'undecided', 'OK' if ok else 'FAIL'))
print('ALL OK' if ok_all else 'SOME FAILED')
