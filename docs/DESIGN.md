# fx v2 design

Target: norns 3.x only (uses `audio.port_connect` and the
`audio_post_restore_default_routing` hook for the later source-routing work).
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
sources: engine (bus 0) | audio inputs | cooperative per-voice sends | (later) softcut
main:    input -> PRE taps -> pre sends -> INSERT chain -> POST taps -> post sends -> out
send X:  tap level + other sends -> inlet -> chain -> return level -> main bus, pre or post insert
                                                   -> level into each other send
```

Node tree, inside one group placed directly after `context.og`:

```
fx group
  input       audio inputs (context.in_b) into the main bus, level 0 by default
  preTaps     tap synths of sends with tap = pre
  preSends    send groups whose return is pre-insert
  insert      main chain, in place on bus 0
  postTaps    tap synths of sends with tap = post
  postSends   send groups whose return is post-insert
```

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
`FxSetup.sendB` stay for cooperating engines.

## Lua model

The rack model in Lua is the source of truth; SC executes `/fx/slot`,
`/fx/set`, `/fx/send`, `/fx/clear`.

- **Units** are registered once at mod load, by the v1 API
  (`fx:new{subpath=...}` + `add_params`) or the declarative v2 API
  (`fx.register{name=..., params={...}}`). One instance per unit for now.
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
| `script_post_init` | add params, restore values, bang fx params, rebuild the params menu |
| `script_post_cleanup` | if persist is off, `/fx/clear` |

Restoring values at `script_post_init`:

- **persist on** (default, "station mode"): the rack keeps running across
  script changes and the new script's fx params take the live values.
- **persist off**: the rack is cleared at cleanup, and fx values are re-read
  from the PSET the script loaded in `init`.

PSETs loaded later from the params menu read fx params natively.

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
  read > default scene > each unit's default preset > built-in defaults.
  Defaults are not re-applied when a unit is placed, so moving a unit never
  discards edits.

## Later steps

5. Rack page in the mod menu: slots, order, bypass, meters, CPU.
6. Softcut as a source (extra SC inputs + JACK routes), sidechain and
   modulation control buses, tempo sync, plugins as a single `.sc` file with
   params read from SynthDef metadata, multiple instances per unit, a script
   API to request a rack.

## Testing

- `test/click_test.scd`: boots scsynth, feeds a sine through the insert chain,
  performs place / swap / move / bypass / remove, records the output and fails
  on any sample-to-sample step above a threshold. It also checks the audio
  input, that a feedback send keeps ringing after the source stops, and that
  a loop with gain 4 stays bounded.
- `test/run.lua`: runs the Lua core against the real norns `paramset` with
  stubbed OSC, covering the rack model, v1 API, PSET write/read and persist.
