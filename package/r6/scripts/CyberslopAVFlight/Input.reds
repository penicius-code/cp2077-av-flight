// Cyberslop AV Flight 1.0.0 - raw input through Codeware's callback system.
// Key-targeted callbacks: only the listed keys ever reach script (mouse moves and every other key stay native).
// The pilot callbacks exist only while V sits in the pilot seat of a flyable vehicle; the on-foot callback
// listens to two keys only (call key, board key). Build 16: the L3 + R3 gamepad chord is gone (2026-11-22);
// keys changed in Mod Settings re-register at once (AVFSettings.OnModSettingsChange -> AVFSystem.OnKeysChanged).
// Build 19: double tap of the call key on foot = the AV comes to V (AVFSystem.OnCallDoubleTap); single tap unused.
module CyberslopAVFlight

public class AVFHoldCheck extends DelayCallback {
  public let input: wref<AVFInput>;
  public let token: Int32;
  public let chord: Bool;

  public func Call() -> Void {
    if IsDefined(this.input) {
      this.input.OnHoldCheck(this.token, this.chord);
    };
  }
}

public class AVFInput extends IScriptable {
  private let m_gi: GameInstance;
  private let m_sys: wref<AVFSystem>;
  private let m_settings: wref<AVFSettings>;
  private let m_footOn: Bool;
  private let m_pilotOn: Bool;
  private let m_footH: ref<CallbackSystemHandler>;
  private let m_pilotKeyH: ref<CallbackSystemHandler>;
  private let m_pilotAxisH: ref<CallbackSystemHandler>;
  private let m_rawFoot: Int32;
  private let m_rawPilot: Int32;
  private let m_rawAxisOther: Int32;

  // keyboard, pilot
  public let up: Bool;
  public let down: Bool;
  public let left: Bool;
  public let right: Bool;
  public let climb: Bool;
  public let descend: Bool;
  public let hover: Bool;
  public let upSince: Float;
  public let downSince: Float;
  public let tapsUp: Int32;     // short presses not yet consumed by the throttle lever
  public let tapsDown: Int32;
  // gamepad, pilot
  public let rt: Float;
  public let lt: Float;
  public let lx: Float;
  public let ly: Float;
  public let padHover: Bool;
  public let ap: Bool;          // autopilot key held
  public let apSince: Float;
  public let lastPad: Bool;

  // on foot
  private let m_callHeld: Bool;
  private let m_callSince: Float;
  private let m_tapArmed: Bool;     // build 19: a first tap is waiting for its second
  private let m_tapAt: Float;
  private let m_l3: Bool;
  private let m_r3: Bool;
  private let m_token: Int32;

  public func Init(gi: GameInstance, sys: ref<AVFSystem>, settings: ref<AVFSettings>) -> Void {
    this.m_gi = gi;
    this.m_sys = sys;
    this.m_settings = settings;
  }

  private func Now() -> Float {
    let sys: ref<AVFSystem> = this.m_sys;
    if !IsDefined(sys) {
      return 0.0;
    };
    return sys.Now();   // session-relative: the raw sim time as a Float only resolves 0.125 s on a long save
  }

  // ---------------------------------------------------------------- on foot

  public func SetSettings(s: ref<AVFSettings>) -> Void {
    this.m_settings = s;
  }

  private func Diag(s: String) -> Void {
    AVFSystem.LogLine(this.m_gi, "diag " + s);
  }

  public func StartFoot() -> Void {
    if !IsDefined(this.m_settings) {
      this.m_settings = AVFSettings.Get(this.m_gi);
    };
    if this.m_footOn {
      this.Diag("foot keys already on");
      return;
    };
    if !IsDefined(this.m_settings) {
      this.Diag("foot keys NOT started: settings missing");
      return;
    };
    let sys: ref<AVFSystem> = this.m_sys;
    if !IsDefined(sys) {
      this.Diag("foot keys NOT started: system missing");
      return;
    };
    this.m_footH = GameInstance.GetCallbackSystem().RegisterCallback(n"Input/Key", sys, n"OnAVFFootKey");
    this.m_footH.AddTarget(InputTarget.Key(this.m_settings.keyCall));
    this.m_footH.AddTarget(InputTarget.Key(this.m_settings.keyBoard));
    this.m_footOn = true;
    this.m_rawFoot = 0;
    this.Diag("diag2 foot keys on, call key " + EnumValueToString("EInputKey", Cast<Int64>(EnumInt(this.m_settings.keyCall))) + " handler=" + ToString(IsDefined(this.m_footH)) + " registered=" + ToString(this.m_footH.IsRegistered()) + " clockPaused=" + ToString(this.ClockPaused()));
  }

