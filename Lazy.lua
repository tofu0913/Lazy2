require('chat')
require('logger')
require('tables')
config = require('config')
res = require('resources')
packets = require('packets')
require('coroutine')
require('mylibs/aggro')

_addon.name = 'lazy'
_addon.author = 'Cliff, Based version by Brax'
_addon.version = '0.5'
_addon.commands = {'lazy','lz'}

Start_Engine = false
isCasting = false
cleanAggro = false
killAggro = true
isBusy = 0
buffactive = {}
Action_Delay = 2

local running = false
local running_target = {}
local running_target_dist = 2
local usePull = false

buffactive = {}

defaults = {}
defaults.spell = ""
defaults.spell_active = false
defaults.weaponskill = ""
defaults.weaponskill_active = false
defaults.autotarget = false
defaults.target = ""

flag = false
settings = config.load(defaults)

function handle_mob_dead(id, data, modified, injected, blocked)

    if id == 0x29 then	-- Mob died
        local p = packets.parse('incoming',data)
        local target_id = p['Target'] --data:unpack('I',0x09)
        local player_id = p['Actor'] 
        local message_id = p['Message'] --data:unpack('H',0x19)%32768

        -- 6 == actor defeats target, 20 == target falls to the ground
        if message_id == 6 or message_id == 20 then
            -- killedMob = windower.ffxi.get_mob_by_id(target_id).name
            -- log('killed: '..killedMob..' by '..player_id)
            if settings.targetid then
                windower.send_command('input //sw reset; input //sw start; ')
            end
            if flag then
                windower.send_command('input //fsd c')
                flag = false
            end
        end
    end
end

windower.register_event('incoming chunk', function(id, data)
    handle_mob_dead(id, data)

    if id == 0x028 then
        local action_message = packets.parse('incoming', data)
		if action_message["Category"] == 4 then
			isCasting = false
		elseif action_message["Category"] == 8 then
			isCasting = true
			if action_message["Target 1 Action 1 Message"] == 0 then
				isCasting = false
				isBusy = Action_Delay
			end
		end
	end
end)

windower.register_event('outgoing chunk', function(id, data)
    if id == 0x015 then
        local action_message = packets.parse('outgoing', data)
		PlayerH = action_message["Rotation"]
	end
end)

function triggerStart()
    windower.add_to_chat(2,"....Starting Lazy Helper....")
    cleanAggro = false
    Start_Engine = true
    Engine()
end

function triggerStop()
    windower.add_to_chat(2,"....Stopping Lazy Helper....")
    cleanAggro = false
    Start_Engine = false
    usePull = false
    killAggro = true
    stop()
end

windower.register_event('addon command', function (...)
	local args	= T{...}:map(string.lower)
	if args[1] == nil or args[1] == "help" then
		print("Help Info")
    elseif S{'start','go','g'}:contains(args[1]) then
		triggerStart()
        
    elseif S{'stop','s'}:contains(args[1]) then
		triggerStop()
    
    elseif S{'trigger'}:contains(args[1]) then
        if Start_Engine then
            triggerStop()
        else
            triggerStart()
        end

	elseif args[1] == "reload" then
		windower.add_to_chat(2,"....Reloading Config....")
		config.reload(settings)
	elseif args[1] == "save" then
		config.save(settings,windower.ffxi.get_player().name)
	elseif args[1] == "test" then
		test()
	elseif args[1] == "clean" then
        cleanAggro = true
		-- windower.add_to_chat(2,"....Clean aggro....")
	elseif args[1] == "ignoreaggro" then
        killAggro = false
	elseif args[1] == "pull" then
        usePull = true
        windower.add_to_chat(2,"....Use RA to pull....")
	elseif args[1] == "show" then
		windower.add_to_chat(11,"Autotarget: "..tostring(settings.autotarget))
		windower.add_to_chat(11,"Spell: "..settings.spell)
		windower.add_to_chat(11,"Use Spell "..tostring(settings.spell_active))
		windower.add_to_chat(11,"Weaponskill: "..settings.weaponskill)
		windower.add_to_chat(11,"Use Weaponskill: "..tostring(settings.weaponskill_active))
		windower.add_to_chat(11,"Target:"..settings.target)
		windower.add_to_chat(11,"Is aggro:"..tostring(isAggrod()))
	elseif args[1] == "autotarget" then
		if args[2] == "on" then
			settings.autotarget = true
			windower.add_to_chat(3,"Autotarget: True")
		else
			settings.autotarget = false
			windower.add_to_chat(3,"Autotarget: False")
		end
	elseif args[1] == "target" then
		settings.target = args[2]
	end
end)

