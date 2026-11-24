// Cyberslop AV Flight 1.0.0 - per-aircraft cosmetics taken from Drive an Aerial Vehicle 3.5.0 (MIT, tidusmd):
//   - the engine / thruster components of DAV's aircraft entities are re-pivoted, and DAV puts them in place
//     after every spawn (Data\default_model.json engine_component_offset / thruster_fx_offset, av.lua
//     SetThrusterComponent). Without it the Excalibur's thruster pods hang 0.45 / 0.65 m too low and the
//     Atlus's engines sit at the aircraft's origin.
//   - the crystal dome (see-through cabin of the Excalibur and the Manticore), switched through the game's own
//     VehicleQuestCrystalDomeEvent, the same path a quest uses.
module CyberslopAVFlight

// Entity.FindComponentByName is protected: this opens it for the vehicle.
@addMethod(VehicleObject)
public final func AVF_Component(name: CName) -> ref<IComponent> {
  return this.FindComponentByName(name);
}

public abstract class AVFParts {

  private final static func Place(veh: ref<VehicleObject>, name: CName, x: Float, y: Float, z: Float) -> Int32 {
    let c: ref<IPlacedComponent> = veh.AVF_Component(name) as IPlacedComponent;
    if !IsDefined(c) {
      return 0;
    };
    c.SetLocalPosition(new Vector4(x, y, z, 1.0));
    return 1;
  }

  private final static func Slots(veh: ref<VehicleObject>, fx: Float, fy: Float, fz: Float, bx: Float, by: Float, bz: Float) -> Int32 {
    let n: Int32 = 0;
    n += AVFParts.Place(veh, n"SlotThrusterFL", -fx, fy, fz);
    n += AVFParts.Place(veh, n"SlotThrusterFR", fx, fy, fz);
    n += AVFParts.Place(veh, n"SlotThrusterBL", -bx, by, bz);
    n += AVFParts.Place(veh, n"SlotThrusterBR", bx, by, bz);
    return n;
  }

  // Returns how many components were found and placed (0 = none of the names exist on this entity).
  public final static func Apply(veh: ref<VehicleObject>, key: String) -> Int32 {
    let n: Int32 = 0;
    if Equals(key, "excalibur") {
      n += AVFParts.Place(veh, n"engine_01_fl_a", 0.0, 0.0, 0.0);
      n += AVFParts.Place(veh, n"engine_01_fr_a", 0.0, 0.0, 0.0);
      n += AVFParts.Place(veh, n"engine_01_bl_a", 0.0, 0.0, 0.0);
      n += AVFParts.Place(veh, n"engine_01_br_a", 0.0, 0.0, 0.0);
      n += AVFParts.Place(veh, n"thruster_01_fl_a", 0.0, 0.0, 0.45);
      n += AVFParts.Place(veh, n"thruster_01_fr_a", 0.0, 0.0, 0.45);
      n += AVFParts.Place(veh, n"thruster_01_bl_a", 0.0, 0.0, 0.65);
      n += AVFParts.Place(veh, n"thruster_01_br_a", 0.0, 0.0, 0.65);
      n += AVFParts.Slots(veh, 0.95, 3.35, 0.0, 1.55, -3.3, 0.5);
      return n;
    };
    if Equals(key, "manticore") {
      n += AVFParts.Place(veh, n"engine_fl_01", 0.0, 0.0, 0.0);
      n += AVFParts.Place(veh, n"engine_fr_01", 0.0, 0.0, 0.0);
      n += AVFParts.Place(veh, n"engine_bl_01", 0.0, 0.0, 0.0);
      n += AVFParts.Place(veh, n"engine_br_01", 0.0, 0.0, 0.0);
      n += AVFParts.Slots(veh, 1.4, 3.4, 0.0, 1.4, -3.4, 0.0);
      return n;
    };
    if Equals(key, "atlus") {
      n += AVFParts.Place(veh, n"av_zetatech_atlus__ext01_engines_fl", -1.55, 2.4, 1.2);
      n += AVFParts.Place(veh, n"av_zetatech_atlus__ext01_engines_fr", 1.55, 2.4, 1.2);
      n += AVFParts.Place(veh, n"av_zetatech_atlus__ext01_engines_bl", -1.45, -2.95, 1.0);
      n += AVFParts.Place(veh, n"av_zetatech_atlus__ext01_engines_br", 1.45, -2.95, 1.0);
      n += AVFParts.Slots(veh, 1.55, 2.2, 1.2, 1.45, -2.75, 1.0);
      return n;
    };
    if Equals(key, "surveyor") {
      n += AVFParts.Place(veh, n"engine_fl_01", 0.0, 0.0, 0.0);
      n += AVFParts.Place(veh, n"engine_fr_01", 0.0, 0.0, 0.0);
      n += AVFParts.Place(veh, n"engine_bl_01", 0.0, 0.0, 0.0);
      n += AVFParts.Place(veh, n"engine_br_01", 0.0, 0.0, 0.0);
      n += AVFParts.Slots(veh, 1.75, 4.85, 0.0, 1.75, -4.9, 0.0);
      return n;
    };
    return 0;
  }

