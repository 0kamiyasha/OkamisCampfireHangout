local H = CampfireHangout

local FONT_TITLE = "Fonts\\MORPHEUS.TTF"
local FONT_BODY = "Fonts\\FRIZQT__.TTF"

-- File ids from the 1.60 listfile. A bad model id can crash SetModelByFileID.
local CAMPFIRE_FILE = 189705
local CAMPFIRE_PATH = "world/azeroth/elwynn/passivedoodads/campfire/elwynncampfire.m2"
local BACKDROP_PATH = "Interface\\AddOns\\" .. H.NAME .. "\\Textures\\CampfireBackdrop"
local BACKDROP_ASPECT = 1024 / 419
-- Center of the flames in CampfireBackdrop, as fractions of that image.
local PAINTED_FIRE = { u = 0.511, v = 0.845, w = 0.10, h = 0.20 }
local BACKDROP_FALLBACK = "Interface\\Glues\\LoadingScreens\\LoadScreenRuinedCity"

-- Paper-doll fallback. /cfh cam overrides distance and z.
local DOLL_CAMERA = {
	distance = 1.55,
	z = -0.45,
	portraitZoom = 0,
}

-- Shared scene camera, in yards. Distance pulls the camera back. z is camera height.
local SCENE_CAMERA = {
	distance = 9.2,
	z = 1.65,
}

local LAYOUT = {
	skyFraction = 0.28,
	feetFraction = 0.10,
	slotHeightFraction = 0.805,
	slotAspect = 0.42,
	maxWidthFraction = 0.92,
	sideLift = 0.03,
	sideScale = 0.9,
	inwardFacing = 0.2,
}

local FLAMES = {
	{ x = 0.00, w = 0.09, h = 0.58, phase = 0.0 },
	{ x = -0.07, w = 0.06, h = 0.46, phase = 1.3 },
	{ x = 0.08, w = 0.07, h = 0.50, phase = 2.2 },
	{ x = -0.14, w = 0.045, h = 0.34, phase = 2.8 },
	{ x = 0.15, w = 0.045, h = 0.32, phase = 0.7 },
}

local frame
local sky
local horizon
local groundFade
local backdrop
local dimmer
local textLayer
local titleText
local subtitleText
local timerText
local footerText
local slots = {}
local emoteButtons = {}
local scene
local sceneMode = false
local fireActor
local fireModel
local campfireModelOn = false
local fireLoaded = false
local fire
local flames = {}
local embers = {}
local glow
local currentEntries = {}
local expiresAt
local staticTimer = ""
local backdropFile

local function Try(object, method, ...)
	if object and type(object[method]) == "function" then
		return pcall(object[method], object, ...)
	end
	return false
end

local function Camera()
	local saved = CampfireHangoutDB and CampfireHangoutDB.camera
	if sceneMode then
		if type(saved) == "table" and saved.scene then
			return {
				distance = tonumber(saved.distance) or SCENE_CAMERA.distance,
				z = tonumber(saved.z) or SCENE_CAMERA.z,
			}
		end
		return SCENE_CAMERA
	end
	if type(saved) == "table" and not saved.scene then
		return {
			distance = tonumber(saved.distance) or DOLL_CAMERA.distance,
			z = tonumber(saved.z) or DOLL_CAMERA.z,
			portraitZoom = DOLL_CAMERA.portraitZoom,
		}
	end
	return DOLL_CAMERA
end

local function MakeColor(r, g, b, a)
	if type(CreateColor) == "function" then
		return CreateColor(r, g, b, a or 1)
	end
end

local function ApplyGradient(texture, orientation, c1, c2, fallbackR, fallbackG, fallbackB, fallbackA)
	texture:SetColorTexture(1, 1, 1, 1)
	if c1 and c2 and pcall(texture.SetGradient, texture, orientation, c1, c2) then
		return
	end
	texture:SetColorTexture(fallbackR, fallbackG, fallbackB, fallbackA or 1)
end

local function MakeLabel(parent, size, r, g, b)
	local line = parent:CreateFontString(nil, "OVERLAY")
	H.SetFont(line, FONT_BODY, size)
	line:SetTextColor(r, g, b)
	line:SetJustifyH("CENTER")
	line:SetWordWrap(false)
	line:Hide()
	return line
end

local function ApplyLabel(slot, unit)
	local nameOk, name = pcall(UnitName, unit)
	if nameOk then
		H.SetText(slot.name, name)
	else
		slot.name:SetText("")
	end

	local classOk, localized, classFile = pcall(UnitClass, unit)
	if not classOk then
		slot.class:SetText("")
		return
	end

	H.SetText(slot.class, localized)

	local color
	if classFile and not H.Sealed(classFile) and RAID_CLASS_COLORS then
		color = RAID_CLASS_COLORS[classFile]
	end
	if color and not H.Sealed(color.r) then
		slot.class:SetTextColor(color.r, color.g, color.b)
	else
		slot.class:SetTextColor(0.78, 0.71, 0.58)
	end
end

local function PoseModel(model, facing)
	local cam = Camera()
	pcall(function()
		model:SetPortraitZoom(cam.portraitZoom)
		model:SetCamDistanceScale(cam.distance)
		model:SetPosition(0, 0, cam.z)
		model:SetFacing(facing or 0)
	end)
end

local function AssignFacing(entries)
	local count = #entries
	for index = 1, count do
		local t = 0
		if count > 1 then
			t = ((index - 1) / (count - 1)) * 2 - 1
		end
		entries[index].facing = -t * LAYOUT.inwardFacing
	end
end

local function PoseUntilReady(slot, entry)
	local delays = { 0, 0.1, 0.25, 0.5, 1.0 }
	for _, delay in ipairs(delays) do
		C_Timer.After(delay, function()
			if frame:IsShown() and slot.key == entry.key and slot.model then
				PoseModel(slot.model, entry.facing or 0)
			end
		end)
	end
end

local function ApplyDollEntries(entries, force)
	AssignFacing(entries)
	for i = 1, H.MAX_SLOTS do
		local slot = slots[i]
		local entry = entries[i]
		if not entry then
			if slot.key then
				pcall(slot.model.ClearModel, slot.model)
			end
			slot.key = nil
			slot.frame:Hide()
			slot.name:Hide()
			slot.class:Hide()
			if slot.bubbleFrame then
				slot.bubbleFrame:Hide()
			end
		else
			slot.frame:Show()
			slot.name:Show()
			slot.class:Show()
			ApplyLabel(slot, entry.unit)
			if force or slot.key ~= entry.key then
				slot.key = entry.key
				local model = slot.model
				pcall(function()
					model:ClearModel()
					model:SetUnit(entry.unit)
				end)
				PoseModel(model, entry.facing or 0)
				PoseUntilReady(slot, entry)
			end
		end
	end
end

local function SlotOffset(index, count)
	local t = 0
	if count > 1 then
		t = ((index - 1) / (count - 1)) * 2 - 1
	end
	local span = math.min(3.3, 0.72 * math.max(count - 1, 1))
	local x = t * span
	-- Camera sits on negative Y. Larger Y is farther from the lens.
	local y = 0.7 * math.abs(t)
	local yaw = t * 0.22
	local center = math.floor((count + 1) / 2)
	local scale = (index == center) and 1.04 or 0.96
	return x, y, yaw, scale, t
end

local function PoseScene()
	if not scene then
		return
	end
	local cam = Camera()
	Try(scene, "SetCameraNearClip", 0.2)
	Try(scene, "SetCameraFarClip", 50)
	Try(scene, "SetCameraFieldOfView", 0.78)
	Try(scene, "SetCameraPosition", 0, -cam.distance, cam.z)
	Try(scene, "SetCameraOrientationByYawPitchRoll", 0, 0.04, 0)
	Try(scene, "SetAllowOverlappedModels", true)
	Try(scene, "SetPaused", false)
	Try(scene, "SetLightVisible", true)
	Try(scene, "SetLightAmbientColor", 0.4, 0.34, 0.3)
	Try(scene, "SetLightDiffuseColor", 1, 0.5, 0.2)
	Try(scene, "SetLightDirection", 0, 1, 0.35)
end

local function PlaceFire()
	if not fireActor or not fireLoaded then
		return
	end
	Try(fireActor, "Show")
	Try(fireActor, "SetScale", 1.3)
	Try(fireActor, "SetPosition", 0, -1.9, 0)
	Try(fireActor, "SetYaw", 0.35)
end

local function PlaceActor(index)
	local slot = slots[index]
	local count = #currentEntries
	if not slot or not slot.actor or index > count then
		return
	end
	local x, y, yaw, scale = SlotOffset(index, count)
	Try(slot.actor, "Show")
	Try(slot.actor, "SetScale", scale)
	Try(slot.actor, "SetPosition", x, y, 0)
	Try(slot.actor, "SetYaw", yaw)
	Try(slot.actor, "SetPitch", 0)
	Try(slot.actor, "SetRoll", 0)
end

local function LoadFire()
	if not fireActor or fireLoaded then
		return
	end
	local ok, success = Try(fireActor, "SetModelByFileID", CAMPFIRE_FILE, true)
	if not ok or success == false then
		ok, success = Try(fireActor, "SetModelByPath", CAMPFIRE_PATH, true)
	end
	fireLoaded = ok and success ~= false
	if fireLoaded then
		PlaceFire()
		Try(fireActor, "SetAnimation", 0)
		if fire then
			fire:Hide()
		end
	else
		Try(fireActor, "Hide")
		if fire then
			fire:Show()
		end
	end
end

local function SetActorUnit(actor, unit)
	local ok, success = Try(actor, "SetModelByUnit", unit, true, true, false, true)
	if ok and success ~= false then
		return true
	end
	ok, success = Try(actor, "SetModelByUnit", unit)
	return ok and success ~= false
end

