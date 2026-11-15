# fx v2 design

Target: norns 3.x. Softcut as a source uses `audio.port_connect` and the
`audio_post_restore_default_routing` hook, which older versions (250926 and
the like) do not have: there it is skipped, see "Softcut" below.
v2 replaces v1 in the same `dust/code/fx` directory: both define
`FxBase`/`FxSetup`, and two copies would stop sclang compiling.

## Goals

1. Seamless switching: no clicks when loading, swapping, reordering or
   bypassing effects, and tails that ring out.
2. Serial insert chain with user-controlled order.
3. Configurable routing: sends with pre/post tap and pre/post return.
4. Per-fx presets, rack scenes and a default rack.
5. Works with unmodified scripts and with v1 plugins.
6. A base for a modular audio station: softcut and ADC as sources, sidechain
   and modulation buses, tempo sync.

## Problems in v1

| Problem | Cause |
|---|---|
| Clicks on load/switch | bare `syn.free` / `Synth.new`, replacer appears at full dry/wet, routing changed by several separate messages |
| Tails cut on script change | whole fx group freed at `script_post_cleanup` |
| Fx params not restored from the script PSET at load | params added by wrapping `init`, after the script's own `params:default()` |
| Inserts share one dry/wet, capped at four | single replacer, hard-coded `chain1..3` buses |
| Sends are not really pre/post | both returns summed after the insert |
| Only the SC engine is processed | softcut, monitor and tape are mixed in crone |

## Signal model

```
sources: engine (bus 0) | audio inputs | softcut | cooperative per-voice sends
main:    input -> PRE taps -> pre sends -> INSERT chain -> POST taps -> post sends -> out
send X:  tap level + other sends -> inlet -> chain -> return level -> main bus, pre or post insert
                                                   -> level into each other send
```

Node tree, inside one group placed directly after `context.og`:

```
fx group
  input       audio inputs (context.in_b) into the main bus, level 0 by default
  softcut     the server's inputs 3 and 4 into the main bus
              (ahead of both: the engine alone to outputs 3 and 4, for softcut)
  key         the sidechain source onto the key bus, its envelope onto a control bus
  preTaps     tap synths of sends with tap = pre
  preSends    send groups whose return is pre-insert
  insert      main chain, in place on bus 0
  postTaps    tap synths of sends with tap = post
  postSends   send groups whose return is post-insert
```

The rack group is made directly after `context.og`, but that is not always
the end: some engines add an output stage at the tail of the root group
when they load (Sines sums its voices on a private bus and writes them to
the main bus from there), and the rack would see none of it. So at
`script_post_init`, when the engine is up, `/fx/tail` moves the rack group to
the tail of its parent. A node added to the tail later, while the script
runs, is still missed.

A send group holds the send's inlet, its chain group, its return synth and
one synth per other send (send-to-send). A pre-insert return passes through
the inserts.

### Send inputs and feedback

A tap and the other sends do not write to the send's chain bus but to a
second bus, `inBus`. The inlet copies it to the chain bus with `InFeedback`.
If the writer ran earlier in the same block the copy is immediate; if it runs
later in the node order, the inlet reads the previous block. So every routing
is valid, and those that loop are delayed by one block (1.3 ms at 64 frames):

- tap = post with return = pre: out of the inserts, through the send, back
  into the inserts;
- a -> b together with b -> a.

The inlet is the loop protection: NaN guard, `LeakDC`, and a limiter without
lookahead (envelope follower and a clip at full scale), so a send is not
delayed and signals below full scale pass unchanged. A loop with gain above 1
settles at the limiter instead of growing.

Cooperating engines write to the chain bus directly, as in v1; the inlet adds
to it.

The send-to-send synths are muted with the return while the chain is empty.

### In-place chains

A chain is one stereo bus and one group. Each occupied slot is a node that
reads the bus, processes, and writes back with `ReplaceOut`. Order is node
order; an empty slot is no node. There are no intermediate buses and no slot
limit on the SC side. The insert chain runs on bus 0, so any script works. Each
send has its own chain on a private bus, so a send can be delay -> reverb.

The return of a send whose chain is empty is muted, otherwise the dry send
signal would be added back to the output.

### Wrapper

