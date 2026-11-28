// Cyberslop AV Flight 1.0.0 - charter, pilot and Night Hunter state machine.
// Build 19 (2026-11-28): the charter lands with its door side (left) towards V, the hull side about 3 m from V's
// feet, on the flattest ground there (FindSpot); it turns to that heading high up and comes straight down. Touchdown by
// gear contact (Touchdown), not by a remembered resting height: no more creeping / twitching just above the ground.
// The front-left door opens when V walks up and closes when V walks off or the AV takes off. Getting out in the air
// drops V beside the hull (it used to leave V on the roof). Double tap of the call key on foot = "come to me": the AV
// comes from where it holds in the air or from where it landed (OnCallDoubleTap); the single tap is gone.
// Build 18 (2026-11-26): the board key seats V in the seat from Mod Settings ("Your seat", default back right) and V
// flies the charter from there; right-hand seats get out on the right; take-off switches the vehicle on as well.
// Build 16 (2026-11-23, bug hunt minors): a pad with the radio / vehicle list or a menu open no longer flies (stick and A
// neutral), call / board / pilot keys changed in Mod Settings apply at once, the "holding until you are on foot" note
// shows for every charter, an abandoned or destroyed charter's bill shares one message with the reason, the restored
// bill from the last session shows on the panel, and the stale "L3 + R3" gamepad call text is gone (removed 2026-11-22).
// Build 15 (2026-11-23): send-away climbs above the tallest known building on its way out (height map, 500 m ahead,
// + 25 m) before it flies off, and stops to climb whenever a known building is less than 20 m under it 150 m ahead.
// Build 14 flew level at 60 m over the ground with no obstacle check ("departure aborted" = building hit).
//   Call (hold the call key on foot) -> quote -> hold again: paid -> en route (ETA from the nearest AV pad)
//   -> the AV flies in and lands on an open spot near V -> board -> fly -> land -> get out -> send away (hold)
//   -> it climbs out and leaves; flight time and fuel burned are billed.
//   The NCPD Night Hunter (Oranje3 Night Hunter Quest) flies with the same controller when V drives it.
// Ticks only while an AV exists or V pilots a flyable vehicle; otherwise nothing runs.
module CyberslopAVFlight

@if(ModuleExists("CyberslopCashflow"))
import CyberslopCashflow.*
@if(ModuleExists("VehicleMileage.Runtime"))
import VehicleMileage.Runtime.*

@if(ModuleExists("CyberslopCashflow"))
func AVF_TagCashflow(gi: GameInstance, detail: String) -> Void { CashflowBook.TagNow(gi, CashflowCat.Vehicle(), detail, 3.0); }
@if(!ModuleExists("CyberslopCashflow"))
func AVF_TagCashflow(gi: GameInstance, detail: String) -> Void {}

// Vehicle Mileage would run its car fuel model (12 L/100 km, 40 L tank) on the charter AV: put it on its ignore list.
@if(ModuleExists("VehicleMileage.Runtime"))
func AVF_IgnoreInMileage(gi: GameInstance) -> Void {
  let vm: ref<VMRuntimeSystem> = GameInstance.GetScriptableSystemsContainer(gi).Get(n"VehicleMileage.Runtime.VMRuntimeSystem") as VMRuntimeSystem;
  if IsDefined(vm) {
    vm.SetCurrentIgnored(true);
  };
}
@if(!ModuleExists("VehicleMileage.Runtime"))
func AVF_IgnoreInMileage(gi: GameInstance) -> Void {}

public enum AVFState {
  None = 0,
  Quoted = 1,
  EnRoute = 2,
  Arriving = 3,
  Parked = 4,
  Piloting = 5,
  Departing = 6,
  Wreck = 7
}

public class AVFWatch extends DelayCallback {
  public let sys: wref<AVFSystem>;

  public func Call() -> Void {
    if IsDefined(this.sys) {
      this.sys.Watch();
    };
  }
}

public class AVFTick extends DelayCallback {
  public let sys: wref<AVFSystem>;
  public let gen: Int32;

  public func Call() -> Void {
    if IsDefined(this.sys) {
      this.sys.Tick(this.gen);
    };
  }
}

public class AVFRestoredBill extends DelayCallback {
  public let sys: wref<AVFSystem>;

  public func Call() -> Void {
    if IsDefined(this.sys) {
      this.sys.SettleRestored();
    };
  }
}

public class AVFMileageCall extends DelayCallback {
  public let gi: GameInstance;

  public func Call() -> Void {
    AVF_IgnoreInMileage(this.gi);
  }
}

public class AVFSystem extends ScriptableSystem {
  private let m_gi: GameInstance;
  private let m_settings: ref<AVFSettings>;
  private let m_input: ref<AVFInput>;
  private let m_flight: ref<AVFFlight>;
  private let m_hud: ref<AVFHud>;
  private let m_models: array<ref<AVFModel>>;
  private let m_cmd: ref<AVFCmd>;
  private let m_ticking: Bool;
  private let m_lastTime: Float;
  private let m_lastET: EngineTime;
  private let m_tickN: Int32;
  private let m_watchN: Int32;
  private let m_tickLogT: Float;
  private let m_fallback: Bool;
  private let m_watching: Bool;
  private let m_tickGen: Int32;      // only the newest tick chain runs (the watchdog may start a second one)
  private let m_t0: EngineTime;      // clock base, see Now()
  private let m_t0Set: Bool;
  private let m_glideZ0: Float;      // arrival glide: height and distance of the spawn point over the approach point
  private let m_glideD0: Float;
  private let m_blockT: Float;       // seconds of blocked descent (touchdown test)
  private let m_blockZ: Float;       // lowest height of the current blocked-descent window
  private let m_blockOn: Bool;
  private let m_engineChkT: Float;
  private let m_hadPilot: Bool;      // a pilot seat is active (the wref alone cannot tell "gone" from "never")
  private let m_pilotT: Float;       // seconds in the pilot seat
  private let m_lostT: Float;        // seconds V has not been mounted while the pilot seat is active
  private let m_auto: ref<AVFAutopilot>;
  private let m_apLatch: Bool;       // the autopilot key is still held from the last toggle
  private let m_domeT: Float;        // countdown to the crystal dome after boarding
  private let m_domeOn: Bool;
  private let m_partsT: Float;       // second pass of the component placement after a spawn
  private let m_engineLogged: Bool;

  // charter
  private let m_state: AVFState;
  private let m_model: ref<AVFModel>;
  private let m_avID: EntityID;
  private let m_quoteCost: Int32;
  private let m_quoteFerryL: Float;
  private let m_quoteUntil: Float;
  private let m_quoteEta: Float;
  private let m_depot: Vector4;
  private let m_etaAt: Float;
  private let m_spot: Vector4;
  private let m_approach: Vector4;
  private let m_departDir: Vector4;
  // build 15: departure obstacle check (height map columns along m_departDir)
  private let m_departMap: ref<AVFHeights>;
  private let m_departTopZ: Float;
  private let m_departScanT: Float;
  private let m_departBlocked: Bool;
  private let m_departBlockedT: Float;
  private let m_phase: Int32;
  private let m_phaseT: Float;
  private let m_spawnWait: Float;
  private let m_noSpotNotified: Bool;
  private let m_retryAt: Float;
  private let m_rentS: Float;
  private let m_fuelL: Float;
  private let m_awayT: Float;
  private let m_wreckT: Float;
  private let m_mileageDone: Bool;
  private let m_exitTeleport: Bool;
  private let m_exitAir: Bool;       // build 19: that exit was in the air: V is dropped beside the hull
  private let m_seatRight: Bool;     // build 18: V boarded a right-hand seat (exit point mirrored)
  private let m_spotFwd: Vector4;    // build 19: heading the arrival lands with (door side towards V)
  private let m_doorT: Float;        // build 19: door check cooldown
  private let m_tdOn: Bool;          // build 19: touchdown contact test (see Touchdown)
  private let m_tdRef: Float;
  private let m_tdStall: Float;
  private let m_tdSteady: Float;
  private let m_restAGL: Float;
  private let m_restMeasureT: Float;
  private persistent let p_open: Bool;
  private persistent let p_due: Int32;
  private let m_restoredDue: Int32;
  private let m_holdNotified: Bool;
  private let m_billPrefix: String;   // build 16: reason shown in front of the next bill
  private let m_saveT: Float;

  // pilot (charter AV or Night Hunter)
  private let m_pilotVeh: wref<VehicleObject>;
  private let m_pilotModel: ref<AVFModel>;
  private let m_isNH: Bool;
  private let m_airborne: Bool;
  private let m_airT: Float;
  private let m_takeoffT: Float;
  private let m_nhRest: Float;
  private let m_vSet: Float;
  private let m_zeroLatch: Bool;
  private let m_steer: Float;
  private let m_lift: Float;
  private let m_blocked: Bool;
  private let m_hintUntil: Float;
  private let m_hintKey: Int32;
  private let m_hudT: Float;
  private let m_audioT: Float;
  private let m_volSent: Float;
  private let m_thrustSent: Float;
  private let m_speedSent: Float;
  private let m_sideSent: Float;
  private let m_rotSent: Float;
  private let m_lastFootPad: Bool;
  private let m_engineOffT: Float;
  private let m_radioDone: Bool;
  private let m_radioToken: ref<ResourceToken>;
  private let m_pilotID: EntityID;

  // hover hold: an aircraft V left in the air (charter or Night Hunter) stops and holds its position unmanned
  // until it is boarded again, sent away, destroyed, or another aircraft needs the (single) flight controller
  private let m_hoverOn: Bool;
  private let m_hoverVeh: wref<VehicleObject>;
  private let m_hoverID: EntityID;
  private let m_hoverModel: ref<AVFModel>;
  private let m_hoverNH: Bool;
  private let m_hoverChkT: Float;
  private let m_hoverLand: Bool;     // the held aircraft is flying to V (build 19: double tap of the call key)

  // ---------------------------------------------------------------- lifecycle

  private func OnAttach() -> Void {
    this.m_gi = this.GetGameInstance();
    this.m_settings = AVFSettings.Get(this.m_gi);
    this.m_models = AVFData.Models();
    this.m_cmd = new AVFCmd();
    this.m_flight = new AVFFlight();
    this.m_flight.Init(this.m_gi);
    this.m_hud = new AVFHud();
    this.m_hud.Init(this.m_gi);
    this.m_input = new AVFInput();
    this.m_input.Init(this.m_gi, this, this.m_settings);
    this.m_restAGL = 0.6;
    this.m_auto = new AVFAutopilot();
    this.m_auto.Init(this.m_gi);
  }

  private func OnDetach() -> Void {
    this.Shutdown();
  }

  private func OnRestored(saveVersion: Int32, gameVersion: Int32) -> Void {
    // A charter that was open when the save was made: the aircraft is gone (never saved), the meter is
    // settled a few seconds after the player is back (the wallet is not readable this early).
    if this.p_open {
      this.m_restoredDue = this.p_due;
      this.p_open = false;
      this.p_due = 0;
    };
  }

  private func OnPlayerAttach(request: ref<PlayerAttachRequest>) -> Void {
    if !IsDefined(this.m_settings) {
      this.m_settings = AVFSettings.Get(this.m_gi);
      this.Log("diag settings were missing at attach, now " + ToString(IsDefined(this.m_settings)));
      this.m_input.SetSettings(this.m_settings);
    };
    this.m_t0Set = false;
    this.m_hud.Forget();
    this.m_input.StartFoot();
    GameInstance.GetDynamicEntitySystem().DeleteTagged(n"CyberslopAVFlight");
    if this.m_restoredDue > 0 {
      let cb: ref<AVFRestoredBill> = new AVFRestoredBill();
      cb.sys = this;
      GameInstance.GetDelaySystem(this.m_gi).DelayCallback(cb, 5.0, false);
    };
    this.Log("1.0.0 ready (" + IntToString(ArraySize(this.m_models)) + " models)");
    this.EnsureRadio();
  }

  // The aircraft's audio entry gets a car radio receiver (Radio.reds). Tried at attach, again before a
  // spawn and at boarding if the metadata was not loaded yet.
  private func EnsureRadio() -> Void {
    if this.m_radioDone {
      return;
    };
    let r: String = AVFRadio.Enable(this.m_radioToken);
    this.m_radioDone = StrBeginsWith(r, "on") || Equals(r, "already on");
    this.Log("radio receiver: " + r);
  }

  public func SettleRestored() -> Void {
    let due: Int32 = this.m_restoredDue;
    this.m_restoredDue = 0;
    if due <= 0 {
      return;
    };
    let paid: Int32 = this.TakeMoney(due, "AV charter (previous session)");
    this.Log("open charter from the save billed " + IntToString(paid) + " of " + IntToString(due));
    this.m_hud.Message("AV charter from your last session settled: " + AVFSystem.Eddies(paid) + " eb", 6.0);
    this.StartTick();   // build 16: the panel shows it and ages it (NeedsTick runs while a message is up)
  }

  // build 16: keys changed in Mod Settings: re-register the raw key callbacks that are on now
  public func OnKeysChanged() -> Void {
    if !IsDefined(this.m_input) {
      return;
    };
    let foot: Bool = this.m_input.IsFootOn();
    let pilot: Bool = this.m_input.IsPilotOn();
    if foot {
      this.m_input.StopFoot();
      this.m_input.StartFoot();
    };
    if pilot {
      this.m_input.StopPilot();
      this.m_input.StartPilot();
    };
    this.Log("Mod Settings changed: key callbacks re-registered (foot " + ToString(foot) + ", pilot " + ToString(pilot) + ")");
  }

  private func OnPlayerDetach(request: ref<PlayerDetachRequest>) -> Void {
    this.Shutdown();
  }

  private func Shutdown() -> Void {
    if this.m_blocked {
      this.SetBlocked(false);
    };
    if IsDefined(this.m_input) {
      this.m_input.StopPilot();
      this.m_input.StopFoot();
    };
    if IsDefined(this.m_flight) && this.m_flight.bound {
      this.m_flight.Release();
    };
    this.m_ticking = false;
    this.m_state = AVFState.None;
    this.m_pilotVeh = null;
    this.m_airborne = false;
    this.m_hoverOn = false;
    this.m_hoverVeh = null;
    this.m_hoverLand = false;
  }

  // Codeware input callbacks land here (system target, as in the mods whose key listeners are known to work).
  private cb func OnAVFFootKey(event: ref<KeyInputEvent>) -> Void {
    if IsDefined(this.m_input) {
      this.m_input.FootKey(event);
    };
  }

  private cb func OnAVFPilotKey(event: ref<KeyInputEvent>) -> Void {
    if IsDefined(this.m_input) {
      this.m_input.PilotKey(event);
    };
  }

  private cb func OnAVFPilotAxis(event: ref<AxisInputEvent>) -> Void {
    if IsDefined(this.m_input) {
      this.m_input.PilotAxis(event);
    };
  }

  public static func Get(gi: GameInstance) -> ref<AVFSystem> {
    return GameInstance.GetScriptableSystemsContainer(gi).Get(n"CyberslopAVFlight.AVFSystem") as AVFSystem;
  }

