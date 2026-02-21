-- Trapdaddy - Turtle WoW (Vanilla 1.12) NPC respawn tracker
-- Features:
--  * /td track  (or /track)   - track your current target
--  * /td untrack (or /untrack) - remove your current target
--  * Learns respawn by observing first death -> reappear cycle
--  * Shows a small on-screen list with timers
--
-- Notes:
--  * Vanilla 1.12 has no GUID combat log, so this is NAME-based.
--  * Respawn detection uses a UnitScan-style visible nameplate scan (plus target/mouseover).
--  * Nameplates must exist/visible for scan detection (press 'V' to show nameplates).

local ADDON = "Trapdaddy"

local TD = CreateFrame("Frame")
TD:SetScript("OnEvent", function() TD:OnEvent(event, arg1, arg2, arg3, arg4, arg5) end)
TD:SetScript("OnUpdate", function() TD:OnUpdate(arg1) end)

-- =========================
-- Utils
-- =========================
local function TD_Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Trapdaddy:|r " .. tostring(msg))
end

local function Wipe(t)
  for k in pairs(t) do t[k] = nil end
end

local function Clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function FormatTime(sec)
  sec = math.floor(sec + 0.5)
  if sec < 0 then sec = 0 end
  local m = math.floor(sec / 60)
  local s = sec - (m * 60)
  return string.format("%d:%02d", m, s)
end

local function IsEmpty(s)
  return (not s) or s == ""
end

-- =========================
-- Saved Vars + Runtime State
-- =========================
TrapdaddyDB = TrapdaddyDB or nil

TD.db = nil
TD.state = {}   -- transient per-mob runtime state: { [name] = { timing, lastDeathAt } }
TD.visible = {} -- temp visibility set: { [name] = true }
TD.sortbuf = {} -- temp for sorting names

-- Config defaults
local function EnsureDB()
  if not TrapdaddyDB or type(TrapdaddyDB) ~= "table" then
    TrapdaddyDB = {}
  end
  if type(TrapdaddyDB.mobs) ~= "table" then
    TrapdaddyDB.mobs = {}
  end
  if type(TrapdaddyDB.config) ~= "table" then
    TrapdaddyDB.config = {}
  end
  if TrapdaddyDB.config.shown == nil then TrapdaddyDB.config.shown = true end
  if TrapdaddyDB.config.locked == nil then TrapdaddyDB.config.locked = false end
  if TrapdaddyDB.config.scale == nil then TrapdaddyDB.config.scale = 1.0 end
  if TrapdaddyDB.config.scanInterval == nil then TrapdaddyDB.config.scanInterval = 0.35 end
  if TrapdaddyDB.config.uiInterval == nil then TrapdaddyDB.config.uiInterval = 0.15 end
  if TrapdaddyDB.config.maxRows == nil then TrapdaddyDB.config.maxRows = 8 end
  return TrapdaddyDB
end

local function EnsureMob(name)
  if IsEmpty(name) then return nil end
  local mobs = TD.db.mobs
  if type(mobs[name]) ~= "table" then
    mobs[name] = { respawn = nil } -- respawn seconds learned (baseline)
  end
  if type(TD.state[name]) ~= "table" then
    TD.state[name] = { timing = false, lastDeathAt = nil }
  end
  return mobs[name], TD.state[name]
end

local function RemoveMob(name)
  if IsEmpty(name) then return end
  TD.db.mobs[name] = nil
  TD.state[name] = nil
end

local function MobCount()
  local n = 0
  for _ in pairs(TD.db.mobs) do n = n + 1 end
  return n
end

-- =========================
-- Nameplate scanning (UnitScan-style)
-- =========================
-- Vanilla nameplates are anonymous frames under WorldFrame.
-- We detect them heuristically:
--   * unnamed frame
--   * shown
--   * has a StatusBar child (healthbar)
--   * has a FontString region with non-empty text (name)
local function HasStatusBarChild(f)
  -- Avoid 'select' for older embedded Lua (some 1.12 clients omit it).
  local kids = { f:GetChildren() }
  local count = table.getn(kids)
  for i = 1, count do
    local child = kids[i]
    if child and child.GetObjectType and child:GetObjectType() == "StatusBar" then
      return true
    end
  end
  return false
end

local function GetFirstFontStringText(f)
  -- Avoid 'select' for older embedded Lua.
  local regions = { f:GetRegions() }
  local count = table.getn(regions)
  for i = 1, count do
    local region = regions[i]
    if region and region.GetObjectType and region:GetObjectType() == "FontString" and region.GetText then
      local txt = region:GetText()
      if txt and txt ~= "" then
        return txt
      end
    end
  end
  return nil