Plugins supply DSP only: `{ |in, drive, tone| ... wet }`. The framework builds
the SynthDef around it:

```
dry  = In(bus)
on   = asr(fade) on gate                  -- input gate and dry replacement
life = 0 -> 1, hold, tail seconds, -> 0   -- output; frees the node
act  = lagged (1 - bypass)
wet  = fx(dry * on * act)                 -- NaN/inf guarded
out  = dry * (1 - mix * on * act) + wet * mix * life
```

- Release or bypass closes the input and restores the dry signal at once; the
  wet output keeps ringing for `tail` seconds (spillover).
- Wrapper controls are prefixed `fx_` so they cannot collide with plugin
  controls. Plugin controls are lagged by default.
- A bypassed node is paused once its tail has decayed and resumed on
  un-bypass.
- In a send chain the effective mix is 1.

### Switching

Every graph change is one server bundle. Replacing the effect in a slot starts
the new node directly after the old one and releases the old one in the same
bundle. Moving a unit (reorder, or to another chain) is release + start at the
new position, so it crossfades and the effect state restarts.

### v1 plugins

`FxBase` subclasses and `FxSetup.register` still work. A v1 SynthDef with
`inBus`/`outBus` runs inside a per-instance group: pre synth (chain bus ->
private in bus), the plugin synth, post synth (private wet bus -> chain bus,
same mix/tail maths, frees the group). `~sendA`, `~sendB`, `FxSetup.sendA` and
`FxSetup.sendB` stay for cooperating engines. `FxSetup.insertInput` returns
nil so older engine-driven routing that checks for this separate insert feed
disables its extra copy: inserts now process the engine's main output in place.

## Lua model

The rack model in Lua is the source of truth; SC executes `/fx/slot`,
`/fx/set`, `/fx/send`, `/fx/clear`. Each unit's dry/wet and bypass are part of
the model too (`unit.mix`, `unit.bypass`), so they exist when no script, and
so no param, does.

- **Units** are registered once at mod load, by the v1 API
  (`fx:new{subpath=...}` + `add_params`) or the declarative v2 API
  (`fx.register{name=..., params={...}}`), or read from the units file that
  sclang writes (see "Single-file plugins").
- **Params are plugin-centric with stable IDs**, so PSETs and PMAPs keep
  working. v1 IDs are unchanged.
- **Choosing where an effect goes is scroll-then-confirm.** The stock params
  menu applies an option on every encoder step, which would load every effect
  scrolled past. Rack rows and each unit's slot row are therefore `Chooser`
  params (`lib/chooser.lua`): they present as triggers, so E3 only moves the
  candidate (`delta`) and K3 applies it (`set`). A trigger row shows no value,
  so the choice is part of the row name, with ` ?` while unapplied. This uses
  only the param-object contract; core is not patched.
- **Rack rows** (`fx_ins_1..4`, `fx_a_1..2`, `fx_b_1..2`): applying a row
  unloads its occupant and moves the chosen unit there if it was elsewhere.
  Not saved; the option list depends on what is installed.
- **Per-unit slot row** (`<slot id>_pick`: none / send a / send b / insert):
  applying puts the unit in the first free slot of that chain.
- **Saved state per unit**, hidden in the fx rack group: the slot option under
  its v1 id, and the position `fx_pos_<unit>`. Slot + position restore a rack
  independently of which other plugins are installed. Setting these (PSET
  load) moves an occupant to the first free slot of the chain, or out of the
  rack if the chain is full, so the result does not depend on line order.
- Unit groups come first in the menu, then fx rack, fx sends and fx presets:
  the rack group needs every unit's slot id.
- **Bypass** is a param of every unit: `fx_<unit>_bypass` in a v2 unit's own
  group, `fx_bypass_<unit>` in the fx rack group for a v1 plugin, whose group
  size is fixed.
- **Sends**: `level` (master tap, so any script can use the send), `tap`
  (pre/post), `return` level, `dest` (pre/post insert), and `to_<other>`
  (level into each other send).
- **Input**: `fx_input_level` and `fx_input_mode` (stereo / mono). Crone still
  mixes the monitor signal after SuperCollider, so the user turns the monitor
  down to hear only the processed input; the mod does not touch it.

### Lifecycle

