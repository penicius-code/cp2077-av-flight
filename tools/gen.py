"""Generate the data files of Cyberslop AV Flight from one table:
  build\r6\tweaks\CyberslopAVFlight\avflight.yaml   (TweakXL records, camera presets)
  build\r6\scripts\CyberslopAVFlight\Data.reds      (per-model flight / charter data, depot pads)

Usage: python -I -X utf8 gen.py <ltbf helipads.tsv> <build root>
"""
import math
import os
import sys

G = 9.81

# DAV 3.5.0 (MIT, tidusmd): entity templates, base records, inline packages, entry / exit points, camera ratios
# (Data\default_model.json, init.lua:170-344). Flight numbers: power vs drag (plan) cross-checked with a separate
# SPEEDS.md; burn: jet-lift momentum theory for the AVs (research\COST.md), real helicopter figures for Valgus / Mayhem.
MODELS = [
    dict(key='excalibur', name='Rayfield Excalibur', kind=0,
         base='Vehicle.av_rayfield_excalibur', vdp='Vehicle.av_rayfield_excalibur_inline0', exit_delay=2.3,
         ent=r'base\dav\excalibur\av_rayfield_excalibur__basic_01_dav.ent', app='premium', destroyed=None,
         vmax=118, accel=4.0, brake=4.8, climb=10.0, descent=7.0, yaw=45, pitch=0.35,
         dispatch=2800, rent=1800, burn=(26, 33, 46), hull=250000,
         L=10.5, W=3.8, H=2.5, entry=(-1.0, 0.0, -1.0), entry_r=2.5, exit=(-2.5, 0.0, 0.0),
         cam=1.2, look=(0.0, 0.0, 1.0)),
    dict(key='atlus', name='Zetatech Atlus', kind=0,
         base='Vehicle.av_zetatech_atlus', vdp='Vehicle.av_zetatech_atlus_inline0', exit_delay=1.2,
         ent=r'base\dav\atlus\av_zetatech_atlus_basic_02_dav.ent', app='n54_news', destroyed=None,
         vmax=105, accel=3.0, brake=3.6, climb=9.0, descent=7.0, yaw=35, pitch=0.35,
         dispatch=3200, rent=2100, burn=(40, 52, 73), hull=300000,
         L=9.6, W=5.2, H=3.0, entry=(-1.5, 0.0, -1.0), entry_r=3.0, exit=(-2.5, 0.0, 0.0),
         cam=1.0, look=(0.0, 0.0, 1.0)),
    dict(key='manticore', name='Militech Manticore', kind=0,
         base='Vehicle.av_militech_manticore', vdp='Vehicle.av_militech_manticore_inline0', exit_delay=1.2,
         ent=r'base\dav\manticore\av_militech_manticore_basic_01_dav.ent', app='manticore', destroyed='burnt',
         vmax=115, accel=3.5, brake=4.2, climb=11.0, descent=7.0, yaw=40, pitch=0.35,
         dispatch=5000, rent=3200, burn=(63, 83, 116), hull=400000,
         L=13.1, W=7.6, H=3.5, entry=(0.0, 0.0, -2.0), entry_r=4.0, exit=(-2.8, 0.0, -1.5),
         cam=1.5, look=(0.0, 0.0, 0.5)),
    dict(key='surveyor', name='Zetatech Surveyor', kind=0,
         base='Vehicle.av_zetatech_surveyor', vdp='Vehicle.av_zetatech_atlus_inline0', exit_delay=2.2,
         ent=r'base\dav\surveyor\av_zetatech_surveyor_basic_01_ep1_dav.ent', app='kangtao', destroyed=None,
         vmax=97, accel=2.5, brake=3.0, climb=7.0, descent=6.0, yaw=30, pitch=0.35,
         dispatch=3800, rent=2600, burn=(98, 119, 153), hull=500000,
         L=17.7, W=9.3, H=4.5, entry=(-2.0, 2.0, -2.0), entry_r=3.0, exit=(-3.2, 1.0, -1.0),
         cam=1.8, look=(0.0, 0.0, -1.0)),
    dict(key='valgus', name='Zetatech Valgus', kind=1,
         base='Vehicle.q000_nomad_border_patrol_heli', vdp='Vehicle.av_zetatech_valgus_inline0', exit_delay=0.8,
         ent=r'base\dav\valgus\q000_border_patrol_heli_dav.ent', app='valgus', destroyed='valgus_rusted',
         display='LocKey#77966', maker='Vehicle.Zetatech',
         vmax=85, accel=3.0, brake=3.6, climb=9.5, descent=5.0, yaw=50, pitch=1.0,
         dispatch=1900, rent=1200, burn=(7, 6, 9), hull=200000,
         L=24.4, W=9.8, H=4.0, entry=(-1.0, 1.0, -1.0), entry_r=3.0, exit=(-3.2, 1.0, 0.0),
         cam=2.1, look=(0.0, -5.0, 1.0)),
    dict(key='mayhem', name='Militech Mayhem', kind=1,
         base='Vehicle.q000_nomad_border_patrol_heli', vdp='Vehicle.av_zetatech_valgus_inline0', exit_delay=0.8,
         ent=r'base\dav\mayhem\q000_border_patrol_heli_mayhem_dav.ent', app='valgus_attack', destroyed='valgus_rusted',
         display='LocKey#88814', maker='Vehicle.Militech',
         vmax=88, accel=3.5, brake=4.2, climb=12.5, descent=5.0, yaw=50, pitch=1.0,
         dispatch=4500, rent=3000, burn=(11, 10, 14), hull=350000,
         L=24.4, W=9.8, H=4.0, entry=(-1.0, 1.0, -1.0), entry_r=3.0, exit=(-3.2, 1.0, 0.0),
         cam=2.1, look=(0.0, -5.0, 1.0)),
    # Oranje3 Night Hunter Quest (28931): world vehicle, never chartered. 54 t hover tank.
    dict(key='nighthunter', name='NCPD Night Hunter', kind=2, record='Vehicle.oranje3_night_hunter',
         vmax=70, accel=2.0, brake=2.5, climb=6.0, descent=5.0, yaw=25, pitch=0.25,
         dispatch=0, rent=0, burn=(0, 0, 0), hull=0,
         L=11.0, W=8.0, H=3.5, entry=(0.0, 0.0, 0.0), entry_r=0.0, exit=(0.0, 0.0, 0.0)),
]

