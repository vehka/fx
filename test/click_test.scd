// Feeds a sine through the rack, performs graph changes, records the output
// and fails on any sample-to-sample step larger than a smooth signal can make.
//
//   test/run_sc.sh
(
var threshold = 0.1;
var seconds = 20;
var failures = List.new;
var check = { |label, cond| if(cond.not) { failures.add(label) }; ("  " ++ if(cond) { "ok   " } { "FAIL " } ++ label).postln };
var maxStep = { |data, from, to|
	var m = 0;
	var a = (from * 48000 * 2).asInteger.max(2), b = (to * 48000 * 2).asInteger.min(data.size - 1);
	(a..b).do { |i| var d = (data[i] - data[i - 2]).abs; if(d > m) { m = d } };
	m;
};
var rms = { |data, from, to|
	var a = (from * 48000 * 2).asInteger, b = (to * 48000 * 2).asInteger.min(data.size - 1);
	var sum = 0;
	(a..b).do { |i| sum = sum + data[i].squared };
	(sum / (b - a + 1)).sqrt;
};

var peak = { |data, from, to|
	var a = (from * 48000 * 2).asInteger, b = (to * 48000 * 2).asInteger.min(data.size - 1);
	var m = 0;
	(a..b).do { |i| var v = data[i].abs; if(v.isNaN or: { v > m }) { m = v } };
	m;
};

"SC_JACK_DEFAULT_INPUTS".setenv("");
"SC_JACK_DEFAULT_OUTPUTS".setenv("");
Server.program = "exec pw-jack scsynth";
Server.default.options.sampleRate = 48000;

FxUnit.register(\drive, { |in, drive = 4| (in * drive).tanh });
FxUnit.register(\echo, { |in, time = 0.11, fb = 0.5|
	var local = LocalIn.ar(2) + in;
	LocalOut.ar(DelayN.ar(local, 1, time) * fb);
	local;
}, (tail: 1.5));
FxUnit.register(\mono, { |in| in[0] * 0.5 });
FxUnit.register(\soft, { |in| in * 0.5 });
FxUnit.register(\unity, { |in| in });

fork { try {
	var s = Server.default, buf, src, inSrc, rec, data, t0, at, mark = 0, marks = ();
	var step = { |name, dur, f| marks[name] = mark; f.value; dur.wait; mark = mark + dur };
	s.bootSync;
	FxRack.ensure;
	while { FxRack.ready.not } { 0.1.wait };
	buf = Buffer.alloc(s, 48000 * seconds, 2);
	// sine on a DC offset: an abrupt dry/wet switch then steps at every phase
	SynthDef(\testSrc, { |out, gate = 1|
		var env = EnvGen.kr(Env.asr(0.02, 1, 0.02, \sine), gate, doneAction: 2);
		Out.ar(out, (SinOsc.ar(220, 0, 0.2) + 0.3) * env ! 2);
	}).send(s);
	// what v1 did: an effect appearing with no fade
	SynthDef(\testHard, { ReplaceOut.ar(0, (In.ar(0, 2) * 4).tanh) }).send(s);
	SynthDef(\testRec, { |in, buf| RecordBuf.ar(In.ar(in, 2), buf, loop: 0, doneAction: 2) }).send(s);
	s.sync;
	s.makeBundle(nil, {
		src = Synth(\testSrc, [\out, 0], s.defaultGroup, \addToHead);
		rec = Synth(\testRec, [\in, 0, \buf, buf], s.defaultGroup, \addToTail);
	});

	step.(\dry, 0.5, { });
	step.(\place, 0.5, { FxRack.place(\insert, 1, \drive) });
	step.(\swap, 0.5, { FxRack.place(\insert, 1, \echo) });
	step.(\add, 0.5, { FxRack.place(\insert, 2, \drive) });
	step.(\reorder, 0.5, { FxRack.place(\insert, 1, \drive); FxRack.place(\insert, 2, \echo) });
	step.(\param, 0.5, { FxUnit.all[\drive].set(\drive, 1); FxUnit.all[\drive].set(\mix, 0.5) });
	step.(\bypass, 0.7, { FxUnit.all[\drive].set(\bypass, 1) });
	step.(\unbypass, 0.5, { FxUnit.all[\drive].set(\bypass, 0) });
	step.(\legacy, 0.5, { FxRack.place(\insert, 3, \fx_test_legacy) });
	step.(\mono, 0.5, { FxRack.place(\insert, 4, \mono) });
	step.(\sendOn, 0.5, {
		FxRack.place(\a, 1, \fx_test_legacy);
		FxRack.sends[\a].set(\level, 0.5);
	});
	step.(\sendRoute, 0.5, { FxRack.sends[\a].set(\dest, 0) });
	// post tap with a pre return is a feedback loop through the inserts
	step.(\feedback, 0.6, { FxRack.sends[\a].set(\tap, 1) });
	// and so is a -> b -> a
	step.(\cross, 0.6, {
		FxRack.place(\b, 1, \soft);
		FxRack.sends[\a].setCross(\b, 0.5);
		FxRack.sends[\b].setCross(\a, 0.5);
	});
	// stop the source too, so only the tails are left
	step.(\clear, 3.0, {
		FxRack.clear;
		src.set(\gate, 0);
		FxRack.sends[\a].setCross(\b, 0);
		FxRack.sends[\b].setCross(\a, 0);
		FxRack.sends[\a].set(\level, 0);
	});
	marks[\end] = mark;
	// audio input as a source
	step.(\input, 0.5, {
		inSrc = Synth(\testSrc, [\out, FxRack.inBuses[0]], s.defaultGroup, \addToHead);
		FxRack.setInput(\level, 1);
	});
	step.(\inputOff, 0.4, { FxRack.setInput(\level, 0); inSrc.set(\gate, 0) });
	// a unity-gain loop keeps ringing after the source stops
	step.(\fbOn, 0.5, {
		src = Synth(\testSrc, [\out, 0], s.defaultGroup, \addToHead);
		FxRack.place(\a, 1, \unity);
		FxRack.sends[\a].set(\tap, 1);
		FxRack.sends[\a].set(\dest, 0);
		FxRack.sends[\a].set(\level, 1);
	});
	step.(\fbRing, 0.6, { src.set(\gate, 0) });
	// a loop with gain 4 must stay bounded
	step.(\fbHot, 0.8, {
		src = Synth(\testSrc, [\out, 0], s.defaultGroup, \addToHead);
		FxUnit.all[\drive].set(\drive, 4);
		FxUnit.all[\drive].set(\mix, 1);
		FxRack.place(\a, 1, \drive);
	});
	step.(\fbOff, 1.0, { FxRack.clear; FxRack.sends[\a].set(\level, 0); src.set(\gate, 0) });
	marks[\fbEnd] = mark;
	// a deliberately abrupt change, to prove the detector sees clicks
	step.(\resume, 0.4, { src = Synth(\testSrc, [\out, 0], s.defaultGroup, \addToHead) });
	step.(\hardCut, 0.4, { Synth(\testHard, target: FxRack.insertGroup) });
	marks[\stop] = mark;
	0.3.wait;

	buf.loadToFloatArray(action: { |d| data = d });
	while { data.isNil } { 0.1.wait };

	"\nfx click test".postln;
	check.("signal present (dry rms %)".format(rms.(data, 0.1, 0.4).round(0.001)), rms.(data, 0.1, 0.4) > 0.15);
	check.("no click across all rack operations (max step %)".format(maxStep.(data, 0.05, marks[\end]).round(0.0001)),
		maxStep.(data, 0.05, marks[\end]) < threshold);
	check.("drive is audible while placed",
		rms.(data, marks[\place] + 0.3, marks[\place] + 0.45) > (rms.(data, 0.1, 0.4) * 1.5));
	check.("echo tail still ringing 0.3 s after clear (rms %)".format(rms.(data, marks[\clear] + 0.3, marks[\clear] + 0.5).round(0.0001)),
		rms.(data, marks[\clear] + 0.3, marks[\clear] + 0.5) > 0.005);
	check.("silent once the tails are over (rms %)".format(rms.(data, marks[\end] - 0.4, marks[\end] - 0.1).round(0.00001)),
		rms.(data, marks[\end] - 0.4, marks[\end] - 0.1) < 0.0005);
	check.("no nodes left in the insert chain", FxRack.insert.isEmpty);
	check.("audio input reaches the output (rms %)".format(rms.(data, marks[\input] + 0.2, marks[\input] + 0.45).round(0.001)),
		rms.(data, marks[\input] + 0.2, marks[\input] + 0.45) > 0.15);
	check.("and is silent at level 0", rms.(data, marks[\fbOn] - 0.15, marks[\fbOn] - 0.02) < 0.0005);
	check.("a post tap with a pre return feeds back (rms % after the source stopped)".format(rms.(data, marks[\fbRing] + 0.3, marks[\fbRing] + 0.55).round(0.0001)),
		rms.(data, marks[\fbRing] + 0.3, marks[\fbRing] + 0.55) > 0.02);
	check.("a feedback loop with gain above 1 stays bounded (peak %)".format(peak.(data, marks[\fbHot], marks[\fbEnd]).round(0.001)),
		peak.(data, marks[\fbHot], marks[\fbEnd]) < 2.5);
	check.("and stops when the rack is cleared (rms %)".format(rms.(data, marks[\fbEnd] - 0.3, marks[\fbEnd] - 0.05).round(0.00001)),
		rms.(data, marks[\fbEnd] - 0.3, marks[\fbEnd] - 0.05) < 0.0005);
	check.("detector sees a hard cut (max step %)".format(maxStep.(data, marks[\hardCut] - 0.05, marks[\stop]).round(0.0001)),
		maxStep.(data, marks[\hardCut] - 0.05, marks[\stop]) > threshold);

	if(failures.isEmpty) { "PASS".postln } { ("FAILED: " ++ failures.size).postln };
	s.quit;
	0.5.wait;
	(if(failures.isEmpty) { 0 } { 1 }).exit;
} { |err| err.reportError; Server.default.quit; 1.exit } };
)
