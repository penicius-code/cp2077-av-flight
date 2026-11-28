// Cyberslop AV Flight 1.0.0 - autopilot: flies the piloted aircraft to the tracked map pin and lands there.
// It only writes speed commands (AVFCmd) for the same flight controller the pilot uses.
//   plan     the straight line to the pin is sampled on the building-height map (HeightMap.reds, made from Drive
//            an Aerial Vehicle's obstacle map): three lines 20 m apart, every 10 m. Cruise altitude = the highest
//            thing on that line + 15 m.
//   climb    straight up to that altitude, turning towards the pin.
//   cruise   flies there over everything. Two safety nets: the map columns ahead of the nose (they can raise the
//            altitude and cap the speed to what still clears them) and a forward radar of four 300 m rays.
//            Where the map knows nothing (outside the city) it flies "blind": radar only, 54 km/h at most.
//   let-down over the pin it sinks to 40 m over everything within 40 m (map) and looks for a flat, open spot from
//            there (the charter arrival's test), first at the height of the surface under the pin.
//   descent  it moves over the spot and comes straight down. The system's touchdown test ends it.
//   fetch    build 19 (double tap of the call key): the system gives the spot at V's feet and the heading (door side
//            towards V). Cruise = known buildings on the way + 15 m and at least 25 m over the spot (no 60 m rule),
//            no let-down search: straight down over the spot, turning to the heading, not under 8 m before it is
//            turned (the hull must not sweep over V).
// Same logic as tools\sim_route.py, which flies it over the real height map with the radar at 300 m, 60 m and off.
// Version 1 (build 8) had only the radar and flew into buildings in game: the rays did not report them in time.
module CyberslopAVFlight

// The building-height map, one 500 m chunk cached at a time.
public class AVFHeights extends IScriptable {
  private let m_has: Bool;
  private let m_cx: Int32;
  private let m_cy: Int32;
  private let m_chunk: String;

  // Top of the highest known obstacle in the 10 m column at (x, y), metres above sea level. -1 = nothing known.
  public func At(x: Float, y: Float) -> Float {
    let ccx: Int32 = FloorF(x / 500.0);
    let ccy: Int32 = FloorF(y / 500.0);
    if !this.m_has || ccx != this.m_cx || ccy != this.m_cy {
      this.m_chunk = AVFHeightData.Chunk(ccx, ccy);
      this.m_cx = ccx;
      this.m_cy = ccy;
      this.m_has = true;
    };
    if StrLen(this.m_chunk) < 5000 {
      return -1.0;
    };
    let idx: Int32 = (FloorF(y / 10.0) - ccy * 50) * 50 + (FloorF(x / 10.0) - ccx * 50);
    if idx < 0 || idx >= 2500 {
      return -1.0;
    };
    let v: Int32 = StringToInt(StrMid(this.m_chunk, idx * 2, 2));
    if v < 10 || v >= 99 {
      return -1.0;
    };
    return Cast<Float>(v - 10) * 10.0;
  }
}

public class AVFAutopilot extends IScriptable {
  private let m_gi: GameInstance;
  private let m_map: ref<AVFHeights>;
  public let on: Bool;
  public let phase: Int32;         // 0 plan, 1 climb, 2 cruise, 3 descent onto the spot
  public let dest: Vector4;
  public let spot: Vector4;
  public let hasSpot: Bool;
  public let cruiseZ: Float;
  public let distLeft: Float;
  public let blind: Bool;          // the map knows too little about this route
  public let top: Float;           // highest map column on the route (-1 = none known)
  public let reason: String;       // why control went back to the pilot (Step returned 2)
  public let note: String;         // one line for the log when a phase starts ("" = nothing new)
  // plan
  private let m_ox: Float;
  private let m_oy: Float;
  private let m_ux: Float;
  private let m_uy: Float;
  private let m_planI: Int32;
  private let m_planN: Int32;
  private let m_unknown: Int32;
  private let m_samples: Int32;
  // cruise
  private let m_scanT: Float;
  private let m_clear: Float;      // free distance ahead at the last radar scan
  private let m_blocked: Bool;
  private let m_blockedT: Float;
  private let m_radarLogged: Bool;
  private let m_mapT: Float;
  private let m_mapLimit: Float;   // speed that still clears the map columns ahead
  // landing spot
  private let m_spotT: Float;
  private let m_spotIdx: Int32;
  private let m_spotRounds: Int32;
  private let m_pinZ: Float;       // height of the surface under the pin
  private let m_pinZKnown: Bool;
  private let m_overT: Float;      // seconds over the pin without a landing spot
  private let m_zLow: Float;       // let-down altitude over the pin
  private let m_zLowKnown: Bool;
  private let m_phaseT: Float;
  // build 19: fetch (fixed spot and landing heading)
  private let m_fetch: Bool;
  private let m_hx: Float;
  private let m_hy: Float;

