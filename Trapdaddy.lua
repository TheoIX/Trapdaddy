-- Trapdaddy (Vanilla 1.12 / Turtle WoW)
-- Tracks NPC respawns by learning once (death -> first seen alive),
-- then uses that learned time for countdown on future deaths.

TrapdaddyDB = TrapdaddyDB or {}

local TD = {}
TD.addon = "Trapdaddy"

TD.visibleRows  = 8
TD.rowH         = 16
TD.scanInterval = 0.50  -- seconds
TD.uiInterval   = 0.20  -- seconds

TD.totalItems   = 0
TD.rows         = {}
TD.scanElapsed  = 0
TD.uiElapsed    = 0

local function Trim(s)
  if not s then return "" end
  s = string.gsub(s, "^%s+", "")
  s = string.gsub(s, "%s+$", "")
  return s
end

function TD:Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Trapdaddy:|r " .. tostring(msg or ""))
end

function TD:InitDB()
  if not TrapdaddyDB then TrapdaddyDB = {} end
  TrapdaddyDB.tracked = TrapdaddyDB.tracked or {}
  TrapdaddyDB.options = TrapdaddyDB.options or {
    unlocked     = 0,  -- allow dragging
    scanInCombat = 0,  -- avoid target flicker in combat
    sound        = 1,  -- play sound on respawn detect
  }
end

function TD:FormatTime(sec)
  if not sec then return "?" end
  if sec < 0 then sec = 0 end
  sec = math.floor(sec + 0.5)

  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60

  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%d:%02d", m, s)
end

function TD:MakeKey(name, zone)
  return tostring(name or "?") .. "@" .. tostring(zone or "?")
end

function TD:GetTargetEnemyName()
  if not UnitExists("target") then return nil end
  if UnitIsPlayer("target") then return nil end
  if not UnitCanAttack("player", "target") then return nil end
  local n = UnitName("target")
  if not n or n == "" then return nil end
  return n
end

function TD:GetSortedKeys()
  local keys = {}
  for k,_ in pairs(TrapdaddyDB.tracked) do
    table.insert(keys, k)
  end

  local curZone = GetZoneText() or "?"
  table.sort(keys, function(a, b)
    local ta = TrapdaddyDB.tracked[a]
    local tb = TrapdaddyDB.tracked[b]
    if not ta or not tb then return a < b end

    -- current zone first
    local az = (ta.zone == curZone) and 0 or 1
    local bz = (tb.zone == curZone) and 0 or 1
    if az ~= bz then return az < bz end

    if ta.name == tb.name then
      return (ta.zone or "") < (tb.zone or "")
    end
    return (ta.name or "") < (tb.name or "")
  end)

  return keys
end

function TD:GetStatusText(t)
  if not t then return "" end
  local now  = time()
  local zone = GetZoneText() or "?"

  -- Out of zone display
  if t.zone ~= zone then
    if t.state == "countdown" and t.lastDeath and t.respawn then
      local rem = (t.lastDeath + t.respawn) - now
      if rem > 0 then
        return self:FormatTime(rem) .. " | " .. (t.zone or "?")
      else
        return "OVERDUE | " .. (t.zone or "?")
      end
    end
    return "OUT OF ZONE"
  end

  if t.state == "up" then
    if t.respawn then
      return "UP | " .. self:FormatTime(t.respawn)
    end
    return "UP | ?"
  end

  if t.state == "learning" then
    if t.lastDeath then
      return "LEARN +" .. self:FormatTime(now - t.lastDeath)
    end
    return "LEARN"
  end

  if t.state == "countdown" then
    if t.lastDeath and t.respawn then
      local rem = (t.lastDeath + t.respawn) - now
      if rem <= 0 then
        t.state = "overdue"
        rem = 0
      end
      return self:FormatTime(rem)
    end
    return "..."
  end

  if t.state == "overdue" then
    if t.lastDeath and t.respawn then
      local over = now - (t.lastDeath + t.respawn)
      if over < 0 then over = 0 end
      return "OVERDUE +" .. self:FormatTime(over)
    end
    return "OVERDUE"
  end

  return ""
end

