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
sources: engine (bus 0) | cooperative per-voice sends | (later) ADC, softcut
main:    PRE taps -> pre sends -> INSERT chain -> POST taps -> post sends -> out
send X:  tap level -> chain -> return level -> main bus, pre or post insert
```

Node tree, inside one group placed directly after `context.og`:

```
fx group
  preTaps     tap synths of sends with tap = pre
  preSends    send groups whose return is pre-insert
  insert      main chain, in place on bus 0
  postTaps    tap synths of sends with tap = post
  postSends   send groups whose return is post-insert
```

A send group holds the send's chain group followed by its return synth. A
pre-insert return passes through the inserts. Tap = post with return = pre
would be a feedback path; until feedback routing exists it is treated as
return = post.

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
- **Per-unit `slot` option** (`none / send a / send b / insert`, the v1 param)
  puts the unit in the first free slot of that chain.
- **Per-unit position** (`fx_pos_<unit>`, hidden, saved) gives the index in the
  chain. Slot + position restore a rack independently of which other plugins
  are installed.
- **Rack slot params** (`fx_ins_1..4`, `fx_a_1..2`, `fx_b_1..2`) are an
  unsaved view for editing order; their option lists depend on what is
  installed, so they are not written to PSETs.
- Placing a unit on an occupied slot moves the occupant to the first free slot
  of the chain, or out of the rack if the chain is full.
- **Sends**: `level` (master tap, so any script can use the send), `tap`
  (pre/post), `return` level, `dest` (pre/post insert).

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

## Presets (step 3)

- Per-fx presets in `dust/data/fx/<unit>/<name>.fxp`; `default.fxp` is applied
  when the unit is placed; factory presets ship in the plugin's `presets/`.
  Each fx group gets `preset`, `load`, `save as...`, `save as default`.
- Rack scenes save the rack, routing and all values. A default rack applies to
  scripts with no fx state.

## Later steps

4. ADC as a source; send-to-send and feedback routing with `InFeedback` behind
   a limiter.
5. Rack page in the mod menu: slots, order, bypass, meters, CPU.
6. Softcut as a source (extra SC inputs + JACK routes), sidechain and
   modulation control buses, tempo sync, plugins as a single `.sc` file with
   params read from SynthDef metadata, multiple instances per unit, a script
   API to request a rack.

## Testing

- `test/click_test.scd`: boots scsynth, feeds a sine through the insert chain,
  performs place / swap / move / bypass / remove, records the output and fails
  on any sample-to-sample step above a threshold.
- `test/run.lua`: runs the Lua core against the real norns `paramset` with
  stubbed OSC, covering the rack model, v1 API, PSET write/read and persist.