function HeadingTo(X,Y)
	local X = X - windower.ffxi.get_mob_by_id(windower.ffxi.get_player().id).x
	local Y = Y - windower.ffxi.get_mob_by_id(windower.ffxi.get_player().id).y
	local H = math.atan2(X,Y)
	return H - 1.5708
end

function TurnToTarget()
	local destX = windower.ffxi.get_mob_by_target('t').x
	local destY = windower.ffxi.get_mob_by_target('t').y
	local direction = math.abs(PlayerH - math.deg(HeadingTo(destX,destY)))
	if direction > 10 then
		windower.ffxi.turn(HeadingTo(destX,destY))
	end
end

function isMob(id)
    m = windower.ffxi.get_mob_by_id(id)
    if m and m['spawn_type']==16 and m['hpp'] >0 then
        return true
    end
    return false
end

local function isTargetID(val)
  for field in settings.targetid:gmatch('([^,]+)') do
    -- log(field..' vs '..val)
    if tostring(field) == tostring(val) then
        return true
    end
  end
  return false
end

--TODO, cant attack protect
function Find_Nearest_Target(setting)
    targets = string.lower(setting):split('%,')
	local id_targ = -1
	local dist_targ = -1
	local marray = windower.ffxi.get_mob_array()
	for key,mob in pairs(marray) do
        pl = windower.ffxi.get_mob_by_index(windower.ffxi.get_player().index or 0)
        if math.abs(mob['z'] - pl.z) < 5 and
         ((cleanAggro and isInAggro(mob.id)) or 
        (settings.targetid and isTargetID(string.format('%.3X',mob.index))) or 
        -- (settings.targetid and settings.targetid == string.format('%.3X',mob.index)) or 
		 (not cleanAggro and ((setting == '' and isMob(mob['id'])) or targets:contains(string.lower(mob["name"])) or (killAggro and isInAggro(mob.id)))))
            and mob["valid_target"] and mob["hpp"] >0 then
			if dist_targ == -1 then
				id_targ = key
				dist_targ = math.sqrt(mob["distance"])
			elseif math.sqrt(mob["distance"]) < dist_targ then
				id_targ = key
				dist_targ = math.sqrt(mob["distance"])
			end
		end
	end
    if usePull and dist_targ > 25 then
        return 0
    end
	return(id_targ)
end

function Check_Distance()
    target = windower.ffxi.get_mob_by_target('t')
	local distance = target.distance:sqrt()
	if distance > 3 and Start_Engine then
		TurnToTarget()
		windower.ffxi.run()
        running_target = target
        running = true
	-- else
		-- windower.ffxi.run(false)
	end
end

function test()
end

function Engine()
	if not Start_Engine then 
        stop()
        return 
    end
	Buffs = windower.ffxi.get_player()["buffs"]
    table.reassign(buffactive,convert_buff_list(Buffs))

	if isBusy < 1 then
		pcall(Combat)
	else
		isBusy = isBusy -1
	end
	if Start_Engine then
		coroutine.schedule(Engine,1)
	end
end

function setTarget(target, unlock)
    local player = windower.ffxi.get_player()

    packets.inject(packets.new('incoming', 0x058, {
        ['Player'] = player.id,
        ['Target'] = target.id,
        ['Player Index'] = player.index,
    }))
    if unlock then
        windower.send_command('wait 1; input /lockon')
    end
end

local targetLastChange = os.clock() - 2