local function PoseSceneUntilReady(index, key)
	local delays = { 0, 0.1, 0.25, 0.5, 1.0 }
	for _, delay in ipairs(delays) do
		C_Timer.After(delay, function()
			local slot = slots[index]
			if frame:IsShown() and slot and slot.key == key then
				PoseScene()
				PlaceActor(index)
				if not fireLoaded then
					LoadFire()
				else
					PlaceFire()
				end
			end
		end)
	end
end

local function ApplySceneEntries(entries, force)
	for i = 1, H.MAX_SLOTS do
		local slot = slots[i]
		local entry = entries[i]
		if not entry then
			slot.key = nil
			slot.name:Hide()
			slot.class:Hide()
			Try(slot.actor, "Hide")
		else
			slot.name:Show()
			slot.class:Show()
			ApplyLabel(slot, entry.unit)
			if force or slot.key ~= entry.key then
				slot.key = entry.key
				SetActorUnit(slot.actor, entry.unit)
				PoseSceneUntilReady(i, entry.key)
			end
			PlaceActor(i)
		end
	end
	LoadFire()
	PoseScene()
end

local function ApplyEntries(entries, force)
	currentEntries = entries or {}
	if sceneMode then
		ApplySceneEntries(currentEntries, force)
	else
		ApplyDollEntries(currentEntries, force)
	end
end

local function LayoutLabels()
	local width, height = frame:GetWidth(), frame:GetHeight()
	local count = #currentEntries
	if count < 1 then
		return
	end
	local span = width * 0.78
	local left = (width - span) / 2
	for i = 1, count do
		local slot = slots[i]
		local _, _, _, _, t = SlotOffset(i, count)
		local cx = left + ((t + 1) / 2) * span
		local feetY = height * 0.13
		slot.name:ClearAllPoints()
		slot.name:SetWidth(math.max(span / count, 80))
		slot.name:SetPoint("TOP", frame, "BOTTOMLEFT", cx, feetY)
		slot.class:ClearAllPoints()
		slot.class:SetWidth(math.max(span / count, 80))
		slot.class:SetPoint("TOP", slot.name, "BOTTOM", 0, -2)
	end
end

local LayoutFlatFire
local PositionChatEdit

local function FitBackdrop(width, height)
	if not backdrop or not width or width <= 0 or not height or height <= 0 then
		return
	end
	-- Cover the screen without stretching the painting.
	local imageAspect = BACKDROP_ASPECT
	local frameAspect = width / height
	backdrop:SetAllPoints()
	if frameAspect > imageAspect then
		local visible = imageAspect / frameAspect
		local inset = (1 - visible) / 2
		backdrop:SetTexCoord(0, 1, inset, 1 - inset)
	else
		local visible = frameAspect / imageAspect
		local inset = (1 - visible) / 2
		backdrop:SetTexCoord(inset, 1 - inset, 0, 1)
	end
end

local function LayoutDolls()
	local width, height = frame:GetWidth(), frame:GetHeight()
	if backdrop and backdrop:IsShown() then
		horizon:Hide()
		FitBackdrop(width, height)
		sky:SetHeight(height * 0.18)
		ApplyGradient(
			sky,
			"VERTICAL",
			MakeColor(0, 0, 0, 0),
			MakeColor(0, 0, 0, 0.55),
			0, 0, 0, 0
		)
	else
		sky:SetHeight(height * 0.34)
		ApplyGradient(
			sky,
			"VERTICAL",
			MakeColor(0, 0, 0, 0),
			MakeColor(0, 0, 0, 0.9),
			0, 0, 0, 0.35
		)
		horizon:Show()
		horizon:ClearAllPoints()
		horizon:SetSize(width * 0.46, 2)
		horizon:SetPoint("TOP", frame, "TOP", 0, -height * LAYOUT.skyFraction)
	end
	if groundFade then
		groundFade:Hide()
	end

	local count = #currentEntries
	local crown = 0
	if count > 0 then
		local slotH = height * LAYOUT.slotHeightFraction
		local slotW = slotH * LAYOUT.slotAspect
		local total = slotW * count
		local maxW = width * LAYOUT.maxWidthFraction
		if total > maxW then
			local shrink = maxW / total
			slotW = slotW * shrink
			slotH = slotH * shrink
		end

		local left = (width - slotW * count) / 2
		for i = 1, count do
			local slot = slots[i]
			local t = 0
			if count > 1 then
				t = ((i - 1) / (count - 1)) * 2 - 1
			end
			local inward = 1 - math.abs(t)
			local scale = LAYOUT.sideScale + (1 - LAYOUT.sideScale) * inward
			local lift = (1 - inward) * height * LAYOUT.sideLift
			local cx = left + (i - 0.5) * slotW
			local feetY = height * LAYOUT.feetFraction + lift
			local sw, sh = slotW * scale, slotH * scale

			slot.frame:ClearAllPoints()
			slot.frame:SetSize(sw, sh)
			slot.frame:SetPoint("BOTTOM", frame, "BOTTOMLEFT", cx, feetY)

			local above = feetY + sh * 0.78
			slot.class:ClearAllPoints()
			slot.class:SetWidth(math.max(sw, 90))
			slot.class:SetPoint("BOTTOM", frame, "BOTTOMLEFT", cx, above)

			slot.name:ClearAllPoints()
			slot.name:SetWidth(math.max(sw, 90))
			slot.name:SetPoint("BOTTOM", slot.class, "TOP", 0, 1)

			if slot.bubbleFrame then
				slot.bubbleFrame:ClearAllPoints()
				slot.bubbleFrame:SetPoint("LEFT", frame, "BOTTOMLEFT", cx + sw * 0.22, above + 8)
			end

			if above + 34 > crown then
				crown = above + 34
			end

			currentEntries[i].facing = -t * LAYOUT.inwardFacing
			if slot.model:IsShown() then
				pcall(slot.model.SetFacing, slot.model, currentEntries[i].facing)
			end
		end
	end

	if crown > 0 and #emoteButtons > 0 then
		local buttonW = 84
		local buttonH = 26
		local gap = 8
		local headerBottom = height - 160
		if timerText and timerText.GetBottom then
			local bottom = timerText:GetBottom()
			if type(bottom) == "number" and bottom > 0 then
				headerBottom = bottom
			end
		end
		local mid = (headerBottom + crown) / 2
		local buttonY = mid - buttonH / 2
		if buttonY < crown + 10 then
			buttonY = crown + 10
		end
		local rowW = #emoteButtons * buttonW + (#emoteButtons - 1) * gap
		local origin = -rowW / 2 + buttonW / 2
		for i, button in ipairs(emoteButtons) do
			button:SetSize(buttonW, buttonH)
			button:ClearAllPoints()
			button:SetPoint("BOTTOM", frame, "BOTTOM", origin + (i - 1) * (buttonW + gap), buttonY)
		end
	end

	LayoutFlatFire(height)
end

local function BackdropPlacement(u, v, uw, vh)
	local width, height = frame:GetWidth(), frame:GetHeight()
	local frameAspect = width / height
	local u0, u1, v0, v1 = 0, 1, 0, 1
	if frameAspect > BACKDROP_ASPECT then
		local visible = BACKDROP_ASPECT / frameAspect
		local inset = (1 - visible) / 2
		v0, v1 = inset, 1 - inset
	else
		local visible = frameAspect / BACKDROP_ASPECT
		local inset = (1 - visible) / 2
		u0, u1 = inset, 1 - inset
	end
	local spanU = u1 - u0
	local spanV = v1 - v0
	local x = ((u - u0) / spanU) * width
	local y = (1 - ((v - v0) / spanV)) * height
	return x, y, (uw / spanU) * width, (vh / spanV) * height
end

function LayoutFlatFire(height)
	if not height or height <= 0 then
		return
	end
	if backdrop and backdrop:IsShown() and backdropFile == BACKDROP_PATH then
		if fire then
			fire:Hide()
		end
		if fireModel and campfireModelOn then
			local x, y, pw, ph = BackdropPlacement(PAINTED_FIRE.u, PAINTED_FIRE.v, PAINTED_FIRE.w, PAINTED_FIRE.h)
			fireModel:SetSize(math.max(pw, 48), math.max(ph, 48))
			fireModel:ClearAllPoints()
			fireModel:SetPoint("CENTER", frame, "BOTTOMLEFT", x, y)
			fireModel:Show()
		elseif fireModel then
			fireModel:Hide()
		end
		return
	end
	if fireModel then
		local modelH = height * 0.36
		local modelW = modelH * 1.55
		fireModel:SetSize(modelW, modelH)
		fireModel:ClearAllPoints()
		fireModel:SetPoint("BOTTOM", frame, "BOTTOM", 0, height * 0.015)
	end
	if campfireModelOn then
		if fire then
			fire:Hide()
		end
		if fireModel then
			fireModel:Show()
		end
		return
	end
	if not fire then
		return
	end
	local fireH = height * 0.30
	local fireW = fireH * 1.45
	fire:SetSize(fireW, fireH)
	fire:ClearAllPoints()
	fire:SetPoint("BOTTOM", frame, "BOTTOM", 0, height * LAYOUT.feetFraction - fireH * 0.28)

	for i, spec in ipairs(FLAMES) do
		local flame = flames[i]
		flame.baseH = fireH * spec.h
		flame:SetSize(fireW * spec.w, flame.baseH)
		flame:ClearAllPoints()
		flame:SetPoint("BOTTOM", fire, "BOTTOM", fireW * spec.x, fireH * 0.20)
	end

	for i, ember in ipairs(embers) do
		ember.x0 = ((i - 4.5) / 8) * fireW * 0.35
	end

	glow:SetSize(fireW * 0.9, fireH * 0.42)
	glow:ClearAllPoints()
	glow:SetPoint("CENTER", fire, "BOTTOM", 0, fireH * 0.22)
end

