local UH = UndercutHunter

UH.Results = {
  rows = {},
  selectedKey = nil,
}

function UH.Results:Clear()
  self.rows = {}
  self.selectedKey = nil
  if UH.UI and UH.UI.Refresh then
    UH.UI.Refresh()
  end
end

function UH.Results:Count()
  return #self.rows
end

function UH.Results:Selected()
  if not self.selectedKey then
    return nil
  end
  for i = 1, #self.rows do
    if UH.RowKey(self.rows[i]) == self.selectedKey then
      return self.rows[i]
    end
  end
  return nil
end

function UH.Results:Select(row)
  self.selectedKey = row and UH.RowKey(row) or nil
  if UH.UI and UH.UI.Refresh then
    UH.UI.Refresh()
  end
  if UH.UI and UH.UI.UpdateButtons then
    UH.UI.UpdateButtons()
  end
end

local function PassesQuality(itemID, quality)
  local db = UH.Config.DB()
  if db.includePoor then
    return true
  end
  quality = UH.AsNumber(quality)
  if quality == nil then
    local record = UH.GetItemRecord(itemID)
    quality = record and record.quality
  end
  if quality == nil then
    return true
  end
  return quality > 0
end

local function ApplyIdentity(row, partial, priced)
  -- Item data is requested only for rows that already passed the price test.
  local record = nil
  if not partial.name or partial.name == "" or not partial.icon or not partial.link then
    record = UH.GetItemRecord(partial.itemID)
  end
  row.itemID = partial.itemID
  row.name = partial.name or (record and record.name) or ("Item " .. tostring(partial.itemID))
  row.link = partial.link or (record and record.link)
  row.quality = partial.quality or (record and record.quality) or 1
  row.icon = partial.icon or (record and record.texture)
  row.quantity = priced.quantity
  row.unitListed = priced.unitListed
  row.buyoutAmount = priced.buyoutAmount
  row.unitMarket = priced.unitMarket
  row.percentOfMarket = priced.percentOfMarket
  row.percentOff = priced.percentOff
  row.goldSavedUnit = priced.goldSavedUnit
  row.goldSavedStack = priced.goldSavedStack
  row.timeLeft = partial.timeLeft
  row.timeLeftSeconds = partial.timeLeftSeconds
  row.timeLeftText = UH.TimeLeftText(partial.timeLeft, partial.timeLeftSeconds)
  row.owner = partial.owner
  row.auctionID = UH.AsNumber(partial.auctionID)
  row.itemKey = partial.itemKey or UH.ItemKey(partial.itemID)
  row.isCommodity = partial.isCommodity and true or false
  row.bidOnly = false
  row.listIndex = partial.listIndex
  row.page = partial.page
  row.legacyName = partial.legacyName or row.name
  return row
end

function UH.Results:FindExisting(row)
  local key = UH.RowKey(row)
  for i = 1, #self.rows do
    if UH.RowKey(self.rows[i]) == key then
      return i
    end
  end
  return nil
end