-- UnitScan-style scan: target by name briefly, then restore target.
-- Returns true if an ALIVE unit of that name is found.
function TD:ScanForName(name)
  if not name or name == "" then return false end

  -- If already targeting it and it's alive, that's a hit.
  if UnitExists("target") and UnitName("target") == name and not UnitIsDead("target") then
    return true
  end

  local hadTarget = UnitExists("target")

  if hadTarget then
    TargetByName(name, true)
    local found = UnitExists("target") and UnitName("target") == name and not UnitIsDead("target")
    TargetLastTarget()
    return found
  else
    if ClearTarget then ClearTarget() end
    TargetByName(name, true)
    local found = UnitExists("target") and UnitName("target") == name and not UnitIsDead("target")
    if ClearTarget then ClearTarget() end
    return found
  end
end

function TD:EntryNeedsScan(t)
  if not t or t.zone ~= (GetZoneText() or "?") then return false end
  if not t.lastDeath then return false end

  if t.state == "learning" then return true end
  if t.state == "overdue"  then return true end

  if t.state == "countdown" and t.respawn then
    return (time() >= (t.lastDeath + t.respawn))
  end

  return false
end

function TD:MarkRespawned(t)
  local now = time()

  if t.lastDeath then
    local observed = now - t.lastDeath
    if observed < 0 then observed = 0 end

    -- Learn once
    if not t.respawn then
      t.respawn = observed
      self:Print(t.name .. " respawn learned: " .. self:FormatTime(observed))
    end
  end

  t.state    = "up"
  t.lastSeen = now

  if TrapdaddyDB.options.sound == 1 and PlaySound then
    PlaySound("RaidWarning")
  end
end

function TD:DoScanTick()
  if TrapdaddyDB.options.scanInCombat ~= 1 and UnitAffectingCombat and UnitAffectingCombat("player") then
    return
  end

  local keys = self:GetSortedKeys()
  for i=1, table.getn(keys) do
    local t = TrapdaddyDB.tracked[keys[i]]
    if t and self:EntryNeedsScan(t) then
      if self:ScanForName(t.name) then
        self:MarkRespawned(t)
        self:UpdateUI()
        return
      end
    end
  end
end

function TD:ExtractDeathName(msg)
  if not msg or msg == "" then return nil end

  -- Common Vanilla patterns (English client)
  local n = string.match(msg, "^(.+) dies%.$")
  if n then return n end

  n = string.match(msg, "^You have slain (.+)!$")
  if n then return n end

  n = string.match(msg, "^(.+) is slain%.$")
  if n then return n end

  return nil
end

function TD:OnDeathMessage(msg)
  local name = self:ExtractDeathName(msg)
  if not name then return end

  local zone = GetZoneText() or "?"
  local now  = time()

  for _,t in pairs(TrapdaddyDB.tracked) do
    if t and t.name == name and t.zone == zone then
      t.lastDeath = now
      if t.respawn then
        t.state = "countdown"
      else
        t.state = "learning"
      end
      -- no spam; one line is fine
      self:UpdateUI()
    end
  end
end

-- Tracking commands
function TD:Track(name)
  name = Trim(name)
  if name == "" then
    name = self:GetTargetEnemyName()
  end
  if not name then
    self:Print("Target a hostile NPC and type /track (or /track <name>).")
    return
  end

  local zone = GetZoneText() or "?"
  local key  = self:MakeKey(name, zone)

  if not TrapdaddyDB.tracked[key] then
    TrapdaddyDB.tracked[key] = {
      name     = name,
      zone     = zone,
      addedAt  = time(),
      respawn  = nil,        -- seconds (learned once)
      lastDeath= nil,        -- epoch seconds
      state    = "up",       -- up | learning | countdown | overdue
      lastSeen = nil,
    }
    self:Print("Tracking " .. name .. " (" .. zone .. ")")
  else
    self:Print("Already tracking " .. name .. " (" .. zone .. ")")
  end

  self:UpdateUI()
end

