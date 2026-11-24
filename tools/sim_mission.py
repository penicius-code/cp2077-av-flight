"""Offline run of the Cyberslop AV Flight mission logic on top of the Flight.reds Step law
(linear channels + yaw; attitude is covered by sim_att.py). Ports of:
  System.reds  AutoArrive, TickPilot touchdown, BlockedDescent
  Autopilot.reds  Step, Scan, CheckSpot, SearchSpot
DLL mode 2: the script writes a velocity target = measured velocity + commanded acceleration * dt, the DLL writes
it into the body on every physics step (60 Hz). World: flat ground plus boxes (buildings). The body rests with its
origin `rest_true` over the surface below it; the script only knows `rest_agl`.
GetVelocity is run in both readings: 'true' (the body's velocity after collisions) and 'written' (the value the
hook wrote last).
Usage: python -I -X utf8 sim_mission.py [-v]
"""
import math
import random
import sys

VERBOSE = '-v' in sys.argv
EXC = dict(name='Excalibur', vmax=118.0, accel=4.0, brake=4.8, climb=10.0, descent=7.0, yawRate=0.7854,
           turnLat=5.6638, length=10.5, width=3.8)
NH = dict(name='Night Hunter', vmax=70.0, accel=2.0, brake=2.5, climb=6.0, descent=5.0, yawRate=0.6,
          turnLat=4.0, length=9.0, width=4.5)


def clamp(x, lo, hi):
    return max(lo, min(hi, x))


def approach(cur, tgt, step):
    return min(tgt, cur + step) if tgt > cur else max(tgt, cur - step)


class World:
    """Flat ground at z = 0 and axis-aligned boxes (x0, x1, y0, y1, height)."""

    def __init__(self, boxes=()):
        self.boxes = list(boxes)

    def surface(self, x, y):
        s = 0.0
        for x0, x1, y0, y1, h in self.boxes:
            if x0 <= x <= x1 and y0 <= y <= y1:
                s = max(s, h)
        return s

    def ray(self, a, b):
        """Distance from a to the first hit on the way to b, or None. Also returns the hit point."""
        d = [b[i] - a[i] for i in range(3)]
        length = math.sqrt(sum(c * c for c in d))
        if length < 1e-9:
            return None
        best = None
        if d[2] < 0.0 and a[2] > 0.0:               # ground plane
            t = -a[2] / d[2]
            if 0.0 <= t <= 1.0:
                best = t
        for x0, x1, y0, y1, h in self.boxes:
            lo, hi = (x0, y0, 0.0), (x1, y1, h)
            t0, t1 = 0.0, 1.0
            ok = True
            for i in range(3):
                if abs(d[i]) < 1e-12:
                    if a[i] < lo[i] or a[i] > hi[i]:
                        ok = False
                        break
                else:
                    ta, tb = (lo[i] - a[i]) / d[i], (hi[i] - a[i]) / d[i]
                    if ta > tb:
                        ta, tb = tb, ta
                    t0, t1 = max(t0, ta), min(t1, tb)
                    if t0 > t1:
                        ok = False
                        break
            if ok and (best is None or t0 < best):
                best = t0
        if best is None:
            return None
        return best * length, [a[i] + d[i] * best for i in range(3)]


FLAT = World()


class Body:
    def __init__(self, x, y, z, psi, rest_true, meas, world=FLAT):
        self.p = [x, y, z]
        self.v = [0.0, 0.0, 0.0]
        self.vt = [0.0, 0.0, 0.0]     # held velocity target (mode 2)
        self.have_target = False
        self.psi, self.w, self.wt = psi, 0.0, 0.0
        self.rest, self.meas, self.world = rest_true, meas, world
        self.on_ground = False
        self.engaged = False
        self.crashed = False

    def measured(self):
        return list(self.vt) if (self.meas == 'written' and self.have_target) else list(self.v)

    def physics(self, dt):
        if self.engaged:
            if self.have_target:
                self.v = list(self.vt)
                self.w = self.wt
        else:
            self.v[2] -= 9.81 * dt
            self.v[0] *= 0.9
            self.v[1] *= 0.9
            self.w = 0.0
        s_before = self.world.surface(self.p[0], self.p[1])
        for i in range(3):
            self.p[i] += self.v[i] * dt
        self.psi += self.w * dt
        s = self.world.surface(self.p[0], self.p[1])
        if s > s_before + 1.0 and self.p[2] < s + self.rest - 0.5:
            self.crashed = True                    # flew into the side of a building
        self.on_ground = False
        if self.p[2] <= s + self.rest:
            self.p[2] = s + self.rest
            if self.v[2] < 0.0:
                self.v[2] = 0.0
            self.on_ground = True


