// Cyberslop AV Flight 1.0.0 - flight controller ("translational rate command", fly-by-wire).
// Every control asks for a speed: forward / sideways speed, vertical speed (or altitude hold) and yaw rate.
// The controller turns that into a net acceleration inside the aircraft's limits (tapering towards top speed,
// jerk-limited) and an angular-velocity target (yaw rate + leveling to a bank / pitch that follows the real
// accelerations), and hands both to DriveAerialVehicle.dll mode 1, which applies them on every physics step.
// Same formulas as tools\sim.py.
module CyberslopAVFlight

public class AVFCmd {
  public let vf: Float;        // forward speed target, m/s (negative = reverse)
  public let vl: Float;        // sideways speed target, m/s (positive = right)
  public let vz: Float;        // vertical speed target, m/s (used when holdAlt is false)
  public let holdAlt: Bool;    // hold the captured altitude instead
  public let yaw: Float;       // yaw rate target, rad/s (positive = right turn)
  public let brakeBoost: Bool; // hover brake: stronger deceleration
}

public class AVFFlight extends IScriptable {
  private let m_gi: GameInstance;
  public let fly: ref<FlyAVSystem>;
  // RULE: every FlyAVSystem call is its own assignment statement (`x = this.fly.F(...);`).
  // - DriveAerialVehicle.dll writes every return value through the out pointer without a null check
  //   (crash 2026-11-22, DLL+0xaf9d): a discarded result is a null write.
  // - Its zero-parameter natives do not skip ParamEnd. The VM runs the leftover as a no-op, which is only
  //   harmless when the call is the whole right-hand side: as an operand or argument it desyncs the bytecode.
  private let m_r: Float;
  public let veh: wref<VehicleObject>;
  public let vehID: EntityID;
  public let model: ref<AVFModel>;
  public let bound: Bool;
  public let engaged: Bool;        // game physics off, controller flying
  public let mass: Float;
  public let gainFactor: Float;
  private let m_sigma: Float;
  private let m_frameLocal: Bool;
  private let m_calLocked: Bool;
  private let m_signLocked: Bool;
  public let tumbleT: Float;       // seconds of uncontrolled spin (watchdog)
  public let vScale: Float;        // vertical speed scale (Mod Settings); the system sets it before every Step
  public let unresolvedT: Float;   // seconds engaged without a resolved body (watchdog)
  private let m_respLogged: Bool;
  private let m_wzPrev: Float;
  private let m_calHasPrev: Bool;
  private let m_calSamples: Int32;
  private let m_calErr: array<Float>;
  private let m_upPrev: Vector4;
  private let m_fwdPrev: Vector4;
  private let m_aF: Float;
  private let m_aL: Float;
  private let m_aZ: Float;
  private let m_yawCmd: Float;
  private let m_zHold: Float;
  private let m_holding: Bool;
  private let m_oscCount: Int32;
  private let m_ePrev: Vector3;
  private let m_vecA: Vector3;
  private let m_vecW: Vector3;
  private let m_tickPrev: Float;
  private let m_tickStall: Float;
  private let m_fdrT: Float;       // flight-data lines: seconds since the last engage
  private let m_fdrNext: Float;
  // telemetry (read by the system / HUD)
  public let speed: Float;
  public let vfNow: Float;
  public let vzNow: Float;
  public let agl: Float;
  public let aglValid: Bool;
  public let groundZ: Float;
  public let posZ: Float;
  public let powerFrac: Float;
  public let yawNow: Float;
  private let m_aglTimer: Float;

  public func Init(gi: GameInstance) -> Void {
    this.m_gi = gi;
    this.m_sigma = 1.0;
    this.gainFactor = 30.0;
    this.vScale = 1.0;
    ArrayResize(this.m_calErr, 4);
  }

  private func Log(s: String) -> Void {
    AVFSystem.LogLine(this.m_gi, s);
  }

  // ---------------------------------------------------------------- binding