function Combat()
	-- is Engaged / combat
	if windower.ffxi.get_player().status == 1 then
		TurnToTarget()
		Check_Distance()
		if windower.ffxi.get_player().vitals.tp >1000 and settings.weaponskill_active == true and windower.ffxi.get_mob_by_target('t').distance:sqrt() < 3.0 then
			windower.send_command(settings.weaponskill)
			isBusy = Action_Delay
		elseif Can_Cast_Spell(settings.spell) and settings.spell_active == true then
			Cast_Spell(settings.spell)
		end
	elseif settings.autotarget == true then
		local nearest_target = Find_Nearest_Target(settings.target)
		-- if nearest_target > 0 and Start_Engine then
		if nearest_target > 0 and Start_Engine and (os.clock()-targetLastChange>2) then
			-- windower.ffxi.follow(nearest_target)
            target = windower.ffxi.get_mob_by_index(nearest_target)
            setTarget(target, false)
            targetLastChange = os.clock()
            -- log(math.sqrt(target.distance))
            if usePull and math.sqrt(target.distance) > 7 and math.sqrt(target.distance) < 20 then
                -- log('Pull')
                TurnToTarget()
                windower.send_command("input //fsd s; wait 1; input /ra <t>")
                flag = true
            elseif math.sqrt(target.distance) <= 7 then
                -- log('Melee')
                -- windower.send_command("input /targetbnpc")
                -- windower.send_command("wait 1.5;input /attack on")
                windower.send_command("input /attack on")
            else
                -- log('Approach')
                running_target = target
                if usePull then
                    running_target_dist = 20
                else
                    running_target_dist = 2
                end
                running = true
            end
        elseif not Start_Engine then
            stop()
		end
	end
end

function Can_Cast_Spell(spell)
	local result = false
	local myspell = res.spells:with('name',spell)
	Recasts = windower.ffxi.get_spell_recasts()
	if (Recasts[myspell.id] == 0) and (not isCasting) and (windower.ffxi.get_player().vitals.mp >= myspell.mp_cost) and (isBusy == 0) then
		result = true
	end
	return result
end

function Can_Cast_Ability(ability)
	local result = false
	local myability = res.job_abilities:with('name',ability)
	Recasts = windower.ffxi.get_ability_recasts()
	print("Checking:"..myability.name)
	if (Recasts[myability.recast_id] == 0) and (not isCasting) and (isBusy == 0) then
		result = true
	end
	return result
end

function Cast_Spell(spell)
	Recasts = windower.ffxi.get_spell_recasts()
	local myspell = res.spells:with('name',spell)
	if Recasts[myspell.id] == 0 and not isCasting then
		windower.send_command(myspell.name)
		isBusy = Action_Delay
	end
end

function Cast_Ability(ability)
	Recasts = windower.ffxi.get_ability_recasts()
	local myability = res.job_abilities:with('name',ability)
	if Recasts[myability.recast_id] == 0 and not isCasting then
		windower.send_command(myability.name)
		isBusy = Action_Delay
	end
end


function convert_buff_list(bufflist)
    local buffarr = {}
    for i,v in pairs(bufflist) do
        if res.buffs[v] then -- For some reason we always have buff 255 active, which doesn't have an entry.
            local buff = res.buffs[v].english
            if buffarr[buff] then
                buffarr[buff] = buffarr[buff] +1
            else
                buffarr[buff] = 1
            end

            if buffarr[v] then
                buffarr[v] = buffarr[v] +1
            else
                buffarr[v] = 1
            end
        end
    end
    return buffarr
end

function stop()
    windower.ffxi.run(false)
    running = false
    running_target = {}
    -- windower.ffxi.follow()
    windower.send_command('setkey r;wait 0.1;setkey r up;wait 0.1;setkey r;wait 0.1;setkey r up')
end

windower.register_event('load', function()
    windower.send_command('bind @z input //lz trigger')
end)
windower.register_event('unload', function()
    stop()
    windower.send_command('unbind @z')
end)

function runtopos(x,y)
	local self_vector = windower.ffxi.get_mob_by_index(windower.ffxi.get_player().index or 0)
	local angle = (math.atan2((y - self_vector.y), (x - self_vector.x))*180/math.pi)*-1
	windower.ffxi.run((angle):radian())
end

windower.register_event('status change', function(new, old)
    if new == 2 then
        stop()
    end
end)

windower.register_event('prerender', function(...)
    -- Auto run
    if running then
        pl = windower.ffxi.get_mob_by_index(windower.ffxi.get_player().index or 0)
        if pl~=nil and next(running_target) ~= nil then
            local distance = math.sqrt(math.pow(pl.x-running_target.x,2) + math.pow(pl.y-running_target.y,2))
            -- debug(distance)
            if distance > running_target_dist then
                runtopos(running_target.x, running_target.y)
            else
                windower.ffxi.run(false)
                running = false
                -- running_callback()
            end
        end
    end
end)