  public func StopFoot() -> Void {
    if !this.m_footOn {
      return;
    };
    if IsDefined(this.m_footH) {
      this.m_footH.Unregister();
      this.m_footH = null;
    };
    this.m_footOn = false;
    this.m_callHeld = false;
    this.m_tapArmed = false;
    this.m_l3 = false;
    this.m_r3 = false;
  }

  // Raw keys also arrive while a menu is open: presses are ignored while the game is paused, releases never.
  // IsPausedState is the game CLOCK pause (quest time freeze, clock mods), not the menu pause: it is only logged.
  private func Paused() -> Bool {
    let bb: ref<IBlackboard> = GameInstance.GetBlackboardSystem(this.m_gi).Get(GetAllBlackboardDefs().UI_System);
    return IsDefined(bb) && bb.GetBool(GetAllBlackboardDefs().UI_System.IsInMenu);
  }

  private func ClockPaused() -> Bool {
    return GameInstance.GetTimeSystem(this.m_gi).IsPausedState();
  }

  public func FootKey(evt: ref<KeyInputEvent>) -> Bool {
    let key: EInputKey = evt.GetKey();
    let act: EInputAction = evt.GetAction();
    let pressed: Bool = Equals(act, EInputAction.IACT_Press);
    if !pressed && !Equals(act, EInputAction.IACT_Release) {
      return false;
    };
    if pressed && this.m_rawFoot < 20 {
      this.m_rawFoot += 1;
      this.Diag("raw foot press " + EnumValueToString("EInputKey", Cast<Int64>(EnumInt(key))) + " inMenu=" + ToString(this.Paused()) + " clockPaused=" + ToString(this.ClockPaused()));
    };
    if pressed && this.Paused() {
      return false;
    };
    if Equals(key, this.m_settings.keyCall) {
      if pressed {
        this.Diag("call key down");
      };
      this.lastPad = false;
      // a tap = released within 0.4 s; the hold (0.8 s) stays call / confirm / send away.
      // Build 19 (2026-11-28): a DOUBLE tap (second release within 0.6 s of the first) = "come to me"; a single
      // tap does nothing any more (build 14's single-tap landing is gone, no accidental landings).
      let tap: Bool = !pressed && this.m_callHeld && this.Now() - this.m_callSince < 0.4 && !this.Paused();
      if pressed && !this.m_callHeld {
        this.m_callSince = this.Now();
      };
      this.m_callHeld = pressed;
      if pressed {
        this.ScheduleHold(false);
      };
      if tap {
        let now: Float = this.Now();
        if this.m_tapArmed && now - this.m_tapAt < 0.6 {
          this.m_tapArmed = false;
          this.Diag("call key double tap");
          if IsDefined(this.m_sys) {
            this.m_sys.OnCallDoubleTap();
          };
        } else {
          this.m_tapArmed = true;
          this.m_tapAt = now;
        };
      };
      return false;
    };
    if Equals(key, this.m_settings.keyBoard) && pressed {
      if IsDefined(this.m_sys) {
        this.m_sys.OnBoardPressed();
      };
    };
    return false;
  }

  private func ScheduleHold(chord: Bool) -> Void {
    this.m_token += 1;
    let cb: ref<AVFHoldCheck> = new AVFHoldCheck();
    cb.input = this;
    cb.token = this.m_token;
    cb.chord = chord;
    GameInstance.GetDelaySystem(this.m_gi).DelayCallback(cb, 0.8, false);
  }

