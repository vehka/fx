// A serial chain processed in place on one stereo bus. Order is node order.
FxChain {
	var <name, <bus, <group, <isSend;
	var <slots;   // index -> FxUnit
	var <>onChange;

	*new { |name, bus, group, isSend = false|
		^super.newCopyArgs(name, bus, group, isSend).init;
	}

	init {
		slots = IdentityDictionary.new;
	}

	isEmpty { ^slots.isEmpty }

	// node of the nearest occupied slot before index, or nil
	nodeBefore { |index|
		var best;
		slots.keysValuesDo { |i, unit|
			if((i < index) and: { unit.node.notNil }) {
				if(best.isNil or: { i > best }) { best = i };
			};
		};
		^best !? { slots[best].node };
	}

	// Put unit at index; nil empties the slot. Call inside a server bundle.
	place { |index, unit|
		var old = slots[index];
		var anchor;
		if(old === unit) { ^this };
		if(unit.notNil and: { unit.chain.notNil }) {
			// already running somewhere: release that instance first
			unit.chain.vacate(unit);
		};
		if(old.notNil) {
			anchor = old.node;
			slots.removeAt(index);
			old.release;
		};
		if(unit.notNil) {
			if(anchor.notNil) {
				unit.start(this, index, anchor, \addAfter);
			} {
				anchor = this.nodeBefore(index);
				if(anchor.notNil) {
					unit.start(this, index, anchor, \addAfter);
				} {
					unit.start(this, index, group, \addToHead);
				};
			};
			slots[index] = unit;
		};
		onChange.value(this, old);
	}

	vacate { |unit|
		if(unit.index.notNil and: { slots[unit.index] === unit }) {
			slots.removeAt(unit.index);
		};
		unit.release;
		onChange.value(this, unit);
	}

	clear {
		var last;
		slots.do { |unit| last = unit; unit.release };
		slots.clear;
		onChange.value(this, last);
	}

	forget {
		slots.do { |unit| unit.forget };
		slots.clear;
	}
}

// A send: a tap from the main bus, its own chain, a return to the main bus
// before or after the insert chain, and a level into every other send.
//
// The tap and the other sends write to inBus; the inlet copies it to the
// chain bus with InFeedback, behind a limiter. A writer that runs later in
// the node order (post tap with pre return, or a send further down) is then
// heard one block late instead of not at all, which is what makes feedback
// routing possible. Cooperating engines write to the chain bus directly.
FxSend {
	var <name, <bus, <inBus, <group, <chain, <tapSynth, <retSynth, <inlet;
	var <level = 0, <ret = 1, <tap = \pre, <dest = \post;
	var <area;   // \pre or \post: where the group currently lives
	var <crossLevels, <crossSynths;   // other send's name -> level, synth
	var gen = 0;

	*new { |name| ^super.newCopyArgs(name).init }

	init {
		crossLevels = IdentityDictionary.new;
		crossSynths = IdentityDictionary.new;
	}

	// buses first: build needs the other sends' inBus
	alloc { |server|
		bus = bus ?? { Bus.audio(server, 2) };
		inBus = inBus ?? { Bus.audio(server, 2) };
	}

	build { |server|
		this.alloc(server);
		area = dest;
		group = Group.new(FxRack.sendArea(area), \addToTail);
		inlet = Synth.new(\fxInlet, [\in, inBus, \out, bus], group, \addToHead);
		chain = FxChain.new(name, bus, Group.new(inlet, \addAfter), true);
		chain.onChange = { |ch, removed| this.chainChanged(removed) };
		retSynth = Synth.new(\fxReturn, [
			\in, bus, \out, FxRack.mainBus, \level, ret, \active, 0
		], group, \addToTail);
		FxRack.sends.keysValuesDo { |other, send|
			if(other != name) {
				crossSynths[other] = Synth.new(\fxReturn, [
					\in, bus, \out, send.inBus, \level, crossLevels[other] ? 0, \active, 0
				], group, \addToTail);
			};
		};
		tapSynth = Synth.new(\fxTap, [
			\in, FxRack.mainBus, \out, inBus, \level, level
		], FxRack.tapArea(tap), \addToTail);
	}

	forget {
		chain !? { chain.forget };
		group = nil; chain = nil; tapSynth = nil; retSynth = nil; inlet = nil;
		crossSynths.clear;
	}

	outputs { ^[retSynth] ++ crossSynths.values }

	// level from this send's chain output into another send
	setCross { |other, value|
		crossLevels[other] = value;
		crossSynths[other] !? { |syn| syn.set(\level, value) };
	}

	set { |key, value|
		switch(key,
			\level, { level = value; tapSynth !? { tapSynth.set(\level, level) } },
			\ret, { ret = value; retSynth !? { retSynth.set(\level, ret) } },
			\tap, { tap = if(value > 0) { \post } { \pre }; this.reroute },
			\dest, { dest = if(value > 0) { \post } { \pre }; this.reroute }
		);
	}

	// duck the return, move the nodes, bring it back
	reroute {
		var myGen;
		if(group.isNil) { ^this };
		gen = gen + 1;
		myGen = gen;
		retSynth.set(\duck, 0);
		tapSynth.set(\duck, 0);
		SystemClock.sched(0.08, {
			if((gen == myGen) and: { group.notNil }) {
				FxRack.server.makeBundle(nil, {
					area = dest;
					group.moveToTail(FxRack.sendArea(area));
					tapSynth.moveToTail(FxRack.tapArea(tap));
					retSynth.set(\duck, 1);
					tapSynth.set(\duck, 1);
				});
			};
			nil;
		});
	}

	// mute the outputs while the chain is empty, after the last tail has rung out
	chainChanged { |removed|
		if(retSynth.isNil) { ^this };
		if(chain.isEmpty) {
			var wait = (FxRack.fade * 2) + (removed !? { removed.tail } ? 0) + 0.1;
			var myChain = chain;
			SystemClock.sched(wait, {
				if((chain === myChain) and: { chain.isEmpty } and: { retSynth.notNil }) {
					this.outputs.do { |syn| syn.set(\active, 0) };
				};
				nil;
			});
		} {
			this.outputs.do { |syn| syn.set(\active, 1) };
		};
	}
}

