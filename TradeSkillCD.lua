--[[
  TradeSkillCD
  ------------
  Tracks profession cooldowns (Alchemy, Tailoring, Leatherworking) for
  WoW 1.12 (Turtle WoW / Octo WoW).

  Design notes:
   1. Fully standalone addon. Data is stored in its own SavedVariables
      file (TSCD_DB), which the client automatically writes to
      WTF/Account/<ACCOUNT>/SavedVariables/TradeSkillCD.lua.
      No dependency on pfUI - if pfUI is installed, the addon also
      appends the cooldown list to the tooltip of pfUI's clock widget,
      but that is purely optional.
   2. If SuperWoW (https://github.com/balakethelock/SuperWoW) is
      installed, the addon also reads/writes a shared file through
      SuperWoW's global ImportFile/ExportFile functions. That file
      lives OUTSIDE the WTF folder (in the client root), so every
      account launched from the same game folder can see it - this is
      the same trick FullSack (Otari98) uses for cross-account data.
      Without SuperWoW the addon still works fine, just scoped to a
      single account.
   3. Everything else happens through chat slash commands (/tscd ...).
      The main event handler runs inside pcall, so a problem in any
      single event can only print a diagnostic message instead of
      silently breaking the rest of the addon.
   4. Tool items with a passive, icon-only cooldown (Salt Shaker etc.)
      are detected automatically: bag/bank changes are watched and,
      shortly after, the addon quietly checks the tracked tool items'
      cooldown swirl and records it - no manual /tscd scan required.
--]]

local ADDON_NAME  = "TradeSkillCD"
local SHARED_FILE = "TradeSkillCD_Shared" -- shared file name for ExportFile/ImportFile

-------------------------------------------------------------------
-- Colors / formatting
--
-- Deliberately neutral: soft whites and greys for almost everything,
-- muted green/red only where they carry meaning (ready / on / off /
-- error). The paladin-pink accent is reserved for a few titles.
-------------------------------------------------------------------

local colors = {
  pink  = "|cffe08cb4", -- accent: titles/headers only
  green = "|cff6fbf8f", -- ready / on
  red   = "|cffd9827b", -- off / error
  white = "|cffe6e6e6", -- primary text
  grey  = "|cff9a9a9a", -- secondary text
  dim   = "|cff666666", -- separators, timestamps
}

local function C(color, text)
  if not colors[color] then return text end
  return colors[color] .. text .. "|r"
end

local MSG_PREFIX = C("grey", "TSCD") .. C("dim", " » ")

-- Message with the addon prefix
local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage(MSG_PREFIX .. msg)
end

-- Message without prefix (used for indented body lines)
local function Raw(msg)
  DEFAULT_CHAT_FRAME:AddMessage(msg)
end

-- Formats a remaining duration as "Xd Yh" / "Xh Ym" / "Xm Ys"
local function FormatDuration(seconds)
  if seconds <= 0 then
    return C("green", "ready")
  end
  local d = floor(seconds / 86400)
  local h = floor(mod(seconds, 86400) / 3600)
  local m = floor(mod(seconds, 3600) / 60)
  local s = mod(seconds, 60)
  if d > 0 then
    return C("white", d .. "d " .. h .. "h")
  elseif h > 0 then
    return C("white", h .. "h " .. m .. "m")
  elseif m > 0 then
    return C("white", m .. "m " .. s .. "s")
  else
    return C("white", s .. "s")
  end
end

-------------------------------------------------------------------
-- Player / realm
-------------------------------------------------------------------

local player_name = UnitName("player")
local realm_name  = GetRealmName()

local function IsCurrent(realm, char)
  return char == player_name and realm == realm_name
end

-------------------------------------------------------------------
-- Profession list and cooldown-marker items
-------------------------------------------------------------------

-- index -> {name, texture, spell_id(filled in by the spellbook scan)}
local tradeskill_list = {
  [1] = { name = "Alchemy",         texture = "Interface\\Icons\\Trade_Alchemy" },
  [2] = { name = "Tailoring",       texture = "Interface\\Icons\\Trade_Tailoring" },
  [3] = { name = "Leatherworking",  texture = "Interface\\Icons\\INV_Misc_ArmorKit_17" },
}

-- Items whose crafting grants a fixed profession cooldown
-- (detected through CHAT_MSG_LOOT at the moment of crafting)
--   t = cooldown duration in seconds
--   i = profession index from tradeskill_list
--   shared_check = true -> this item has no cooldown of its own; it
--                  shares its cooldown with another item of the same
--                  profession (example: Truesilver Bar/Gold Bar share
--                  the same transmute cooldown as Arcanite Bar) - in
--                  that case, instead of a fixed timer, the addon
--                  opens the profession window and checks the real
--                  cooldown.
local tradeskill_items = {
  ["12360"] = { t = 172800, i = 1 },                  -- Arcanite Bar (Alchemy, 48h)
  ["6037"]  = { t = 172800, i = 1, shared_check = 1 }, -- Truesilver Bar (same cooldown as Arcanite)
  ["3577"]  = { t = 172800, i = 1, shared_check = 1 }, -- Gold Bar (same cooldown as Arcanite)
  ["14342"] = { t = 345600, i = 2 },                  -- Mooncloth (Tailoring, 96h)
}

-- One-shot tools whose cooldown is tracked through the item icon in
-- the bags/bank (GetContainerItemCooldown). These are picked up
-- automatically by the bag-scan below, no crafting/loot event for them.
local tradeskill_tools = {
  ["15846"] = { t = 259200, i = 3 }, -- Salt Shaker -> Refined Deeprock Salt (Leatherworking, 72h)
}

-------------------------------------------------------------------
-- SuperWoW / cross-account synchronization
-------------------------------------------------------------------

local function HasSuperWoW()
  return SUPERWOW_VERSION and tonumber(SUPERWOW_VERSION) and ImportFile and ExportFile
end

-- Serializes TSCD_DB into a plain lua chunk (same approach as FullSack)
-- for ExportFile
local function SerializeDB(db)
  local chunk = "return {\n"
  for realm in db do
    chunk = chunk .. "[\"" .. realm .. "\"]={\n"
    for char in db[realm] do
      chunk = chunk .. "\t[\"" .. char .. "\"]={\n"
      for prof in db[realm][char] do
        local e = db[realm][char][prof]
        if type(e) == "table" and e.ready and e.updated then
          chunk = chunk .. "\t\t[" .. prof .. "]={ready=" .. e.ready .. ",updated=" .. e.updated .. "},\n"
        end
      end
      chunk = chunk .. "\t},\n"
    end
    chunk = chunk .. "},\n"
  end
  chunk = chunk .. "}"
  return chunk
end

-- Merges imported data (from the shared file) into TSCD_DB; the entry
-- with the more recent "updated" field wins
local function MergeDB(imported)
  if type(imported) ~= "table" then return end
  for realm in imported do
    if type(imported[realm]) == "table" then
      TSCD_DB[realm] = TSCD_DB[realm] or {}
      for char in imported[realm] do
        if type(imported[realm][char]) == "table" then
          TSCD_DB[realm][char] = TSCD_DB[realm][char] or {}
          for prof in imported[realm][char] do
            local remote = imported[realm][char][prof]
            local local_e = TSCD_DB[realm][char][prof]
            if type(remote) == "table" and remote.updated then
              if not local_e or not local_e.updated or remote.updated > local_e.updated then
                TSCD_DB[realm][char][prof] = { ready = remote.ready or 0, updated = remote.updated }
              end
            end
          end
        end
      end
    end
  end
end

local function SyncImport()
  if not HasSuperWoW() then return end
  local raw = ImportFile(SHARED_FILE)
  if not raw or raw == "" then return end
  local chunk = loadstring(raw)
  if not chunk then return end
  local ok, imported = pcall(chunk)
  if ok and type(imported) == "table" then
    MergeDB(imported)
  end
end

local function SyncExport()
  if not HasSuperWoW() then return end
  ExportFile(SHARED_FILE, SerializeDB(TSCD_DB))
end

-------------------------------------------------------------------
-- Cooldown data handling
-------------------------------------------------------------------

local function EnsurePath(realm, char)
  TSCD_DB[realm] = TSCD_DB[realm] or {}
  TSCD_DB[realm][char] = TSCD_DB[realm][char] or {}
end

-- Timestamp (time()) of the earliest cooldown that still needs to be
-- watched for expiry, or nil if nothing is pending. This lets the
-- periodic ticker skip the full DB scan on almost every tick - see the
-- "Periodic cooldown-expiry check" section below.
local next_check_at = nil

local function RecomputeNextCheck()
  local earliest = nil
  for realm in TSCD_DB do
    for char in TSCD_DB[realm] do
      for prof in TSCD_DB[realm][char] do
        local e = TSCD_DB[realm][char][prof]
        if type(e) == "table" and e.ready and e.ready ~= 0 then
          if not earliest or e.ready < earliest then
            earliest = e.ready
          end
        end
      end
    end
  end
  next_check_at = earliest
end

-- Sets a cooldown "ready in X seconds from now" for the CURRENT character
local function SetCooldown(prof_index, seconds_from_now)
  EnsurePath(realm_name, player_name)
  local now = time()
  TSCD_DB[realm_name][player_name][prof_index] = { ready = now + seconds_from_now, updated = now }
  if TSCD_CFG.noti_chat then
    Print(C("white", tradeskill_list[prof_index].name) .. C("grey", " is now on cooldown: ") .. FormatDuration(seconds_from_now))
  end
  RecomputeNextCheck()
end

-- Same as SetCooldown, but skips the write/announcement entirely if we
-- already have essentially the same cooldown recorded (within a small
-- tolerance). Used by the automatic bag scan so that re-detecting the
-- SAME ongoing Salt Shaker cooldown every couple of seconds doesn't
-- spam chat - only a genuinely NEW cooldown gets announced.
local COOLDOWN_CHANGE_THRESHOLD = 10 -- seconds

local function SetCooldownIfChanged(prof_index, seconds_from_now)
  local new_ready = time() + seconds_from_now
  local existing = TSCD_DB[realm_name] and TSCD_DB[realm_name][player_name] and TSCD_DB[realm_name][player_name][prof_index]
  if existing and existing.ready and existing.ready ~= 0 then
    local diff = existing.ready - new_ready
    if diff < 0 then diff = -diff end
    if diff <= COOLDOWN_CHANGE_THRESHOLD then
      return -- same cooldown we already know about, nothing changed
    end
  end
  SetCooldown(prof_index, seconds_from_now)
end

-- Marks a profession as ready right now
local function MarkReady(realm, char, prof_index, announce)
  TSCD_DB[realm][char][prof_index].ready = 0
  TSCD_DB[realm][char][prof_index].updated = time()
  if announce then
    local who = IsCurrent(realm, char) and "" or (C("white", char) .. C("dim", " · "))
    Print(who .. C("white", tradeskill_list[prof_index].name) .. C("grey", ": ") .. C("green", "ready!"))
    if TSCD_CFG.noti_sound then
      PlaySound("LEVELUP")
    end
    if TSCD_CFG.noti_rw and IsCurrent(realm, char) then
      UIErrorsFrame:AddMessage(tradeskill_list[prof_index].name .. " ready!", 0.65, 0.9, 0.75)
    end
  end
end

-------------------------------------------------------------------
-- Spellbook scan - detects spell_id of the professions the character knows
-------------------------------------------------------------------

local function ScanSpellbook()
  local _, _, offset, num = GetSpellTabInfo(1) -- professions are always on the first tab
  if not offset then return end
  for id = offset + 1, offset + num do
    local tex = GetSpellTexture(id, BOOKTYPE_SPELL)
    local name = GetSpellName(id, BOOKTYPE_SPELL)
    for i in tradeskill_list do
      if tex == tradeskill_list[i].texture then
        tradeskill_list[i].spell_id = id
        tradeskill_list[i].name = name or tradeskill_list[i].name
      end
    end
  end
end

-------------------------------------------------------------------
-- Manual check through the profession window (opens/closes the window)
-------------------------------------------------------------------

local function ManualTradeskillCheck(only_index)
  local now = time()
  for i in tradeskill_list do
    if tradeskill_list[i].spell_id and (not only_index or only_index == i) then
      CastSpell(tradeskill_list[i].spell_id, BOOKTYPE_SPELL)
      local num = GetNumTradeSkills and GetNumTradeSkills() or 0
      for slot = 1, num do
        local cd = GetTradeSkillCooldown and GetTradeSkillCooldown(slot)
        if cd and cd > 0 then
          EnsurePath(realm_name, player_name)
          TSCD_DB[realm_name][player_name][i] = { ready = now + cd, updated = now }
          if TSCD_CFG.noti_chat then
            Print(C("white", tradeskill_list[i].name) .. C("grey", " cooldown: ") .. FormatDuration(cd))
          end
        end
      end
      CloseTradeSkill()
    end
  end
  RecomputeNextCheck()
end

-------------------------------------------------------------------
-- Manual check of tools in bags/bank (Salt Shaker etc.)
-------------------------------------------------------------------

local function ManualItemCheck()
  for bag = -1, 10 do
    local size = GetContainerNumSlots(bag)
    if size and size > 0 then
      for slot = 1, size do
        local link = GetContainerItemLink(bag, slot)
        if link and link ~= "" then
          local _, _, item_id = strfind(link, "item:(%d+)")
          local tool = item_id and tradeskill_tools[item_id]
          if tool then
            local start, duration = GetContainerItemCooldown(bag, slot)
            if start and start > 0 and duration == tool.t then
              local remaining = tool.t - (GetTime() - start)
              SetCooldownIfChanged(tool.i, remaining)
            end
          end
        end
      end
    end
  end
end

local function ManualCheckAll()
  ManualTradeskillCheck()
  ManualItemCheck()
end

-------------------------------------------------------------------
-- Automatic tool-cooldown detection (e.g. Salt Shaker)
--
-- Bag/bank contents change very often (looting, moving items,
-- vendoring), so instead of scanning on every single BAG_UPDATE we
-- just set a "pending" flag and let a throttled OnUpdate perform the
-- actual (cheap, read-only) scan a couple of seconds later. Combined
-- with SetCooldownIfChanged above, this means: use a Salt Shaker, and
-- within a couple of seconds its cooldown is recorded and announced
-- automatically - no manual /tscd scan needed. This never opens any
-- profession window, so it can't interrupt anything you're doing.
-------------------------------------------------------------------

local BAG_SCAN_INTERVAL = 2 -- seconds
local bag_scan_pending = false
local bag_scan_last = 0
local bag_scan_frame = CreateFrame("Frame")

bag_scan_frame:SetScript("OnUpdate", function()
  if not bag_scan_pending then return end
  local now = GetTime()
  if now - bag_scan_last < BAG_SCAN_INTERVAL then return end
  bag_scan_last = now
  bag_scan_pending = false
  ManualItemCheck()
end)

local function RequestBagScan()
  bag_scan_pending = true
end

-------------------------------------------------------------------
-- Craft detection through CHAT_MSG_LOOT (Arcanite Bar / Mooncloth etc.)
-------------------------------------------------------------------

local function OnLootMessage(msg)
  if not msg then return end
  local filter_created = gsub(LOOT_ITEM_CREATED_SELF or "", "%%.-s.", "")
  if filter_created == "" or not strfind(msg, filter_created) then return end

  local _, _, item_id = strfind(msg, "item:(%d+)")
  if not item_id then return end

  local entry = tradeskill_items[item_id]
  if not entry then return end

  if entry.shared_check then
    -- this item has no fixed cooldown of its own - re-check the profession window
    ManualTradeskillCheck(entry.i)
  else
    SetCooldown(entry.i, entry.t)
  end
end

-------------------------------------------------------------------
-- Periodic cooldown-expiry check + ready announcement
--
-- OnUpdate fires every rendered frame, so two things keep this cheap:
--  1. A throttle (TICK_INTERVAL) so the actual logic below runs at
--     most every few real seconds, not every frame.
--  2. next_check_at (see RecomputeNextCheck above) lets a throttled
--     tick skip the DB scan entirely unless a tracked cooldown is
--     actually due - so on a normal tick the whole handler is just
--     two number comparisons, and the full realm/char/profession scan
--     only runs right when something is about to become ready (or
--     right after scan/craft/sync changes the data).
-------------------------------------------------------------------

local TICK_INTERVAL = 5 -- seconds; cooldowns run in hours/days, so second-level precision isn't needed
local tick_frame = CreateFrame("Frame")
local last_tick = 0

local function UpdateTicker()
  local now = GetTime()
  if now - last_tick < TICK_INTERVAL then return end
  last_tick = now

  if not next_check_at then return end -- nothing pending, nothing to scan

  local rt = time()
  if rt < next_check_at then return end -- earliest pending cooldown isn't due yet

  for realm in TSCD_DB do
    for char in TSCD_DB[realm] do
      for prof in TSCD_DB[realm][char] do
        local e = TSCD_DB[realm][char][prof]
        if type(e) == "table" and e.ready and e.ready ~= 0 and e.ready <= rt then
          MarkReady(realm, char, prof, true)
        end
      end
    end
  end

  RecomputeNextCheck()
end

tick_frame:SetScript("OnUpdate", UpdateTicker)

-------------------------------------------------------------------
-- Character list + status output
-------------------------------------------------------------------

-- Every known character as {realm=, char=}: current character first,
-- then the rest of the current realm, then other realms - alphabetical
-- within each group, so the output order is always stable.
local function CollectCharacters()
  local list = {}
  for realm in TSCD_DB do
    for char in TSCD_DB[realm] do
      table.insert(list, { realm = realm, char = char })
    end
  end
  table.sort(list, function(a, b)
    local a_me = IsCurrent(a.realm, a.char)
    local b_me = IsCurrent(b.realm, b.char)
    if a_me ~= b_me then return a_me end
    local a_here = (a.realm == realm_name)
    local b_here = (b.realm == realm_name)
    if a_here ~= b_here then return a_here end
    if a.realm ~= b.realm then return a.realm < b.realm end
    return a.char < b.char
  end)
  return list
end

-- Rows {name=, remaining=, ready_at=} for one character, in fixed profession order
local function CollectRows(realm, char)
  local rows = {}
  for prof = 1, table.getn(tradeskill_list) do
    local e = TSCD_DB[realm][char][prof]
    if type(e) == "table" and e.ready then
      local remaining = 0
      if e.ready ~= 0 then remaining = e.ready - time() end
      table.insert(rows, { name = tradeskill_list[prof].name, remaining = remaining, ready_at = e.ready })
    end
  end
  return rows
end

local function CharacterLabel(realm, char)
  local label = C("white", char)
  if realm ~= realm_name then
    label = label .. C("dim", " (" .. realm .. ")")
  end
  return label
end

-- Prints cooldowns for every known character (only_self = current one only)
local function PrintStatus(only_self)
  local list = CollectCharacters()
  local printed = false
  Print(C("pink", "Cooldown status"))
  for i = 1, table.getn(list) do
    local entry = list[i]
    if not only_self or IsCurrent(entry.realm, entry.char) then
      local rows = CollectRows(entry.realm, entry.char)
      if table.getn(rows) > 0 then
        printed = true
        Raw("  " .. CharacterLabel(entry.realm, entry.char))
        for r = 1, table.getn(rows) do
          local row = rows[r]
          local line = "     " .. C("grey", row.name) .. C("dim", " · ") .. FormatDuration(row.remaining)
          if row.remaining > 0 then
            line = line .. C("dim", "  " .. date("%d.%m %H:%M", row.ready_at))
          end
          Raw(line)
        end
      end
    end
  end
  if not printed then
    Print(C("grey", "no data yet - run ") .. C("white", "/tscd scan"))
  end
end

-------------------------------------------------------------------
-- Optional pfUI integration: cooldowns in the clock widget's tooltip
--
-- How pfUI wires that tooltip (see modules/panel.lua): the clock
-- widget's Tooltip function is bound ONCE to the panel button's
-- OnEnter script the first time the clock updates, and never re-read
-- afterwards. Replacing widget.Tooltip later therefore does nothing -
-- the already-bound OnEnter has to be wrapped instead. We do both:
--   * wrap the OnEnter of the panel button that shows the clock
--   * wrap widget.Tooltip too, in case something binds it again later
-- Wrapped functions are remembered, so repeating this is harmless.
-------------------------------------------------------------------

local tscd_wrapped = {} -- set of functions that already include our lines

-- Appends the cooldown list of ALL known characters to GameTooltip
local function AppendCooldownTooltip()
  if not TSCD_DB then return end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("|cff555555TradeSkillCD") -- same muted header style pfUI uses
  local any = false
  local list = CollectCharacters()
  for i = 1, table.getn(list) do
    local entry = list[i]
    local rows = CollectRows(entry.realm, entry.char)
    if table.getn(rows) > 0 then
      any = true
      GameTooltip:AddLine(CharacterLabel(entry.realm, entry.char))
      for r = 1, table.getn(rows) do
        GameTooltip:AddDoubleLine("   " .. C("grey", rows[r].name), FormatDuration(rows[r].remaining))
      end
    end
  end
  if not any then
    GameTooltip:AddLine(C("grey", "no data - use /tscd scan"))
  end
  GameTooltip:Show()
end

local function WrapTooltipFunc(fn)
  if not fn or tscd_wrapped[fn] then return fn end
  local wrapper = function()
    fn()
    AppendCooldownTooltip()
  end
  tscd_wrapped[wrapper] = true
  return wrapper
end

-- Returns true once pfUI's panel exists and the hook has been applied
local function TryHookPfUI()
  if not (pfUI and pfUI.panel and pfUI.panel.minimap) then return false end
  local widget = getglobal("pfPanelWidgetClock")
  if not widget then return false end

  local original = widget.Tooltip

  -- 1) panel buttons that already have the clock tooltip bound
  local candidates = {}
  local function add(frame)
    if frame then table.insert(candidates, frame) end
  end
  if pfUI.panel.left then
    add(pfUI.panel.left.left) add(pfUI.panel.left.center) add(pfUI.panel.left.right)
  end
  if pfUI.panel.right then
    add(pfUI.panel.right.left) add(pfUI.panel.right.center) add(pfUI.panel.right.right)
  end
  add(pfUI.panel.minimap)

  for i = 1, table.getn(candidates) do
    local frame = candidates[i]
    if frame.GetScript then
      local enter = frame:GetScript("OnEnter")
      if enter and not tscd_wrapped[enter] and (frame.initialized == "time" or enter == original) then
        frame:SetScript("OnEnter", WrapTooltipFunc(enter))
      end
    end
  end

  -- 2) anything that binds widget.Tooltip from now on
  if original and not tscd_wrapped[original] then
    widget.Tooltip = WrapTooltipFunc(original)
  end
  return true
