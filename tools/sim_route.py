"""Offline run of the Cyberslop AV Flight autopilot, version 2 (Autopilot.reds), over the real building heights of
Night City (research\\data\\dav_heights.json = the height map made from Drive an Aerial Vehicle's obstacle map).
  plan    sample the straight line to the pin on the height map (three lines 20 m apart): cruise altitude
  climb   straight up to the cruise altitude, turning towards the pin
  cruise  fly there; the map ahead and the forward radar can raise the altitude and cap the speed
  descend find a flat open spot at the pin and come straight down
The "true" city of the simulation: every known column is solid up to its map height minus 15 m (the map carries a
danger margin above the real surfaces: measured against 105 landing pads, 10 to 50 m); a column the map knows
nothing about is solid up to UNKNOWN_TRUE. The forward radar is run in three variants, because its real range in
the game is not known: 300 m, 60 m, and blind.
Usage: python -I -X utf8 sim_route.py [-v]
"""
import json
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)      # python -I leaves the script folder out of the path
import sim_mission as sm

VERBOSE = '-v' in sys.argv
# Height data made by: python dav_heightmap.py json <file>. Path from AVF_HEIGHTS_JSON or tools/work/.
DATA = json.load(open(os.environ.get('AVF_HEIGHTS_JSON', os.path.join(HERE, 'work', 'dav_heights.json'))))
UNKNOWN_TRUE = 40.0
CLEAR = 15.0            # metres over the map height


def map_at(x, y):
    """Autopilot's knowledge: top of the highest known obstacle, or -1.0."""
    cx, cy = math.floor(x / 10.0), math.floor(y / 10.0)
    ccx, ccy = math.floor(x / 500.0), math.floor(y / 500.0)
    ch = DATA.get('%d,%d' % (ccx, ccy))
    if ch is None:
        return -1.0
    v = ch[(cy - ccy * 50) * 50 + (cx - ccx * 50)]
    if v >= 99 or v < 10:
        return -1.0
    return (v - 10) * 10.0


class City(sm.World):
    def __init__(self, radar_range):
        self.boxes = []
        self.radar_range = radar_range

    def surface(self, x, y):
        h = map_at(x, y)
        if h < 0.0:
            return UNKNOWN_TRUE
        return max(0.0, h - 15.0)

    def ray(self, a, b):
        d = [b[i] - a[i] for i in range(3)]
        length = math.sqrt(sum(c * c for c in d))
        if length < 1e-6:
            return None
        horizontal = abs(d[2]) < 0.5 * length
        limit = min(length, self.radar_range) if horizontal else length
        step = 5.0
        n = int(limit / step)
        for i in range(1, n + 1):
            t = i * step / length
            p = [a[j] + d[j] * t for j in range(3)]
            if p[2] <= self.surface(p[0], p[1]):
                return i * step, p
        if not horizontal:
            # vertical rays: exact ground hit
            if d[2] < 0:
                s = self.surface(a[0], a[1])
                if a[2] + d[2] <= s <= a[2]:
                    return a[2] - s, [a[0], a[1], s]
        return None


