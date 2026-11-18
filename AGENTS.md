# Working on fx

Handoff notes for whoever picks this up next, human or agent.

**Keep this file current.** Before ending a session that changed the code,
update "Where things stand" and "Next" below, and add anything to "Things
that will bite you" that cost you time. Remove entries that are no longer
true. Design decisions and their reasons belong in `docs/DESIGN.md`, user-facing
behaviour in `README.md`; this file is only what you need to resume work.

## What this is

A norns mod: a rack of SuperCollider effects (serial inserts and two send
chains) that works with any script. This is v2, a rewrite, on branch `v2`.
It targets norns 3.x and replaces v1 in `dust/code/fx`. On older versions
(no `audio.port_connect`) only softcut routing is skipped; keep it that way.

Read `docs/DESIGN.md` first. It has the signal model, the node tree, the Lua
model and the precedence rules for restoring values.

## Where things stand

The plan in the design is implemented. Lua test and click test cover all of
it; on hardware it has been checked to different depths:

1. SC core: in-place chains, wrapper with fades/tails/NaN guard, bundled graph
   changes, v1 plugin compatibility (`lib/FxRack.sc`, `FxUnit.sc`, `FxLegacy.sc`).
   Checked on hardware.
2. Lua core: registry, rack model, params, PSET restore, persist across
   scripts, settings page (`lib/core.lua`, `fx.lua`, `mod.lua`). Checked on
   hardware, except start-up restore from a script's own PSET.
3. Presets: per-effect presets, rack scenes, defaults (`lib/presets.lua`).
4. Menu UX: rack rows and effect slot rows are scroll-with-E3, apply-with-K3
   (`lib/chooser.lua`).
5. Routing: audio inputs as a source (`fx_input_*`), send-to-send
   (`fx_send_a_to_b`, `fx_send_b_to_a`), feedback routing through the send
   inlets (`FxSend`, `\fxInlet`). Checked on hardware, by ear as well: node
   tree, CPU (about 17% under awake with two v1 effects), xruns.