  public func Init(gi: GameInstance) -> Void {
    this.m_gi = gi;
    this.m_map = new AVFHeights();
  }

  public func Start(dest: Vector4, pos: Vector4, fl: ref<AVFFlight>) -> Void {
    this.on = true;
    this.phase = 0;
    this.dest = dest;
    this.hasSpot = false;
    this.reason = "";
    this.note = "";
    this.blind = false;
    this.top = -1.0;
    let dx: Float = dest.X - pos.X;
    let dy: Float = dest.Y - pos.Y;
    this.distLeft = SqrtF(dx * dx + dy * dy);
    this.m_ox = pos.X;
    this.m_oy = pos.Y;
    if this.distLeft > 1.0 {
      this.m_ux = dx / this.distLeft;
      this.m_uy = dy / this.distLeft;
    } else {
      this.m_ux = 1.0;
      this.m_uy = 0.0;
    };
    this.m_planI = 0;
    this.m_planN = FloorF(this.distLeft / 10.0) + 2;
    this.m_unknown = 0;
    this.m_samples = 0;
    this.m_scanT = 0.0;
    this.m_clear = 300.0;
    this.m_blocked = false;
    this.m_blockedT = 0.0;
    this.m_radarLogged = false;
    this.m_mapT = 0.0;
    this.m_mapLimit = 1000.0;
    this.m_spotT = 0.0;
    this.m_spotIdx = 0;
    this.m_spotRounds = 0;
    this.m_pinZKnown = false;
    this.m_overT = 0.0;
    this.m_zLowKnown = false;
    this.m_phaseT = 0.0;
    this.cruiseZ = pos.Z;
    this.m_fetch = false;
  }

  // Build 19: fly to the spot the system found at V's feet and land there with heading fwd.
  public func StartFetch(spot: Vector4, fwd: Vector4, pos: Vector4, fl: ref<AVFFlight>) -> Void {
    this.Start(spot, pos, fl);
    this.spot = spot;
    this.hasSpot = true;
    this.m_fetch = true;
    this.m_hx = fwd.X;
    this.m_hy = fwd.Y;
  }

  public func Stop() -> Void {
    this.on = false;
  }

  public func Descending() -> Bool {
    return this.on && this.phase == 3;
  }

  // 40 samples of the route per call (three map columns each). True when the whole line is done.
  private func Plan() -> Bool {
    let n: Int32 = 0;
    while this.m_planI < this.m_planN && n < 40 {
      let d: Float = Cast<Float>(this.m_planI) * 10.0;
      let k: Int32 = -1;
      while k <= 1 {
        let off: Float = Cast<Float>(k) * 20.0;
        let h: Float = this.m_map.At(this.m_ox + this.m_ux * d - this.m_uy * off, this.m_oy + this.m_uy * d + this.m_ux * off);
        this.m_samples += 1;
        if h < 0.0 {
          this.m_unknown += 1;
        } else {
          this.top = MaxF(this.top, h);
        };
        k += 1;
      };
      this.m_planI += 1;
      n += 1;
    };
    return this.m_planI >= this.m_planN;
  }

  private func Ray(from: Vector4, to: Vector4, out hit: TraceResult) -> Bool {
    return GameInstance.GetSpatialQueriesSystem(this.m_gi).SyncRaycastByCollisionPreset(from, to, n"World Static", hit, true, false) && TraceResult.IsValid(hit);
  }

  private func HitDist(from: Vector4, to: Vector4, max: Float) -> Float {
    let hit: TraceResult;
    if !this.Ray(from, to, hit) {
      return max;
    };
    let dx: Float = hit.position.X - from.X;
    let dy: Float = hit.position.Y - from.Y;
    let dz: Float = hit.position.Z - from.Z;
    return MinF(max, SqrtF(dx * dx + dy * dy + dz * dz));
  }