| Hook | Work |
|---|---|
| `system_post_startup`, `script_pre_init` | `/fx/ensure` (idempotent); record which PSET the script reads during `init` |
| `script_post_init` | move the rack behind the engine (`/fx/tail`), add params, restore values, bang fx params, rebuild the params menu |
| `script_post_cleanup` | if persist is off, `/fx/clear` |

Restoring values at `script_post_init`:

- **persist on** (default, "station mode"): the rack keeps running across
  script changes and the new script's fx params take the live values.
- **persist off**: the rack is cleared at cleanup, and fx values are re-read
  from the PSET the script loaded in `init`.

PSETs loaded later from the params menu read fx params natively.

With persist on, the model wins at script start: slot, position, dry/wet and
bypass params are set from it before they are banged. A rack built on the
rack page before any script ran is therefore kept, and counts as live state
even though no param value was ever recorded. With persist off the script's
PSET or the default scene decides, as before.

## Rack page

The mod's menu page (SYSTEM > MODS > fx, `lib/page.lua`) is a second view of
the state the params menu shows, laid out as the rack instead of as groups.
The params stay the store: PSETs, MIDI mapping and saved racks are made of
them. The page reads the model and changes it only through the core
(`set_row`, `swap`, `set_mix`, `set_bypass`) and the params, so the two views
agree.

Rows, in signal order: `input`, the four inserts, then `send a` with its two
slots and `send b` with its two, then `sidechain`, `mod 1`, `rack`,
`save rack...` and the two settings.

| Control | Action |
|---|---|
| E2 | select a row |
| E3 | the row's value: dry/wet of an insert, input or send level, a setting, which rack |
| K3 | bypass an effect; load the rack shown; save a rack |
| K1 + E2 | move the effect within its chain (swaps with the neighbour) |
| K1 + E3 | scroll through the effects; releasing K1 loads the one shown |
| K1 + K3 | open the row |
| K2 | back |

An opened row is a list of params in place of the rack list, with the meters
still shown: for an effect its bypass and everything in `unit.param_ids`
(dry/wet and its own params), for a send its tap, return, destination and
send-to-send level, for the input its mode. Hidden params are left out, so a
send effect has no dry/wet. An opened effect ends with a `copies` row, which
is not a param but the unit's number of instances. E2 selects, E3 changes, K3 toggles a switch, K2
or K1 + K3 goes back. Params a v1 plugin adds without the helper API are not
in `param_ids` and so not listed.

What works without a script: the rack, order, dry/wet and bypass, which are
in the model. Everything else on the page is a param and exists only while a
script runs; those rows are dim and answer "needs a running script". Making
the fx params exist with no script loaded would remove the limit but is not
done: core clears the paramset after the last hook of a script change, and
v1 plugins add their params from script hooks.

The `rack` rows use the scenes of `lib/presets.lua`: E3 picks one (marked
`?` until loaded), K3 loads it, `save rack...` asks for a name with the last
rack's name filled in. A scene holds every fx param, so a saved rack is
complete: slots, order, sends, input and each effect's values.

Loading an effect is scroll-then-confirm here as well: nothing is loaded
while K1 is held. The menu delivers a long K1 press to a page only after a
delay, so the page also reads `_menu.alt`, the menu's own "K1 is down" state.
That is an internal; without it the page still works but the first steps
after pressing K1 would be taken as unmodified. A K1 press shorter than the
menu's hold time (0.25 s) leaves the menu, as on every menu page, so K1 has
to be held a moment before K3.

### Meters and CPU

Crone's polls belong to the script and are reset when it changes, so the
page has its own path. While the page is open (`/fx/meter 1`, `0` when it
closes) two synths run in the fx group: one after the input synth writes the
level at the rack's input to a control bus, one at the tail reads that bus,
each send's chain bus and the main bus, and sends all four with `SendReply`
at 15 Hz. sclang adds `avgCPU` and `peakCPU` and forwards the lot to matron's
OSC port (10111) as `/fx/meter in a b out cpuAvg cpuPeak`. Levels are peak
followers over both channels; the page draws them on a 48 dB scale.