  public func Bind(veh: ref<VehicleObject>, model: ref<AVFModel>) -> Bool {
    if !IsDefined(veh) {
      return false;
    };
    if !IsDefined(this.fly) {
      this.fly = new FlyAVSystem();
    };
    if this.bound && Equals(this.vehID, veh.GetEntityID()) {
      return true;
    };
    this.veh = veh;
    this.vehID = veh.GetEntityID();
    this.model = model;
    let hash: Uint64 = EntityID.ToHash(this.vehID);
    let low: Uint32 = Cast<Uint32>(hash % 4294967296ul);
    let ok: Float = this.fly.SetVehicle(low);
    // SetVehicle always switches the game's physics back on and drops a held command.
    this.m_r = this.fly.UnsetPhysicsState();
    this.Push0();
    this.bound = true;
    this.engaged = false;
    this.mass = this.fly.GetMass();
    // half the box-inertia estimate to start with: the real inertia comes from the collider and is unmeasured;
    // the response time is logged once per flight and the oscillation guard lowers it further if needed
    this.gainFactor = model.gainPerKg * 0.5;
    this.m_respLogged = false;
    this.m_oscCount = 0;
    this.m_tickPrev = -1.0;
    this.m_tickStall = 0.0;
    this.Log("bind " + model.name + " resolved " + FloatToString(ok) + " mass " + FloatToStringPrec(this.mass, 0));
    return true;
  }

  public func Release() -> Void {
    if !this.bound {
      return;
    };
    this.Push0();
    this.m_r = this.fly.EnableGravity(true);
    this.m_r = this.fly.EnableOriginalPhysics(true);
    this.m_r = this.fly.SetVehicle(0u);
    this.bound = false;
    this.engaged = false;
    this.veh = null;
    this.Log("release");
  }

  private func Push0() -> Void {
    this.m_vecA.X = 0.0;
    this.m_vecA.Y = 0.0;
    this.m_vecA.Z = 0.0;
    this.m_vecW.X = 0.0;
    this.m_vecW.Y = 0.0;
    this.m_vecW.Z = 0.0;
    this.m_r = this.fly.SetFlightControl(0.0, this.m_vecA, this.m_vecW, 0.0);
  }

  // Game physics off for the bound body: no gravity, no wheels / springs / drag. The controller flies it.
  public func Engage() -> Void {
    if !this.bound {
      return;
    };
    this.m_r = this.fly.EnableOriginalPhysics(false);
    this.m_r = this.fly.EnableGravity(false);
    this.m_r = this.fly.UnsetPhysicsState();
    this.engaged = true;
    this.m_calHasPrev = false;
    this.tumbleT = 0.0;
    this.unresolvedT = 0.0;
    this.m_fdrT = 0.0;
    this.m_fdrNext = 0.0;
    this.m_aF = 0.0;
    this.m_aL = 0.0;
    this.m_aZ = 0.0;
    this.m_yawCmd = 0.0;
    this.m_holding = false;
    let veh: ref<VehicleObject> = this.veh;
    if IsDefined(veh) {
      this.m_zHold = veh.GetWorldPosition().Z;
    };
    this.Log("engage");
  }

  // Back to the game's physics (landed: the body rests on its gear / tank springs).
  public func Disengage() -> Void {
    if !this.bound {
      return;
    };
    this.Push0();
    this.m_r = this.fly.EnableGravity(true);
    this.m_r = this.fly.EnableOriginalPhysics(true);
    this.engaged = false;
    this.Log("disengage");
  }

  public func HoldHere() -> Void {
    let veh: ref<VehicleObject> = this.veh;
    if IsDefined(veh) {
      this.m_zHold = veh.GetWorldPosition().Z;
      this.m_holding = true;
    };
  }

  public func IsOnGround() -> Bool {
    if !this.bound {
      return false;
    };
    let g: Bool = this.fly.IsOnGround();   // a plain assignment, like every other FlyAVSystem call
    return g;
  }

  // ---------------------------------------------------------------- ground

  // Radar altitude, 10 times a second: World Static straight down, water as a fallback.
  public func UpdateAGL(dt: Float, force: Bool) -> Void {
    this.m_aglTimer -= dt;
    if !force && this.m_aglTimer > 0.0 {
      return;
    };
    this.m_aglTimer = this.agl < 4.0 ? 0.0 : 0.1;   // every tick close to the ground (touchdown within centimetres)
    let veh: ref<VehicleObject> = this.veh;
    if !IsDefined(veh) {
      this.aglValid = false;
      return;
    };
    let p: Vector4 = veh.GetWorldPosition();
    this.posZ = p.Z;
    let from: Vector4 = new Vector4(p.X, p.Y, p.Z + 0.5, 1.0);
    let to: Vector4 = new Vector4(p.X, p.Y, p.Z - 400.0, 1.0);
    let hit: TraceResult;
    let sq: ref<SpatialQueriesSystem> = GameInstance.GetSpatialQueriesSystem(this.m_gi);
    if sq.SyncRaycastByCollisionPreset(from, to, n"World Static", hit, true, false) && TraceResult.IsValid(hit) {
      this.groundZ = hit.position.Z;
      this.agl = p.Z - hit.position.Z;
      this.aglValid = true;
      return;
    };
    let hitW: TraceResult;
    if sq.SyncRaycastByCollisionGroup(from, to, n"Water", hitW, false, false) && TraceResult.IsValid(hitW) {
      this.groundZ = hitW.position.Z;
      this.agl = p.Z - hitW.position.Z;
      this.aglValid = true;
      return;
    };
    this.aglValid = false;
    this.agl = 400.0;
  }

