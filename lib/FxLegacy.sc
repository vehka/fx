// v1 compatibility. Existing plugins subclass FxBase and call
// FxSetup.register(this.new) from *initClass; engines read FxSetup.sendA/B or
// ~sendA/~sendB. Both keep working on top of FxRack.

FxBase {
	// order matters: v1 plugins construct with super.newCopyArgs
	var <>syn, <>slot, <>params, <>replacer, <>drywet;

	addSynthdefs { }

	subPath { ^"???" }

	symbol { ^\fillIn }

	// Called once at startup. Placement is driven by the rack now, but some v1
	// plugins send params straight to their own <subPath>/set, and some
	// override this (calling super) to add handlers of their own.
	listenOSC {
		var name = this.subPath.asString;
		if(name.beginsWith("/")) { name = name.drop(1) };
		OSCFunc.new({ |msg|
			var unit = FxUnit.all[name.asSymbol];
			unit !? { unit.set(msg[1].asSymbol, msg[2].asFloat) };
		}, this.subPath ++ "/set");
	}
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