end

local function GetNameplateName(f)
  if not f or (f.GetName and f:GetName()) then return nil end
  if not f.IsShown or not f:IsShown() then return nil end
  if not HasStatusBarChild(f) then return nil end
  return GetFirstFontStringText(f)
end

function TD:CollectVisibleNames(dest)
  Wipe(dest)

  -- target + mouseover are "free" visibility hints (but IGNORE corpses)
  -- Looting often keeps a dead mob targeted; without this, we would "learn" a fake respawn instantly.
  if UnitExists("target") and not UnitIsDeadOrGhost("target") and (UnitHealth("target") or 0) > 0 then
    local tn = UnitName("target")
    if tn then dest[tn] = true end
  end
  if UnitExists("mouseover") and not UnitIsDeadOrGhost("mouseover") and (UnitHealth("mouseover") or 0) > 0 then
    local mn = UnitName("mouseover")
    if mn then dest[mn] = true end
  end

  -- scan nameplates
  -- NOTE: Vanilla 1.12's embedded Lua does NOT provide the global 'select' on some clients.
  -- Pack children into a table and iterate safely.
  local children = { WorldFrame:GetChildren() }
  local count = table.getn(children)
  for i = 1, count do
    local child = children[i]
    local name = GetNameplateName(child)
    if name then
      dest[name] = true
    end
  end
end

-- =========================
-- UI
-- =========================
TD.ui = nil
TD.rows = {}

local function CreateUI()
  if TD.ui then return end

  local f = CreateFrame("Frame", "TrapdaddyFrame", UIParent)
  TD.ui = f
  f:SetWidth(260)
  f:SetHeight(24)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
  f:SetScale(TD.db.config.scale or 1.0)

  f:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
  })
  f:SetBackdropColor(0, 0, 0, 0.70)

  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetMovable(true)
  f:SetClampedToScreen(true)

  f:SetScript("OnDragStart", function()
    if TD.db.config.locked then return end
    f:StartMoving()
  end)
  f:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
  end)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -6)
  title:SetText("Trapdaddy")

  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -6)
  hint:SetText("(/td)")

  f.title = title
  f.hint = hint
end

local function EnsureRow(i)
  if TD.rows[i] then return TD.rows[i] end
  local f = TD.ui
  local row = CreateFrame("Frame", nil, f)
  row:SetHeight(16)
  row:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -22 - ((i-1) * 16))
  row:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -22 - ((i-1) * 16))

  local left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  left:SetPoint("LEFT", row, "LEFT", 0, 0)
  left:SetJustifyH("LEFT")

  local right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  right:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  right:SetJustifyH("RIGHT")

  row.left = left
  row.right = right
  TD.rows[i] = row
  return row
end

function TD:UpdateUI()
  if not TD.ui then return end

  local shown = TD.db.config.shown
  local n = MobCount()
  if not shown or n == 0 then
    TD.ui:Hide()
    return
  end
  TD.ui:Show()

  -- build sorted list of names
  -- Some 1.12/Lua5.0 environments can mis-handle table lengths if an old-style
  -- 'n' field ever appears, which can cause table.sort to compare a string with nil.
  -- To be extra robust, build a fresh array each update and use a nil-safe comparator.
  local names = {}
  local nn = 0
  for name in pairs(TD.db.mobs) do
    nn = nn + 1
    names[nn] = name
  end
  table.sort(names, function(a, b)
    if a == nil then return false end
    if b == nil then return true end
    return tostring(a) < tostring(b)
  end)

  local maxRows = TD.db.config.maxRows or 8
  maxRows = Clamp(maxRows, 1, 20)

  local now = GetTime()
  local rowsShown = 0

  for idx = 1, maxRows do
    local row = EnsureRow(idx)
    local name = names[idx]

    if name then
      rowsShown = rowsShown + 1
      local mob = TD.db.mobs[name]
      local st = TD.state[name] or { timing = false, lastDeathAt = nil }

      row.left:SetText(name)

      local text = ""
      if st.timing and st.lastDeathAt then
        if mob.respawn and mob.respawn > 0 then
          local remain = mob.respawn - (now - st.lastDeathAt)
          if remain <= 0 then
            text = "ready"
          else
            text = FormatTime(remain)
          end
        else
          text = "timing..."
        end
      else
        -- Not currently timing
        if st.lastDeathAt and mob.respawn and mob.respawn > 0 then
          local remain = mob.respawn - (now - st.lastDeathAt)
          if remain > 0 then
            text = FormatTime(remain)
          else
            text = "ready"
          end
        else
          if mob.respawn and mob.respawn > 0 then
            text = "base " .. FormatTime(mob.respawn)
          else
            text = "tracked"
          end
        end
      end

      row.right:SetText(text)
      row:Show()
    else
      row.left:SetText("")
      row.right:SetText("")
      row:Hide()
    end
  end

  -- resize panel height to fit rows (plus header)
  local h = 24 + (rowsShown * 16) + 10
  TD.ui:SetHeight(h)