end

-- pfUI builds its panel some time after login, so retry for a while
-- (every 2s, up to ~2 minutes) until the hook could be applied.
local pfui_hook_frame = CreateFrame("Frame")
local pfui_hook_tries = 0
local pfui_hook_last = 0

local function StartPfUIHook()
  if not pfUI then return end
  pfui_hook_tries = 0
  pfui_hook_frame:SetScript("OnUpdate", function()
    local now = GetTime()
    if now - pfui_hook_last < 2 then return end
    pfui_hook_last = now
    pfui_hook_tries = pfui_hook_tries + 1
    local ok, done = pcall(TryHookPfUI)
    if not ok then
      Print(C("red", "pfUI tooltip hook failed: ") .. tostring(done))
      this:SetScript("OnUpdate", nil)
    elseif done or pfui_hook_tries >= 60 then
      this:SetScript("OnUpdate", nil)
    end
  end)
end

-------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------

local function HelpCommand()
  Print(C("pink", "TradeSkillCD") .. C("grey", "  v1.0"))
  Raw("  " .. C("white", "/tscd scan") .. C("grey", "  check profession and tool cooldowns"))
  Raw("  " .. C("white", "/tscd status") .. C("grey", "  cooldowns of all known characters"))
  Raw("  " .. C("white", "/tscd status me") .. C("grey", "  only the current character"))
  Raw("  " .. C("white", "/tscd sync") .. C("grey", "  force a SuperWoW synchronization"))
  Raw("  " .. C("white", "/tscd chat") .. C("grey", ", ") .. C("white", "rw") .. C("grey", ", ") .. C("white", "sound") .. C("grey", "  toggle notification type"))