function TD:Untrack(name)
  name = Trim(name)
  if name == "" then
    name = self:GetTargetEnemyName()
  end

  if not name then
    self:Print("Target the mob and /untrack (or /untrack <name>, /untrack all).")
    return
  end

  if string.lower(name) == "all" then
    TrapdaddyDB.tracked = {}
    self:Print("Cleared all tracked mobs.")
    self:UpdateUI()
    return
  end

  local zone = GetZoneText() or "?"
  local key  = self:MakeKey(name, zone)

  if TrapdaddyDB.tracked[key] then
    TrapdaddyDB.tracked[key] = nil
    self:Print("Untracked " .. name .. " (" .. zone .. ")")
  else
    self:Print("Not tracked: " .. name .. " (" .. zone .. ")")
  end

  self:UpdateUI()
end

function TD:Reset(name)
  name = Trim(name)
  if name == "" then
    name = self:GetTargetEnemyName()
  end
  if not name then
    self:Print("Target the mob and /td reset (or /td reset <name>).")
    return
  end

  local zone = GetZoneText() or "?"
  local key  = self:MakeKey(name, zone)
  local t    = TrapdaddyDB.tracked[key]

  if not t then
    self:Print("Not tracked: " .. name .. " (" .. zone .. ")")
    return
  end

  t.respawn   = nil
  t.lastDeath = nil
  t.state     = "up"
  self:Print("Reset learned respawn for " .. name .. " (" .. zone .. ")")
  self:UpdateUI()
end

function TD:List()
  local c = 0
  for _ in pairs(TrapdaddyDB.tracked) do c = c + 1 end
  self:Print("Tracked: " .. c)
end

-- UI
function TD:CreateUI()
  local f = CreateFrame("Frame", "TrapdaddyFrame", UIParent)
  self.frame = f

  f:SetWidth(270)
  f:SetHeight(24 + (self.visibleRows * self.rowH) + 14)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 200)

  f:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true, tileSize = 16, edgeSize = 16,
    insets   = { left=4, right=4, top=4, bottom=4 }
  })
  f:SetBackdropColor(0, 0, 0, 0.85)

  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function()
    if TrapdaddyDB.options.unlocked == 1 then
      this:StartMoving()
    end
  end)
  f:SetScript("OnDragStop", function()
    this:StopMovingOrSizing()
  end)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -8)
  title:SetText("Trapdaddy")

  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -8)
  hint:SetText("/track  /untrack")

  local sf = CreateFrame("ScrollFrame", "TrapdaddyScroll", f, "FauxScrollFrameTemplate")
  sf:SetPoint("TOPLEFT",  f, "TOPLEFT", 10, -24)
  sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 10)

  sf:SetScript("OnVerticalScroll", function()
    FauxScrollFrame_OnVerticalScroll(this, arg1, TD.rowH, function() TD:UpdateUI() end)
  end)

  sf:EnableMouseWheel(true)
  sf:SetScript("OnMouseWheel", function()
    local total   = TD.totalItems or 0
    local offset  = FauxScrollFrame_GetOffset(this) or 0

    if arg1 > 0 then offset = offset - 1 else offset = offset + 1 end
    if offset < 0 then offset = 0 end
    local maxOff = total - TD.visibleRows
    if maxOff < 0 then maxOff = 0 end
    if offset > maxOff then offset = maxOff end

    FauxScrollFrame_SetOffset(this, offset)
    TD:UpdateUI()
  end)

  for i=1, self.visibleRows do
    local r = CreateFrame("Frame", nil, f)
    r:SetHeight(self.rowH)
    r:SetWidth(220)
    r:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -24 - ((i-1) * self.rowH))

    r.left = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.left:SetPoint("LEFT", r, "LEFT", 0, 0)
    r.left:SetWidth(140)
    r.left:SetJustifyH("LEFT")

    r.right = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.right:SetPoint("RIGHT", r, "RIGHT", 0, 0)
    r.right:SetWidth(110)
    r.right:SetJustifyH("RIGHT")

    self.rows[i] = r
  end

  self:UpdateUI()
end