class Autopilot2:
    """Autopilot.reds, version 2."""

    def __init__(self, world):
        self.world = world
        self.on = False

    def start(self, dest, pos, fl):
        self.on, self.dest = True, dest
        self.phase = 0
        self.hasSpot, self.spot, self.reason = False, None, ''
        self.scanT, self.clear, self.blocked, self.blockedT = 0.0, 300.0, False, 0.0
        self.spotT, self.spotIdx, self.spotRounds, self.overT, self.phaseT = 0.0, 0, 0, 0.0, 0.0
        self.pinZ = None
        dx, dy = dest[0] - pos[0], dest[1] - pos[1]
        self.dist0 = math.hypot(dx, dy)
        self.ox, self.oy = pos[0], pos[1]
        self.ux, self.uy = (dx / self.dist0, dy / self.dist0) if self.dist0 > 1.0 else (1.0, 0.0)
        self.planI, self.planN = 0, int(self.dist0 / 10.0) + 2
        self.top, self.unknown, self.samples = -1.0, 0, 0
        self.blind = False
        self.cruiseZ = pos[2]
        self.mapT, self.mapLimit = 0.0, 1e9

    def plan(self):
        n = 0
        while self.planI < self.planN and n < 40:
            d = self.planI * 10.0
            for off in (-20.0, 0.0, 20.0):
                h = map_at(self.ox + self.ux * d - self.uy * off, self.oy + self.uy * d + self.ux * off)
                self.samples += 1
                if h < 0.0:
                    self.unknown += 1
                else:
                    self.top = max(self.top, h)
            self.planI += 1
            n += 1
        return self.planI >= self.planN

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
        if fl.aglValid and fl.agl > 12.0:
            lo = [pos[0], pos[1], pos[2] - 8.0]
            best = min(best, self.hit_dist(lo, [lo[0] + fx * ln, lo[1] + fy * ln, lo[2]], ln))
        self.clear, self.blocked = best, best < ln - 0.5

    def map_ahead(self, pos, fx, fy, v, climb):
        """Map columns ahead along the heading: raise the altitude, and the speed that still clears them."""
        la = sm.clamp(v * 6.0 + 80.0, 100.0, 400.0)
        limit = 1e9
        d = 0.0
        while d <= la:
            for off in (-15.0, 0.0, 15.0):
                h = map_at(pos[0] + fx * d - fy * off, pos[1] + fy * d + fx * off)
                if h >= 0.0 and h + CLEAR > pos[2] + 2.0:
                    need = h + CLEAR
                    self.cruiseZ = max(self.cruiseZ, need)
                    limit = min(limit, max(0.0, climb * 0.7 * (d - 30.0) / (need - pos[2])))
            d += 20.0
        self.mapLimit = limit

    def low_alt(self):
        top = -1.0
        for i in range(-2, 3):
            for j in range(-2, 3):
                top = max(top, map_at(self.dest[0] + i * 20.0, self.dest[1] + j * 20.0))
        return None if top < 0.0 else top + 40.0

    def check_spot(self, cx, cy, topZ, rr, nearZ=None):
        gz = self.world.surface(cx, cy)
        if topZ - gz < 3.0:
            return None
        if nearZ is not None and abs(gz - nearZ) > 3.0:
            return None
        for k in range(4):
            ka = k * 1.5708
            if abs(self.world.surface(cx + rr * math.cos(ka), cy + rr * math.sin(ka)) - gz) > 1.0:
                return None
        return [cx, cy, gz]

    def search_spot(self, pos, m):
        rr = max(m['length'], m['width']) * 0.5 + 1.0
        if self.pinZ is None:
            self.pinZ = self.world.surface(self.dest[0], self.dest[1])
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

    def step(self, dt, b, m, fl, cmd, vCruise, restH, vs):
        pos = b.p
        fx, fy = math.cos(b.psi), math.sin(b.psi)
        self.phaseT += dt
        climb, descent = m['climb'] * vs, m['descent'] * vs
        tx, ty = (self.spot[0], self.spot[1]) if self.hasSpot else (self.dest[0], self.dest[1])
        dx, dy = tx - pos[0], ty - pos[1]
        dh = math.hypot(dx, dy)
        self.distLeft = dh
        cmd.update(brakeBoost=False, holdAlt=False, vf=0.0, vl=0.0, yaw=0.0, vz=0.0)
        ang = math.atan2(dx * fy - dy * fx, dx * fx + dy * fy)
        if self.phase == 0:
            cmd['holdAlt'] = True
            if self.plan():
                if self.top < 0.0:
                    self.blind = True
                    self.cruiseZ = max(pos[2], fl.groundZ + 120.0) if fl.aglValid else pos[2] + 60.0
                else:
                    self.blind = self.unknown * 2 > self.samples
                    self.cruiseZ = max(pos[2], self.top + CLEAR)
                    if fl.aglValid:
                        self.cruiseZ = max(self.cruiseZ, fl.groundZ + 60.0)
                self.phase, self.phaseT = 1, 0.0
            return 0
        if self.phase == 1:
            cmd['vz'] = sm.clamp(0.8 * (self.cruiseZ - pos[2]), -descent, climb)
            cmd['yaw'] = sm.clamp(1.5 * ang, -m['yawRate'], m['yawRate']) if dh > 3.0 else 0.0
            if pos[2] >= self.cruiseZ - 3.0:
                self.phase, self.phaseT = 2, 0.0
            elif self.phaseT > 120.0:
                self.reason = 'climb too long'
                return 2
            return 0
        if self.phase == 2:
            self.scanT -= dt
            if self.scanT <= 0.0:
                self.scanT = 0.2
                self.scan(pos, fx, fy, fl, m)
            self.mapT -= dt
            if self.mapT <= 0.0:
                self.mapT = 0.25
                self.map_ahead(pos, fx, fy, fl.vfNow, climb)
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
            cmd['vz'] = sm.clamp(0.8 * (self.cruiseZ - pos[2]), -descent, climb)
            s = min(vCruise, math.sqrt(2.0 * 0.6 * m['brake'] * max(dh - 2.0, 0.0)))
            if self.blocked:      # the radar reports something: stop inside the free distance
                s = min(s, math.sqrt(2.0 * 0.5 * m['brake'] * max(self.clear - 25.0, 0.0)))
            s = min(s, self.mapLimit)
            if self.blind:
                s = min(s, 15.0)
            cmd['vf'] = s * max(0.0, math.cos(ang))
            cmd['yaw'] = sm.clamp(1.5 * ang, -m['yawRate'], m['yawRate']) if dh > 3.0 else 0.0
            if dh < 4.0 and fl.speed < 2.5:
                self.phase, self.phaseT = 4, 0.0
                self.zLow = self.low_alt()
            return 0
        if self.phase == 4:
            # let down over the pin to 40 m over everything within 40 m, look for the spot from there
            cmd['vf'] = sm.clamp(0.6 * (dx * fx + dy * fy), -6.0, 6.0)
            cmd['vl'] = sm.clamp(0.6 * (dx * fy - dy * fx), -6.0, 6.0)
            if self.zLow is None and fl.aglValid:
                self.zLow = fl.groundZ + 60.0
            if self.zLow is None:
                cmd['vz'] = -min(descent, 8.0)
                near = False
            else:
                cmd['vz'] = sm.clamp(0.8 * (self.zLow - pos[2]), -descent, climb)
                near = pos[2] <= self.zLow + 60.0
            if near and not self.hasSpot:
                self.spotT -= dt
                if self.spotT <= 0.0:
                    self.spotT = 0.2
                    self.search_spot(pos, m)
            if self.hasSpot and dh < 4.0 and fl.speed < 2.5:
                self.phase, self.phaseT = 3, 0.0
            elif not self.hasSpot and self.zLow is not None and pos[2] <= self.zLow + 3.0:
                self.overT += dt
                if self.overT > 15.0:
                    self.reason = 'no landing zone'
                    return 2
            if self.phaseT > 300.0:
                self.reason = 'let-down too long'
                return 2
            return 0
        cmd['vf'] = sm.clamp(0.6 * (dx * fx + dy * fy), -3.0, 3.0)
        cmd['vl'] = sm.clamp(0.6 * (dx * fy - dy * fx), -3.0, 3.0)
        h = fl.agl - restH if fl.aglValid else 60.0
        a_lim = 3.5 * (0.5 + 0.5 * vs)
        cmd['vz'] = -max(0.15, min(descent, 0.45 * h, math.sqrt(2.0 * 0.6 * a_lim * max(h, 0.0))))
        if self.phaseT > 300.0:
            self.reason = 'descent too long'
            return 2
        return 0


