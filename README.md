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
  Turn E3 to scroll through the effects and press K3 to load the one shown; a
  `?` marks a choice that is not loaded yet.
- **fx input**: the level of the audio inputs into the rack, stereo or summed
  to mono. The input then passes through the inserts and send taps like the
  engine does. Turn the norns monitor level down to hear only the processed
  signal.
- **fx sends**: per send, the level tapped from the engine output, where it is
  tapped (pre/post insert), the return level, where it returns, and the level
  from its effects into the other send (delay into reverb).

  Two settings make a feedback loop: a post-insert tap with a pre-insert
  return, and both "a to send b" and "b to send a" above zero. Each send input
  has a limiter, so a loop stays below full scale, but it can sustain or howl:
  bring the levels up slowly.
- **fx presets**: save and load presets per effect, and scenes of the whole
  rack. "save as default" makes a preset the effect's starting values; "save
  as default rack" makes a scene the rack for scripts that have no fx settings
  of their own. Files live in `dust/data/fx/`.
- one group per effect, with `slot` (none / send a / send b / insert; E3 then
  K3, as in the rack), dry/wet and the effect's own params.

Effects fade in and out, and tails ring out when an effect is removed or
bypassed. Every effect has a bypass: in its own group, or for older (v1)
plugins in **fx rack** as "<effect> bypass".

### The rack page

SYSTEM > MODS > fx shows the whole rack in signal order: the input, the four
inserts, and each send with its two slots. Inserts show their dry/wet (or
`byp` when bypassed), the input and the sends their level. On the right are
meters for the rack input (i), the two sends (a, b) and the rack output (o);
at the top the average / peak CPU of SuperCollider.

| | |
|---|---|
| E2 | select a row |
| E3 | dry/wet of an insert, or the level of the input or a send |
| K3 | bypass on/off |
| K1 + E2 | move the effect up or down in its chain |
| K1 + E3 | scroll through the effects, release K1 to load the one shown (`-` empties the slot) |
| K1 + K3 | open the row: an effect's params, or the routing of a send or the input |
| K2 | back |

In an opened row E2 selects a param, E3 changes it, K3 toggles a switch and
K2 goes back to the rack. Hold K1 for a moment before pressing K3: a quick
tap of K1 leaves the menu, as everywhere on norns.

Below the rack:

- **rack** and **save rack...**: E3 picks a saved rack and K3 loads it; save
  asks for a name. A saved rack holds everything: which effects are where,
  the sends and input, and every effect's own settings. These are the same
  racks as the scenes in **fx presets**.
- **keep rack**: the rack keeps running across script changes, and a rack you
  set up here is kept when a script starts. When off, each script starts from
  its own PSET or the default rack.
- **fade**: the fade time for loading and bypass.

The page and the params menu show the same things; change them in either.
With no script loaded you can still place, move and bypass effects and set
dry/wet, but effect params, sends, input and saved racks need a running
script.

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
