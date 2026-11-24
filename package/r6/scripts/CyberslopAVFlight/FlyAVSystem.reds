// Cyberslop AV Flight 1.0.0 - native flight physics of DriveAerialVehicle.dll
// (Drive an Aerial Vehicle 3.5.0, MIT License, Copyright (C) 2024 tidusmd), registered by the DLL as FlyAVSystem.
// Only the calls this mod uses are declared. Semantics of these calls, as found by analysing the DLL:
//   SetVehicle: low 32 bits of the entity hash; switches the game's own physics back on every time.
//   SetFlightControl mode 1: force += velocity * mass and torque += (angularVelocity - angvel_now) * torqueGain
//   on every physics step, world axes, rad/s. Mode 0: nothing. The DLL holds the last command.
//   EnableOriginalPhysics(false): every game force on the bound vehicle is dropped (no drag, no damping).
// No module line: the class binds to the DLL's RTTI class by its global name.

public native class FlyAVSystem extends IScriptable {
  public native func SetVehicle(entity_id_hash: Uint32) -> Float;
  public native func EnableOriginalPhysics(is_enable: Bool) -> Float;
  public native func EnableGravity(is_enable: Bool) -> Float;
  public native func GetMass() -> Float;
  public native func GetVelocity() -> Vector3;
  public native func GetAngularVelocity() -> Vector3;
  public native func UnsetPhysicsState() -> Float;
  public native func IsOnGround() -> Bool;
  public native func GetNativeTickCount() -> Float;
  public native func SetFlightControl(mode: Float, velocity: Vector3, angularVelocity: Vector3, torqueGain: Float) -> Float;
}
