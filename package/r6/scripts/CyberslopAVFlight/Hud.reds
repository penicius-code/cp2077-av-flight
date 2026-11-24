// Cyberslop AV Flight 1.0.0 - three text lines on the HUD layer (flight data, keys for the situation, charter meter)
// and onscreen messages. Built once, updated 5 times a second by the system, hidden when there is nothing to say.
module CyberslopAVFlight

public class AVFHud extends IScriptable {
  private let m_gi: GameInstance;
  private let m_root: wref<inkCanvas>;
  private let m_data: wref<inkText>;
  private let m_keys: wref<inkText>;
  private let m_meter: wref<inkText>;
  private let m_shown: Bool;
  private let m_warned: Bool;
  // the last message, also shown on the middle line of this panel (the warning pop-up may be hidden by HUD mods)
  public let msg: String;
  public let msgLeft: Float;

  public func Init(gi: GameInstance) -> Void {
    this.m_gi = gi;
  }

  private func MakeText(parent: ref<inkCompoundWidget>, name: CName, size: Int32, color: HDRColor) -> ref<inkText> {
    let t: ref<inkText> = new inkText();
    t.SetName(name);
    t.SetFontFamily("base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily");
    t.SetFontStyle(n"Medium");
    t.SetFontSize(size);
    t.SetTintColor(color);
    t.SetHAlign(inkEHorizontalAlign.Center);
    t.SetHorizontalAlignment(textHorizontalAlignment.Center);
    t.SetFitToContent(true);
    t.SetText("");
    t.Reparent(parent);
    return t;
  }

  private func Ensure() -> Bool {
    if IsDefined(this.m_root) {
      return true;
    };
    let layer: ref<inkLayerWrapper> = GameInstance.GetInkSystem().GetLayer(n"inkHUDLayer");
    if !IsDefined(layer) {
      if !this.m_warned {
        this.m_warned = true;
        AVFSystem.LogLine(this.m_gi, "hud: inkHUDLayer missing, no panel");
      };
      return false;
    };
    let window: ref<inkVirtualWindow> = layer.GetVirtualWindow();
    if !IsDefined(window) {
      if !this.m_warned {
        this.m_warned = true;
        AVFSystem.LogLine(this.m_gi, "hud: the HUD layer has no virtual window, no panel");
      };
      return false;
    };
    window.RemoveChildByName(n"CyberslopAVFlightHud");   // a load can keep the HUD layer: never two panels
    let root: ref<inkCanvas> = new inkCanvas();
    root.SetName(n"CyberslopAVFlightHud");
    root.SetAnchor(inkEAnchor.BottomCenter);
    root.SetAnchorPoint(0.5, 1.0);
    root.SetSize(1400.0, 140.0);
    root.SetMargin(new inkMargin(0.0, 0.0, 0.0, 150.0));
    root.Reparent(window);
    let panel: ref<inkVerticalPanel> = new inkVerticalPanel();
    panel.SetName(n"lines");
    panel.SetAnchor(inkEAnchor.BottomCenter);
    panel.SetAnchorPoint(0.5, 1.0);
    panel.SetHAlign(inkEHorizontalAlign.Center);
    panel.SetVAlign(inkEVerticalAlign.Bottom);
    panel.SetFitToContent(true);
    panel.Reparent(root);
    this.m_data = this.MakeText(panel, n"data", 32, new HDRColor(0.369, 0.965, 1.0, 1.0));
    this.m_keys = this.MakeText(panel, n"keys", 24, new HDRColor(0.94, 0.94, 0.94, 0.9));
    this.m_meter = this.MakeText(panel, n"meter", 24, new HDRColor(1.0, 0.82, 0.38, 0.95));
    root.SetVisible(false);
    this.m_root = root;
    this.m_shown = false;
    AVFSystem.LogLine(this.m_gi, "hud panel created");
    return true;
  }

  public func Show(data: String, keys: String, meter: String) -> Void {
    if !this.Ensure() {
      return;
    };
    this.m_data.SetText(data);
    this.m_data.SetVisible(StrLen(data) > 0);
    let k: String = keys;
    if this.msgLeft > 0.0 {
      k = this.msg;
    };
    this.m_keys.SetText(k);
    this.m_keys.SetVisible(StrLen(k) > 0);
    this.m_meter.SetText(meter);
    this.m_meter.SetVisible(StrLen(meter) > 0);
    let any: Bool = StrLen(data) > 0 || StrLen(k) > 0 || StrLen(meter) > 0;
    if NotEquals(any, this.m_shown) {
      this.m_root.SetVisible(any);
      this.m_shown = any;
    };
  }

  public func Age(dt: Float) -> Void {
    if this.msgLeft > 0.0 {
      this.msgLeft -= dt;
    };
  }

  public func Hide() -> Void {
    if this.msgLeft > 0.0 {
      this.Show("", "", "");
      return;
    };
    if this.m_shown && IsDefined(this.m_root) {
      this.m_root.SetVisible(false);
    };
    this.m_shown = false;
  }

  // Session end: the HUD layer is rebuilt, the widget goes with it.
  public func Forget() -> Void {
    this.m_root = null;
    this.m_data = null;
    this.m_keys = null;
    this.m_meter = null;
    this.m_shown = false;
  }

  public func Message(text: String, seconds: Float) -> Void {
    let msg: SimpleScreenMessage;
    msg.isShown = true;
    msg.duration = seconds;
    msg.message = text;
    msg.isInstant = true;
    this.msg = text;
    this.msgLeft = seconds;
    GameInstance.GetBlackboardSystem(this.m_gi).Get(GetAllBlackboardDefs().UI_Notifications).SetVariant(GetAllBlackboardDefs().UI_Notifications.WarningMessage, ToVariant(msg), true);
  }
}