  public static func LogLine(gi: GameInstance, s: String) -> Void {
    let st: ref<AVFSettings> = AVFSettings.Get(gi);
    if IsDefined(st) && st.debugLog {
      FTLog("[AVFlight] " + s);
    };
  }

  private func Log(s: String) -> Void {
    AVFSystem.LogLine(this.m_gi, s);
  }

  // Seconds since the player attached. Never the raw sim time as a Float: on a long save (1.06e6 s) that only
  // resolves 0.125 s, which broke tap / hold timing and the frame time.
  public func Now() -> Float {
    let t: EngineTime = GameInstance.GetSimTime(this.m_gi);
    if !this.m_t0Set {
      this.m_t0 = t;
      this.m_t0Set = true;
    };
    return EngineTime.ToFloat(t - this.m_t0);
  }

  private func StartTick() -> Void {
    if this.m_ticking {
      return;
    };
    this.m_ticking = true;
    this.m_lastTime = this.Now();
    this.m_lastET = GameInstance.GetSimTime(this.m_gi);
    this.m_tickN = 0;
    this.m_watchN = 0;
    this.m_tickLogT = 0.0;
    this.m_tickGen += 1;
    this.Log("diag3 tick start state=" + IntToString(EnumInt(this.m_state)) + " gen=" + IntToString(this.m_tickGen));
    this.QueueTick();
    if !this.m_watching {
      this.m_watching = true;
      this.QueueWatch();
    };
  }

  private func QueueTick() -> Void {
    let cb: ref<AVFTick> = new AVFTick();
    cb.sys = this;
    cb.gen = this.m_tickGen;
    // Timed, not DelayCallbackNextFrame: a next-frame callback queued from inside a next-frame callback never
    // fired (log 2026-11-22: "tick STALLED at n=1"); the timed chain ran until the spawn.
    GameInstance.GetDelaySystem(this.m_gi).DelayCallback(cb, this.IdleTick() ? 0.25 : 0.016, false);
  }

  // Nothing flies and nobody sits in an aircraft (en route, parked, wreck, a message showing): 4 ticks a second do.
  private func IdleTick() -> Bool {
    return !this.m_flight.engaged && !IsDefined(this.m_pilotVeh) && !this.m_hadPilot;
  }

  private func QueueWatch() -> Void {
    let cb: ref<AVFWatch> = new AVFWatch();
    cb.sys = this;
    GameInstance.GetDelaySystem(this.m_gi).DelayCallback(cb, 1.0, false);
  }

  // Once a second while the tick should run: a tick that made no progress is restarted on timed callbacks.
  public func Watch() -> Void {
    if !this.m_ticking {
      this.m_watching = false;
      return;
    };
    if this.m_tickN == this.m_watchN {
      this.m_fallback = true;
      this.m_tickGen += 1;   // a late callback of the old chain is ignored
      this.Log("diag3 tick STALLED at n=" + IntToString(this.m_tickN) + " state=" + IntToString(EnumInt(this.m_state)) + ": restarted");
      this.QueueTick();
    };
    this.m_watchN = this.m_tickN;
    this.QueueWatch();
  }

  private func NeedsTick() -> Bool {
    if IsDefined(this.m_pilotVeh) || this.m_hadPilot || this.m_hoverOn {
      return true;
    };
    if this.m_hud.msgLeft > 0.0 {
      return true;
    };
    return NotEquals(this.m_state, AVFState.None) && NotEquals(this.m_state, AVFState.Quoted);
  }

  // ---------------------------------------------------------------- helpers

  public static func Eddies(n: Int32) -> String {
    let neg: Bool = n < 0;
    let v: Int32 = neg ? -n : n;
    let s: String = "";
    while v >= 1000 {
      let part: Int32 = v % 1000;
      let p: String = IntToString(part);
      if part < 10 {
        p = "00" + p;
      } else {
        if part < 100 {
          p = "0" + p;
        };
      };
      s = "," + p + s;
      v = v / 1000;
    };
    s = IntToString(v) + s;
    return neg ? "-" + s : s;
  }

  private func Clock(sec: Float) -> String {
    let t: Int32 = RoundF(MaxF(sec, 0.0));
    let ss: Int32 = t % 60;
    return IntToString(t / 60) + ":" + (ss < 10 ? "0" : "") + IntToString(ss);
  }

  private func ModelForSetting() -> ref<AVFModel> {
    let i: Int32 = EnumInt(this.m_settings.charter);
    if i < 0 || i >= ArraySize(this.m_models) || this.m_models[i].kind == 2 {
      i = 0;
    };
    return this.m_models[i];
  }

  private func NightHunterModel() -> ref<AVFModel> {
    for m in this.m_models {
      if m.kind == 2 {
        return m;
      };
    };
    return null;
  }

  private func VmaxEff(m: ref<AVFModel>) -> Float {
    return m.vmax * Cast<Float>(this.m_settings.speedLimit) / 100.0;
  }

  private func Player() -> ref<PlayerPuppet> {
    return GetPlayer(this.m_gi);
  }

  private func PlayerInVehicle() -> Bool {
    let p: ref<PlayerPuppet> = this.Player();
    return IsDefined(p) && VehicleComponent.IsMountedToVehicle(this.m_gi, p);
  }

  private func Wallet() -> Int32 {
    let p: ref<PlayerPuppet> = this.Player();
    if !IsDefined(p) {
      return 0;
    };
    return GameInstance.GetTransactionSystem(this.m_gi).GetItemQuantity(p, MarketSystem.Money());
  }

  // Takes up to `amount` from the wallet, returns what was taken.
  private func TakeMoney(amount: Int32, detail: String) -> Int32 {
    let p: ref<PlayerPuppet> = this.Player();
    if !IsDefined(p) || amount <= 0 {
      return 0;
    };
    let take: Int32 = Min(amount, this.Wallet());
    if take <= 0 {
      return 0;
    };
    AVF_TagCashflow(this.m_gi, detail);
    GameInstance.GetTransactionSystem(this.m_gi).RemoveItem(p, MarketSystem.Money(), take);
    return take;
  }

  private func AV() -> ref<VehicleObject> {
    if !EntityID.IsDefined(this.m_avID) {
      return null;
    };
    return GameInstance.FindEntityByID(this.m_gi, this.m_avID) as VehicleObject;
  }

  private func LocalToWorld(veh: ref<VehicleObject>, off: Vector3) -> Vector4 {
    let p: Vector4 = veh.GetWorldPosition();
    let f: Vector4 = veh.GetWorldForward();
    let r: Vector4 = veh.GetWorldRight();
    let u: Vector4 = veh.GetWorldUp();
    return new Vector4(p.X + r.X * off.X + f.X * off.Y + u.X * off.Z, p.Y + r.Y * off.X + f.Y * off.Y + u.Y * off.Z, p.Z + r.Z * off.X + f.Z * off.Y + u.Z * off.Z, 1.0);
  }

  private func HDist(a: Vector4, b: Vector4) -> Float {
    let dx: Float = a.X - b.X;
    let dy: Float = a.Y - b.Y;
    return SqrtF(dx * dx + dy * dy);
  }

  private func Ray(from: Vector4, to: Vector4, out hit: TraceResult) -> Bool {
    return GameInstance.GetSpatialQueriesSystem(this.m_gi).SyncRaycastByCollisionPreset(from, to, n"World Static", hit, true, false) && TraceResult.IsValid(hit);
  }

  private func CallKeyName() -> String {
    return this.KeyLabel(this.m_settings.keyCall);   // build 16: the L3 + R3 chord was removed (2026-11-22)
  }

  private func KeyLabel(k: EInputKey) -> String {
    let s: String = NameToString(EnumValueToName(n"EInputKey", Cast<Int64>(EnumInt(k))));
    if StrBeginsWith(s, "IK_") {
      s = StrMid(s, 3);
    };
    if Equals(s, "LControl") {
      return "L-Ctrl";
    };
    if Equals(s, "LShift") {
      return "L-Shift";
    };
    return s;
  }

  // ---------------------------------------------------------------- calling

  public func OnCallHold() -> Void {
    if this.PlayerInVehicle() {
      return;
    };
    this.m_lastFootPad = this.m_input.lastPad;
    let now: Float = this.Now();
    switch this.m_state {
      case AVFState.None:
        this.MakeQuote();
        break;
      case AVFState.Quoted:
        if now <= this.m_quoteUntil {
          this.Confirm();
        } else {
          this.MakeQuote();
        };
        break;
      case AVFState.EnRoute:
        this.m_state = AVFState.None;
        this.p_open = false;
        this.m_hud.Message("Dispatch cancelled. The dispatch fee is not refunded.", 5.0);
        this.Log("cancelled en route");
        break;
      case AVFState.Arriving:
      case AVFState.Parked:
        this.SendAway("sent away");
        break;
      default:
        break;
    };
    this.StartTick();   // the tick also shows the message on the mod's own panel
  }

  // Build 19 (2026-11-28): DOUBLE tap of the call key on foot = "come to me". The AV holding in the air, or the
  // charter standing landed somewhere else, flies to V and lands at V's feet with its door side towards V (FindSpot).
  // Flown unmanned by TickHover: the autopilot's route (StartFetch: fixed spot + heading), the contact touchdown.
  // Double tap again while it comes: it stops and holds in the air. Replaces build 14's single tap (it landed 14-32 m
  // away, or under itself; the single tap does nothing now). No open spot at V's feet: it stays where it is.
  public func OnCallDoubleTap() -> Void {
    let p: ref<PlayerPuppet> = this.Player();
    if !IsDefined(p) || this.PlayerInVehicle() {
      return;
    };
    let keyName: String = this.KeyLabel(this.m_settings.keyCall);
    if this.m_hoverOn && this.m_hoverLand {
      this.m_hoverLand = false;
      this.m_auto.Stop();
      this.m_hud.Message("Your " + this.m_hoverModel.name + " holds its position. Come to me: double tap " + keyName + ".", 4.0);
      this.Log("fetch called off by V: holding in the air");
      this.StartTick();
      return;
    };
    let veh: ref<VehicleObject>;
    let m: ref<AVFModel>;
    let fromGround: Bool = false;
    if this.m_hoverOn {
      veh = this.m_hoverVeh;
      m = this.m_hoverModel;
    } else {
      if Equals(this.m_state, AVFState.EnRoute) || Equals(this.m_state, AVFState.Arriving) {
        this.m_hud.Message("Your " + this.m_model.name + " is already on its way to you.", 4.0);
        this.StartTick();
        return;
      };
      if Equals(this.m_state, AVFState.Parked) {
        veh = this.AV();
        m = this.m_model;
        fromGround = true;
      };
    };
    if !IsDefined(veh) || !IsDefined(m) {
      if Equals(this.m_state, AVFState.None) {
        this.m_hud.Message("No AV out. Call one: hold " + keyName + ".", 4.0);
        this.StartTick();
      };
      return;
    };
    if fromGround && this.NearEntry(veh, p) {
      this.m_hud.Message("Your " + m.name + " is right here. Board: " + this.KeyLabel(this.m_settings.keyBoard) + ".", 4.0);
      this.StartTick();
      return;
    };
    let spot: Vector4;
    let fwd: Vector4;
    if !this.FindSpot(m, spot, fwd) {
      this.m_hud.Message("No open, flat spot at your feet for your " + m.name + ". Step into the open and double tap " + keyName + " again.", 6.0);
      this.Log("fetch: no landing spot near V");
      this.StartTick();
      return;
    };
    if fromGround {
      // lift off from where it landed: the controller flies it unmanned, like an aircraft V left in the air
      if !this.m_flight.Bind(veh, m) {
        return;
      };
      this.CloseDoor(veh);
      this.m_flight.Engage();
      veh.TurnVehicleOn(true);
      veh.TurnEngineOn(true);
      this.m_thrustSent = -1.0;
      this.m_volSent = -100.0;
      if !this.StartHover(veh, m, false) {
        this.m_flight.Disengage();
        veh.TurnEngineOn(false);
        this.Log("fetch: the flight controller did not take it");
        return;
      };
    };
    let pos: Vector4 = veh.GetWorldPosition();
    this.m_flight.UpdateAGL(0.0, true);
    this.m_auto.StartFetch(spot, fwd, pos, this.m_flight);
    this.m_hoverLand = true;
    this.m_blockOn = false;
    this.m_blockT = 0.0;
    this.ResetTouchdown();
    this.m_awayT = 0.0;
    this.m_hud.Message("Your " + m.name + " is coming to you.", 5.0);
    this.Log("fetch: " + (fromGround ? "from the ground" : "from the air") + ", spot " + FloatToStringPrec(this.HDist(spot, p.GetWorldPosition()), 1) + " m from V (hull centre), " + FloatToStringPrec(this.HDist(spot, pos), 0) + " m to fly, now at " + FloatToStringPrec(pos.Z, 0) + " m, spot at " + FloatToStringPrec(spot.Z, 0) + " m");
    this.StartTick();
  }

  private func NearestPad(p: Vector4) -> Vector4 {
    let pads: array<Vector4> = AVFData.Pads();
    let best: Vector4 = new Vector4(p.X + 3000.0, p.Y, p.Z + 60.0, 1.0);
    let bestD: Float = 1000000.0;
    for q in pads {
      let d: Float = this.HDist(p, q);
      if d < bestD && d > 150.0 {
        bestD = d;
        best = q;
      };
    };
    return best;
  }

  private func MakeQuote() -> Void {
    let p: ref<PlayerPuppet> = this.Player();
    if !IsDefined(p) {
      return;
    };
    let m: ref<AVFModel> = this.ModelForSetting();
    let pos: Vector4 = p.GetWorldPosition();
    this.m_depot = this.NearestPad(pos);
    let dist: Float = this.HDist(pos, this.m_depot);
    let cruise: Float = 0.7 * this.VmaxEff(m);
    let ferryMin: Float = 2.0 * dist / cruise / 60.0;
    this.m_quoteFerryL = m.burnCruise * ferryMin + m.burnHover * 2.0;
    let fee: Float = m.dispatch * this.m_settings.priceScale;
    let fuel: Float = this.m_quoteFerryL * this.m_settings.fuelPrice;
    this.m_quoteCost = RoundF(fee + fuel);
    this.m_quoteEta = ClampF(dist / cruise + 30.0, 40.0, 300.0);
    this.m_quoteUntil = this.Now() + 15.0;
    this.m_model = m;
    this.m_state = AVFState.Quoted;
    this.m_hud.Message(m.name + " charter: " + AVFSystem.Eddies(this.m_quoteCost) + " eb (dispatch " + AVFSystem.Eddies(RoundF(fee)) + " + ferry fuel " + AVFSystem.Eddies(RoundF(fuel)) + ", " + FloatToStringPrec(dist / 1000.0, 1) + " km). ETA " + this.Clock(this.m_quoteEta) + ". Hold " + this.CallKeyName() + " again to confirm.", 8.0);
    this.Log("quote " + m.name + " " + IntToString(this.m_quoteCost) + " eb, depot " + FloatToStringPrec(dist, 0) + " m, ferry " + FloatToStringPrec(this.m_quoteFerryL, 0) + " L");
  }