class Flight:
    """Flight.reds Step, linear + yaw, mode 2 output."""

    def __init__(self, body, m):
        self.b, self.m = body, m
        self.aF = self.aL = self.aZ = self.yawCmd = 0.0
        self.zHold, self.holding = body.p[2], False
        self.agl, self.agl_t, self.groundZ, self.aglValid = 0.0, 0.0, 0.0, True
        self.vfNow = self.vzNow = self.speed = 0.0

    def engage(self):
        self.b.engaged = True
        self.b.have_target = False
        self.aF = self.aL = self.aZ = self.yawCmd = 0.0
        self.holding = False
        self.zHold = self.b.p[2]

    def disengage(self):
        self.b.engaged = False
        self.b.have_target = False

    def update_agl(self, dt, force=False):
        self.agl_t -= dt
        if force or self.agl_t <= 0.0:
            self.agl_t = 0.0 if self.agl < 4.0 else 0.1
            s = self.b.world.surface(self.b.p[0], self.b.p[1])
            self.aglValid = self.b.p[2] - s <= 150.0
            self.groundZ = s
            self.agl = self.b.p[2] - s if self.aglValid else 150.0

    def step(self, dt, cmd, vmax):
        b, m = self.b, self.m
        v = b.measured()
        fx, fy = math.cos(b.psi), math.sin(b.psi)
        rx, ry = fy, -fx
        vf = v[0] * fx + v[1] * fy
        vl = v[0] * rx + v[1] * ry
        vz = v[2]
        self.vfNow, self.vzNow = vf, vz
        self.speed = math.sqrt(sum(c * c for c in v))
        vt = clamp(cmd['vf'], -8.3, vmax)
        a = 1.0 * (vt - vf)
        brake = m['brake'] * 1.6 if cmd.get('brakeBoost') else m['brake']
        if a > 0.0:
            lim = m['accel'] * max(0.12, 1.0 - (vf / vmax) ** 2) if vf >= 0.0 else brake
        else:
            lim = brake if vf > 0.0 else m['accel'] * 0.5
        self.aF = approach(self.aF, clamp(a, -lim, lim), 4.0 * dt)
        latMax = m['turnLat'] + 1.5
        aL = clamp(1.5 * (cmd['vl'] - vl) + vf * self.yawCmd, -latMax, latMax)
        self.aL = approach(self.aL, aL, 6.0 * dt)
        if cmd['holdAlt']:
            if not self.holding:
                self.zHold = b.p[2] + vz * abs(vz) / 7.0
                self.holding = True
            vzT = clamp(0.8 * (self.zHold - b.p[2]), -2.5, 2.5)
        else:
            self.holding = False
            vzT = cmd['vz']
        self.aZ = approach(self.aZ, clamp(1.6 * (vzT - vz), -3.5, 3.5), 6.0 * dt)
        b.vt = [v[0] + (self.aF * fx + self.aL * rx) * dt, v[1] + (self.aF * fy + self.aL * ry) * dt,
                v[2] + self.aZ * dt]
        b.have_target = True
        spd = max(abs(vf), 1.0)
        yawMax = min(m['yawRate'], m['turnLat'] / spd)
        self.yawCmd = approach(self.yawCmd, clamp(cmd['yaw'], -yawMax, yawMax), 2.0 * dt)
        b.wt = -self.yawCmd       # right turn = clockwise seen from above


class Blocked:
    """System.reds BlockedDescent: sinking asked, height not 5 cm lower for T seconds."""

    def __init__(self):
        self.on, self.z, self.t = False, 0.0, 0.0

    def update(self, dt, active, z):
        if not active:
            self.on, self.t = False, 0.0
            return
        if not self.on or self.z - z > 0.05:
            self.on, self.z, self.t = True, z, 0.0
            return
        self.t += dt


