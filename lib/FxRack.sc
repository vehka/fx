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

// A send bus: tap from the main bus, its own chain, and a return to the main
// bus either before or after the insert chain.
FxSend {
	var <name, <bus, <group, <chain, <tapSynth, <retSynth;
	var <level = 0, <ret = 1, <tap = \pre, <dest = \post;
	var <area;   // \pre or \post: where the group currently lives
	var gen = 0;

	*new { |name| ^super.newCopyArgs(name) }

	build { |server|
		bus = bus ?? { Bus.audio(server, 2) };
		area = this.wantedArea;
		group = Group.new(FxRack.sendArea(area), \addToTail);
		chain = FxChain.new(name, bus, Group.new(group, \addToHead), true);
		chain.onChange = { |ch, removed| this.chainChanged(removed) };
		retSynth = Synth.new(\fxReturn, [
			\in, bus, \out, FxRack.mainBus, \level, ret, \active, 0
		], group, \addToTail);
		tapSynth = Synth.new(\fxTap, [
			\in, FxRack.mainBus, \out, bus, \level, level
		], FxRack.tapArea(tap), \addToTail);
	}

	forget {
		chain !? { chain.forget };
		group = nil; chain = nil; tapSynth = nil; retSynth = nil;
	}

	// a post-insert tap cannot return before the insert without feedback
	wantedArea {
		^if((dest == \pre) and: { tap == \pre }) { \pre } { \post };
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
					area = this.wantedArea;
					group.moveToTail(FxRack.sendArea(area));
					tapSynth.moveToTail(FxRack.tapArea(tap));
					retSynth.set(\duck, 1);
					tapSynth.set(\duck, 1);
				});
			};
			nil;
		});
	}

	// mute the return while the chain is empty, after the last tail has rung out
	chainChanged { |removed|
		if(retSynth.isNil) { ^this };
		if(chain.isEmpty) {
			var wait = (FxRack.fade * 2) + (removed !? { removed.tail } ? 0) + 0.1;
			var myChain = chain;
			SystemClock.sched(wait, {
				if((chain === myChain) and: { chain.isEmpty } and: { retSynth.notNil }) {
					retSynth.set(\active, 0);
				};
				nil;
			});
		} {
			retSynth.set(\active, 1);
		};
	}
}

// The rack: groups, buses, chains and the OSC interface used by the Lua side.
FxRack {
	classvar <server, <ready = false, building = false;
	classvar <group, <preTaps, <preSends, <insertGroup, <postTaps, <postSends;
	classvar <mainBus, <insert, <sends;
	classvar <>fade = 0.05;
	classvar queue;
	classvar <sendNames;

	*initClass {
		sendNames = [\a, \b];
		queue = List.new;
		sends = IdentityDictionary.new;
		StartUp.add {
			this.addOSC;
			ServerQuit.add({ this.reset }, \all);
			CmdPeriod.add({ this.reset });
		};
	}

	*sendArea { |which| ^if(which == \pre) { preSends } { postSends } }
	*tapArea { |which| ^if(which == \pre) { preTaps } { postTaps } }

	*units { ^FxUnit.all }

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
			this.sendDefs;
			server.sync;
			mainBus = Bus.new(\audio, 0, 2, server);
			group = if(context.notNil) {
				Group.after(context.og);
			} {
				Group.new(server.defaultGroup, \addToTail);
			};
			preTaps = Group.new(group, \addToTail);
			preSends = Group.new(group, \addToTail);
			insertGroup = Group.new(group, \addToTail);
			postTaps = Group.new(group, \addToTail);
			postSends = Group.new(group, \addToTail);
			insert = FxChain.new(\insert, mainBus, insertGroup, false);
			sendNames.do { |n|
				if(sends[n].isNil) { sends[n] = FxSend.new(n) };
				sends[n].build(server);
			};
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
		var unit = if(unitName.isNil or: { unitName == \none }) { nil } { FxUnit.all[unitName] };
		if(chain.isNil) { ("fx: no chain " ++ chainName).warn; ^this };
		if(unit.isNil and: { unitName.notNil } and: { unitName != \none }) {
			("fx: unknown unit " ++ unitName).warn;
			^this;
		};
		server.makeBundle(nil, { chain.place(index, unit) });
	}

	*clear {
		if(ready.not) { ^this };
		server.makeBundle(nil, {
			insert.clear;
			sends.do { |s| s.chain.clear };
		});
	}

	*addOSC {
		OSCFunc({ this.ensure }, '/fx/ensure');
		OSCFunc({ |msg|
			var chainName = msg[1].asSymbol, index = msg[2].asInteger, unitName = msg[3].asSymbol;
			this.do { this.place(chainName, index, unitName) };
		}, '/fx/slot');
		OSCFunc({ |msg|
			var unit = FxUnit.all[msg[1].asSymbol];
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
		OSCFunc({ this.do { this.clear } }, '/fx/clear');
		OSCFunc({ |msg| fade = msg[1].asFloat.max(0.005) }, '/fx/fade');
	}
}