  private func Confirm() -> Void {
    let m: ref<AVFModel> = this.m_model;
    let reserve: Int32 = RoundF(m.rentPerHour * this.m_settings.priceScale / 12.0 + m.burnCruise * 5.0 * this.m_settings.fuelPrice);
    let need: Int32 = this.m_quoteCost + reserve;
    if this.Wallet() < need {
      this.m_state = AVFState.None;
      this.m_hud.Message("Dispatcher: insufficient funds. You need " + AVFSystem.Eddies(need) + " eb (call + 5 minutes of flight).", 6.0);
      this.Log("declined, wallet " + IntToString(this.Wallet()) + " < " + IntToString(need));
      return;
    };
    let paid: Int32 = this.TakeMoney(this.m_quoteCost, "AV charter " + m.name);
    this.m_state = AVFState.EnRoute;
    this.m_holdNotified = false;   // build 16: the "holding until you are on foot" note once per charter
    this.m_etaAt = this.Now() + this.m_quoteEta;
    this.m_rentS = 0.0;
    this.m_fuelL = 0.0;
    this.m_awayT = 0.0;
    this.m_mileageDone = false;
    this.m_noSpotNotified = false;
    this.m_retryAt = 0.0;
    this.p_open = true;
    this.p_due = 0;
    this.m_hud.Message(m.name + " dispatched, " + AVFSystem.Eddies(paid) + " eb paid. ETA " + this.Clock(this.m_quoteEta) + ". Stay in the open.", 6.0);
    this.Log("dispatched " + m.name + ", paid " + IntToString(paid));
    this.StartTick();
  }

  // Build 19 (2026-11-28): a landing spot at V's feet. The aircraft lands side-on to V with its door side (left,
  // DAV's door: seat_front_left on every model) towards V: hull side 3 m from V first, then 5.5 m, both at V's own
  // level; then the old rings (14 / 22 / 32 m from V, any level within 6 m). Eight directions per ring, V's facing
  // first. Each candidate: open sky over its middle and both ends, its whole footprint (the hull's real outline, not
  // a circle) on ground within 1 m; the flattest one wins, so it sits level and the door meets the ground.
  // fwd = the heading it lands with: its right side points away from V.
  private func FindSpot(m: ref<AVFModel>, out spot: Vector4, out fwd: Vector4) -> Bool {
    let p: ref<PlayerPuppet> = this.Player();
    if !IsDefined(p) {
      return false;
    };
    let pos: Vector4 = p.GetWorldPosition();
    let pf: Vector4 = p.GetWorldForward();
    let base: Float = AtanF(pf.Y, pf.X);
    let side: Float = m.width * 0.5;
    let rr: Float = MaxF(m.length, m.width) * 0.5 + 1.0;
    let radii: array<Float>;
    ArrayPush(radii, side + 3.0);
    ArrayPush(radii, side + 5.5);
    ArrayPush(radii, MaxF(14.0, rr + 6.0));
    ArrayPush(radii, MaxF(22.0, rr + 12.0));
    ArrayPush(radii, MaxF(32.0, rr + 20.0));
    let offs: array<Float>;
    ArrayPush(offs, 0.0);
    ArrayPush(offs, 0.785);
    ArrayPush(offs, -0.785);
    ArrayPush(offs, 1.571);
    ArrayPush(offs, -1.571);
    ArrayPush(offs, 2.356);
    ArrayPush(offs, -2.356);
    ArrayPush(offs, 3.1416);
    let found: Bool = false;
    let done: Bool = false;
    let bestScore: Float = 1000000.0;
    let bestDev: Float = 10.0;
    let bestR: Float = 0.0;
    let ri: Int32 = 0;
    for r in radii {
      if done {
        break;
      };
      let oi: Int32 = 0;
      for o in offs {
        let a: Float = base + o;
        let ux: Float = CosF(a);
        let uy: Float = SinF(a);
        // right = u (away from V), so forward = u turned 90 degrees to the left
        let f: Vector4 = new Vector4(-uy, ux, 0.0, 0.0);
        let s: Vector4;
        let dev: Float;
        if this.CheckSpot(pos.X + r * ux, pos.Y + r * uy, pos.Z, f, m, ri < 2, s, dev) {
          let score: Float = dev * 4.0 + Cast<Float>(ri) * 0.5 + Cast<Float>(oi) * 0.05;
          if !found || score < bestScore {
            found = true;
            bestScore = score;
            bestDev = dev;
            bestR = r;
            spot = s;
            fwd = f;
          };
          if ri == 0 && dev <= 0.12 {
            done = true;   // flat, right at V's feet, in the first directions: take it
            break;
          };
        };
        oi += 1;
      };
      // close rings: the flattest of both unless the first had a flat one; the far rings: the first ring with any
      if found && (ri >= 2 || ri == 1 && bestDev <= 0.35) {
        done = true;
      };
      ri += 1;
    };
    if found {
      this.Log("landing spot: hull centre " + FloatToStringPrec(bestR, 1) + " m from V, ground within " + FloatToStringPrec(bestDev, 2) + " m over the footprint");
    };
    return found;
  }

  // DAV's collision boxes: the Valgus / Mayhem tail reaches 15 m behind the origin (nose 9.4 m); the others are
  // about symmetric.
  private func RearExt(m: ref<AVFModel>) -> Float {
    if Equals(m.key, "valgus") || Equals(m.key, "mayhem") {
      return 15.0;
    };
    return m.length * 0.5;
  }

  // One candidate (centre cx / cy, heading f). close: only ground at V's own level (+-1.2 m) counts.
  // dev = how far the ground under the footprint differs from the ground under the centre.
  private func CheckSpot(cx: Float, cy: Float, pz: Float, f: Vector4, m: ref<AVFModel>, close: Bool, out spot: Vector4, out dev: Float) -> Bool {
    let hit: TraceResult;
    if !this.Ray(new Vector4(cx, cy, pz + 20.0, 1.0), new Vector4(cx, cy, pz - 20.0, 1.0), hit) {
      return false;
    };
    if hit.normal.Z < 0.94 || AbsF(hit.position.Z - pz) > (close ? 1.2 : 6.0) {
      return false;
    };
    let gz: Float = hit.position.Z;
    let sky: TraceResult;
    if this.Ray(new Vector4(cx, cy, gz + 1.0, 1.0), new Vector4(cx, cy, gz + 120.0, 1.0), sky) {
      return false;
    };
    let front: Float = m.length * 0.5 + 0.8;
    let rear: Float = this.RearExt(m) + 0.8;
    let hw: Float = m.width * 0.5 + 0.5;
    let rx: Float = f.Y;
    let ry: Float = -f.X;
    // it comes straight down: open sky over both ends too
    let e: Int32 = 0;
    while e < 2 {
      let lf: Float = e == 0 ? front * 0.85 : -rear * 0.85;
      let ex: Float = cx + f.X * lf;
      let ey: Float = cy + f.Y * lf;
      let skyE: TraceResult;
      if this.Ray(new Vector4(ex, ey, gz + 1.5, 1.0), new Vector4(ex, ey, gz + 40.0, 1.0), skyE) {
        return false;
      };
      e += 1;
    };
    // the footprint: four corners and the middle of both long sides, ground within 1 m of the centre's
    dev = 0.0;
    let k: Int32 = 0;
    while k < 6 {
      let lr: Float = (k % 2 == 0) ? -hw : hw;
      let lf2: Float = k < 2 ? front : (k < 4 ? -rear : 0.0);
      let x: Float = cx + rx * lr + f.X * lf2;
      let y: Float = cy + ry * lr + f.Y * lf2;
      let h2: TraceResult;
      if !this.Ray(new Vector4(x, y, gz + 8.0, 1.0), new Vector4(x, y, gz - 4.0, 1.0), h2) || AbsF(h2.position.Z - gz) > 1.0 {
        return false;
      };
      dev = MaxF(dev, AbsF(h2.position.Z - gz));
      k += 1;
    };
    spot = new Vector4(cx, cy, gz, 1.0);
    return true;
  }

  // Build 19: V stands under the hull (its real outline + margin), below it and less than 15 m down.
  private func VUnderHull(veh: ref<VehicleObject>, m: ref<AVFModel>, margin: Float) -> Bool {
    let p: ref<PlayerPuppet> = this.Player();
    if !IsDefined(p) || !IsDefined(veh) || !IsDefined(m) {
      return false;
    };
    let pp: Vector4 = p.GetWorldPosition();
    let vp: Vector4 = veh.GetWorldPosition();
    if pp.Z >= vp.Z || vp.Z - pp.Z > 15.0 {
      return false;
    };
    let fw: Vector4 = veh.GetWorldForward();
    let fl: Float = MaxF(SqrtF(fw.X * fw.X + fw.Y * fw.Y), 0.05);
    let fx: Float = fw.X / fl;
    let fy: Float = fw.Y / fl;
    let dx: Float = pp.X - vp.X;
    let dy: Float = pp.Y - vp.Y;
    let lf: Float = dx * fx + dy * fy;
    let lr: Float = dx * fy - dy * fx;
    return lf < m.length * 0.5 + margin && lf > -(this.RearExt(m) + margin) && AbsF(lr) < m.width * 0.5 + margin;
  }

  // Build 19: angle from the hull's heading to the wanted heading h (rad, positive = turn right).
  private func HeadingErr(veh: ref<VehicleObject>, h: Vector4) -> Float {
    if AbsF(h.X) + AbsF(h.Y) < 0.01 {
      return 0.0;
    };
    let fw: Vector4 = veh.GetWorldForward();
    let fl: Float = MaxF(SqrtF(fw.X * fw.X + fw.Y * fw.Y), 0.05);
    let fx: Float = fw.X / fl;
    let fy: Float = fw.Y / fl;
    return AtanF(h.X * fy - h.Y * fx, h.X * fx + h.Y * fy);
  }

  // Build 19: touchdown by gear contact. A descent has been asked for (vz under -0.2 m/s) for 0.4 s, close to the
  // ground (under 3 m over the remembered resting height), and the hull has not sunk 1 cm for 0.12 s: it stands on
  // its gear, hand it back to the game now. Builds 8-18 waited for 4 cm over a remembered resting height that jumped
  // between landings (0.66 / 1.00 m): too high = let go and dropped, too low = pushed into the ground for 0.7 s
  // before the blocked test fired (the twitch V saw). Also down when it is 0.4 m under that resting height.
  private func ResetTouchdown() -> Void {
    this.m_tdOn = false;
    this.m_tdStall = 0.0;
    this.m_tdSteady = 0.0;
  }

  private func Touchdown(dt: Float, vzCmd: Float, h: Float, z: Float) -> Bool {
    // 3 m, like the old blocked test: the resting height of the bigger models was never measured (0.6 m assumed)
    if vzCmd > -0.2 || h > 3.0 {
      this.ResetTouchdown();
      return false;
    };
    this.m_tdSteady += dt;
    if h < -0.4 && this.m_tdSteady >= 0.2 {
      return true;
    };
    if !this.m_tdOn || z < this.m_tdRef - 0.01 {
      this.m_tdOn = true;
      this.m_tdRef = z;
      this.m_tdStall = 0.0;
      return false;
    };
    this.m_tdStall += dt;
    return this.m_tdSteady >= 0.4 && this.m_tdStall >= 0.12;
  }

  // Build 19 (2026-11-28): the front-left door (every charter model has it; DAV opened it the same way) opens when
  // V walks up to the aircraft and closes when V walks off; take-off and every unmanned flight close it.
  private func DoorState(veh: ref<VehicleObject>) -> VehicleDoorState {
    let ps: ref<VehicleComponentPS> = veh.GetVehiclePS();
    if !IsDefined(ps) {
      return VehicleDoorState.Closed;
    };
    return ps.GetDoorState(EVehicleDoor.seat_front_left);
  }

  private func SendDoor(veh: ref<VehicleObject>, open: Bool) -> Void {
    let ps: ref<VehicleComponentPS> = veh.GetVehiclePS();
    if !IsDefined(ps) {
      return;
    };
    if open {
      let evo: ref<VehicleDoorOpen> = new VehicleDoorOpen();
      evo.slotID = n"seat_front_left";
      evo.shouldAutoClose = false;
      evo.forceScene = false;
      GameInstance.GetPersistencySystem(this.m_gi).QueuePSEvent(ps.GetID(), ps.GetClassName(), evo);
    } else {
      let evc: ref<VehicleDoorClose> = new VehicleDoorClose();
      evc.slotID = n"seat_front_left";
      evc.forceScene = false;
      GameInstance.GetPersistencySystem(this.m_gi).QueuePSEvent(ps.GetID(), ps.GetClassName(), evc);
    };
    this.Log("door " + (open ? "opened" : "closed"));
  }

  private func CloseDoor(veh: ref<VehicleObject>) -> Void {
    if IsDefined(veh) && Equals(this.DoorState(veh), VehicleDoorState.Open) {
      this.SendDoor(veh, false);
    };
  }

  private func TickDoor(dt: Float, veh: ref<VehicleObject>, p: ref<PlayerPuppet>) -> Void {
    this.m_doorT -= dt;
    if this.m_doorT > 0.0 {
      return;
    };
    this.m_doorT = 0.25;
    if this.m_hoverOn || this.m_flight.engaged && Equals(this.m_flight.vehID, veh.GetEntityID()) {
      return;   // flying (held in the air or coming to V)
    };
    let e: Vector4 = this.LocalToWorld(veh, this.m_model.entry);
    let pp: Vector4 = p.GetWorldPosition();
    let d: Float = this.HDist(e, pp);
    let dz: Float = AbsF(e.Z - pp.Z);
    let st: VehicleDoorState = this.DoorState(veh);
    if d <= this.m_model.entryRadius + 2.5 && dz < 3.5 {
      if Equals(st, VehicleDoorState.Closed) {
        this.SendDoor(veh, true);
        this.m_doorT = 1.0;
      };
    } else {
      if (d > this.m_model.entryRadius + 4.0 || dz > 4.5) && Equals(st, VehicleDoorState.Open) {
        this.SendDoor(veh, false);
        this.m_doorT = 1.0;
      };
    };
  }