class Autopilot:
    """Autopilot.reds."""

    def __init__(self, world):
        self.world = world
        self.on = False

    def start(self, dest, pos, fl):
        self.on, self.phase, self.dest = True, 1, dest
        self.hasSpot, self.spot, self.reason = False, None, ''
        self.scanT, self.clear, self.blocked, self.blockedT = 0.0, 400.0, False, 0.0
        self.spotT, self.spotIdx, self.spotRounds, self.overT, self.phaseT = 0.0, 0, 0, 0.0, 0.0
        self.pinZ = None
        self.cruiseZ = max(pos[2], fl.groundZ + 120.0) if fl.aglValid else pos[2]

    def hit_dist(self, a, b, mx):
        r = self.world.ray(a, b)
        return mx if r is None else min(mx, r[0])

    def scan(self, pos, fx, fy, fl, m):
        ln = 300.0
        rx, ry = fy, -fx
        half = m['width'] * 0.5 + 1.5
        z = pos[2] + 1.0
        c = [pos[0], pos[1], z]
        best = self.hit_dist(c, [pos[0] + fx * ln, pos[1] + fy * ln, z], ln)
        for sgn in (-1.0, 1.0):
            s = [pos[0] + sgn * rx * half, pos[1] + sgn * ry * half, z]
            best = min(best, self.hit_dist(s, [s[0] + fx * ln, s[1] + fy * ln, z], ln))
        if fl.aglValid and fl.agl > 12.0:      # 8 m under the hull: keeps that much room over roofs
            lo = [pos[0], pos[1], pos[2] - 8.0]
            best = min(best, self.hit_dist(lo, [lo[0] + fx * ln, lo[1] + fy * ln, lo[2]], ln))
        self.clear, self.blocked = best, best < ln - 0.5
        return ln

    def check_spot(self, cx, cy, topZ, rr, nearZ=None):
        r = self.world.ray([cx, cy, topZ], [cx, cy, topZ - 700.0])
        if r is None:
            return None
        gz = r[1][2]
        if abs(self.world.surface(cx, cy) - gz) > 0.01 or topZ - gz < 3.0:   # side hit = not flat
            return None
        if nearZ is not None and abs(gz - nearZ) > 3.0:
            return None
        if self.world.ray([cx, cy, gz + 1.0], [cx, cy, gz + 120.0]) is not None:
            return None
        for k in range(4):
            ka = k * 1.5708
            x, y = cx + rr * math.cos(ka), cy + rr * math.sin(ka)
            h2 = self.world.ray([x, y, gz + 8.0], [x, y, gz - 4.0])
            if h2 is None or abs(h2[1][2] - gz) > 1.0:
                return None
        return [cx, cy, gz]

    def search_spot(self, pos, m):
        rr = max(m['length'], m['width']) * 0.5 + 1.0
        if self.pinZ is None:
            r = self.world.ray([self.dest[0], self.dest[1], pos[2] + 2.0], [self.dest[0], self.dest[1], pos[2] - 698.0])
            if r is not None:
                self.pinZ = r[1][2]
        n = 0
        while n < 5 and not self.hasSpot:
            i = self.spotIdx
            cx, cy = self.dest[0], self.dest[1]
            if i > 0:
                ring = (i - 1) // 8
                a = ((i - 1) % 8) * 0.7854
                rad = 12.0 if ring == 0 else (24.0 if ring == 1 else 40.0)
                cx += rad * math.cos(a)
                cy += rad * math.sin(a)
            s = self.check_spot(cx, cy, pos[2] + 2.0, rr, self.pinZ if self.spotRounds == 0 else None)
            if s is not None:
                self.spot, self.hasSpot = s, True
            self.spotIdx += 1
            if self.spotIdx >= 25:
                self.spotIdx = 0
                self.spotRounds += 1
            n += 1

    def step(self, dt, b, m, fl, cmd, vCruise, restH):
        pos = b.p
        fx, fy = math.cos(b.psi), math.sin(b.psi)
        self.phaseT += dt
        tx, ty = (self.spot[0], self.spot[1]) if self.hasSpot else (self.dest[0], self.dest[1])
        dx, dy = tx - pos[0], ty - pos[1]
        dh = math.hypot(dx, dy)
        self.distLeft = dh
        cmd.update(brakeBoost=False, holdAlt=False)
        if self.phase == 1:
            self.scanT -= dt
            if self.scanT <= 0.0:
                self.scanT = 0.1
                self.scan(pos, fx, fy, fl, m)
            if not self.hasSpot and dh < 220.0:
                self.spotT -= dt
                if self.spotT <= 0.0:
                    self.spotT = 0.2
                    self.search_spot(pos, m)
            if fl.aglValid and fl.agl < 30.0:
                self.cruiseZ = max(self.cruiseZ, fl.groundZ + 40.0)
            if self.blocked:
                self.cruiseZ = max(self.cruiseZ, pos[2] + 20.0)
                self.blockedT += dt
            else:
                self.blockedT = 0.0
            if self.blockedT > 90.0:
                self.reason = 'no way over'
                return 2
            cmd['vz'] = clamp(0.5 * (self.cruiseZ - pos[2]), -m['descent'], m['climb'])
            ang = math.atan2(dx * fy - dy * fx, dx * fx + dy * fy)
            s = min(vCruise, math.sqrt(2.0 * 0.6 * m['brake'] * max(dh - 2.0, 0.0)))
            # never faster than it can stop inside what the radar sees (half the brake, 25 m to spare)
            s = min(s, math.sqrt(2.0 * 0.5 * m['brake'] * max(self.clear - 25.0, 0.0)))
            if fl.aglValid and fl.agl < 15.0:
                s = min(s, 5.0)                 # still low after a take-off: creep
            cmd['vf'] = s * max(0.0, math.cos(ang))
            cmd['vl'] = 0.0
            cmd['yaw'] = clamp(1.5 * ang, -m['yawRate'], m['yawRate']) if dh > 3.0 else 0.0
            if dh < 4.0 and fl.speed < 2.5:
                if self.hasSpot:
                    self.phase, self.phaseT = 2, 0.0
                else:
                    self.overT += dt
                    if self.overT > 12.0:
                        self.reason = 'no landing zone'
                        return 2
            return 0
        cmd['vf'] = clamp(0.6 * (dx * fx + dy * fy), -3.0, 3.0)
        cmd['vl'] = clamp(0.6 * (dx * fy - dy * fx), -3.0, 3.0)
        cmd['yaw'] = 0.0
        h = fl.agl - restH if fl.aglValid else 50.0
        cmd['vz'] = -max(0.15, min(m['descent'], 0.45 * h))
        if self.phaseT > 240.0:
            self.reason = 'descent too long'
            return 2
        return 0