  // Forward radar, 300 m along the heading: centre line, both hull sides, and a line 8 m under the hull.
  private func Scan(pos: Vector4, fx: Float, fy: Float, fl: ref<AVFFlight>, m: ref<AVFModel>) -> Void {
    let len: Float = 300.0;
    let rx: Float = fy;
    let ry: Float = -fx;
    let half: Float = m.width * 0.5 + 1.5;
    let z: Float = pos.Z + 1.0;
    let c: Vector4 = new Vector4(pos.X, pos.Y, z, 1.0);
    let best: Float = this.HitDist(c, new Vector4(pos.X + fx * len, pos.Y + fy * len, z, 1.0), len);
    let l: Vector4 = new Vector4(pos.X - rx * half, pos.Y - ry * half, z, 1.0);
    best = MinF(best, this.HitDist(l, new Vector4(l.X + fx * len, l.Y + fy * len, z, 1.0), len));
    let r: Vector4 = new Vector4(pos.X + rx * half, pos.Y + ry * half, z, 1.0);
    best = MinF(best, this.HitDist(r, new Vector4(r.X + fx * len, r.Y + fy * len, z, 1.0), len));
    if fl.aglValid && fl.agl > 12.0 {
      let lo: Vector4 = new Vector4(pos.X, pos.Y, pos.Z - 8.0, 1.0);
      best = MinF(best, this.HitDist(lo, new Vector4(lo.X + fx * len, lo.Y + fy * len, lo.Z, 1.0), len));
    };
    this.m_clear = best;
    this.m_blocked = best < len - 0.5;
    if this.m_blocked && !this.m_radarLogged {
      // once per flight: at which range the radar first reports something (its real range is not known)
      this.m_radarLogged = true;
      this.note = "autopilot radar: first contact at " + FloatToStringPrec(best, 0) + " m, altitude " + FloatToStringPrec(pos.Z, 0);
    };
  }

  // Map columns ahead of the nose (three lines 15 m apart, every 20 m): anything not cleared yet raises the
  // cruise altitude, and the speed is capped to what the climb rate still clears it with.
  private func MapAhead(pos: Vector4, fx: Float, fy: Float, v: Float, climb: Float) -> Void {
    let la: Float = ClampF(v * 6.0 + 80.0, 100.0, 400.0);
    let limit: Float = 1000.0;
    let d: Float = 0.0;
    while d <= la {
      let k: Int32 = -1;
      while k <= 1 {
        let off: Float = Cast<Float>(k) * 15.0;
        let h: Float = this.m_map.At(pos.X + fx * d - fy * off, pos.Y + fy * d + fx * off);
        if h >= 0.0 && h + 15.0 > pos.Z + 2.0 {
          let need: Float = h + 15.0;
          this.cruiseZ = MaxF(this.cruiseZ, need);
          limit = MinF(limit, MaxF(0.0, climb * 0.7 * (d - 30.0) / (need - pos.Z)));
        };
        k += 1;
      };
      d += 20.0;
    };
    this.m_mapLimit = limit;
  }

  // Let-down altitude over the pin: 40 m over the highest map column within 40 m of it.
  private func LowAlt() -> Void {
    let top: Float = -1.0;
    let i: Int32 = -2;
    while i <= 2 {
      let j: Int32 = -2;
      while j <= 2 {
        top = MaxF(top, this.m_map.At(this.dest.X + Cast<Float>(i) * 20.0, this.dest.Y + Cast<Float>(j) * 20.0));
        j += 1;
      };
      i += 1;
    };
    this.m_zLowKnown = top >= 0.0;
    this.m_zLow = top + 40.0;
  }

  // Height of the surface straight under a point, seen from topZ.
  private func SurfaceZ(x: Float, y: Float, topZ: Float, out z: Float) -> Bool {
    let hit: TraceResult;
    if !this.Ray(new Vector4(x, y, topZ, 1.0), new Vector4(x, y, topZ - 400.0, 1.0), hit) {
      return false;
    };
    z = hit.position.Z;
    return true;
  }

