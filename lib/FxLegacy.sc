// v1 compatibility. Existing plugins subclass FxBase and call
// FxSetup.register(this.new) from *initClass; engines read FxSetup.sendA/B or
// ~sendA/~sendB. Both keep working on top of FxRack.

FxBase {
	// order matters: v1 plugins construct with super.newCopyArgs
	var <>syn, <>slot, <>params, <>replacer, <>drywet;

	addSynthdefs { }

	subPath { ^"???" }

	symbol { ^\fillIn }

	// v1 plugins were driven over per-plugin OSC paths; the rack does it now
	listenOSC { }
}

FxSetup {
	*register { |plugin|
		Class.initClassTree(FxUnit);
		FxUnit.registerLegacy(plugin);
		"fx: registered v1 plugin %\n".postf(plugin.class.name);
	}

	*sendA { ^FxRack.sends[\a] !? { |s| s.bus } }
	*sendB { ^FxRack.sends[\b] !? { |s| s.bus } }
	*insertGroup { ^FxRack.insertGroup }
	*fxGroup { ^FxRack.group }
}