def frames(seconds, seed):
    """Controller ticks: DelayCallback(0.016) fires on the first frame after the delay, frames of 8-20 ms."""
    rng = random.Random(seed)
    t = 0.0
    while t < seconds:
        dt = 0.0
        while dt < 0.016:
            dt += rng.uniform(0.008, 0.020)
        t += dt
        yield t, dt


def advance(body, dt):
    n = max(1, int(round(dt * 60.0)))
    for _ in range(n):
        body.physics(dt / n)


def arrival(m, bearing, start_h, rest_true, rest_agl, ground_flag, seed, meas):
    target = (0.0, 0.0, 35.0)
    sx, sy = 180.0 * math.cos(bearing), 180.0 * math.sin(bearing)
    body = Body(sx, sy, start_h, math.atan2(-sy, -sx), rest_true, meas)
    fl = Flight(body, m)
    fl.engage()
    vmax = m['vmax']
    glideZ0, glideD0 = start_h, 180.0
    phase, phaseT = 0, 0.0
    blk = Blocked()
    res = dict(landed=False, line_gap=1e9)
    for t, dt in frames(200.0, seed):
        pos = body.p
        fx, fy = math.cos(body.psi), math.sin(body.psi)
        phaseT += dt
        fl.update_agl(dt)
        cmd = dict(brakeBoost=False)
        if phase == 0:
            dx, dy = target[0] - pos[0], target[1] - pos[1]
            dh = math.hypot(dx, dy)
            ang = math.atan2(dx * fy - dy * fx, dx * fx + dy * fy)
            s = min(min(40.0, vmax * 0.5), math.sqrt(2.0 * 0.6 * m['brake'] * max(dh - 2.0, 0.0)))
            cmd.update(vf=s * max(0.0, math.cos(ang)), vl=0.0, yaw=clamp(1.5 * ang, -m['yawRate'], m['yawRate']),
                       holdAlt=False)
            zLine = target[2] + (glideZ0 - target[2]) * clamp(dh / glideD0, 0.0, 1.0)
            cmd['vz'] = clamp(0.8 * (zLine - pos[2]), -m['descent'], m['climb'] * 0.6)
            res['line_gap'] = min(res['line_gap'], pos[2] - zLine)
            if dh < 4.0 and fl.speed < 2.5 or phaseT > 90.0:
                res['phase0_timeout'] = phaseT > 90.0
                phase, phaseT = 1, 0.0
        else:
            ex, ey = -pos[0], -pos[1]
            cmd.update(vf=clamp(0.6 * (ex * fx + ey * fy), -3.0, 3.0), vl=clamp(0.6 * (ex * fy - ey * fx), -3.0, 3.0),
                       yaw=0.0, holdAlt=False)
            h = fl.agl - rest_agl
            cmd['vz'] = -max(0.15, min(m['descent'] * 0.7, 0.45 * h))
            blk.update(dt, h < 3.0, pos[2])
            if phaseT > 60.0 and h > 3.0:
                res.update(aborted=True)
                break
            if phaseT > 1.0 and (h < 0.04 or (ground_flag and body.on_ground) and h < 0.15 or blk.t > 0.7) or phaseT > 60.0:
                res.update(landed=True, descent_s=phaseT, timeout=phaseT > 60.0, miss=math.hypot(pos[0], pos[1]),
                           total=t, touch_v=abs(fl.vzNow), drop=pos[2] - rest_true)
                break
        fl.step(dt, cmd, vmax)
        advance(body, dt)
    return res


