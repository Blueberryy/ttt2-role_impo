if SERVER then
	AddCSLuaFile()
	resource.AddFile("materials/vgui/ttt/dynamic/roles/icon_impo.vmt")
	util.AddNetworkString("TTT2ImpostorInformEveryone")
	util.AddNetworkString("TTT2ImpostorDefaultSaboMode")
	util.AddNetworkString("TTT2ImpostorInstantKillUpdate")
	util.AddNetworkString("TTT2ImpostorSendInstantKillRequest")
	util.AddNetworkString("TTT2ImpostorSendSabotageRequest")
	util.AddNetworkString("TTT2ImpostorSabotageLightsScreenFade")
	util.AddNetworkString("TTT2ImpostorSabotageLightsRedownloadMap")
	util.AddNetworkString("TTT2ImpostorSendSabotageResponse")
end

function ROLE:PreInitialize()
	--Color of a Red Impostor
	self.color = Color(197, 17, 17, 255)
	self.abbr = "impo" -- abbreviation
	
	--Score vars
	self.surviveBonus = 0.5 -- bonus multiplier for every survive while another player was killed
	self.scoreKillsMultiplier = 5 -- multiplier for kill of player of another team
	self.scoreTeamKillsMultiplier = -16 -- multiplier for teamkill
	
	--Prevent the Impostor from gaining credits normally.
	self.preventFindCredits = true
	self.preventKillCredits = true
	self.preventTraitorAloneCredits = true
	
	self.defaultEquipment = SPECIAL_EQUIPMENT -- here you can set up your own default equipment
	self.defaultTeam = TEAM_TRAITOR
	
	self.conVarData = {
		pct = 0.17, -- necessary: percentage of getting this role selected (per player)
		maximum = 1, -- maximum amount of roles in a round
		minPlayers = 6, -- minimum amount of players until this role is able to get selected
		togglable = true, -- option to toggle a role for a client if possible (F1 menu)
		random = 30,
		traitorButton = 1, -- can use traitor buttons
		
		--Impostor can't access shop, and has no credits.
		credits = 0,
		creditsTraitorKill = 0,
		creditsTraitorDead = 0,
		shopFallback = SHOP_DISABLED
	}
end

function ROLE:Initialize()
	roles.SetBaseRole(self, ROLE_TRAITOR)
end

--CREATES "TEAM_LOSER". THEY'RE SOLE PURPOSE IS TO LOSE. EVERYONE LOSES.
roles.InitCustomTeam("loser", {
	icon = "vgui/ttt/dynamic/roles/icon_inno",
	color = Color(0, 0, 0, 255)
})

--------------------------------------------
--SHARED CONSTS, GLOBALS, FUNCS, AND HOOKS--
--------------------------------------------
--Used to reduce chances of lag interrupting otherwise seemless player interactions.
IMPO_IOTA = 0.3
--Sabotage enum
SABO_MODE = {NONE = 0, MNGR = 1, LIGHTS = 2, COMMS = 3, O2 = 4, REACT = 5, NUM = 6}
SABO_MODE_ABBR = {"None", "Mngr", "Lights", "Comms", "O2", "React", "Num"}
SABO_LIGHTS_MODE = {SCREEN_FADE = 0, DISABLE_MAP = 1}
SABO_REACT_MODE = {EVERYONE_LOSES = 0, TEAM_WIN = 1}

local function IsInSpecDM(ply)
	if SpecDM and (ply.IsGhost and ply:IsGhost()) then
		return true
	end
	
	return false
end

local function CanKillTarget(impo, tgt, dist)
	--impo is assumed to be a valid impostor and tgt is assumed to be a valid player
	--True if the Impostor can instantly kill in general
	local can_instant_kill = impo.impo_can_insta_kill and dist <= GetConVar("ttt2_impostor_kill_dist"):GetInt() and impo.impo_in_vent == nil and not IsInSpecDM(impo)
	
	--Handle friendly fire and disguised roles
	local can_kill_target = impo:GetTeam() ~= tgt:GetTeam()
	if SPY and tgt:GetSubRole() == ROLE_SPY then
		--Edge case: Prevent the Spy from being instant killable to prevent the traitors from having an easy solution.
		can_kill_target = false
	end
	
	return can_instant_kill and can_kill_target
end

local function SabotageStationManagerIsEnabled()
	return GetConVar("ttt2_impostor_station_enable"):GetBool() and GetConVar("ttt2_impostor_station_manager_enable"):GetBool()
end

local function SabotageLightsIsEnabled()
	local sabo_lights_mode = GetConVar("ttt2_impostor_sabo_lights_mode"):GetInt()
	local fade_trans_len = GetConVar("ttt2_impostor_sabo_lights_fade_trans_length"):GetFloat()
	local fade_dark_len = GetConVar("ttt2_impostor_sabo_lights_fade_dark_length"):GetFloat()
	local sabo_lights_len = GetConVar("ttt2_impostor_sabo_lights_length"):GetInt()
	
	if (sabo_lights_mode == SABO_LIGHTS_MODE.SCREEN_FADE and (fade_trans_len <= 0.0 or fade_dark_len < 0.0)) or sabo_lights_len <= 0 then
		return false
	end
	
	return true
end

local function SabotageCommsIsEnabled()
	local sabo_comms_len = GetConVar("ttt2_impostor_sabo_comms_length"):GetInt()
	
	if sabo_comms_len <= 0 then
		return false
	end
	
	return true
end

local function SabotageO2IsEnabled()
	local sabo_o2_len = GetConVar("ttt2_impostor_sabo_o2_length"):GetInt()
	
	if sabo_o2_len <= 0 then
		return false
	end
	
	return true
end

local function SabotageReactorIsEnabled()
	local sabo_react_len = GetConVar("ttt2_impostor_sabo_react_length"):GetInt()
	
	if not GetConVar("ttt2_impostor_station_enable"):GetBool() or sabo_react_len <= 0 then
		return false
	end
	
	return true
end

local function SabotageModeIsValid(sabo_mode)
	if sabo_mode == SABO_MODE.MNGR then
		return SabotageStationManagerIsEnabled()
	elseif sabo_mode == SABO_MODE.LIGHTS then
		return SabotageLightsIsEnabled()
	elseif sabo_mode == SABO_MODE.COMMS then
		return SabotageCommsIsEnabled()
	elseif sabo_mode == SABO_MODE.O2 then
		return SabotageO2IsEnabled()
	elseif sabo_mode == SABO_MODE.REACT then
		return SabotageReactorIsEnabled()
	end
	
	return false