  // A flat, open spot with a clear footprint and open sky above (the charter arrival's test).
  // useNear: only a surface within 3 m of nearZ counts.
  private func CheckSpot(cx: Float, cy: Float, topZ: Float, rr: Float, nearZ: Float, useNear: Bool, out spot: Vector4) -> Bool {
    let hit: TraceResult;
    if !this.Ray(new Vector4(cx, cy, topZ, 1.0), new Vector4(cx, cy, topZ - 400.0, 1.0), hit) {
      return false;
    };
    let gz: Float = hit.position.Z;
    if hit.normal.Z < 0.94 || topZ - gz < 3.0 {
      return false;
    };
    if useNear && AbsF(gz - nearZ) > 3.0 {
      return false;
    };
    let sky: TraceResult;
    if this.Ray(new Vector4(cx, cy, gz + 1.0, 1.0), new Vector4(cx, cy, gz + 120.0, 1.0), sky) {
      return false;
    };
    let k: Int32 = 0;
    while k < 4 {
      let ka: Float = Cast<Float>(k) * 1.5708;
      let x: Float = cx + rr * CosF(ka);
      let y: Float = cy + rr * SinF(ka);
      let h2: TraceResult;
      if !this.Ray(new Vector4(x, y, gz + 8.0, 1.0), new Vector4(x, y, gz - 4.0, 1.0), h2) || AbsF(h2.position.Z - gz) > 1.0 {
        return false;
      };
      k += 1;
    };
    spot = new Vector4(cx, cy, gz, 1.0);
    return true;
  }

  // 25 candidates around the pin (the pin itself, then rings of 12, 24 and 40 m), five per call.
  // First round: only at the height of the surface under the pin (a street pin does not end on a roof next to
  // it). Later rounds: any flat, open surface.
  private func SearchSpot(pos: Vector4, m: ref<AVFModel>) -> Void {
    let rr: Float = MaxF(m.length, m.width) * 0.5 + 1.0;
    if !this.m_pinZKnown {
      let pz: Float;
      if this.SurfaceZ(this.dest.X, this.dest.Y, pos.Z + 2.0, pz) {
        this.m_pinZ = pz;
        this.m_pinZKnown = true;
      };
    };
    let n: Int32 = 0;
    while n < 5 && !this.hasSpot {
      let i: Int32 = this.m_spotIdx;
      let cx: Float = this.dest.X;
      let cy: Float = this.dest.Y;
      if i > 0 {
        let ring: Int32 = (i - 1) / 8;
        let a: Float = Cast<Float>((i - 1) % 8) * 0.7854;
        let rad: Float = ring == 0 ? 12.0 : (ring == 1 ? 24.0 : 40.0);
        cx += rad * CosF(a);
        cy += rad * SinF(a);
      };
      let s: Vector4;
      if this.CheckSpot(cx, cy, pos.Z + 2.0, rr, this.m_pinZ, this.m_pinZKnown && this.m_spotRounds == 0, s) {
        this.spot = s;
        this.hasSpot = true;
      };
      this.m_spotIdx += 1;
      if this.m_spotIdx >= 25 {
        this.m_spotIdx = 0;
        this.m_spotRounds += 1;
      };
      n += 1;
    };
  }