-- partial: itemID, quantity, buyoutAmount or (isCommodity + unitPrice), auctionID, link, name, owner, timeLeft
function UH.Results:Consider(partial)
  if type(partial) ~= "table" then
    return false
  end
  local itemID = UH.AsNumber(partial.itemID)
  if not itemID or UH.Watchlist.IsIgnored(itemID) then
    return false
  end
  if not PassesQuality(itemID, partial.quality) then
    return false
  end

  local quantity = UH.AsNumber(partial.quantity) or 0
  local buyout = UH.AsNumber(partial.buyoutAmount)
  if partial.isCommodity then
    local unitPrice = UH.AsNumber(partial.unitPrice)
    if unitPrice and unitPrice > 0 and quantity > 0 then
      buyout = unitPrice * quantity
    end
  end

  local db = UH.Config.DB()
  if (not buyout or buyout <= 0) then
    if not db.includeBids then
      return false
    end
    local bid = UH.AsNumber(partial.bidAmount)
    if not bid or bid <= 0 or quantity < 1 then
      return false
    end
    local record = UH.GetItemRecord(itemID)
    local row = {
      itemID = itemID,
      name = partial.name or (record and record.name) or ("Item " .. itemID),
      link = partial.link or (record and record.link),
      quality = partial.quality or (record and record.quality) or 1,
      icon = partial.icon or (record and record.texture),
      quantity = quantity,
      unitListed = bid / quantity,
      buyoutAmount = 0,
      unitMarket = 0,
      percentOfMarket = 0,
      percentOff = 0,
      goldSavedUnit = 0,
      goldSavedStack = 0,
      timeLeft = partial.timeLeft,
      timeLeftSeconds = partial.timeLeftSeconds,
      timeLeftText = UH.TimeLeftText(partial.timeLeft, partial.timeLeftSeconds),
      owner = partial.owner,
      auctionID = UH.AsNumber(partial.auctionID),
      itemKey = partial.itemKey or UH.ItemKey(itemID),
      isCommodity = false,
      bidOnly = true,
      listIndex = partial.listIndex,
      page = partial.page,
      legacyName = partial.legacyName,
    }
    local market = UH.Prices.GetMarket(itemID, row.link)
    if market and market > 0 then
      row.unitMarket = market
      row.percentOfMarket = row.unitListed / market * 100
      row.percentOff = (market - row.unitListed) / market * 100
      row.goldSavedUnit = market - row.unitListed
      row.goldSavedStack = row.goldSavedUnit * quantity
    end
    if self:FindExisting(row) then
      return false
    end
    self.rows[#self.rows + 1] = row
    return true
  end

  local priced = UH.Prices.Evaluate(itemID, buyout, quantity, partial.link, partial.marketOverride)
  if not priced then
    return false
  end
  local row = ApplyIdentity({}, partial, priced)
  local existing = self:FindExisting(row)
  if existing then
    self.rows[existing] = row
    return true
  end
  self.rows[#self.rows + 1] = row
  return true
end

function UH.Results:DropItem(itemID)
  itemID = UH.AsNumber(itemID)
  if not itemID then
    return
  end
  for i = #self.rows, 1, -1 do
    if self.rows[i].itemID == itemID then
      table.remove(self.rows, i)
    end
  end
end

function UH.Results:RemoveKey(key)
  for i = #self.rows, 1, -1 do
    if UH.RowKey(self.rows[i]) == key then
      table.remove(self.rows, i)
    end
  end
  if self.selectedKey == key then
    self.selectedKey = nil
  end
end

function UH.Results:FillItem(itemID)
  itemID = UH.AsNumber(itemID)
  if not itemID then
    return
  end
  local record = UH.GetItemRecord(itemID)
  if not record then
    return
  end
  for i = 1, #self.rows do
    local row = self.rows[i]
    if row.itemID == itemID then
      if record.name then
        row.name = record.name
      end
      if record.link then
        row.link = record.link
      end
      if record.quality then
        row.quality = record.quality
      end
      if record.texture then
        row.icon = record.texture
      end
    end
  end
  local db = UH.Config.DB()
  if not db.includePoor then
    for i = #self.rows, 1, -1 do
      local row = self.rows[i]
      if row.itemID == itemID and (row.quality or 1) == 0 then
        table.remove(self.rows, i)
      end
    end
  end
end

function UH.Results:Reprice()
  local kept = {}
  for i = 1, #self.rows do
    local row = self.rows[i]
    if row.bidOnly then
      if UH.Config.DB().includeBids and not UH.Watchlist.IsIgnored(row.itemID) then
        kept[#kept + 1] = row
      end
    else
      local priced = UH.Prices.Evaluate(row.itemID, row.buyoutAmount, row.quantity, row.link)
      if priced and PassesQuality(row.itemID, row.quality) and not UH.Watchlist.IsIgnored(row.itemID) then
        row.unitListed = priced.unitListed
        row.unitMarket = priced.unitMarket
        row.percentOfMarket = priced.percentOfMarket
        row.percentOff = priced.percentOff
        row.goldSavedUnit = priced.goldSavedUnit
        row.goldSavedStack = priced.goldSavedStack
        kept[#kept + 1] = row
      end
    end
  end
  self.rows = kept
end

local function Num(value)
  if type(value) ~= "number" then
    return 0
  end
  return value
end

local function Compare(mode, a, b)
  local aOff, bOff = Num(a.percentOff), Num(b.percentOff)
  local aGold, bGold = Num(a.goldSavedStack), Num(b.goldSavedStack)
  if mode == "goldSaved" then
    if aGold ~= bGold then
      return aGold > bGold
    end
    if aOff ~= bOff then
      return aOff > bOff
    end
  elseif mode == "percent" then
    if aOff ~= bOff then
      return aOff > bOff
    end
  else
    if aOff ~= bOff then
      return aOff > bOff
    end
    if aGold ~= bGold then
      return aGold > bGold
    end
  end
  local an = a.name or ""
  local bn = b.name or ""
  if an ~= bn then
    return an < bn
  end
  return (a.itemID or 0) < (b.itemID or 0)
end

function UH.Results:GetView()
  local db = UH.Config.DB()
  local filter = UH.Trim(db.nameFilter or ""):lower()
  local view = {}
  for i = 1, #self.rows do
    local row = self.rows[i]
    local include = true
    if filter ~= "" then
      local name = (row.name or ""):lower()
      if not name:find(filter, 1, true) then
        include = false
      end
    end
    if include then
      view[#view + 1] = row
    end
  end
  table.sort(view, function(a, b)
    return Compare(db.sortMode, a, b)
  end)
  local cap = db.maxResults or 200
  if #view > cap then
    local trimmed = {}
    for i = 1, cap do
      trimmed[i] = view[i]
    end
    view = trimmed
  end
  return view
end

local function UnitCopper(row)
  local unit = UH.AsNumber(row.unitListed)
  if unit and unit > 0 then
    return unit
  end
  local buy = UH.AsNumber(row.buyoutAmount)
  local qty = UH.AsNumber(row.quantity)
  if buy and qty and qty > 0 then
    return buy / qty
  end
  return nil
end

function UH.Results.SameListing(a, b)
  if not a or not b then
    return false
  end
  if a.itemID ~= b.itemID then
    return false
  end
  if a.bidOnly or b.bidOnly then
    return false
  end
  -- Commodity piles change size. Match the unit price and require enough left
  -- to cover the quantity the player already confirmed.
  if a.isCommodity or b.isCommodity then
    local aUnit = UnitCopper(a)
    local bUnit = UnitCopper(b)
    if not aUnit or not bUnit then
      return false
    end
    if math.floor(aUnit + 0.5) ~= math.floor(bUnit + 0.5) then
      return false
    end
    return (b.quantity or 0) >= (a.quantity or 1)
  end
  local aID = UH.AsNumber(a.auctionID)
  local bID = UH.AsNumber(b.auctionID)
  if aID and bID and aID ~= bID then
    return false
  end
  local aBuy = UH.AsNumber(a.buyoutAmount)
  local bBuy = UH.AsNumber(b.buyoutAmount)
  if not aBuy or not bBuy or math.floor(aBuy + 0.5) ~= math.floor(bBuy + 0.5) then
    return false
  end
  if (a.quantity or 0) ~= (b.quantity or 0) then
    return false
  end
  return true
end

function UH.Results.OwnerName(owners, fallback)
  if type(fallback) == "string" and fallback ~= "" then
    return fallback
  end
  if type(owners) == "table" then
    local first = owners[1]
    if type(first) == "string" and first ~= "" then
      return first
    end
  end
  return nil
end