local function TextureAccepted(texture, asset)
	local ok = pcall(texture.SetTexture, texture, asset)
	if not ok or not texture:GetTexture() then
		return false
	end
	return true
end

local function ShowBackdrop()
	if not backdrop then
		return false
	end
	local asset = BACKDROP_PATH
	if not TextureAccepted(backdrop, asset) then
		asset = BACKDROP_FALLBACK
		if not TextureAccepted(backdrop, asset) then
			backdrop:Hide()
			if dimmer then
				dimmer:Hide()
			end
			return false
		end
	end
	backdrop:SetVertexColor(1, 1, 1, 1)
	backdrop:Show()
	if dimmer then
		dimmer:Hide()
	end
	backdropFile = asset
	return true
end

local function LayoutScene()
	local width, height = frame:GetWidth(), frame:GetHeight()
	sky:SetHeight(height * 0.46)
	ApplyGradient(
		sky,
		"VERTICAL",
		MakeColor(0, 0, 0, 0),
		MakeColor(0, 0, 0, 0.88),
		0, 0, 0, 0.55
	)
	horizon:Hide()
	if groundFade then
		groundFade:Show()
		groundFade:ClearAllPoints()
		groundFade:SetPoint("BOTTOMLEFT")
		groundFade:SetPoint("BOTTOMRIGHT")
		groundFade:SetHeight(height * 0.34)
		ApplyGradient(
			groundFade,
			"VERTICAL",
			MakeColor(0, 0, 0, 0.72),
			MakeColor(0, 0, 0, 0),
			0, 0, 0, 0.35
		)
	end
	if fire and not fireLoaded then
		fire:Show()
		LayoutFlatFire(height)
	end
	LayoutLabels()
	PoseScene()
	for i = 1, #currentEntries do
		PlaceActor(i)
	end
	PlaceFire()
end

local function Layout()
	local width, height = frame:GetWidth(), frame:GetHeight()
	if not width or width <= 0 or not height or height <= 0 then
		return
	end
	if sceneMode then
		LayoutScene()
	else
		LayoutDolls()
	end
	if liftedEdit and liftedEdit:IsShown() then
		PositionChatEdit(liftedEdit)
	end
end

local function UpdateTimer()
	if type(expiresAt) == "number" then
		local ok, remain = pcall(function()
			return expiresAt - GetTime()
		end)
		if ok and type(remain) == "number" then
			local seconds = math.max(0, math.floor(remain + 0.5))
			if seconds == 1 then
				timerText:SetText("1 second remaining")
			else
				timerText:SetText(seconds .. " seconds remaining")
			end
			if seconds <= 10 then
				timerText:SetTextColor(1, 0.86, 0.48)
			else
				timerText:SetTextColor(0.94, 0.78, 0.42)
			end
			timerText:Show()
			return
		end
	end

	if staticTimer ~= "" then
		timerText:SetText(staticTimer)
		timerText:SetTextColor(0.94, 0.78, 0.42)
		timerText:Show()
	else
		timerText:SetText("")
		timerText:Hide()
	end
end

local function FlickerFire(elapsed)
	if not fire or not fire:IsShown() then
		return
	end
	local now = GetTime()
	for i, flame in ipairs(flames) do
		local spec = FLAMES[i]
		local wave = 0.86 + 0.14 * math.sin(now * (6 + i * 0.35) + spec.phase)
		if flame.baseH then
			flame:SetHeight(flame.baseH * wave)
		end
	end
	glow:SetAlpha(0.38 + 0.1 * math.sin(now * 2.6))

	local _, fireH = fire:GetSize()
	for _, ember in ipairs(embers) do
		ember.life = (ember.life or 0) + elapsed * ember.speed
		if ember.life > 1 then
			ember.life = ember.life - 1
		end
		local rise = (fireH or 200) * 0.62 * ember.life
		local drift = math.sin(ember.life * 8 + ember.phase) * 12
		ember.tex:ClearAllPoints()
		ember.tex:SetPoint("CENTER", fire, "BOTTOM", (ember.x0 or 0) + drift, 24 + rise)
		ember.tex:SetAlpha((1 - ember.life) * 0.85)
	end
end

local function FlickerSceneLight()
	if not scene or not fireLoaded then
		return
	end
	local wave = 0.86 + 0.14 * math.sin(GetTime() * 6.2)
	Try(scene, "SetLightDiffuseColor", wave, 0.46 * wave, 0.16 * wave)
end

local function BuildFire(parent)
	fire = CreateFrame("Frame", nil, parent)
	fire:SetFrameLevel(220)
	fire:Hide()

	glow = fire:CreateTexture(nil, "ARTWORK")
	glow:SetBlendMode("ADD")
	ApplyGradient(
		glow,
		"VERTICAL",
		MakeColor(1, 0.28, 0.02, 0),
		MakeColor(1, 0.55, 0.12, 0.55),
		1, 0.4, 0.08, 0.35
	)

	for i, spec in ipairs(FLAMES) do
		local flame = fire:CreateTexture(nil, "OVERLAY")
		flame:SetBlendMode("ADD")
		ApplyGradient(
			flame,
			"VERTICAL",
			MakeColor(1, 0.28, 0.02, 0.95),
			MakeColor(1, 0.92, 0.45, 0),
			1, 0.45, 0.08, 0.85
		)
		flame.phase = spec.phase
		flames[i] = flame
	end

	local logSpecs = {
		{ rot = 0.42, y = 0.16, w = 0.46 },
		{ rot = -0.38, y = 0.15, w = 0.42 },
		{ rot = 0.04, y = 0.13, w = 0.34 },
	}
	for _, spec in ipairs(logSpecs) do
		local log = fire:CreateTexture(nil, "ARTWORK", nil, 2)
		log:SetColorTexture(0.16, 0.07, 0.03, 1)
		log:SetHeight(8)
		pcall(log.SetRotation, log, spec.rot)
		log.layout = spec
		log:SetPoint("BOTTOM", fire, "BOTTOM", 0, 0)
	end

	fire:SetScript("OnSizeChanged", function(self, w, h)
		for _, region in ipairs({ self:GetRegions() }) do
			if region.layout then
				region:SetSize(w * region.layout.w, math.max(6, h * 0.045))
				region:ClearAllPoints()
				region:SetPoint("CENTER", self, "BOTTOM", 0, h * region.layout.y)
			end
		end
	end)

	for i = 1, 8 do
		local tex = fire:CreateTexture(nil, "OVERLAY", nil, 3)
		tex:SetColorTexture(1, 0.82, 0.35, 1)
		tex:SetSize(i % 3 == 0 and 3 or 2, i % 3 == 0 and 3 or 2)
		tex:SetBlendMode("ADD")
		embers[i] = {
			tex = tex,
			life = (i - 1) / 8,
			speed = 0.22 + (i % 4) * 0.05,
			phase = i * 0.9,
		}
	end
end

local function BuildDollSlot(parent, textParent, index)
	local slotFrame = CreateFrame("Frame", nil, parent)
	slotFrame:SetFrameLevel(210)
	slotFrame:EnableMouse(false)

	local model = CreateFrame("PlayerModel", nil, slotFrame)
	model:SetAllPoints()
	model:EnableMouse(false)
	if model.SetKeepModelOnHide then
		pcall(model.SetKeepModelOnHide, model, false)
	end

	slots[index] = {
		frame = slotFrame,
		model = model,
		name = MakeLabel(textParent, 16, 0.95, 0.82, 0.48),
		class = MakeLabel(textParent, 13, 0.78, 0.71, 0.58),
		key = nil,
	}

	local bubbleFrame = CreateFrame("Frame", nil, parent)
	bubbleFrame:SetSize(220, 48)
	bubbleFrame:SetFrameLevel(340)
	bubbleFrame:EnableMouse(false)
	bubbleFrame:Hide()
	local bubbleBg = bubbleFrame:CreateTexture(nil, "BACKGROUND")
	bubbleBg:SetAllPoints()
	bubbleBg:SetColorTexture(0.06, 0.035, 0.02, 0.9)
	local tail = bubbleFrame:CreateTexture(nil, "BORDER")
	tail:SetSize(12, 12)
	tail:SetColorTexture(0.06, 0.035, 0.02, 0.9)
	tail:SetPoint("RIGHT", bubbleFrame, "LEFT", 6, -8)
	pcall(tail.SetRotation, tail, math.rad(45))
	local bubble = bubbleFrame:CreateFontString(nil, "OVERLAY")
	H.SetFont(bubble, FONT_BODY, 13)
	bubble:SetTextColor(0.96, 0.91, 0.78)
	bubble:SetJustifyH("CENTER")
	bubble:SetJustifyV("MIDDLE")
	bubble:SetWordWrap(true)
	bubble:SetPoint("TOPLEFT", 8, -6)
	bubble:SetPoint("BOTTOMRIGHT", -8, 6)
	slots[index].bubbleFrame = bubbleFrame
	slots[index].bubble = bubble
	slotFrame:Hide()
end

local function BuildScene(parent, textParent)
	local ok, widget = pcall(CreateFrame, "ModelScene", nil, parent)
	if not ok or not widget then
		return false
	end

	scene = widget
	scene:SetAllPoints()
	scene:SetFrameLevel(210)
	scene:EnableMouse(false)
	Try(scene, "EnableMouseWheel", false)

	for i = 1, H.MAX_SLOTS do
		local actorOk, actor = pcall(scene.CreateActor, scene)
		if not actorOk or not actor then
			scene:Hide()
			scene = nil
			for n = 1, i do
				slots[n] = nil
			end
			return false
		end
		slots[i] = {
			actor = actor,
			name = MakeLabel(textParent, 16, 0.95, 0.82, 0.48),
			class = MakeLabel(textParent, 13, 0.78, 0.71, 0.58),
			key = nil,
		}
	end

	local fireOk, actor = pcall(scene.CreateActor, scene)
	if not fireOk or not actor then
		scene:Hide()
		scene = nil
		return false
	end
	fireActor = actor
	return true