  private func TrySpawn() -> Void {
    this.EnsureRadio();
    let m: ref<AVFModel> = this.m_model;
    let spot: Vector4;
    let spotFwd: Vector4;
    if !this.FindSpot(m, spot, spotFwd) {
      if !this.m_noSpotNotified {
        this.m_hud.Message("Your " + m.name + " has no open landing zone near you. Get to open ground (hold " + this.CallKeyName() + " to cancel).", 6.0);
        this.m_noSpotNotified = true;
        this.Log("no landing spot near V");
      };
      this.m_retryAt = this.Now() + 4.0;
      return;
    };
    this.m_spot = spot;
    this.m_spotFwd = spotFwd;   // build 19: the heading it lands with (door side towards V)
    this.ResetTouchdown();
    // fly in from the depot side on a clear line, or come straight down from above
    let dx: Float = this.m_depot.X - spot.X;
    let dy: Float = this.m_depot.Y - spot.Y;
    let dl: Float = MaxF(SqrtF(dx * dx + dy * dy), 1.0);
    let base: Float = AtanF(dy / dl, dx / dl);
    let target: Vector4 = new Vector4(spot.X, spot.Y, spot.Z + 35.0, 1.0);
    let start: Vector4;
    let found: Bool = false;
    let tries: array<Float>;
    ArrayPush(tries, 0.0);
    ArrayPush(tries, 1.047);
    ArrayPush(tries, -1.047);
    ArrayPush(tries, 2.094);
    ArrayPush(tries, -2.094);
    let heights: array<Float>;
    ArrayPush(heights, 80.0);
    ArrayPush(heights, 120.0);
    ArrayPush(heights, 160.0);
    for t in tries {
      if found {
        break;
      };
      for h in heights {
        let s: Vector4 = new Vector4(spot.X + 180.0 * CosF(base + t), spot.Y + 180.0 * SinF(base + t), spot.Z + h, 1.0);
        let hit: TraceResult;
        if !this.Ray(s, target, hit) {
          start = s;
          found = true;
          break;
        };
      };
    };
    if found {
      this.m_phase = 0;
    } else {
      start = new Vector4(spot.X, spot.Y, spot.Z + 100.0, 1.0);
      this.m_phase = 1;
    };
    this.m_approach = target;
    this.m_glideZ0 = start.Z;
    this.m_glideD0 = MaxF(this.HDist(start, target), 1.0);
    let dir: Vector4 = new Vector4(target.X - start.X, target.Y - start.Y, 0.0, 0.0);
    if AbsF(dir.X) + AbsF(dir.Y) < 0.1 {
      dir = new Vector4(-dx, -dy, 0.0, 0.0);
    };
    let spec: ref<DynamicEntitySpec> = new DynamicEntitySpec();
    spec.recordID = m.record;
    spec.appearanceName = AVFParts.Livery(m.key, this.m_settings, m.appearance);
    spec.position = start;
    spec.orientation = EulerAngles.ToQuat(Vector4.ToRotation(dir));
    spec.persistState = false;
    spec.persistSpawn = false;
    spec.alwaysSpawned = true;
    ArrayPush(spec.tags, n"CyberslopAVFlight");
    this.m_avID = GameInstance.GetDynamicEntitySystem().CreateEntity(spec);
    this.m_state = AVFState.Arriving;
    this.m_phaseT = 0.0;
    this.m_spawnWait = 0.0;
    this.m_hud.Message("Your " + m.name + " is on final approach.", 4.0);
    this.Log("spawned " + m.name + (found ? " for a glide-in" : " for a vertical descent") + ", spot " + FloatToStringPrec(this.HDist(spot, this.Player().GetWorldPosition()), 0) + " m from V");
  }

  private func SendAway(why: String) -> Void {
    let veh: ref<VehicleObject> = this.AV();
    this.SettleBill(why);
    // no fly-out while the flight DLL is busy keeping the Night Hunter in the air (piloted or left hovering)
    if !IsDefined(veh) || IsDefined(this.m_pilotVeh) && this.m_isNH && this.m_airborne || this.m_hoverOn && this.m_hoverNH {
      this.Despawn();
      return;
    };
    this.EndHover(false, "sent away");   // a charter left hovering departs from where it is
    this.CloseDoor(veh);                 // build 19
    let pp: Vector4 = this.Player().GetWorldPosition();
    let vp: Vector4 = veh.GetWorldPosition();
    let dx: Float = this.m_depot.X - vp.X;
    let dy: Float = this.m_depot.Y - vp.Y;
    let dl: Float = SqrtF(dx * dx + dy * dy);
    if dl < 1.0 {
      dx = vp.X - pp.X;
      dy = vp.Y - pp.Y;
      dl = MaxF(SqrtF(dx * dx + dy * dy), 1.0);
    };
    this.m_departDir = new Vector4(dx / dl, dy / dl, 0.0, 0.0);
    this.m_state = AVFState.Departing;
    this.m_phase = 10;
    this.m_phaseT = 0.0;
    this.m_departTopZ = this.DepartTopAhead(vp, 500.0);
    this.m_departScanT = 0.0;
    this.m_departBlocked = false;
    this.m_departBlockedT = 0.0;
    this.Log("departure: tallest known column on the way out " + (this.m_departTopZ >= 0.0 ? FloatToStringPrec(this.m_departTopZ, 0) + " m, climbing to " + FloatToStringPrec(this.m_departTopZ + 25.0, 0) + " m" : "unknown, climbing to 60 m over the ground") + " (now " + FloatToStringPrec(vp.Z, 0) + " m)");
    if !this.m_flight.Bind(veh, this.m_model) {
      this.Despawn();
      return;
    };
    veh.TurnEngineOn(true);
    this.m_flight.Engage();
    this.Log("departing (" + why + ")");
  }

  // build 16: the reason (abandoned) goes in front of the bill, in one message
  private func SettleBill(why: String) -> Void {
    let pre: String = this.m_billPrefix;
    this.m_billPrefix = "";
    let text: String = this.SettleBillText(why);
    if StrLen(pre) > 0 || StrLen(text) > 0 {
      this.m_hud.Message(pre + text, StrLen(text) > 20 ? 7.0 : 5.0);
    };
  }

  // the bill as text ("" = nothing was open); charges the wallet
  private func SettleBillText(why: String) -> String {
    if !this.p_open {
      return "";
    };
    let due: Int32 = this.MeterCost();
    this.p_open = false;
    this.p_due = 0;
    let rentMin: Int32 = RoundF(this.m_rentS / 60.0);
    if due <= 0 {
      return "Charter closed.";
    };
    let paid: Int32 = this.TakeMoney(due, "AV charter " + this.m_model.name + " (flight)");
    let msg: String = "Charter settled: " + AVFSystem.Eddies(paid) + " eb (" + IntToString(rentMin) + " min, " + IntToString(RoundF(this.m_fuelL)) + " L fuel)";
    if paid < due {
      msg += ". " + AVFSystem.Eddies(due - paid) + " eb unpaid.";
    };
    this.Log("bill " + why + ": " + IntToString(paid) + " / " + IntToString(due) + " eb, " + FloatToStringPrec(this.m_rentS, 0) + " s, " + FloatToStringPrec(this.m_fuelL, 1) + " L");
    return msg;
  }

  private func MeterCost() -> Int32 {
    if !IsDefined(this.m_model) {
      return 0;
    };
    let rent: Float = this.m_rentS / 3600.0 * this.m_model.rentPerHour * this.m_settings.priceScale;
    return RoundF(rent + this.m_fuelL * this.m_settings.fuelPrice);
  }

  private func Despawn() -> Void {
    if this.m_hoverOn && !this.m_hoverNH {
      this.EndHover(false, "the charter is gone");
    };
    if this.m_flight.bound && Equals(this.m_flight.vehID, this.m_avID) {
      this.m_flight.Release();
    };
    if EntityID.IsDefined(this.m_avID) {
      GameInstance.GetDynamicEntitySystem().DeleteEntity(this.m_avID);
    };
    this.m_avID = new EntityID();
    this.m_state = AVFState.None;
    this.m_hud.Hide();
    this.Log("despawned");
  }

  private func DisableDoors(veh: ref<VehicleObject>) -> Void {
    let ps: ref<VehicleComponentPS> = veh.GetVehiclePS();
    if !IsDefined(ps) {
      return;
    };
    let i: Int32 = 0;
    while i < 6 {
      let evt: ref<VehicleDoorInteractionStateChange> = new VehicleDoorInteractionStateChange();
      evt.source = "CyberslopAVFlight";
      evt.door = IntEnum<EVehicleDoor>(i);
      evt.newState = VehicleDoorInteractionState.Disabled;
      GameInstance.GetPersistencySystem(this.m_gi).QueuePSEvent(ps.GetID(), ps.GetClassName(), evt);
      i += 1;
    };
  }

  // ---------------------------------------------------------------- boarding / mounting

  public func OnBoardPressed() -> Void {
    if NotEquals(this.m_state, AVFState.Parked) || this.PlayerInVehicle() {
      return;
    };
    let veh: ref<VehicleObject> = this.AV();
    let p: ref<PlayerPuppet> = this.Player();
    if !IsDefined(veh) || !IsDefined(p) || !this.NearEntry(veh, p) {
      return;
    };
    let seat: CName = this.ChosenSeat(this.m_model);
    let mountData: ref<MountEventData> = new MountEventData();
    mountData.isInstant = false;
    mountData.slotName = seat;
    mountData.mountParentEntityId = veh.GetEntityID();
    let slot: MountingSlotId;
    slot.id = seat;
    let info: MountingInfo;
    info.childId = p.GetEntityID();
    info.parentId = veh.GetEntityID();
    info.slotId = slot;
    let req: ref<MountingRequest> = new MountingRequest();
    req.lowLevelMountingInfo = info;
    req.mountData = mountData;
    GameInstance.GetMountingFacility(this.m_gi).Mount(req);
    this.Log("board " + NameToString(seat));
  }

  // Build 18: the seat from Mod Settings (2026-11-26, design goal: "always sits in the back right seat"). The flight input is raw
  // (Codeware key / axis callbacks), so V flies from any seat. Seat lists from DAV's model table: every charter has
  // all four seats except the Atlus (front left, back left, back right): front right falls back to the pilot seat there.
  private func ChosenSeat(m: ref<AVFModel>) -> CName {
    let s: AVFSeat = IsDefined(this.m_settings) ? this.m_settings.seat : AVFSeat.BackRight;
    if Equals(s, AVFSeat.FrontRight) {
      if IsDefined(m) && Equals(m.key, "atlus") {
        return n"seat_front_left";
      };
      return n"seat_front_right";
    };
    if Equals(s, AVFSeat.BackLeft) {
      return n"seat_back_left";
    };
    if Equals(s, AVFSeat.BackRight) {
      return n"seat_back_right";
    };
    return n"seat_front_left";
  }

  private func NearEntry(veh: ref<VehicleObject>, p: ref<PlayerPuppet>) -> Bool {
    let e: Vector4 = this.LocalToWorld(veh, this.m_model.entry);
    let pp: Vector4 = p.GetWorldPosition();
    return this.HDist(e, pp) <= this.m_model.entryRadius + 0.5 && AbsF(e.Z - pp.Z) < 3.5;
  }

  public func OnPlayerMounted(veh: ref<VehicleObject>, slot: CName) -> Void {
    this.Log("diag mounted " + TDBID.ToStringDEBUG(veh.GetRecordID()) + " slot " + NameToString(slot));
    // build 18: the charter is flown from whatever seat V boarded (Mod Settings "Your seat"); any other vehicle
    // (the Night Hunter) only from the driver seat, as before
    let charter: Bool = EntityID.IsDefined(this.m_avID) && Equals(veh.GetEntityID(), this.m_avID);
    if !charter && !Equals(slot, n"seat_front_left") {
      return;
    };
    this.EnsureRadio();
    if charter {
      // right-hand seats get out on the right: the exit point is mirrored (DAV's exit points are the left side)
      this.m_seatRight = Equals(slot, n"seat_front_right") || Equals(slot, n"seat_back_right");
      this.m_isNH = false;
      this.m_pilotModel = this.m_model;
      this.m_state = AVFState.Piloting;
      this.m_awayT = 0.0;
      this.m_engineOffT = 1.5;   // the mount starts the engine; it stays off until take-off
      if !this.m_mileageDone {
        let cb: ref<AVFMileageCall> = new AVFMileageCall();
        cb.gi = this.m_gi;
        GameInstance.GetDelaySystem(this.m_gi).DelayCallback(cb, 2.0, false);
        this.m_mileageDone = true;
      };
      this.BeginPilot(veh);
      if this.m_flight.engaged && Equals(this.m_flight.vehID, veh.GetEntityID()) {
        // boarded while the controller still flies it (left hovering, or not through Board): take over in the air
        this.EndHover(false, "boarded");
        this.m_airborne = true;
        this.m_airT = 0.0;
        this.SetBlocked(true);
        this.ShowHintsFor(2);
      };
      return;
    };
    let nh: ref<AVFModel> = this.NightHunterModel();
    if IsDefined(nh) && veh.GetRecordID() == nh.record && !this.m_settings.flyNightHunter {
      // build 17: the Night Hunter keeps its own hover-tank controls unless the setting is on
      this.Log("Night Hunter: flight controls off (Mod Settings), left to the vehicle");
      return;
    };
    if IsDefined(nh) && veh.GetRecordID() == nh.record {
      this.m_isNH = true;
      this.m_pilotModel = nh;
      this.BeginPilot(veh);
      if this.m_hoverOn && Equals(this.m_hoverID, veh.GetEntityID()) && this.m_flight.engaged && Equals(this.m_flight.vehID, veh.GetEntityID()) {
        // boarded the Night Hunter that was left hovering: take over in the air (m_nhRest is still its own)
        this.EndHover(false, "boarded");
        this.m_airborne = true;
        this.m_airT = 0.0;
        this.SetBlocked(true);
        this.ShowHintsFor(2);
      };
    };
  }

  private func BeginPilot(veh: ref<VehicleObject>) -> Void {
    this.m_pilotVeh = veh;
    this.m_pilotID = veh.GetEntityID();
    this.m_hadPilot = true;
    this.m_pilotT = 0.0;
    this.m_lostT = 0.0;
    this.m_airborne = false;
    this.m_takeoffT = 0.0;
    this.m_vSet = 0.0;
    this.m_steer = 0.0;
    this.m_lift = 0.0;
    this.m_volSent = -100.0;
    this.m_thrustSent = -1.0;
    this.m_input.StartPilot();
    this.ShowHintsFor(1);
    this.StartTick();
    this.Log("pilot seat: " + this.m_pilotModel.name);
    this.m_domeOn = false;
    this.m_domeT = (!this.m_isNH && this.m_settings.crystalDome && AVFParts.HasDome(this.m_pilotModel.key)) ? 3.0 : 0.0;
    this.m_apLatch = false;
    this.m_auto.Stop();
  }

  public func InCharterSeat() -> Bool {
    return IsDefined(this.m_pilotVeh) && !this.m_isNH;
  }

  public func OnPlayerUnmounted(veh: ref<VehicleObject>) -> Void {
    let pv: ref<VehicleObject> = this.m_pilotVeh;
    if !IsDefined(pv) || !Equals(pv.GetEntityID(), veh.GetEntityID()) {
      return;
    };
    this.m_input.StopPilot();
    this.m_hadPilot = false;
    this.m_auto.Stop();
    this.m_domeT = 0.0;
    if this.m_domeOn {
      AVFParts.SetDome(this.m_gi, veh, false);
      this.m_domeOn = false;
    };
    let wasAirborne: Bool = this.m_airborne;
    let holds: Bool = false;
    if this.m_airborne {
      // only possible with "Allow getting out in the air" or a forced exit. V, 2026-11-23: the aircraft must stay
      // in the air, not drop: the controller keeps flying it unmanned, stops it and holds the position
      this.m_airborne = false;
      holds = this.StartHover(veh, this.m_pilotModel, this.m_isNH);
      if !holds {
        this.m_flight.Disengage();
      };
    };
    this.SetBlocked(false);
    this.m_pilotVeh = null;
    if this.m_isNH {
      if !holds && this.m_flight.bound && Equals(this.m_flight.vehID, veh.GetEntityID()) {
        this.m_flight.Release();
      };
      this.m_hud.Hide();
      if holds {
        this.m_hud.Message("The Night Hunter holds its position. Bring it to you: double tap " + this.KeyLabel(this.m_settings.keyCall) + ".", 5.0);
      };
      this.Log("left the Night Hunter" + (holds ? " in the air" : ""));
      return;
    };
    if Equals(this.m_state, AVFState.Piloting) {
      this.m_state = AVFState.Parked;
      // build 19: in the air too: the game's exit left V standing on the roof of the holding aircraft (2026-11-28),
      // now V is put beside the hull and falls from there (TickParked)
      this.m_exitTeleport = true;
      this.m_exitAir = wasAirborne;
      this.m_restMeasureT = wasAirborne ? 0.0 : 1.5;
      this.m_awayT = 0.0;
      if holds {
        this.m_hud.Message("Your " + this.m_model.name + " holds its position. Bring it to you: double tap " + this.KeyLabel(this.m_settings.keyCall) + ". Send away: hold " + this.CallKeyName() + ".", 6.0);
      };
      this.Log("left the AV" + (wasAirborne ? (holds ? " in the air" : " in the air, no hover hold") : ""));
    };
  }

