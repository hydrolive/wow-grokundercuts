local UH = UndercutHunter

-- One explicit click starts a fresh listing check. A second explicit click
-- (the confirm popup, or Buyout again when confirm is off) is the only place
-- that calls PlaceBid / StartCommoditiesPurchase.
-- Forever 1.60.1 / modern AH: those purchase calls require a hardware event,
-- so they cannot run from the search-result event or a timer. The fresh
-- search finishes first. The confirm click re-reads that result and buys
-- only if auctionID, quantity, and buyout still match. No queued or timed buy.

UH.Buyout = {
  generation = 0,
  requested = nil,
  fresh = nil,
  armed = nil,
  commodity = nil,
  waitingThrottle = false,
  legacyPage = 0,
  legacyPagesTried = 0,
}

local function PopupVisible(which)
  if type(StaticPopup_Visible) ~= "function" then
    return false
  end
  local ok, visible = pcall(StaticPopup_Visible, which)
  return ok and visible and true or false
end

local function FillPrice(row, buyout, quantity, link)
  local priced = UH.Prices.Evaluate(row.itemID, buyout, quantity, link or row.link)
  if priced then
    row.unitListed = priced.unitListed
    row.unitMarket = priced.unitMarket
    row.percentOfMarket = priced.percentOfMarket
    row.percentOff = priced.percentOff
    row.goldSavedUnit = priced.goldSavedUnit
    row.goldSavedStack = priced.goldSavedStack
    row.buyoutAmount = priced.buyoutAmount
    row.quantity = priced.quantity
  else
    row.buyoutAmount = buyout
    row.quantity = quantity
    row.unitListed = quantity > 0 and buyout / quantity or 0
  end
  return row
end

function UH.Buyout:CancelPending(announce)
  self.generation = self.generation + 1
  self.requested = nil
  self.fresh = nil
  self.armed = nil
  self.waitingThrottle = false
  if self.commodity then
    self:CancelCommodity(self.commodity)
    self.commodity = nil
  end
  if UH.queryLock then
    UH.SetQueryLock(false)
  end
  if type(StaticPopup_Hide) == "function" then
    pcall(StaticPopup_Hide, "UNDERCUTHUNTER_BUYOUT")
  end
  if UH.UI and UH.UI.SetBuyoutLabel then
    UH.UI.SetBuyoutLabel(UH.L.BUYOUT)
  end
  if announce then
    UH.Print(UH.L.LISTING_CHANGED)
  end
end

function UH.Buyout:Abort(message)
  self:CancelPending(false)
  message = message or UH.L.LISTING_CHANGED
  if UH.UI and UH.UI.SetStatus then
    UH.UI.SetStatus(message)
  end
  UH.Print(message)
end

function UH.Buyout:Request(row)
  if not row then
    UH.Print(UH.L.NO_SELECTION)
    return
  end
  if PopupVisible("UNDERCUTHUNTER_BUYOUT") then
    return
  end
  if row.bidOnly or not row.buyoutAmount or row.buyoutAmount <= 0 then
    UH.Print(UH.L.BID_ONLY)
    return
  end
  if UH.Scanner and UH.Scanner.running then
    UH.Print(UH.L.QUERY_BUSY)
    return
  end

  if self.armed and not UH.Config.DB().confirmBuyout and UH.RowKey(self.armed) == UH.RowKey(row) then
    self:Commit(self.armed)
    return
  end

  if UH.queryLock then
    UH.Print(UH.L.QUERY_BUSY)
    return
  end
  if not UH.AHOpen() then
    UH.Print(UH.L.AH_CLOSED)
    return
  end
  UH.DetectAPI()
  if not UH.supportedAH then
    UH.Print(UH.L.NO_API)
    return
  end

  self.generation = self.generation + 1
  local gen = self.generation
  self.requested = {
    itemID = row.itemID,
    name = row.name,
    link = row.link,
    quality = row.quality,
    icon = row.icon,
    quantity = row.quantity,
    buyoutAmount = row.buyoutAmount,
    unitListed = row.unitListed,
    unitMarket = row.unitMarket,
    percentOfMarket = row.percentOfMarket,
    percentOff = row.percentOff,
    goldSavedUnit = row.goldSavedUnit,
    goldSavedStack = row.goldSavedStack,
    auctionID = row.auctionID,
    itemKey = row.itemKey or UH.ItemKey(row.itemID),
    isCommodity = row.isCommodity and true or false,
    legacyName = row.legacyName or row.name,
    listIndex = row.listIndex,
    page = row.page,
  }
  self.fresh = nil
  self.armed = nil
  self.commodity = nil
  self.legacyPage = 0
  self.legacyPagesTried = 0

  if UH.modernAH then
    self:RefreshModern(gen)
  else
    self:RefreshLegacy(gen)
  end
