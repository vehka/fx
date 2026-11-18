# fx

A send and insert effects rack for norns, usable with any script. SuperCollider
effects are placed in a serial insert chain on the engine output or in one of
two send chains.

This is v2, written for norns 3.x. It replaces v1 in `dust/code/fx`; do not
keep both installed. v1 plugins and v1-aware engines keep working. Routing
softcut through the rack uses the audio routing functions of 3.x and is left
out where norns does not have them.
Design notes: [docs/DESIGN.md](docs/DESIGN.md).

## Signal flow

Everything the rack can route. `[brackets]` are params; the main bus is
SuperCollider's output, which is where any script's engine plays.

```
 SOURCES                         MAIN BUS
                                    ║
 engine of any script ──┬──────────►║
                        │           ║
   softcut's input ◄────┘           ║
     dry, [LEVELS: input engine],   ║
     only with softcut through rack ║
                                    ║
 audio in ── [input level, mode] ──►║
 softcut ─ [softcut: through rack] ►║
                                    ║
                                    ╟──► SEND A / B   tap: pre insert
                                    ║      [send level]
                                    ║◄── SEND A / B   return to: pre insert
                                    ║      [return level]
                               ┌────╨────┐
                               │  ins 1  │
                               │  ins 2  │  in series, each with
                               │  ins 3  │  [dry/wet] and [bypass]
                               │  ins 4  │
                               └────╥────┘
                                    ╟──► SEND A / B   tap: post insert
                                    ║      [send level]
                                    ║◄── SEND A / B   return to: post insert
                                    ║      [return level]
                                    ▼
                 norns mixer: reverb, compressor, tape, output


 SEND A  (send b is the same, with a and b exchanged)

 tap from the main bus ─────┐
 send b ── [b to send a] ───┼─► limiter ─► a 1 ─► a 2 ─┐
 voices of an fx-aware      │                100 % wet │
 engine ────────────────────┘                          │
                                                       │
         main bus ◄── [return level] ◄─────────────────┤
         send b   ◄── [a to send b]  ◄─────────────────┘


 SIDECHAIN AND CONTROL  (for the effects that read them)

 [sidechain: off | rack input | audio in | send a | send b | softcut]
     ─► [sc gain] ─► key signal + its envelope
 [mod 1] .. [mod 4]   four values any effect may follow; map them
                      to MIDI or set them from a script
 tempo                the norns clock, for synced effects
```

What follows from it:

- **Inserts** process everything on the main bus: the engine, and the audio
  input and softcut once they are brought in. Without the rack those two are
  mixed in after SuperCollider and cannot be processed.
- **A send is tapped and returned on either side of the inserts**, each side
  chosen separately. Pre tap with post return is the usual parallel effect;
  pre tap with pre return sends the effect through the inserts too.
- **Post tap with pre return is a feedback loop**: out of the inserts, through
  the send, back into the inserts. So are `a to send b` and `b to send a`
  together. `a to send b` alone is a delay feeding a reverb.
- **The sidechain is heard only by effects that use it.** With `audio in` as
  the source and the input level at 0, a kick on the input can duck the
  engine without being in the rack itself.
- An effect can be loaded more than once (see copies, below).

In SuperCollider the rack is one group placed directly after norns' output
group. Some engines (Sines, for one) add an output stage at the end of the
node tree when they load, after the rack, so once a script's engine is up the
rack is moved to the end again. A node an engine adds there later, while the
script runs, is not processed. The tree, for an engine that stays in its
group:

```
1 group
   group  Crone.context.ig     adc passthrough to Crone.context.in_b
   group  Crone.context.xg     the script's engine, writing to the main bus
                               [0, 1]
   group  Crone.context.og
   group  FxRack.group
      fxTap                    the engine alone -> server outputs 3, 4,
                               for softcut to record
      fxInput                  audio inputs (in_b) -> main bus
      fxInput                  softcut (server inputs 3, 4) -> main bus
      fxKey                    the chosen sidechain source -> key bus
                               and envelope
      group  preTaps           the tap of each send with tap = pre insert
      group  preSends          the sends that return pre insert
      group  insert            ins 1..4, each replacing the main bus in place
      group  postTaps          the tap of each send with tap = post insert
      group  postSends         the sends that return post insert
         group  send a
            fxInlet            taps and send b -> the send's own bus,
                               behind a limiter
            group  chain       a 1, a 2, in place on that bus
            fxReturn           -> main bus
            fxReturn           -> send b
```

A loop works because a send reads its input one block late when the writer
runs after it. An empty send is muted, and removed effects ring out before
their node is freed.

## Using it

Enable the mod and its effect plugins under SYSTEM > MODS and restart. Every
script then has these at the end of its params menu:

- **fx rack**: what is in each insert and send slot. Inserts run in slot order.
  Turn E3 to scroll through the effects and press K3 to load the one shown; a
  `?` marks a choice that is not loaded yet.