end

-- =========================
-- Death parsing + state transitions
-- =========================
local function ParseDeathMessage(msg)
  if IsEmpty(msg) then return nil end
  -- Vanilla EN patterns:
  --  "X dies."
  --  "You have slain X!"
  local name = string.find(msg, "^(.+) dies%.$")
  if name then return name end
  name = string.find(msg, "^You have slain (.+)!$")
  if name then return name end
  return nil
end

function TD:MarkDeath(name)
  local mob, st = EnsureMob(name)
  if not mob or not st then return end

  st.timing = true
  st.lastDeathAt = GetTime()

  -- UI will show "timing..." if no baseline yet, otherwise countdown
end

function TD:MarkRespawnSeen(name)
  local mob, st = EnsureMob(name)
  if not mob or not st then return end
  if not st.timing or not st.lastDeathAt then return end

  local now = GetTime()
  local dt = now - st.lastDeathAt
  if (not mob.respawn) or mob.respawn <= 0 then
    mob.respawn = math.floor(dt + 0.5)
    TD_Print("Learned respawn for |cff00ff00" .. name .. "|r: " .. FormatTime(mob.respawn))
  end

  st.timing = false
  -- keep lastDeathAt as the most recent death time so countdown can still show if needed
end

-- =========================
-- Slash Commands
-- =========================
function TD:Help()
  TD_Print("Commands:")
  TD_Print("  /td track    - track your current target")
  TD_Print("  /td untrack  - untrack your current target")
  TD_Print("  /td list     - list tracked mobs")
  TD_Print("  /td reset <name> - forget learned respawn for name")
  TD_Print("  /td clear    - clear all tracked mobs")
  TD_Print("  /td show | hide")
  TD_Print("  /td lock | unlock")
end

function TD:CmdTrack()
  if not UnitExists("target") then
    TD_Print("No target.")
    return
  end
  local name = UnitName("target")
  if IsEmpty(name) then
    TD_Print("Couldn't read target name.")
    return
  end

  EnsureMob(name)
  TD_Print("Tracking |cff00ff00" .. name .. "|r")
  self:UpdateUI()
end

function TD:CmdUntrack()
  if not UnitExists("target") then
    TD_Print("No target.")
    return
  end
  local name = UnitName("target")
  if IsEmpty(name) then
    TD_Print("Couldn't read target name.")
    return
  end

  if TD.db.mobs[name] then
    RemoveMob(name)
    TD_Print("Untracked |cffff6666" .. name .. "|r")
  else
    TD_Print("Not tracked: " .. name)
  end
  self:UpdateUI()
end

function TD:CmdList()
  local n = 0
  TD_Print("Tracked mobs:")
  for name, mob in pairs(TD.db.mobs) do
    n = n + 1
    local base = (mob.respawn and mob.respawn > 0) and (" (base " .. FormatTime(mob.respawn) .. ")") or ""
    TD_Print("  - " .. name .. base)
  end
  if n == 0 then
    TD_Print("  (none)")
  end
end

function TD:CmdReset(name)
  if IsEmpty(name) then
    TD_Print("Usage: /td reset <name>")
    return
  end
  local mob = TD.db.mobs[name]
  if not mob then
    TD_Print("Not tracked: " .. name)
    return
  end
  mob.respawn = nil
  TD_Print("Forgot learned respawn for " .. name)
  self:UpdateUI()
end

function TD:CmdClear()
  TD.db.mobs = {}
  TD.state = {}
  TD_Print("Cleared all tracked mobs.")
  self:UpdateUI()
end

function TD:CmdShowHide(show)
  TD.db.config.shown = show and true or false
  if TD.ui then
    if show then TD.ui:Show() else TD.ui:Hide() end
  end
  self:UpdateUI()
end