def pilot_hop(m, rest_true, rest_agl, margin, ground_flag, seed, meas):
    body = Body(0.0, 0.0, rest_true, 0.0, rest_true, meas)
    fl = Flight(body, m)
    vmax = m['vmax']
    airborne, airT, takeoffT, lift, vset = False, 0.0, 0.0, 0.0, 0.0
    blk = Blocked()
    res = dict(took_off=None, landed=None, max_h=0.0, max_v=0.0, hold_err=0.0, drop=0.0)
    for t, dt in frames(120.0, seed):
        liftT = (1.0 if t < 3.5 else 0.0) - (1.0 if t > 22.0 else 0.0)
        lift = approach(lift, liftT, 4.0 * dt)
        if 6.0 < t < 12.0:
            vset = min(vmax, vset + max(1.5, 0.8 * m['accel']) * dt)      # W held
        if t > 14.0:
            vset = max(0.0, vset - max(2.0, 0.8 * m['brake']) * dt)        # S held to zero
        if not airborne:
            if res['landed'] is not None:
                break
            takeoffT = takeoffT + dt if lift > 0.5 else 0.0
            if takeoffT > 0.25:
                fl.engage()
                airborne, airT, vset = True, 0.0, 0.0
                res['took_off'] = t
            advance(body, dt)
            continue
        airT += dt
        fl.update_agl(dt)
        h = fl.agl - rest_agl
        cmd = dict(vf=vset, vl=0.0, yaw=0.0, brakeBoost=False)
        if abs(lift) > 0.05:
            cmd['holdAlt'] = False
            cmd['vz'] = lift * m['climb'] if lift > 0.0 else lift * m['descent']
            if cmd['vz'] < 0.0:
                cmd['vz'] = max(cmd['vz'], -max(0.15, 0.45 * h))
        else:
            cmd['holdAlt'] = True
            cmd['vz'] = 0.0
        fl.step(dt, cmd, vmax)
        blk.update(dt, lift < -0.5 and h < 3.0, body.p[2])
        if 16.0 < t < 21.0:
            res['hold_err'] = max(res['hold_err'], abs(body.p[2] - fl.zHold))
        if airT > 1.0 and lift <= 0.05 and (h < margin or (ground_flag and body.on_ground) and h < 0.15 or blk.t > 0.7) \
                and fl.vzNow > -1.5 and abs(fl.vfNow) < 1.5:
            fl.disengage()
            airborne = False
            res['landed'] = t
            res['drop'] = body.p[2] - rest_true
            res['touch_v'] = abs(fl.vzNow)
        res['max_h'] = max(res['max_h'], body.p[2] - rest_true)
        res['max_v'] = max(res['max_v'], fl.vfNow)
        advance(body, dt)
    return res


