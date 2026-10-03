local H = CampfireHangout

local ANNOUNCE_TTL = 20
local BROADCAST_INTERVAL = 10

local ready = false
local dismissed = false
local suppressDismiss = false
local mode = nil
local tiedToBuff = false
local hadBuff = false
local nextBroadcast = 0
local announcers = {}
local company = {}
local scanAccumulator = 0
local ignoreMoveUntil = 0
local function UnitKey(unit)
	local ok, guid = pcall(UnitGUID, unit)
	if ok and type(guid) == "string" and guid ~= "" and not H.Sealed(guid) then
		return guid
	end
	return unit
end

local function GroupCount(includeSelf)
	local fn = includeSelf and GetNumGroupMembers or GetNumSubgroupMembers
	if type(fn) ~= "function" then
		return 0
	end
	local ok, count = pcall(fn)
	if not ok or H.Sealed(count) or type(count) ~= "number" then
		return 0
	end
	return count
end

local function DB()
	if type(CampfireHangoutDB) ~= "table" then
		CampfireHangoutDB = {}
	end
	if CampfireHangoutDB.enabled == nil then
		CampfireHangoutDB.enabled = true
	end
	return CampfireHangoutDB
end

local function RememberSpell(aura)
	if not aura then
		return
	end
	local spellId = aura.spellId
	if type(spellId) == "number" and spellId > 0 and not H.Sealed(spellId) then
		DB().buffSpellID = spellId
	end
end

local function AuraMatches(aura)
	if type(aura) ~= "table" then
		return false
	end
	local saved = CampfireHangoutDB and CampfireHangoutDB.buffSpellID
	local spellId = aura.spellId
	if type(saved) == "number" and type(spellId) == "number" and not H.Sealed(spellId) and spellId == saved then
		return true
	end
	local name = aura.name
	if type(name) == "string" and not H.Sealed(name) and name == H.BUFF_NAME then
		return true
	end
	return false
end

local function TryAura(fn)
	local ok, aura = pcall(fn)
	if ok and type(aura) == "table" then
		return aura
	end
end

local function FindBuff(unit)
	local saved = CampfireHangoutDB and CampfireHangoutDB.buffSpellID
	local aura

	if unit == "player" and type(saved) == "number" and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
		aura = TryAura(function()
			return C_UnitAuras.GetPlayerAuraBySpellID(saved)
		end)
	end

	if not aura and type(saved) == "number" and C_UnitAuras and C_UnitAuras.GetAuraDataBySpellID then
		aura = TryAura(function()
			return C_UnitAuras.GetAuraDataBySpellID(unit, saved)
		end)
	end

	if not aura and C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
		aura = TryAura(function()
			local byName = C_UnitAuras.GetAuraDataBySpellName(unit, H.BUFF_NAME, "HELPFUL")
			if AuraMatches(byName) then
				return byName
			end
		end)
	end

	if not aura and C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
		aura = TryAura(function()
			for index = 1, 40 do
				local data = C_UnitAuras.GetBuffDataByIndex(unit, index)
				if not data then
					return nil
				end
				if AuraMatches(data) then
					return data
				end
			end
		end)
	end

	if not aura and type(UnitBuff) == "function" then
		aura = TryAura(function()
			for index = 1, 40 do
				local name, _, icon, _, _, duration, expirationTime, _, _, _, spellId = UnitBuff(unit, index)
				if not name then
					return nil
				end
				local data = {
					name = name,
					icon = icon,
					duration = duration,
					expirationTime = expirationTime,
					spellId = spellId,
				}
				if AuraMatches(data) then
					return data
				end
			end
		end)
	end

	if type(aura) ~= "table" then
		return nil
	end
	if unit == "player" then
		RememberSpell(aura)
	end
	return aura
end

local function Expiration(aura)
	if not aura then
		return nil
	end
	local expires = aura.expirationTime
	local duration = aura.duration
	if H.Sealed(expires) or type(expires) ~= "number" then
		return nil
	end
	if not H.Sealed(duration) and type(duration) == "number" and duration <= 0 then
		return nil
	end
	return expires
end