On the Lua side `osc.event` is one slot owned by the script. The page puts
its handler there while it is open, passes everything but `/fx/meter` to the
handler it found, and gives the slot back on closing. Each meter message
redraws the page, so there is no timer: the redraw rate is the meter rate,
and both stop together.

## Presets

Files are `"id": value` lines, like a PSET.

| What | Where |
|---|---|
| user presets of a unit | `dust/data/fx/presets/<unit>/<name>.fxp` |
| factory presets | `<plugin>/presets/<unit>/<name>.fxp`, read-only; a user preset of the same name wins |
| rack scenes | `dust/data/fx/scenes/<name>.fxs` |

- A unit preset holds the unit's own params and its dry/wet, not its slot.
- A scene holds every fx param: slots, positions, sends and all unit values.
  Loading a scene removes units it does not mention.
- The **fx presets** params group has one effect selector with preset, load,
  save, save as..., save as default and delete, and the same for scenes. One
  shared group is used because v1 plugin groups have a fixed size.
- The preset and scene named `default` are applied when a script starts.
  Precedence: the live rack (persist on) > fx values in the PSET the script
  read > the rack the script requested > default scene > each unit's default
  preset > built-in defaults.
  Defaults are not re-applied when a unit is placed, so moving a unit never
  discards edits.

## Softcut

Softcut is a JACK client of its own; crone mixes it in after SuperCollider.
To get it into the rack its two outputs are disconnected from `crone:input_3/4`
and connected to `SuperCollider:in_3/4`, where a second `fxInput` synth adds
them to the main bus. The param is `fx_softcut` (to output / through rack) in
the fx input group.

- **The server needs four inputs.** `FxRack.initClass` raises
  `numInputBusChannels` to 4. Crone boots the server from a `StartUp`
  function, and those run after every `initClass`, so the option is set in
  time. The extra inputs are unconnected until the param asks for them.
- **Core puts the routes back.** `Script.clear` calls `audio.routing_default`
  whenever a route was changed through `audio.port_connect`, and then runs the
  `audio_post_restore_default_routing` hook, where the mod patches softcut in
  again. With persist off the routes are returned to default at cleanup
  instead.
- **Older norns.** Everything on the Lua side is behind
  `Core.softcut_available()`, which is false when `audio.port_connect` is
  nil: no `fx_softcut` param, no softcut choice for the sidechain, no hook,
  and `set_softcut` returns at once. The SC side is the same on every
  version; its softcut synth just reads two silent inputs. If the
  `SuperCollider:in_3` port is missing the routes are left alone.

### What softcut records

Crone feeds SuperCollider's output to softcut's input at the
engine-to-softcut level (`audio.level_eng_cut`; the LEVELS param
`cut_input_eng`, 0 dB by default, and many scripts set it to 1). With softcut
in the rack that output contains softcut, so softcut would record itself: in
awake the delay's feedback would exceed 1. Once softcut is on the main bus
it cannot be taken out again, and crone has no softcut-free input other than
the softcut return, so the path is replaced:

- While softcut is in the rack, crone's engine-to-softcut level is held at 0.
- An `fxTap` at the head of the rack group, before the audio inputs and
  softcut join, copies the main bus (the engine alone) to the server's
  outputs 3 and 4 at the level that was asked of crone. Those are connected
  to `softcut:input_1/2`, next to crone's feed, which still carries the adc
  and tape.

So softcut records the engine at the level the script or the user wants,
dry: effects are applied once, when softcut plays through the rack.

Core has no getter for the level. `Core.wrap_eng_cut` replaces
`audio.level_eng_cut` with a function that remembers the value and passes it
to crone or, while softcut is in the rack, to the feed (`/fx/cutfeed`). Every
caller goes through that function: scripts, and the LEVELS param's action.
This is a run-time override of a core function, beyond the param and mod
contracts; the user agreed to it for this purpose (2026-11-15). It is only
installed where softcut routing is available. Until something sets the
level, the saved `norns.state.mix.cut_input_eng` is taken. Switching back to
"to output" hands the remembered level to crone.

"Through rack" is refused unless the wrap is in place and both
`SuperCollider:in_3` and `SuperCollider:out_3` exist: without the feed the
loop would be open. `FxRack.initClass` raises `numOutputBusChannels` to 4 as
well, which moves the hardware input buses from 2, 3 to 4, 5.

