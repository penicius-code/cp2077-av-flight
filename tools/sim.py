"""Offline check of the Cyberslop AV Flight control law (same formulas as Flight.reds).
Point-mass body, no drag (the DLL removes every game force), physics at 60 Hz, controller at the frame rate.
Prints step responses, overshoot, peak jerk and the slow-speed resolution.
Usage: python -I -X utf8 sim.py
"""
import math

G = 9.81
KV, KVL, KVZ, KZ = 1.0, 1.5, 1.6, 0.8
JERK, JERK_Z = 4.0, 6.0
LAT_MAX = 6.5


def approach(cur, tgt, step):
    if tgt > cur:
        return min(tgt, cur + step)
    return max(tgt, cur - step)


def accel_avail(m, vf, vmax):
    return m['accel'] * max(0.12, 1.0 - (vf / vmax) ** 2) if vf >= 0.0 else m['brake']


def fwd_accel(m, vf, vt, vmax):
    a = KV * (vt - vf)
    if a > 0.0:
        lim = accel_avail(m, vf, vmax) if vf >= 0.0 else m['brake']
    else:
        lim = m['brake'] if vf > 0.0 else m['accel'] * 0.5
    return max(-lim, min(lim, a))


def run(m, targets, seconds, fps=60.0, vmax=None, v0=0.0):
    """targets: function(t) -> forward target speed. Returns trace of (t, v, a)."""
    vmax = vmax or m['vmax']
    dt = 1.0 / fps
    v, a_prev, t = v0, 0.0, 0.0
    out = []
    while t < seconds:
        vt = targets(t)
        a = fwd_accel(m, v, vt, vmax)
        a = approach(a_prev, a, JERK * dt)
        # physics: 60 Hz steps with the held command
        v += a * dt
        out.append((t, v, a, vt))
        a_prev = a
        t += dt
    return out


def report(name, tr, vt_final):
    vmax_seen = max(p[1] for p in tr)
    over = (vmax_seen - vt_final) / max(vt_final, 1e-6) * 100.0 if vt_final > 0 else 0.0
    t90 = next((p[0] for p in tr if p[1] >= 0.9 * vt_final), None)
    jerks = [abs(tr[i + 1][2] - tr[i][2]) * 60.0 for i in range(len(tr) - 1)]
    final = tr[-1][1]
    print('%-34s t90 %6s s  overshoot %5.2f %%  peak jerk %4.1f m/s3  final %6.2f m/s (target %6.2f)' % (
        name, '%.1f' % t90 if t90 is not None else '-', over, max(jerks), final, vt_final))


MODELS = {
    'excalibur': dict(vmax=118, accel=4.0, brake=4.8),
    'surveyor': dict(vmax=97, accel=2.5, brake=3.0),
    'valgus': dict(vmax=85, accel=3.0, brake=3.6),
    'nighthunter': dict(vmax=70, accel=2.0, brake=2.5),
}

for key, m in MODELS.items():
    print('==', key)
    report('0 -> top speed', run(m, lambda t: m['vmax'], 120.0), m['vmax'])
    report('0 -> 50 km/h', run(m, lambda t: 50 / 3.6, 30.0), 50 / 3.6)
    report('0 -> 5 km/h (one tap)', run(m, lambda t: 5 / 3.6, 15.0), 5 / 3.6)
    tr = run(m, lambda t: 0.0, 60.0, v0=m['vmax'])
    stop = next((p[0] for p in tr if p[1] <= 0.3), None)
    print('%-34s %.1f s, min speed %.2f (no reverse overshoot)' % ('top speed -> stop', stop, min(p[1] for p in tr)))

# keyboard lever: hold W for 4 s then release; the target ramps at 0.9 x available accel
print('== keyboard lever, Excalibur: hold W 4 s, release')
m = MODELS['excalibur']
state = {'vset': 0.0}


def lever(t, dt=1.0 / 60.0):
    if t < 4.0:
        state['vset'] = min(m['vmax'], state['vset'] + max(2.0, 0.9 * accel_avail(m, state['vset'], m['vmax'])) * dt)
    return state['vset']


tr = run(m, lever, 12.0)
for p in tr[::60]:
    print('  t %4.1f  target %6.2f  speed %6.2f  accel %5.2f' % (p[0], p[3], p[1], p[2]))

# yaw rate limit at speed (coordinated turn)
print('== yaw-rate limit, Excalibur (hover 45 deg/s, lateral 5.66 m/s2)')
for v in (0, 5, 10, 20, 40, 60, 90, 118):
    w = min(math.radians(45), G * math.tan(math.radians(30)) / max(abs(v), 1.0))
    bank = math.degrees(math.atan(v * w / G))
    print('  %5.1f m/s (%4d km/h): %5.1f deg/s, bank %4.1f deg, turn radius %6.0f m' % (
        v, round(v * 3.6), math.degrees(w), bank, v / w if w > 0 else 0))