// The rack: groups, buses, chains and the OSC interface used by the Lua side.
FxRack {
	classvar <server, <ready = false, building = false;
	classvar <group, <preTaps, <preSends, <insertGroup, <postTaps, <postSends;
	classvar <mainBus, <insert, <sends;
	classvar <>inBuses;   // two mono bus indices carrying the audio inputs
	classvar <inputSynth, <inputLevel = 0, <inputMono = 0;
	// softcut, when it is patched to the server's third and fourth input
	classvar <>cutBuses, <softcutSynth, <softcutLevel = 0;
	// what softcut records of the engine while it is in the rack: a tap taken
	// before softcut joins, on the server's outputs 3 and 4
	classvar <>feedBus, <feedSynth, <feedLevel = 0;
	// shared buses any unit may read: the sidechain (key) signal, and one
	// control bus of [key envelope, tempo, mod 1..4]
	classvar <keyBus, <ctlBus, <keySynth, <keySettings, <bpm = 120, <mods;
	classvar <>numMods = 4;
	// where the list of units is written for the Lua side; nil outside norns
	classvar <>unitsFile, started = false;
	classvar <>fade = 0.05;
	classvar <meterIn, <meterOut, meterBus;
	classvar <>matron;   // where meter and CPU readings go: matron's OSC port
	classvar queue;
	classvar <sendNames;

	*initClass {
		sendNames = [\a, \b];
		queue = List.new;
		sends = IdentityDictionary.new;
		keySettings = (src: 0, gain: 1, attack: 0.005, release: 0.15);
		mods = 0 ! numMods;
		// Two more server inputs, for softcut: crone boots the server from a
		// StartUp function, which runs after every initClass.
		Class.initClassTree(Server);
		Server.local.options.numInputBusChannels = max(Server.local.options.numInputBusChannels, 4);
		// and two more outputs, for what softcut records: see feedBus
		Server.local.options.numOutputBusChannels = max(Server.local.options.numOutputBusChannels, 4);
		StartUp.add {
			if(\Crone.asClass.notNil) {
				unitsFile = unitsFile ?? { Platform.userHomeDir +/+ "dust/data/fx/units.lua" };
			};
			started = true;
			this.unitsChanged;
			this.addOSC;
			ServerQuit.add({ this.reset }, \all);
			CmdPeriod.add({ this.reset });
		};
	}

	*sendArea { |which| ^if(which == \pre) { preSends } { postSends } }
	*tapArea { |which| ^if(which == \pre) { preTaps } { postTaps } }

	*units { ^FxUnit.all }

	// called when a unit is registered: keep the list for the Lua side current
	*unitsChanged {
		if(started and: { unitsFile.notNil }) { FxUnit.writeUnits(unitsFile) };
	}

	// For use inside a unit's function. The bus numbers arrive as controls of
	// the unit's synth, so nothing here depends on when the def was built.

	// the sidechain signal, stereo
	*key { ^In.ar(\fx_key.kr(0), 2) }
	// its envelope, 0..1 for a full-scale signal
	*env { ^In.kr(\fx_ctl.kr(0)) }
	// beats per minute and seconds per beat of the norns clock
	*tempo { ^In.kr(\fx_ctl.kr(0) + 1).max(1) }
	*beat { ^60 / this.tempo }
	// modulation bus n (1..numMods), 0..1, set by the fx_mod_<n> params
	*mod { |n = 1| ^Lag.kr(In.kr(\fx_ctl.kr(0) + 1 + n.clip(1, numMods)), 0.05) }

	*chain { |name|
		^if(name == \insert) { insert } { sends[name] !? { |s| s.chain } };
	}

	// the node tree is gone: drop all references so the next ensure rebuilds
	*reset {
		ready = false;
		building = false;
		FxUnit.all.do { |u| u.forget };
		sends.do { |s| s.forget };
		insert = nil;
		group = nil;
		inputSynth = nil;
		softcutSynth = nil;
		feedSynth = nil;
		keySynth = nil;
		meterIn = nil;
		meterOut = nil;
	}

	// Run f now if the rack is built, otherwise once it is.
	*do { |f|
		if(ready) { f.value } { queue.add(f) };
	}

	*ensure { |onDone|
		if(ready) { onDone.value; ^this };
		onDone !? { queue.add(onDone) };
		if(building) { ^this };
		building = true;
		fork {
			var crone = \Crone.asClass;
			var context = crone !? { crone.context };
			// crone boots the server and builds its context; wait for both
			server = (crone !? { crone.server }) ? Server.default;
			while { server.isNil or: { server.serverRunning.not } } {
				0.2.wait;
				server = (crone !? { crone.server }) ? Server.default;
			};
			if(crone.notNil) {
				while { crone.context.isNil } { 0.2.wait };
			};
			context = crone !? { crone.context };
			keyBus = keyBus ?? { Bus.audio(server, 2) };
			ctlBus = ctlBus ?? { Bus.control(server, 2 + numMods) };
			ctlBus.setn([0, bpm] ++ mods);
			this.sendDefs;
			server.sync;
			mainBus = Bus.new(\audio, 0, 2, server);
			group = if(context.notNil) {
				Group.after(context.og);
			} {
				Group.new(server.defaultGroup, \addToTail);
			};
			// the audio inputs join the main bus ahead of everything else
			inBuses = inBuses ?? {
				if(context.notNil) {
					context.in_b.collect(_.index);
				} {
					server.options.numOutputBusChannels + [0, 1];
				};
			};
			inputSynth = Synth.new(\fxInput, [
				\in_l, inBuses[0], \in_r, inBuses[1], \out, mainBus,
				\level, inputLevel, \mono, inputMono
			], group, \addToHead);
			// softcut joins the same way when its outputs are patched to the
			// server's inputs 3 and 4, which the Lua side does on norns 3.x
			cutBuses = cutBuses ?? {
				if(server.options.numInputBusChannels >= 4) {
					server.options.numOutputBusChannels + [2, 3];
				};
			};
			if(cutBuses.notNil) {
				softcutSynth = Synth.new(\fxInput, [
					\in_l, cutBuses[0], \in_r, cutBuses[1], \out, mainBus,
					\level, softcutLevel, \mono, 0
				], inputSynth, \addAfter);
			};
			// The engine alone, for softcut to record: at the very head, where
			// nothing of the rack and no softcut is on the main bus yet. With
			// softcut in the rack the engine-to-softcut path inside crone would
			// carry softcut back into itself, so the Lua side closes it and
			// sets this level to what was asked of crone.
			feedBus = feedBus ?? { if(server.options.numOutputBusChannels >= 4) { 2 } };
			if(feedBus.notNil) {
				feedSynth = Synth.new(\fxTap, [
					\in, mainBus, \out, feedBus, \level, feedLevel
				], group, \addToHead);
			};
			preTaps = Group.new(group, \addToTail);
			preSends = Group.new(group, \addToTail);
			insertGroup = Group.new(group, \addToTail);
			postTaps = Group.new(group, \addToTail);
			postSends = Group.new(group, \addToTail);
			insert = FxChain.new(\insert, mainBus, insertGroup, false);
			sendNames.do { |n|
				if(sends[n].isNil) { sends[n] = FxSend.new(n) };
				sends[n].alloc(server);
			};
			sendNames.do { |n| sends[n].build(server) };
			// the sidechain: after the sources, ahead of everything that may read it
			keySynth = Synth.new(\fxKey, [
				\main, mainBus, \in_l, inBuses[0], \in_r, inBuses[1],
				\a, sends[\a].bus, \b, sends[\b].bus,
				\cut_l, (cutBuses ? inBuses)[0], \cut_r, (cutBuses ? inBuses)[1],
				\has_cut, cutBuses.notNil.binaryValue,
				\out, keyBus, \env, ctlBus
			] ++ keySettings.asPairs, preTaps, \addBefore);
			// v1 engines look these up when they allocate
			topEnvironment.put(\sendA, sends[\a].bus);
			topEnvironment.put(\sendB, sends[\b].bus);
			server.sync;
			ready = true;
			building = false;
			"fx: rack ready".postln;
			queue.do { |f| f.value };
			queue.clear;
		};
	}

	*sendDefs {
		SynthDef(\fxTap, { |in, out, level = 0, duck = 1|
			Out.ar(out, In.ar(in, 2) * Lag.kr(level, 0.05) * Lag.kr(duck, 0.05));
		}).send(server);

		SynthDef(\fxReturn, { |in, out, level = 1, active = 0, duck = 1|
			var amp = Lag.kr(level, 0.05) * Lag.kr(active, 0.05) * Lag.kr(duck, 0.05);
			Out.ar(out, In.ar(in, 2) * amp);
		}).send(server);

		SynthDef(\fxInput, { |in_l, in_r, out, level = 0, mono = 0|
			var l = In.ar(in_l), r = In.ar(in_r);
			var mid = (l + r) * 0.5;
			var m = Lag.kr(mono, 0.05);
			Out.ar(out, [l + ((mid - l) * m), r + ((mid - r) * m)] * Lag.kr(level, 0.05));
		}).send(server);

		// send input: see FxSend. The limiter has no lookahead, so a send is
		// not delayed; it is transparent below full scale and keeps a
		// feedback loop bounded. LeakDC stops a loop latching up on DC.
		SynthDef(\fxInlet, { |in, out|
			var sig = LeakDC.ar(FxUnit.guard(InFeedback.ar(in, 2)), 0.9997);
			var env = Amplitude.ar(max(sig[0].abs, sig[1].abs), 0.001, 0.2);
			Out.ar(out, (sig / env.max(1)).clip2(1));
		}).send(server);

		// Sidechain. src: 0 off, 1 the rack's input (engine and whatever
		// else joined the main bus), 2 the audio inputs alone, 3 and 4 the
		// output of a send's chain (one block late), 5 softcut.
		SynthDef(\fxKey, { |main, in_l, in_r, a, b, cut_l, cut_r, has_cut = 0, out, env,
			src = 0, gain = 1, attack = 0.005, release = 0.15|
			var sig = Select.ar(src.clip(0, 5), [
				DC.ar(0) ! 2,
				In.ar(main, 2),
				[In.ar(in_l), In.ar(in_r)],
				InFeedback.ar(a, 2),
				InFeedback.ar(b, 2),
				[In.ar(cut_l), In.ar(cut_r)] * has_cut
			]);
			sig = FxUnit.guard(sig) * Lag.kr(gain, 0.05);
			Out.ar(out, sig);
			Out.kr(env, A2K.kr(Amplitude.ar(max(sig[0].abs, sig[1].abs), attack, release)).min(4));
		}).send(server);

		// meters, running only while the rack page is open. The level at the
		// rack's input is taken at the head of the group and passed on a
		// control bus, so one reply carries every reading.
		SynthDef(\fxMeterIn, { |in, out|
			Out.kr(out, FxRack.level(In.ar(in, 2)));
		}).send(server);

		SynthDef(\fxMeterOut, { |main, a, b, in, rate = 15|
			SendReply.kr(Impulse.kr(rate), '/fxMeter', [
				In.kr(in),
				FxRack.level(In.ar(a, 2)),
				FxRack.level(In.ar(b, 2)),
				FxRack.level(In.ar(main, 2))
			]);
		}).send(server);

		// wrapper halves for v1 plugins, see FxUnit.start
		SynthDef(\fxLegacyPre, { |fx_bus, fx_in, fx_gate = 1, fx_bypass = 0, fx_fade = 0.05|
			var on = EnvGen.kr(Env.asr(fx_fade, 1, fx_fade, \sine), fx_gate);
			var act = Lag.kr(1 - fx_bypass, fx_fade);
			Out.ar(fx_in, In.ar(fx_bus, 2) * on * act);
		}).send(server);

		SynthDef(\fxLegacyPost, { |fx_bus, fx_wet, fx_gate = 1, fx_mix = 1, fx_bypass = 0,
			fx_fade = 0.05, fx_tail = 0|
			var dry = In.ar(fx_bus, 2);
			var amt, life, wet, m;
			#amt, life = FxUnit.gates(fx_gate, fx_bypass, fx_fade, fx_tail, 14);
			wet = FxUnit.guard(In.ar(fx_wet, 2));
			m = Lag.kr(fx_mix, 0.05);
			ReplaceOut.ar(fx_bus, (dry * (1 - (m * amt))) + (wet * m * life));
		}).send(server);

		FxUnit.all.do { |unit| unit.sendDef(server) };
	}

	// unitName nil or \none empties the slot
	*place { |chainName, index, unitName|
		var chain = this.chain(chainName);
		var unit = if(unitName.isNil or: { unitName == \none }) { nil } { FxUnit.find(unitName) };
		if(chain.isNil) { ("fx: no chain " ++ chainName).warn; ^this };
		if(unit.isNil and: { unitName.notNil } and: { unitName != \none }) {
			("fx: unknown unit " ++ unitName).warn;
			^this;
		};
		server.makeBundle(nil, { chain.place(index, unit) });
	}

	*setInput { |key, value|
		switch(key,
			\level, { inputLevel = value; inputSynth !? { inputSynth.set(\level, value) } },
			\mono, { inputMono = value; inputSynth !? { inputSynth.set(\mono, value) } }
		);
	}

	// Some engines add an output stage at the tail of the root group when
	// they load, after the rack, which then sees none of their sound. The
	// Lua side calls this once the script's engine is up.
	*toTail {
		if(group.notNil) { group.moveToTail(group.group ? server.defaultGroup) };
	}

	// softcut into the rack; the JACK routes are made by the Lua side
	*setSoftcut { |value|
		softcutLevel = value;
		softcutSynth !? { softcutSynth.set(\level, value) };
	}

	*setFeed { |value|
		feedLevel = value;
		feedSynth !? { feedSynth.set(\level, value) };
	}

	// key: \src, \gain, \attack or \release
	*setKey { |key, value|
		keySettings[key] = value;
		keySynth !? { keySynth.set(key, value) };
	}

	*setTempo { |value|
		bpm = value.clip(1, 1000);
		ctlBus !? { ctlBus.setAt(1, bpm) };
	}

	*setMod { |n, value|
		n = n.asInteger;
		if((n >= 1) and: { n <= numMods }) {
			mods[n - 1] = value;
			ctlBus !? { ctlBus.setAt(1 + n, value) };
		};
	}

	// peak follower over both channels, at control rate
	*level { |sig|
		^A2K.kr(Amplitude.ar(max(sig[0].abs, sig[1].abs), 0.005, 0.3));
	}

	// Meters: rack input, the output of each send's chain, rack output.
	// Readings go to matron as /fx/meter in a b out cpuAvg cpuPeak.
	*setMeter { |on|
		if(on) {
			if(meterOut.isNil) {
				meterBus = meterBus ?? { Bus.control(server, 1) };
				server.makeBundle(nil, {
					// after every source: the audio inputs and softcut
					meterIn = Synth.new(\fxMeterIn, [\in, mainBus, \out, meterBus],
						keySynth, \addBefore);
					meterOut = Synth.new(\fxMeterOut, [
						\main, mainBus, \a, sends[\a].bus, \b, sends[\b].bus, \in, meterBus
					], group, \addToTail);
				});
			};
		} {
			meterIn !? { meterIn.free };
			meterOut !? { meterOut.free };
			meterIn = nil;
			meterOut = nil;
		};
	}

	*clear {
		if(ready.not) { ^this };
		server.makeBundle(nil, {
			insert.clear;
			sends.do { |s| s.chain.clear };
		});
	}

	*addOSC {
		FxUnit.all.do { |unit| if(unit.isLegacy) { unit.plugin.listenOSC } };
		OSCFunc({ this.ensure }, '/fx/ensure');
		OSCFunc({ |msg|
			var chainName = msg[1].asSymbol, index = msg[2].asInteger, unitName = msg[3].asSymbol;
			this.do { this.place(chainName, index, unitName) };
		}, '/fx/slot');
		OSCFunc({ |msg|
			var unit = FxUnit.find(msg[1].asSymbol);
			if(unit.notNil) {
				unit.set(msg[2].asSymbol, msg[3].asFloat);
			} {
				("fx: unknown unit " ++ msg[1]).warn;
			};
		}, '/fx/set');
		OSCFunc({ |msg|
			var name = msg[1].asSymbol, key = msg[2].asSymbol, value = msg[3].asFloat;
			this.do {
				var send = sends[name];
				if(send.notNil) { send.set(key, value) } { ("fx: no send " ++ name).warn };
			};
		}, '/fx/send');
		OSCFunc({ |msg|
			var from = msg[1].asSymbol, to = msg[2].asSymbol, value = msg[3].asFloat;
			this.do {
				var send = sends[from];
				if(send.notNil and: { sends[to].notNil } and: { from != to }) {
					send.setCross(to, value);
				} {
					("fx: no send path " ++ from ++ " -> " ++ to).warn;
				};
			};
		}, '/fx/xsend');
		OSCFunc({ |msg| this.setInput(msg[1].asSymbol, msg[2].asFloat) }, '/fx/input');
		OSCFunc({ |msg| this.setSoftcut(msg[1].asFloat) }, '/fx/softcut');
		OSCFunc({ |msg| this.setFeed(msg[1].asFloat) }, '/fx/cutfeed');
		OSCFunc({ |msg| this.setKey(msg[1].asSymbol, msg[2].asFloat) }, '/fx/key');
		OSCFunc({ |msg| this.setTempo(msg[1].asFloat) }, '/fx/tempo');
		OSCFunc({ |msg| this.setMod(msg[1], msg[2].asFloat) }, '/fx/mod');
		OSCFunc({ this.do { this.toTail } }, '/fx/tail');
		OSCFunc({ this.do { this.clear } }, '/fx/clear');
		OSCFunc({ |msg| fade = msg[1].asFloat.max(0.005) }, '/fx/fade');
		OSCFunc({ |msg|
			var on = msg[1].asInteger > 0;
			this.do { this.setMeter(on) };
		}, '/fx/meter');
		matron = matron ?? { NetAddr("127.0.0.1", 10111) };
		OSCFunc({ |msg|
			if(meterOut.notNil and: { msg[1] == meterOut.nodeID }) {
				matron.sendMsg('/fx/meter', msg[3], msg[4], msg[5], msg[6],
					server.avgCPU ? 0, server.peakCPU ? 0);
			};
		}, '/fxMeter');
	}
}
