// Cyberslop AV Flight 1.0.0 - settings (Mod Settings > Cyberslop AV Flight) and shared types.
// Build 18 (2026-11-26): Flight > "Your seat" (default back right).
module CyberslopAVFlight

public class AVFModel {
  public let index: Int32;
  public let key: String;
  public let name: String;
  public let kind: Int32;          // 0 AV, 1 helicopter, 2 Night Hunter (world vehicle, no charter)
  public let record: TweakDBID;
  public let appearance: CName;
  public let vmax: Float;          // m/s
  public let accel: Float;         // m/s^2 at low speed, tapers to 0 at vmax
  public let brake: Float;         // m/s^2
  public let climb: Float;         // m/s
  public let descent: Float;       // m/s
  public let yawRate: Float;       // rad/s in a hover
  public let turnLat: Float;       // m/s^2 lateral acceleration of a coordinated turn
  public let pitchFactor: Float;   // share of the acceleration tilt the hull shows (AV 0.35, helicopter 1.0)
  public let gainPerKg: Float;     // torque gain / mass (yaw response about 0.3 s)
  public let dispatch: Float;      // eddies
  public let rentPerHour: Float;   // eddies
  public let burnHover: Float;     // L/min
  public let burnCruise: Float;
  public let burnMax: Float;
  public let hullValue: Float;
  public let length: Float;
  public let width: Float;
  public let height: Float;
  public let entry: Vector3;       // local offset of the boarding spot (x right, y forward, z up)
  public let entryRadius: Float;
  public let exitPoint: Vector3;   // local offset where V stands after getting out
}

public enum AVFCharter {
  Excalibur = 0,
  Atlus = 1,
  Manticore = 2,
  Surveyor = 3,
  Valgus = 4,
  Mayhem = 5
}

public enum AVFPadThrottle {
  Proportional = 0,
  Lever = 1
}

public enum AVFHints {
  Auto = 0,
  Always = 1,
  Off = 2
}

// Build 18: the seat V takes when boarding a charter (the slot names of DAV's model table).
public enum AVFSeat {
  FrontLeft = 0,
  FrontRight = 1,
  BackLeft = 2,
  BackRight = 3
}

// Liveries, in the order of AVFParts.Livery.
public enum AVFSkinExcalibur {
  Premium = 0,
  Delamain = 1,
  Arasaka = 2,
  SaburoArasaka = 3,
  NusaMyers = 4
}

public enum AVFSkinAtlus {
  N54News = 0,
  TraumaTeam = 1,
  Arasaka = 2,
  NCPD = 3,
  Stealth = 4,
  StealthCloaked = 5,
  FIA = 6
}

public enum AVFSkinManticore {
  Militech = 0,
  NCPD = 1,
  TraumaTeam = 2,
  TraumaTeamNusa = 3,
  Barghest = 4,
  DumDum = 5
}

public enum AVFSkinSurveyor {
  KangTao = 0,
  MaxTac = 1,
  Arasaka = 2
}

public enum AVFSkinValgus {
  Valgus = 0,
  BorderPatrol = 1,
  Arasaka = 2,
  Nusa = 3,
  MaxTac = 4
}

public enum AVFSkinMayhem {
  Militech = 0,
  MaxTac = 1
}

public class AVFSettings extends ScriptableSystem {

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Charter")
  @runtimeProperty("ModSettings.category.order", "1")
  @runtimeProperty("ModSettings.displayName", "Aircraft to call")
  @runtimeProperty("ModSettings.description", "What the dispatcher sends when you call (hold the call key on foot). Each one has its own speed, climb, fuel burn and price.")
  @runtimeProperty("ModSettings.displayValues.Excalibur", "Rayfield Excalibur (luxury AV)")
  @runtimeProperty("ModSettings.displayValues.Atlus", "Zetatech Atlus (utility AV)")
  @runtimeProperty("ModSettings.displayValues.Manticore", "Militech Manticore (heavy AV)")
  @runtimeProperty("ModSettings.displayValues.Surveyor", "Zetatech Surveyor (large AV)")
  @runtimeProperty("ModSettings.displayValues.Valgus", "Zetatech Valgus (helicopter)")
  @runtimeProperty("ModSettings.displayValues.Mayhem", "Militech Mayhem (attack helicopter)")
  public let charter: AVFCharter = AVFCharter.Excalibur;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Charter")
  @runtimeProperty("ModSettings.displayName", "Price scale")
  @runtimeProperty("ModSettings.description", "Multiplies the dispatch fee and the hourly rate. Fuel is always billed at the fuel price below.")
  @runtimeProperty("ModSettings.step", "0.05")
  @runtimeProperty("ModSettings.min", "0.25")
  @runtimeProperty("ModSettings.max", "5.0")
  public let priceScale: Float = 1.0;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Charter")
  @runtimeProperty("ModSettings.displayName", "Fuel price (eddies per litre)")
  @runtimeProperty("ModSettings.description", "CHOOH2 price used for the ferry flight and the fuel you burn. 1.3 = Vehicle Mileage's pump price.")
  @runtimeProperty("ModSettings.step", "0.1")
  @runtimeProperty("ModSettings.min", "0.1")
  @runtimeProperty("ModSettings.max", "10.0")
  public let fuelPrice: Float = 1.3;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Charter")
  @runtimeProperty("ModSettings.displayName", "Damage liability")
  @runtimeProperty("ModSettings.description", "A destroyed charter costs the insurance deductible: 10 % of the aircraft's value.")
  public let liability: Bool = true;