6. Rack page (`lib/page.lua`): slots, order, bypass, dry/wet, meters, CPU,
   settings rows; K1 + K3 opens a row (an effect's params, a send's or the
   input's routing); rows for input and send levels and for loading and
   saving racks. Driven over the REPL and checked by screenshot on hardware;
   the opened-row view and the "save as..." name entry only partly.
7. Step 6: softcut as a source, sidechain and modulation buses, tempo,
   single-file plugins through `dust/data/fx/units.lua`, multiple instances
   ("copies"), `fx.request`. See the sections of those names in the design.
   The README has a signal graph of the whole rack; keep it in step with
   routing changes.

   On hardware: start-up (four server inputs, `units.lua` written before the
   mods' start-up hook, v1 plugins register), `fx_softcut` repatching and
   restoring after a script change, tempo reaching `FxRack.bpm`. Softcut's
   dry feed was measured with awake (softcut delay at feedback 0.75,
   engine-to-softcut 1, output muted, levels read from control buses): with a
   steady 0.1 tone the feed carried 0.097 and softcut settled at 0.109; with
   crone's own engine-to-softcut path reopened by hand the noise floor grew
   twentyfold in 9 s, which is the loop the feed replaces. Crone's softcut
   controls through the rack were measured from crone's meters: see "Crone's
   softcut controls" in the design. The softcut fader wrap (`Core.wrap_cut`)
   is Lua-tested only.

Not verified on hardware: softcut through the rack by ear and whether
repatching clicks; the sidechain, mod buses and copies (they need a native
unit); a unit from the units file; `fx.request`; the rack page with the
physical keys and encoders, above all the K1-hold gestures and the meters in
motion.

## Next

What is left is hardware. Check the items above on a device (`test/run.lua`
uses `page.select(label)`; on the device it is
`_menu.m["fx"].select("send a")` and so on) and ask the user how the page
feels in the hand. No effect that uses the sidechain, mod or tempo buses
exists outside the click test; one is needed to hear them.

Smaller open items:

- A one-off `clock.resume` thread error was seen once on a script load;
  watch for a repeat. Leave core unpatched.
- Crone's REVERB "input softcut" does nothing while softcut is in the rack
  (documented, not hidden; see the design).
- Scenes saved before step 4 do not mention the input and send-to-send
  params, and those from before step 6 not the softcut, sidechain and mod
  params, so loading one leaves those as they are.
- The tempo is not followed while no script is loaded.
- Spec'd params are controls only: no options or switches without Lua.
- A copy removed while a script runs leaves its params in the menu until the
  next script; they do nothing.
- The sidechain source switches without a fade.
- Rack page ideas not done: moving an effect between chains with K1 + E2,
  clipping hold on the meters, per-effect presets on the page, K1 + K2 (free).
- The page's param rows need a running script. Making fx params exist with
  no script is the fix if the user wants it; see "Rack page" in the design.
- If matron restarts on its own while the page is open, SC keeps sending
  meter messages until the page is opened and closed again.
- Params a v1 plugin sets up without the helper API (e.g. `fx_resonator`'s
  note and model) are not in presets or the live state.
- Factory preset lookup fails if a plugin writes `return fx.register{...}` as
  a tail call; `plugin_dir` can be passed explicitly.

## Testing

```
lua5.3 test/run.lua [path/to/norns/lua]   # Lua core against the real paramset
test/run_sc.sh                            # audio click test, local scsynth
```

Both must pass before committing. `run.lua` defaults to `~/git/norns/lua`.
`run_sc.sh` needs sclang, scsynth and JACK (pipewire-jack works); it does not
connect to the speakers.

### On the device

Ask the user which device to use and its address. SSH as `we`.

```
rsync -a --delete --exclude .git ./ we@<ip>:dust/code/fx/
test/repl.py --host <ip> '_norns.reset()'                      # restart matron + sclang
test/repl.py --host <ip> --wait 14 'norns.script.load("code/awake/awake.lua")'
test/repl.py --host <ip> 'print(require("fx/lib/core").rack.insert[1])'
test/repl.py --host <ip> --sc 'Crone.server.queryAllNodes;'
ssh we@<ip> 'journalctl -u norns-main -n 80 --no-pager'        # also norns-sclang, norns-jack
```

- A restart is needed after any change: `.sc` classes are compiled at boot,
  and the Lua modules are cached by `require` and shared with the plugin mods.
- Menus can be driven with `_menu.set_page("PARAMS")`, `_menu.set_mode(true)`,
  `_menu.enc(n, d)`, `_menu.key(n, z)`, and captured with
  `_norns.screen_export_screenshot("/tmp/x.png")`. The rack page is
  `_menu.set_page("fx")`; call `_menu.m["fx"].key(n, z)` and `.enc(n, d)`
  directly, since K1 does not go through `_menu.key`.
- A known signal for the meters, from the sclang REPL:
  `~t = { Out.ar(0, SinOsc.ar(330, 0, 0.1) ! 2) }.play(target: Crone.context.xg);`
  then `~t.free;`.
- For multi-line code, copy a file to `/tmp` and `dofile` / `.load` it.
- The click test can run inside the device's sclang: take
  `test/click_test.scd`, remove the server boot/quit/exit lines, and load it.
  It plays a test tone on the outputs; free `testSrc` and any `testHard`
  node afterwards.
- Tell the user before restarting or making sound on their device. Leave
  the rack empty and the fx params neutral when done, above all the send
  levels of any feedback patch.
- `repl.py` needs `websocket-client`: `python3 -m venv <dir outside the repo>`
  and `pip install websocket-client`, then run it with that venv's python.
- Before installing over v1 on a device, back up its `dust/code/fx` and
  mod list outside the SC search paths (`~`, not under `dust/`).
- A silent way to measure crone's mixer: wrap `_norns.vu` (it gets input,
  output, engine, monitor, softcut and tape peaks, 0 to 64) and mute the
  output; the meters read before the output level. Put `_norns.vu` back.

## Conventions

- Commit messages: no AI attribution or tool-specific trailers.
- Commit when a step is done and tested; do not push unless asked.
- The user wants norns core left unpatched: use the param and mod contracts.

## Things that will bite you

- **Two definitions of `FxBase`/`FxSetup` stop sclang compiling**, which means
  no audio at all. Never leave a second copy of fx, or a `.sc` test class,
  under `dust/`. The test plugin is `test/FxTestLegacy.sc.txt` for this reason.
- **v1 plugins are not uniform.** Some add their own params from
  `script_post_init`, some use separators instead of groups, some send OSC to
  their own `<subpath>/set`, and `fx_resonator` overrides `listenOSC` and
  touches `syn` directly. `add_slot` must add exactly two params or v1 group
  sizes break. Check a change against the plugins on the device, not only
  the test plugin.
- **Engines written against v1 internals may ask for `FxSetup.insertInput`**
  (a modified Sines does). Keep that compatibility getter returning nil: such
  an engine then disables its old extra insert feed. Returning the main bus
  instead would double its dry signal.
- **Param actions only fire on change.** Anything restored from a PSET must
  give the same result whatever the line order and whatever was loaded
  before; that is why slot/position params move occupants instead of
  dropping them, while rack rows (applied by hand) replace.
- **The stock params menu applies option params on every encoder step.** Use
  `Chooser` for anything that loads or moves an effect.
- **Rack row option lists depend on what is installed**, so rack rows are
  never saved; the per-unit slot and position are.
- **A send's chain is fed through `InFeedback` from `inBus`**, not from the
  tap directly. Anything new that feeds a send writes to `inBus`; only
  cooperating engines write to the chain bus.
- **A PSET with a post tap and a pre return was a plain post return before
  step 4** and is now a feedback loop.
- **Pre tap with pre return is not a loop**: the return lands after the tap
  point. Feedback needs a post tap with a pre return, or both send-to-send
  levels with an effect on each send.
- **A long K1 press reaches a menu page late.** `_menu.alt` is true from the
  moment K1 goes down, `key(1, 1)` arrives after the long-press timer, and a
  short press never arrives: it leaves the menu. The page reads `_menu.alt`.
- **The node tree dump does not list the children of a paused group**, so a
  bypassed v1 unit looks like an empty group. Its synths are still there.
- **A restart can take two minutes** when some process holds up the stop of
  `norns-main` until systemd kills it after 90 s. Poll the REPL until it
  answers instead of sleeping a fixed time.
- **An engine can put nodes after the rack.** Sines adds its output stage
  with `addToTail` and no target, which lands in the root group behind the
  rack. `/fx/tail` at `script_post_init` moves the rack to the tail; if a
  script is not processed, look at the node order first. The click test
  covers the fix; it has not run on hardware yet.
- **A classvar getter and a class method of the same name do not compile**
  (`classvar <tempo` with `*tempo`), and that is the no-audio failure above.
- **FxRack raises the server's inputs and outputs to 4 each, for every
  script.** Hardware inputs are then buses 4 to 7 and private buses start at
  8; an engine with hard-coded bus numbers would notice. None of 311 `.sc`
  files in a script archive has any.
- **`audio.level_eng_cut` and `audio.level_cut` are wrapped by the mod** (see
  "What softcut records" and "Crone's softcut controls" in the design). With
  softcut in the rack, crone's real engine-to-softcut level is 0 and must
  stay 0: never call `Core.eng_cut_original` with anything else then.
- **`audio.port_connect` marks the routing as altered**, so core resets every
  route at the next script change and calls the restore hook. A route made
  inside that hook does not set the mark again.
- **Do not `clock.cancel` a coroutine id kept across a script change**: core
  has already cancelled it and the id may now be the script's.
- **SC dictionary `put` returns the dictionary**, so
  `x = d[k] ?? { d[k] = v }` does not give you `v`.
- **Mod load order is not alphabetical**, and `system_post_startup` can run
  before sclang listens; `/fx/ensure` is sent again at every `script_pre_init`.
- **xruns at restart and script load are normal on some devices.** Judge a
  change by the per-minute count in `journalctl -u norns-jack` while idle and
  while exercising the rack.