  public func OnHoldCheck(token: Int32, chord: Bool) -> Void {
    if token != this.m_token {
      return;
    };
    let held: Bool = chord ? (this.m_l3 && this.m_r3) : this.m_callHeld;
    this.Diag("hold check held=" + ToString(held) + " inMenu=" + ToString(this.Paused()) + " clockPaused=" + ToString(this.ClockPaused()) + " sys=" + ToString(IsDefined(this.m_sys)));
    if held && IsDefined(this.m_sys) && !this.Paused() {
      this.m_sys.OnCallHold();
    };
  }

  // ---------------------------------------------------------------- pilot

  public func StartPilot() -> Void {
    if !IsDefined(this.m_settings) {
      this.m_settings = AVFSettings.Get(this.m_gi);
    };
    if this.m_pilotOn || !IsDefined(this.m_settings) {
      this.Diag("pilot keys NOT started: on=" + ToString(this.m_pilotOn) + " settings=" + ToString(IsDefined(this.m_settings)));
      return;
    };
    let sys: ref<AVFSystem> = this.m_sys;
    if !IsDefined(sys) {
      this.Diag("pilot keys NOT started: system missing");
      return;
    };
    this.ClearPilot();
    let s: ref<AVFSettings> = this.m_settings;
    let cs: ref<CallbackSystem> = GameInstance.GetCallbackSystem();
    this.m_pilotKeyH = cs.RegisterCallback(n"Input/Key", sys, n"OnAVFPilotKey");
    this.m_pilotKeyH.AddTarget(InputTarget.Key(s.keyThrottleUp));
    this.m_pilotKeyH.AddTarget(InputTarget.Key(s.keyThrottleDown));
    this.m_pilotKeyH.AddTarget(InputTarget.Key(s.keyTurnLeft));
    this.m_pilotKeyH.AddTarget(InputTarget.Key(s.keyTurnRight));
    this.m_pilotKeyH.AddTarget(InputTarget.Key(s.keyClimb));
    this.m_pilotKeyH.AddTarget(InputTarget.Key(s.keyDescend));
    this.m_pilotKeyH.AddTarget(InputTarget.Key(s.keyHover));
    this.m_pilotKeyH.AddTarget(InputTarget.Key(s.keyAutopilot));
    this.m_pilotKeyH.AddTarget(InputTarget.Key(EInputKey.IK_Pad_DigitUp));
    this.m_pilotKeyH.AddTarget(InputTarget.Key(EInputKey.IK_Pad_A_CROSS));
    this.m_pilotAxisH = cs.RegisterCallback(n"Input/Axis", sys, n"OnAVFPilotAxis");
    this.m_pilotAxisH.AddTarget(InputTarget.Axis(EInputKey.IK_Pad_RightTrigger));
    this.m_pilotAxisH.AddTarget(InputTarget.Axis(EInputKey.IK_Pad_LeftTrigger));
    this.m_pilotAxisH.AddTarget(InputTarget.Axis(EInputKey.IK_Pad_LeftAxisX));
    this.m_pilotAxisH.AddTarget(InputTarget.Axis(EInputKey.IK_Pad_LeftAxisY));
    this.m_pilotOn = true;
    this.m_rawPilot = 0;
    this.Diag("diag2 pilot keys on, climb key " + EnumValueToString("EInputKey", Cast<Int64>(EnumInt(s.keyClimb))) + " registered=" + ToString(this.m_pilotKeyH.IsRegistered()) + " clockPaused=" + ToString(this.ClockPaused()));
  }

  public func StopPilot() -> Void {
    if !this.m_pilotOn {
      return;
    };
    let cs: ref<CallbackSystem> = GameInstance.GetCallbackSystem();
    if IsDefined(this.m_pilotKeyH) {
      this.m_pilotKeyH.Unregister();
      this.m_pilotKeyH = null;
    };
    if IsDefined(this.m_pilotAxisH) {
      this.m_pilotAxisH.Unregister();
      this.m_pilotAxisH = null;
    };
    this.m_pilotOn = false;
    this.ClearPilot();
  }

  public func IsPilotOn() -> Bool {
    return this.m_pilotOn;
  }

  public func IsFootOn() -> Bool {
    return this.m_footOn;
  }

  public func ClearPilot() -> Void {
    this.up = false;
    this.down = false;
    this.left = false;
    this.right = false;
    this.climb = false;
    this.descend = false;
    this.hover = false;
    this.tapsUp = 0;
    this.tapsDown = 0;
    this.rt = 0.0;
    this.lt = 0.0;
    this.lx = 0.0;
    this.ly = 0.0;
    this.padHover = false;
    this.ap = false;
  }