  // Liveries: the appearances of Drive an Aerial Vehicle's aircraft entities. Used at the next call.
  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Charter")
  @runtimeProperty("ModSettings.displayName", "Excalibur livery")
  @runtimeProperty("ModSettings.description", "Used the next time you call this aircraft.")
  @runtimeProperty("ModSettings.displayValues.Premium", "Rayfield premium")
  @runtimeProperty("ModSettings.displayValues.Delamain", "Delamain")
  @runtimeProperty("ModSettings.displayValues.Arasaka", "Arasaka")
  @runtimeProperty("ModSettings.displayValues.SaburoArasaka", "Saburo Arasaka")
  @runtimeProperty("ModSettings.displayValues.NusaMyers", "NUSA (President Myers)")
  public let skinExcalibur: AVFSkinExcalibur = AVFSkinExcalibur.Premium;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Charter")
  @runtimeProperty("ModSettings.displayName", "Atlus livery")
  @runtimeProperty("ModSettings.description", "Used the next time you call this aircraft.")
  @runtimeProperty("ModSettings.displayValues.N54News", "N54 News")
  @runtimeProperty("ModSettings.displayValues.TraumaTeam", "Trauma Team")
  @runtimeProperty("ModSettings.displayValues.Arasaka", "Arasaka")
  @runtimeProperty("ModSettings.displayValues.NCPD", "NCPD")
  @runtimeProperty("ModSettings.displayValues.Stealth", "Stealth")
  @runtimeProperty("ModSettings.displayValues.StealthCloaked", "Stealth, cloaked")
  @runtimeProperty("ModSettings.displayValues.FIA", "FIA")
  public let skinAtlus: AVFSkinAtlus = AVFSkinAtlus.N54News;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Charter")
  @runtimeProperty("ModSettings.displayName", "Manticore livery")
  @runtimeProperty("ModSettings.description", "Used the next time you call this aircraft.")
  @runtimeProperty("ModSettings.displayValues.Militech", "Militech")
  @runtimeProperty("ModSettings.displayValues.NCPD", "NCPD")
  @runtimeProperty("ModSettings.displayValues.TraumaTeam", "Trauma Team")
  @runtimeProperty("ModSettings.displayValues.TraumaTeamNusa", "Trauma Team (NUSA)")
  @runtimeProperty("ModSettings.displayValues.Barghest", "Barghest")
  @runtimeProperty("ModSettings.displayValues.DumDum", "Maelstrom (Dum Dum)")
  public let skinManticore: AVFSkinManticore = AVFSkinManticore.Militech;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Charter")
  @runtimeProperty("ModSettings.displayName", "Surveyor livery")
  @runtimeProperty("ModSettings.description", "Used the next time you call this aircraft.")
  @runtimeProperty("ModSettings.displayValues.KangTao", "Kang Tao")
  @runtimeProperty("ModSettings.displayValues.MaxTac", "MaxTac")
  @runtimeProperty("ModSettings.displayValues.Arasaka", "Arasaka")
  public let skinSurveyor: AVFSkinSurveyor = AVFSkinSurveyor.KangTao;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Charter")
  @runtimeProperty("ModSettings.displayName", "Valgus livery")
  @runtimeProperty("ModSettings.description", "Used the next time you call this aircraft.")
  @runtimeProperty("ModSettings.displayValues.Valgus", "Zetatech")
  @runtimeProperty("ModSettings.displayValues.BorderPatrol", "Border patrol")
  @runtimeProperty("ModSettings.displayValues.Arasaka", "Arasaka")
  @runtimeProperty("ModSettings.displayValues.Nusa", "NUSA")
  @runtimeProperty("ModSettings.displayValues.MaxTac", "MaxTac")
  public let skinValgus: AVFSkinValgus = AVFSkinValgus.Valgus;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Charter")
  @runtimeProperty("ModSettings.displayName", "Mayhem livery")
  @runtimeProperty("ModSettings.description", "Used the next time you call this aircraft.")
  @runtimeProperty("ModSettings.displayValues.Militech", "Militech")
  @runtimeProperty("ModSettings.displayValues.MaxTac", "MaxTac")
  public let skinMayhem: AVFSkinMayhem = AVFSkinMayhem.Militech;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Flight")
  @runtimeProperty("ModSettings.category.order", "2")
  @runtimeProperty("ModSettings.displayName", "Speed limit (%)")
  @runtimeProperty("ModSettings.description", "Share of each aircraft's real top speed you allow yourself. Above about 250 km/h the city can stream in late.")
  @runtimeProperty("ModSettings.step", "5")
  @runtimeProperty("ModSettings.min", "30")
  @runtimeProperty("ModSettings.max", "100")
  public let speedLimit: Int32 = 100;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Flight")
  @runtimeProperty("ModSettings.displayName", "Gamepad throttle")
  @runtimeProperty("ModSettings.description", "Proportional: trigger travel = speed, let go = slow to a hover. Lever: the triggers move a target speed that stays, like W / S.")
  @runtimeProperty("ModSettings.displayValues.Proportional", "Proportional")
  @runtimeProperty("ModSettings.displayValues.Lever", "Lever")
  public let padThrottle: AVFPadThrottle = AVFPadThrottle.Proportional;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Flight")
  @runtimeProperty("ModSettings.displayName", "Invert climb stick")
  @runtimeProperty("ModSettings.description", "Off: left stick forward = climb.")
  public let invertClimb: Bool = false;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Flight")
  @runtimeProperty("ModSettings.displayName", "Allow getting out in the air")
  @runtimeProperty("ModSettings.description", "Off: the exit is blocked until the aircraft has landed. On: after you get out in the air the aircraft stops and holds its position.")
  public let exitInAir: Bool = false;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Flight")
  @runtimeProperty("ModSettings.displayName", "Your seat")
  @runtimeProperty("ModSettings.description", "Where you sit when you board a charter. You fly it from any seat; the other seats stay empty. Used the next time you board. The Atlus has no front right seat: there you take the front left one.")
  @runtimeProperty("ModSettings.displayValues.FrontLeft", "Front left (pilot)")
  @runtimeProperty("ModSettings.displayValues.FrontRight", "Front right")
  @runtimeProperty("ModSettings.displayValues.BackLeft", "Back left")
  @runtimeProperty("ModSettings.displayValues.BackRight", "Back right")
  public let seat: AVFSeat = AVFSeat.BackRight;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Flight")
  @runtimeProperty("ModSettings.displayName", "Fly the NCPD Night Hunter")
  @runtimeProperty("ModSettings.description", "Off: the Night Hunter keeps its own hover-tank controls, this mod does not touch it. On: Space / Left Ctrl climb and descend it like a charter AV.")
  public let flyNightHunter: Bool = false;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Flight")
  @runtimeProperty("ModSettings.displayName", "Vertical speed (%)")
  @runtimeProperty("ModSettings.description", "Climb and descent rate of your own flying and of the autopilot, as a share of each aircraft's real figure (Excalibur at 100 %: 10 m/s up, 7 m/s down). The landing flare near the ground stays gentle.")
  @runtimeProperty("ModSettings.step", "25")
  @runtimeProperty("ModSettings.min", "50")
  @runtimeProperty("ModSettings.max", "300")
  public let verticalSpeed: Int32 = 200;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Flight")
  @runtimeProperty("ModSettings.displayName", "Autopilot speed (km/h)")
  @runtimeProperty("ModSettings.description", "Cruise speed of the autopilot (hold the autopilot key: it flies to your tracked map pin and lands there). It flies over the buildings on the way, at an altitude read from a height map of the city.")
  @runtimeProperty("ModSettings.step", "10")
  @runtimeProperty("ModSettings.min", "60")
  @runtimeProperty("ModSettings.max", "300")
  public let autopilotSpeed: Int32 = 160;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Flight")
  @runtimeProperty("ModSettings.displayName", "Crystal dome")
  @runtimeProperty("ModSettings.description", "Excalibur and Manticore: the cabin walls turn see-through three seconds after you board.")
  public let crystalDome: Bool = true;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Sound")
  @runtimeProperty("ModSettings.category.order", "3")
  @runtimeProperty("ModSettings.displayName", "Engine volume (%)")
  @runtimeProperty("ModSettings.description", "Level of the AV / Night Hunter engine (the Basilisk engine). 85 = 15 % quieter than vanilla.")
  @runtimeProperty("ModSettings.step", "5")
  @runtimeProperty("ModSettings.min", "10")
  @runtimeProperty("ModSettings.max", "100")
  public let engineVolume: Int32 = 85;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Sound")
  @runtimeProperty("ModSettings.displayName", "Apply the volume globally")
  @runtimeProperty("ModSettings.description", "Fallback if the slider does not change the level: sets it for every Basilisk-engine vehicle.")
  public let volumeGlobal: Bool = false;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "HUD")
  @runtimeProperty("ModSettings.category.order", "4")
  @runtimeProperty("ModSettings.displayName", "Control hints")
  @runtimeProperty("ModSettings.description", "Auto: the keys for the current situation for 8 s after it changes, then only the flight data. Always: keys stay. Off: nothing.")
  @runtimeProperty("ModSettings.displayValues.Auto", "Auto")
  @runtimeProperty("ModSettings.displayValues.Always", "Always")
  @runtimeProperty("ModSettings.displayValues.Off", "Off")
  public let hints: AVFHints = AVFHints.Auto;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "HUD")
  @runtimeProperty("ModSettings.displayName", "Metric units")
  @runtimeProperty("ModSettings.description", "On: km/h and metres. Off: mph and feet.")
  public let metric: Bool = true;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Keys")
  @runtimeProperty("ModSettings.category.order", "5")
  @runtimeProperty("ModSettings.displayName", "Call / send away (hold, on foot)")
  @runtimeProperty("ModSettings.description", "Hold 0.8 s for a quote, hold again to confirm. Hold while an AV waits for you to send it away. Double tap: your AV comes to you and lands at your feet, door towards you, from the air or from where it landed (double tap again on its way: it holds in the air). Keyboard only.")
  public let keyCall: EInputKey = EInputKey.IK_K;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Keys")
  @runtimeProperty("ModSettings.displayName", "Board")
  public let keyBoard: EInputKey = EInputKey.IK_F;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Keys")
  @runtimeProperty("ModSettings.displayName", "Throttle up")
  public let keyThrottleUp: EInputKey = EInputKey.IK_W;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Keys")
  @runtimeProperty("ModSettings.displayName", "Throttle down / reverse")
  public let keyThrottleDown: EInputKey = EInputKey.IK_S;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Keys")
  @runtimeProperty("ModSettings.displayName", "Turn left")
  public let keyTurnLeft: EInputKey = EInputKey.IK_A;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Keys")
  @runtimeProperty("ModSettings.displayName", "Turn right")
  public let keyTurnRight: EInputKey = EInputKey.IK_D;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Keys")
  @runtimeProperty("ModSettings.displayName", "Climb / take off")
  public let keyClimb: EInputKey = EInputKey.IK_Space;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Keys")
  @runtimeProperty("ModSettings.displayName", "Descend / land")
  public let keyDescend: EInputKey = EInputKey.IK_LControl;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Keys")
  @runtimeProperty("ModSettings.displayName", "Hover (hold: stop, slide, creep)")
  public let keyHover: EInputKey = EInputKey.IK_LShift;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Keys")
  @runtimeProperty("ModSettings.displayName", "Autopilot to the map pin (hold)")
  public let keyAutopilot: EInputKey = EInputKey.IK_G;

  @runtimeProperty("ModSettings.mod", "Cyberslop AV Flight")
  @runtimeProperty("ModSettings.category", "Debug")
  @runtimeProperty("ModSettings.category.order", "6")
  @runtimeProperty("ModSettings.displayName", "Log to CET gamelog.log")
  @runtimeProperty("ModSettings.description", "[AVFlight] lines for calls, bills, take-offs, landings and the physics binding. Events only, nothing per frame.")
  public let debugLog: Bool = false;

  private func OnAttach() -> Void {
    ModSettings.RegisterListenerToClass(this);
  }

  // build 16: new keys take effect at once (the raw key callbacks are registered per key)
  public cb func OnModSettingsChange() -> Void {
    let sys: ref<AVFSystem> = AVFSystem.Get(this.GetGameInstance());
    if IsDefined(sys) {
      sys.OnKeysChanged();
    };
  }

  private func OnDetach() -> Void {
    ModSettings.UnregisterListenerToClass(this);
  }

  public static func Get(gi: GameInstance) -> ref<AVFSettings> {
    return GameInstance.GetScriptableSystemsContainer(gi).Get(n"CyberslopAVFlight.AVFSettings") as AVFSettings;
  }
}