end

local FONT_CINZEL = "Interface\\AddOns\\" .. H.NAME .. "\\Fonts\\CinzelDecorative-Regular.ttf"
local chatLines = {}
local chatText
local chatPrompt
local chatEntry
local chatPlaceholder
local chatFont
local chatSending = false
local lastChatLine
local pendingEcho
local pendingEchoAt
local pendingToken
local chatHooked = false
local liftedEdit
local savedParent
local savedPoints
local savedStrata
local savedLevel
local fontPanel
local fontRows = {}
local fontOffset = 0
local FONT_PAGE = 12

local EMOTE_ANIMS = {
	WAVE = 67,
	YES = 185,
	BOW = 66,
	CHEER = 68,
	LAUGH = 70,
}

local function NameMatches(unit, speaker)
	if type(speaker) ~= "string" or H.Sealed(speaker) then
		return false
	end
	local ok, name, realm = pcall(UnitName, unit)
	if not ok or type(name) ~= "string" or H.Sealed(name) then
		return false
	end
	if speaker == name then
		return true
	end
	local short = speaker:match("^([^%-]+)")
	if short == name then
		return true
	end
	if type(realm) == "string" and realm ~= "" and not H.Sealed(realm) then
		return speaker == (name .. "-" .. realm)
	end
	return false
end

local function TickBubbles()
	local now = GetTime()
	for i = 1, H.MAX_SLOTS do
		local slot = slots[i]
		if slot and slot.bubbleFrame and slot.bubbleFrame:IsShown() and now > (slot.bubbleUntil or 0) then
			slot.bubbleFrame:Hide()
		end
	end
end

local function ShowBubble(slot, text)
	if not slot or not slot.bubble or not slot.bubbleFrame then
		return
	end
	H.SetText(slot.bubble, text)
	slot.bubbleUntil = GetTime() + 8
	slot.bubbleFrame:Show()
	slot.bubbleFrame:Raise()
end

local function RefreshChatLog()
	if not chatText then
		return
	end
	H.SetText(chatText, table.concat(chatLines, "\n"))
	local panel = chatText:GetParent()
	if GameChatWanted() then
		if panel then
			panel:Hide()
		end
		return
	end
	if panel and #chatLines > 0 then
		panel:Show()
	end
end

