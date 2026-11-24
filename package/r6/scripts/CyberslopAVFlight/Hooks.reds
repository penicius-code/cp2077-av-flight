// Cyberslop AV Flight 1.0.0 - the only game hooks: V's mount / unmount events (called once per seat change),
// and the exit side for the charter AV (forced to the driver's side as Drive an Aerial Vehicle does, so the
// vanilla exit never tries a car's passenger-seat swap). The exit-side wraps only run when V presses exit.
module CyberslopAVFlight

@wrapMethod(PlayerPuppet)
protected cb func OnMountingEvent(evt: ref<MountingEvent>) -> Bool {
  let r: Bool = wrappedMethod(evt);
  let veh: ref<VehicleObject> = GameInstance.FindEntityByID(this.GetGame(), evt.request.lowLevelMountingInfo.parentId) as VehicleObject;
  AVFSystem.LogLine(this.GetGame(), "diag mount event veh=" + ToString(IsDefined(veh)) + " me=" + ToString(evt.request.lowLevelMountingInfo.childId == this.GetEntityID()) + " sys=" + ToString(IsDefined(AVFSystem.Get(this.GetGame()))));
  if IsDefined(veh) && evt.request.lowLevelMountingInfo.childId == this.GetEntityID() {
    let sys: ref<AVFSystem> = AVFSystem.Get(this.GetGame());
    if IsDefined(sys) {
      sys.OnPlayerMounted(veh, evt.request.lowLevelMountingInfo.slotId.id);
    };
  };
  return r;
}

@wrapMethod(PlayerPuppet)
protected cb func OnUnmountingEvent(evt: ref<UnmountingEvent>) -> Bool {
  let veh: ref<VehicleObject> = GameInstance.FindEntityByID(this.GetGame(), evt.request.lowLevelMountingInfo.parentId) as VehicleObject;
  let r: Bool = wrappedMethod(evt);
  if IsDefined(veh) && evt.request.lowLevelMountingInfo.childId == this.GetEntityID() {
    let sys: ref<AVFSystem> = AVFSystem.Get(this.GetGame());
    if IsDefined(sys) {
      sys.OnPlayerUnmounted(veh);
    };
  };
  return r;
}

@wrapMethod(VehicleTransition)
protected final func IsUnmountDirectionClosest(stateContext: ref<StateContext>, unmountDirection: vehicleExitDirection) -> Bool {
  let sys: ref<AVFSystem> = AVFSystem.Get(GetGameInstance());
  if IsDefined(sys) && sys.InCharterSeat() {
    return true;
  };
  return wrappedMethod(stateContext, unmountDirection);
}

@wrapMethod(VehicleTransition)
protected final func IsUnmountDirectionOpposite(stateContext: ref<StateContext>, unmountDirection: vehicleExitDirection) -> Bool {
  let sys: ref<AVFSystem> = AVFSystem.Get(GetGameInstance());
  if IsDefined(sys) && sys.InCharterSeat() {
    return false;
  };
  return wrappedMethod(stateContext, unmountDirection);
}
