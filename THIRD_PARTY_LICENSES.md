# Third-party work this mod builds on

This repository contains none of the files below. It contains my own code, which calls into or was generated from them. Both projects are published by their authors under the MIT licence; their notices are reproduced here because parts of this repository are derived from their data.

## Drive an Aerial Vehicle 3.5.0

Copyright (C) 2024 tidusmd. MIT License. <https://github.com/tidusmd0806/CP2077-DriveAerialVehicle>

Needed at runtime, from your own download of that mod:
- `DriveAerialVehicle.dll`: the native flight physics this mod calls.
- its `.archive`: the flyable aircraft entities and their appearances.

Derived from it, in this repository:
- `FlyAVSystem.reds`: declarations of the ten functions of that DLL which this mod calls.
- `avflight.yaml` and the model table in `tools/gen.py`: the vehicle records point at that mod's entities; entry and exit points and camera ratios follow its `default_model.json`.
- `Parts.reds`: positions of the engine components of those entities.

Derived from it, NOT in this repository:
- `HeightMap.reds`: building heights generated from that mod's obstacle map. You generate it from your own copy with `tools/dav_heightmap.py`.

## Let There Be Flight 0.4.0

Copyright 2021-2023 Jack Humbert. MIT License. <https://github.com/jackhumbert/let_there_be_flight>

Derived from it, in this repository:
- the 111 landing-pad positions in `Data.reds` (from its `helipads.tsv`), used as charter depots.
- the idea of flight controls that command a speed and come to rest when released.

## MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