  // ---------------------------------------------------------------- hover hold

  private func StartHover(veh: ref<VehicleObject>, model: ref<AVFModel>, isNH: Bool) -> Bool {
    if !IsDefined(veh) || !IsDefined(model) || veh.IsDestroyed() || !this.m_flight.bound || !this.m_flight.engaged || !Equals(this.m_flight.vehID, veh.GetEntityID()) {
      return false;
    };
    this.m_hoverOn = true;
    this.m_hoverVeh = veh;
    this.m_hoverID = veh.GetEntityID();
    this.m_hoverModel = model;
    this.m_hoverNH = isNH;
    this.m_hoverChkT = 0.0;
    this.m_hoverLand = false;
    this.Log("hover hold: " + model.name + " at " + FloatToStringPrec(this.m_flight.speed * 3.6, 0) + " km/h, " + (this.m_flight.aglValid ? FloatToStringPrec(this.m_flight.agl, 0) + " m over the ground" : "no ground below"));
    return true;
  }

  // drop = back on the game's physics (it falls). Otherwise whoever takes the aircraft over keeps it engaged.
  private func EndHover(drop: Bool, why: String) -> Void {
    if !this.m_hoverOn {
      return;
    };
    this.m_hoverOn = false;
    this.m_hoverVeh = null;
    if this.m_hoverLand {
      this.m_hoverLand = false;
      this.m_auto.Stop();
    };
    if drop && this.m_flight.bound && Equals(this.m_flight.vehID, this.m_hoverID) {
      this.m_flight.Disengage();
      if this.m_hoverNH {
        this.m_flight.Release();
      };
    };
    this.Log("hover hold over: " + why + (drop ? " (back on game physics)" : ""));
  }

  private func TickHover(dt: Float) -> Void {
    if !this.m_hoverOn {
      return;
    };
    let veh: ref<VehicleObject> = this.m_hoverVeh;
    if !IsDefined(veh) {
      // streamed out or deleted
      if this.m_flight.bound && Equals(this.m_flight.vehID, this.m_hoverID) {
        this.m_flight.Release();
      };
      this.EndHover(false, "the aircraft is gone");
      return;
    };
    if !this.m_flight.bound || !this.m_flight.engaged || !Equals(this.m_flight.vehID, this.m_hoverID) || !this.m_hoverNH && NotEquals(this.m_state, AVFState.Parked) {
      this.EndHover(false, "flight control is no longer on it");
      return;
    };
    if veh.IsDestroyed() {
      this.EndHover(true, "destroyed");
      return;
    };
    let m: ref<AVFModel> = this.m_hoverModel;
    let cmd: ref<AVFCmd> = this.m_cmd;
    // stop as quickly as with V on board (hover brake, V's vertical speed setting), then hold the altitude
    this.m_flight.vScale = Cast<Float>(this.m_settings.verticalSpeed) / 100.0;
    this.m_flight.UpdateAGL(dt, false);
    if this.m_hoverLand && !this.m_auto.on {
      // V sat down in another aircraft: its pilot seat reset the (single) autopilot
      this.m_hoverLand = false;
      this.Log("hover landing dropped: the autopilot was reset");
    };
    let restH: Float = this.m_hoverNH ? this.m_nhRest : this.m_restAGL;
    if this.m_hoverLand {
      let vsL: Float = this.m_flight.vScale;
      let res: Int32 = this.m_auto.Step(dt, veh, m, this.m_flight, cmd, MinF(MinF(Cast<Float>(this.m_settings.autopilotSpeed) / 3.6, 30.0), this.VmaxEff(m)), restH, vsL);
      if StrLen(this.m_auto.note) > 0 {
        this.Log(this.m_auto.note);
      };
      if res == 2 {
        this.m_hoverLand = false;
        this.m_auto.Stop();
        this.m_hud.Message("Landing called off, your " + m.name + " holds its position. " + this.m_auto.reason, 6.0);
        this.Log("hover landing called off: " + this.m_auto.reason);
      } else {
        // never come down on V: wait above while V stands under the hull. Build 19: the hull's real outline + 1 m
        // (the old circle of half the length + 2 m would have stopped every landing 3 m from V's feet)
        if this.m_auto.Descending() && cmd.vz < 0.0 && this.VUnderHull(veh, m, 1.0) {
          cmd.vz = 0.0;
        };
      };
    };
    if !this.m_hoverLand {
      cmd.vf = 0.0;
      cmd.vl = 0.0;
      cmd.vz = 0.0;
      cmd.yaw = 0.0;
      cmd.holdAlt = true;
      cmd.brakeBoost = true;
    };
    this.m_flight.Step(dt, cmd, this.VmaxEff(m));
    if this.m_flight.unresolvedT > 4.0 || this.m_flight.tumbleT > 2.0 {
      this.EndHover(true, this.m_flight.unresolvedT > 4.0 ? "the physics body never resolved" : "the aircraft tumbled");
      return;
    };
    if !this.m_hoverNH {
      this.m_fuelL += LerpF(this.m_flight.powerFrac, m.burnHover, m.burnMax) / 60.0 * dt;
    };
    // touchdown when it comes to V. Build 19: the charter by gear contact (Touchdown); the Night Hunter (a hover tank
    // that floats on its springs) keeps the old test (resting height, contact flag near the ground, blocked descent)
    if this.m_hoverLand {
      let h: Float = this.m_flight.aglValid ? this.m_flight.agl - restH : 50.0;
      let down: Bool = this.m_auto.Descending();
      let z: Float = veh.GetWorldPosition().Z;
      let landed: Bool;
      if this.m_hoverNH {
        this.BlockedDescent(dt, down && cmd.vz < 0.0 && h < 3.0, z);
        landed = down && (h < 0.3 || this.m_flight.IsOnGround() && h < 0.15 || this.m_blockT > 0.7);
      } else {
        landed = this.Touchdown(dt, (down && !cmd.holdAlt) ? cmd.vz : 0.0, h, z);
      };
      if landed && this.m_flight.vzNow > -1.5 && AbsF(this.m_flight.vfNow) < 1.5 {
        this.Log("touchdown: " + FloatToStringPrec(h, 2) + " m over the resting height " + FloatToStringPrec(restH, 2) + " m");
        this.ResetTouchdown();
        this.HoverLanded(veh);
        return;
      };
    };
    // the game switches the vehicle and its engine off when the driver gets out: a hovering aircraft keeps running
    this.m_hoverChkT -= dt;
    if this.m_hoverChkT <= 0.0 {
      this.m_hoverChkT = 0.25;
      if !veh.IsEngineTurnedOn() {
        veh.TurnVehicleOn(true);
        veh.TurnEngineOn(true);
        this.m_thrustSent = -1.0;
      };
    };
  }

  private func HoverLanded(veh: ref<VehicleObject>) -> Void {
    let nh: Bool = this.m_hoverNH;
    let m: ref<AVFModel> = this.m_hoverModel;
    this.m_blockT = 0.0;
    this.EndHover(false, "landed");
    this.m_flight.Disengage();
    this.Param(veh, n"v_av_panzer_thrust", 0.0);
    this.Param(veh, n"v_av_panzer_speed", 0.0);
    this.Param(veh, n"v_av_panzer_rotation_speed", 0.0);
    this.m_thrustSent = 0.0;
    this.m_speedSent = 0.0;
    this.m_rotSent = 0.0;
    veh.TurnEngineOn(false);
    if nh {
      this.m_flight.Release();
      veh.TurnVehicleOn(false);
      this.m_hud.Message("The Night Hunter has landed.", 4.0);
    } else {
      this.m_restMeasureT = 1.5;
      this.m_awayT = 0.0;
      this.m_doorT = 0.0;   // build 19: the door opens at once when V stands next to it
      this.m_hud.Message("Your " + m.name + " has landed. Board: " + this.KeyLabel(this.m_settings.keyBoard) + " at the door. Send away: hold " + this.CallKeyName() + ".", 6.0);
    };
    this.Log("fetch: " + m.name + " landed");
  }

  // Exit blocked + saving locked while airborne (an autosave in the air would load V without the aircraft).
  private func SetBlocked(on: Bool) -> Void {
    let p: ref<PlayerPuppet> = this.Player();
    if Equals(on, this.m_blocked) {
      return;
    };
    if on && !IsDefined(p) {
      return;
    };
    this.m_blocked = on;
    if on {
      if !this.m_settings.exitInAir {
        StatusEffectHelper.ApplyStatusEffect(p, t"GameplayRestriction.VehicleBlockExit");
      };
      SaveLocksManager.RequestSaveLockAdd(this.m_gi, n"CyberslopAVFlight");
    } else {
      // the save lock never depends on the player object: it must always come off
      if IsDefined(p) {
        StatusEffectHelper.RemoveStatusEffect(p, t"GameplayRestriction.VehicleBlockExit");
      };
      SaveLocksManager.RequestSaveLockRemove(this.m_gi, n"CyberslopAVFlight");
    };
  }

  // The piloted vehicle went away without an unmount event (deleted, streamed out, V pulled out by a scene,
  // a teleport or death): same cleanup as an unmount, so the save lock and the exit block never stay behind.
  private func PilotLost(why: String) -> Void {
    this.m_hadPilot = false;
    this.m_input.StopPilot();
    // only the piloted aircraft's own binding: the controller may be holding another aircraft in a hover
    if this.m_flight.bound && Equals(this.m_flight.vehID, this.m_pilotID) {
      let holds: Bool = false;
      if this.m_airborne {
        holds = this.StartHover(this.m_pilotVeh, this.m_pilotModel, this.m_isNH);
        if !holds {
          this.m_flight.Disengage();
        };
      };
      if this.m_isNH && !holds {
        this.m_flight.Release();
      };
    };
    this.m_airborne = false;
    this.SetBlocked(false);
    this.m_pilotVeh = null;
    if !this.m_isNH && Equals(this.m_state, AVFState.Piloting) {
      this.m_state = AVFState.Parked;
      this.m_exitTeleport = false;
      this.m_restMeasureT = 0.0;
    };
    this.m_hud.Hide();
    this.m_auto.Stop();
    this.m_domeT = 0.0;
    this.m_domeOn = false;
    this.Log("pilot seat lost: " + why);
  }

  // ---------------------------------------------------------------- tick

  public func Tick(gen: Int32) -> Void {
    if !this.m_ticking || gen != this.m_tickGen {
      return;
    };
    let now: Float = this.Now();
    let et: EngineTime = GameInstance.GetSimTime(this.m_gi);
    let dt: Float = ClampF(EngineTime.ToFloat(et - this.m_lastET), 0.0, this.IdleTick() ? 0.5 : 0.1);
    this.m_lastET = et;
    this.m_lastTime = now;
    this.m_tickN += 1;
    this.m_tickLogT += dt;
    if this.m_tickN == 1 || this.m_tickLogT >= 5.0 {
      this.m_tickLogT = 0.0;
      this.Log("diag3 tick n=" + IntToString(this.m_tickN) + " state=" + IntToString(EnumInt(this.m_state)) + " dt=" + FloatToStringPrec(dt, 4) + " eta in " + FloatToStringPrec(this.m_etaAt - now, 1) + " inVehicle=" + ToString(this.PlayerInVehicle()));
    };
    if dt > 0.0 {
      this.TickCharter(dt, now);
      this.TickPilot(dt, now);
      this.TickHover(dt);
      this.m_hud.Age(dt);
      this.TickHud(dt, now);
      this.TickAudio(dt);
      if this.m_flight.bound {
        this.m_flight.Heartbeat(dt);
      };
    };
    if this.NeedsTick() {
      this.QueueTick();
    } else {
      this.m_ticking = false;
      this.m_hud.Hide();
    };
  }

  private func TickCharter(dt: Float, now: Float) -> Void {
    let veh: ref<VehicleObject>;
    switch this.m_state {
      case AVFState.EnRoute:
        if now >= this.m_etaAt && now >= this.m_retryAt {
          if this.PlayerInVehicle() {
            // never land next to a moving car (or while the Night Hunter holds the flight DLL)
            if !this.m_holdNotified {
              this.m_hud.Message("Your " + this.m_model.name + " is holding until you are on foot.", 4.0);
              this.m_holdNotified = true;
              this.Log("holding: V is in a vehicle");
            };
            this.m_retryAt = now + 3.0;
          } else {
            this.TrySpawn();
          };
        };
        break;
      case AVFState.Arriving:
        veh = this.AV();
        if !IsDefined(veh) {
          this.m_spawnWait += dt;
          if this.m_spawnWait > 15.0 {
            this.Log("AV never streamed in; refunding the call");
            GameInstance.GetTransactionSystem(this.m_gi).GiveItem(this.Player(), MarketSystem.Money(), this.m_quoteCost);
            this.p_open = false;
            this.Despawn();
          };
          return;
        };
        if this.CheckWreck(veh) {
          return;
        };
        if !this.m_flight.bound || !Equals(this.m_flight.vehID, this.m_avID) {
          if IsDefined(this.m_pilotVeh) && this.m_airborne {
            return;   // the DLL is flying the Night Hunter right now
          };
          // one flight controller: a Night Hunter left hovering comes down when the charter needs it
          this.EndHover(true, "the charter needs flight control");
          this.m_flight.Bind(veh, this.m_model);
          this.DisableDoors(veh);
          this.Log("parts placed: " + IntToString(AVFParts.Apply(veh, this.m_model.key)));
          this.m_partsT = 1.0;
          veh.TurnEngineOn(true);
          this.m_flight.Engage();
          this.m_volSent = -100.0;
        };
        if this.m_partsT > 0.0 {
          this.m_partsT -= dt;
          if this.m_partsT <= 0.0 {
            AVFParts.Apply(veh, this.m_model.key);
          };
        };
        this.AutoArrive(dt, veh);
        break;
      case AVFState.Parked:
        veh = this.AV();
        if !IsDefined(veh) {
          this.SettleBill("aircraft lost");
          this.Despawn();
          return;
        };
        if this.CheckWreck(veh) {
          return;
        };
        this.m_rentS += dt;
        this.TickParked(dt, veh);
        break;
      case AVFState.Piloting:
        veh = this.AV();
        if IsDefined(veh) && this.CheckWreck(veh) {
          return;
        };
        this.m_rentS += dt;
        if !this.m_airborne {
          this.MeasureRest(dt);
        };
        break;
      case AVFState.Departing:
        veh = this.AV();
        if !IsDefined(veh) {
          this.Despawn();
          return;
        };
        this.AutoDepart(dt, veh);
        break;
      case AVFState.Wreck:
        this.m_wreckT += dt;
        veh = this.AV();
        if !IsDefined(veh) {
          this.Despawn();
        } else {
          // never delete the wreck with V still inside it
          if !this.InCharterSeat() && (this.m_wreckT > 120.0 || this.HDist(veh.GetWorldPosition(), this.Player().GetWorldPosition()) > 150.0) {
            this.Despawn();
          };
        };
        break;
      default:
        break;
    };
    // the open meter goes into the save once a second
    if this.p_open {
      this.m_saveT -= dt;
      if this.m_saveT <= 0.0 {
        this.m_saveT = 1.0;
        this.p_due = this.MeterCost();
      };
    };
  }