class Flight2(sm.Flight):
    """Flight.reds Step with the vertical scale of build 9 (acceleration limit and jerk grow with it)."""

    vs = 2.0

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
        vt = sm.clamp(cmd['vf'], -8.3, vmax)
        a = 1.0 * (vt - vf)
        brake = m['brake']
        if a > 0.0:
            lim = m['accel'] * max(0.12, 1.0 - (vf / vmax) ** 2) if vf >= 0.0 else brake
        else:
            lim = brake if vf > 0.0 else m['accel'] * 0.5
        self.aF = sm.approach(self.aF, sm.clamp(a, -lim, lim), 4.0 * dt)
        latMax = m['turnLat'] + 1.5
        aL = sm.clamp(1.5 * (cmd['vl'] - vl) + vf * self.yawCmd, -latMax, latMax)
        self.aL = sm.approach(self.aL, aL, 6.0 * dt)
        k = 0.5 + 0.5 * self.vs
        if cmd['holdAlt']:
            if not self.holding:
                self.zHold = b.p[2] + vz * abs(vz) / (7.0 * k)
                self.holding = True
            vzT = sm.clamp(0.8 * (self.zHold - b.p[2]), -2.5, 2.5)
        else:
            self.holding = False
            vzT = cmd['vz']
        self.aZ = sm.approach(self.aZ, sm.clamp(1.6 * (vzT - vz), -3.5 * k, 3.5 * k), 6.0 * k * dt)
        b.vt = [v[0] + (self.aF * fx + self.aL * rx) * dt, v[1] + (self.aF * fy + self.aL * ry) * dt,
                v[2] + self.aZ * dt]
        b.have_target = True
        spd = max(abs(vf), 1.0)
        yawMax = min(m['yawRate'], m['turnLat'] / spd)
        self.yawCmd = sm.approach(self.yawCmd, sm.clamp(cmd['yaw'], -yawMax, yawMax), 2.0 * dt)
        b.wt = -self.yawCmd