end

local function ActsLikeTraitorButNotImpostor(ply)
	--Only handle Dop!Traitor (who explicitly isn't an Impostor) for now.
	--Handling Spy scenario would lead to them being able to vent and not be affected by sabos. Historically they only look like a traitor, they don't have special traitor abilities.
	--Handling Defective scenario would lead to them being unable to vent and being affected by sabos. Probably not worth it.
	local team = ply:GetTeam()
	if DOPPELGANGER and team == TEAM_DOPPELGANGER and GetConVar("ttt2_impostor_dopt_special_handling"):GetBool() then
		local role_data = roles.GetByIndex(ply:GetSubRole())
		if role_data.defaultTeam == TEAM_TRAITOR then
			team = TEAM_TRAITOR
		end
	end
	
	return team == TEAM_TRAITOR and ply:GetSubRole() ~= ROLE_IMPOSTOR
end

local function CanHaveLightsSabotaged(ply)
	if ply:GetSubRole() == ROLE_IMPOSTOR or (ActsLikeTraitorButNotImpostor(ply) and not GetConVar("ttt2_impostor_traitor_team_is_affected_by_sabo_lights"):GetBool()) or IsInSpecDM(ply) then
		return false
	end
	
	return true
end

local function CanHaveCommsSabotaged(ply)
	if ply:GetSubRole() == ROLE_IMPOSTOR or (ActsLikeTraitorButNotImpostor(ply) and not GetConVar("ttt2_impostor_traitor_team_is_affected_by_sabo_comms"):GetBool()) or IsInSpecDM(ply) then
		return false
	end
	
	return true
end

local function CanHaveO2Sabotaged(ply)
	if not ply:Alive() or (ply:GetSubRole() == ROLE_IMPOSTOR and not GetConVar("ttt2_impostor_is_affected_by_sabo_o2"):GetBool()) or (ActsLikeTraitorButNotImpostor(ply) and not GetConVar("ttt2_impostor_traitor_team_is_affected_by_sabo_o2"):GetBool()) or IsInSpecDM(ply) then
		return false
	end
	
	return true
end

local function InduceScreenFade(ply)
	local fade_trans_time = GetConVar("ttt2_impostor_sabo_lights_fade_trans_length"):GetFloat()
	--Sabotage ply's lights by performing two screen fades.
	local fade_dark_time = GetConVar("ttt2_impostor_sabo_lights_fade_dark_length"):GetFloat()
	local total_fade_time = 2*fade_trans_time + fade_dark_time
	
	if CanHaveLightsSabotaged(ply) then
		--SCREENFADE.IN: Cut to black immediately. After fade_hold, transition out over fade_trans_time.
		--SCREENFADE.OUT: Fade to black over fade_trans_time. After fade_hold, cut back to normal immediately.
		--SCREENFADE.MODULATE: Cut to black immediately. Cut back to normal some time after. Not sure how fade_trans_time factors in here.
		--SCREENFADE.STAYOUT: Cut to black immediately. Never returns to normal. Why is this a thing?
		--SCREENFADE.PURGE: Not sure how this differs from SCREENFADE.MODULATE.
		
		--Create temporary lights-out effect: fade to black, hold, then fade to normal.
		--Add IMPO_IOTA in first ScreenFade call to handle lag between the two calls and create a hopefully seemless blackout effect.
		ply:ScreenFade(SCREENFADE.OUT, COLOR_BLACK, fade_trans_time, (fade_dark_time/2) + IMPO_IOTA)
		timer.Simple(fade_trans_time + (fade_dark_time/2), function()
			--Have to create a lambda function() here. ply:ScreenFade by itself doesn't pass compile.
			ply:ScreenFade(SCREENFADE.IN, COLOR_BLACK, fade_trans_time, fade_dark_time/2)
		end)
	end
	
	if SERVER then
		--Send request to client to call this same function, just to keep things in sync.
		net.Start("TTT2ImpostorSabotageLightsScreenFade")
		net.Send(ply)
		
		local fade_bright_time = GetConVar("ttt2_impostor_sabo_lights_fade_bright_length"):GetInt()
		local time_left = GetConVar("ttt2_impostor_sabo_lights_length"):GetInt()
		if timer.Exists("ImpostorSaboLightsTimer_Server") then
			time_left = timer.TimeLeft("ImpostorSaboLightsTimer_Server")
		end
		
		--Induce further screen fades, until the sabotage is cleared.
		if time_left >= 2*total_fade_time + fade_bright_time - IMPO_IOTA then
			timer.Simple(total_fade_time + fade_bright_time, function()
				--Peform another check on the timer here in case the sabotage is cleared early.
				if timer.Exists("ImpostorSaboLightsTimer_Server") then
					InduceScreenFade(ply)
				end
			end)
		end
	end
	
	if CLIENT and ply:GetSubRole() == ROLE_IMPOSTOR then
		--Create timer just to keep track of this for UI purposes.
		--Only create this for impostor because we have enough timers already.
		--Only edge case missed is when someone becomes an impostor during a dark interval, the HUD will still be bright.
		timer.Create("ImpostorScreenFade_Client", total_fade_time, 1, function()
			return
		end)
	end
end

if SERVER then
	--Used for Sabotage Reactor TEAM_WIN
	local impo_team_win = nil
	
	local function SendInstantKillUpdateToClient(ply)
		net.Start("TTT2ImpostorInstantKillUpdate")
		net.WriteBool(ply.impo_can_insta_kill)
		net.Send(ply)
	end
	
	local function PutInstantKillOnCooldown(ply)
		local kill_cooldown = GetConVar("ttt2_impostor_kill_cooldown"):GetInt()
		
		--Handle case where admin wants impostor to be overpowered trash.
		if kill_cooldown <= 0 then
			ply.impo_can_insta_kill = true
			SendInstantKillUpdateToClient(ply)
			return
		end
		
		--Turn off ability to kill
		ply.impo_can_insta_kill = false
		SendInstantKillUpdateToClient(ply)
		
		--Create a timer that is unique to the player. When it finishes, turn on ability to kill.
		timer.Create("ImpostorKillTimer_Server_" .. ply:SteamID64(), kill_cooldown, 1, function()
			--Verify the player's existence, in case they are dropped from the Server.
			if IsValid(ply) and ply:IsPlayer() then
				ply.impo_can_insta_kill = true
				SendInstantKillUpdateToClient(ply)
			end
		end)
	end
	
	local function SendDefaultSaboMode(ply)
		local mode = SABO_MODE.NONE
		
		if SabotageStationManagerIsEnabled() then
			mode = SABO_MODE.MNGR
		elseif SabotageLightsIsEnabled() then
			mode = SABO_MODE.LIGHTS
		elseif SabotageCommsIsEnabled() then
			mode = SABO_MODE.COMMS
		elseif SabotageO2IsEnabled() then
			mode = SABO_MODE.O2
		elseif SabotageReactorIsEnabled() then
			mode = SABO_MODE.REACT
		end
		
		net.Start("TTT2ImpostorDefaultSaboMode")
		net.WriteInt(mode, 16)
		net.Send(ply)
	end
	
	net.Receive("TTT2ImpostorSendInstantKillRequest", function(len, ply)
		if not IsValid(ply) or not ply:IsPlayer() or not ply:IsTerror() or ply:GetSubRole() ~= ROLE_IMPOSTOR then
			return
		end
		
		--Determine if the impostor is looking at someone who isn't on their team
		local trace = ply:GetEyeTrace(MASK_SHOT_HULL)
		local dist = trace.StartPos:Distance(trace.HitPos)
		local tgt = trace.Entity
		if not IsValid(tgt) or not tgt:IsPlayer() then
			return
		end
		
		--If the impostor is able to, instantly kill the target and reset the cooldown.
		if CanKillTarget(ply, tgt, dist) then
			tgt:Kill()
			--Create a timer which will aid in preventing the Impostor from searching the corpse that they just made.
			timer.Create("ImpostorJustKilled_Server_" .. ply:SteamID64(), IMPO_IOTA*2, 1, function()
				return
			end)
			PutInstantKillOnCooldown(ply)
		end
	end)
	
	local function SendSabotageResponse(ply, sabo_mode, sabo_len)
		net.Start("TTT2ImpostorSendSabotageResponse")
		net.WriteInt(sabo_mode, 16)
		net.WriteInt(sabo_len, 16)
		net.Send(ply)
	end
	
	local function SabotageLights()
		local sabo_lights_mode = GetConVar("ttt2_impostor_sabo_lights_mode"):GetInt()
		local sabo_duration = GetConVar("ttt2_impostor_sabo_lights_length"):GetInt()
		local sabo_cooldown = GetConVar("ttt2_impostor_sabo_lights_cooldown"):GetInt()
		
		if sabo_lights_mode == SABO_LIGHTS_MODE.DISABLE_MAP then
			engine.LightStyle(0, "a")
		end
		
		for _, ply in ipairs(player.GetAll()) do
			SendSabotageResponse(ply, SABO_MODE.LIGHTS, sabo_duration)
			
			if sabo_lights_mode == SABO_LIGHTS_MODE.SCREEN_FADE then
				InduceScreenFade(ply, ply:GetSubRole() == ROLE_IMPOSTOR)
			elseif sabo_lights_mode == SABO_LIGHTS_MODE.DISABLE_MAP and CanHaveLightsSabotaged(ply) then
				net.Start("TTT2ImpostorSabotageLightsRedownloadMap")
				net.Send(ply)
				--Keep track of who had their map disabled, in case a role changes during sabo.
				ply.impo_tmp_light_map_disabled = true
			end
		end
		
		timer.Create("ImpostorSaboLightsTimer_Server", sabo_duration, 1, function()
			IMPO_SABO_DATA.DestroyStation()
			IMPO_SABO_DATA.PutSabotageOnCooldown(sabo_cooldown)
			
			if sabo_lights_mode == SABO_LIGHTS_MODE.DISABLE_MAP then
				engine.LightStyle(0, "m")
				for _, ply in ipairs(player.GetAll()) do
					if ply.impo_tmp_light_map_disabled then
						net.Start("TTT2ImpostorSabotageLightsRedownloadMap")
						net.Send(ply)
						ply.impo_tmp_light_map_disabled = nil
					end
				end
			end
		end)
	end
	
	local function SabotageComms()
		local sabo_duration = GetConVar("ttt2_impostor_sabo_comms_length"):GetInt()
		local sabo_cooldown = GetConVar("ttt2_impostor_sabo_comms_cooldown"):GetInt()
		
		for _, ply in ipairs(player.GetAll()) do
			SendSabotageResponse(ply, SABO_MODE.COMMS, sabo_duration)
		end
		
		if GetConVar("ttt2_impostor_sabo_comms_deafen"):GetBool() then
			hook.Add("Think", "ImpostorSaboComms_Deafen", function()
				for _, ply in ipairs(player.GetAll()) do
					if CanHaveCommsSabotaged(ply) then
						ply:ConCommand("soundfade 100 1")
					end
				end
			end)
		end
		
		--Create a timer that'll be used to explicitly silence those affected.
		timer.Create("ImpostorSaboCommsTimer_Server", sabo_duration, 1, function()
			--If hook doesn't exist, hook.Remove will not throw errors, and instead silently pass.
			hook.Remove("Think", "ImpostorSaboComms_Deafen")
			IMPO_SABO_DATA.DestroyStation()
			IMPO_SABO_DATA.PutSabotageOnCooldown(sabo_cooldown)
		end)
	end
	
	local function SabotageO2_DamageOverTime(hits_left, sabo_duration, grace_period, interval, hp_loss, stop_thresh)
		--Calculate damage before creating a timer, as we do not know when the sabotage ends, and deducting HP loss at the tail end may lead to non-uniform HP loss across all players on the final tick.
		if hits_left <= sabo_duration - grace_period and (((sabo_duration - grace_period) - hits_left) % interval) == 0 then
			local dmg_info = DamageInfo()
			dmg_info:SetDamageType(DMG_DROWN)
			for _, ply in ipairs(player.GetAll()) do
				if ply:Alive() and CanHaveO2Sabotaged(ply) and ply:Health() > stop_thresh then
					--Attacker must be specified, or TTT2 starts complaining.
					dmg_info:SetAttacker(IMPO_SABO_DATA.ACTIVE_STAT_ENT or ply)
					dmg_info:SetDamage(math.min(hp_loss, ply:Health() - stop_thresh))
					ply:TakeDamageInfo(dmg_info)
				end
			end
		end
		
		timer.Simple(1, function()
			--Check for "> 1" instead of "> 0" as we already deduct an HP at the start.
			if hits_left > 1 and timer.Exists("ImpostorSaboO2Timer_Server") then
				SabotageO2_DamageOverTime(hits_left - 1, sabo_duration, grace_period, interval, hp_loss, stop_thresh)
			end
		end)
	end
	
	local function SabotageO2()
		local sabo_duration = GetConVar("ttt2_impostor_sabo_o2_length"):GetInt()
		local sabo_cooldown = GetConVar("ttt2_impostor_sabo_o2_cooldown"):GetInt()
		
		for _, ply in ipairs(player.GetAll()) do
			SendSabotageResponse(ply, SABO_MODE.O2, sabo_duration)
		end
		
		timer.Create("ImpostorSaboO2Timer_Server", sabo_duration, 1, function()
			IMPO_SABO_DATA.DestroyStation()
			IMPO_SABO_DATA.PutSabotageOnCooldown(sabo_cooldown)
		end)
		
		SabotageO2_DamageOverTime(sabo_duration, sabo_duration, GetConVar("ttt2_impostor_sabo_o2_grace_period"):GetInt(), GetConVar("ttt2_impostor_sabo_o2_interval"):GetInt(), GetConVar("ttt2_impostor_sabo_o2_hp_loss"):GetInt(), GetConVar("ttt2_impostor_sabo_o2_stop_thresh"):GetInt())
	end
	
	hook.Add("TTTCheckForWin", "ImpostorCheckForWin", function()
		if impo_team_win ~= nil then
			return impo_team_win
		end
	end)
	
	local function SabotageReactor(team)
		local sabo_react_mode = GetConVar("ttt2_impostor_sabo_react_win_mode"):GetInt()
		local sabo_duration = GetConVar("ttt2_impostor_sabo_react_length"):GetInt()
		local sabo_cooldown = GetConVar("ttt2_impostor_sabo_react_cooldown"):GetInt()
		
		for _, ply in ipairs(player.GetAll()) do
			SendSabotageResponse(ply, SABO_MODE.REACT, sabo_duration)
		end
		
		timer.Create("ImpostorSaboReactTimer_Server", sabo_duration, 1, function()
			if GetRoundState() == ROUND_ACTIVE then
				if sabo_react_mode == SABO_REACT_MODE.EVERYONE_LOSES then
					impo_team_win = TEAM_LOSER
				else --SABO_REACT_MODE.TEAM_WIN
					impo_team_win = team
				end
				
				IMPO_SABO_DATA.SetStrangeGame()
			end
		end)
	end
	
	net.Receive("TTT2ImpostorSendSabotageRequest", function(len, ply)
		local sabo_mode = net.ReadInt(16)
		local selected_station = net.ReadInt(16)
		local station_enabled = GetConVar("ttt2_impostor_station_enable"):GetBool()
		
		if not IsValid(ply) or not ply:IsPlayer() or not ply:IsTerror() or ply:GetSubRole() ~= ROLE_IMPOSTOR or not SabotageModeIsValid(sabo_mode) or GetRoundState() ~= ROUND_ACTIVE or IMPO_SABO_DATA.STRANGE_GAME then
			return
		end
		
		if sabo_mode == SABO_MODE.MNGR then
			IMPO_SABO_DATA.MaybeAddNewStationSpawn(ply)
		elseif not IMPO_SABO_DATA.ON_COOLDOWN then
			if station_enabled and GetConVar("ttt2_impostor_dissuade_station_reuse"):GetBool() and IMPO_SABO_DATA.StationHasBeenUsed(selected_station) then
				--Do not sabotage if the Impostor is trying to reuse a station.
				LANG.Msg(ply, "SABO_CANNOT_REUSE_" .. IMPOSTOR.name, nil, MSG_MSTACK_WARN)
				return
			end
			
			if station_enabled and not IMPO_SABO_DATA.CreateStation(ply, selected_station) then
				--Station could not be made. 
				--Return early so that we don't cause a sabotage that players can't force end.
				return
			end
			
			--Prevent button spamming tricks by immediately disabling sabo.
			IMPO_SABO_DATA.ON_COOLDOWN = true
			
			if sabo_mode == SABO_MODE.LIGHTS then
				SabotageLights()
			elseif sabo_mode == SABO_MODE.COMMS then
				SabotageComms()
			elseif sabo_mode == SABO_MODE.O2 then
				SabotageO2()
			elseif sabo_mode == SABO_MODE.REACT then
				SabotageReactor(ply:GetTeam())
			end
		end
	end)
	
	function ROLE:GiveRoleLoadout(ply, isRoleChange)
		ply:GiveEquipmentWeapon('weapon_ttt_vent')
		PutInstantKillOnCooldown(ply)
		SendDefaultSaboMode(ply)
		if #IMPO_SABO_DATA.STATION_NETWORK > 0 then
			IMPO_SABO_DATA.SendStationNetwork(ply)
		end
	end
	
	function ROLE:RemoveRoleLoadout(ply, isRoleChange)
		ply:StripWeapon('weapon_ttt_vent')
	end
	
	hook.Add("EntityTakeDamage", "ImpostorModifyDamage", function(target, dmg_info)
		local attacker = dmg_info:GetAttacker()
		
		if IsValid(attacker) and attacker:IsPlayer() then
			if attacker.impo_in_vent then
				--Force everyone to deal no damage if they are in a vent (just to be safe)
				dmg_info:SetDamage(0)
			elseif attacker:GetSubRole() == ROLE_IMPOSTOR and not IsInSpecDM(attacker) then
				--Impostor deals less damage.
				dmg_info:SetDamage(dmg_info:GetDamage() * GetConVar("ttt2_impostor_normal_dmg_multi"):GetFloat())
			end
		end
	end)
	
	hook.Add("TTT2PostPlayerDeath", "ImpostorPostPlayerDeath", function(victim, inflictor, attacker)
		--Force any dead player who is venting out of the Vent Network in case they revive.
		if IsValid(victim) and victim:IsPlayer() and IsValid(victim.impo_in_vent) then
			IMPO_VENT_DATA.ForceExitFromVent(victim)
		end
	end)
	
	hook.Add("TTTCanSearchCorpse", "ImpostorCanSearchCorpse", function(ply, corpse, isCovert, isLongRange)
		--Lessens chance of Impostor accidentally searching the corpse of a player that they just killed.
		if IsValid(ply) and ply:IsPlayer() and timer.Exists("ImpostorJustKilled_Server_" .. ply:SteamID64()) then
			return false
		end
	end)
	
	hook.Add("TTT2CanUseVoiceChat", "ImpostorCanUseVoiceChatForServer", function(speaker, isTeamVoice)
		if timer.Exists("ImpostorSaboCommsTimer_Server") and (not isTeamVoice or CanHaveCommsSabotaged(speaker)) and not speaker:IsSpec() then
			return false
		end
	end)
	
	hook.Add("TTTPlayerRadioCommand", "ImpostorPlayerRadioCommand", function(ply, msg_name, msg_target)
		if timer.Exists("ImpostorSaboCommsTimer_Server") then
			return true
		end
	end)
	
	hook.Add("TTT2AvoidGeneralChat", "ImpostorAvoidGeneralChat", function(sender, text)
		--Prevents player from sending messages to general chat.
		if timer.Exists("ImpostorSaboCommsTimer_Server") then
			LANG.Msg(sender, "SABO_COMMS_START_" .. IMPOSTOR.name, nil, MSG_MSTACK_WARN)
			return false
		end
	end)
	
	hook.Add("TTT2AvoidTeamChat", "ImpostorAvoidTeamChat", function(sender, tm, msg)
		if timer.Exists("ImpostorSaboCommsTimer_Server") and (tm == TEAM_INNOCENT or tm == TEAM_NONE or (IsValid(sender) and CanHaveCommsSabotaged(sender))) then
			--Jam everyone but traitors while Sabotage Comms is in effect.
			LANG.Msg(sender, "SABO_COMMS_START_" .. IMPOSTOR.name, nil, MSG_MSTACK_WARN)
			return false
		end
	end)
	
	hook.Add("TTTBeginRound", "ImpostorBeginRoundServer", function()
		impo_team_win = nil
		IMPO_SABO_DATA.SendSabotageUpdateToClients(0)
		
		if GetConVar("ttt2_impostor_inform_everyone"):GetBool() then
			local num_impos = 0
			
			for _, ply in ipairs(player.GetAll()) do
				if ply:GetSubRole() == ROLE_IMPOSTOR then
					num_impos = num_impos + 1
				end
			end
			
			if num_impos > 0 then
				net.Start("TTT2ImpostorInformEveryone")
				net.WriteInt(num_impos, 16)
				net.Broadcast()
			end
		end
		
		--Reset data for everyone in case someone becomes an impostor/traitor/trapper/etc.
		for _, ply in ipairs(player.GetAll()) do
			ply.impo_in_vent = nil
			ply.impo_trapper_timer_expired = nil
		end
	end)
end

if CLIENT then
	--Client consts
	local NUMBERS_STR_ARR = {"ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE", "TEN"}
	local IMPO_BUTTON_SIZE = 64
	local IMPO_BUTTON_MIDPOINT = IMPO_BUTTON_SIZE / 2
	local IMPO_SELECTED_BUTTON_SIZE = 80
	local IMPO_SELECTED_BUTTON_MIDPOINT = IMPO_SELECTED_BUTTON_SIZE / 2
	local ICON_IN_VENT = Material("vgui/ttt/icon_vent")
	local ICON_STATION = Material("vgui/ttt/dynamic/roles/icon_impo")
	
	local function SelectedSaboModeInRange(ply)
		if not ply.impo_sabo_mode or ply.impo_sabo_mode <= SABO_MODE.NONE or ply.impo_sabo_mode >= SABO_MODE.NUM then
			--All forms of sabotage have been disabled, or the ply is very confused.
			return false
		end
		
		return true
	end
	
	hook.Add("TTTPrepareRound", "ImpostorPrepareRoundClient", function()
		local client = LocalPlayer()
		
		client.impo_in_vent = nil
		client.impo_selected_vent = nil
		client.impo_last_switch_time = nil
		client.impo_trapper_timer_expired = nil
		client.impo_sabo_mode = nil
		client.impo_highlighted_station = nil
		client.impo_selected_station = nil
	end)
	
	net.Receive("TTT2ImpostorInformEveryone", function()
		local num_impos = net.ReadInt(16)
		
		if num_impos == 1 then
			EPOP:AddMessage({text = LANG.GetTranslation("INFORM_ONE_" .. IMPOSTOR.name), color = IMPOSTOR.color}, "", 6)
		else
			EPOP:AddMessage({text = LANG.GetParamTranslation("INFORM_" .. IMPOSTOR.name, {n = num_impos}), color = IMPOSTOR.color}, "", 6)
		end
	end)
	
	net.Receive("TTT2ImpostorDefaultSaboMode", function()
		local client = LocalPlayer()
		client.impo_sabo_mode = net.ReadInt(16)
	end)
	
	net.Receive("TTT2ImpostorInstantKillUpdate", function()
		local client = LocalPlayer()
		local kill_cooldown = GetConVar("ttt2_impostor_kill_cooldown"):GetInt()
		
		client.impo_can_insta_kill = net.ReadBool()
		
		if not client.impo_can_insta_kill then
			--Create a timer which hopefully will match the server's timer.
			--This is used in the HUD to keep the client up to date in real time on when they can next kill
			timer.Create("ImpostorKillTimer_Client_" .. client:SteamID64(), kill_cooldown, 1, function()
				return
			end)
		elseif timer.Exists("ImpostorKillTimer_Client_" .. client:SteamID64()) then
			--Remove the previously created timer if it still exists.
			--Hopefully this will prevent cases where multiple timers run around.
			timer.Remove("ImpostorKillTimer_Client_" .. client:SteamID64())
		end
	end)
	
	net.Receive("TTT2ImpostorSabotageLightsScreenFade", function()
		local client = LocalPlayer()
		
		InduceScreenFade(client)
	end)
	
	net.Receive("TTT2ImpostorSabotageLightsRedownloadMap", function()
		render.RedownloadAllLightmaps()
	end)
	
	local function SabotageReactorCountdown(time_left)
		local timer_duration = -1
		
		if time_left > 10 then
			LANG.Msg("SABO_REACT_TIME_LEFT_" .. IMPOSTOR.name, {t = time_left}, MSG_MSTACK_WARN)
			
			if time_left % 10 == 0 then
				timer_duration = 10
			else
				--Most likely initial duration isn't divisible by 10. Make sure next warning is.
				timer_duration = time_left % 10
			end
		elseif time_left > 0 then
			LANG.Msg("SABO_REACT_" .. NUMBERS_STR_ARR[time_left] .. "_" .. IMPOSTOR.name, nil, MSG_MSTACK_WARN)
			
			timer_duration = 1
		end
		
		if timer_duration > 0 then
			--Two recursive functions in one script? It must be my lucky day!
			timer.Create("ImpostorSaboReactCountdown_Client", timer_duration, 1, function()
				if timer.Exists("ImpostorSaboReactTimer_Client") then
					SabotageReactorCountdown(time_left - timer_duration)
				end
			end)
		end
	end
	
	local function DisplaySaboPopUps(sabo_mode)
		if sabo_mode == SABO_MODE.LIGHTS then
			if GetConVar("ttt2_impostor_sabo_lights_mode"):GetInt() == SABO_LIGHTS_MODE.SCREEN_FADE then
				EPOP:AddMessage({text = LANG.GetTranslation("SABO_LIGHTS_INFO_FADE_" .. IMPOSTOR.name), color = IMPOSTOR.color}, "", 6)
			else --SABO_LIGHTS_MODE.DISABLE_MAP
				EPOP:AddMessage({text = LANG.GetTranslation("SABO_LIGHTS_INFO_MAP_" .. IMPOSTOR.name), color = IMPOSTOR.color}, "", 6)
			end
		elseif sabo_mode == SABO_MODE.COMMS then
			if GetConVar("ttt2_impostor_sabo_comms_deafen"):GetBool() then
				EPOP:AddMessage({text = LANG.GetTranslation("SABO_COMMS_INFO_MUTE_AND_DEAF_" .. IMPOSTOR.name), color = IMPOSTOR.color}, "", 6)
			else
				EPOP:AddMessage({text = LANG.GetTranslation("SABO_COMMS_INFO_MUTE_" .. IMPOSTOR.name), color = IMPOSTOR.color}, "", 6)
			end
		elseif sabo_mode == SABO_MODE.O2 then
			EPOP:AddMessage({text = LANG.GetTranslation("SABO_O2_INFO_" .. IMPOSTOR.name), color = IMPOSTOR.color}, "", 6)
		elseif sabo_mode == SABO_MODE.REACT then
			if GetConVar("ttt2_impostor_sabo_react_win_mode"):GetInt() == SABO_REACT_MODE.EVERYONE_LOSES then
				EPOP:AddMessage({text = LANG.GetTranslation("SABO_REACT_INFO_LOSE_" .. IMPOSTOR.name), color = IMPOSTOR.color}, "", 6)
			else --SABO_REACT_MODE.TEAM_WIN
				EPOP:AddMessage({text = LANG.GetTranslation("SABO_REACT_INFO_TEAM_WIN_" .. IMPOSTOR.name), color = IMPOSTOR.color}, "", 6)
			end
		end
		
		if GetConVar("ttt2_impostor_station_enable"):GetBool() and IMPO_SABO_DATA.THRESHOLD then
			--Use simple timer so that this pop up message doesn't overwrite the message above.
			timer.Simple(6, function()
				EPOP:AddMessage({text = LANG.GetParamTranslation("SABO_STAT_INFO_" .. IMPOSTOR.name, {n = IMPO_SABO_DATA.THRESHOLD}), color = IMPOSTOR.color}, "", 6)
			end)
		end
	end
	
	net.Receive("TTT2ImpostorSendSabotageResponse", function()
		local sabo_mode = net.ReadInt(16)
		local sabo_duration = net.ReadInt(16)
		--Plus one because Lua is 1-indexed!
		local abbr = SABO_MODE_ABBR[sabo_mode + 1]
		local abbr_upper = abbr:upper()
		local client = LocalPlayer()
		
		--Inform the clients that an Impostor has started a sabotage
		LANG.Msg("SABO_" .. abbr_upper .. "_START_" .. IMPOSTOR.name, nil, MSG_MSTACK_WARN)
		
		if client:GetSubRole() == ROLE_IMPOSTOR and GetConVar("ttt2_impostor_station_enable"):GetBool() then
			IMPO_SABO_DATA.MarkAndCycleSelectedSabotageStation()
		end
		
		--Create a timer which hopefully will match the server's timer.
		--This is used in the HUD to allow impostors to track the sabotages that other clients are experiencing.
		--And also to inform non-Impostors when a sabotage has ended.
		timer.Create("ImpostorSabo" .. abbr .. "Timer_Client", sabo_duration, 1, function()
			LANG.Msg("SABO_" .. abbr_upper .. "_END_" .. IMPOSTOR.name, nil, MSG_MSTACK_WARN)
			return
		end)
		
		if sabo_mode == SABO_MODE.REACT then
			SabotageReactorCountdown(sabo_duration)
		end
		
		if GetConVar("ttt2_impostor_sabo_pop_ups"):GetBool() then
			DisplaySaboPopUps(sabo_mode)
		end
	end)
	
	hook.Add("TTT2CanUseVoiceChat", "ImpostorCanUseVoiceChatForClient", function(speaker, isTeamVoice)
		--Jam all voice channels except traitor chat and spectator chat
		if timer.Exists("ImpostorSaboCommsTimer_Client") and (not isTeamVoice or CanHaveCommsSabotaged(speaker)) and not speaker:IsSpec() then
			LANG.Msg("SABO_COMMS_START_" .. IMPOSTOR.name, nil, MSG_MSTACK_WARN)
			return false
		end
	end)
	
	hook.Add("TTT2ClientRadioCommand", "ImpostorClientRadioCommand", function(cmd)
		--ttt_radio is a base TTT command that can be used to broadcast quickchat messages to others.
		--It can be accessed with running the "ttt_radio <option>" console command while looking at someone, or pressing "b" by default.
		--See https://ttt.badking.net/help/gameplay/ for details.
		--This should be prevented during Sabotage Comms.
		if timer.Exists("ImpostorSaboCommsTimer_Client") then
			LANG.Msg("SABO_COMMS_START_" .. IMPOSTOR.name, nil, MSG_MSTACK_WARN)
			return true
		end
	end)
	
	hook.Add("TTTRenderEntityInfo", "ImpostorRenderEntityInfo", function(tData)
		local client = LocalPlayer()
		local ent = tData:GetEntity()
		
		if not IsValid(client) or not client:IsPlayer() or not client:Alive() or not client:IsTerror() or client:GetSubRole() ~= ROLE_IMPOSTOR or not IsValid(ent) then
			return
		end
		
		--If the player can kill the player they're looking at, inform them by putting a notification
		--on the body. Also tell them which key they need to press.
		if ent:IsPlayer() and CanKillTarget(client, ent, tData:GetEntityDistance()) then
			local kill_key = string.upper(input.GetKeyName(bind.Find("ImpostorSendInstantKillRequest")))
			
			if tData:GetAmountDescriptionLines() > 0 then
				tData:AddDescriptionLine()
			end
			
			tData:AddDescriptionLine(LANG.GetTranslation("PRESS_" .. IMPOSTOR.name) .. kill_key .. LANG.GetTranslation("TO_KILL_" .. IMPOSTOR.name), IMPOSTOR.color)
		end
	end)
	
	local function SendInstantKillRequest()
		local client = LocalPlayer()
		if IsInSpecDM(client) then
			return
		end
		
		net.Start("TTT2ImpostorSendInstantKillRequest")
		net.SendToServer()
	end
	bind.Register("ImpostorSendInstantKillRequest", SendInstantKillRequest, nil, "Impostor", "Instant Kill", KEY_E)
	
	local function CycleSabotageMode()
		local client = LocalPlayer()
		
		if IsInSpecDM(client) then
			return
		end
		
		if not SelectedSaboModeInRange(client) then
			--All forms of sabotage have been disabled, or the client is very confused.
			return
		end
		
		if IMPO_SABO_DATA.CurrentSabotageInProgress() ~= SABO_MODE.NONE then
			--Don't cycle sabotage mode while a sabotage is in progress.
			return
		end
		
		local new_mode = client.impo_sabo_mode
		for i = SABO_MODE.NONE + 1, SABO_MODE.NUM do
			new_mode = new_mode + 1
			if new_mode >= SABO_MODE.NUM then
				new_mode = SABO_MODE.NONE + 1
			end
			
			if SabotageModeIsValid(new_mode) then
				client.impo_sabo_mode = new_mode
				break
			end
		end
	end
	bind.Register("ImpostorSabotageCycle", CycleSabotageMode, nil, "Impostor", "Cycle Sabotage Mode", KEY_C)
	
	local function SendSabotageRequest()
		local client = LocalPlayer()
		
		if IsInSpecDM(client) then
			return
		end
		
		if not SelectedSaboModeInRange(client) or IMPO_SABO_DATA.CurrentSabotageInProgress() ~= SABO_MODE.NONE or IMPO_SABO_DATA.STRANGE_GAME then
			--All forms of sabotage have been disabled, or the client is confused/ill-informed.
			return
		end
		
		if client.impo_sabo_mode == SABO_MODE.MNGR then
			--If we're not looking at a player, merely cycle the selected station.
			--Otherwise, head over to the server to see if a new station spawn can be added.
			local trace = client:GetEyeTrace(MASK_SHOT_HULL)
			local dist = trace.StartPos:Distance(trace.HitPos)
			local tgt = trace.Entity
			if not (IsValid(tgt) and tgt:IsPlayer()) then
				if IMPO_SABO_DATA.SelectedStationIsValid(client.impo_highlighted_station) then
					client.impo_selected_station = client.impo_highlighted_station
					client.impo_highlighted_station = nil
				else
					--Display help, because Station Manager is probably unintuitive.
					LANG.Msg("SABO_MNGR_HELP_" .. IMPOSTOR.name, nil, MSG_MSTACK_WARN)
				end
				
				--Return early as we aren't planning to create a new station spawn point.
				return
			end
		end
		
		net.Start("TTT2ImpostorSendSabotageRequest")
		net.WriteInt(client.impo_sabo_mode, 16)
		net.WriteInt(client.impo_selected_station, 16)
		net.SendToServer()
	end
	bind.Register("ImpostorSendSabotageRequest", SendSabotageRequest, nil, "Impostor", "Sabotage", KEY_V)
	
	hook.Add("KeyPress", "ImpostorKeyPressForClient", function(ply, key)
		--Note: Technically KeyPress is called on both the server and client.
		--However, what we do with KeyPress depends on the client's aim, so it is easier to have this
		--hook be client-only, which will then call on the server to replicate the functionality.
		local client = LocalPlayer()
		if ply:SteamID64() == client:SteamID64() and client:Alive() and client:IsTerror() and key == IN_USE and IsValid(client.impo_in_vent) then
			local ent_idx = -1
			if IsValid(client.impo_selected_vent) and client.impo_selected_vent:EntIndex() ~= client.impo_in_vent:EntIndex() then
				--Selected vent must be valid and different from the one we're currently in.
				ent_idx = client.impo_selected_vent:EntIndex()
			end
			
			--Use timer to prevent cases where key presses are registered multiple times on accident
			--Not quite sure if this is a bug in GMod, my testing server, or my keyboard...
			local cur_time = CurTime()
			if client.impo_last_move_time == nil or cur_time > client.impo_last_move_time + IMPO_IOTA then
				IMPO_VENT_DATA.MovePlayerFromVentTo(client, ent_idx)
				client.impo_last_move_time = cur_time
			end
		end
	end)
	
	local function CursorIsOverImpoButton(ply, button_scr_pos, previously_selected)
		local midscreen_x = ScrW() / 2
		local midscreen_y = ScrH() / 2
		
		if util.IsOffScreen(button_scr_pos) then
			return false
		end
		
		local dist_from_mid_x = math.abs(button_scr_pos.x - midscreen_x)
		local dist_from_mid_y = math.abs(button_scr_pos.y - midscreen_y)
		local button_dist_check = IMPO_BUTTON_MIDPOINT
		if previously_selected then
			button_dist_check = IMPO_SELECTED_BUTTON_MIDPOINT
		end
		
		if dist_from_mid_x > button_dist_check or dist_from_mid_y > button_dist_check then
			return false
		end
		
		return true
	end
	
	local function DrawVentHUD()
		local client = LocalPlayer()
		
		--If the player was selecting a valid vent on the previous frame then see if they still are
		local selected_vent_idx = -1
		if IsValid(client.impo_selected_vent) then
			local vent_pos = client.impo_selected_vent:GetPos() + client.impo_selected_vent:OBBCenter()
			local vent_scr_pos = vent_pos:ToScreen()
			if CursorIsOverImpoButton(client, vent_scr_pos, true) then
				selected_vent_idx = client.impo_selected_vent:EntIndex()
			else
				client.impo_selected_vent = nil
				selected_vent_idx = -1
			end
		end
		
		--See if we are currently selecting any vents
		if not IsValid(client.impo_selected_vent) then
			for _, vent in ipairs(IMPO_VENT_DATA.VENT_NETWORK) do
				--Make sure not to run CursorIsOverImpoButton on selected_vent_idx (which we already checked above)
				local vent_pos = vent:GetPos() + vent:OBBCenter()
				local vent_scr_pos = vent_pos:ToScreen()
				if IsValid(vent) and vent:EntIndex() ~= selected_vent_idx and CursorIsOverImpoButton(client, vent_scr_pos, false) then
					client.impo_selected_vent = vent
					selected_vent_idx = client.impo_selected_vent:EntIndex()
					break
				end
			end
		end
		
		--Finally, draw all vents, making sure to draw the selected one last (to handle overlaps)
		for _, vent in ipairs(IMPO_VENT_DATA.VENT_NETWORK) do
			if IsValid(vent) and vent:EntIndex() ~= selected_vent_idx and vent:EntIndex() ~= client.impo_in_vent:EntIndex() then
				local vent_pos = vent:GetPos() + vent:OBBCenter()
				local vent_scr_pos = vent_pos:ToScreen()
				
				if util.IsOffScreen(vent_scr_pos) then
					continue
				end
				
				draw.FilteredTexture(vent_scr_pos.x - IMPO_BUTTON_MIDPOINT, vent_scr_pos.y - IMPO_BUTTON_MIDPOINT, IMPO_BUTTON_SIZE, IMPO_BUTTON_SIZE, ICON_IN_VENT, 200, COLOR_ORANGE)
			end
		end
		if IsValid(client.impo_selected_vent) and client.impo_selected_vent:EntIndex() ~= client.impo_in_vent:EntIndex() then
			local vent_pos = client.impo_selected_vent:GetPos() + client.impo_selected_vent:OBBCenter()
			local vent_scr_pos = vent_pos:ToScreen()
			
			draw.FilteredTexture(vent_scr_pos.x - IMPO_SELECTED_BUTTON_MIDPOINT, vent_scr_pos.y - IMPO_SELECTED_BUTTON_MIDPOINT, IMPO_SELECTED_BUTTON_SIZE, IMPO_SELECTED_BUTTON_SIZE, ICON_IN_VENT, 200, IMPOSTOR.color)
		end
	end
	
	local function DrawStationManagerHUD()
		local client = LocalPlayer()
		local dissuade_station_reuse = GetConVar("ttt2_impostor_dissuade_station_reuse"):GetBool()
		
		surface.SetFont("Default")
		surface.SetTextColor(255, 255, 255)
		
		--If the player was highlighting a valid station spawn on the previous frame then see if they still are
		local highlighted_station = -1
		if IMPO_SABO_DATA.SelectedStationIsUsable(client.impo_highlighted_station) then
			local stat_spawn_scr_pos = IMPO_SABO_DATA.STATION_NETWORK[client.impo_highlighted_station].pos:ToScreen()
			if CursorIsOverImpoButton(client, stat_spawn_scr_pos, true) then
				highlighted_station = client.impo_highlighted_station
			else
				client.impo_highlighted_station = nil
				highlighted_station = -1
			end
		end
		
		--See if we are currently highighting any stations
		if not IMPO_SABO_DATA.SelectedStationIsUsable(client.impo_highlighted_station) then
			for i, stat_spawn in ipairs(IMPO_SABO_DATA.STATION_NETWORK) do
				--Make sure not to run CursorIsOverImpoButton on highlighted_station (which we already checked above)
				if IMPO_SABO_DATA.SelectedStationIsUsable(i) and i ~= client.impo_selected_station then
					local stat_spawn_scr_pos = IMPO_SABO_DATA.STATION_NETWORK[i].pos:ToScreen()
					if CursorIsOverImpoButton(client, stat_spawn_scr_pos, false) then
						client.impo_highlighted_station = i
						highlighted_station = i
						break
					end
				end
			end
		end
		
		--Finally, draw all station spawns, making sure to draw the highlighted one last (to handle overlaps)
		for i, stat_spawn in ipairs(IMPO_SABO_DATA.STATION_NETWORK) do
			if i ~= client.impo_highlighted_station and i ~= highlighted_station then
				local stat_spawn_scr_pos = stat_spawn.pos:ToScreen()
				
				if util.IsOffScreen(stat_spawn_scr_pos) then
					continue
				end
				
				local color = COLOR_ORANGE
				local size = IMPO_BUTTON_SIZE
				local midpoint = IMPO_BUTTON_MIDPOINT
				
				if i == client.impo_selected_station then
					color = IMPOSTOR.color
					size = IMPO_SELECTED_BUTTON_SIZE
					midpoint = IMPO_SELECTED_BUTTON_MIDPOINT
				end
				
				if dissuade_station_reuse and stat_spawn.used then
					color = COLOR_BLACK
				end
				
				draw.FilteredTexture(stat_spawn_scr_pos.x - midpoint, stat_spawn_scr_pos.y - midpoint, size, size, ICON_STATION, 200, color)
				
				local text = math.ceil(client:GetPos():Distance(stat_spawn.pos))
				local text_width, text_height = surface.GetTextSize(text)
				surface.SetTextPos(stat_spawn_scr_pos.x - text_width * 0.5, stat_spawn_scr_pos.y - text_height * 0.15)
				surface.DrawText(text)
			end
		end
		if IMPO_SABO_DATA.SelectedStationIsUsable(client.impo_highlighted_station) then
			local stat_spawn = IMPO_SABO_DATA.STATION_NETWORK[client.impo_highlighted_station]
			local stat_spawn_scr_pos = stat_spawn.pos:ToScreen()
			local color = COLOR_ORANGE
			local size = IMPO_SELECTED_BUTTON_SIZE
			local midpoint = IMPO_SELECTED_BUTTON_MIDPOINT
			
			draw.FilteredTexture(stat_spawn_scr_pos.x - midpoint, stat_spawn_scr_pos.y - midpoint, size, size, ICON_STATION, 200, color)
			
			local text = math.ceil(client:GetPos():Distance(stat_spawn.pos))
			local text_width, text_height = surface.GetTextSize(text)
			surface.SetTextPos(stat_spawn_scr_pos.x - text_width * 0.5, stat_spawn_scr_pos.y - text_height * 0.15)
			surface.DrawText(text)
		end
	end
	
	hook.Add("HUDPaint", "ImpostorHUDPaint", function()
		local client = LocalPlayer()
		
		if not client:Alive() or not client:IsTerror() then
			return
		end
		
		if IsValid(client.impo_in_vent) then
			DrawVentHUD()
		end
		
		if client:GetSubRole() == ROLE_IMPOSTOR and client.impo_sabo_mode == SABO_MODE.MNGR and IMPO_SABO_DATA.CurrentSabotageInProgress() == SABO_MODE.NONE then
			DrawStationManagerHUD()
		end
	end)
end