end

function UH.Buyout:RefreshModern(gen)
  local function send()
    if gen ~= UH.Buyout.generation then
      return
    end
    UH.Buyout.waitingThrottle = false
    UH.SetQueryLock(true)
    if UH.UI and UH.UI.SetStatus then
      UH.UI.SetStatus(UH.L.CHECKING)
    end
    local key = UH.Buyout.requested.itemKey or UH.ItemKey(UH.Buyout.requested.itemID)
    UH.Buyout.requested.itemKey = key
    local ok, err = pcall(C_AuctionHouse.SendSearchQuery, key, UH.PriceSorts(), false)
    if not ok then
      UH.Debug("buyout search failed", err)
      UH.Buyout:Abort(UH.L.LISTING_CHANGED)
      return
    end
    UH.After(UH.QUERY_TIMEOUT, function()
      if gen ~= UH.Buyout.generation or UH.Buyout.fresh or UH.Buyout.armed then
        return
      end
      if UH.queryLock then
        UH.Buyout:Abort(UH.L.LISTING_CHANGED)
      end
    end)
  end

  if UH.ThrottleReady() then
    send()
    return
  end
  self.waitingThrottle = true
  self.throttleGen = gen
  if UH.UI and UH.UI.SetStatus then
    UH.UI.SetStatus(UH.L.CHECKING)
  end
  UH.After(UH.QUERY_TIMEOUT, function()
    if UH.Buyout.waitingThrottle and UH.Buyout.throttleGen == gen then
      UH.Buyout.waitingThrottle = false
      UH.Buyout:Abort(UH.L.LISTING_CHANGED)
    end
  end)
end

function UH.Buyout:OnThrottleReady()
  if not self.waitingThrottle then
    return false
  end
  self.waitingThrottle = false
  self:RefreshModern(self.throttleGen)
  return true
end

function UH.Buyout:MatchItem(itemKey)
  if not UH.HasFn(C_AuctionHouse, "GetNumItemSearchResults") or not itemKey then
    return nil
  end
  local ok, count = pcall(C_AuctionHouse.GetNumItemSearchResults, itemKey)
  count = ok and UH.AsNumber(count) or 0
  local requested = self.requested
  if not requested then
    return nil
  end
  for i = 1, (count or 0) do
    local okInfo, info = pcall(C_AuctionHouse.GetItemSearchResultInfo, itemKey, i)
    if okInfo and type(info) == "table" and not info.containsOwnerItem then
      local qty = UH.AsNumber(info.quantity) or 1
      local buyout = UH.AsNumber(info.buyoutAmount) or 0
      if buyout > 0 and qty > 0 then
        local row = {
          itemID = requested.itemID,
          name = requested.name,
          link = info.itemLink or requested.link,
          quality = requested.quality,
          icon = requested.icon,
          auctionID = UH.AsNumber(info.auctionID),
          itemKey = itemKey,
          isCommodity = false,
          owner = UH.Results.OwnerName(info.owners),
          timeLeft = info.timeLeft,
          timeLeftSeconds = info.timeLeftSeconds,
          unitMarket = requested.unitMarket,
          percentOff = requested.percentOff,
          percentOfMarket = requested.percentOfMarket,
          goldSavedUnit = requested.goldSavedUnit,
          goldSavedStack = requested.goldSavedStack,
        }
        FillPrice(row, buyout, qty, row.link)
        if UH.Results.SameListing(requested, row) then
          return row
        end
      end
    end
  end
  return nil
end