  // Fills cmd. Returns 0 while flying, 2 when control goes back to the pilot (see reason).
  // vs = vertical speed scale (Mod Settings). Landing itself is the system's touchdown test while Descending().
  public func Step(dt: Float, veh: ref<VehicleObject>, m: ref<AVFModel>, fl: ref<AVFFlight>, cmd: ref<AVFCmd>, vCruise: Float, restH: Float, vs: Float) -> Int32 {
    let pos: Vector4 = veh.GetWorldPosition();
    let fwd: Vector4 = veh.GetWorldForward();
    let fl2: Float = MaxF(SqrtF(fwd.X * fwd.X + fwd.Y * fwd.Y), 0.05);
    let fx: Float = fwd.X / fl2;
    let fy: Float = fwd.Y / fl2;
    let climb: Float = m.climb * vs;
    let descent: Float = m.descent * vs;
    this.m_phaseT += dt;
    this.note = "";
    let tx: Float = this.hasSpot ? this.spot.X : this.dest.X;
    let ty: Float = this.hasSpot ? this.spot.Y : this.dest.Y;
    let dx: Float = tx - pos.X;
    let dy: Float = ty - pos.Y;
    let dh: Float = SqrtF(dx * dx + dy * dy);
    this.distLeft = dh;
    let ang: Float = AtanF(dx * fy - dy * fx, dx * fx + dy * fy);
    cmd.brakeBoost = false;
    cmd.holdAlt = false;
    cmd.vf = 0.0;
    cmd.vl = 0.0;
    cmd.yaw = 0.0;
    cmd.vz = 0.0;
    if this.phase == 0 {
      // a few ticks: read the route off the map, hold still meanwhile
      cmd.holdAlt = true;
      if this.Plan() {
        if this.top < 0.0 {
          this.blind = true;
          this.cruiseZ = fl.aglValid ? MaxF(pos.Z, fl.groundZ + 120.0) : pos.Z + 60.0;
        } else {
          this.blind = this.m_unknown * 2 > this.m_samples;
          this.cruiseZ = MaxF(pos.Z, this.top + 15.0);
          if this.m_fetch {
            // build 19: a hop to V: over what the map knows + 15 m and 25 m over the spot (radar and map stay on)
            this.cruiseZ = MaxF(this.cruiseZ, this.spot.Z + 25.0);
          } else {
            if fl.aglValid {
              this.cruiseZ = MaxF(this.cruiseZ, fl.groundZ + 60.0);
            };
          };
        };
        this.phase = 1;
        this.m_phaseT = 0.0;
        this.note = "autopilot route: " + FloatToStringPrec(this.distLeft, 0) + " m, highest on the map " + FloatToStringPrec(this.top, 0) + " m, " + IntToString(this.m_unknown) + " of " + IntToString(this.m_samples) + " columns unknown" + (this.blind ? " (BLIND: radar only, slow)" : "") + ", cruise altitude " + FloatToStringPrec(this.cruiseZ, 0) + " m, now at " + FloatToStringPrec(pos.Z, 0);
      };
      return 0;
    };
    if this.phase == 1 {
      // straight up, turning towards the pin
      cmd.vz = ClampF(0.8 * (this.cruiseZ - pos.Z), -descent, climb);
      cmd.yaw = dh > 3.0 ? ClampF(1.5 * ang, -m.yawRate, m.yawRate) : 0.0;
      if pos.Z >= this.cruiseZ - 3.0 {
        this.phase = 2;
        this.m_phaseT = 0.0;
      } else {
        if this.m_phaseT > 120.0 {
          this.reason = "Autopilot: could not reach the cruise altitude. Holding here.";
          return 2;
        };
      };
      return 0;
    };
    if this.phase == 2 {
      this.m_scanT -= dt;
      if this.m_scanT <= 0.0 {
        this.m_scanT = 0.2;
        this.Scan(pos, fx, fy, fl, m);
      };
      this.m_mapT -= dt;
      if this.m_mapT <= 0.0 {
        this.m_mapT = 0.25;
        this.MapAhead(pos, fx, fy, fl.vfNow, climb);
      };
      // never under 40 m over the ground below (build 19: 25 m on a hop to V); 20 m higher for as long as the radar
      // sees something ahead
      let minAgl: Float = this.m_fetch ? 25.0 : 40.0;
      if fl.aglValid && fl.agl < minAgl - 10.0 {
        this.cruiseZ = MaxF(this.cruiseZ, fl.groundZ + minAgl);
      };
      if this.m_blocked {
        this.cruiseZ = MaxF(this.cruiseZ, pos.Z + 20.0);
        this.m_blockedT += dt;
      } else {
        this.m_blockedT = 0.0;
      };
      if this.m_blockedT > 90.0 {
        this.reason = "Autopilot: no way over the obstacle ahead. Holding here.";
        return 2;
      };
      cmd.vz = ClampF(0.8 * (this.cruiseZ - pos.Z), -descent, climb);
      let s: Float = MinF(vCruise, SqrtF(2.0 * 0.6 * m.brake * MaxF(dh - 2.0, 0.0)));
      // the radar reports something: stop inside the free distance (half the brake, 25 m to spare) ...
      if this.m_blocked {
        s = MinF(s, SqrtF(2.0 * 0.5 * m.brake * MaxF(this.m_clear - 25.0, 0.0)));
      };
      // ... and never faster than it can climb over what the map shows ahead
      s = MinF(s, this.m_mapLimit);
      if this.blind {
        s = MinF(s, 15.0);
      };
      cmd.vf = s * MaxF(0.0, CosF(ang));
      cmd.yaw = dh > 3.0 ? ClampF(1.5 * ang, -m.yawRate, m.yawRate) : 0.0;
      if dh < 4.0 && fl.speed < 2.5 {
        if this.m_fetch {
          // build 19: spot and heading are known: straight down from here
          this.phase = 3;
          this.m_phaseT = 0.0;
          this.note = "fetch: over the spot at " + FloatToStringPrec(pos.Z, 0) + " m, coming down to " + FloatToStringPrec(this.spot.Z, 0) + " m";
        } else {
          this.phase = 4;
          this.m_phaseT = 0.0;
          this.LowAlt();
          this.note = "autopilot over the pin at " + FloatToStringPrec(pos.Z, 0) + " m, letting down to " + (this.m_zLowKnown ? FloatToStringPrec(this.m_zLow, 0) + " m" : "radar-altimeter range");
        };
      };
      return 0;
    };
    if this.phase == 4 {
      // let down over the pin to 40 m over everything within 40 m, and look for the landing spot from there:
      // every ray of the search is then short
      cmd.vf = ClampF(0.6 * (dx * fx + dy * fy), -6.0, 6.0);
      cmd.vl = ClampF(0.6 * (dx * fy - dy * fx), -6.0, 6.0);
      if !this.m_zLowKnown && fl.aglValid {
        this.m_zLow = fl.groundZ + 60.0;
        this.m_zLowKnown = true;
      };
      let near: Bool = false;
      if !this.m_zLowKnown {
        cmd.vz = -MinF(descent, 8.0);
      } else {
        cmd.vz = ClampF(0.8 * (this.m_zLow - pos.Z), -descent, climb);
        near = pos.Z <= this.m_zLow + 60.0;
      };
      if near && !this.hasSpot {
        this.m_spotT -= dt;
        if this.m_spotT <= 0.0 {
          this.m_spotT = 0.2;
          this.SearchSpot(pos, m);
          if this.hasSpot {
            this.note = "autopilot landing spot: surface at " + FloatToStringPrec(this.spot.Z, 0) + " m, " + FloatToStringPrec(SqrtF((this.spot.X - this.dest.X) * (this.spot.X - this.dest.X) + (this.spot.Y - this.dest.Y) * (this.spot.Y - this.dest.Y)), 0) + " m from the pin, search round " + IntToString(this.m_spotRounds + 1);
          };
        };
      };
      if this.hasSpot && dh < 4.0 && fl.speed < 2.5 {
        this.phase = 3;
        this.m_phaseT = 0.0;
      } else {
        if !this.hasSpot && this.m_zLowKnown && pos.Z <= this.m_zLow + 3.0 {
          this.m_overT += dt;
          if this.m_overT > 15.0 {
            this.reason = "Autopilot: no clear landing zone at the pin. Holding here.";
            return 2;
          };
        };
      };
      if this.m_phaseT > 300.0 {
        this.reason = "Autopilot: the let-down took too long. Holding here.";
        return 2;
      };
      return 0;
    };
    // straight down onto the spot, holding position over it
    cmd.vf = ClampF(0.6 * (dx * fx + dy * fy), -3.0, 3.0);
    cmd.vl = ClampF(0.6 * (dx * fy - dy * fx), -3.0, 3.0);
    let h: Float = fl.aglValid ? fl.agl - restH : 60.0;
    cmd.vz = -AVFFlight.Flare(h, descent, vs);
    if this.m_fetch {
      // build 19: turn to the landing heading (door side towards V) on the way down; not under 8 m before that
      let herr: Float = AtanF(this.m_hx * fy - this.m_hy * fx, this.m_hx * fx + this.m_hy * fy);
      cmd.yaw = ClampF(1.5 * herr, -m.yawRate, m.yawRate);
      if AbsF(herr) > 0.14 && h < 8.0 {
        cmd.vz = ClampF(0.8 * (8.0 - h), 0.0, 2.0);
      };
    };
    if this.m_phaseT > 300.0 {
      this.reason = "Autopilot: the descent took too long. Holding here.";
      return 2;
    };
    return 0;
  }
}