  // ---------------------------------------------------------------- liveness

  // The DLL's physics hook must tick for the bound body; if it stops, wake the body (DAV's heartbeat).
  public func Heartbeat(dt: Float) -> Void {
    if !this.bound {
      return;
    };
    if this.mass <= 0.0 {
      this.mass = this.fly.GetMass();
      if this.mass > 0.0 {
        this.Log("mass resolved " + FloatToStringPrec(this.mass, 0));
      };
    };
    let t: Float = this.fly.GetNativeTickCount();
    if t == this.m_tickPrev && this.engaged {
      // only while flying: a parked body is allowed to sleep
      this.m_tickStall += dt;
      if this.m_tickStall > 1.0 {
        this.m_r = this.fly.UnsetPhysicsState();
        this.m_tickStall = 0.0;
      };
    } else {
      this.m_tickStall = 0.0;
    };
    this.m_tickPrev = t;
  }

  // ---------------------------------------------------------------- control law

  // Sink rate (positive) for a descent to a touchdown, h metres over the resting height: the asked rate far up,
  // a constant deceleration below that, 0.45 x height near the ground, 0.15 m/s at the ground.
  public final static func Flare(h: Float, descent: Float, vs: Float) -> Float {
    let aLim: Float = 3.5 * (0.5 + 0.5 * MaxF(vs, 0.5));
    return MaxF(0.15, MinF(descent, MinF(0.45 * h, SqrtF(2.0 * 0.6 * aLim * MaxF(h, 0.0)))));
  }

  private func Approach(cur: Float, tgt: Float, step: Float) -> Float {
    if tgt > cur {
      return MinF(tgt, cur + step);
    };
    return MaxF(tgt, cur - step);
  }

