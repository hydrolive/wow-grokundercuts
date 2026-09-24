-- Undercut Hunter. Forever 1.60.1 only.
-- One addon table plus the slash-command globals WoW requires.
UndercutHunter = UndercutHunter or {}

local UH = UndercutHunter

UH.CALLER_ID = "UndercutHunter"
UH.VERSION = "0.1.0-forever"
UH.MAX_BROWSE_KEYS = 100
-- Forever stacks are at most 20. Browse minPrice is documented as a unit
-- price; if a build reports a stack total instead, the detail search still
-- runs for listings that would be cheap per unit at a full stack.
UH.STACK_SLACK = 20
UH.QUERY_TIMEOUT = 8
UH.BATCH_GAP = 0.12

UH.modernAH = false
UH.legacyAH = false
UH.supportedAH = false
UH.queryLock = false
UH.attached = false

UH.handlers = {}
UH.events = CreateFrame("Frame")

function UH.On(event, fn)
  if not UH.handlers[event] then
    UH.handlers[event] = {}
    local ok = pcall(function()
      UH.events:RegisterEvent(event)
    end)
    if not ok then
      UH.handlers[event] = nil
      return
    end
  end
  UH.handlers[event][#UH.handlers[event] + 1] = fn
end

UH.events:SetScript("OnEvent", function(_, event, ...)
  local list = UH.handlers[event]
  if not list then
    return
  end
  for i = 1, #list do
    list[i](event, ...)
  end
end)

function UH.Print(...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do
    parts[i] = tostring(select(i, ...))
  end
  local text = table.concat(parts, " ")
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Undercut Hunter:|r " .. text)
  else
    print("|cff33ff99Undercut Hunter:|r " .. text)
  end
end

function UH.Debug(...)
  local db = UH.db or UndercutHunterDB
  if db and db.debug then
    UH.Print(...)
  end
end

function UH.SafeCall(fn)
  return pcall(fn)
end

-- Forever money fields are plain numbers on 1.60.1. If a value cannot be
-- read as a number, skip it instead of inventing a price.
function UH.AsNumber(value)
  if type(value) == "number" then
    return value
  end
  if value == nil then
    return nil
  end
  local ok, n = pcall(tonumber, value)
  if ok and type(n) == "number" then
    return n
  end
  return nil
end

function UH.Trim(text)
  if type(text) ~= "string" then
    return ""
  end
  if type(strtrim) == "function" then
    return strtrim(text)
  end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function UH.CopyTable(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = UH.CopyTable(v)
  end
  return out
end

function UH.FormatMoney(copper)
  copper = math.floor((UH.AsNumber(copper) or 0) + 0.5)
  if copper < 0 then
    copper = 0
  end
  if type(GetCoinTextureString) == "function" then
    local ok, text = pcall(GetCoinTextureString, copper)
    if ok and type(text) == "string" and text ~= "" then
      return text
    end
  end
  return UH.FormatMoneyPlain(copper)
end

function UH.FormatMoneyPlain(copper)
  copper = math.floor((UH.AsNumber(copper) or 0) + 0.5)
  if copper < 0 then
    copper = 0
  end
  local gold = math.floor(copper / 10000)
  local silver = math.floor((copper % 10000) / 100)
  local rest = copper % 100
  if gold > 0 then
    if silver > 0 then
      return string.format("%dg %ds", gold, silver)
    end
    return string.format("%dg", gold)
  end
  if silver > 0 then
    if rest > 0 then
      return string.format("%ds %dc", silver, rest)
    end
    return string.format("%ds", silver)
  end
  return string.format("%dc", rest)
end

function UH.QualityHex(quality)
  local colors = ITEM_QUALITY_COLORS
  local entry = colors and colors[quality or 1]
  if entry and type(entry.hex) == "string" then
    return entry.hex
  end
  if entry and type(entry.r) == "number" then
    return string.format("|cff%02x%02x%02x", entry.r * 255, entry.g * 255, entry.b * 255)
  end
  return "|cffffffff"
end

function UH.ItemKey(itemID)
  itemID = UH.AsNumber(itemID)
  if not itemID then
    return nil
  end
  if type(C_AuctionHouse) == "table" and type(C_AuctionHouse.MakeItemKey) == "function" then
    local ok, key = pcall(C_AuctionHouse.MakeItemKey, itemID, 0, 0, 0)
    if ok and type(key) == "table" and key.itemID then
      return key
    end
    ok, key = pcall(C_AuctionHouse.MakeItemKey, itemID)
    if ok and type(key) == "table" and key.itemID then
      return key
    end
  end
  return { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
end

function UH.PriceSorts()
  local order = 0
  if Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price ~= nil then
    order = Enum.AuctionHouseSortOrder.Price
  end
  return {
    { sortOrder = order, reverseSort = false },
  }
end

function UH.HasFn(obj, name)
  return type(obj) == "table" and type(obj[name]) == "function"
end

function UH.DetectAPI()
  -- Forever 1.60.1 reports WOW_PROJECT_MAINLINE. Do not branch on it.
  -- Capability is whatever this client actually exposes.
  local modern = UH.HasFn(C_AuctionHouse, "SendBrowseQuery")
    and UH.HasFn(C_AuctionHouse, "SearchForItemKeys")
    and UH.HasFn(C_AuctionHouse, "SendSearchQuery")
    and UH.HasFn(C_AuctionHouse, "GetItemSearchResultInfo")

  local legacy = type(QueryAuctionItems) == "function"
    and type(GetAuctionItemInfo) == "function"
    and type(CanSendAuctionQuery) == "function"

  UH.modernAH = modern and true or false
  UH.legacyAH = (not modern) and legacy or false
  UH.legacyPresent = legacy and true or false
  UH.supportedAH = UH.modernAH or UH.legacyAH

  UH.Debug(
    "API",
    UH.modernAH and "modern" or (UH.legacyAH and "legacy" or "none"),
    "replicate", tostring(UH.HasFn(C_AuctionHouse, "ReplicateItems"))
  )
end

function UH.DescribeAPI()
  local version, build, date, toc = "?", "?", "?", "?"
  if type(GetBuildInfo) == "function" then
    local ok, a, b, c, d = pcall(GetBuildInfo)
    if ok then
      version, build, date, toc = tostring(a), tostring(b), tostring(c), tostring(d)
    end
  end
  local names = {
    "SendBrowseQuery", "SearchForItemKeys", "SendSearchQuery", "GetBrowseResults",
    "GetItemSearchResultInfo", "GetNumItemSearchResults", "GetCommoditySearchResultInfo",
    "PlaceBid", "StartCommoditiesPurchase", "ConfirmCommoditiesPurchase",
    "CancelCommoditiesPurchase", "IsThrottledMessageSystemReady", "ReplicateItems",
    "GetReplicateItemInfo", "MakeItemKey", "GetItemCommodityStatus",
  }
  local present = {}
  for i = 1, #names do
    if UH.HasFn(C_AuctionHouse, names[i]) then
      present[#present + 1] = names[i]
    end
  end
  UH.Print("Build", version, build, "toc", toc, date)
  UH.Print("Path", UH.modernAH and "modern" or (UH.legacyAH and "legacy" or "unsupported"))
  UH.Print("Frame", AuctionHouseFrame and "AuctionHouseFrame" or (AuctionFrame and "AuctionFrame" or "none"))
  local hasLib = false
  if type(LibStub) == "function" then
    local ok, lib = pcall(LibStub, "LibAHTab-1-0")
    hasLib = ok and type(lib) == "table" and type(lib.CreateTab) == "function"
  end
  UH.Print("LibAHTab", hasLib and "yes" or "no")
  UH.Print("Auctionator", UH.Prices and UH.Prices.IsReady() and "API.v1" or "missing")
  UH.Print("C_AuctionHouse:", table.concat(present, ", "))
  if type(C_AuctionHouse) == "table" and type(C_AuctionHouse.IsThrottledMessageSystemReady) == "function" then
    local ok, ready = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
    UH.Print("Throttle ready:", tostring(ok and ready))
  end
end

function UH.AHOpen()
  if AuctionHouseFrame and AuctionHouseFrame.IsShown and AuctionHouseFrame:IsShown() then
    return true
  end
  if AuctionFrame and AuctionFrame.IsShown and AuctionFrame:IsShown() then
    return true
  end
  return false
end

function UH.SetQueryLock(locked)
  UH.queryLock = locked and true or false
  if UH.UI and UH.UI.UpdateButtons then
    UH.UI.UpdateButtons()
  end
end

function UH.RequestItemData(itemID)
  itemID = UH.AsNumber(itemID)
  if not itemID then
    return
  end
  if UH.HasFn(C_Item, "RequestLoadItemDataByID") then
    pcall(C_Item.RequestLoadItemDataByID, itemID)
  end
end

function UH.GetItemRecord(item)
  if item == nil then
    return nil
  end
  local numeric = UH.AsNumber(item)
  if numeric then
    UH.RequestItemData(numeric)
  end

  -- GetItemInfo: name, link, quality, level, req, class, subclass, stack, equip, texture, sellPrice.
  local ok, name, link, quality, _, _, _, _, _, _, texture, sellPrice
  if UH.HasFn(C_Item, "GetItemInfo") then
    ok, name, link, quality, _, _, _, _, _, _, texture, sellPrice = pcall(C_Item.GetItemInfo, item)
  end
  if (not ok or not name) and type(GetItemInfo) == "function" then
    ok, name, link, quality, _, _, _, _, _, _, texture, sellPrice = pcall(GetItemInfo, item)
  end

  local icon = texture
  if numeric and UH.HasFn(C_Item, "GetItemInfoInstant") then
    local okInstant, _, _, _, _, instantIcon = pcall(C_Item.GetItemInfoInstant, numeric)
    if okInstant and instantIcon and not icon then
      icon = instantIcon
    end
  end

  local resolvedName = name
  if not resolvedName and numeric then
    if UH.HasFn(C_Item, "GetItemNameByID") then
      local okName, itemName = pcall(C_Item.GetItemNameByID, numeric)
      if okName and type(itemName) == "string" then
        resolvedName = itemName
      end
    elseif UH.HasFn(C_Item, "GetItemName") then
      local okName, itemName = pcall(C_Item.GetItemName, numeric)
      if okName and type(itemName) == "string" then
        resolvedName = itemName
      end
    end
  end

  if not resolvedName and not link and not icon and not sellPrice then
    return nil
  end

  return {
    name = resolvedName,
    link = link,
    quality = UH.AsNumber(quality) or 1,
    texture = icon,
    sellPrice = UH.AsNumber(sellPrice),
  }
end

function UH.TimeLeftText(band, seconds)
  seconds = UH.AsNumber(seconds)
  if seconds and seconds > 0 then
    if seconds < 60 then
      return "<1m"
    end
    if seconds < 3600 then
      return string.format("%dm", math.floor(seconds / 60))
    end
    if seconds < 86400 then
      return string.format("%dh", math.floor(seconds / 3600))
    end
    return string.format("%dd", math.floor(seconds / 86400))
  end
  band = UH.AsNumber(band)
  local labels = {
    [0] = UH.L.TIME_SHORT,
    [1] = UH.L.TIME_MEDIUM,
    [2] = UH.L.TIME_LONG,
    [3] = UH.L.TIME_VERY_LONG,
  }
  -- Legacy GetAuctionItemTimeLeft returns 1..4.
  local legacy = {
    [1] = UH.L.TIME_SHORT,
    [2] = UH.L.TIME_MEDIUM,
    [3] = UH.L.TIME_LONG,
    [4] = UH.L.TIME_VERY_LONG,
  }
  return labels[band] or legacy[band] or ""
end

function UH.RowKey(row)
  if not row then
    return ""
  end
  local auctionID = UH.AsNumber(row.auctionID)
  if auctionID then
    return "a:" .. auctionID
  end
  return table.concat({
    "i",
    tostring(row.itemID or 0),
    tostring(row.buyoutAmount or 0),
    tostring(row.quantity or 0),
  }, ":")
end

function UH.After(seconds, fn)
  if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
    C_Timer.After(seconds, fn)
    return true
  end
  return false
end

function UH.ThrottleReady()
  if not UH.HasFn(C_AuctionHouse, "IsThrottledMessageSystemReady") then
    return true
  end
  local ok, ready = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
  if not ok then
    return true
  end
  return ready and true or false
end

local function SlashCommand(msg)
  msg = UH.Trim(msg or "")
  local command, rest = msg:match("^(%S+)%s*(.*)$")
  command = command and command:lower() or ""
  rest = UH.Trim(rest or "")

  if command == "" or command == "help" then
    UH.Print(UH.L.HELP)
    return
  end
  if command == "debug" then
    UH.Config.Apply()
    if rest == "off" or rest == "0" then
      UH.db.debug = false
      UH.Print(UH.L.DEBUG_OFF)
    else
      UH.db.debug = true
      UH.Print(UH.L.DEBUG_ON)
      UH.DetectAPI()
      UH.DescribeAPI()
    end
    return
  end
  if command == "threshold" then
    local value = tonumber(rest)
    if not value then
      UH.Print(UH.L.HELP)
      return
    end
    value = math.floor(value + 0.5)
    if value < 1 then
      value = 1
    end
    if value > 100 then
      value = 100
    end
    UH.Config.Apply()
    UH.db.thresholdPercent = value
    if UH.UI and UH.UI.SyncFromDB then
      UH.UI.SyncFromDB()
    end
    if UH.Results and UH.Results.Reprice then
      UH.Results:Reprice()
    end
    UH.Print(string.format(UH.L.THRESHOLD_SET, value))
    return
  end
  if command == "add" then
    if UH.Watchlist and UH.Watchlist.AddFromText(rest) then
      return
    end
    UH.Print(UH.L.NEED_ITEM)
    return
  end
  if command == "clear" then
    if UH.Results then
      UH.Results:Clear()
    end
    UH.Print(UH.L.CLEARED)
    if UH.UI and UH.UI.SetStatus then
      UH.UI.SetStatus(UH.L.IDLE)
    end
    return
  end
  if command == "stop" then
    if UH.Scanner then
      UH.Scanner:Stop()
    end
    return
  end
  if command == "scan" then
    if not UH.AHOpen() then
      UH.Print(UH.L.AH_CLOSED)
      return
    end
    if UH.Scanner then
      UH.Scanner:Start()
    end
    return
  end
  UH.Print(UH.L.HELP)
end

SLASH_UNDERCUTHUNTER1 = "/uh"
SLASH_UNDERCUTHUNTER2 = "/undercuthunter"
SlashCmdList.UNDERCUTHUNTER = SlashCommand

local function OnAddonLoaded(_, addonName)
  if addonName ~= "UndercutHunter" then
    return
  end
  UH.Config.Apply()
  UH.DetectAPI()
  if UH.Prices and UH.Prices.RegisterUpdates then
    UH.Prices.RegisterUpdates()
  end
  UH.Debug("loaded", UH.VERSION)
end

local function OnHouseShow()
  UH.DetectAPI()
  if UH.UI and UH.UI.TryAttach then
    UH.UI.TryAttach()
  end
end

local function OnHouseClosed()
  if UH.Scanner then
    UH.Scanner:Stop(true)
  end
  if UH.Buyout then
    UH.Buyout:CancelPending(false)
  end
  UH.didAutoScan = false
end

local function OnInteraction(_, interactionType)
  local auctioneer = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Auctioneer
  if auctioneer ~= nil and interactionType ~= auctioneer then
    return
  end
  OnHouseShow()
end

UH.On("ADDON_LOADED", OnAddonLoaded)
UH.On("AUCTION_HOUSE_SHOW", OnHouseShow)
UH.On("AUCTION_HOUSE_CLOSED", OnHouseClosed)
UH.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", OnInteraction)
UH.On("PLAYER_INTERACTION_FRAME_SHOW", OnInteraction)

UH.On("GET_ITEM_INFO_RECEIVED", function(_, itemID)
  if UH.Watchlist then
    UH.Watchlist.ResolveName(itemID)
  end
  if UH.Results then
    UH.Results:FillItem(itemID)
  end
  if UH.UI and UH.UI.Refresh then
    UH.UI.Refresh()
  end
end)