  public func PilotKey(evt: ref<KeyInputEvent>) -> Bool {
    let key: EInputKey = evt.GetKey();
    let act: EInputAction = evt.GetAction();
    let pressed: Bool = Equals(act, EInputAction.IACT_Press);
    if !pressed && !Equals(act, EInputAction.IACT_Release) {
      return false;
    };
    if pressed && this.m_rawPilot < 30 {
      this.m_rawPilot += 1;
      this.Diag("raw pilot press " + EnumValueToString("EInputKey", Cast<Int64>(EnumInt(key))) + " inMenu=" + ToString(this.Paused()) + " clockPaused=" + ToString(this.ClockPaused()));
    };
    if pressed && this.Paused() {
      return false;
    };
    let s: ref<AVFSettings> = this.m_settings;
    if pressed && Equals(key, s.keyClimb) {
      this.Diag("climb key down");
    };
    if Equals(key, s.keyAutopilot) || Equals(key, EInputKey.IK_Pad_DigitUp) {
      if pressed && !this.ap {
        this.apSince = this.Now();
      };
      this.ap = pressed;
      return false;
    };
    if Equals(key, EInputKey.IK_Pad_A_CROSS) {
      this.padHover = pressed;
      this.lastPad = true;
      return false;
    };
    this.lastPad = false;
    if Equals(key, s.keyThrottleUp) {
      if pressed && !this.up {
        this.upSince = this.Now();
      } else {
        if !pressed && this.up && this.Now() - this.upSince < 0.25 {
          this.tapsUp += 1;
        };
      };
      this.up = pressed;
    } else {
      if Equals(key, s.keyThrottleDown) {
        if pressed && !this.down {
          this.downSince = this.Now();
        } else {
          if !pressed && this.down && this.Now() - this.downSince < 0.25 {
            this.tapsDown += 1;
          };
        };
        this.down = pressed;
      } else {
        if Equals(key, s.keyTurnLeft) {
          this.left = pressed;
        } else {
          if Equals(key, s.keyTurnRight) {
            this.right = pressed;
          } else {
            if Equals(key, s.keyClimb) {
              this.climb = pressed;
            } else {
              if Equals(key, s.keyDescend) {
                this.descend = pressed;
              } else {
                if Equals(key, s.keyHover) {
                  this.hover = pressed;
                };
              };
            };
          };
        };
      };
    };
    return false;
  }

  public func PilotAxis(evt: ref<AxisInputEvent>) -> Bool {
    let key: EInputKey = evt.GetKey();
    let v: Float = evt.GetValue();
    if Equals(key, EInputKey.IK_Pad_RightTrigger) {
      this.rt = ClampF(v, 0.0, 1.0);
    } else {
      if Equals(key, EInputKey.IK_Pad_LeftTrigger) {
        this.lt = ClampF(v, 0.0, 1.0);
      } else {
        if Equals(key, EInputKey.IK_Pad_LeftAxisX) {
          this.lx = ClampF(v, -1.0, 1.0);
        } else {
          if Equals(key, EInputKey.IK_Pad_LeftAxisY) {
            this.ly = ClampF(v, -1.0, 1.0);
          } else {
            // not one of the four targets: never read it as the left stick
            if this.m_rawAxisOther < 5 {
              this.m_rawAxisOther += 1;
              this.Diag("axis event from an untargeted key " + EnumValueToString("EInputKey", Cast<Int64>(EnumInt(key))) + " value " + FloatToStringPrec(v, 2));
            };
            return false;
          };
        };
      };
    };
    if AbsF(v) > 0.2 {
      this.lastPad = true;
    };
    return false;
  }

  // Seconds a throttle key has been held (0 when up).
  public func HeldUp() -> Float {
    return this.up ? this.Now() - this.upSince : 0.0;
  }

  public func HeldDown() -> Float {
    return this.down ? this.Now() - this.downSince : 0.0;
  }

  public func HeldAp() -> Float {
    return this.ap ? this.Now() - this.apSince : 0.0;
  }
}