- **fx input**: the level of the audio inputs into the rack, stereo or summed
  to mono. The input then passes through the inserts and send taps like the
  engine does. Turn the norns monitor level down to hear only the processed
  signal. **softcut** (norns 3.x) can be set to "through rack": its output
  then goes into the rack instead of straight to the norns mixer. Softcut
  still records the engine at the level the script or LEVELS > "input engine"
  sets, but it records the engine as it is before the rack, so softcut never
  records itself and effects are heard once, on playback.

  Through the rack, softcut reaches the norns mixer inside the engine signal,
  which changes what some of the mixer's own controls do:

  - LEVELS > "softcut" still sets softcut's level: the mod applies it where
    softcut enters the rack. The "engine" level now scales softcut too, and
    the LEVELS softcut meter stays at zero; softcut shows on the engine meter.
  - REVERB > "input softcut" does nothing. Softcut reaches the norns reverb
    through "input engine", at the engine's send level. For reverb on softcut
    alone, put a reverb on an fx send instead.
  - Tape's multitrack source "softcut" records nothing; the main tape, which
    records the output, still has softcut.
- **fx sends**: per send, the level tapped from the engine output, where it is
  tapped (pre/post insert), the return level, where it returns, and the level
  from its effects into the other send (delay into reverb).

  Two settings make a feedback loop: a post-insert tap with a pre-insert
  return, and both "a to send b" and "b to send a" above zero. Each send input
  has a limiter, so a loop stays below full scale, but it can sustain or howl:
  bring the levels up slowly.
- **fx sidechain + mod**: where the sidechain signal comes from and its gain,
  and the four mod values. They do nothing by themselves: effects that have a
  sidechain or follow a mod value read them.
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

The last row of an opened effect is **copies**: how many of that effect the
rack offers, up to four. A second copy appears among the effects as
"<effect> 2" and can be loaded at once; its own params (and so its place in
PSETs) come with the next script start. Copies share the effect's presets.
Older (v1) plugins have one copy.

Below the sends are rows for the **sidechain** source and **mod 1**; open
them for the gain and the other mod values.

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

That file can be the whole plugin. Give the controls specs and the rack makes
the params itself; the file only has to be somewhere under `dust/code`:

```supercollider
FxUnit.register(\mydelay, { |in, time = 0.3, fb = 0.4| ... }, (
    tail: 4,
    title: "My Delay",
    specs: (time: [0.01, 2, \exp, 0, 0.3, "s"], fb: [0, 0.95]),
));
```

A control without a spec gets one if SuperCollider has a spec of that name
(`\freq`, `\rq`, ...) and is otherwise left at its default. The default
value is the one in the function. `instances: 2` offers two copies from the
start.

Inside the function these read the shared signals:

| | |
|---|---|
| `FxRack.key` | the sidechain signal, stereo |
| `FxRack.env` | its envelope, 0 to 1 for a full-scale signal |
| `FxRack.mod(n)` | mod value n (1 to 4), 0 to 1 |
| `FxRack.tempo`, `FxRack.beat` | the norns clock in bpm, and seconds per beat |

```supercollider
// a ducker, and a delay of a dotted eighth
FxUnit.register(\duck, { |in, depth = 1| in * (1 - (FxRack.env * depth).clip(0, 1)) },
    (specs: (depth: [0, 1])));
FxUnit.register(\sync, { |in| DelayC.ar(in, 4, (FxRack.beat * 0.75).min(4)) }, (tail: 4));
```

For option and switch params, formatters or factory presets, describe the
params in Lua instead, in `lib/mod.lua`:

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
`instances = 2` offers two copies. A Lua description replaces the specs.

Factory presets go in `presets/<name>/<preset>.fxp` in the plugin's directory.
Save them on the device from **fx presets** and copy them from
`dust/data/fx/presets/<name>/`.

## Scripts

A script can ask for a rack in its `init`, without depending on the mod:

```lua
local ok, fx = pcall(require, 'fx/lib/fx')
if ok then
  fx.request{
    insert = { "mydelay", { "drive", mix = 0.4, gain = 2 } },
    a = { "reverb" },
    params = { fx_send_a_level = 0.3 },
  }
end
```

`insert`, `a` and `b` list effects in slot order: a name, or a table of the
name with its dry/wet (`mix`), `bypass` and own params. An effect named twice
uses a second copy if there is one. `params` sets any fx param by id, and a
string instead of the table names a saved rack. Effects that are not
installed are skipped.

It is a request. The fx values in the PSET the script loads come first, and
with **keep rack** on so does a rack that is already running; add
`replace = true` to take the rack over anyway. Called later than `init`, it
is applied at once under the same rule.

## Engines

Nothing is needed for inserts or the send levels in **fx sends**. An engine
that wants per-voice sends can write to `FxSetup.sendA` / `FxSetup.sendB`
(also `~sendA` / `~sendB`), as in v1.

## Tests

```
lua5.3 test/run.lua [path/to/norns/lua]   # Lua core against the real paramset
test/run_sc.sh                            # click test; needs sclang and JACK
```