CITY = World([
    (300.0, 380.0, -100.0, 300.0, 150.0),      # slab across the direct line
    (700.0, 900.0, 0.0, 400.0, 320.0),         # tower block
    (1100.0, 1200.0, 50.0, 250.0, 60.0),       # low roofs
    (1440.0, 1560.0, 140.0, 260.0, 45.0),      # a roof under one of the pins
    (1990.0, 2004.0, -40.0, 40.0, 30.0),       # a wall right next to another pin
])


def autopilot_run(m, start, start_agl, dest, meas, seed, vCruise, from_ground=False):
    rest = 0.66
    world = CITY
    s0 = world.surface(start[0], start[1])
    z0 = s0 + rest if from_ground else s0 + start_agl
    body = Body(start[0], start[1], z0, 0.3, rest, meas, world)
    fl = Flight(body, m)
    fl.engage()
    fl.update_agl(0.0, True)
    ap = Autopilot(world)
    ap.start(dest, body.p, fl)
    blk = Blocked()
    res = dict(landed=False, reason='', min_agl=1e9, max_z=0.0)
    airT = 0.0
    for t, dt in frames(900.0, seed):
        airT += dt
        fl.update_agl(dt)
        h = fl.agl - rest if fl.aglValid else 50.0
        cmd = dict(vf=0.0, vl=0.0, yaw=0.0, holdAlt=True, vz=0.0, brakeBoost=False)
        if ap.step(dt, body, m, fl, cmd, vCruise, rest) == 2:
            res['reason'] = ap.reason
            res['total'] = t
            break
        fl.step(dt, cmd, m['vmax'])
        down = ap.phase == 2
        blk.update(dt, down and h < 3.0, body.p[2])
        if airT > 1.0 and down and (h < 0.04 or body.on_ground and h < 0.15 or blk.t > 0.7) and fl.vzNow > -1.5 \
                and abs(fl.vfNow) < 1.5:
            sp = ap.spot
            res.update(landed=True, total=t, miss=math.hypot(body.p[0] - sp[0], body.p[1] - sp[1]),
                       pin_miss=math.hypot(body.p[0] - dest[0], body.p[1] - dest[1]), surface=sp[2],
                       drop=body.p[2] - (world.surface(body.p[0], body.p[1]) + rest))
            break
        if ap.phase == 1 and t > 12.0:
            res['min_agl'] = min(res['min_agl'], body.p[2] - world.surface(body.p[0], body.p[1]))
        res['max_z'] = max(res['max_z'], body.p[2])
        advance(body, dt)
        if body.crashed:
            res['crashed'] = True
            res['total'] = t
            break
    return res


