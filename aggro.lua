res = require('resources')

tracked_actions = {}
tracked_enmity = {}
tracked_debuff = {}
framerate = 75
clean_actions_delay = framerate
clean_actions_tick = clean_actions_delay

wears_off_message_ids = S{204,206}
tracked_message_ids = S{8,4,7,11,3,6,9,5}
starting_message_ids = S{8,7,9}
completed_message_ids = S{4,11,3,5,6}
spell_message_ids = S{8,4}
item_message_ids = S{5,9}
weapon_skill_message_ids = S{3,7,11}
tracked_debuff_ids = S{2,19,7,28}
untracked_debuff_categories = S{8,7,6,9}
damaging_spell_message_ids = S{2,252}
non_damaging_spell_message_ids = S{75,236,237,268,270,271}

function handle_action_packet(id, data)
    if 0x028 == id then
        local ai = windower.packets.parse_action(data)

        track_enmity(ai)
        track_actions(ai)
        track_debuffs(ai)
    elseif 0x029 then
        local message_id = data:unpack('H',0x19)
        if not message_id then return end
        message_id = message_id%0x8000
        local param_1 = data:unpack('I',0x0D)
        local target_id = data:unpack('I',0x09)
        if wears_off_message_ids:contains(message_id) then
            -- wears off message.
            if tracked_debuff[target_id]  then
                tracked_debuff[target_id][param_1] = nil
            end
        end
    end
end

function track_enmity(ai)
    local actor_id = ai.actor_id

    for i,t in ipairs(ai.targets) do
        local target_id = t.id

        local pc = nil
        local mob = nil
        if is_party_member_or_pet(actor_id) then
            pc = actor_id
        elseif is_npc(actor_id) then
        	mob = actor_id
        end
        if is_party_member_or_pet(target_id) then
            pc = target_id
        elseif is_npc(target_id) then
        	mob = target_id
        end

        if pc and mob then
            -- we have npc/pc interaction
            -- if the actor is the npc, then we know there's enmity. Otherwise, if the target of the pc spell isn't tracked, it definitely hates the pc now.
            if actor_id == mob or not tracked_enmity[mob] then
                tracked_enmity[mob] = {pc=pc, mob=mob, time=os.time()}

                -- if the actor is the npc, we don't care about the other targets. The first target is the one they targeted.
                if actor_id == mob then return end
            end
        end
    end
end

function track_actions(ai)
    local actor_id = ai.actor_id

    -- if the category is not casting magic, jas, items or ws, don't bother.
    if not tracked_message_ids:contains(ai.category) then return end

    -- if it's a starting packet, the id is in param2
    local action_id = ai.param
    if starting_message_ids:contains(ai.category) then
        action_id = ai.targets[1].actions[1].param
    end
    if action_id == 0 then return end
    -- find the action
    local action_map = nil
    if spell_message_ids:contains(ai.category) then
        action_map = res.spells[action_id]
    elseif item_message_ids:contains(ai.category) then
        action_map = res.items[action_id]
    elseif is_npc(actor_id) then
        action_map = res.monster_abilities[action_id]
    elseif ai.category == 6 then
        action_map = res.job_abilities[action_id]
    elseif weapon_skill_message_ids:contains(ai.category) then
        action_map = res.weapon_skills[action_id]
    end
    -- couldn't find the action, let's just give some debug output.
    if not action_map then
        action_map = {en='Unknown (id:'..action_id..')'}
    end 

    if ai.targets[1].actions[1].message == 0 and ai.targets[1].id == ai.actor_id then
        -- cast was interrupted
        tracked_actions[ai.actor_id] = nil;
    else
        tracked_actions[ai.actor_id] = {actor_id=actor_id, target_id=ai.targets[1].id, ability=action_map, complete=completed_message_ids:contains(ai.category), time=os.time()}
    end
end

function track_debuffs(ai)
    check_conflicting_debuffs(ai)
    if untracked_debuff_categories:contains(ai.category) then return end

    for i,t in ipairs(ai.targets) do
        local target_id =t.id
        if is_npc(target_id) then

            if damaging_spell_message_ids:contains(t.actions[1].message) then
                local spell = ai.param
                local effect = res.spells[spell].status

                if effect then
                    apply_debuff(target_id, effect, spell)
                end
                
            -- Non-damaging spells
            elseif non_damaging_spell_message_ids:contains(t.actions[1].message) then
                local effect = t.actions[1].param
                local spell = ai.param

                apply_debuff(target_id, effect, spell)
            end
        end
    end
end

function apply_debuff(target_id, effect, spell)  
    local overwrites = res.spells[spell].overwrites or {}
    if not did_overwrite(target_id, spell, overwrites) then
        return
    end 

    local target = windower.ffxi.get_mob_by_id(target_id)
    if not target then return end 

    if not tracked_debuff[target_id] then
        tracked_debuff[target_id] = {}
    end

    tracked_debuff[target_id][effect] = {target_id=target_id,spell=spell,effect=effect,time=os.time(),duration=res.spells[spell].duration or 0,pos={x=target.x,y=target.y}}
end

function did_overwrite(target_id, new, t)
    if not tracked_debuff[target_id] then return true end
    
    for effect, tracked in pairs(tracked_debuff[target_id]) do
        local old = res.spells[tracked.spell].overwrites or {}
        
        -- Check if there isn't a higher priority debuff active
        for _,v in ipairs(old) do
            if new == v then
                return false
            end
        end
        
        -- Check if a lower priority debuff is being overwritten
        for _,v in ipairs(t) do
            if tracked.spell == v then
                tracked_debuff[target_id][effect] = nil
            end
        end
    end
    return true