  public func Step(dt: Float, cmd: ref<AVFCmd>, vmaxEff: Float) -> Void {
    let veh: ref<VehicleObject> = this.veh;
    if !this.bound || !IsDefined(veh) || dt <= 0.0 {
      return;
    };
    let m: ref<AVFModel> = this.model;
    if this.mass <= 0.0 {
      // Not resolved yet: keep calling SetFlightControl (it is the DLL's lazy resolver), hold position.
      this.Push0();
      this.mass = this.fly.GetMass();
      this.unresolvedT += dt;
      return;
    };
    this.unresolvedT = 0.0;
    let fwd: Vector4 = veh.GetWorldForward();
    let up: Vector4 = veh.GetWorldUp();
    let v3: Vector3 = this.fly.GetVelocity();
    let w3: Vector3 = this.fly.GetAngularVelocity();
    // tumble = spinning fast or lying on its side / back
    if SqrtF(w3.X * w3.X + w3.Y * w3.Y + w3.Z * w3.Z) > 3.0 || up.Z < 0.3 {
      this.tumbleT += dt;
    } else {
      this.tumbleT = 0.0;
    };

    // heading frame (horizontal forward / right), right-handed, Z up
    let fl: Float = SqrtF(fwd.X * fwd.X + fwd.Y * fwd.Y);
    if fl < 0.05 {
      fl = 0.05;
    };
    let fx: Float = fwd.X / fl;
    let fy: Float = fwd.Y / fl;
    let rx: Float = fy;
    let ry: Float = -fx;
    let vf: Float = v3.X * fx + v3.Y * fy;
    let vl: Float = v3.X * rx + v3.Y * ry;
    let vz: Float = v3.Z;
    this.vfNow = vf;
    this.vzNow = vz;
    this.speed = SqrtF(v3.X * v3.X + v3.Y * v3.Y + v3.Z * v3.Z);

    // forward channel
    let vt: Float = ClampF(cmd.vf, -8.3, vmaxEff);
    let a: Float = 1.0 * (vt - vf);
    let lim: Float;
    let brake: Float = cmd.brakeBoost ? m.brake * 1.6 : m.brake;
    if a > 0.0 {
      if vf >= 0.0 {
        lim = m.accel * MaxF(0.12, 1.0 - (vf / vmaxEff) * (vf / vmaxEff));
      } else {
        lim = brake;
      };
    } else {
      if vf > 0.0 {
        lim = brake;
      } else {
        lim = m.accel * 0.5;
      };
    };
    a = ClampF(a, -lim, lim);
    this.m_aF = this.Approach(this.m_aF, a, 4.0 * dt);

    // sideways channel: removes slip (the velocity follows the heading through turns) or slides on request
    // feed-forward: the centripetal acceleration of the commanded turn, so the nose and the path stay together
    let latMax: Float = m.turnLat + 1.5;
    let aL: Float = ClampF(1.5 * (cmd.vl - vl) + vf * this.m_yawCmd, -latMax, latMax);
    this.m_aL = this.Approach(this.m_aL, aL, 6.0 * dt);

    // vertical channel
    let p: Vector4 = veh.GetWorldPosition();
    let vzT: Float;
    // vertical acceleration and jerk grow half as fast as the vertical speed setting
    let vk: Float = 0.5 + 0.5 * MaxF(this.vScale, 0.5);
    if cmd.holdAlt {
      if !this.m_holding {
        // capture where the climb / descent would stop, so letting go does not bounce
        this.m_zHold = p.Z + vz * AbsF(vz) / (7.0 * vk);
        this.m_holding = true;
      };
      vzT = ClampF(0.8 * (this.m_zHold - p.Z), -2.5, 2.5);
    } else {
      this.m_holding = false;
      vzT = cmd.vz;
    };
    let aZ: Float = ClampF(1.6 * (vzT - vz), -3.5 * vk, 3.5 * vk);
    this.m_aZ = this.Approach(this.m_aZ, aZ, 6.0 * vk * dt);

    // DLL mode 2 (velocity hold, the mode DAV itself flies with): the target is the measured velocity plus the
    // commanded acceleration over this tick. Mode 1 (force + torque) tumbled in game on 2026-11-22: its
    // torque gain needs the body's real inertia, which no native returns and which is far below the box estimate.
    this.m_vecA.X = v3.X + (this.m_aF * fx + this.m_aL * rx) * dt;
    this.m_vecA.Y = v3.Y + (this.m_aF * fy + this.m_aL * ry) * dt;
    this.m_vecA.Z = v3.Z + this.m_aZ * dt;

    // yaw: rate command, limited at speed by the lateral acceleration of a coordinated turn
    let spd: Float = MaxF(AbsF(vf), 1.0);
    let yawMax: Float = MinF(m.yawRate, m.turnLat / spd);
    let yawT: Float = ClampF(cmd.yaw, -yawMax, yawMax);
    this.m_yawCmd = this.Approach(this.m_yawCmd, yawT, 2.0 * dt);
    this.yawNow = this.m_yawCmd;

    // attitude the hull should show: bank into the turn, pitch with the acceleration
    let bank: Float = 0.0;
    if AbsF(vf) > 3.0 {
      bank = ClampF(AtanF(vf * this.m_yawCmd, 9.81), -0.70, 0.70);
    };
    let tilt: Float = this.m_aF;
    if m.kind == 1 {
      // a helicopter also noses down to hold its cruise speed against drag
      tilt += m.accel * (vf / vmaxEff) * AbsF(vf / vmaxEff);
    };
    let pitchMax: Float = m.kind == 1 ? 0.26 : 0.14;
    let pitch: Float = ClampF(m.pitchFactor * AtanF(tilt, 9.81), -pitchMax, pitchMax);
    // desired up vector = Z tilted towards the right by the bank and forwards by the pitch (nose down)
    let tb: Float = TanF(bank);
    let tp: Float = TanF(pitch);
    let ux: Float = tb * rx + tp * fx;
    let uy: Float = tb * ry + tp * fy;
    let uz: Float = 1.0;
    let ul: Float = SqrtF(ux * ux + uy * uy + uz * uz);
    ux /= ul;
    uy /= ul;
    uz /= ul;
    // rotation that brings the hull's up onto the desired up: axis = up x desired
    let ex: Float = up.Y * uz - up.Z * uy;
    let ey: Float = up.Z * ux - up.X * uz;
    let ez: Float = up.X * uy - up.Y * ux;
    let kAtt: Float = 4.0;
    let wx: Float = ClampF(kAtt * ex, -1.5, 1.5);
    let wy: Float = ClampF(kAtt * ey, -1.5, 1.5);
    let wz: Float = ClampF(kAtt * ez, -1.5, 1.5) - this.m_yawCmd;   // right turn = clockwise seen from above
    // world-axis target -> the axes the engine's angular velocity really uses (calibrated in flight)
    let rgt: Vector4 = veh.GetWorldRight();
    if this.m_frameLocal {
      this.m_vecW.X = this.m_sigma * (wx * rgt.X + wy * rgt.Y + wz * rgt.Z);
      this.m_vecW.Y = this.m_sigma * (wx * fwd.X + wy * fwd.Y + wz * fwd.Z);
      this.m_vecW.Z = this.m_sigma * (wx * up.X + wy * up.Y + wz * up.Z);
    } else {
      this.m_vecW.X = this.m_sigma * wx;
      this.m_vecW.Y = this.m_sigma * wy;
      this.m_vecW.Z = this.m_sigma * wz;
    };

    this.Calibrate(w3, up, fwd, rgt, dt);
    this.m_wzPrev = w3.Z;

    // flight data for the first 4 s after every engage (16 lines): what was asked and what the body did
    this.m_fdrT += dt;
    if this.m_fdrT < 4.0 && this.m_fdrT >= this.m_fdrNext {
      this.m_fdrNext = this.m_fdrT + 0.25;
      this.Log("fdr t=" + FloatToStringPrec(this.m_fdrT, 2) + " upZ=" + FloatToStringPrec(up.Z, 2)
        + " w=(" + FloatToStringPrec(w3.X, 2) + " " + FloatToStringPrec(w3.Y, 2) + " " + FloatToStringPrec(w3.Z, 2) + ")"
        + " wT=(" + FloatToStringPrec(this.m_vecW.X, 2) + " " + FloatToStringPrec(this.m_vecW.Y, 2) + " " + FloatToStringPrec(this.m_vecW.Z, 2) + ")"
        + " v=(" + FloatToStringPrec(v3.X, 1) + " " + FloatToStringPrec(v3.Y, 1) + " " + FloatToStringPrec(v3.Z, 1) + ")"
        + " vT=(" + FloatToStringPrec(this.m_vecA.X, 1) + " " + FloatToStringPrec(this.m_vecA.Y, 1) + " " + FloatToStringPrec(this.m_vecA.Z, 1) + ")"
        + " z=" + FloatToStringPrec(p.Z, 1) + " dt=" + FloatToStringPrec(dt, 3));
    };

    // mode 2: linear and angular velocity targets, written into the body by the DLL on every physics step
    this.m_r = this.fly.SetFlightControl(2.0, this.m_vecA, this.m_vecW, 0.0);

    // share of full power, for the fuel meter and the engine sound
    let aH: Float = SqrtF(this.m_aF * this.m_aF + this.m_aL * this.m_aL);
    this.powerFrac = ClampF(0.55 * AbsF(vf) / vmaxEff + 0.45 * aH / m.accel + 0.3 * MaxF(this.m_aZ, 0.0) / 3.5, 0.0, 1.0);
  }