def main():
    bad = n = 0
    worst = dict(total=0.0, touch=0.0, miss=0.0, gap=0.0, hold=0.0, drop=0.0)
    for meas in ('true', 'written'):
        for rest_true in (0.3, 0.6, 0.66, 0.9, 1.5):
            for flag in (True, False):
                for seed, (b, h0) in enumerate([(0.0, 80.0), (2.1, 120.0), (-1.0, 160.0)]):
                    r = arrival(EXC, b, h0, rest_true, 0.6, flag, seed, meas)
                    n += 1
                    ok = r['landed'] and not r.get('timeout') and not r.get('phase0_timeout') and r['miss'] < 2.0
                    if ok:
                        worst['total'] = max(worst['total'], r['total'])
                        worst['touch'] = max(worst['touch'], r['touch_v'])
                        worst['miss'] = max(worst['miss'], r['miss'])
                        worst['gap'] = max(worst['gap'], -r['line_gap'])
                        if abs(rest_true - 0.6) < 0.1:
                            worst['drop'] = max(worst['drop'], r['drop'])
                    if not ok or VERBOSE:
                        print('arrival %-7s rest %.2f flag %-5s bearing %.1f: %s %s' % (meas, rest_true, flag, b, 'OK' if ok else 'FAIL', r))
                    bad += 0 if ok else 1
        for m, margin in ((EXC, 0.04), (NH, 0.3)):
            for rest_true, rest_agl in ((0.66, 0.66), (0.6, 0.6), (1.2, 0.6), (0.3, 0.6), (2.2, 2.2), (2.6, 2.2)):
                for flag in (True, False):
                    r = pilot_hop(m, rest_true, rest_agl, margin, flag, 7, meas)
                    n += 1
                    ok = r['took_off'] is not None and r['landed'] is not None and r['max_h'] > 5.0 and r['max_v'] > 5.0
                    worst['hold'] = max(worst['hold'], r['hold_err'])
                    if ok and m is EXC and abs(rest_true - rest_agl) < 0.01:
                        worst['drop'] = max(worst['drop'], r['drop'])
                    if not ok or VERBOSE:
                        print('hop %-7s %-12s rest %.2f/%.2f flag %-5s: %s %s' % (meas, m['name'], rest_true, rest_agl, flag, 'OK' if ok else 'FAIL', r))
                    bad += 0 if ok else 1
    print('%d arrival / hop cases, %d failed. Arrival: longest %.1f s, touchdown speed up to %.2f m/s, largest miss %.2f m, '
          'deepest under the glide line %.1f m. Hop: altitude-hold error up to %.2f m. Hand-back height over the resting '
          'height (known rest): up to %.2f m.' % (n, bad, worst['total'], worst['touch'], worst['miss'], worst['gap'],
                                                 worst['hold'], worst['drop']))

    # autopilot: over the city blocks to pins on the ground, on a roof and next to a wall
    apn = apbad = 0
    cases = [
        ('street pin behind two blocks', (0.0, 100.0), 30.0, (1700.0, 60.0, 0.0), False),
        ('same, from the ground', (0.0, 100.0), 0.0, (1700.0, 60.0, 0.0), True),
        ('pin on a 45 m roof', (0.0, 100.0), 60.0, (1500.0, 200.0, 0.0), False),
        ('pin next to a 30 m wall', (0.0, 0.0), 30.0, (1985.0, 0.0, 0.0), False),
        ('short hop, 60 m', (0.0, 100.0), 15.0, (60.0, 100.0, 0.0), False),
        ('pin behind us', (0.0, 100.0), 80.0, (-600.0, -300.0, 0.0), False),
    ]
    for meas in ('true', 'written'):
        for vc in (160.0 / 3.6, 300.0 / 3.6):
            for name, start, agl, dest, ground in cases:
                r = autopilot_run(EXC, start, agl, dest, meas, 3, vc, ground)
                apn += 1
                ok = r['landed'] and not r.get('crashed') and r['miss'] < 2.5 and r['pin_miss'] < 45.0 and r['drop'] < 0.1
                if not ok or VERBOSE:
                    print('autopilot %-7s %3.0f km/h %-28s: %s %s' % (meas, vc * 3.6, name, 'OK' if ok else 'FAIL', r))
                apbad += 0 if ok else 1
                if ok and meas == 'true' and abs(vc - 160.0 / 3.6) < 0.1:
                    print('  autopilot %-30s %5.0f s, landed %4.1f m from the pin on a surface at %3.0f m, top altitude %3.0f m, '
                          'lowest clearance in cruise %3.0f m' % (name, r['total'], r['pin_miss'], r['surface'], r['max_z'], r['min_agl']))
    print('%d autopilot cases, %d failed.' % (apn, apbad))
    print('ALL OK' if bad + apbad == 0 else 'SOME FAILED')


if __name__ == '__main__':
    main()