function UH.Buyout:MatchCommodity(itemID)
  if not UH.HasFn(C_AuctionHouse, "GetNumCommoditySearchResults") then
    return nil
  end
  local ok, count = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)
  count = ok and UH.AsNumber(count) or 0
  local requested = self.requested
  if not requested then
    return nil
  end
  for i = 1, (count or 0) do
    local okInfo, info = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, i)
    if okInfo and type(info) == "table" and not info.containsOwnerItem then
      local unit = UH.AsNumber(info.unitPrice) or 0
      local qty = UH.AsNumber(info.quantity) or 0
      if unit > 0 and qty > 0 then
        local row = {
          itemID = itemID,
          name = requested.name,
          link = requested.link,
          quality = requested.quality,
          icon = requested.icon,
          auctionID = UH.AsNumber(info.auctionID),
          itemKey = requested.itemKey,
          isCommodity = true,
          owner = UH.Results.OwnerName(info.owners),
          timeLeftSeconds = info.timeLeftSeconds,
          unitMarket = requested.unitMarket,
          percentOff = requested.percentOff,
          percentOfMarket = requested.percentOfMarket,
          goldSavedUnit = requested.goldSavedUnit,
          goldSavedStack = requested.goldSavedStack,
        }
        FillPrice(row, unit * qty, qty, row.link)
        if UH.Results.SameListing(requested, row) then
          return row
        end
      end
    end
  end
  return nil
end

function UH.Buyout:OnItemResults(itemKey)
  if not self.requested or not UH.queryLock or self.fresh or self.armed then
    return false
  end
  local itemID = type(itemKey) == "table" and UH.AsNumber(itemKey.itemID) or nil
  if itemID ~= self.requested.itemID then
    return false
  end
  local match = self:MatchItem(itemKey)
  if not match then
    -- An empty item search still leaves room for a commodity result event.
    local count = 0
    if itemKey and UH.HasFn(C_AuctionHouse, "GetNumItemSearchResults") then
      local ok, n = pcall(C_AuctionHouse.GetNumItemSearchResults, itemKey)
      count = ok and UH.AsNumber(n) or 0
    end
    if count < 1 then
      return false
    end
    self:Abort(UH.L.LISTING_CHANGED)
    return true
  end
  self.requested.isCommodity = false
  self.requested.itemKey = itemKey or self.requested.itemKey
  self:ResolveMatch(match)
  return true
end

function UH.Buyout:OnCommodityResults(itemID)
  if not self.requested or not UH.queryLock or self.fresh or self.armed then
    return false
  end
  itemID = UH.AsNumber(itemID)
  if itemID ~= self.requested.itemID then
    return false
  end
  self.requested.isCommodity = true
  self:ResolveMatch(self:MatchCommodity(itemID))
  return true
end

function UH.Buyout:ResolveMatch(row)
  if not row or not UH.Results.SameListing(self.requested, row) then
    self:Abort(UH.L.LISTING_CHANGED)
    return
  end
  self.fresh = row
  UH.SetQueryLock(false)
  if UH.Config.DB().confirmBuyout then
    self:ShowPopup(row)
    return
  end
  self.armed = row
  if UH.UI and UH.UI.SetBuyoutLabel then
    UH.UI.SetBuyoutLabel(UH.L.CONFIRM_BUYOUT)
  end
  if UH.UI and UH.UI.SetStatus then
    UH.UI.SetStatus(UH.L.CONFIRM_AGAIN)
  end
  if UH.UI and UH.UI.UpdateButtons then
    UH.UI.UpdateButtons()
  end
  local gen = self.generation
  UH.After(20, function()
    if UH.Buyout.generation == gen and UH.Buyout.armed then
      UH.Buyout.armed = nil
      UH.Buyout.fresh = nil
      if UH.UI and UH.UI.SetBuyoutLabel then
        UH.UI.SetBuyoutLabel(UH.L.BUYOUT)
      end
      if UH.UI and UH.UI.SetStatus then
        UH.UI.SetStatus(UH.L.ARMED_EXPIRED)
      end
      if UH.UI and UH.UI.UpdateButtons then
        UH.UI.UpdateButtons()
      end
    end
  end)
end

function UH.Buyout:ShowPopup(row)
  local lines = {
    UH.L.BUY_HEADER,
    UH.L.BUY_LINE_ITEM .. ": " .. (row.link or row.name or "?"),
    UH.L.BUY_LINE_EACH .. ": " .. UH.FormatMoney(row.unitListed),
    UH.L.BUY_LINE_TOTAL .. ": " .. UH.FormatMoney(row.buyoutAmount),
    UH.L.BUY_LINE_MARKET .. ": " .. UH.FormatMoney(row.unitMarket),
    UH.L.BUY_LINE_OFF .. ": " .. string.format("%.0f percent", row.percentOff or 0),
    UH.L.BUY_LINE_SAVED .. ": " .. UH.FormatMoney(row.goldSavedUnit) .. " (" .. UH.FormatMoney(row.goldSavedStack) .. ")",
  }
  StaticPopupDialogs.UNDERCUTHUNTER_BUYOUT.text = table.concat(lines, "\n")
  local dialog = StaticPopup_Show("UNDERCUTHUNTER_BUYOUT")
  if dialog then
    dialog.data = row
  end
