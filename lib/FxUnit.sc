// One effect type. Owns its parameter state and at most one running node.
//
// Native units supply DSP only:
//
//   FxUnit.register(\mydelay, { |in, time = 0.3, fb = 0.4| ... wet }, (tail: 4));
//
// The framework wraps the function with the chain I/O, mix, fades and tail
// handling (see docs/DESIGN.md). Wrapper controls are prefixed fx_.
//
// With specs the unit needs no Lua: the rack makes a param of every control
// that has one.
//
//   FxUnit.register(\mydelay, { |in, time = 0.3, fb = 0.4| ... },
//       (tail: 4, title: "My Delay", specs: (time: [0.01, 2, \exp, 0, 0.3, "s"], fb: [0, 0.95])));
//
// Inside the function FxRack.key, .env, .mod(n), .tempo and .beat give the
// sidechain signal, its envelope, the modulation buses and the clock.
//
// A second instance of a unit is a copy under the name <name>_2 (_3, ...): it
// shares the SynthDef and has its own values and node. Copies are made when
// first asked for, see *find.
FxUnit {
	classvar <all;

	var <name, <func, <opts, <plugin;
	var <base;   // the unit this is a copy of, or nil
	var <params;
	var <mix = 1, <bypass = 0, <tail = 0;
	var <node, <chain, <index;
	var gen = 0;

	*initClass {
		all = all ?? { IdentityDictionary.new };
	}

	// opts: tail (seconds the wet output rings after release), lag (default
	// control lag), lags (Event of per-control lag or rate overrides), title,
	// specs (Event of control name -> ControlSpec or anything asSpec takes),
	// instances (how many copies the rack offers; the user can change it).
	*register { |name, func, opts|
		var unit = super.new.init(name.asSymbol, func, opts ?? { () }, nil);
		all = all ?? { IdentityDictionary.new };
		all[unit.name] = unit;
		if(FxRack.ready) { unit.sendDef(FxRack.server) };
		FxRack.unitsChanged;
		^unit;
	}

	// The unit of that name. An unknown <name>_<n> whose <name> is a native
	// unit becomes a copy of it.
	*find { |name|
		var unit, str, cut, source;
		name = name.asSymbol;
		unit = all[name];
		if(unit.notNil) { ^unit };
		str = name.asString;
		cut = str.findBackwards("_");
		if(cut.isNil or: { cut < 1 }) { ^nil };
		if(str.drop(cut + 1).every(_.isDecDigit).not or: { cut + 1 >= str.size }) { ^nil };
		source = all[str.keep(cut).asSymbol];
		if(source.isNil or: { source.isLegacy } or: { source.base.notNil }) { ^nil };
		unit = super.new.init(name, source.func, source.opts, nil);
		unit.setBase(source);
		all[name] = unit;
		^unit;
	}

	setBase { |unit| base = unit }

	// v1 plugin: an FxBase subclass instance with its own inBus/outBus SynthDef
	*registerLegacy { |plugin|
		var name = plugin.subPath.asString;
		var unit;
		if(name.beginsWith("/")) { name = name.drop(1) };
		unit = super.new.init(name.asSymbol, nil, (), plugin);
		all = all ?? { IdentityDictionary.new };
		all[unit.name] = unit;
		^unit;
	}

	init { |argName, argFunc, argOpts, argPlugin|
		name = argName;
		func = argFunc;
		opts = argOpts;
		plugin = argPlugin;
		tail = opts[\tail] ? 0;
		params = IdentityDictionary.new;
		if(plugin.notNil and: { plugin.params.notNil }) {
			plugin.params.keysValuesDo { |k, v| params[k] = v };
		};
	}

	isLegacy { ^plugin.notNil }

	defName { ^("fxu_" ++ (base ? this).name).asSymbol }

	argNames { ^if(func.isNil) { [] } { func.def.argNames.drop(1) } }

	// control name -> ControlSpec, for the controls that have one: from opts,
	// or a global spec of the same name. The default is the function's.
	specs {
		var given = opts[\specs] ?? { () };
		var defaults = func.def.prototypeFrame;
		var out = IdentityDictionary.new;
		this.argNames.do { |n, i|
			var spec = (given[n] ? n).asSpec;
			if(spec.notNil) {
				spec = spec.copy;
				defaults[i + 1] !? { |d| if(d.isNumber) { spec.default = d } };
				out[n] = spec;
			};
		};
		^out;
	}

	// The unit as a Lua table, for the Lua side to build params from.
	describe {
		var specs = this.specs;
		var quote = { |x| "\"" ++ x.asString.replace("\\", "\\\\").replace("\"", "\\\"") ++ "\"" };
		var warp = { |spec|
			case
			{ spec.warp.isKindOf(ExponentialWarp) } { "exp" }
			{ spec.warp.isKindOf(DbFaderWarp) } { "db" }
			{ "lin" };
		};
		var list = this.argNames.select { |n| specs[n].notNil }.collect { |n|
			var spec = specs[n];
			"{ id = %, min = %, max = %, warp = %, step = %, default = %, units = % }".format(
				quote.(n), spec.minval, spec.maxval, quote.(warp.(spec)), spec.step,
				spec.default, quote.(spec.units ? ""));
		};
		^"{ name = %, title = %, instances = %, params = { % } }".format(
			quote.(name), quote.(opts[\title] ? name), (opts[\instances] ? 1).asInteger,
			list.join(", "));
	}

	// Every native unit, as a Lua file. Returns whether it could be written.
	*writeUnits { |path|
		var units = all.values.select { |u| u.isLegacy.not and: { u.base.isNil } };
		var file;
		units = units.sort { |a, b| a.name <= b.name };
		File.mkdir(path.dirname);
		file = File(path, "w");
		if(file.isOpen.not) { ("fx: cannot write " ++ path).warn; ^false };
		file.write("-- written by FxUnit when sclang starts; do not edit\nreturn {\n");
		units.do { |u| file.write("  " ++ u.describe ++ ",\n") };
		file.write("}\n");
		file.close;
		^true;
	}

	// shared output stage: returns [inputAmount, outputSignalFunc]
	*gates { |gate, bypass, fade, tail, doneAction|
		var on = EnvGen.kr(Env.asr(fade, 1, fade, \sine), gate);
		var life = EnvGen.kr(
			Env.new([0, 1, 1, 0], [fade, tail, fade], \sine, 1),
			gate, doneAction: doneAction
		);
		var act = Lag.kr(1 - bypass, fade);
		^[on * act, life];
	}

	*guard { |sig|
		^sig.asArray.collect { |ch|
			Select.ar(CheckBadValues.ar(ch, 0, 0) > 0, [ch, DC.ar(0)]);
		};
	}

	*stereo { |sig|
		sig = sig.asArray;
		^if(sig.size == 1) { [sig[0], sig[0]] } { sig.keep(2) };
	}

	buildDef {
		var argNames = func.def.argNames.drop(1);
		var defaultLag = opts[\lag] ? 0.05;
		var lagOverrides = opts[\lags] ?? { () };
		var lags = argNames.collect { |n| lagOverrides[n] ? defaultLag };
		^SynthDef(this.defName, { |fx_bus, fx_gate = 1, fx_mix = 1, fx_bypass = 0,
			fx_fade = 0.05, fx_tail = 0|
			var dry = In.ar(fx_bus, 2);
			var amt, life, wet, m;
			#amt, life = FxUnit.gates(fx_gate, fx_bypass, fx_fade, fx_tail, 2);
			wet = SynthDef.wrap(func, lags, [dry * amt]);
			wet = FxUnit.guard(FxUnit.stereo(wet));
			m = Lag.kr(fx_mix, 0.05);
			ReplaceOut.ar(fx_bus, (dry * (1 - (m * amt))) + (wet * m * life));
		}, metadata: (specs: this.specs));
	}

	sendDef { |server|
		if(this.isLegacy) {
			plugin.addSynthdefs;
		} {
			// a copy runs its base's def
			if(base.isNil) { this.buildDef.send(server) };
		};
	}

	effectiveMix {
		^if(chain.notNil and: { chain.isSend }) { 1 } { mix };
	}

	// Start a node for this unit. Call inside a server bundle.
	start { |argChain, argIndex, target, addAction|
		var server = FxRack.server;
		var wrapperArgs, busArgs;
		chain = argChain;
		index = argIndex;
		gen = gen + 1;
		wrapperArgs = [
			\fx_bus, chain.bus,
			\fx_gate, 1,
			\fx_mix, this.effectiveMix,
			\fx_bypass, bypass,
			\fx_fade, FxRack.fade,
			\fx_tail, tail
		];
		// the shared buses, for units that read them; see FxRack.key
		busArgs = [\fx_key, FxRack.keyBus.index, \fx_ctl, FxRack.ctlBus.index];
		if(this.isLegacy) {
			var inBus = Bus.audio(server, 2);
			var wetBus = Bus.audio(server, 2);
			var g = Group.new(target, addAction);
			Synth.new(\fxLegacyPre, wrapperArgs ++ [\fx_in, inBus], g, \addToTail);
			plugin.syn = Synth.new(plugin.symbol,
				[\inBus, inBus, \outBus, wetBus] ++ params.asPairs, g, \addToTail);
			Synth.new(\fxLegacyPost, wrapperArgs ++ [\fx_wet, wetBus], g, \addToTail);
			g.onFree { inBus.free; wetBus.free };
			node = g;
		} {
			node = Synth.new(this.defName, wrapperArgs ++ busArgs ++ params.asPairs, target, addAction);
		};
		if(bypass > 0) { this.schedulePause };
		^node;
	}

	// Fade out and let the node free itself after its tail. Bundle-safe.
	release {
		if(node.notNil) {
			node.run(true);
			node.set(\fx_gate, 0);
			node = nil;
		};
		if(this.isLegacy) { plugin.syn = nil };
		gen = gen + 1;
		chain = nil;
		index = nil;
	}

	// The node was freed externally (server reboot, tree reset).
	forget {
		node = nil;
		chain = nil;
		index = nil;
		gen = gen + 1;
		if(this.isLegacy) { plugin.syn = nil };
	}

	set { |key, value|
		switch(key,
			\mix, { this.setMix(value) },
			\drywet, {
				this.setMix(value);
				// some v1 SynthDefs have a drywet control of their own
				if(this.isLegacy) {
					params[\drywet] = value;
					if(node.notNil) { node.set(\drywet, value) };
				};
			},
			\bypass, { this.setBypass(value) },
			\tail, { tail = value; if(node.notNil) { node.set(\fx_tail, tail) } },
			{
				params[key] = value;
				if(node.notNil) { node.set(key, value) };
			}
		);
	}

	setMix { |value|
		mix = value;
		if(this.isLegacy) { plugin.drywet = value };
		if(node.notNil) { node.set(\fx_mix, this.effectiveMix) };
	}

	setBypass { |value|
		bypass = if(value > 0) { 1 } { 0 };
		if(node.notNil) {
			gen = gen + 1;
			if(bypass > 0) {
				node.set(\fx_bypass, 1);
				this.schedulePause;
			} {
				FxRack.server.makeBundle(nil, {
					node.run(true);
					node.set(\fx_bypass, 0);
				});
			};
		};
	}

	// pause a bypassed node once its tail has decayed, to save CPU
	schedulePause {
		var myGen = gen;
		var myNode = node;
		SystemClock.sched((FxRack.fade * 2) + tail + 0.2, {
			if((gen == myGen) and: { node === myNode } and: { bypass > 0 }) {
				myNode.run(false);
			};
			nil;
		});
	}
}