PRESETS = [  # (suffix, vanilla base, boom offset)
    ('High_Close', 'Camera.VehicleTPP_4w_Preset_High_Close', 0.0),
    ('High_Medium', 'Camera.VehicleTPP_4w_Preset_High_Medium', 1.75),
    ('High_Far', 'Camera.VehicleTPP_4w_Preset_High_Far', 4.0),
    ('Low_Close', 'Camera.VehicleTPP_4w_Preset_Low_Close', 0.0),
    ('Low_Medium', 'Camera.VehicleTPP_4w_Preset_Low_Medium', 1.75),
    ('Low_Far', 'Camera.VehicleTPP_4w_Preset_Low_Far', 4.0),
]


def f(x):
    return ('%.4f' % x).rstrip('0').rstrip('.') if abs(x - round(x)) > 1e-9 else '%d.0' % round(x)


def yaml_text():
    out = ['# Cyberslop AV Flight 1.0.0 - charter AV records (generated by tools\\gen.py, do not edit by hand).',
           '# Entity templates and the base set-up come from Drive an Aerial Vehicle 3.5.0 (MIT, tidusmd).',
           '# The engine sound is the vanilla Basilisk / Night Hunter engine; its metadata is never changed.',
           '',
           'Vehicle.cyav_fpp_driver:',
           '  $base: Vehicle.VehicleDriverFPPCameraParamsDefault',
           '  forward_offset_value: -0.2',
           '  is_forward_offset: 1',
           '']
    for m in MODELS:
        if m['kind'] == 2:
            continue
        k = m['key']
        for suf, base, off in PRESETS:
            out += ['Camera.cyav_%s_%s:' % (k, suf),
                    '  $base: %s' % base,
                    '  baseBoomLength: %s' % f(5.0 * m['cam']),
                    '  boomLengthOffset: %s' % f(off * m['cam']),
                    '  lookAtOffset: { x: %s, y: %s, z: %s }' % tuple(f(v) for v in m['look']),
                    '']
        out += ['Vehicle.cyav_%s_vdp:' % k,
                '  $base: %s' % m['vdp'],
                '  exitDelay: %s' % f(m['exit_delay']),
                '  driverCombat: DriverCombatTypes.Disabled',
                '',
                'Vehicle.cyav_%s:' % k,
                '  $base: %s' % m['base'],
                '  entityTemplatePath: %s' % m['ent'],
                '  player_audio_resource: v_av_basilisk_tank',
                '  traffic_audio_resource: v_av_basilisk_tank_traffic',
                '  vehDataPackage: Vehicle.cyav_%s_vdp' % k,
                '  vehDriver_FPPCameraParams: Vehicle.cyav_fpp_driver',
                '  savable: false',
                '  isHackable: Vehicle.Never',
                '  weapons: []',
                '  tppCameraPresets:']
        out += ['    - Camera.cyav_%s_%s' % (k, suf) for suf, _, _ in PRESETS]
        if m.get('destroyed'):
            out.append('  destroyedAppearance: %s' % m['destroyed'])
        if m.get('display'):
            out.append('  displayName: %s' % m['display'])
        if m.get('maker'):
            out.append('  manufacturer: %s' % m['maker'])
        if m['kind'] == 1:
            out += ['  tags:', '    - InteractiveTrunk']
        out.append('')
    return '\n'.join(out)


