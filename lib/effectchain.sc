EffectChain {
    var <effects;  // List of effects in the chain
    var <buses;    // Audio buses used for routing
    var <>replacer; // The replacer synth for wet/dry mixing
    
    *new { |server|
        ^super.new.init(server);
    }
    
    init { |server|
        effects = List.new;
        buses = (
            wet: Bus.audio(server, numChannels: 2),
            chain1: Bus.audio(server, numChannels: 2),
            chain2: Bus.audio(server, numChannels: 2),
            chain3: Bus.audio(server, numChannels: 2)
        );
    }
    
    // Add an effect to the chain
    add { |effect|
        if(effects.size >= 4, {
            "Cannot add more than 4 effects to chain".error;
            ^false;
        });
        
        "Adding effect to chain (current size: %)\n".postf(effects.size);
        effects.add(effect);
        
        // Create replacer if this is the first effect
        if(effects.size == 1 and: { replacer.isNil }, {
            "Creating replacer synth".postln;
            replacer = Synth.new(\replacer, [
                \in, buses.wet,
                \out, Server.default.outputBus,
                \drywet, 1
            ], target: effect.syn, addAction: \addAfter);
            "Created replacer with ID %\n".postf(replacer.nodeID);
        });
        
        this.updateRouting;
        ^true;
    }
    
    // Remove an effect from the chain
    remove { |effect|
        "Removing effect from chain. Before: % effects\n".postf(effects.size);
        effects.remove(effect);
        "After removal: % effects\n".postf(effects.size);
        
        // If chain is now empty, free the replacer
        if(effects.isEmpty, {
            "Chain empty, freeing replacer".postln;
            replacer.free;
            replacer = nil;
        }, {
            // Otherwise update routing for remaining effects
            "Updating routing for remaining effects".postln;
            this.updateRouting;
        });
    }
    
    // Calculate routing for a specific position in the chain
    calculateRouting { |position|
        var routing = ();
        
        routing.inBus = switch(position)
        { 0 } { Server.default.outputBus }
        { 1 } { buses.chain1 }
        { 2 } { buses.chain2 }
        { 3 } { buses.chain3 };
        
        routing.outBus = if(position == (effects.size - 1), {
            buses.wet // Last effect always outputs to wet bus
        }, {
            switch(position)
            { 0 } { buses.chain1 }
            { 1 } { buses.chain2 }
            { 2 } { buses.chain3 }
        });
        
        ^routing;
    }
    
    // Update routing for all effects in the chain
    updateRouting {
        "Updating routing for % effects\n".postf(effects.size);
        effects.do { |effect, i|
            var routing = this.calculateRouting(i);
            "Effect % routing: in=%, out=%\n".postf(
                i + 1,
                routing.inBus.index,
                routing.outBus.index
            );
            effect.updateRouting(routing);
        };
        
        // Update replacer position if it exists
        if(replacer.notNil and: { effects.notEmpty }, {
            "Moving replacer after last effect".postln;
            replacer.moveAfter(effects.last.syn);
        });
    }
    
    // Create or update replacer synth
    updateReplacer { |drywet = 1|
        if(effects.isEmpty, {
            replacer.free;
            replacer = nil;
            ^this;
        });
        
        if(replacer.isNil, {
            replacer = Synth.new(\replacer, [
                \in, buses.wet,
                \out, Server.default.outputBus,
                \drywet, drywet
            ], addAction: \addToTail);
        }, {
            replacer.set(\drywet, drywet);
            replacer.moveAfter(effects.last.syn);
        });
    }
    
    // Free all resources
    free {
        effects.do(_.free);
        effects.clear;
        buses.do(_.free);
        replacer.free;
    }
    
    // Get size of chain
    size {
        ^effects.size;
    }
    
    // Access specific effect by index
    at { |index|
        ^effects[index];
    }
    
    // Print current chain state
    printChain {
        "Effect Chain State:".postln;
        if(effects.isEmpty, {
            "  Chain is empty".postln;
            ^this;
        });
        
        effects.do { |effect, i|
            var routing = this.calculateRouting(i);
            "  Effect %: % (in: %, out: %)\n".postf(
                i + 1,
                effect.symbol,
                routing.inBus.index,
                routing.outBus.index
            );
        };
    }
}