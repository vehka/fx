FxSetup {
    classvar <sendA, <sendB, <insertInput, <preMix, <postMix, <fxGroup, <sendAGroup, <sendBGroup, <insertGroup;
    classvar <plugins, <initOnce;
    classvar <effectChain;  // Instance of EffectChain
    classvar <masterRouter;  // Master router synth splitting input to sendA and insertInput
    classvar <masterMixer;  // Master mixer synth combining sends and insert output
    
    *dynamicInit {
        if(fxGroup.isNil, {
            var server = Server.default;

            // Create groups
            fxGroup = Group.new(server, addAction: \addToTail);
            sendAGroup = Group.new(fxGroup, addAction: \addToHead);
            sendBGroup = Group.new(fxGroup, addAction: \addToHead);
            insertGroup = Group.new(fxGroup, addAction: \addToTail);

            // Create effect chain
            effectChain = EffectChain.new(server);

            // Create master router synth at the beginning to split input to sends and insert
            masterRouter = Synth.new(\masterRouter, [
                \in, server.outputBus,
                \sendA, sendA,
                \insertInput, insertInput,
            ], target: fxGroup, addAction: \addToHead);

            // Create master mixer synth after all other groups
            masterMixer = Synth.new(\masterMixer, [
                \preMix, preMix,
                \insertOut, effectChain.buses.wet,
                \postMix, postMix,
                \out, server.outputBus
            ], target: fxGroup, addAction: \addToTail);

            // Set environment variables
            ~sendAGroup = sendAGroup;
            ~sendBGroup = sendBGroup;
            ~insertGroup = insertGroup;
            ~insertInput = insertInput;
            ~preMix = preMix;
            ~postMix = postMix;
        });
    }
    
    *dynamicCleanup {
        effectChain.free;
        masterRouter.free;
        masterMixer.free;
        fxGroup.free;

        fxGroup = nil;
        sendAGroup = nil;
        sendBGroup = nil;
        insertGroup = nil;
        insertInput = nil;
        preMix = nil;
        postMix = nil;
        effectChain = nil;
        masterRouter = nil;
        masterMixer = nil;

        ~sendAGroup = sendAGroup;
        ~sendBGroup = sendBGroup;
        ~insertGroup = insertGroup;
        ~insertInput = insertInput;
        ~preMix = preMix;
        ~postMix = postMix;
    }
    
    *register { |plugin|
        "Registering plugin %\n".postf(plugin);
        plugins = plugins.add(plugin);
    }
    
    *initClass {
        initOnce = false;
        plugins = List[];

        StartUp.add {
            // Create send buses and mixing buses
            sendA = Bus.audio(Server.default, numChannels: 2);
            sendB = Bus.audio(Server.default, numChannels: 2);
            insertInput = Bus.audio(Server.default, numChannels: 2);
            preMix = Bus.audio(Server.default, numChannels: 2);
            postMix = Bus.audio(Server.default, numChannels: 2);

            // Create replacer SynthDef for insert chain dry/wet
            SynthDef(\replacer, {|in, out, drywet|
                XOut.ar(out, drywet, In.ar(in, 2));
            }).add;

            // Create master router SynthDef
            // Routes main input to both sendA bus and insertInput bus
            SynthDef(\masterRouter, {|in, sendA, insertInput|
                var sig = In.ar(in, 2);
                Out.ar(sendA, sig);
                Out.ar(insertInput, sig);
            }).add;

            // Create master mixer SynthDef
            // Combines: pre-insert sends (A) + insert output + post-insert sends (B)
            SynthDef(\masterMixer, {|preMix, insertOut, postMix, out|
                var preSignal = In.ar(preMix, 2);
                var insertSignal = In.ar(insertOut, 2);
                var postSignal = In.ar(postMix, 2);
                var mixed = preSignal + insertSignal + postSignal;
                Out.ar(out, mixed);
            }).add;
            
            // Set environment variables
            ~sendA = sendA;
            ~sendB = sendB;
            ~insertInput = insertInput;
            ~preMix = preMix;
            ~postMix = postMix;
            
            // Setup OSC handlers
            OSCFunc.new({ |msg, time, addr, recvPort|
                FxSetup.dynamicInit;
                "FX setup complete".postln;
            }, "/fxmod/init");
            
            OSCFunc.new({ |msg, time, addr, recvPort|
                FxSetup.dynamicCleanup;
                "FX cleanup complete".postln;
            }, "/fxmod/cleanup");
            
            // Initialize plugins
            if(initOnce.not, {
                initOnce = true;
                "Initializing plugins".postln;
                plugins.do { |p|
                    "Installing %\n".postf(p);
                    p.addSynthdefs;
                    p.listenOSC;
                };
            });
        };
    }
    
    // Effect chain management methods
    *addEffect { |effect|
        ^effectChain.add(effect);
    }
    
    *removeEffect { |effect|
        effectChain.remove(effect);
    }
    
    *updateEffectRouting {
        effectChain.updateRouting;
    }
    
    *printChainState {
        effectChain.printChain;
    }
    
    // Helper methods to access chain state
    *chainSize {
        ^effectChain.size;
    }
    
    *effectAt { |index|
        ^effectChain.at(index);
    }
    
    // Access buses through effect chain
    *wet { ^effectChain.buses.wet }
    *chain1 { ^effectChain.buses.chain1 }
    *chain2 { ^effectChain.buses.chain2 }
    *chain3 { ^effectChain.buses.chain3 }
}