  // Appearance name of DAV's aircraft entity for the livery picked in Mod Settings (names as in the .ent files,
  // "trama_team" is the entity's own spelling).
  public final static func Livery(key: String, s: ref<AVFSettings>, fallback: CName) -> CName {
    let i: Int32;
    if Equals(key, "excalibur") {
      i = EnumInt(s.skinExcalibur);
      if i == 1 { return n"delamain"; };
      if i == 2 { return n"arasaka"; };
      if i == 3 { return n"saburo_arasaka"; };
      if i == 4 { return n"nusa_myers"; };
      return n"premium";
    };
    if Equals(key, "atlus") {
      i = EnumInt(s.skinAtlus);
      if i == 1 { return n"trama_team"; };
      if i == 2 { return n"arasaka"; };
      if i == 3 { return n"ncpd"; };
      if i == 4 { return n"stealth"; };
      if i == 5 { return n"stealth_cloaked"; };
      if i == 6 { return n"fia"; };
      return n"n54_news";
    };
    if Equals(key, "manticore") {
      i = EnumInt(s.skinManticore);
      if i == 1 { return n"ncpd"; };
      if i == 2 { return n"trauma_team"; };
      if i == 3 { return n"trauma_team_nusa"; };
      if i == 4 { return n"barghest"; };
      if i == 5 { return n"manticore_dumdum"; };
      return n"manticore";
    };
    if Equals(key, "surveyor") {
      i = EnumInt(s.skinSurveyor);
      if i == 1 { return n"maxtac"; };
      if i == 2 { return n"arasaka"; };
      return n"kangtao";
    };
    if Equals(key, "valgus") {
      i = EnumInt(s.skinValgus);
      if i == 1 { return n"border_patrol"; };
      if i == 2 { return n"arasaka"; };
      if i == 3 { return n"nusa"; };
      if i == 4 { return n"max_tac"; };
      return n"valgus";
    };
    if Equals(key, "mayhem") {
      i = EnumInt(s.skinMayhem);
      if i == 1 { return n"max_tac_attack"; };
      return n"valgus_attack";
    };
    return fallback;
  }

  public final static func HasDome(key: String) -> Bool {
    return Equals(key, "excalibur") || Equals(key, "manticore");
  }

  public final static func SetDome(gi: GameInstance, veh: ref<VehicleObject>, on: Bool) -> Void {
    let ps: ref<VehicleComponentPS> = veh.GetVehiclePS();
    if !IsDefined(ps) {
      return;
    };
    let evt: ref<VehicleQuestCrystalDomeEvent> = new VehicleQuestCrystalDomeEvent();
    evt.toggle = on;
    evt.removeQuestControl = !on;
    GameInstance.GetPersistencySystem(gi).QueuePSEvent(ps.GetID(), ps.GetClassName(), evt);
  }
}