## Sidechain, modulation and tempo

Two buses exist for effects to read; nothing in the rack uses them itself.

- **Key bus** (audio, stereo): `fxKey` copies one source to it, chosen by
  `fx_key_source`: off, the rack's input (the main bus after the sources),
  the audio inputs alone, the output of a send's chain (through `InFeedback`,
  so one block late), or softcut. `fx_key_gain` scales it.
- **Control bus**, six channels: the key signal's envelope, the tempo in bpm,
  and four modulation values (`fx_mod_1..4`, plain 0..1 params, so they can be
  MIDI-mapped, saved in racks and set by a script).

A unit reads them with `FxRack.key`, `.env`, `.mod(n)`, `.tempo` and `.beat`
inside its function. These are `In` UGens on bus numbers that arrive as the
controls `fx_key` and `fx_ctl` of every native unit's synth, so a def does
not depend on when the buses were allocated. v1 plugins do not get them.

Tempo: `/fx/tempo` is sent at every `/fx/ensure` and by a clock coroutine
that compares `clock.get_tempo()` twice a second, which covers every clock
source. `clock.tempo_change_handler` is not used: it is one slot that belongs
to the script. Core cancels all clocks when a script ends, after the cleanup
hook, so the coroutine is started again at each script start and the tempo
is not followed while no script is loaded.

## Single-file plugins

sclang compiles every `.sc` file under `dust`, mod or not, so an effect can be
one file with no Lua. `FxUnit.register` takes `specs` (control name ->
`ControlSpec` or anything `asSpec` accepts), `title` and `instances` in its
options; the specs are also the SynthDef's metadata. A control without a
given spec uses the global spec of its name if there is one, else it gets no
param. The default is the function argument's.

The Lua side cannot ask SC for this: `osc.event` belongs to the script. So
sclang writes `dust/data/fx/units.lua` when it starts (and when a unit is
registered later): a Lua table of every native unit, its title, instances
and spec'd params. `Core.load_units_file` reads it at start-up, before every
script and when the rack page opens, and registers the units no mod has
registered (`unit.auto`). A Lua registration of the same name wins, so a
plugin with a `mod.lua` is unchanged. The file is loaded with an empty
environment.

## Multiple instances

A second instance is a unit of its own, named `<name>_2` (up to `_4`), with
its own params (`fx_<name>_2_<id>`), slot, position, dry/wet and bypass, so
PSETs, racks and MIDI maps need nothing new. `unit.base` names the original.

- How many: `Core.settings.instances[name]` (the "copies" row of an opened
  effect on the rack page) > the plugin's `instances` > 1. v1 plugins always
  have one: their SC object holds a single synth.
- Lua makes the copies in `Core.apply_instances`. SC makes its copy when a
  name is first used: `FxUnit.find(\name_2)` clones `\name`, sharing the
  SynthDef. A real unit of that name wins on both sides.
- A new copy is in the model at once and can be placed from the rack page;
  its params are added at the next script start, like everything else.
- Copies share the base's presets: the directory and the ids in the file are
  the base's, translated by position in `param_ids`.

## Script API

`fx.request(spec)` (`lib/fx.lua`), called from a script's `init`, is kept
until the fx params exist and applied in `Core.restore`. The spec lists
effects per chain, with values, or names a saved rack. Precedence is in
"Presets" below: the PSET's fx values win, and so does a kept rack unless
the spec says `replace` or the rack is empty. After `init` it is applied at
once. It returns false when the mod is installed but not enabled.

## Testing

- `test/click_test.scd`: boots scsynth, feeds a sine through the insert chain,
  performs place / swap / move / bypass / remove, records the output and fails
  on any sample-to-sample step above a threshold. It also checks the audio
  input, that a feedback send keeps ringing after the source stops, that
  a loop with gain 4 stays bounded, the meter readings, softcut's input, a
  ducker on the sidechain, the mod and tempo buses, two instances of one
  unit, and the units file.
- `test/run.lua`: runs the Lua core against the real norns `paramset` with
  stubbed OSC, covering the rack model, v1 API, PSET write/read, persist,
  the rack page's controls, softcut routing with and without
  `audio.port_connect`, the units file, instances and script requests.