  private func CheckWreck(veh: ref<VehicleObject>) -> Bool {
    if !veh.IsDestroyed() {
      return false;
    };
    if this.m_flight.bound && Equals(this.m_flight.vehID, this.m_avID) {
      this.m_flight.Release();
    };
    this.SetBlocked(false);
    let bill: String = this.SettleBillText("destroyed");
    if this.m_settings.liability && IsDefined(this.m_model) {
      let ded: Int32 = RoundF(this.m_model.hullValue * 0.1);
      let paid: Int32 = this.TakeMoney(ded, "AV charter " + this.m_model.name + " (deductible)");
      this.m_hud.Message("Charter aircraft destroyed. Insurance deductible: " + AVFSystem.Eddies(paid) + " eb." + (StrLen(bill) > 0 ? " " + bill : ""), 8.0);
      this.Log("destroyed, deductible " + IntToString(paid));
    } else {
      if StrLen(bill) > 0 {
        this.m_hud.Message("Charter aircraft destroyed. " + bill, 7.0);
      };
    };
    this.m_state = AVFState.Wreck;
    this.m_wreckT = 0.0;
    return true;
  }

  private func TickParked(dt: Float, veh: ref<VehicleObject>) -> Void {
    let p: ref<PlayerPuppet> = this.Player();
    if !IsDefined(p) {
      return;
    };
    // after getting out: stand V at the aircraft's exit point (DAV's exit), once the unmount is done
    if this.m_exitTeleport && !VehicleComponent.IsMountedToVehicle(this.m_gi, p) {
      this.m_exitTeleport = false;
      let exLocal: Vector3 = this.m_model.exitPoint;
      if this.m_exitAir {
        // build 19: out in the air: beside the hull and clear of it (DAV's exit point is under the wing on the
        // wider models), at the bottom of the hull; V falls from there instead of standing on the roof
        exLocal = new Vector3(-(this.m_model.width * 0.5 + 1.3), 0.0, MinF(exLocal.Z, 0.0));
      };
      if this.m_seatRight {
        exLocal = new Vector3(-exLocal.X, exLocal.Y, exLocal.Z);
      };
      let ex: Vector4 = this.LocalToWorld(veh, exLocal);
      let rot: EulerAngles = veh.GetWorldOrientation().ToEulerAngles();
      let face: EulerAngles;
      face.Yaw = this.m_seatRight ? rot.Yaw - 90.0 : rot.Yaw + 90.0;
      GameInstance.GetTeleportationFacility(this.m_gi).Teleport(p, ex, face);
      if this.m_exitAir {
        this.Log("out in the air: V dropped beside the hull, " + (this.m_flight.aglValid ? FloatToStringPrec(this.m_flight.agl, 0) + " m over the ground" : "no ground below"));
      };
      this.m_exitAir = false;
    };
    this.MeasureRest(dt);
    this.TickDoor(dt, veh, p);
    let d: Float = this.HDist(veh.GetWorldPosition(), p.GetWorldPosition());
    if this.m_hoverLand {
      this.m_awayT = 0.0;   // build 19: on its way to V
    } else if d > 150.0 && !VehicleComponent.IsMountedToVehicle(this.m_gi, p) || d > 600.0 {
      this.m_awayT += dt;
      if this.m_awayT > 60.0 {
        this.m_billPrefix = "Your charter left after waiting a minute without you. ";
        this.SendAway("abandoned");
      };
    } else {
      this.m_awayT = 0.0;
    };
  }

  // Resting height of this aircraft over the ground below it, measured once it has settled on its gear
  // (1.5 s after a landing). The touchdown test and the flare use it.
  private func MeasureRest(dt: Float) -> Void {
    if this.m_restMeasureT <= 0.0 {
      return;
    };
    this.m_restMeasureT -= dt;
    if this.m_restMeasureT > 0.0 {
      return;
    };
    if this.m_flight.bound && Equals(this.m_flight.vehID, this.m_avID) && !this.m_flight.engaged {
      this.m_flight.UpdateAGL(dt, true);
      if this.m_flight.aglValid {
        // only a plausible value: standing on a car or a kerb must not move the touchdown height
        // (18:44: 1.72 m after a landing on something, and the next landing was handed back 1.1 m up)
        if this.m_flight.agl > 0.2 && this.m_flight.agl < 1.5 {
          this.m_restAGL = this.m_flight.agl;
          this.Log("rest height " + FloatToStringPrec(this.m_restAGL, 2) + " m");
        } else {
          this.Log("rest height " + FloatToStringPrec(this.m_flight.agl, 2) + " m ignored, kept " + FloatToStringPrec(this.m_restAGL, 2));
        };
      };
    };
  }

  // ---------------------------------------------------------------- auto flights

  private func AutoArrive(dt: Float, veh: ref<VehicleObject>) -> Void {
    let m: ref<AVFModel> = this.m_model;
    let cmd: ref<AVFCmd> = this.m_cmd;
    this.m_flight.vScale = 1.0;   // the unmanned flights keep the aircraft's own vertical rates
    let pos: Vector4 = veh.GetWorldPosition();
    let fwd: Vector4 = veh.GetWorldForward();
    let fl: Float = MaxF(SqrtF(fwd.X * fwd.X + fwd.Y * fwd.Y), 0.05);
    let fx: Float = fwd.X / fl;
    let fy: Float = fwd.Y / fl;
    this.m_phaseT += dt;
    this.m_flight.UpdateAGL(dt, false);
    cmd.brakeBoost = false;
    if this.m_phase == 0 {
      let dx: Float = this.m_approach.X - pos.X;
      let dy: Float = this.m_approach.Y - pos.Y;
      let dh: Float = SqrtF(dx * dx + dy * dy);
      let dF: Float = dx * fx + dy * fy;
      let dR: Float = dx * fy - dy * fx;
      let ang: Float = AtanF(dR, dF);
      let s: Float = MinF(MinF(40.0, this.VmaxEff(m) * 0.5), SqrtF(2.0 * 0.6 * m.brake * MaxF(dh - 2.0, 0.0)));
      cmd.vf = s * MaxF(0.0, CosF(ang));
      cmd.vl = 0.0;
      cmd.yaw = ClampF(1.5 * ang, -m.yawRate, m.yawRate);
      cmd.holdAlt = false;
      // stay on the straight line from the spawn point to the approach point: that line was ray-checked
      let zLine: Float = this.m_approach.Z + (this.m_glideZ0 - this.m_approach.Z) * ClampF(dh / this.m_glideD0, 0.0, 1.0);
      cmd.vz = ClampF(0.8 * (zLine - pos.Z), -m.descent, m.climb * 0.6);
      if dh < 4.0 && this.m_flight.speed < 2.5 || this.m_phaseT > 90.0 {
        this.m_phase = 1;
        this.m_phaseT = 0.0;
      };
    } else {
      let ex: Float = this.m_spot.X - pos.X;
      let ey: Float = this.m_spot.Y - pos.Y;
      cmd.vf = ClampF(0.6 * (ex * fx + ey * fy), -3.0, 3.0);
      cmd.vl = ClampF(0.6 * (ex * fy - ey * fx), -3.0, 3.0);
      // build 19: turn to the landing heading (door side towards V) on the way down, done before 8 m
      let herr: Float = this.HeadingErr(veh, this.m_spotFwd);
      cmd.yaw = ClampF(1.5 * herr, -m.yawRate, m.yawRate);
      cmd.holdAlt = false;
      let h: Float = this.m_flight.aglValid ? this.m_flight.agl - this.m_restAGL : 20.0;
      // build 19: a steady 0.4 m/s at the end (was 0.15), touchdown by gear contact (Touchdown)
      cmd.vz = -MaxF(0.4, MinF(m.descent * 0.7, 0.45 * h));
      if AbsF(herr) > 0.14 && h < 8.0 {
        cmd.vz = ClampF(0.8 * (8.0 - h), 0.0, 2.0);   // still turning: not lower than 8 m, the hull would sweep over V
      };
      if cmd.vz < 0.0 && this.VUnderHull(veh, m, 1.0) {
        cmd.vz = 0.0;   // never come down on V
      };
      if this.m_phaseT > 60.0 && h > 3.0 {
        this.AbortArrival("the descent timed out " + FloatToStringPrec(h, 0) + " m above the ground");
        return;
      };
      if this.m_phaseT > 1.0 && this.Touchdown(dt, cmd.vz, h, pos.Z) || this.m_phaseT > 60.0 && !this.VUnderHull(veh, m, 0.5) {
        this.Log("touchdown: " + FloatToStringPrec(h, 2) + " m over the resting height " + FloatToStringPrec(this.m_restAGL, 2) + " m, heading off by " + FloatToStringPrec(AbsF(herr) * 57.3, 0) + " deg");
        this.ResetTouchdown();
        this.m_blockT = 0.0;
        this.m_flight.Disengage();
        veh.TurnEngineOn(false);
        this.m_state = AVFState.Parked;
        this.m_restMeasureT = 1.5;
        this.m_awayT = 0.0;
        this.m_doorT = 0.0;
        this.m_hud.Message("Your " + m.name + " has landed. Board: " + this.KeyLabel(this.m_settings.keyBoard) + " at the door. Send away: hold " + this.CallKeyName() + ".", 6.0);
        this.Log("landed for V after " + FloatToStringPrec(this.m_phaseT, 1) + " s descent");
        return;
      };
    };
    this.m_flight.Step(dt, cmd, this.VmaxEff(m));
    // watchdog for the unmanned approach: no physics body or a tumble -> abort, refund, never drop a wreck on V
    if this.m_flight.unresolvedT > 4.0 || this.m_flight.tumbleT > 2.0 {
      this.AbortArrival(this.m_flight.unresolvedT > 4.0 ? "the physics body never resolved" : "the aircraft tumbled");
    };
  }

  // Blocked descent, by height: sinking is asked and the height has not dropped 5 cm for m_blockT seconds.
  // By height, not by speed: in DLL mode 2 the measured speed can be the speed that was just written.
  private func BlockedDescent(dt: Float, active: Bool, z: Float) -> Void {
    if !active {
      this.m_blockOn = false;
      this.m_blockT = 0.0;
      return;
    };
    if !this.m_blockOn || this.m_blockZ - z > 0.05 {
      this.m_blockOn = true;
      this.m_blockZ = z;
      this.m_blockT = 0.0;
      return;
    };
    this.m_blockT += dt;
  }

  private func AbortArrival(why: String) -> Void {
    this.Log("arrival aborted: " + why + "; call refunded");
    let p: ref<PlayerPuppet> = this.Player();
    if IsDefined(p) {
      GameInstance.GetTransactionSystem(this.m_gi).GiveItem(p, MarketSystem.Money(), this.m_quoteCost);
    };
    this.p_open = false;
    this.m_hud.Message("Your charter aborted its approach (flight control fault). The call was refunded.", 6.0);
    this.Despawn();
  }

  // build 15: top of the tallest known building column (height map, world Z) along the departure line from pos,
  // three lanes 15 m apart, every 20 m from 20 m to ahead m. -1 = nothing known there.
  private func DepartTopAhead(pos: Vector4, ahead: Float) -> Float {
    if !IsDefined(this.m_departMap) {
      this.m_departMap = new AVFHeights();
    };
    let top: Float = -1.0;
    let k: Int32 = -1;
    while k <= 1 {
      let off: Float = Cast<Float>(k) * 15.0;
      let d: Float = 20.0;
      while d <= ahead {
        top = MaxF(top, this.m_departMap.At(pos.X + this.m_departDir.X * d - this.m_departDir.Y * off, pos.Y + this.m_departDir.Y * d + this.m_departDir.X * off));
        d += 20.0;
      };
      k += 1;
    };
    return top;
  }

  private func AutoDepart(dt: Float, veh: ref<VehicleObject>) -> Void {
    let m: ref<AVFModel> = this.m_model;
    let cmd: ref<AVFCmd> = this.m_cmd;
    this.m_flight.vScale = 1.0;
    let fwd: Vector4 = veh.GetWorldForward();
    let fl: Float = MaxF(SqrtF(fwd.X * fwd.X + fwd.Y * fwd.Y), 0.05);
    let fx: Float = fwd.X / fl;
    let fy: Float = fwd.Y / fl;
    this.m_phaseT += dt;
    this.m_flight.UpdateAGL(dt, false);
    cmd.brakeBoost = false;
    cmd.vl = 0.0;
    let pos: Vector4 = veh.GetWorldPosition();
    let climbV: Float = MinF(m.climb * 0.6, 6.0);
    if this.m_phase == 10 {
      cmd.vf = 0.0;
      cmd.yaw = 0.0;
      cmd.holdAlt = false;
      cmd.vz = climbV;
      // build 15: also clear the tallest known building on the way out (+ 25 m); time limit grows with the climb
      let clearZ: Float = this.m_departTopZ >= 0.0 ? this.m_departTopZ + 25.0 : -10000.0;
      let limitT: Float = 14.0;
      if clearZ > pos.Z {
        limitT = ClampF((clearZ - pos.Z) / MaxF(climbV, 1.0) + 6.0, 14.0, 60.0);
      };
      if this.m_flight.agl > 60.0 && pos.Z >= clearZ || this.m_phaseT > limitT {
        this.Log("departure: climb done at " + FloatToStringPrec(pos.Z, 0) + " m (" + FloatToStringPrec(this.m_phaseT, 1) + " s), heading out");
        this.m_phase = 11;
        this.m_phaseT = 0.0;
      };
    } else {
      // build 15: every 0.5 s look 150 m ahead; a known building less than 20 m under the hull = stop and climb
      this.m_departScanT -= dt;
      if this.m_departScanT <= 0.0 {
        this.m_departScanT = 0.5;
        let top: Float = this.DepartTopAhead(pos, 150.0);
        let blocked: Bool = top >= 0.0 && top + 20.0 > pos.Z;
        if blocked && !this.m_departBlocked {
          this.Log("departure: building ahead (top " + FloatToStringPrec(top, 0) + " m, AV at " + FloatToStringPrec(pos.Z, 0) + " m), climbing first");
        };
        this.m_departBlocked = blocked;
      };
      if this.m_departBlocked && this.m_departBlockedT < 30.0 {
        this.m_departBlockedT += dt;
        this.m_phaseT -= dt;   // the 10 s fly-out starts again once the way is clear
      } else {
        this.m_departBlocked = false;
      };
    };
    if this.m_phase == 11 && this.m_departBlocked {
      cmd.vf = 0.0;
      cmd.yaw = 0.0;
      cmd.holdAlt = false;
      cmd.vz = climbV;
    } else if this.m_phase == 11 {
      let dF: Float = this.m_departDir.X * fx + this.m_departDir.Y * fy;
      let dR: Float = this.m_departDir.X * fy - this.m_departDir.Y * fx;
      let ang: Float = AtanF(dR, dF);
      cmd.yaw = ClampF(1.5 * ang, -m.yawRate, m.yawRate);
      cmd.vf = MinF(45.0, this.VmaxEff(m)) * MaxF(0.0, CosF(ang));
      cmd.holdAlt = false;
      cmd.vz = 2.0;
      let p: ref<PlayerPuppet> = this.Player();
      if this.m_phaseT > 10.0 || IsDefined(p) && this.HDist(veh.GetWorldPosition(), p.GetWorldPosition()) > 350.0 {
        this.Despawn();
        return;
      };
    };
    this.m_flight.Step(dt, cmd, this.VmaxEff(m));
    if this.m_flight.unresolvedT > 4.0 || this.m_flight.tumbleT > 2.0 {
      this.Log("departure aborted (flight control fault): despawned");
      this.Despawn();
    };
  }