end

local function OnOff(value)
  return value and C("green", "on") or C("red", "off")
end

local function SlashHandler(msg)
  msg = msg or ""
  local cmd = strlower(gsub(msg, "^%s*(.-)%s*$", "%1"))

  if cmd == "" or cmd == "help" then
    HelpCommand()
  elseif cmd == "scan" then
    ManualCheckAll()
    Print(C("grey", "scan complete."))
  elseif cmd == "status" or cmd == "status all" then
    PrintStatus(false)
  elseif cmd == "status me" then
    PrintStatus(true)
  elseif cmd == "sync" then
    if HasSuperWoW() then
      SyncImport()
      SyncExport()
      Print(C("grey", "synchronization complete."))
    else
      Print(C("red", "SuperWoW not detected, synchronization unavailable."))
    end
  elseif cmd == "chat" then
    TSCD_CFG.noti_chat = not TSCD_CFG.noti_chat
    Print(C("grey", "chat notifications: ") .. OnOff(TSCD_CFG.noti_chat))
  elseif cmd == "rw" then
    TSCD_CFG.noti_rw = not TSCD_CFG.noti_rw
    Print(C("grey", "screen notifications: ") .. OnOff(TSCD_CFG.noti_rw))
  elseif cmd == "sound" then
    TSCD_CFG.noti_sound = not TSCD_CFG.noti_sound
    Print(C("grey", "ready sound: ") .. OnOff(TSCD_CFG.noti_sound))
  else
    Print(C("grey", "unknown command, type ") .. C("white", "/tscd help"))
  end