def reds_text(pads):
    L = ['// Cyberslop AV Flight 1.0.0 - per-model data and depot pads (generated by tools\\gen.py, do not edit by hand).',
         '// Pads: Let There Be Flight helipads.tsv (MIT, Copyright 2021-2023 Jack Humbert), open-sky pads only.',
         'module CyberslopAVFlight', '',
         'public abstract class AVFData {', '',
         '  public static func Models() -> array<ref<AVFModel>> {',
         '    let a: array<ref<AVFModel>>;',
         '    let m: ref<AVFModel>;']
    for i, m in enumerate(MODELS):
        rec = m.get('record', 'Vehicle.cyav_%s' % m['key'])
        lat_turn = G * math.tan(math.radians(30.0))
        # torque gain per kg: yaw response 0.3 s on a box inertia (DLL-NOTES: response = inertia / gain)
        gain = (m['L'] ** 2 + m['W'] ** 2) / 12.0 / 0.3
        L += ['    m = new AVFModel();',
              '    m.index = %d; m.key = "%s"; m.name = "%s"; m.kind = %d;' % (i, m['key'], m['name'], m['kind']),
              '    m.record = t"%s"; m.appearance = n"%s";' % (rec, m.get('app', '')),
              '    m.vmax = %s; m.accel = %s; m.brake = %s; m.climb = %s; m.descent = %s;' % tuple(
                  f(m[x]) for x in ('vmax', 'accel', 'brake', 'climb', 'descent')),
              '    m.yawRate = %s; m.turnLat = %s; m.pitchFactor = %s; m.gainPerKg = %s;' % (
                  f(math.radians(m['yaw'])), f(lat_turn), f(m['pitch']), f(round(gain, 1))),
              '    m.dispatch = %s; m.rentPerHour = %s; m.burnHover = %s; m.burnCruise = %s; m.burnMax = %s; m.hullValue = %s;' % (
                  f(m['dispatch']), f(m['rent']), f(m['burn'][0]), f(m['burn'][1]), f(m['burn'][2]), f(m['hull'])),
              '    m.length = %s; m.width = %s; m.height = %s;' % (f(m['L']), f(m['W']), f(m['H'])),
              '    m.entry = new Vector3(%s, %s, %s); m.entryRadius = %s; m.exitPoint = new Vector3(%s, %s, %s);' % (
                  f(m['entry'][0]), f(m['entry'][1]), f(m['entry'][2]), f(m['entry_r']),
                  f(m['exit'][0]), f(m['exit'][1]), f(m['exit'][2])),
              '    ArrayPush(a, m);']
    L += ['    return a;', '  }', '',
          '  public static func Pads() -> array<Vector4> {',
          '    let p: array<Vector4>;']
    for x, y, z in pads:
        L.append('    ArrayPush(p, new Vector4(%.1f, %.1f, %.1f, 1.0));' % (x, y, z))
    L += ['    return p;', '  }', '}', '']
    return '\n'.join(L)


def read_pads(path):
    pads = []
    for line in open(path, encoding='utf-8'):
        if line.startswith('#') or not line.strip():
            continue
        cols = line.rstrip('\n').split('\t')
        x, y, z = float(cols[1]), float(cols[2]), float(cols[3])
        clearance = cols[6]
        if clearance != 'inf' and float(clearance) < 60.0:
            continue
        pads.append((x, y, z))
    return pads


def main():
    pads = read_pads(sys.argv[1])
    root = sys.argv[2]
    ypath = os.path.join(root, 'r6', 'tweaks', 'CyberslopAVFlight', 'avflight.yaml')
    rpath = os.path.join(root, 'r6', 'scripts', 'CyberslopAVFlight', 'Data.reds')
    os.makedirs(os.path.dirname(ypath), exist_ok=True)
    os.makedirs(os.path.dirname(rpath), exist_ok=True)
    open(ypath, 'w', encoding='utf-8', newline='\n').write(yaml_text())
    open(rpath, 'w', encoding='utf-8', newline='\n').write(reds_text(pads))
    print('models', len(MODELS), 'pads', len(pads))
    print(ypath)
    print(rpath)


main()
