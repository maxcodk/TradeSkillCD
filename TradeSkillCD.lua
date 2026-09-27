--[[
  TradeSkillCD
  ------------
  Tracks profession cooldowns (Alchemy, Tailoring, Leatherworking) for
  WoW 1.12 (Turtle WoW / Octo WoW).

  Design notes:
   1. Fully standalone addon. Data is stored in its own SavedVariables
      file (TSCD_DB), which the client automatically writes to
      WTF/Account/<ACCOUNT>/SavedVariables/TradeSkillCD.lua.
      No dependency on pfUI - if pfUI happens to be loaded, the addon
      will additionally hook a tooltip onto the pfUI clock widget, but
      that is purely optional.
   2. If SuperWoW (https://github.com/balakethelock/SuperWoW) is
      installed, the addon also reads/writes a shared file through
      SuperWoW's global ImportFile/ExportFile functions. That file
      lives OUTSIDE the WTF folder (in the client root), so every
      account launched from the same game folder can see it - this is
      the same trick FullSack (Otari98) uses for cross-account data.
      Without SuperWoW the addon still works fine, just scoped to a
      single account.
   3. Everything happens through chat slash commands (/tscd ...). The
      main event handler runs inside pcall, so a problem in any single
      event can only print a diagnostic message instead of silently
      breaking the rest of the addon.
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
-- Soft, muted paladin-pink theme for the addon's own branding/headers;
-- functional colors (ready/off/etc.) stay close to their usual meaning
-- so status output stays easy to scan at a glance.
-------------------------------------------------------------------

local colors = {
  pink  = "|cffe08cb4", -- brand color: addon name, headers, section titles
  rose  = "|cffcf9fb2", -- softer pink, used for secondary accents
  green = "|cff59c98a", -- ready / on
  red   = "|cffe0736b", -- off / error
  white = "|cfff2e6ec", -- warm-white body text
  grey  = "|cff9c8b93", -- muted secondary text (timestamps, hints)
}

local function C(color, text)
  if not colors[color] then return text end
  return colors[color] .. text .. "|r"
end

local MSG_PREFIX = C("pink", "TradeSkillCD") .. C("grey", " » ")

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage(MSG_PREFIX .. msg)
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

-- Absolute "ready at" timestamp, used in /tscd status
local function FormatAbsolute(ts)
  if ts == 0 then return C("green", "ready") end
  return date("%d.%m %H:%M", ts)
end

-------------------------------------------------------------------
-- Player / realm
-------------------------------------------------------------------

local player_name = UnitName("player")
local realm_name  = GetRealmName()

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
    Print(C("rose", tradeskill_list[prof_index].name) .. " is now on cooldown: " .. FormatDuration(seconds_from_now))
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
    local who = (char == player_name and realm == realm_name) and "" or (C("grey", char .. " » "))
    Print(who .. C("rose", tradeskill_list[prof_index].name) .. ": " .. C("green", "ready!"))
    if TSCD_CFG.noti_sound then
      PlaySound("LEVELUP")
    end
    if TSCD_CFG.noti_rw and char == player_name and realm == realm_name then
      UIErrorsFrame:AddMessage(MSG_PREFIX .. tradeskill_list[prof_index].name .. " ready!", 0.94, 0.65, 0.80)
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
            Print(C("rose", tradeskill_list[i].name) .. " cooldown: " .. FormatDuration(cd))
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
-- Status on request
-------------------------------------------------------------------

local function PrintStatus(only_self)
  local printed = false
  Print(C("pink", "── cooldown status ──"))
  for realm in TSCD_DB do
    for char in TSCD_DB[realm] do
      if not only_self or (char == player_name and realm == realm_name) then
        local shown_char = false
        for prof in tradeskill_list do
          local e = TSCD_DB[realm][char][prof]
          if type(e) == "table" then
            if not only_self and not shown_char then
              local label = (char == player_name and realm == realm_name) and C("pink", char) or C("white", char)
              Print(label)
              shown_char = true
            end
            local remaining = e.ready == 0 and 0 or (e.ready - time())
            local indent = only_self and "" or "   "
            Print(indent .. C("rose", " " .. tradeskill_list[prof].name) .. ": " .. FormatDuration(remaining) ..
                  C("grey", "  (" .. FormatAbsolute(e.ready) .. ")"))
            printed = true
          end
        end
      end
    end
  end
  if not printed then
    Print(C("grey", "no data yet - run ") .. C("pink", "/tscd scan"))
  end
end

-------------------------------------------------------------------
-- Optional pfUI integration (only if pfUI is loaded)
-------------------------------------------------------------------

local function TryHookPfUI()
  if not pfUI or not getglobal("pfPanelWidgetClock") then return end
  local widget_clock = getglobal("pfPanelWidgetClock")
  if widget_clock.Old_Tooltip_tscd then return end -- already hooked
  widget_clock.Old_Tooltip_tscd = widget_clock.Tooltip
  widget_clock.Tooltip = function()
    widget_clock.Old_Tooltip_tscd()
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(C("pink", "TradeSkillCD"))
    local any = false
    for prof in tradeskill_list do
      local e = TSCD_DB[realm_name] and TSCD_DB[realm_name][player_name] and TSCD_DB[realm_name][player_name][prof]
      if type(e) == "table" then
        local remaining = e.ready == 0 and 0 or (e.ready - time())
        GameTooltip:AddDoubleLine(" " .. tradeskill_list[prof].name, FormatDuration(remaining))
        any = true
      end
    end
    if not any then
      GameTooltip:AddLine(C("grey", "no data"))
    end
    GameTooltip:Show()
  end
end

-------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------

local function HelpCommand()
  Print(C("pink", "TradeSkillCD") .. C("grey", "  v1.0"))
  Print(C("rose", "/tscd scan") .. C("grey", "  - check profession and tool cooldowns"))
  Print(C("rose", "/tscd status") .. C("grey", "  - show your character's cooldowns"))
  Print(C("rose", "/tscd status all") .. C("grey", "  - show cooldowns for all known characters"))
  Print(C("rose", "/tscd sync") .. C("grey", "  - force a SuperWoW synchronization"))
  Print(C("rose", "/tscd chat|rw|sound") .. C("grey", "  - toggle the matching notification type"))
end

local function SlashHandler(msg)
  msg = msg or ""
  local cmd = strlower(gsub(msg, "^%s*(.-)%s*$", "%1"))

  if cmd == "" or cmd == "help" then
    HelpCommand()
  elseif cmd == "scan" then
    ManualCheckAll()
    Print(C("grey", "scan complete."))
  elseif cmd == "status" then
    PrintStatus(true)
  elseif cmd == "status all" then
    PrintStatus(false)
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
    Print("chat notifications: " .. (TSCD_CFG.noti_chat and C("green", "on") or C("red", "off")))
  elseif cmd == "rw" then
    TSCD_CFG.noti_rw = not TSCD_CFG.noti_rw
    Print("screen notifications: " .. (TSCD_CFG.noti_rw and C("green", "on") or C("red", "off")))
  elseif cmd == "sound" then
    TSCD_CFG.noti_sound = not TSCD_CFG.noti_sound
    Print("ready sound: " .. (TSCD_CFG.noti_sound and C("green", "on") or C("red", "off")))
  else
    Print(C("grey", "unknown command, type ") .. C("pink", "/tscd help"))
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
    TryHookPfUI()
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
    TryHookPfUI()

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
