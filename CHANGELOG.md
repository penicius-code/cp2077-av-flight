# Changelog

Version 1.0.0 was developed in numbered builds on game version 2.5. "Flown" means the build was flown in game; "not flown" means compile-checked only.

## build 19 - 2026-11-28
### Changed
- The charter lands side-on with its left (door) side towards you, the hull side about 3 m from your feet at your own level (then 5.5 m, then the old 14 to 32 m rings). It turns to that heading while still 8 m or more up and never comes down while you stand under the hull.
- Touchdown without the twitch: a steady 0.4 m/s sink for the last 0.9 m, and the aircraft is handed back to the game as soon as the gear stands on the ground (before, it waited until it was within 4 cm of a remembered resting height that changed between landings). Applies to arrival, fetch, your own landings and the autopilot's pin landing. Letting go of the controls less than 0.5 m over the ground settles it by itself.
- The front-left door opens when you walk up to it and closes when you walk away; take-off, send-away and the fetch close it.
- Getting out in the air puts you beside the hull, 1.3 m clear of its side, and you fall; before, you were left standing on the roof.
- Double tap `K` (second release within 0.6 s) brings a holding or landed aircraft to you; double tap again while it comes stops it. A single tap does nothing now (build 14's tap landed the aircraft 14 to 32 m away). Hold `K` is unchanged.

## build 18 - 2026-11-26
### Added
- Mod Settings "Your seat": front left (pilot), front right, back left, back right (default). You fly from any seat: the flight keys and the pad are read directly, not through the driver controls. Right-hand seats get out on the right. The Atlus has no front right seat, so that choice takes the front left there.
### Fixed
- Take-off switches the vehicle on as well as the engine; the game only does that for a driver-seat mount.

## build 17 - 2026-11-25
### Changed
- Mod Settings "Fly the NCPD Night Hunter", off by default. Off, the mod leaves that vehicle alone and it drives as its quest mod ships it. The author found it broken under the mod's controller; the cause was not looked into.

Builds 17 to 19 compile on 2.5 (0 errors; the 7 warnings come from other mods) and are not flown yet. The two publication changes below are kept.

## Changes made for publication - 2026-11-24
- The charter arrival time uses its formula again (dispatch distance over cruise speed plus 30 seconds, between 40 and 300 seconds). A fixed 10 seconds had been left in from testing.
- The debug log is off by default.
- The other author's DLL and archive, and the height map generated from that mod's data, are not part of this repository.

## 1.0.0 build 16 - 2026-11-23
- Stick and confirm button no longer fly the aircraft while a radio list, vehicle list or menu is open.
- Changed call / board / pilot keys apply at once.
- Messages: the "holding until you are on foot" note shows for every charter; an abandoned or destroyed charter shows reason and bill in one message; the restored bill from the last session is shown.

Not flown.

## build 15 - 2026-11-23
- A charter that is sent away climbs above the tallest mapped building on its way out.

Not flown.

## build 14 - 2026-11-23
- Tap the call key on foot: a hovering aircraft flies to an open spot near you and lands.

Not flown.

## build 13 - 2026-11-23
- Hover hold: an aircraft you leave in the air brakes, holds altitude and keeps its engines running.

Flown: works.

## build 12 - 2026-11-23
- The radio plays in the cabin (the aircraft's audio entry gets a radio receiver at runtime).

Not flown.

## build 11 - 2026-11-23
- The autopilot ends only by its own key.

Flown: "works great", radio silent in the cabin; one "departure aborted" fault seen.

## build 10 - 2026-11-22
- No flight input while a list or menu is open (first version).

## build 9 - 2026-11-22
- Autopilot version 2 over a building height map. Vertical speed setting. Pin selection fix.

Flown: the autopilot works.

## build 8 - 2026-11-22
- Flare before touchdown and a clean hand-back to the game's physics. First autopilot (forward checks only). Canopy option, part placement, 28 liveries.

Flown: landing smooth; the autopilot flew into buildings.

## build 7 - 2026-11-22
- Velocity-target control mode instead of force and torque, after the aircraft tumbled.

Flown: first complete flight.

## build 6 - 2026-11-22
- Clean-up when the piloted aircraft vanishes. DLL functions without parameters are only used as whole statements. Idle tick at 4 Hz.

## build 5 - 2026-11-22
- Session-relative clock, touchdown test for a blocked descent, approach watchdog with refund.

## builds 2 to 4 - 2026-11-22
- Fixed: keys did nothing (key callbacks moved to the mod's system object).
- Fixed: the tick stalled after one frame (timed callback with a watchdog).
- Fixed: crash one second after a spawn (every call into the DLL assigns its result).

## build 1 - 2026-11-22
- First install.
