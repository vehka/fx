FxBase {
    var <syn;           // The effect synth
    var <slot;          // Current slot (insert, sendA, sendB)
    var <params;        // Effect parameters
    var <drywet = 1;    // Dry/wet mix for insert effects
    
    addSynthdefs {
        // Virtual. Override me.
    }
    
    subPath {
        ^"???";  // Virtual. Override me.
    }
    
    symbol {
        ^\fillIn;  // Virtual. Override me.
    }
    
    handleSlot { |newSlot|
        if(newSlot != slot, {
            this.cleanupCurrentSlot;
            this.setupNewSlot(newSlot);
            slot = newSlot;
        });
    }
    
    cleanupCurrentSlot {
        slot.notNil.if({
            switch(slot)
            {\insert} {
                FxSetup.removeEffect(this);
                "Removed from insert chain".postln;
            };
            
            syn.free;
            syn = nil;
        });
    }
    
    setupNewSlot { |newSlot|
        switch(newSlot)
        {\none} {
            "Set to none".postln;
        }
        {\sendA} {
            this.setupSendA;
        }
        {\sendB} {
            this.setupSendB;
        }
        {\insert} {
            this.setupInsert;
        };
    }
    
    setupSendA {
        if(~sendAGroup.notNil and: { ~sendA.notNil }, {
            syn = Synth.new(this.symbol, [
                \inBus, ~sendA,
                \outBus, Server.default.outputBus,
            ] ++ params.asPairs, target: ~sendAGroup);
            "Added to send A".postln;
        });
    }
    
    setupSendB {
        if(~sendBGroup.notNil and: { ~sendB.notNil }, {
            syn = Synth.new(this.symbol, [
                \inBus, ~sendB,
                \outBus, Server.default.outputBus,
            ] ++ params.asPairs, target: ~sendBGroup);
            "Added to send B".postln;
        });
    }
    
    setupInsert {
        if(FxSetup.insertGroup.notNil, {
            "Setting up insert effect %\n".postf(this.symbol);
            
            // Create the synth first
            syn = Synth.new(this.symbol, [
                \inBus, Server.default.outputBus,  // Initial routing, will be updated
                \outBus, FxSetup.wet,
            ] ++ params.asPairs, target: FxSetup.insertGroup, addAction: \addToTail);
            
            "Created synth % with ID %\n".postf(this.symbol, syn.nodeID);
            
            if(FxSetup.addEffect(this), {
                "Added to insert chain".postln;
                FxSetup.printChainState;
                
                // Print current node tree, for debugging
                //"Current node tree:".postln;
                //Server.default.queryAllNodes;
            }, {
                "Failed to add to insert chain".postln;
            });
        });
    }
    
    // Called by EffectChain to update routing
    updateRouting { |routing|
        if(syn.notNil, {
            syn.set(\inBus, routing.inBus, \outBus, routing.outBus);
            "Updated routing for %: in=%, out=%\n".postf(
                this.symbol,
                routing.inBus.index,
                routing.outBus.index
            );
        });
    }
    
    // Handle parameter updates
    updateParam { |key, value|
        params[key] = value;
        if(syn.notNil, {
            syn.set(key, value);
        });
        
        if(key == \drywet, {
            drywet = value;
            if(slot == \insert, {
                FxSetup.effectChain.updateReplacer(drywet);
            });
        });
    }
    
    // OSC handlers
    listenOSC {
        OSCFunc.new({ |msg, time, addr, recvPort|
            var newSlot = msg[1].asSymbol;
            "Considering slot % (current: %)\n".postf(newSlot, slot);
            this.handleSlot(newSlot);
        }, this.subPath ++ "/slot");
        
        OSCFunc.new({ |msg, time, addr, recvPort|
            var key = msg[1].asSymbol;
            var value = msg[2].asFloat;
            this.updateParam(key, value);
        }, this.subPath ++ "/set");
    }
    
    // Resource cleanup
    free {
        syn.free;
        syn = nil;
    }
}