  // Which axes and sign the engine's angular velocity uses is not readable from the DLL. This measures it once
  // per session from the real motion: the hull's up and forward vectors must turn as (omega x vector) * dt.
  // Four candidates: world axes +/- and body axes (x right, y forward, z up) +/-. The one that predicts the
  // measured rotation best (and clearly better than the rest) is kept; until then world axes, right-handed.
  private func Calibrate(w3: Vector3, up: Vector4, fwd: Vector4, rgt: Vector4, dt: Float) -> Void {
    if this.m_calLocked {
      return;
    };
    if !this.m_calHasPrev || dt <= 0.0 || dt > 0.1 {
      this.m_upPrev = up;
      this.m_fwdPrev = fwd;
      this.m_calHasPrev = true;
      return;
    };
    let wl: Float = SqrtF(w3.X * w3.X + w3.Y * w3.Y + w3.Z * w3.Z);
    if wl > 0.08 {
      let duX: Float = up.X - this.m_upPrev.X;
      let duY: Float = up.Y - this.m_upPrev.Y;
      let duZ: Float = up.Z - this.m_upPrev.Z;
      let dfX: Float = fwd.X - this.m_fwdPrev.X;
      let dfY: Float = fwd.Y - this.m_fwdPrev.Y;
      let dfZ: Float = fwd.Z - this.m_fwdPrev.Z;
      // body axes -> world
      let bX: Float = w3.X * rgt.X + w3.Y * fwd.X + w3.Z * up.X;
      let bY: Float = w3.X * rgt.Y + w3.Y * fwd.Y + w3.Z * up.Y;
      let bZ: Float = w3.X * rgt.Z + w3.Y * fwd.Z + w3.Z * up.Z;
      let c: Int32 = 0;
      while c < 4 {
        let s: Float = (c == 1 || c == 3) ? -1.0 : 1.0;
        let oX: Float = c < 2 ? s * w3.X : s * bX;
        let oY: Float = c < 2 ? s * w3.Y : s * bY;
        let oZ: Float = c < 2 ? s * w3.Z : s * bZ;
        let u: Vector4 = this.m_upPrev;
        let f: Vector4 = this.m_fwdPrev;
        let eUX: Float = duX - (oY * u.Z - oZ * u.Y) * dt;
        let eUY: Float = duY - (oZ * u.X - oX * u.Z) * dt;
        let eUZ: Float = duZ - (oX * u.Y - oY * u.X) * dt;
        let eFX: Float = dfX - (oY * f.Z - oZ * f.Y) * dt;
        let eFY: Float = dfY - (oZ * f.X - oX * f.Z) * dt;
        let eFZ: Float = dfZ - (oX * f.Y - oY * f.X) * dt;
        this.m_calErr[c] += eUX * eUX + eUY * eUY + eUZ * eUZ + eFX * eFX + eFY * eFY + eFZ * eFZ;
        c += 1;
      };
      this.m_calSamples += 1;
    };
    this.m_upPrev = up;
    this.m_fwdPrev = fwd;
    if this.m_calSamples < 25 {
      return;
    };
    // 1) the sign: yaw alone decides it (world and body agree when the hull is level), so it locks first
    if !this.m_signLocked {
      let plus: Float = MinF(this.m_calErr[0], this.m_calErr[2]);
      let minus: Float = MinF(this.m_calErr[1], this.m_calErr[3]);
      if plus < 0.4 * minus || minus < 0.4 * plus {
        this.m_sigma = minus < plus ? -1.0 : 1.0;
        this.m_signLocked = true;
        this.Log("angular sign: " + (this.m_sigma > 0.0 ? "right-handed" : "mirrored") + " (" + IntToString(this.m_calSamples) + " samples)");
      };
      return;
    };
    // 2) the axes, within that sign: needs roll / pitch motion; a tie keeps world axes and keeps listening
    let ew: Float = this.m_sigma > 0.0 ? this.m_calErr[0] : this.m_calErr[1];
    let eb: Float = this.m_sigma > 0.0 ? this.m_calErr[2] : this.m_calErr[3];
    if eb < 0.4 * ew || ew < 0.4 * eb {
      this.m_frameLocal = eb < ew;
      this.m_calLocked = true;
      this.Log("angular axes: " + (this.m_frameLocal ? "body" : "world") + " (" + IntToString(this.m_calSamples) + " samples)");
    } else {
      if this.m_calSamples > 3000 {
        this.m_calLocked = true;
        this.Log("angular axes: world and body never differed in 3000 samples, staying on world axes");
      };
    };
  }