local function AppendChatLine(line)
	if line == lastChatLine then
		return
	end
	if #chatLines > 0 and chatLines[#chatLines] == line then
		return
	end
	lastChatLine = line
	chatLines[#chatLines + 1] = line
	while #chatLines > 5 do
		table.remove(chatLines, 1)
	end
	RefreshChatLog()
end

local function ReplaceChatLine(line)
	if #chatLines > 0 then
		chatLines[#chatLines] = line
	else
		chatLines[1] = line
	end
	lastChatLine = line
	RefreshChatLog()
end

local function ShowChat(speaker, text, fromPlayer)
	if type(speaker) ~= "string" or type(text) ~= "string" then
		return
	end
	if H.Sealed(speaker) or H.Sealed(text) then
		return
	end
	if #text > 140 then
		text = text:sub(1, 137) .. "..."
	end
	local echoed = not fromPlayer and pendingEcho == text and pendingEchoAt and (GetTime() - pendingEchoAt) < 3
	if echoed then
		pendingEcho = nil
		pendingEchoAt = nil
		pendingToken = nil
	end
	local line = (speaker:match("^([^%-]+)") or speaker) .. ": " .. text
	if fromPlayer then
		-- The chat echo carries the name other players see. Hold the log for that.
	elseif echoed and #chatLines > 0 and chatLines[#chatLines]:sub(-(#text + 2)) == (": " .. text) then
		ReplaceChatLine(line)
	else
		AppendChatLine(line)
	end
	for i, entry in ipairs(currentEntries) do
		local mine = (fromPlayer or echoed) and (entry.unit == "player" or H.SafeTrue(UnitIsUnit, entry.unit, "player"))
		if mine or NameMatches(entry.unit, speaker) then
			ShowBubble(slots[i], text)
		end
	end
end

local function AnimateSlot(index, anim)
	local slot = slots[index]
	local entry = currentEntries[index]
	local model = slot and slot.model
	if not model or not entry then
		return
	end
	pcall(model.SetAnimation, model, anim)
	local key = slot.key
	C_Timer.After(3, function()
		if not frame:IsShown() or slot.key ~= key then
			return
		end
		pcall(function()
			model:ClearModel()
			model:SetUnit(entry.unit)
		end)
		PoseModel(model, entry.facing or 0)
	end)
end

local function PlayToken(token, speaker)
	local anim = EMOTE_ANIMS[token]
	if not anim then
		return
	end
	for i, entry in ipairs(currentEntries) do
		local play = false
		if speaker then
			play = NameMatches(entry.unit, speaker)
		else
			play = entry.unit == "player" or H.SafeTrue(UnitIsUnit, entry.unit, "player")
		end
		if play then
			AnimateSlot(i, anim)
		end
	end
end

local function ChosenFont()
	local saved = CampfireHangoutDB
	if type(saved) == "table" and type(saved.fontPath) == "string" and saved.fontPath ~= "" then
		return saved.fontPath, saved.fontName or "Custom"
	end
	return FONT_CINZEL, "Cinzel Decorative"
end

local function ApplyChosenFont()
	local path = ChosenFont()
	if titleText then
		H.SetFont(titleText, path, 34)
	end
	if subtitleText then
		H.SetFont(subtitleText, path, 18)
	end
	if timerText then
		H.SetFont(timerText, path, 20)
	end
	for i = 1, H.MAX_SLOTS do
		local slot = slots[i]
		if slot and slot.name then
			H.SetFont(slot.name, path, 15)
		end
		if slot and slot.bubble then
			H.SetFont(slot.bubble, path, 13)
		end
	end
end

local function AddFont(list, seen, name, path)
	if type(name) ~= "string" or name == "" then
		return
	end
	if type(path) ~= "string" or path == "" then
		return
	end
	local key = name:lower()
	if seen[key] then
		return
	end
	seen[key] = true
	list[#list + 1] = { name = name, path = path }
end

local function SharedMediaLib()
	if C_AddOns and C_AddOns.LoadAddOn then
		pcall(C_AddOns.LoadAddOn, "LibSharedMedia-3.0")
	elseif type(LoadAddOn) == "function" then
		pcall(LoadAddOn, "LibSharedMedia-3.0")
	end
	if LibStub == nil then
		return nil
	end
	local function Try(major)
		if type(LibStub.GetLibrary) == "function" then
			local ok, lib = pcall(LibStub.GetLibrary, LibStub, major, true)
			if ok and lib then
				return lib
			end
		end
		local ok, lib = pcall(function()
			return LibStub(major, true)
		end)
		if ok and lib then
			return lib
		end
	end
	return Try("LibSharedMedia-3.0") or Try("LibSharedMedia-2.0")
end

local function SharedMediaFontType(lib)
	if type(lib.MediaType) == "table" and type(lib.MediaType.FONT) == "string" then
		return lib.MediaType.FONT
	end
	return "font"
end

local function CollectSharedMedia(list, seen, lib)
	local mediaType = SharedMediaFontType(lib)
	if type(lib.HashTable) == "function" then
		local ok, hash = pcall(lib.HashTable, lib, mediaType)
		if ok and type(hash) == "table" then
			for name, path in pairs(hash) do
				AddFont(list, seen, name, path)
			end
		end
	end
	if type(lib.MediaTable) == "table" and type(lib.MediaTable[mediaType]) == "table" then
		for name, path in pairs(lib.MediaTable[mediaType]) do
			AddFont(list, seen, name, path)
		end
	end
	if type(lib.List) ~= "function" or type(lib.Fetch) ~= "function" then
		return
	end
	local listOk, names = pcall(lib.List, lib, mediaType)
	if not listOk or type(names) ~= "table" then
		return
	end
	if names[1] ~= nil then
		for _, name in ipairs(names) do
			local pathOk, path = pcall(lib.Fetch, lib, mediaType, name, true)
			if pathOk then
				AddFont(list, seen, name, path)
			end
		end
	else
		for name, path in pairs(names) do
			if type(path) ~= "string" then
				local pathOk, fetched = pcall(lib.Fetch, lib, mediaType, name, true)
				path = pathOk and fetched or nil
			end
			AddFont(list, seen, name, path)
		end
	end
end

local function FontCatalog()
	local list = {}
	local seen = {}
	AddFont(list, seen, "Cinzel Decorative", FONT_CINZEL)
	AddFont(list, seen, "Morpheus", "Fonts\\MORPHEUS.TTF")
	AddFont(list, seen, "Friz Quadrata", "Fonts\\FRIZQT__.TTF")
	AddFont(list, seen, "Arial Narrow", "Fonts\\ARIALN.TTF")
	AddFont(list, seen, "Skurri", "Fonts\\skurri.ttf")
	if type(LibStub) == "table" or type(LibStub) == "function" then
		local lib = SharedMediaLib()
		if lib then
			CollectSharedMedia(list, seen, lib)
		end
	end
	table.sort(list, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	return list
end

local function RefreshFontPanel()
	if not fontPanel then
		return
	end
	local list = FontCatalog()
	local maxOffset = math.max(0, #list - FONT_PAGE)
	if fontOffset > maxOffset then
		fontOffset = maxOffset
	end
	if fontOffset < 0 then
		fontOffset = 0
	end
	for row = 1, FONT_PAGE do
		local item = list[fontOffset + row]
		local button = fontRows[row]
		if item and button then
			button.item = item
			button.label:SetText(item.name)
			H.SetFont(button.label, item.path, 13)
			button:Show()
		elseif button then
			button.item = nil
			button:Hide()
		end
	end
end

local function SelectFont(query)
	local list = FontCatalog()
	local q = (query or ""):lower()
	local match
	local partial = {}
	for _, item in ipairs(list) do
		if item.name:lower() == q then
			match = item
			break
		end
		if q ~= "" and item.name:lower():find(q, 1, true) then
			partial[#partial + 1] = item
		end
	end
	if not match and #partial == 1 then
		match = partial[1]
	end
	if not match then
		H.Print("No matching font. /cfh font list, or Options, AddOns, Campfire Hangout.")
		return
	end
	if type(CampfireHangoutDB) ~= "table" then
		CampfireHangoutDB = {}
	end
	CampfireHangoutDB.fontName = match.name
	CampfireHangoutDB.fontPath = match.path
	ApplyChosenFont()
	H.Print("Font set to " .. match.name .. ".")
end

local function PrintFonts()
	local list = FontCatalog()
	local _, current = ChosenFont()
	H.Print("Current font: " .. tostring(current) .. ". /cfh font <name>")
	local buffer = {}
	for i, item in ipairs(list) do
		buffer[#buffer + 1] = item.name
		if #buffer == 6 then
			H.Print(table.concat(buffer, ", "))
			buffer = {}
		end
		if i >= 36 then
			H.Print("More fonts are under Options, AddOns, Campfire Hangout.")
			break
		end
	end
	if #buffer > 0 then
		H.Print(table.concat(buffer, ", "))
	end
end

local function ToggleFonts()
	if not fontPanel then
		return
	end
	if fontPanel:IsShown() then
		fontPanel:Hide()
		return
	end
	fontOffset = 0
	RefreshFontPanel()
	fontPanel:Show()
end

local function MakeGoldButton(parent, label, onClick)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(84, 26)
	button:RegisterForClicks("LeftButtonUp")
	local bg = button:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.09, 0.05, 0.025, 0.88)
	local text = button:CreateFontString(nil, "OVERLAY")
	H.SetFont(text, FONT_BODY, 14)
	text:SetTextColor(0.95, 0.82, 0.48)
	text:SetPoint("CENTER")
	text:SetText(label)
	button.label = text
	button:SetScript("OnClick", onClick)
	button:SetScript("OnEnter", function()
		bg:SetColorTexture(0.22, 0.13, 0.05, 0.95)
	end)
	button:SetScript("OnLeave", function()
		bg:SetColorTexture(0.09, 0.05, 0.025, 0.88)
	end)
	return button
end

local function PoseCampfire()
	if not fireModel then
		return
	end
	pcall(function()
		fireModel:SetPortraitZoom(0)
		fireModel:SetCamDistanceScale(1.05)
		fireModel:SetPosition(0, 0, -0.2)
		fireModel:SetFacing(0.55)
	end)
end

local function LoadCampfire()
	if not frame then
		return
	end
	if not fireModel then
		fireModel = CreateFrame("PlayerModel", nil, frame)
		fireModel:SetFrameLevel(218)
		fireModel:EnableMouse(false)
		if fireModel.SetKeepModelOnHide then
			pcall(fireModel.SetKeepModelOnHide, fireModel, true)
		end
		fireModel:Hide()
	end
	if campfireModelOn then
		fireModel:Show()
		if fire then
			fire:Hide()
		end
		PoseCampfire()
		return
	end

	local loaded = false
	if type(fireModel.SetModel) == "function" then
		local ok, success = pcall(fireModel.SetModel, fireModel, CAMPFIRE_FILE)
		loaded = ok and success ~= false
		if not loaded then
			ok, success = pcall(fireModel.SetModel, fireModel, CAMPFIRE_PATH)
			loaded = ok and success ~= false
		end
	end
	if loaded then
		campfireModelOn = true
		fireModel:Show()
		PoseCampfire()
		pcall(fireModel.SetAnimation, fireModel, 0)
		if fire then
			fire:Hide()
		end
		for _, delay in ipairs({ 0.1, 0.25, 0.5, 1 }) do
			C_Timer.After(delay, function()
				if frame:IsShown() and campfireModelOn then
					PoseCampfire()
				end
			end)
		end
	else
		fireModel:Hide()
		if fire then
			fire:Show()
		end
	end
end

function PositionChatEdit(edit)
	local width = frame:GetWidth()
	if not width or width <= 0 then
		width = 400
	end
	edit:ClearAllPoints()
	edit:SetWidth(math.min(420, math.max(240, width * 0.28)))
	edit:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 12)
	edit:SetAlpha(1)
	pcall(edit.SetClampedToScreen, edit, true)
end

local function RestoreChatEdit()
	local edit = liftedEdit
	if not edit then
		return
	end
	liftedEdit = nil
	edit:SetParent(savedParent or UIParent)
	if savedStrata then
		edit:SetFrameStrata(savedStrata)
	end
	if savedLevel then
		edit:SetFrameLevel(savedLevel)
	end
	edit:ClearAllPoints()
	if savedPoints then
		for i = 1, #savedPoints do
			local point, relativeTo, relativePoint, x, y = savedPoints[i][1], savedPoints[i][2], savedPoints[i][3], savedPoints[i][4], savedPoints[i][5]
			if relativeTo then
				edit:SetPoint(point, relativeTo, relativePoint, x, y)
			else
				edit:SetPoint(point, UIParent, relativePoint, x, y)
			end
		end
	end
	savedParent, savedPoints, savedStrata, savedLevel = nil, nil, nil, nil
	if chatPrompt and frame and frame:IsShown() then
		chatPrompt:Show()
	end
end

local function LiftChatEdit(edit)
	if not frame or not frame:IsShown() or not edit then
		return
	end
	if liftedEdit and liftedEdit ~= edit then
		RestoreChatEdit()
	end
	if liftedEdit ~= edit then
		savedParent = edit:GetParent()
		savedStrata = edit:GetFrameStrata()
		savedLevel = edit:GetFrameLevel()
		savedPoints = {}
		for i = 1, edit:GetNumPoints() do
			savedPoints[i] = { edit:GetPoint(i) }
		end
		liftedEdit = edit
		edit:SetParent(frame)
		edit:SetFrameStrata("FULLSCREEN_DIALOG")
		edit:SetFrameLevel(320)
	end
	PositionChatEdit(edit)
	if chatPrompt then
		chatPrompt:Hide()
	end
end

local function UpdateChatPlaceholder()
	if not chatPlaceholder or not chatEntry then
		return
	end
	local empty = chatEntry:GetText() == ""
	local focused = chatEntry.HasFocus and chatEntry:HasFocus()
	if empty and not focused then
		chatPlaceholder:Show()
	else
		chatPlaceholder:Hide()
	end
end

local function SendChatLine(text)
	if type(text) ~= "string" then
		return
	end
	text = text:match("^%s*(.-)%s*$") or ""
	if text == "" then
		return
	end
	local slash = text:sub(1, 1) == "/"
	if not slash then
		pendingEcho = text
		if #pendingEcho > 140 then
			pendingEcho = pendingEcho:sub(1, 137) .. "..."
		end
		pendingEchoAt = GetTime()
	end
	local edit = ChatFrame1EditBox
	local sent = false
	if slash and edit and type(ChatEdit_ParseText) == "function" then
		chatSending = true
		edit:SetText(text)
		sent = pcall(ChatEdit_ParseText, edit, 1)
		edit:SetText("")
		if edit:IsShown() then
			edit:Hide()
		end
		chatSending = false
	end
	if not sent then
		if C_ChatInfo and type(C_ChatInfo.SendChatMessage) == "function" then
			sent = pcall(C_ChatInfo.SendChatMessage, text, "SAY")
		end
		if not sent and type(SendChatMessage) == "function" then
			pcall(SendChatMessage, text, "SAY")
		end
	end
	if not slash then
		local name = "You"
		local ok, unitName = pcall(UnitName, "player")
		if ok and type(unitName) == "string" and unitName ~= "" and not H.Sealed(unitName) then
			name = unitName
		end
		local token = {}
		pendingToken = token
		local spoken = pendingEcho or text
		ShowChat(name, text, true)
		C_Timer.After(1, function()
			if pendingToken ~= token or pendingEcho ~= spoken then
				return
			end
			pendingToken = nil
			pendingEcho = nil
			pendingEchoAt = nil
			AppendChatLine(name .. ": " .. spoken)
		end)
	end
end

local function SubmitChatEntry(edit)
	if chatSending or not edit then
		return
	end
	local text = edit:GetText() or ""
	text = text:match("^%s*(.-)%s*$") or ""
	if text == "" then
		return
	end
	edit:SetText("")
	SendChatLine(text)
	UpdateChatPlaceholder()
end

local function ChatEntryFont()
	if not chatFont then
		chatFont = _G.CampfireHangoutChatFont or CreateFont("CampfireHangoutChatFont")
	end
	if not chatFont then
		return nil
	end
	chatFont:SetFont(FONT_BODY, 15, "")
	if not chatFont:GetFont() then
		chatFont:SetFont("Fonts\\FRIZQT__.TTF", 15, "")
	end
	chatFont:SetTextColor(0.96, 0.9, 0.75)
	chatFont:SetShadowColor(0, 0, 0, 1)
	chatFont:SetShadowOffset(1, -1)
	return chatFont
end

local function ApplyChatEntryFont()
	if not chatEntry then
		return
	end
	local font = ChatEntryFont()
	if font and font:GetFont() then
		chatEntry:SetFontObject(font)
	elseif ChatFontNormal then
		chatEntry:SetFontObject(ChatFontNormal)
	end
	chatEntry:SetTextColor(0.96, 0.9, 0.75)
end

local function BlizzardChatBoxes()
	local list = {}
	local seen = {}
	local function add(edit)
		if edit and edit ~= chatEntry and not seen[edit] then
			seen[edit] = true
			list[#list + 1] = edit
		end
	end
	add(ACTIVE_CHAT_EDIT_BOX)
	add(ChatFrame1EditBox)
	return list
end

local function TakeBlizzardChat()
	if chatSending or not chatEntry then
		return false
	end
	local took = false
	for _, edit in ipairs(BlizzardChatBoxes()) do
		local shown = edit.IsShown and edit:IsShown()
		local focused = edit.HasFocus and edit:HasFocus()
		if shown or focused then
			local ok, text = pcall(edit.GetText, edit)
			if ok and type(text) == "string" and text ~= "" and not H.Sealed(text) then
				local current = chatEntry:GetText() or ""
				if current == "" or #text > #current then
					chatEntry:SetText(text)
					pcall(chatEntry.SetCursorPosition, chatEntry, #text)
				end
				pcall(edit.SetText, edit, "")
			end
			pcall(edit.ClearFocus, edit)
			if shown then
				edit:Hide()
			end
			took = true
		end
	end
	return took
end

local function FocusChatEntry()
	if chatSending or not frame or not frame:IsShown() or not chatEntry then
		return
	end
	ApplyChatEntryFont()
	TakeBlizzardChat()
	chatEntry:SetFocus()
	UpdateChatPlaceholder()
end

local raisedChat = {}
local chatHost
local PlaceHangoutEntry

local function GameChatWanted()
	local saved = CampfireHangoutDB
	return type(saved) == "table" and saved.showGameChat == true and frame and frame:IsShown()
end

local function RestorePoints(widget, points)
	widget:ClearAllPoints()
	for i = 1, #points do
		local point, relativeTo, relativePoint, x, y = points[i][1], points[i][2], points[i][3], points[i][4], points[i][5]
		if relativeTo then
			widget:SetPoint(point, relativeTo, relativePoint, x, y)
		else
			widget:SetPoint(point, UIParent, relativePoint or "CENTER", x or 0, y or 0)
		end
	end
end

local function RestoreGameChat()
	local pending = raisedChat
	raisedChat = {}
	for widget, saved in pairs(pending) do
		pcall(function()
			widget:SetParent(saved.parent or UIParent)
			if saved.strata then
				widget:SetFrameStrata(saved.strata)
			end
			if type(saved.level) == "number" then
				widget:SetFrameLevel(saved.level)
			end
			if saved.points then
				RestorePoints(widget, saved.points)
			end
			if saved.shown == false and widget.Hide then
				widget:Hide()
			end
		end)
	end
	if PlaceHangoutEntry then
		PlaceHangoutEntry()
	end
end

local function Outermost(widget)
	local current = widget
	while current do
		local parent = current:GetParent()
		if not parent or parent == UIParent or parent == chatHost or parent == frame then
			return current
		end
		current = parent
	end
	return widget
end

local function LiftWidget(widget, direct, levelOffset)
	if not widget or not chatHost or not widget.GetFrameLevel or not widget.SetParent or not widget.SetFrameStrata then
		return
	end
	if not direct then
		widget = Outermost(widget)
	end
	if not widget or widget == frame or widget == UIParent or widget == chatHost then
		return
	end
	if raisedChat[widget] and widget:GetParent() == chatHost then
		pcall(widget.SetFrameLevel, widget, (chatHost:GetFrameLevel() or 200) + (levelOffset or 10))
		return
	end
	local points = {}
	local count = widget.GetNumPoints and widget:GetNumPoints() or 0
	for i = 1, count do
		points[i] = { widget:GetPoint(i) }
	end
	if not raisedChat[widget] then
		raisedChat[widget] = {
			parent = widget:GetParent(),
			strata = widget:GetFrameStrata(),
			level = widget:GetFrameLevel(),
			points = points,
			shown = widget.IsShown and widget:IsShown() or false,
		}
	end
	local saved = raisedChat[widget]
	local ok = pcall(function()
		widget:SetParent(chatHost)
		widget:SetFrameStrata("TOOLTIP")
		widget:SetFrameLevel((chatHost:GetFrameLevel() or 200) + (levelOffset or 10))
		if widget.EnableMouse then
			widget:EnableMouse(true)
		end
		if saved.points and #saved.points > 0 then
			RestorePoints(widget, saved.points)
		end
	end)
	if not ok then
		raisedChat[widget] = nil
		pcall(widget.SetFrameStrata, widget, "TOOLTIP")
	end
end

local customChat
local customChatTries = 0
local nextEditScan = 0

local function AddonLoaded(name)
	if C_AddOns and C_AddOns.IsAddOnLoaded then
		local ok, loaded = pcall(C_AddOns.IsAddOnLoaded, name)
		if ok and loaded then
			return true
		end
	end
	if type(IsAddOnLoaded) == "function" then
		local ok, loaded = pcall(IsAddOnLoaded, name)
		return ok and loaded
	end
	return false
end

local function ReplacementAddon()
	return AddonLoaded("Chattynator") or AddonLoaded("ElvUI")
end

local function FrameName(widget)
	if not widget or not widget.GetName then
		return ""
	end
	local ok, name = pcall(widget.GetName, widget)
	if ok and type(name) == "string" then
		return name
	end
	return ""
end

local function LooksLikeCustomChat(widget)
	if not widget or widget == frame or widget == chatHost or widget == chatPrompt or widget == chatEntry then
		return false
	end
	if not widget.IsShown or not widget:IsShown() then
		return false
	end
	local name = FrameName(widget)
	if name:match("^ChatFrame%d") or name == "GeneralDockManager" or name:find("HyperlinkHandler", 1, true) then
		return false
	end
	if type(widget.ScrollingMessages) == "table" then
		return true
	end
	if name:find("Chattynator", 1, true) or name:find("ElvUI_Chat", 1, true) then
		local w = widget.GetWidth and widget:GetWidth()
		local h = widget.GetHeight and widget:GetHeight()
		return type(w) == "number" and w > 180 and type(h) == "number" and h > 80
	end
	return false
end

local function FindCustomChat()
	if customChat and customChat.GetParent and customChat:GetParent() then
		return customChat
	end
	if customChatTries > 20 or type(EnumerateFrames) ~= "function" then
		return nil
	end
	customChatTries = customChatTries + 1
	local current = EnumerateFrames()
	local guard = 0
	while current and guard < 6000 do
		guard = guard + 1
		if LooksLikeCustomChat(current) then
			customChat = current
			return current
		end
		current = EnumerateFrames(current)
	end
	return nil
end

local function IsChatEdit(edit)
	if not edit or edit == chatEntry or edit == chatPrompt then
		return false
	end
	if not edit.GetObjectType or edit:GetObjectType() ~= "EditBox" then
		return false
	end
	local name = FrameName(edit)
	if name:find("Wardrobe", 1, true) or name:find("CustomSet", 1, true) then
		return false
	end
	if edit == ACTIVE_CHAT_EDIT_BOX then
		return true
	end
	if name:match("^ChatFrame%d+EditBox") or name:find("Chattynator", 1, true) then
		return true
	end
	local parentName = FrameName(edit.GetParent and edit:GetParent())
	if parentName:find("Chattynator", 1, true) or parentName:match("^ChatFrame") then
		return true
	end
	return false
end

local function CollectChatEdits(widget, depth, seen, boxes)
	if not widget or depth > 5 or seen[widget] then
		return
	end
	seen[widget] = true
	if IsChatEdit(widget) or (widget.GetObjectType and widget:GetObjectType() == "EditBox" and widget ~= chatEntry and FrameName(widget):find("Wardrobe", 1, true) == nil and FrameName(widget):find("CustomSet", 1, true) == nil and depth > 0) then
		if widget.GetObjectType and widget:GetObjectType() == "EditBox" and widget ~= chatEntry then
			local name = FrameName(widget)
			if name:find("Wardrobe", 1, true) == nil and name:find("CustomSet", 1, true) == nil then
				boxes[#boxes + 1] = widget
			end
		end
	end
	if widget.GetChildren then
		local children = { widget:GetChildren() }
		for i = 1, #children do
			CollectChatEdits(children[i], depth + 1, seen, boxes)
		end
	end
	for _, key in ipairs({ "EditBox", "editBox", "entry", "EntryBox", "ChatEdit", "input", "InputBox" }) do
		local field = widget[key]
		if type(field) == "table" then
			CollectChatEdits(field, depth + 1, seen, boxes)
		end
	end
end

local function LiftOpenChatEdit()
	local boxes = {}
	local function add(edit)
		if IsChatEdit(edit) then
			boxes[#boxes + 1] = edit
		end
	end
	add(ACTIVE_CHAT_EDIT_BOX)
	local windows = NUM_CHAT_WINDOWS
	if type(windows) ~= "number" or windows < 1 then
		windows = 10
	end
	for i = 1, windows do
		add(_G["ChatFrame" .. i .. "EditBox"])
	end
	local treeBoxes = {}
	if customChat then
		local seen = {}
		CollectChatEdits(customChat, 0, seen, treeBoxes)
		local outer = Outermost(customChat)
		if outer and outer ~= customChat then
			CollectChatEdits(outer, 0, seen, treeBoxes)
		end
	end
	for i = 1, #treeBoxes do
		LiftWidget(treeBoxes[i], true, 70)
	end
	for i = 1, #boxes do
		LiftWidget(boxes[i], true, 70)
	end
end

local function VisibleChatWindow()
	if customChat and type(customChat.ScrollingMessages) == "table" and customChat.IsShown and customChat:IsShown() then
		return customChat
	end
	local handler
	if type(Chattynator) == "table" and type(Chattynator.API) == "table" and type(Chattynator.API.GetHyperlinkHandler) == "function" then
		local ok, value = pcall(Chattynator.API.GetHyperlinkHandler)
		if ok then
			handler = value
		end
	end
	if handler and handler.GetChildren then
		local children = { handler:GetChildren() }
		for i = 1, #children do
			local child = children[i]
			if child and type(child.ScrollingMessages) == "table" and child.IsShown and child:IsShown() then
				return child
			end
		end
	end
	return customChat
end

local function RevealGameChatEdit()
	if not GameChatWanted() or not chatHost then
		return
	end
	local edit = ChatFrame1EditBox
	if ACTIVE_CHAT_EDIT_BOX and IsChatEdit(ACTIVE_CHAT_EDIT_BOX) then
		edit = ACTIVE_CHAT_EDIT_BOX
	end
	if not IsChatEdit(edit) then
		return
	end
	LiftWidget(edit, true, 90)
	local anchor = VisibleChatWindow()
	if anchor == edit or anchor == chatHost or anchor == frame then
		anchor = nil
	end
	if anchor and FrameName(anchor):find("HyperlinkHandler", 1, true) then
		anchor = nil
	end
	if not edit._cfhKeepShown then
		edit._cfhKeepShown = true
		edit:HookScript("OnHide", function(self)
			if not GameChatWanted() or self._cfhReshowing then
				return
			end
			self._cfhReshowing = true
			C_Timer.After(0, function()
				self._cfhReshowing = nil
				if GameChatWanted() then
					self:Show()
				end
			end)
		end)
	end
	pcall(function()
		edit:SetParent(UIParent)
		edit:SetFrameStrata("TOOLTIP")
		edit:SetFrameLevel(500)
		edit:SetAlpha(1)
		edit:ClearAllPoints()
		if anchor then
			edit:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
			edit:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, 2)
		else
			edit:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 24, 220)
			edit:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", 480, 220)
		end
		edit:SetHeight(28)
		if edit.EnableMouse then
			edit:EnableMouse(true)
		end
		edit:Show()
	end)
end

function PlaceHangoutEntry()
	if not chatPrompt or not frame then
		return
	end
	chatPrompt:ClearAllPoints()
	if GameChatWanted() then
		RevealGameChatEdit()
		chatPrompt:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -24, 16)
		if chatText and chatText.GetParent then
			local panel = chatText:GetParent()
			if panel then
				panel:Hide()
			end
		end
	else
		chatPrompt:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 12)
	end
	if chatEntry then
		chatEntry:ClearAllPoints()
		chatEntry:SetPoint("TOPLEFT", chatPrompt, "TOPLEFT", 0, 0)
		chatEntry:SetPoint("BOTTOMRIGHT", chatPrompt, "BOTTOMRIGHT", 0, 0)
	end
end

local function ApplyGameChat()
	if not GameChatWanted() or not chatHost then
		RestoreGameChat()
		return
	end
	chatHost:SetFrameLevel((frame:GetFrameLevel() or 200) + 80)
	chatHost:Show()
	if ReplacementAddon() then
		local root = FindCustomChat()
		if root then
			local outer = Outermost(root)
			local tooBig = false
			if outer and outer.GetWidth and frame.GetWidth then
				local w, h = outer:GetWidth(), outer:GetHeight()
				local sw, sh = frame:GetWidth(), frame:GetHeight()
				tooBig = type(w) == "number" and type(sw) == "number" and sw > 0 and w > sw * 0.85 and type(h) == "number" and type(sh) == "number" and h > sh * 0.85
			end
			if tooBig then
				LiftWidget(root, true, 20)
			else
				LiftWidget(root)
			end
		elseif customChatTries <= 20 then
			LiftOpenChatEdit()
			PlaceHangoutEntry()
			return
		end
		LiftOpenChatEdit()
		PlaceHangoutEntry()
		return
	end
	local windows = NUM_CHAT_WINDOWS
	if type(windows) ~= "number" or windows < 1 then
		windows = 10
	end
	for i = 1, windows do
		local chat = _G["ChatFrame" .. i]
		if chat and chat.IsShown and chat:IsShown() then
			LiftWidget(chat)
		end
		local tab = _G["ChatFrame" .. i .. "Tab"] or (chat and chat.Tab)
		if tab and tab.IsShown and tab:IsShown() then
			LiftWidget(tab, true, 40)
		end
	end
	if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.IsShown and DEFAULT_CHAT_FRAME:IsShown() then
		LiftWidget(DEFAULT_CHAT_FRAME)
	end
	if GeneralDockManager and GeneralDockManager.IsShown and GeneralDockManager:IsShown() then
		LiftWidget(GeneralDockManager)
	end
	for _, name in ipairs({
		"ChatFrameMenuButton",
		"ChatFrameChannelButton",
		"ChatFrameToggleVoiceDeafenButton",
		"ChatFrameToggleVoiceMuteButton",
	}) do
		local widget = _G[name]
		if widget and widget.IsShown and widget:IsShown() then
			LiftWidget(widget, true, 20)
		end
	end
	LiftOpenChatEdit()
	PlaceHangoutEntry()
end

local function SyncChatEdit()
	if chatSending or not frame or not frame:IsShown() or not chatEntry or GameChatWanted() then
		return
	end
	if chatEntry.HasFocus and chatEntry:HasFocus() then
		return
	end
	if TakeBlizzardChat() then
		chatEntry:SetFocus()
		UpdateChatPlaceholder()
	end
end

local function HookChatEdits()
	if chatHooked or type(hooksecurefunc) ~= "function" or type(ChatFrame_OpenChat) ~= "function" then
		return
	end
	chatHooked = true
	hooksecurefunc("ChatFrame_OpenChat", function()
		if GameChatWanted() then
			C_Timer.After(0, LiftOpenChatEdit)
			return
		end
		if chatSending or not frame or not frame:IsShown() then
			return
		end
		C_Timer.After(0, function()
			if not frame or not frame:IsShown() or chatSending or GameChatWanted() then
				return
			end
			TakeBlizzardChat()
			SubmitChatEntry(chatEntry)
			FocusChatEntry()
		end)
	end)
end

local function OpenChatEntry()
	FocusChatEntry()
end

local function Build()
	frame = CreateFrame("Frame", "CampfireHangoutFrame", UIParent)
	frame:SetAllPoints(UIParent)
	frame:SetFrameStrata("FULLSCREEN_DIALOG")
	frame:SetFrameLevel(200)
	frame:EnableMouse(true)
	frame:EnableMouseWheel(true)
	frame:Hide()

	chatHost = CreateFrame("Frame", nil, frame)
	chatHost:SetAllPoints(frame)
	chatHost:SetFrameLevel(280)
	chatHost:EnableMouse(false)

	local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
	bg:SetAllPoints()
	bg:SetColorTexture(0.01, 0.012, 0.02, 1)

	backdrop = frame:CreateTexture(nil, "BACKGROUND", nil, 0)
	backdrop:SetAllPoints()
	backdrop:Hide()

	dimmer = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
	dimmer:SetAllPoints()
	dimmer:SetColorTexture(0, 0, 0, 0.16)
	dimmer:Hide()

	sky = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
	sky:SetPoint("TOPLEFT")
	sky:SetPoint("TOPRIGHT")
	ApplyGradient(
		sky,
		"VERTICAL",
		MakeColor(0.01, 0.015, 0.03, 1),
		MakeColor(0.05, 0.07, 0.12, 1),
		0.02, 0.025, 0.04, 1
	)

	horizon = frame:CreateTexture(nil, "BACKGROUND", nil, 3)
	horizon:SetColorTexture(0.55, 0.32, 0.14, 0.45)

	groundFade = frame:CreateTexture(nil, "BACKGROUND", nil, 4)
	groundFade:Hide()

	textLayer = CreateFrame("Frame", nil, frame)
	textLayer:SetAllPoints()
	textLayer:SetFrameLevel(240)
	textLayer:EnableMouse(false)

	titleText = textLayer:CreateFontString(nil, "OVERLAY")
	H.SetFont(titleText, FONT_TITLE, 42)
	titleText:SetTextColor(0.96, 0.83, 0.46)
	titleText:SetPoint("TOP", textLayer, "TOP", 0, -42)
	titleText:SetText("Campfire Hangout")

	local ruleLeft = textLayer:CreateTexture(nil, "ARTWORK")
	ruleLeft:SetColorTexture(0.72, 0.56, 0.28, 0.85)
	ruleLeft:SetSize(120, 1)
	ruleLeft:SetPoint("RIGHT", titleText, "BOTTOM", -14, -12)

	local ruleRight = textLayer:CreateTexture(nil, "ARTWORK")
	ruleRight:SetColorTexture(0.72, 0.56, 0.28, 0.85)
	ruleRight:SetSize(120, 1)
	ruleRight:SetPoint("LEFT", titleText, "BOTTOM", 14, -12)

	local diamond = textLayer:CreateTexture(nil, "ARTWORK")
	diamond:SetColorTexture(0.9, 0.74, 0.38, 1)
	diamond:SetSize(7, 7)
	diamond:SetPoint("TOP", titleText, "BOTTOM", 0, -9)
	pcall(diamond.SetRotation, diamond, math.rad(45))

	subtitleText = textLayer:CreateFontString(nil, "OVERLAY")
	H.SetFont(subtitleText, FONT_BODY, 15)
	subtitleText:SetTextColor(0.74, 0.67, 0.54)
	subtitleText:SetPoint("TOP", titleText, "BOTTOM", 0, -28)
	subtitleText:SetWidth(720)
	subtitleText:SetJustifyH("CENTER")

	timerText = textLayer:CreateFontString(nil, "OVERLAY")
	H.SetFont(timerText, FONT_BODY, 20)
	timerText:SetTextColor(0.94, 0.78, 0.42)
	timerText:SetPoint("TOP", subtitleText, "BOTTOM", 0, -10)

	footerText = textLayer:CreateFontString(nil, "OVERLAY")
	H.SetFont(footerText, FONT_BODY, 13)
	footerText:SetTextColor(0.48, 0.44, 0.38)
	footerText:SetPoint("BOTTOM", textLayer, "BOTTOM", 0, 16)

	sceneMode = false
	for i = 1, H.MAX_SLOTS do
		BuildDollSlot(frame, textLayer, i)
	end
	BuildFire(frame)
	ShowBackdrop()
	LoadCampfire()
	if fire and backdropFile == BACKDROP_PATH then
		fire:Hide()
	end

	chatPrompt = CreateFrame("Frame", nil, frame)
	chatPrompt:SetSize(420, 36)
	chatPrompt:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 12)
	chatPrompt:SetFrameLevel(300)

	local chatFrame = CreateFrame("Frame", nil, frame)
	chatFrame:SetSize(420, 118)
	chatFrame:SetPoint("BOTTOMLEFT", chatPrompt, "TOPLEFT", 0, 6)
	chatFrame:SetFrameLevel(310)
	chatFrame:EnableMouse(false)
	chatFrame:Hide()
	local chatBg = chatFrame:CreateTexture(nil, "BACKGROUND")
	chatBg:SetAllPoints()
	chatBg:SetColorTexture(0.04, 0.03, 0.02, 0.78)
	chatText = chatFrame:CreateFontString(nil, "OVERLAY")
	H.SetFont(chatText, FONT_BODY, 14)
	chatText:SetTextColor(0.93, 0.86, 0.7)
	chatText:SetJustifyH("LEFT")
	chatText:SetJustifyV("BOTTOM")
	chatText:SetWordWrap(true)
	chatText:SetPoint("TOPLEFT", 12, -8)
	chatText:SetPoint("BOTTOMRIGHT", -12, 8)
	chatText:SetShadowColor(0, 0, 0, 1)
	chatPrompt:EnableMouse(true)
	local promptBg = chatPrompt:CreateTexture(nil, "BACKGROUND")
	promptBg:SetAllPoints()
	promptBg:SetColorTexture(0.04, 0.03, 0.02, 0.82)
	chatPlaceholder = chatPrompt:CreateFontString(nil, "ARTWORK")
	H.SetFont(chatPlaceholder, FONT_BODY, 15)
	chatPlaceholder:SetTextColor(0.72, 0.64, 0.46)
	chatPlaceholder:SetPoint("LEFT", 12, 0)
	chatPlaceholder:SetText("Enter to speak")
	chatEntry = CreateFrame("EditBox", nil, frame)
	chatEntry:SetPoint("TOPLEFT", chatPrompt, "TOPLEFT", 0, 0)
	chatEntry:SetPoint("BOTTOMRIGHT", chatPrompt, "BOTTOMRIGHT", 0, 0)
	chatEntry:SetFrameLevel(320)
	chatEntry:EnableMouse(true)
	chatEntry:SetAutoFocus(false)
	chatEntry:SetMaxLetters(255)
	chatEntry:SetTextInsets(12, 10, 2, 2)
	pcall(chatEntry.SetMultiLine, chatEntry, false)
	pcall(chatEntry.SetJustifyH, chatEntry, "LEFT")
	pcall(chatEntry.SetJustifyV, chatEntry, "MIDDLE")
	ApplyChatEntryFont()
	pcall(chatEntry.SetPropagateKeyboardInput, chatEntry, false)
	chatEntry:SetScript("OnEnterPressed", function(self)
		SubmitChatEntry(self)
	end)
	chatEntry:SetScript("OnKeyDown", function(self, key)
		if key == "ENTER" then
			SubmitChatEntry(self)
		end
	end)
	chatEntry:SetScript("OnEscapePressed", function(self)
		self:SetText("")
		self:ClearFocus()
		UpdateChatPlaceholder()
	end)
	chatEntry:SetScript("OnEditFocusGained", function()
		ApplyChatEntryFont()
		UpdateChatPlaceholder()
	end)
	chatEntry:SetScript("OnEditFocusLost", UpdateChatPlaceholder)
	chatEntry:SetScript("OnTextChanged", UpdateChatPlaceholder)
	chatEntry:SetScript("OnMouseDown", function(self)
		self:SetFocus()
	end)
	chatPrompt:SetScript("OnMouseDown", function()
		FocusChatEntry()
	end)

	local emotes = {
		{ "Wave", "WAVE" },
		{ "Nod", "YES" },
		{ "Bow", "BOW" },
		{ "Cheer", "CHEER" },
		{ "Laugh", "LAUGH" },
	}
	local buttonW = 84
	local gap = 8
	local rowW = #emotes * buttonW + (#emotes - 1) * gap
	local origin = -rowW / 2 + buttonW / 2
	for i, spec in ipairs(emotes) do
		local token = spec[2]
		local button = MakeGoldButton(frame, spec[1], function()
			if H.RequestEmote then
				H.RequestEmote(token)
			end
		end)
		button:SetFrameLevel(260)
		emoteButtons[#emoteButtons + 1] = button
		button:SetPoint("BOTTOM", frame, "BOTTOM", origin + (i - 1) * (buttonW + gap), 16)
	end

	ApplyChosenFont()

	frame:SetScript("OnMouseWheel", function() end)
	frame:SetScript("OnMouseDown", function(_, button)
		if button == "RightButton" and H.RequestClose then
			H.RequestClose("manual")
		end
	end)
	frame:SetScript("OnSizeChanged", function()
		Layout()
	end)
	frame:SetScript("OnUpdate", function(_, elapsed)
		TickBubbles()
		if sceneMode then
			FlickerSceneLight()
		end
		FlickerFire(elapsed)
		UpdateTimer()
		SyncChatEdit()
		ApplyGameChat()
	end)
	frame:SetScript("OnHide", function()
		RestoreGameChat()
		RestoreChatEdit()
		if chatEntry then
			chatEntry:SetText("")
			chatEntry:ClearFocus()
			UpdateChatPlaceholder()
		end
		for i = 1, H.MAX_SLOTS do
			local slot = slots[i]
			if slot then
				slot.key = nil
				slot.name:Hide()
				slot.class:Hide()
				if slot.bubbleFrame then
					slot.bubbleFrame:Hide()
				end
				if slot.frame then
					slot.frame:Hide()
				end
				if slot.model then
					pcall(slot.model.ClearModel, slot.model)
				end
				if slot.actor then
					Try(slot.actor, "ClearModel")
					Try(slot.actor, "Hide")
				end
			end
		end
		fireLoaded = false
		currentEntries = {}
		lastChatLine = nil
		pendingEcho = nil
		pendingEchoAt = nil
		pendingToken = nil
		for i = #chatLines, 1, -1 do
			chatLines[i] = nil
		end
		if chatText then
			chatText:SetText("")
			chatText:GetParent():Hide()
		end
		if fontPanel then
			fontPanel:Hide()
		end
		if H.OnSceneHidden then
			H.OnSceneHidden()
		end
	end)

	HookChatEdits()

	if UISpecialFrames then
		local listed = false
		for _, name in ipairs(UISpecialFrames) do
			if name == "CampfireHangoutFrame" then
				listed = true
				break
			end
		end
		if not listed then
			table.insert(UISpecialFrames, "CampfireHangoutFrame")
		end
	end
end

H.Scene = {}

function H.Scene:IsShown()
	return frame and frame:IsShown()
end

function H.Scene:Present(payload)
	payload = payload or {}
	if not frame:IsShown() then
		frame:Show()
	end
	frame:Raise()
	LoadCampfire()
	if chatPrompt and not (liftedEdit and liftedEdit:IsShown()) then
		chatPrompt:Show()
	end
	if chatEntry then
		chatEntry:Show()
		ApplyChatEntryFont()
	end
	titleText:SetText(payload.title or "Campfire Hangout")
	subtitleText:SetText(payload.subtitle or "")
	footerText:SetText(payload.footer or "Escape or right-click to return")
	expiresAt = payload.expiresAt
	staticTimer = payload.timerText or ""
	ApplyEntries(payload.entries or {}, true)
	Layout()
	UpdateTimer()
	ApplyGameChat()
end

function H.Scene:Update(payload)
	if not frame:IsShown() then
		self:Present(payload)
		return
	end
	if payload.subtitle then
		subtitleText:SetText(payload.subtitle)
	end
	if payload.footer then
		footerText:SetText(payload.footer)
	end
	if payload.title then
		titleText:SetText(payload.title)
	end
	local previousCount = #currentEntries
	expiresAt = payload.expiresAt
	staticTimer = payload.timerText or ""
	ApplyEntries(payload.entries or {}, false)
	if previousCount ~= #currentEntries then
		Layout()
	end
	UpdateTimer()
	ApplyGameChat()
end

function H.Scene:HideScene()
	if frame and frame:IsShown() then
		frame:Hide()
	end
end

function H.Scene:RefreshCamera()
	if sceneMode then
		PoseScene()
		for i = 1, #currentEntries do
			PlaceActor(i)
		end
		PlaceFire()
		LayoutLabels()
	else
		ApplyEntries(currentEntries, true)
	end
	Layout()
end

function H.Scene:CameraDefaults()
	if sceneMode then
		return SCENE_CAMERA.distance, SCENE_CAMERA.z
	end
	return DOLL_CAMERA.distance, DOLL_CAMERA.z
end

function H.Scene:UsesSceneCamera()
	return sceneMode
end

function H.Scene:ShowChat(speaker, text)
	ShowChat(speaker, text)
end

function H.Scene:ApplyGameChat()
	ApplyGameChat()
end

function H.Scene:PlayLocal(token)
	PlayToken(token, nil)
end

function H.Scene:PlayFromSender(sender, token)
	PlayToken(token, sender)
end

function H.Scene:SelectFont(name)
	SelectFont(name)
end

function H.Scene:PrintFonts()
	PrintFonts()
end

function H.Scene:ApplySavedFont()
	ApplyChosenFont()
end

function H.Scene:GetFonts()
	return FontCatalog()
end

function H.Scene:GetFont()
	return ChosenFont()
end

function H.SharedMediaLib()
	return SharedMediaLib()
end

Build()