def fly(m, start, start_agl, dest, radar_range, seed, vCruise, vs):
    world = City(radar_range)
    rest = 0.66
    s0 = world.surface(start[0], start[1])
    body = sm.Body(start[0], start[1], s0 + max(start_agl, rest), 0.3, rest, 'true', world)
    fl = Flight2(body, m)
    fl.vs = vs
    fl.engage()
    fl.update_agl(0.0, True)
    ap = Autopilot2(world)
    ap.start(dest, body.p, fl)
    blk = sm.Blocked()
    res = dict(landed=False, reason='', max_z=0.0, min_clear=1e9, top=0.0)
    airT = 0.0
    for t, dt in sm.frames(1500.0, seed):
        airT += dt
        fl.update_agl(dt)
        h = fl.agl - rest if fl.aglValid else 60.0
        cmd = dict()
        if ap.step(dt, body, m, fl, cmd, vCruise, rest, vs) == 2:
            res.update(reason=ap.reason, total=t)
            break
        fl.step(dt, cmd, m['vmax'])
        down = ap.phase == 3
        blk.update(dt, down and h < 3.0, body.p[2])
        if airT > 1.0 and down and (h < 0.04 or body.on_ground and h < 0.15 or blk.t > 0.7) and fl.vzNow > -1.5 \
                and abs(fl.vfNow) < 1.5:
            res.update(landed=True, total=t, pin_miss=math.hypot(body.p[0] - dest[0], body.p[1] - dest[1]),
                       touch=abs(fl.vzNow))
            break
        if ap.phase == 2:
            res['min_clear'] = min(res['min_clear'], body.p[2] - world.surface(body.p[0], body.p[1]))
        res['max_z'] = max(res['max_z'], body.p[2])
        sm.advance(body, dt)
        if body.crashed:
            res.update(crashed=True, total=t, at=(round(body.p[0]), round(body.p[1]), round(body.p[2])), phase=ap.phase)
            break
    res['top'] = ap.top
    res['blind'] = ap.blind
    res['cruise'] = ap.cruiseZ
    return res


