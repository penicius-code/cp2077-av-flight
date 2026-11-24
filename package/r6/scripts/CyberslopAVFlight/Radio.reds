// Cyberslop AV Flight 1.0.0 - car radio in the aircraft.
// The charter AVs and the Night Hunter use the Basilisk's audio entry v_av_basilisk_tank
// (base\sound\metadata\cooked_metadata.audio_metadata). That entry has no radio receiver
// (hasRadioReceiver = false), so the radio list opens but no station plays. This switches the receiver on
// for that entry, as Drive an Aerial Vehicle did (radio_car_hyper_player); the engine sound data is left
// as it is. Runtime only, once per session; side effect: the vanilla Basilisk gets a radio as well.
module CyberslopAVFlight

public abstract class AVFRadio {
  // Returns "on", "already on" or the reason it could not be done (then it is tried again later).
  public static func Enable(out token: ref<ResourceToken>) -> String {
    let depot: ref<ResourceDepot> = GameInstance.GetResourceDepot();
    if !IsDefined(depot) {
      return "no resource depot";
    };
    token = depot.LoadResource(r"base\\sound\\metadata\\cooked_metadata.audio_metadata");
    if !IsDefined(token) {
      return "no resource token";
    };
    let cooked: ref<audioCookedMetadataResource> = token.GetResource() as audioCookedMetadataResource;
    if !IsDefined(cooked) {
      return "audio metadata not loaded yet";
    };
    for entry in cooked.entries {
      let veh: ref<audioVehicleMetadata> = entry as audioVehicleMetadata;
      if IsDefined(veh) && Equals(veh.name, n"v_av_basilisk_tank") {
        if veh.hasRadioReceiver && Equals(veh.radioReceiverType, n"radio_car_hyper_player") {
          return "already on";
        };
        let was: String = ToString(veh.hasRadioReceiver) + " / " + NameToString(veh.radioReceiverType);
        veh.hasRadioReceiver = true;
        veh.radioReceiverType = n"radio_car_hyper_player";
        return "on (was " + was + ")";
      };
    };
    return "entry v_av_basilisk_tank not found";
  }
}