function TD:UpdateUI()
  if not self.frame then return end

  local keys = self:GetSortedKeys()
  self.totalItems = table.getn(keys)

  FauxScrollFrame_Update(TrapdaddyScroll, self.totalItems, self.visibleRows, self.rowH)
  local offset = FauxScrollFrame_GetOffset(TrapdaddyScroll) or 0

  for i=1, self.visibleRows do
    local idx = offset + i
    local key = keys[idx]
    local row = self.rows[i]

    if key and TrapdaddyDB.tracked[key] then
      local t = TrapdaddyDB.tracked[key]
      row:Show()
      row.left:SetText(t.name or "?")
      row.right:SetText(self:GetStatusText(t))
    else
      row:Hide()
    end
  end
end

-- Slash commands
SLASH_TRAPDADDY1 = "/trapdaddy"
SLASH_TRAPDADDY2 = "/td"
SlashCmdList["TRAPDADDY"] = function(msg)
  msg = Trim(msg)
  local cmd, rest = string.match(msg, "^(%S+)%s*(.*)$")
  cmd  = string.lower(cmd or "")
  rest = rest or ""

  if cmd == "" or cmd == "help" then
    TD:Print("Commands:")
    TD:Print("/track (or /track <name>)  |  /untrack (or /untrack <name> /untrack all)")
    TD:Print("/td unlock|lock  /td sound on|off  /td combatscan on|off  /td list  /td reset [name]")
    return
  end

  if cmd == "unlock" then
    TrapdaddyDB.options.unlocked = 1
    TD:Print("Frame unlocked (drag with left mouse).")
    return
  end

  if cmd == "lock" then
    TrapdaddyDB.options.unlocked = 0
    TD:Print("Frame locked.")
    return
  end

  if cmd == "sound" then
    rest = string.lower(Trim(rest))
    if rest == "on" then TrapdaddyDB.options.sound = 1; TD:Print("Sound ON.") return end
    if rest == "off" then TrapdaddyDB.options.sound = 0; TD:Print("Sound OFF.") return end
    TD:Print("Usage: /td sound on|off")
    return
  end

  if cmd == "combatscan" then
    rest = string.lower(Trim(rest))
    if rest == "on" then TrapdaddyDB.options.scanInCombat = 1; TD:Print("Combat scanning ON (may flicker target).") return end
    if rest == "off" then TrapdaddyDB.options.scanInCombat = 0; TD:Print("Combat scanning OFF (recommended).") return end
    TD:Print("Usage: /td combatscan on|off")
    return
  end

  if cmd == "list" then
    TD:List()
    return
  end

  if cmd == "reset" then
    TD:Reset(rest)
    return
  end

  TD:Print("Unknown command. /td help")
end

-- NOTE: /track may conflict with other addons/macros.
-- If it does, use /td track (not implemented) or /tdtrack instead.
SLASH_TRAPDADDYTRACK1 = "/track"
SLASH_TRAPDADDYTRACK2 = "/tdtrack"
SlashCmdList["TRAPDADDYTRACK"] = function(msg)
  TD:Track(msg)
end

SLASH_TRAPDADDYUNTRACK1 = "/untrack"
SLASH_TRAPDADDYUNTRACK2 = "/tduntrack"
SlashCmdList["TRAPDADDYUNTRACK"] = function(msg)
  TD:Untrack(msg)
end

-- Main frame / events
local f = CreateFrame("Frame", "TrapdaddyEventFrame", UIParent)
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
f:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")

f:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" and arg1 == TD.addon then
    TD:InitDB()
    TD:CreateUI()
    TD:Print("Loaded. Target a mob and type /track.")
    return
  end

  if event == "CHAT_MSG_COMBAT_HOSTILE_DEATH" or event == "CHAT_MSG_COMBAT_XP_GAIN" then
    TD:OnDeathMessage(arg1)
    return
  end
end)

f:SetScript("OnUpdate", function()
  local e = arg1 or 0

  TD.scanElapsed = TD.scanElapsed + e
  if TD.scanElapsed >= TD.scanInterval then
    TD.scanElapsed = 0
    TD:DoScanTick()
  end

  TD.uiElapsed = TD.uiElapsed + e
  if TD.uiElapsed >= TD.uiInterval then
    TD.uiElapsed = 0
    TD:UpdateUI()
  end
end)