end

function check_conflicting_debuffs(ai)
    local actor_id = ai.actor_id

    if is_npc(actor_id) then
        -- the actor is an npc, let's check if they're supposed to be asleep/petrified/terror'd
        local debuffs = tracked_debuff[actor_id]
        if not debuffs then return end

        local actor = windower.ffxi.get_mob_by_id(actor_id)
        if not actor then 
        	-- mob's gone, remove tracking
			tracked_debuff[actor_id] = {}
        	return
        end

        for id,debuff in pairs(debuffs) do
            if tracked_debuff_ids:contains(id) then
                -- it was inactive, but now it's doing!
                tracked_debuff[actor_id][id] = nil
            end

            if math.abs(debuff.pos.x-actor.x)>0.5 or math.abs(debuff.pos.y-actor.y)>0.5 then
                -- it was locked in place, but now it's not!
                tracked_debuff[actor_id][id] = nil
            end
        end
    end
end

function looking_at(a, b)
    if not a or not b then return false end
    local h = a.facing % math.pi
    local h2 = (math.atan2(a.x-b.x,a.y-b.y) + math.pi/2) % math.pi
    return math.abs(h-h2) < 0.15
end

function is_party_member_or_pet(mob_id)
    if mob_id == windower.ffxi.get_player().id then return true, 1 end

    if is_npc(mob_id) then return false end

    if party_members[mob_id] == nil then return false end

    return party_members[mob_id], party_members[mob_id].party
end

function get_distance(player, target)
    local dx = player.x-target.x
    local dy = player.y-target.y
    return math.sqrt(dx*dx + dy*dy)
end
function is_npc(mob_id)
    local is_pc = mob_id < 0x01000000
    local is_pet = mob_id > 0x01000000 and mob_id % 0x1000 > 0x700

    -- filter out pcs and known pet IDs
    if is_pc or is_pet then return false end

    -- check if the mob is charmed
    local mob = windower.ffxi.get_mob_by_id(mob_id)
    if not mob then return nil end
    return mob.is_npc and not mob.charmed
end
    party_members = {}

packets = require('packets')

function handle_party_packets(id, data)
    if id == 0x0DD then
        -- cache party 
        cache_party_members:schedule(1)
    elseif id == 0x067 then
        local p =  packets.parse('incoming', data)
        if p['Owner Index'] > 0 then
            local owner = windower.ffxi.get_mob_by_index(p['Owner Index'])
            if owner and is_party_member_or_pet(owner.id) then
                party_members[p['Pet ID']] = {is_pet = true, owner = owner.id}
            end
        end
    end
end

function cache_party_members()
    party_members = {}
    local party = windower.ffxi.get_party()
    if not party then return end
    for i=0, (party.party1_count or 0) - 1 do
        cache_party_member(party['p'..i], 1)            
    end
    for i=0, (party.party2_count or 0) - 1 do
        cache_party_member(party['a1'..i], 2)            
    end
    for i=0, (party.party3_count or 0) - 1 do
        cache_party_member(party['a2'..i], 3)            
    end
end

function handle_track_packet(id, data)
    handle_action_packet(id, data)
    handle_party_packets(id, data)
end

function clean_tracked_actions()
    clean_actions_tick = clean_actions_tick - 1

    if clean_actions_tick > 0 then return end

    local player = windower.ffxi.get_mob_by_target("me")
    local time = os.time()
    for id,action in pairs(tracked_actions) do
        -- for incomplete items, timeout at 30s.
        if not action.complete and time - action.time > 30 then
            tracked_actions[id] = nil

        -- for complete actions, timeout at 3s.
        elseif action.complete and time - action.time > 3 then
            tracked_actions[id] = nil
        end
    end

    for id,enmity in pairs(tracked_enmity) do
        if time - enmity.time > 3 then
            local mob = windower.ffxi.get_mob_by_id(enmity.mob)
            if not mob or mob.hpp == 0 then
                tracked_enmity[id] = nil
            elseif mob.status == 0 then
                tracked_enmity[id] = nil
            elseif enmity.pc and not looking_at(mob, windower.ffxi.get_mob_by_id(enmity.pc)) then
                tracked_enmity[id].pc = nil
            elseif get_distance(player, mob) > 50 then
                tracked_enmity[id] = nil
            end
        end
    end

    for id,debuffs in pairs(tracked_debuff) do
        local mob = windower.ffxi.get_mob_by_id(id)
        if not mob or mob.hpp == 0 then
            tracked_debuff[id] = nil
        else
            for i,debuff in ipairs(debuffs) do
                -- if the duration is much longer than +50%, let's assume it wore. 
                if time - debuff.time > debuff.duration * 1.5 then 
                    tracked_debuff[id][debuff.effect] = nil
                end
            end
        end
    end

    clean_actions_tick = clean_actions_delay
end

function reset_tracked_actions()
    tracked_actions = {}
    tracked_enmity = {}
    tracked_debuff = {}
end

function isAggrod()
    local count = 0
    for _ in pairs(tracked_enmity) do count = count + 1 end
    return count ~= 0
end

function isInAggro(id)
    if tracked_enmity[id] then
        return true
    end
    return false
end