local function IsGroupToken(unit)
	return type(unit) == "string" and (unit:match("^party%d+$") ~= nil or unit:match("^raid%d+$") ~= nil)
end

local function IsOtherFriendlyPlayer(unit)
	if not H.SafeTrue(UnitExists, unit) then
		return false
	end
	if not H.SafeTrue(UnitIsPlayer, unit) then
		return false
	end
	if H.SafeTrue(UnitIsUnit, unit, "player") then
		return false
	end
	if H.SafeTrue(UnitIsDeadOrGhost, unit) then
		return false
	end
	if IsGroupToken(unit) then
		local connected = H.SafeBool(UnitIsConnected, unit)
		return connected ~= false
	end
	local attack = H.SafeBool(UnitCanAttack, "player", unit)
	return attack == false
end

local function AlreadyListed(list, unit)
	for _, existing in ipairs(list) do
		if H.SafeTrue(UnitIsUnit, existing, unit) then
			return true
		end
	end
	return false
end

local function NameAnnounced(unit)
	local ok, name, realm = pcall(UnitName, unit)
	if not ok or type(name) ~= "string" or H.Sealed(name) then
		return false
	end
	local now = GetTime()
	local function fresh(key)
		local seen = announcers[key]
		return type(seen) == "number" and (now - seen) < ANNOUNCE_TTL
	end
	if fresh(name) then
		return true
	end
	if type(realm) == "string" and realm ~= "" and not H.Sealed(realm) and fresh(name .. "-" .. realm) then
		return true
	end
	return false
end

local function InCompany(unit)
	local key = UnitKey(unit)
	return type(key) == "string" and company[key] == true
end

local function Qualifies(unit)
	if FindBuff(unit) then
		return true
	end
	local ok, announced = pcall(NameAnnounced, unit)
	if ok and announced == true then
		return true
	end
	return H.Scene:IsShown() and mode == "live" and InCompany(unit)
end

