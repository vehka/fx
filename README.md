# fx

A send and insert effects rack for norns, usable with any script. SuperCollider
effects are placed in a serial insert chain on the engine output or in one of
two send chains.

This is v2 and needs norns 3.x. It replaces v1 in `dust/code/fx`; do not keep
both installed. v1 plugins and v1-aware engines keep working.
Design notes: [docs/DESIGN.md](docs/DESIGN.md).

## Using it

Enable the mod and its effect plugins under SYSTEM > MODS and restart. Every
script then has these at the end of its params menu:

- **fx rack**: what is in each insert and send slot. Inserts run in slot order.
- **fx sends**: per send, the level tapped from the engine output, where it is
  tapped (pre/post insert), the return level and where it returns.
- **fx presets**: save and load presets per effect, and scenes of the whole
  rack. "save as default" makes a preset the effect's starting values; "save
  as default rack" makes a scene the rack for scripts that have no fx settings
  of their own. Files live in `dust/data/fx/`.
- one group per effect, with `slot` (none / send a / send b / insert), dry/wet
  and the effect's own params.

Effects fade in and out, and tails ring out when an effect is removed or
bypassed. The mod's settings page (SYSTEM > MODS > fx) sets the fade time and
whether the rack keeps running across script changes.

## Writing an effect

SuperCollider, in `lib/` of your mod:

```supercollider
FxMyDelay {
    *initClass {
        Class.initClassTree(FxUnit);
        FxUnit.register(\mydelay, { |in, time = 0.3, fb = 0.4|
            var local = LocalIn.ar(2) + in;
            LocalOut.ar(DelayC.ar(local, 2, time) * fb);
            local  // the wet signal
        }, (tail: 4));
    }
}
```

The function receives the stereo input and returns the wet signal. Its other
arguments become lagged controls. `tail` is how long the output keeps ringing
after the effect is removed.

Lua, in `lib/mod.lua`:

```lua
local fx = require 'fx/lib/fx'

fx.register{
  name = "mydelay",
  title = "My Delay",
  params = function()
    return {
      { id = "time", spec = controlspec.new(0.01, 2, 'exp', 0, 0.3, 's') },
      { id = "fb", name = "feedback", spec = controlspec.new(0, 0.95, 'lin', 0, 0.4) },
    }
  end,
}
```

Param types: `control` (default), `taper`, `number`, `option`, `binary`.

Factory presets go in `presets/<name>/<preset>.fxp` in the plugin's directory.
Save them on the device from **fx presets** and copy them from
`dust/data/fx/presets/<name>/`.

## Engines

Nothing is needed for inserts or the send levels in **fx sends**. An engine
that wants per-voice sends can write to `FxSetup.sendA` / `FxSetup.sendB`
(also `~sendA` / `~sendB`), as in v1.

## Tests

```
lua5.3 test/run.lua [path/to/norns/lua]   # Lua core against the real paramset
test/run_sc.sh                            # click test; needs sclang and JACK
```