  // ---------------------------------------------------------------- piloting

  private func Expo(v: Float, dead: Float, e: Float) -> Float {
    let a: Float = AbsF(v);
    if a <= dead {
      return 0.0;
    };
    let n: Float = (a - dead) / (1.0 - dead);
    let r: Float = PowF(n, e);
    return v < 0.0 ? -r : r;
  }

  private func LeverStep(v: Float) -> Float {
    return AbsF(v) < 8.4 ? 1.389 : 2.778;   // a tap: 5 km/h below 30 km/h, 10 km/h above
  }

  private func TickPilot(dt: Float, now: Float) -> Void {
    let veh: ref<VehicleObject> = this.m_pilotVeh;
    if !IsDefined(veh) {
      if this.m_hadPilot {
        this.PilotLost("the vehicle is gone");
      };
      return;
    };
    // V no longer mounted for a full second (after the boarding animation): the unmount event was missed
    this.m_pilotT += dt;
    if this.m_pilotT > 4.0 && !this.PlayerInVehicle() {
      this.m_lostT += dt;
      if this.m_lostT > 1.0 {
        this.PilotLost("V is not in a vehicle any more");
        return;
      };
    } else {
      this.m_lostT = 0.0;
    };
    if veh.IsDestroyed() {
      if this.m_airborne {
        this.m_flight.Disengage();
        this.m_airborne = false;
      };
      this.SetBlocked(false);
      return;
    };
    let m: ref<AVFModel> = this.m_pilotModel;
    let s: ref<AVFSettings> = this.m_settings;
    let inp: ref<AVFInput> = this.m_input;
    let pad: Bool = inp.lastPad;
    // build 16: radio list / vehicle list / a menu open: the left stick and A navigate it, they don't fly
    let padUi: Bool = pad && this.UiBusy();
    let vmaxEff: Float = this.VmaxEff(m);
    let vs: Float = Cast<Float>(s.verticalSpeed) / 100.0;
    this.m_flight.vScale = vs;
    if this.m_domeT > 0.0 {
      this.m_domeT -= dt;
      if this.m_domeT <= 0.0 {
        AVFParts.SetDome(this.m_gi, veh, true);
        this.m_domeOn = true;
        this.Log("crystal dome on");
      };
    };
    // autopilot key: a 0.5 s hold switches it on or off, once per hold
    // a menu, the radio list or the vehicle list is open: its navigation (stick, D-pad up, A) is not flying
    let ui: Bool = (this.m_auto.on || inp.ap) && this.UiBusy();
    let apHeld: Bool = inp.HeldAp() > 0.5;
    if !inp.ap {
      this.m_apLatch = false;
    };
    if ui && inp.ap {
      this.m_apLatch = true;   // D-pad up scrolls the radio list: a hold that touched it never toggles
    };
    let apToggle: Bool = apHeld && !this.m_apLatch;
    if apToggle {
      this.m_apLatch = true;
    };

    // ---- inputs, smoothed
    let steerT: Float;
    let liftT: Float;
    if pad {
      steerT = padUi ? 0.0 : this.Expo(inp.lx, 0.12, 1.6);
      let ly: Float = s.invertClimb ? -inp.ly : inp.ly;
      liftT = padUi ? 0.0 : this.Expo(ly, 0.15, 1.4);
      this.m_steer = steerT;
      this.m_lift = liftT;
    } else {
      steerT = (inp.right ? 1.0 : 0.0) - (inp.left ? 1.0 : 0.0);
      liftT = (inp.climb ? 1.0 : 0.0) - (inp.descend ? 1.0 : 0.0);
      this.m_steer = this.Approach(this.m_steer, steerT, 3.0 * dt);
      this.m_lift = this.Approach(this.m_lift, liftT, 4.0 * dt);
    };
    let hover: Bool = inp.hover || inp.padHover && !padUi;

    // ---- throttle target
    if !pad || EnumInt(s.padThrottle) == 1 {
      // lever: taps step it, a held key ramps it at about the aircraft's real acceleration
      while inp.tapsUp > 0 {
        this.m_vSet += this.LeverStep(this.m_vSet);
        inp.tapsUp -= 1;
      };
      while inp.tapsDown > 0 {
        let nv: Float = this.m_vSet - this.LeverStep(this.m_vSet);
        if this.m_vSet > 0.01 && nv < 0.0 {
          nv = 0.0;
        };
        this.m_vSet = nv;
        inp.tapsDown -= 1;
      };
      let upHeld: Bool = inp.HeldUp() > 0.25 || pad && inp.rt > 0.1;
      let downHeld: Bool = inp.HeldDown() > 0.25 || pad && inp.lt > 0.1;
      let rate: Float = pad ? MaxF(inp.rt, inp.lt) : 1.0;
      if upHeld && !downHeld {
        let avail: Float = this.m_vSet >= 0.0 ? m.accel * MaxF(0.12, 1.0 - (this.m_vSet / vmaxEff) * (this.m_vSet / vmaxEff)) : m.brake;
        this.m_vSet += MaxF(1.5, 0.8 * avail) * rate * dt;
      };
      if downHeld && !upHeld {
        let nv2: Float = this.m_vSet - MaxF(2.0, 0.8 * m.brake) * rate * dt;
        if this.m_zeroLatch {
          nv2 = 0.0;             // stopped at zero during this hold
        } else {
          if this.m_vSet > 0.0 && nv2 <= 0.0 {
            nv2 = 0.0;
            this.m_zeroLatch = true;   // release and press again to reverse
          };
        };
        this.m_vSet = nv2;
      };
      if !downHeld {
        this.m_zeroLatch = false;
      };
      this.m_vSet = ClampF(this.m_vSet, -8.3, vmaxEff);
    } else {
      // proportional trigger: travel = speed (squared for fine control low down)
      this.m_vSet = vmaxEff * PowF(inp.rt, 2.2) - 8.3 * PowF(inp.lt, 2.0);
    };

    if !this.m_airborne {
      if !this.m_isNH {
        this.m_flight.UpdateAGL(dt, false);   // the Night Hunter is only bound from take-off on
      };
      if this.m_engineOffT > 0.0 && !this.m_isNH {
        this.m_engineOffT -= dt;
        if this.m_engineOffT <= 0.0 {
          veh.TurnEngineOn(false);
        };
      };
      // a landed charter is a car record and W / S are also car throttle: if the game restarts the engine on
      // such an input, switch it off again (twice a second at most), so the aircraft never drives as a car
      if !this.m_isNH && this.m_engineOffT <= 0.0 {
        this.m_engineChkT -= dt;
        if this.m_engineChkT <= 0.0 {
          this.m_engineChkT = 0.5;
          if veh.IsEngineTurnedOn() {
            veh.TurnEngineOn(false);
            if !this.m_engineLogged {
              this.m_engineLogged = true;
              this.Log("landed: the game restarted the engine, switched off again");
            };
          };
        };
      };
      if apToggle {
        this.StartAutopilot(veh);   // takes off first
        return;
      };
      // take off: hold climb
      if this.m_lift > 0.5 {
        this.m_takeoffT += dt;
      } else {
        this.m_takeoffT = 0.0;
      };
      if this.m_takeoffT > 0.25 {
        this.TakeOff(veh);
      };
      return;
    };

    // ---- airborne
    this.m_airT += dt;
    this.m_flight.UpdateAGL(dt, false);
    let cmd: ref<AVFCmd> = this.m_cmd;
    let restH: Float = this.m_isNH ? this.m_nhRest : this.m_restAGL;
    let h: Float = this.m_flight.aglValid ? this.m_flight.agl - restH : 50.0;
    let auto: ref<AVFAutopilot> = this.m_auto;
    if apToggle {
      if auto.on {
        this.StopAutopilot("Autopilot off. You have control.", false);
      } else {
        this.StartAutopilot(veh);
      };
    };
    // V, 2026-11-22: no flight control interrupts the autopilot, only its own key switches it off
    if hover {
      this.m_vSet = 0.0;
      if pad {
        cmd.vf = 5.0 * this.Expo(inp.ly, 0.15, 1.4);
        cmd.vl = 5.0 * this.Expo(inp.lx, 0.12, 1.4);
      } else {
        cmd.vf = 5.0 * ((inp.up ? 1.0 : 0.0) - (inp.down ? 1.0 : 0.0));
        cmd.vl = 5.0 * ((inp.right ? 1.0 : 0.0) - (inp.left ? 1.0 : 0.0));
      };
      cmd.yaw = 0.0;
      cmd.brakeBoost = true;
    } else {
      cmd.vf = this.m_vSet;
      cmd.vl = 0.0;
      cmd.yaw = this.m_steer * m.yawRate;
      cmd.brakeBoost = false;
    };
    let lift: Float = this.m_lift;
    if hover && pad {
      lift = inp.rt - inp.lt;   // triggers lift / lower in hover, slow
    };
    if AbsF(lift) > 0.05 {
      cmd.holdAlt = false;
      let k: Float = hover ? 0.5 : 1.0;
      cmd.vz = lift > 0.0 ? lift * m.climb * k * vs : lift * m.descent * k * vs;
      if cmd.vz < 0.0 {
        cmd.vz = MaxF(cmd.vz, -AVFFlight.Flare(h, m.descent * vs, vs));   // flare: 0.15 m/s at the ground
      };
    } else {
      cmd.holdAlt = true;
    };
    // build 19: controls let go just over the ground (under 0.5 m over the resting height), nearly stopped: it settles
    // onto its gear by itself at 0.4 m/s instead of hanging there
    if !this.m_isNH && !auto.on && cmd.holdAlt && h < 0.5 && AbsF(this.m_flight.vfNow) < 1.0 && AbsF(this.m_vSet) < 0.5 && this.m_airT > 2.0 {
      cmd.holdAlt = false;
      cmd.vz = -0.4;
    };
    if auto.on {
      let vCruise: Float = MinF(Cast<Float>(s.autopilotSpeed) / 3.6, vmaxEff);
      let apResult: Int32 = auto.Step(dt, veh, m, this.m_flight, cmd, vCruise, restH, vs);
      if StrLen(auto.note) > 0 {
        this.Log(auto.note);
      };
      if apResult == 2 {
        this.StopAutopilot(auto.reason, true);
        cmd.vf = 0.0;
        cmd.vl = 0.0;
        cmd.yaw = 0.0;
        cmd.holdAlt = true;
        cmd.brakeBoost = false;
      };
    };
    this.m_flight.Step(dt, cmd, vmaxEff);

    // watchdog: no resolved body or an uncontrolled spin for 2 s -> hand back to the game, never strand V
    if this.m_flight.unresolvedT > 2.0 || this.m_flight.tumbleT > 2.0 {
      let why: String = this.m_flight.unresolvedT > 2.0 ? "the physics body never resolved" : "the aircraft is spinning out of control";
      this.m_flight.Disengage();
      if this.m_isNH {
        this.m_flight.Release();
      };
      this.m_airborne = false;
      this.SetBlocked(false);
      this.m_hud.Message("Flight control lost: " + why + ". The aircraft is back on game physics.", 6.0);
      this.m_auto.Stop();
      this.Log("watchdog: " + why);
      return;
    };

    // fuel
    if !this.m_isNH {
      this.m_fuelL += LerpF(this.m_flight.powerFrac, m.burnHover, m.burnMax) / 60.0 * dt;
    };

    // touchdown
    let apDown: Bool = auto.Descending();
    let landed: Bool;
    if this.m_isNH {
      // the Night Hunter (hover tank on springs): the old test. The contact flag counts only near the ground (it
      // also fires on a wall or a roof edge); blocked descent: descend held, not sinking, close to the ground
      this.BlockedDescent(dt, (lift < -0.5 || apDown) && h < 3.0, veh.GetWorldPosition().Z);
      landed = (!auto.on || apDown) && (h < 0.3 || this.m_flight.IsOnGround() && h < 0.15 || this.m_blockT > 0.7);
    } else {
      // build 19: the charter by gear contact (Touchdown): sinking asked for, and the hull stopped sinking
      landed = this.Touchdown(dt, ((!auto.on || apDown) && !cmd.holdAlt) ? cmd.vz : 0.0, h, veh.GetWorldPosition().Z);
    };
    if this.m_airT > 1.0 && lift <= 0.05 && landed && this.m_flight.vzNow > -1.5 && AbsF(this.m_flight.vfNow) < 1.5 {
      if !this.m_isNH {
        this.Log("touchdown: " + FloatToStringPrec(h, 2) + " m over the resting height " + FloatToStringPrec(restH, 2) + " m");
      };
      this.ResetTouchdown();
      this.m_blockT = 0.0;
      this.Land(veh);
    };
  }

  // The pin the autopilot flies to: the tracked custom pin, else any marker V tracks on the map.
  private func TrackedPin(from: Vector4, out pos: Vector4, out kind: String) -> Bool {
    let ms: ref<MappinSystem> = GameInstance.GetMappinSystem(this.m_gi);
    let any: ref<IMappin>;
    let t: Int32 = 2;
    while t >= 0 {
      let pins: array<ref<IMappin>>;
      ms.GetMappins(IntEnum<gamemappinsMappinTargetType>(t), pins);
      for p in pins {
        if IsDefined(p) && p.IsPlayerTracked() {
          if Equals(p.GetVariant(), gamedataMappinVariant.CustomPositionVariant) {
            pos = p.GetWorldPosition();
            kind = "custom pin";
            return true;
          };
          // any other tracked marker only when it is somewhere else (not a marker on this aircraft or on V)
          if !IsDefined(any) && this.HDist(p.GetWorldPosition(), from) > 60.0 {
            any = p;
          };
        };
      };
      t -= 1;
    };
    let manual: ref<IMappin> = ms.GetMappin(ms.GetManuallyTrackedMappinID());
    if IsDefined(manual) {
      pos = manual.GetWorldPosition();
      if AbsF(pos.X) + AbsF(pos.Y) > 0.01 {
        kind = "manually tracked marker";
        return true;
      };
    };
    if IsDefined(any) {
      pos = any.GetWorldPosition();
      kind = "tracked marker, variant " + IntToString(EnumInt(any.GetVariant()));
      return AbsF(pos.X) + AbsF(pos.Y) > 0.01;
    };
    return false;
  }