end

function UH.Buyout:Commit(data)
  if not data or not UH.AHOpen() then
    self:Abort(UH.L.LISTING_CHANGED)
    return
  end
  local live = nil
  if data.isCommodity then
    live = self:MatchCommodity(data.itemID)
  elseif UH.modernAH then
    live = self:MatchItem(data.itemKey or UH.ItemKey(data.itemID))
  else
    live = self:MatchLegacy()
  end
  if not live or not UH.Results.SameListing(data, live) then
    self:Abort(UH.L.LISTING_CHANGED)
    return
  end
  self.fresh = nil
  self.armed = nil
  if UH.UI and UH.UI.SetBuyoutLabel then
    UH.UI.SetBuyoutLabel(UH.L.BUYOUT)
  end

  if live.isCommodity then
    if not UH.HasFn(C_AuctionHouse, "StartCommoditiesPurchase") then
      UH.Print(UH.L.API_INCOMPLETE)
      return
    end
    -- Buy the quantity the player confirmed, not a larger commodity bucket.
    local qty = data.quantity or live.quantity
    if (live.quantity or 0) < qty then
      self:Abort(UH.L.LISTING_CHANGED)
      return
    end
    local ok, err = pcall(C_AuctionHouse.StartCommoditiesPurchase, live.itemID, qty)
    if not ok then
      UH.Debug("StartCommoditiesPurchase", err)
      UH.Print(UH.L.PURCHASE_FAILED)
      return
    end
    local gen = self.generation
    self.commodity = {
      itemID = live.itemID,
      quantity = qty,
      unit = math.floor((live.unitListed or 0) + 0.5),
      total = math.floor((live.unitListed or 0) + 0.5) * qty,
      gen = gen,
      name = live.name,
      key = UH.RowKey(live),
    }
    UH.SetQueryLock(true)
    UH.After(UH.QUERY_TIMEOUT, function()
      if UH.Buyout.commodity and UH.Buyout.commodity.gen == gen then
        local pending = UH.Buyout.commodity
        UH.Buyout.commodity = nil
        UH.Buyout:CancelCommodity(pending)
        UH.Buyout:Abort(UH.L.LISTING_CHANGED)
      end
    end)
    return
  end

  if UH.modernAH then
    if not UH.HasFn(C_AuctionHouse, "PlaceBid") then
      UH.Print(UH.L.API_INCOMPLETE)
      return
    end
    local auctionID = UH.AsNumber(live.auctionID)
    local amount = math.floor((live.buyoutAmount or 0) + 0.5)
    if not auctionID or amount <= 0 then
      self:Abort(UH.L.LISTING_CHANGED)
      return
    end
    local ok, err = pcall(C_AuctionHouse.PlaceBid, auctionID, amount)
    if not ok then
      UH.Debug("PlaceBid", err)
      UH.Print(UH.L.PURCHASE_FAILED)
      return
    end
    UH.Print(string.format(UH.L.PURCHASE_SENT, live.name or "?", live.quantity or 1))
    UH.Results:RemoveKey(UH.RowKey(data))
    UH.Results:RemoveKey(UH.RowKey(live))
    if UH.UI and UH.UI.Refresh then
      UH.UI.Refresh()
    end
    return
  end

  if type(PlaceAuctionBid) ~= "function" or not live.listIndex then
    self:Abort(UH.L.LISTING_CHANGED)
    return
  end
  local ok, err = pcall(PlaceAuctionBid, "list", live.listIndex, math.floor(live.buyoutAmount + 0.5))
  if not ok then
    UH.Debug("PlaceAuctionBid", err)
    UH.Print(UH.L.PURCHASE_FAILED)
    return
  end
  UH.Print(string.format(UH.L.PURCHASE_SENT, live.name or "?", live.quantity or 1))
  UH.Results:RemoveKey(UH.RowKey(data))
  if UH.UI and UH.UI.Refresh then
    UH.UI.Refresh()
  end
end