function TD:CmdLock(lock)
  TD.db.config.locked = lock and true or false
  TD_Print(lock and "UI locked." or "UI unlocked (drag to move).")
end

-- /td ... handler
local function TD_Slash(msg)
  msg = msg or ""
  msg = string.lower(msg)

  if msg == "" or msg == "help" then
    TD:Help()
    return
  end

  if msg == "track" then
    TD:CmdTrack()
    return
  end

  if msg == "untrack" then
    TD:CmdUntrack()
    return
  end

  if msg == "list" then
    TD:CmdList()
    return
  end

  if msg == "clear" then
    TD:CmdClear()
    return
  end

  if msg == "show" then
    TD:CmdShowHide(true)
    return
  end

  if msg == "hide" then
    TD:CmdShowHide(false)
    return
  end

  if msg == "lock" then
    TD:CmdLock(true)
    return
  end

  if msg == "unlock" then
    TD:CmdLock(false)
    return
  end

  local cmd, rest = string.find(msg, "^(%S+)%s*(.-)$")
  if cmd == "reset" then
    if IsEmpty(rest) then
      TD_Print("Usage: /td reset <name>")
    else
      -- keep original casing as best we can by finding an exact key
      -- (fallback: use rest as typed)
      local exact = nil
      for n in pairs(TD.db.mobs) do
        if string.lower(n) == string.lower(rest) then exact = n break end
      end
      TD:CmdReset(exact or rest)
    end
    return
  end

  TD_Print("Unknown command: " .. msg)
  TD:Help()
end

-- =========================
-- Event & Update Loop
-- =========================
TD.scanAccum = 0
TD.uiAccum = 0

function TD:OnEvent(event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON then return end
    self.db = EnsureDB()
    CreateUI()

    -- Slash commands
    SLASH_TRAPDADDY1 = "/td"
    SlashCmdList["TRAPDADDY"] = TD_Slash

    -- Convenience aliases
    SLASH_TRAPDADDYTRACK1 = "/track"
    SlashCmdList["TRAPDADDYTRACK"] = function() TD:CmdTrack() end

    SLASH_TRAPDADDYUNTRACK1 = "/untrack"
    SlashCmdList["TRAPDADDYUNTRACK"] = function() TD:CmdUntrack() end
    return
  end

  if event == "PLAYER_LOGIN" then
    -- ensure UI visibility reflects config
    if self.ui then
      if self.db.config.shown and MobCount() > 0 then
        self.ui:Show()
      else
        self.ui:Hide()
      end
    end
    self:UpdateUI()
    return
  end

  if event == "CHAT_MSG_COMBAT_HOSTILE_DEATH" or event == "CHAT_MSG_COMBAT_FRIENDLY_DEATH" then
    local name = ParseDeathMessage(arg1)
    if name and self.db and self.db.mobs and self.db.mobs[name] then
      self:MarkDeath(name)
      -- optional: print when first learning
      if not self.db.mobs[name].respawn then
        TD_Print("Down: " .. name .. " (learning respawn...)")
      end
      self:UpdateUI()
    end
    return
  end
end

function TD:OnUpdate(elapsed)
  if not self.db then return end
  if MobCount() == 0 then
    -- keep UI synced in case user hides/show
    if self.uiAccum then
      self.uiAccum = self.uiAccum + elapsed
      if self.uiAccum >= (self.db.config.uiInterval or 0.15) then
        self.uiAccum = 0
        self:UpdateUI()
      end
    end
    return
  end

  self.scanAccum = self.scanAccum + elapsed
  self.uiAccum = self.uiAccum + elapsed

  local scanEvery = self.db.config.scanInterval or 0.35
  if self.scanAccum >= scanEvery then
    self.scanAccum = 0

    -- 1) build visible name set once
    self:CollectVisibleNames(self.visible)

    -- 2) for each tracked mob that's timing, see if it's visible again
    for name in pairs(self.db.mobs) do
      local st = self.state[name]
      if st and st.timing and self.visible[name] then
        self:MarkRespawnSeen(name)
      end
    end
  end

  local uiEvery = self.db.config.uiInterval or 0.15
  if self.uiAccum >= uiEvery then
    self.uiAccum = 0
    self:UpdateUI()
  end
end

-- register events
TD:RegisterEvent("ADDON_LOADED")
TD:RegisterEvent("PLAYER_LOGIN")
TD:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
TD:RegisterEvent("CHAT_MSG_COMBAT_FRIENDLY_DEATH")