local function BuildLineup()
	local others = {}

	local function consider(unit)
		if #others >= (H.MAX_SLOTS - 1) then
			return
		end
		if not IsOtherFriendlyPlayer(unit) then
			return
		end
		if AlreadyListed(others, unit) then
			return
		end
		if not Qualifies(unit) then
			return
		end
		others[#others + 1] = unit
	end

	if H.SafeTrue(IsInRaid) then
		for index = 1, GroupCount(true) do
			consider("raid" .. index)
		end
	else
		for index = 1, GroupCount(false) do
			consider("party" .. index)
		end
	end

	for index = 1, 40 do
		consider("nameplate" .. index)
	end

	local left, right = {}, {}
	for index, unit in ipairs(others) do
		if index % 2 == 1 then
			left[#left + 1] = unit
		else
			right[#right + 1] = unit
		end
	end

	local lineup = {}
	for index = #left, 1, -1 do
		lineup[#lineup + 1] = { unit = left[index], key = UnitKey(left[index]) }
	end
	lineup[#lineup + 1] = { unit = "player", key = "player" }
	for index = 1, #right do
		lineup[#lineup + 1] = { unit = right[index], key = UnitKey(right[index]) }
	end
	for index = 1, #lineup do
		local entry = lineup[index]
		if entry.unit ~= "player" and type(entry.key) == "string" then
			company[entry.key] = true
		end
	end
	return lineup
end

local function BuildClones(count)
	count = math.max(1, math.min(H.MAX_SLOTS, count or 5))
	local lineup = {}
	for index = 1, count do
		lineup[index] = { unit = "player", key = "clone" .. index }
	end
	return lineup
end

local function Payload(kind, entries)
	local aura = FindBuff("player")
	local expires = Expiration(aura)
	if kind == "test" then
		return {
			title = "Campfire Hangout",
			subtitle = "Stay a while and listen",
			footer = "Escape or right-click to leave",
			timerText = "Preview",
			expiresAt = nil,
			entries = entries,
		}
	end
	if kind == "live" then
		return {
			title = "Campfire Hangout",
			subtitle = "Stay a while and listen",
			footer = "Escape or right-click to leave",
			timerText = expires and "" or "Camp benefits are ready",
			expiresAt = expires,
			entries = entries,
		}
	end
	return {
		title = "Campfire Hangout",
		subtitle = "Stay a while and listen",
		footer = "Escape or right-click to leave",
		timerText = "",
		expiresAt = nil,
		entries = entries,
	}
end

local function ShowScene(kind, entries)
	ignoreMoveUntil = GetTime() + 1.5
	mode = kind
	tiedToBuff = kind == "live" or (kind ~= "test" and FindBuff("player") ~= nil)
	if kind == "test" then
		tiedToBuff = false
	end
	local payload = Payload(kind, entries)
	if H.Scene:IsShown() then
		H.Scene:Update(payload)
	else
		H.Scene:Present(payload)
	end
end

local function CloseScene(reason)
	if reason == "buffEnded" or reason == "combat" or reason == "disabled" then
		suppressDismiss = true
	end
	H.Scene:HideScene()
	suppressDismiss = false
end

function H.OnSceneHidden()
	if not suppressDismiss and mode == "live" and FindBuff("player") then
		dismissed = true
	end
	if not FindBuff("player") then
		dismissed = false
	end
	mode = nil
	tiedToBuff = false
	company = {}
end

function H.RequestClose(reason)
	if reason == "manual" and mode == "live" then
		dismissed = true
	end
	CloseScene(reason or "manual")
end

local function InCombat()
	if type(InCombatLockdown) == "function" and InCombatLockdown() then
		return true
	end
	return false
end

local function RefreshOpenScene()
	if not H.Scene:IsShown() or not mode then
		return
	end
	if mode == "test" then
		return
	end
	local entries = BuildLineup()
	H.Scene:Update(Payload(mode, entries))
end

local function Broadcast(message, includeGuild)
	pcall(function()
		if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then
			return
		end
		local function send(channel)
			pcall(C_ChatInfo.SendAddonMessage, H.PREFIX, message, channel)
		end
		if LE_PARTY_CATEGORY_INSTANCE and H.SafeTrue(IsInGroup, LE_PARTY_CATEGORY_INSTANCE) then
			send("INSTANCE_CHAT")
		elseif H.SafeTrue(IsInRaid) then
			send("RAID")
		elseif H.SafeTrue(IsInGroup) then
			send("PARTY")
		end
		if includeGuild ~= false and H.SafeTrue(IsInGuild) then
			send("GUILD")
		end
	end)
end

local function BroadcastState(force)
	if not ready or not DB().enabled then
		return
	end
	local buffOn = FindBuff("player") ~= nil
	if not buffOn and not force then
		return
	end
	local now = GetTime()
	if not force and now < nextBroadcast then
		return
	end
	nextBroadcast = now + BROADCAST_INTERVAL
	Broadcast(buffOn and "1" or "0")
end

function H.RequestEmote(token)
	if type(token) ~= "string" or token == "" then
		return
	end
	if type(DoEmote) == "function" then
		pcall(DoEmote, token)
	end
	if H.Scene and H.Scene.PlayLocal then
		H.Scene:PlayLocal(token)
	end
	Broadcast("e:" .. token)
end

local function Evaluate()
	if not ready then
		return
	end
	local aura = FindBuff("player")
	local buffOn = aura ~= nil

	if buffOn and not hadBuff then
		nextBroadcast = 0
		BroadcastState(true)
	end
	if hadBuff and not buffOn then
		Broadcast("0")
		if DB().enabled then
			H.Print("The welcoming fire settles. Camp benefits should be on you now.")
		end
	end

	hadBuff = buffOn

	if not buffOn then
		dismissed = false
		if H.Scene:IsShown() and mode == "live" then
			RefreshOpenScene()
		end
		return
	end

	if not DB().enabled or dismissed or InCombat() then
		if InCombat() and H.Scene:IsShown() and mode == "live" then
			CloseScene("combat")
		end
		return
	end

	if H.Scene:IsShown() and mode == "test" then
		return
	end

	ShowScene("live", BuildLineup())
end

local function RememberAnnouncement(sender, message)
	if type(sender) ~= "string" then
		return
	end
	if message == "0" then
		announcers[sender] = nil
		local short = sender:match("^([^%-]+)")
		if short then
			announcers[short] = nil
		end
		return
	end
	local now = GetTime()
	announcers[sender] = now
	local short = sender:match("^([^%-]+)")
	if short and short ~= sender then
		announcers[short] = now
	end
end

local function PruneAnnouncers()
	local now = GetTime()
	for key, seen in pairs(announcers) do
		if type(seen) ~= "number" or (now - seen) > ANNOUNCE_TTL then
			announcers[key] = nil
		end
	end
end

local function HandleSlash(message)
	local text = (message or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, rest = text:match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()

	if cmd == "" then
		if H.Scene:IsShown() then
			H.RequestClose("manual")
			return
		end
		if FindBuff("player") and DB().enabled then
			dismissed = false
			ShowScene("live", BuildLineup())
		else
			ShowScene("preview", BuildLineup())
		end
		return
	end

	if cmd == "test" then
		local count = tonumber(rest)
		ShowScene("test", BuildClones(count or 5))
		return
	end

	if cmd == "on" then
		DB().enabled = true
		dismissed = false
		H.Print("Auto-open is on.")
		Evaluate()
		return
	end

	if cmd == "off" then
		DB().enabled = false
		CloseScene("disabled")
		H.Print("Auto-open is off. /cfh still opens a preview.")
		return
	end

	if cmd == "cam" or cmd == "camera" then
		local sceneCam = H.Scene:UsesSceneCamera()
		local minDist, maxDist, minZ, maxZ = 0.3, 6, -3, 3
		local example = "1.8 -0.6"
		if sceneCam then
			minDist, maxDist, minZ, maxZ = 4, 18, 0.2, 4
			example = "9 1.6"
		end
		if rest == "" then
			local saved = DB().camera
			local usable = saved and ((sceneCam and saved.scene) or (not sceneCam and not saved.scene))
			local distance = usable and saved.distance or H.Scene:CameraDefaults()
			local z = usable and saved.z or select(2, H.Scene:CameraDefaults())
			H.Print(string.format("Camera distance %.2f, height %.2f. Try /cfh cam %s", distance, z, example))
			return
		end
		if rest:lower() == "reset" then
			DB().camera = nil
			H.Print("Camera reset.")
			if H.Scene:IsShown() then
				H.Scene:RefreshCamera()
			end
			return
		end
		local distText, zText = rest:match("^(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)$")
		local distance, z = tonumber(distText), tonumber(zText)
		if not distance or not z or distance < minDist or distance > maxDist or z < minZ or z > maxZ then
			H.Print(string.format("Usage: /cfh cam <distance> <height>   example /cfh cam %s", example))
			return
		end
		DB().camera = { distance = distance, z = z, scene = sceneCam and true or nil }
		H.Print(string.format("Camera set to distance %.2f, height %.2f.", distance, z))
		if H.Scene:IsShown() then
			H.Scene:RefreshCamera()
		end
		return
	end

	if cmd == "font" then
		if rest == "" or rest:lower() == "list" then
			H.Scene:PrintFonts()
		else
			H.Scene:SelectFont(rest)
		end
		return
	end

	if cmd == "debug" then
		local aura = FindBuff("player")
		local expires = Expiration(aura)
		local remain = "none"
		if type(expires) == "number" then
			local ok, value = pcall(function()
				return expires - GetTime()
			end)
			if ok and type(value) == "number" then
				remain = string.format("%.1fs", math.max(0, value))
			end
		end
		local spellId = DB().buffSpellID
		local announced = 0
		for _ in pairs(announcers) do
			announced = announced + 1
		end
		local lineup = BuildLineup()
		H.Print(string.format(
			"enabled=%s buff=%s spell=%s remain=%s neighbors=%d announcers=%d mode=%s",
			tostring(DB().enabled),
			aura and "yes" or "no",
			spellId and tostring(spellId) or "unknown",
			remain,
			math.max(0, #lineup - 1),
			announced,
			tostring(mode)
		))
		return
	end

	H.Print("Commands: /cfh, /cfh test [count], /cfh font [name], /cfh on, /cfh off, /cfh cam <distance> <height>, /cfh debug")
end

local function RegisterOptions()
	if H.optionsRegistered then
		return
	end
	H.optionsRegistered = true

	local panel = CreateFrame("Frame")
	panel.name = "Campfire Hangout"

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Campfire Hangout")

	local note = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	note:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	note:SetWidth(520)
	note:SetJustifyH("LEFT")
	note:SetText("The font shown in the box is the one used on the hangout screen. The list is every font registered with LibSharedMedia, plus the game fonts.")

	local fontLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	fontLabel:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -18)
	fontLabel:SetText("Font")

	local dropdown = CreateFrame("Button", nil, panel)
	dropdown:SetSize(320, 26)
	dropdown:SetPoint("LEFT", fontLabel, "RIGHT", 16, 0)
	dropdown:RegisterForClicks("LeftButtonUp")
	local dropBg = dropdown:CreateTexture(nil, "BACKGROUND")
	dropBg:SetPoint("TOPLEFT", 1, -1)
	dropBg:SetPoint("BOTTOMRIGHT", -1, 1)
	dropBg:SetColorTexture(0.08, 0.07, 0.06, 0.95)
	local dropBorder = dropdown:CreateTexture(nil, "BACKGROUND")
	dropBorder:SetAllPoints()
	dropBorder:SetColorTexture(0.55, 0.44, 0.18, 0.95)
	dropBg:SetDrawLayer("BACKGROUND", 1)
	dropBorder:SetDrawLayer("BACKGROUND", 0)
	local dropText = dropdown:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	dropText:SetPoint("LEFT", 10, 0)
	dropText:SetPoint("RIGHT", -22, 0)
	dropText:SetJustifyH("LEFT")
	dropText:SetWordWrap(false)
	local dropArrow = dropdown:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	dropArrow:SetPoint("RIGHT", -8, 0)
	dropArrow:SetText("v")
	dropArrow:SetTextColor(0.95, 0.82, 0.4)

	local catcher = CreateFrame("Button", nil, UIParent)
	catcher:SetAllPoints(UIParent)
	catcher:SetFrameStrata("FULLSCREEN_DIALOG")
	catcher:SetFrameLevel(400)
	catcher:Hide()

	local menu = CreateFrame("Frame", nil, UIParent)
	menu:SetFrameStrata("FULLSCREEN_DIALOG")
	menu:SetFrameLevel(410)
	menu:SetSize(320, 28)
	menu:Hide()
	local menuBg = menu:CreateTexture(nil, "BACKGROUND")
	menuBg:SetPoint("TOPLEFT", 1, -1)
	menuBg:SetPoint("BOTTOMRIGHT", -1, 1)
	menuBg:SetColorTexture(0.05, 0.04, 0.03, 0.98)
	local menuBorder = menu:CreateTexture(nil, "BACKGROUND")
	menuBorder:SetAllPoints()
	menuBorder:SetColorTexture(0.55, 0.44, 0.18, 0.95)
	menuBg:SetDrawLayer("BACKGROUND", 1)
	menuBorder:SetDrawLayer("BACKGROUND", 0)

	local scroll = CreateFrame("ScrollFrame", nil, menu)
	scroll:SetPoint("TOPLEFT", 4, -4)
	scroll:SetPoint("BOTTOMRIGHT", -4, 4)
	scroll:EnableMouseWheel(true)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(300, 22)
	scroll:SetScrollChild(content)

	local rows = {}
	local function PaintFont(fs, path, size)
		if not (H.SetFont and pcall(H.SetFont, fs, path, size)) or not fs:GetFont() then
			pcall(fs.SetFont, fs, "Fonts\\FRIZQT__.TTF", size, "")
		end
	end

	local function RefreshDropdown()
		local path, name = "Fonts\\FRIZQT__.TTF", "Friz Quadrata"
		if H.Scene and H.Scene.GetFont then
			local gotPath, gotName = H.Scene:GetFont()
			if type(gotPath) == "string" and gotPath ~= "" then
				path = gotPath
			end
			if type(gotName) == "string" and gotName ~= "" then
				name = gotName
			end
		end
		PaintFont(dropText, path, 14)
		dropText:SetText(name)
		dropText:SetTextColor(1, 0.9, 0.65)
	end

	local function CloseMenu()
		menu:Hide()
		catcher:Hide()
		scroll:SetVerticalScroll(0)
	end

	local function OpenMenu()
		if not H.Scene or not H.Scene.GetFonts then
			return
		end
		local fonts = H.Scene:GetFonts()
		local currentName = ""
		if H.Scene.GetFont then
			local _, gotName = H.Scene:GetFont()
			if type(gotName) == "string" then
				currentName = gotName:lower()
			end
		end
		local rowH = 22
		local shown = 0
		for i, item in ipairs(fonts) do
			local row = rows[i]
			if not row then
				row = CreateFrame("Button", nil, content)
				row:SetSize(300, rowH)
				row:RegisterForClicks("LeftButtonUp")
				local highlight = row:CreateTexture(nil, "BACKGROUND")
				highlight:SetAllPoints()
				highlight:SetColorTexture(0.4, 0.3, 0.08, 0.35)
				highlight:Hide()
				row.highlight = highlight
				local mark = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
				mark:SetPoint("LEFT", 6, 0)
				mark:SetText("*")
				mark:SetTextColor(1, 0.82, 0.3)
				row.mark = mark
				local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
				label:SetPoint("LEFT", 18, 0)
				label:SetPoint("RIGHT", -8, 0)
				label:SetJustifyH("LEFT")
				label:SetWordWrap(false)
				row.label = label
				row:SetScript("OnEnter", function(self)
					self.highlight:Show()
				end)
				row:SetScript("OnLeave", function(self)
					if not self.selected then
						self.highlight:Hide()
					end
				end)
				rows[i] = row
			end
			local selected = item.name:lower() == currentName
			row.selected = selected
			row.itemName = item.name
			row:SetPoint("TOPLEFT", 0, -((i - 1) * rowH))
			PaintFont(row.label, item.path, 14)
			row.label:SetText(item.name)
			if selected then
				row.label:SetTextColor(1, 0.86, 0.4)
				row.mark:Show()
				row.highlight:Show()
			else
				row.label:SetTextColor(0.92, 0.9, 0.84)
				row.mark:Hide()
				row.highlight:Hide()
			end
			row:SetScript("OnClick", function(self)
				if H.Scene.SelectFont then
					H.Scene:SelectFont(self.itemName)
				end
				RefreshDropdown()
				CloseMenu()
			end)
			row:Show()
			shown = i
		end
		for i = shown + 1, #rows do
			rows[i]:Hide()
		end
		content:SetHeight(math.max(shown * rowH, rowH))
		local visible = math.min(shown, 14)
		menu:SetHeight(visible * rowH + 8)
		menu:ClearAllPoints()
		menu:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 0, -2)
		scroll:SetVerticalScroll(0)
		catcher:Show()
		menu:Show()
	end

	scroll:SetScript("OnMouseWheel", function(self, delta)
		local height = content:GetHeight() - self:GetHeight()
		if height < 0 then
			height = 0
		end
		local nextScroll = self:GetVerticalScroll() - delta * 22
		if nextScroll < 0 then
			nextScroll = 0
		end
		if nextScroll > height then
			nextScroll = height
		end
		self:SetVerticalScroll(nextScroll)
	end)

	catcher:SetScript("OnClick", CloseMenu)
	dropdown:SetScript("OnClick", function()
		if menu:IsShown() then
			CloseMenu()
		else
			OpenMenu()
		end
	end)
	panel:SetScript("OnShow", RefreshDropdown)
	panel:SetScript("OnHide", CloseMenu)
	RefreshDropdown()

	if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
		local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, panel, panel.name)
		if ok and category then
			pcall(Settings.RegisterAddOnCategory, category)
			return
		end
	end
	if type(InterfaceOptions_AddCategory) == "function" then
		InterfaceOptions_AddCategory(panel)
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
if type(events.RegisterUnitEvent) == "function" and pcall(events.RegisterUnitEvent, events, "UNIT_AURA", "player") then
	-- Player-only aura updates.
else
	events:RegisterEvent("UNIT_AURA")
end
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_STARTED_MOVING")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("CHAT_MSG_SAY")
events:RegisterEvent("CHAT_MSG_YELL")
events:RegisterEvent("CHAT_MSG_EMOTE")
events:RegisterEvent("CHAT_MSG_PARTY")
events:RegisterEvent("CHAT_MSG_PARTY_LEADER")
events:RegisterEvent("CHAT_MSG_RAID")
events:RegisterEvent("CHAT_MSG_RAID_LEADER")
events:RegisterEvent("CHAT_MSG_INSTANCE_CHAT")

events:SetScript("OnEvent", function(_, event, arg1, arg2, _, arg4)
	if event == "ADDON_LOADED" then
		if arg1 ~= H.NAME then
			return
		end
		DB()
		ready = true
		if H.Scene.ApplySavedFont then
			H.Scene:ApplySavedFont()
		end
		RegisterOptions()
		return
	end

	if not ready then
		return
	end

	if event == "PLAYER_LOGIN" then
		if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
			pcall(C_ChatInfo.RegisterAddonMessagePrefix, H.PREFIX)
		end
		local lib = H.SharedMediaLib and H.SharedMediaLib()
		if lib and type(lib.Register) == "function" then
			pcall(lib.Register, lib, "font", "Cinzel Decorative", "Interface\\AddOns\\" .. H.NAME .. "\\Fonts\\CinzelDecorative-Regular.ttf")
		end
		if DB().enabled then
			H.Print("Loaded. /cfh opens a preview. The screen stays up after the minute until you press Escape.")
		else
			H.Print("Loaded, auto-open off. /cfh on to enable it.")
		end
		C_Timer.After(1, Evaluate)
		return
	end

	if event == "CHAT_MSG_ADDON" then
		if arg1 ~= H.PREFIX then
			return
		end
		if type(arg2) == "string" and not H.Sealed(arg2) and arg2:sub(1, 2) == "e:" then
			if H.Scene:IsShown() and H.Scene.PlayFromSender then
				H.Scene:PlayFromSender(arg4, arg2:sub(3))
			end
			return
		end
		RememberAnnouncement(arg4, arg2)
		if H.Scene:IsShown() then
			RefreshOpenScene()
		end
		return
	end

	if event == "CHAT_MSG_SAY" or event == "CHAT_MSG_YELL" or event == "CHAT_MSG_EMOTE" or event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER" or event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER" or event == "CHAT_MSG_INSTANCE_CHAT" then
		if H.Scene:IsShown() and H.Scene.ShowChat then
			H.Scene:ShowChat(arg2, arg1)
		end
		return
	end

	if event == "PLAYER_REGEN_DISABLED" then
		if H.Scene:IsShown() and mode == "live" then
			CloseScene("combat")
		end
		return
	end

	if event == "PLAYER_STARTED_MOVING" then
		return
	end

	if event == "NAME_PLATE_UNIT_ADDED" then
		C_Timer.After(0.3, function()
			if H.Scene:IsShown() then
				RefreshOpenScene()
			end
		end)
		return
	end

	if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_REGEN_ENABLED" or event == "UNIT_AURA" or event == "GROUP_ROSTER_UPDATE" or event == "NAME_PLATE_UNIT_REMOVED" then
		Evaluate()
	end
end)

events:SetScript("OnUpdate", function(_, elapsed)
	if not ready then
		return
	end
	scanAccumulator = scanAccumulator + elapsed
	if scanAccumulator < 1 then
		return
	end
	scanAccumulator = 0
	if hadBuff then
		BroadcastState(false)
	end
	if H.Scene:IsShown() and mode ~= "test" then
		PruneAnnouncers()
		RefreshOpenScene()
	end
end)

SLASH_CAMPFIREHANGOUT1 = "/cfh"
SLASH_CAMPFIREHANGOUT2 = "/campfirehangout"
SlashCmdList.CAMPFIREHANGOUT = HandleSlash