def main():
    rng = random.Random(11)
    known = []
    while len(known) < 400:
        x, y = rng.uniform(-2800.0, 1300.0), rng.uniform(-3000.0, 3500.0)
        if map_at(x, y) >= 0.0:
            known.append((x, y))
    routes = [(known[2 * i], known[2 * i + 1]) for i in range(40)]
    # two routes that leave the map (blind mode)
    routes.append(((-2000.0, 500.0), (-3900.0, 300.0)))
    routes.append(((1000.0, -500.0), (2600.0, -900.0)))
    total = bad = 0
    stat = dict(time=[], top=[], clear=[], miss=[])
    for radar in (300.0, 60.0, 0.0):
        for i, (a, b) in enumerate(routes):
            for agl, kmh in ((0.0, 160.0), (80.0, 300.0)):
                r = fly(sm.EXC, a, agl, (b[0], b[1], 0.0), radar, i, kmh / 3.6, 2.0)
                total += 1
                blind_route = i >= 40
                # blind routes: the map cannot help; without a radar there is no promise at all
                ok = (r['landed'] or r['reason'] == 'no landing zone') and not r.get('crashed')
                if blind_route and radar == 0.0:
                    ok = True
                if not ok or VERBOSE:
                    print('radar %3.0f route %2d agl %3.0f (%.0f m): %s %s' % (
                        radar, i, agl, math.hypot(b[0] - a[0], b[1] - a[1]), 'OK' if ok else 'FAIL', r))
                bad += 0 if ok else 1
                if r['landed']:
                    stat['time'].append(r['total'])
                    stat['top'].append(r['max_z'])
                    stat['clear'].append(r['min_clear'])
                    stat['miss'].append(r['pin_miss'])
    n = len(stat['time'])
    print('%d flights over the real height map, %d failed. Landed %d: time %.0f-%.0f s (mean %.0f), top altitude '
          '%.0f-%.0f m, lowest clearance over the true surface in cruise %.0f m, landing %.0f-%.0f m from the pin.' % (
              total, bad, n, min(stat['time']), max(stat['time']), sum(stat['time']) / n, min(stat['top']), max(stat['top']),
              min(stat['clear']), min(stat['miss']), max(stat['miss'])))
    # piloted climb / descent with the vertical speed setting: full climb 6 s, hold, then descend held to touchdown
    for vs in (1.0, 2.0, 3.0):
        r = hop(sm.EXC, vs)
        ok = r['landed'] and r['touch'] < 0.6 and r['drop'] < 0.06 and r['over'] < 4.0
        print('vertical speed %3.0f %%: top %5.1f m after 6 s, climb rate reached %4.1f m/s, sink rate reached %4.1f m/s, '
              'runs %.1f m past the hold height after letting go, touchdown at %.2f m/s, hand-back %.0f cm over rest: %s' % (
                  vs * 100, r['top'], r['vup'], r['vdown'], r['over'], r['touch'], r['drop'] * 100, 'OK' if ok else 'FAIL'))
        bad += 0 if ok else 1
    print('ALL OK' if bad == 0 else 'SOME FAILED')


def hop(m, vs):
    """TickPilot's vertical commands (System.reds build 9) on flat ground."""
    world = sm.World()
    rest = 0.66
    body = sm.Body(0.0, 0.0, rest, 0.0, rest, 'true', world)
    fl = Flight2(body, m)
    fl.vs = vs
    fl.engage()
    blk = sm.Blocked()
    lift, airT = 0.0, 0.0
    res = dict(landed=False, top=0.0, vup=0.0, vdown=0.0, over=0.0, touch=9.0, drop=9.0)
    z_release = None
    for t, dt in sm.frames(200.0, 5):
        airT += dt
        liftT = 1.0 if t < 6.0 else (-1.0 if t > 14.0 else 0.0)
        lift = sm.approach(lift, liftT, 4.0 * dt)
        fl.update_agl(dt)
        h = fl.agl - rest
        cmd = dict(vf=0.0, vl=0.0, yaw=0.0, brakeBoost=False)
        if abs(lift) > 0.05:
            cmd['holdAlt'] = False
            cmd['vz'] = lift * m['climb'] * vs if lift > 0.0 else lift * m['descent'] * vs
            if cmd['vz'] < 0.0:
                a_lim = 3.5 * (0.5 + 0.5 * vs)
                flare = max(0.15, min(m['descent'] * vs, 0.45 * h, math.sqrt(2.0 * 0.6 * a_lim * max(h, 0.0))))
                cmd['vz'] = max(cmd['vz'], -flare)
        else:
            cmd['holdAlt'] = True
            cmd['vz'] = 0.0
            if z_release is None:
                z_release = body.p[2]
        fl.step(dt, cmd, m['vmax'])
        if 6.0 <= t <= 14.0 and fl.holding:
            res['over'] = max(res['over'], body.p[2] - fl.zHold)     # how far it runs past the captured height
        res['vup'] = max(res['vup'], fl.vzNow)
        res['vdown'] = max(res['vdown'], -fl.vzNow)
        if t < 6.0:
            res['top'] = body.p[2] - rest
        blk.update(dt, lift < -0.5 and h < 3.0, body.p[2])
        if airT > 1.0 and lift <= 0.05 and t > 14.0 and (h < 0.04 or body.on_ground and h < 0.15 or blk.t > 0.7) \
                and fl.vzNow > -1.5:
            res.update(landed=True, touch=abs(fl.vzNow), drop=body.p[2] - rest)
            break
        sm.advance(body, dt)
    return res


if __name__ == '__main__':
    main()