function UH.Buyout:CancelCommodity(pending)
  if not pending or not UH.HasFn(C_AuctionHouse, "CancelCommoditiesPurchase") then
    return
  end
  local ok = pcall(C_AuctionHouse.CancelCommoditiesPurchase, pending.itemID, pending.quantity)
  if not ok then
    pcall(C_AuctionHouse.CancelCommoditiesPurchase)
  end
end

function UH.Buyout:OnCommodityPrice(unitPrice, totalPrice)
  local pending = self.commodity
  if not pending then
    return false
  end
  unitPrice = UH.AsNumber(unitPrice)
  totalPrice = UH.AsNumber(totalPrice)
  self.commodity = nil
  UH.SetQueryLock(false)
  if not unitPrice or unitPrice ~= pending.unit or (totalPrice and pending.total and totalPrice ~= pending.total) then
    self:CancelCommodity(pending)
    self:Abort(UH.L.LISTING_CHANGED)
    return true
  end
  if not UH.HasFn(C_AuctionHouse, "ConfirmCommoditiesPurchase") then
    self:CancelCommodity(pending)
    UH.Print(UH.L.API_INCOMPLETE)
    return true
  end
  local ok, err = pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, pending.itemID, pending.quantity)
  if not ok then
    UH.Debug("ConfirmCommoditiesPurchase", err)
    self:CancelCommodity(pending)
    UH.Print(UH.L.PURCHASE_FAILED)
    return true
  end
  UH.Print(string.format(UH.L.PURCHASE_SENT, pending.name or "?", pending.quantity or 1))
  if pending.key then
    UH.Results:RemoveKey(pending.key)
  end
  if UH.UI and UH.UI.Refresh then
    UH.UI.Refresh()
  end
  return true
end

function UH.Buyout:RefreshLegacy(gen)
  local function send(page)
    if gen ~= UH.Buyout.generation then
      return
    end
    local ready = true
    if type(CanSendAuctionQuery) == "function" then
      local ok, allowed = pcall(CanSendAuctionQuery)
      if ok and not allowed then
        ready = false
      end
    end
    if not ready then
      UH.After(0.3, function()
        send(page)
      end)
      return
    end
    UH.SetQueryLock(true)
    if UH.UI and UH.UI.SetStatus then
      UH.UI.SetStatus(UH.L.CHECKING)
    end
    UH.Buyout.legacyPage = page or 0
    local name = UH.Buyout.requested.legacyName or UH.Buyout.requested.name or ""
    local ok = pcall(QueryAuctionItems, name, nil, nil, UH.Buyout.legacyPage, false, nil, false, true)
    if not ok then
      pcall(QueryAuctionItems, name, 0, 0, UH.Buyout.legacyPage, 0, 0, false, false)
    end
  end
  send(0)
  UH.After(UH.QUERY_TIMEOUT, function()
    if gen == UH.Buyout.generation and not UH.Buyout.fresh and not UH.Buyout.armed and UH.queryLock then
      UH.Buyout:Abort(UH.L.LISTING_CHANGED)
    end
  end)
end

function UH.Buyout:MatchLegacy()
  if type(GetNumAuctionItems) ~= "function" or type(GetAuctionItemInfo) ~= "function" then
    return nil
  end
  local okNum, batch = pcall(GetNumAuctionItems, "list")
  batch = okNum and UH.AsNumber(batch) or 0
  local requested = self.requested
  if not requested then
    return nil
  end
  local me = type(UnitName) == "function" and UnitName("player") or nil
  for index = 1, (batch or 0) do
    local ok, values = pcall(function()
      return { GetAuctionItemInfo("list", index) }
    end)
    if ok and type(values) == "table" then
      local count = UH.AsNumber(values[3]) or 0
      local buyout = UH.AsNumber(values[10]) or 0
      local owner = values[14]
      local itemID = UH.AsNumber(values[17]) or requested.itemID
      if itemID == requested.itemID and buyout > 0 and (not owner or not me or owner ~= me) then
        local link = requested.link
        if type(GetAuctionItemLink) == "function" then
          local okLink, itemLink = pcall(GetAuctionItemLink, "list", index)
          if okLink and type(itemLink) == "string" then
            link = itemLink
          end
        end
        local row = {
          itemID = itemID,
          name = requested.name,
          link = link,
          quality = requested.quality,
          icon = requested.icon,
          listIndex = index,
          page = self.legacyPage,
          legacyName = requested.legacyName,
          isCommodity = false,
          unitMarket = requested.unitMarket,
          percentOff = requested.percentOff,
          percentOfMarket = requested.percentOfMarket,
          goldSavedUnit = requested.goldSavedUnit,
          goldSavedStack = requested.goldSavedStack,
        }
        FillPrice(row, buyout, count, link)
        if UH.Results.SameListing(requested, row) then
          return row
        end
      end
    end
  end
  return nil