  private func StartAutopilot(veh: ref<VehicleObject>) -> Void {
    let dest: Vector4;
    let kind: String;
    if !this.TrackedPin(veh.GetWorldPosition(), dest, kind) {
      this.m_hud.Message("Autopilot: place a pin on the map (or track a marker) first.", 5.0);
      this.Log("autopilot: no tracked pin");
      return;
    };
    if this.HDist(dest, veh.GetWorldPosition()) < 30.0 {
      this.m_hud.Message("Autopilot: the tracked pin is right here. Place a pin on the map.", 5.0);
      this.Log("autopilot: the pin (" + kind + ") is " + FloatToStringPrec(this.HDist(dest, veh.GetWorldPosition()), 0) + " m away, no flight");
      return;
    };
    if !this.m_airborne {
      this.TakeOff(veh);
      if !this.m_airborne {
        return;
      };
    };
    this.m_flight.UpdateAGL(0.0, true);
    this.m_auto.Start(dest, veh.GetWorldPosition(), this.m_flight);
    this.m_vSet = 0.0;
    this.m_hud.Message("Autopilot: flying to your map pin, " + this.Dist(this.m_auto.distLeft) + ". Hold " + (this.m_input.lastPad ? "D-pad up" : this.KeyLabel(this.m_settings.keyAutopilot)) + " again to switch it off.", 5.0);
    this.Log("autopilot on: " + FloatToStringPrec(this.m_auto.distLeft, 0) + " m to the pin (" + kind + ")");
  }

  // The radio list, the vehicle list or a menu is open (their navigation uses the stick, the D-pad and A / Cross).
  private func UiBusy() -> Bool {
    let bbs: ref<BlackboardSystem> = GameInstance.GetBlackboardSystem(this.m_gi);
    let ui: ref<IBlackboard> = bbs.Get(GetAllBlackboardDefs().UI_System);
    if IsDefined(ui) && ui.GetBool(GetAllBlackboardDefs().UI_System.IsInMenu) {
      return true;
    };
    let gd: ref<IBlackboard> = bbs.Get(GetAllBlackboardDefs().UIGameData);
    return IsDefined(gd) && (gd.GetBool(GetAllBlackboardDefs().UIGameData.Popup_Radio_IsShown) || gd.GetBool(GetAllBlackboardDefs().UIGameData.Popup_VehiclesManager_IsShown));
  }

  // hover = control came back because the autopilot gave up: stop and hold. Otherwise keep the current speed.
  private func StopAutopilot(msg: String, hover: Bool) -> Void {
    if !this.m_auto.on {
      return;
    };
    this.m_auto.Stop();
    this.m_vSet = hover ? 0.0 : MaxF(this.m_flight.vfNow, 0.0);
    this.m_input.tapsUp = 0;
    this.m_input.tapsDown = 0;
    this.m_hud.Message(msg, 5.0);
    this.Log("autopilot off: " + msg);
  }

  // Height over the ground while the radar altimeter reaches it (400 m), else above sea level.
  private func Alt() -> String {
    if this.m_flight.aglValid {
      return this.Height(this.m_flight.agl);
    };
    return this.Height(this.m_flight.posZ) + " ASL";
  }

  private func Dist(d: Float) -> String {
    if this.m_settings.metric {
      return d >= 1000.0 ? FloatToStringPrec(d / 1000.0, 1) + " km" : IntToString(RoundF(d)) + " m";
    };
    return FloatToStringPrec(d / 1609.3, 1) + " mi";
  }

  private func Approach(cur: Float, tgt: Float, step: Float) -> Float {
    if tgt > cur {
      return MinF(tgt, cur + step);
    };
    return MaxF(tgt, cur - step);
  }

  private func TakeOff(veh: ref<VehicleObject>) -> Void {
    if this.m_isNH && (Equals(this.m_state, AVFState.Arriving) || Equals(this.m_state, AVFState.Departing)) {
      this.m_hud.Message("Air traffic control: hold until your charter has landed or left.", 3.0);
      this.m_takeoffT = -2.0;
      return;
    };
    if this.m_hoverOn && !Equals(this.m_hoverID, veh.GetEntityID()) {
      // one flight controller for one aircraft
      if !this.m_hoverNH {
        this.m_hud.Message("Air traffic control: your charter is holding in the air. Bring it to you (double tap " + this.KeyLabel(this.m_settings.keyCall) + " on foot) or send it away (hold) first.", 5.0);
        this.m_takeoffT = -2.0;
        return;
      };
      this.EndHover(true, "another aircraft takes off");
    };
    if !this.m_flight.Bind(veh, this.m_pilotModel) {
      return;
    };
    if this.m_isNH {
      // after Bind: the radar altimeter measures the bound vehicle
      this.m_flight.UpdateAGL(0.0, true);
      this.m_nhRest = this.m_flight.aglValid ? ClampF(this.m_flight.agl, 0.0, 4.0) : 2.2;
    };
    this.m_flight.Engage();
    if !this.m_isNH {
      this.CloseDoor(veh);   // build 19: the door opened for boarding closes at take-off
      // build 18: a passenger-seat mount never switches the vehicle's systems on (only the driver mount does)
      veh.TurnVehicleOn(true);
      veh.TurnEngineOn(true);
      this.m_engineOffT = 0.0;
      this.m_thrustSent = -1.0;
    };
    this.m_airborne = true;
    this.m_airT = 0.0;
    this.m_takeoffT = 0.0;
    this.m_vSet = 0.0;
    this.SetBlocked(true);
    this.ShowHintsFor(2);
    this.Log("take-off " + this.m_pilotModel.name + (this.m_isNH ? " rest " + FloatToStringPrec(this.m_nhRest, 2) + " m" : ""));
  }

  private func Land(veh: ref<VehicleObject>) -> Void {
    if this.m_auto.on {
      this.m_auto.Stop();
      this.m_hud.Message("Autopilot: landed at your pin.", 4.0);
      this.Log("autopilot landed");
    };
    this.m_flight.Disengage();
    if this.m_isNH {
      this.m_flight.Release();
    };
    this.m_airborne = false;
    this.m_vSet = 0.0;
    this.SetBlocked(false);
    this.ShowHintsFor(1);
    if !this.m_isNH {
      this.m_restMeasureT = 1.5;
      // engine sound back to idle, engines shut down 3 s later (a parked AV is a car record: no wheels driving)
      this.Param(veh, n"v_av_panzer_thrust", 0.0);
      this.Param(veh, n"v_av_panzer_speed", 0.0);
      this.Param(veh, n"v_av_panzer_rotation_speed", 0.0);
      this.m_thrustSent = 0.0;
      this.m_speedSent = 0.0;
      this.m_rotSent = 0.0;
      this.m_engineOffT = 3.0;
    };
    this.Log("landed " + this.m_pilotModel.name + " after " + FloatToStringPrec(this.m_airT, 0) + " s");
  }

  // ---------------------------------------------------------------- HUD

  private func ShowHintsFor(key: Int32) -> Void {
    if this.m_hintKey != key {
      this.m_hintKey = key;
      this.m_hintUntil = this.Now() + 8.0;
    };
  }

  private func Speed(v: Float) -> String {
    return this.m_settings.metric ? IntToString(RoundF(v * 3.6)) + " km/h" : IntToString(RoundF(v * 2.237)) + " mph";
  }

  private func Height(h: Float) -> String {
    return this.m_settings.metric ? IntToString(RoundF(h)) + " m" : IntToString(RoundF(h * 3.281)) + " ft";
  }

  private func TickHud(dt: Float, now: Float) -> Void {
    this.m_hudT -= dt;
    if this.m_hudT > 0.0 {
      return;
    };
    this.m_hudT = 0.2;
    let s: ref<AVFSettings> = this.m_settings;
    if Equals(s.hints, AVFHints.Off) {
      this.m_hud.Hide();
      return;
    };
    let showKeys: Bool = Equals(s.hints, AVFHints.Always) || now < this.m_hintUntil;
    let data: String = "";
    let keys: String = "";
    let meter: String = "";
    let pad: Bool = this.m_input.lastPad;
    let veh: ref<VehicleObject> = this.m_pilotVeh;
    if IsDefined(veh) {
      let m: ref<AVFModel> = this.m_pilotModel;
      if this.m_airborne {
        let vsi: Float = this.m_flight.vzNow;
        data = this.Speed(AbsF(this.m_flight.vfNow)) + "  >  " + this.Speed(this.m_vSet) + "     ALT " + this.Alt() + "     V/S " + (vsi >= 0.0 ? "+" : "") + FloatToStringPrec(vsi, 1);
        if showKeys {
          if pad {
            keys = "RT / LT speed   |   left stick: turn, climb   |   hold A: hover (stick slides, triggers lift)   |   hold D-pad up: autopilot";
          } else {
            keys = this.KeyLabel(s.keyThrottleUp) + " / " + this.KeyLabel(s.keyThrottleDown) + " speed (tap = 5-10 km/h)   |   " + this.KeyLabel(s.keyTurnLeft) + " / " + this.KeyLabel(s.keyTurnRight) + " turn   |   " + this.KeyLabel(s.keyClimb) + " / " + this.KeyLabel(s.keyDescend) + " climb / descend   |   hold " + this.KeyLabel(s.keyHover) + ": hover   |   hold " + this.KeyLabel(s.keyAutopilot) + ": autopilot to the map pin";
          };
        };
        if this.m_auto.on {
          data = (this.m_auto.phase <= 1 ? "AUTOPILOT climbing   " : (this.m_auto.phase >= 3 ? "AUTOPILOT landing   " : "AUTOPILOT   ")) + this.Dist(this.m_auto.distLeft) + " to go   " + this.Speed(AbsF(this.m_flight.vfNow)) + "   ALT " + this.Alt();
          keys = "Hold " + (pad ? "D-pad up" : this.KeyLabel(s.keyAutopilot)) + ": autopilot off (the flight controls are locked)";
        };
      } else {
        data = m.name + "  -  landed";
        if showKeys {
          keys = pad ? "Left stick forward (hold): take off   |   hold D-pad up: autopilot   |   B: get out" : "Hold " + this.KeyLabel(s.keyClimb) + ": take off   |   hold " + this.KeyLabel(s.keyAutopilot) + ": autopilot   |   F: get out";
        };
      };
      if !this.m_isNH && this.p_open {
        meter = "Charter " + AVFSystem.Eddies(this.MeterCost()) + " eb   (" + this.Clock(this.m_rentS) + ", " + IntToString(RoundF(this.m_fuelL)) + " L)";
      };
      this.m_hud.Show(data, keys, meter);
      return;
    };
    // on foot
    let av: ref<VehicleObject>;
    let p: ref<PlayerPuppet>;
    switch this.m_state {
      case AVFState.EnRoute:
        meter = this.m_model.name + " inbound   ETA " + this.Clock(this.m_etaAt - now);
        break;
      case AVFState.Arriving:
        meter = this.m_model.name + " landing";
        break;
      case AVFState.Parked:
        av = this.AV();
        p = this.Player();
        if IsDefined(av) && IsDefined(p) && this.NearEntry(av, p) {
          data = "Board " + this.m_model.name + ": " + this.KeyLabel(s.keyBoard);
        };
        // build 19: double tap = come to me (from the air or the ground); while it comes, double tap = hold
        meter = "Charter " + AVFSystem.Eddies(this.MeterCost()) + " eb   (" + this.Clock(this.m_rentS) + ")   " + (this.m_hoverOn && !this.m_hoverNH ? (this.m_hoverLand ? "coming to you   stop it: double tap " + this.KeyLabel(s.keyCall) + "   " : "holding in the air   come to me: double tap " + this.KeyLabel(s.keyCall) + "   ") : "come to me: double tap " + this.KeyLabel(s.keyCall) + "   ") + "send away: hold " + this.CallKeyName();
        break;
      default:
        break;
    };
    this.m_hud.Show(data, "", meter);
  }

  // ---------------------------------------------------------------- engine sound

  private func Param(veh: ref<VehicleObject>, name: CName, v: Float) -> Void {
    let au: ref<AudioSystem> = GameInstance.GetAudioSystem(this.m_gi);
    au.Parameter(name, v, veh.GetEntityID(), n"vehicle_engine_emitter");
    au.Parameter(name, v, veh.GetEntityID());
  }

  private func TickAudio(dt: Float) -> Void {
    this.m_audioT -= dt;
    if this.m_audioT > 0.0 {
      return;
    };
    this.m_audioT = 0.25;
    let veh: ref<VehicleObject> = this.m_pilotVeh;
    if !IsDefined(veh) && this.m_hoverOn {
      veh = this.m_hoverVeh;
    };
    if !IsDefined(veh) {
      veh = this.AV();
    };
    if !IsDefined(veh) {
      return;
    };
    // volume: game parameter v_av_panzer_engine_suppresion (0 dB at -42, linear gain down to -21 dB at -35)
    let gain: Float = Cast<Float>(this.m_settings.engineVolume) / 100.0;
    let x: Float = ClampF(-42.0 + 7.0 * (1.014 - gain) / 0.925, -48.0, -35.0);
    if AbsF(x - this.m_volSent) > 0.01 {
      this.Param(veh, n"v_av_panzer_engine_suppresion", x);
      if this.m_settings.volumeGlobal {
        GameInstance.GetAudioSystem(this.m_gi).GlobalParameter(n"v_av_panzer_engine_suppresion", x);
      };
      this.m_volSent = x;
    };
    // engine character from the flight model, only while the controller flies (the tank model feeds it on the ground)
    if !this.m_flight.engaged || !Equals(this.m_flight.vehID, veh.GetEntityID()) {
      return;
    };
    let m: ref<AVFModel> = this.m_flight.model;
    let thrust: Float = ClampF(0.08 + 0.5 * this.m_flight.powerFrac, 0.0, 1.0);
    let spd: Float = ClampF(this.m_flight.vfNow / MaxF(m.vmax, 1.0), -0.6, 0.6);
    let rot: Float = ClampF(AbsF(this.m_flight.yawNow) / MaxF(m.yawRate, 0.1), 0.0, 1.0);
    if AbsF(thrust - this.m_thrustSent) > 0.02 {
      this.Param(veh, n"v_av_panzer_thrust", thrust);
      this.m_thrustSent = thrust;
    };
    if AbsF(spd - this.m_speedSent) > 0.02 {
      this.Param(veh, n"v_av_panzer_speed", spd);
      this.m_speedSent = spd;
    };
    if AbsF(rot - this.m_rotSent) > 0.02 {
      this.Param(veh, n"v_av_panzer_rotation_speed", rot);
      this.m_rotSent = rot;
    };
  }
}
