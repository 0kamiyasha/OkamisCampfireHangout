local ADDON_NAME = ...

CampfireHangout = CampfireHangout or {}
local H = CampfireHangout

H.NAME = ADDON_NAME
H.BUFF_NAME = "Welcoming Campfire"
H.PREFIX = "CFHangout"
H.MAX_SLOTS = 5

function H.Sealed(value)
	if type(issecretvalue) ~= "function" then
		return false
	end
	local ok, sealed = pcall(issecretvalue, value)
	return ok and sealed == true
end

function H.Print(text)
	local chat = DEFAULT_CHAT_FRAME
	if not chat then
		return
	end
	chat:AddMessage("|cffe7c98aCampfire Hangout|r  " .. tostring(text))
end

-- pcall a unit API. Secret booleans must not be used in an if-test.
function H.SafeBool(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end
	local ok, value = pcall(fn, ...)
	if not ok or H.Sealed(value) or type(value) ~= "boolean" then
		return nil
	end
	return value
end

function H.SafeTrue(fn, ...)
	return H.SafeBool(fn, ...) == true
end

function H.SetFont(fs, path, size)
	fs:SetFont(path, size, "")
	if not fs:GetFont() then
		fs:SetFont("Fonts\\FRIZQT__.TTF", size, "")
	end
	fs:SetShadowColor(0, 0, 0, 1)
	fs:SetShadowOffset(1, -1)
end

function H.SetText(fs, text)
	if text == nil or text == "" then
		fs:SetText("")
		return
	end
	if not pcall(fs.SetText, fs, text) then
		fs:SetText("")
	end
end