end

function UH.Buyout:OnLegacyList()
  if UH.modernAH or not self.requested or not UH.queryLock or self.fresh or self.armed then
    return false
  end
  local match = self:MatchLegacy()
  if match then
    self:ResolveMatch(match)
    return true
  end
  local batch, total = 0, 0
  if type(GetNumAuctionItems) == "function" then
    local ok, a, b = pcall(GetNumAuctionItems, "list")
    if ok then
      batch = UH.AsNumber(a) or 0
      total = UH.AsNumber(b) or batch
    end
  end
  local perPage = NUM_AUCTION_ITEMS_PER_PAGE or 50
  self.legacyPagesTried = (self.legacyPagesTried or 0) + 1
  if batch >= perPage and ((self.legacyPage + 1) * perPage) < total and self.legacyPagesTried < 8 then
    local name = self.requested.legacyName or self.requested.name or ""
    self.legacyPage = self.legacyPage + 1
    local function query()
      if not UH.Buyout.requested or UH.Buyout.fresh then
        return
      end
      if type(CanSendAuctionQuery) == "function" then
        local ok, allowed = pcall(CanSendAuctionQuery)
        if ok and not allowed then
          UH.After(0.3, query)
          return
        end
      end
      pcall(QueryAuctionItems, name, nil, nil, UH.Buyout.legacyPage, false, nil, false, true)
    end
    query()
    return true
  end
  self:Abort(UH.L.LISTING_CHANGED)
  return true
end

function UH.Buyout:OnPurchased()
  UH.SetQueryLock(false)
  self.commodity = nil
  if self.requested then
    UH.Results:RemoveKey(UH.RowKey(self.requested))
    self.requested = nil
    if UH.UI and UH.UI.Refresh then
      UH.UI.Refresh()
    end
  end
end

StaticPopupDialogs = StaticPopupDialogs or {}
StaticPopupDialogs.UNDERCUTHUNTER_BUYOUT = {
  text = "Buy this listing?",
  button1 = "Buyout",
  button2 = "Cancel",
  OnAccept = function(self)
    UH.Buyout:Commit(self.data)
  end,
  OnCancel = function()
    UH.Buyout.fresh = nil
    UH.Buyout.armed = nil
    if UH.UI and UH.UI.SetBuyoutLabel then
      UH.UI.SetBuyoutLabel(UH.L.BUYOUT)
    end
    if UH.UI and UH.UI.SetStatus then
      UH.UI.SetStatus(string.format(UH.L.FOUND_DEALS, UH.Results:Count()))
    end
  end,
  timeout = 0,
  whileDead = 1,
  hideOnEscape = 1,
  preferredIndex = 3,
}

StaticPopupDialogs.UNDERCUTHUNTER_DEEP = {
  text = UH.L.DEEP_WARN,
  button1 = UH.L.DEEP,
  button2 = UH.L.CANCEL,
  OnAccept = function()
    UH.Scanner:StartDeepConfirmed()
  end,
  timeout = 0,
  whileDead = 1,
  hideOnEscape = 1,
  preferredIndex = 3,
  showAlert = 1,
}

UH.On("COMMODITY_PRICE_UPDATED", function(_, unitPrice, totalPrice)
  UH.Buyout:OnCommodityPrice(unitPrice, totalPrice)
end)
UH.On("COMMODITY_PRICE_UNAVAILABLE", function()
  if UH.Buyout.commodity then
    local pending = UH.Buyout.commodity
    UH.Buyout.commodity = nil
    UH.Buyout:CancelCommodity(pending)
    UH.Buyout:Abort(UH.L.LISTING_CHANGED)
  end
end)
UH.On("COMMODITY_PURCHASE_FAILED", function()
  if UH.Buyout.commodity or UH.Buyout.requested then
    UH.Buyout.commodity = nil
    UH.SetQueryLock(false)
    UH.Print(UH.L.PURCHASE_FAILED)
  end
end)
UH.On("COMMODITY_PURCHASE_SUCCEEDED", function()
  UH.Buyout:OnPurchased()
end)
UH.On("ITEM_PURCHASED", function()
  UH.Buyout:OnPurchased()
end)