end

SLASH_TSCD1 = "/tscd"
SlashCmdList["TSCD"] = SlashHandler

-------------------------------------------------------------------
-- Events
-------------------------------------------------------------------

local main_frame = CreateFrame("Frame")
main_frame:RegisterEvent("VARIABLES_LOADED")
main_frame:RegisterEvent("PLAYER_LOGIN")
main_frame:RegisterEvent("PLAYER_LOGOUT")
main_frame:RegisterEvent("SPELLS_CHANGED")
main_frame:RegisterEvent("CHAT_MSG_LOOT")
main_frame:RegisterEvent("BAG_UPDATE")
main_frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
main_frame:RegisterEvent("BANKFRAME_OPENED")

local function HandleEvent()
  if event == "VARIABLES_LOADED" then
    TSCD_DB  = TSCD_DB or {}
    TSCD_CFG = TSCD_CFG or { noti_chat = true, noti_rw = true, noti_sound = true }

  elseif event == "PLAYER_LOGIN" then
    player_name = UnitName("player")
    realm_name  = GetRealmName()
    EnsurePath(realm_name, player_name)

    SyncImport()          -- pull in data from other accounts (if SuperWoW is present)
    ScanSpellbook()
    StartPfUIHook()       -- optional: cooldowns in pfUI's clock tooltip
    RecomputeNextCheck()  -- establish the initial "next expiry" pointer for the ticker
    RequestBagScan()      -- pick up any tool cooldowns already active on login

    if HasSuperWoW() then
      Print(C("grey", "SuperWoW detected - cross-account synchronization is enabled."))
    else
      Print(C("grey", "SuperWoW not detected - data is kept within this account only."))
    end

  elseif event == "PLAYER_LOGOUT" then
    SyncExport()           -- write the merged dataset back to the shared file (if SuperWoW is present)

  elseif event == "SPELLS_CHANGED" then
    ScanSpellbook()

  elseif event == "CHAT_MSG_LOOT" then
    OnLootMessage(arg1)

  elseif event == "BAG_UPDATE" or event == "PLAYERBANKSLOTS_CHANGED" or event == "BANKFRAME_OPENED" then
    RequestBagScan()
  end
end

main_frame:SetScript("OnEvent", function()
  local ok, err = pcall(HandleEvent)
  if not ok then
    Print(C("red", "error handling " .. tostring(event) .. ": ") .. tostring(err))
  end
end)
