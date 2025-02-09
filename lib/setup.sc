FxSetup {
    classvar <sendA, <sendB, <fxGroup, <sendAGroup, <sendBGroup, <insertGroup;
    classvar <plugins, <initOnce;
    classvar <effectChain;  // Instance of EffectChain
    
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
            
            // Set environment variables
            ~sendAGroup = sendAGroup;
            ~sendBGroup = sendBGroup;
            ~insertGroup = insertGroup;
        });
    }
    
    *dynamicCleanup {
        effectChain.free;
        fxGroup.free;
        
        fxGroup = nil;
        sendAGroup = nil;
        sendBGroup = nil;
        insertGroup = nil;
        effectChain = nil;
        
        ~sendAGroup = sendAGroup;
        ~sendBGroup = sendBGroup;
        ~insertGroup = insertGroup;
    }
    
    *register { |plugin|
        "Registering plugin %\n".postf(plugin);
        plugins = plugins.add(plugin);
    }
    
    *initClass {
        initOnce = false;
        plugins = List[];
        
        StartUp.add {
            // Create send buses
            sendA = Bus.audio(Server.default, numChannels: 2);
            sendB = Bus.audio(Server.default, numChannels: 2);
            
            // Create replacer SynthDef
            SynthDef(\replacer, {|in, out, drywet|
                XOut.ar(out, drywet, In.ar(in, 2));
            }).add;
            
            // Set environment variables
            ~sendA = sendA;
            ~sendB = sendB;
            
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