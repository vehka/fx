// v1-style plugin used by the click test
FxTestLegacy : FxBase {
	*new {
		^super.newCopyArgs(nil, \none, (drive: 4), nil, 1);
	}

	*initClass {
		FxSetup.register(this.new);
	}

	subPath { ^"/fx_test_legacy" }

	symbol { ^\fxTestLegacy }

	addSynthdefs {
		SynthDef(\fxTestLegacy, { |inBus, outBus, drive = 4|
			Out.ar(outBus, (In.ar(inBus, 2) * drive).tanh);
		}).add;
	}
}