  // Torque gain too high for the real inertia shows as an angular error that changes sign every frame and grows.
  private func CheckOscillation(w3: Vector3) -> Void {
    let ex: Float = this.m_vecW.X - w3.X;
    let ey: Float = this.m_vecW.Y - w3.Y;
    let ez: Float = this.m_vecW.Z - w3.Z;
    let dot: Float = ex * this.m_ePrev.X + ey * this.m_ePrev.Y + ez * this.m_ePrev.Z;
    let mag: Float = SqrtF(ex * ex + ey * ey + ez * ez);
    let magPrev: Float = SqrtF(this.m_ePrev.X * this.m_ePrev.X + this.m_ePrev.Y * this.m_ePrev.Y + this.m_ePrev.Z * this.m_ePrev.Z);
    if mag > 0.4 && dot < -0.5 * mag * magPrev {
      this.m_oscCount += 1;
      if this.m_oscCount >= 6 && this.gainFactor > 3.0 {
        this.gainFactor = MaxF(3.0, this.gainFactor * 0.6);
        this.m_oscCount = 0;
        this.Log("torque gain lowered to " + FloatToStringPrec(this.gainFactor, 1) + " x mass (oscillation)");
      };
    } else {
      this.m_oscCount = 0;
    };
    this.m_ePrev.X = ex;
    this.m_ePrev.Y = ey;
    this.m_ePrev.Z = ez;
  }
}
