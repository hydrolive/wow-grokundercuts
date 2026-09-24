local UH = UndercutHunter

UH.Prices = {}

local function API()
  if type(Auctionator) ~= "table" then
    return nil
  end
  if type(Auctionator.API) ~= "table" or type(Auctionator.API.v1) ~= "table" then
    return nil
  end
  return Auctionator.API.v1
end

function UH.Prices.IsReady()
  local api = API()
  return api ~= nil and type(api.GetAuctionPriceByItemID) == "function"
end

function UH.Prices.GetAuctionatorByID(itemID)
  itemID = UH.AsNumber(itemID)
  if not itemID or not UH.Prices.IsReady() then
    return nil
  end
  local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, UH.CALLER_ID, itemID)
  if not ok then
    UH.Debug("GetAuctionPriceByItemID failed", price)
    return nil
  end
  price = UH.AsNumber(price)
  if price and price > 0 then
    return price
  end
  return nil
end

function UH.Prices.GetAuctionatorByLink(itemLink)
  if type(itemLink) ~= "string" or not UH.Prices.IsReady() then
    return nil
  end
  if type(Auctionator.API.v1.GetAuctionPriceByItemLink) ~= "function" then
    return nil
  end
  local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemLink, UH.CALLER_ID, itemLink)
  if not ok then
    UH.Debug("GetAuctionPriceByItemLink failed", price)
    return nil
  end
  price = UH.AsNumber(price)
  if price and price > 0 then
    return price
  end
  return nil
end

function UH.Prices.VendorSell(itemID)
  local record = UH.GetItemRecord(itemID)
  if record and record.sellPrice and record.sellPrice > 0 then
    return record.sellPrice
  end
  return nil
end

-- Unit market in copper. Auctionator's last scan for this AH, never a private DB.
-- Vendor sell price is used only when the player turned that fallback on.
function UH.Prices.GetMarket(itemID, itemLink)
  local price = UH.Prices.GetAuctionatorByID(itemID)
  if not price and itemLink then
    price = UH.Prices.GetAuctionatorByLink(itemLink)
  end
  if price then
    return price, "auctionator"
  end
  local db = UH.Config.DB()
  if db.useVendorFallback then
    local vendor = UH.Prices.VendorSell(itemID)
    if vendor then
      return vendor, "vendor"
    end
  end
  return nil, nil
end

-- unitListed / unitMarket * 100 <= threshold keeps the listing.
-- Returns nil when the listing is not a bargain under the current settings.
function UH.Prices.Evaluate(itemID, buyoutCopper, quantity, itemLink, marketOverride)
  local db = UH.Config.DB()
  quantity = UH.AsNumber(quantity)
  buyoutCopper = UH.AsNumber(buyoutCopper)
  if not quantity or quantity < 1 then
    return nil
  end
  if not buyoutCopper or buyoutCopper <= 0 then
    return nil
  end
  if quantity < (db.minQuantity or 1) then
    return nil
  end

  local market = UH.AsNumber(marketOverride)
  if not market or market <= 0 then
    market = UH.Prices.GetMarket(itemID, itemLink)
  end
  if not market or market <= 0 then
    return nil
  end
  if market < (db.minMarketCopper or 0) then
    return nil
  end

  local unitListed = buyoutCopper / quantity
  if unitListed <= 0 then
    return nil
  end
  local percentOfMarket = unitListed / market * 100
  if percentOfMarket > db.thresholdPercent then
    return nil
  end
  local goldSavedUnit = market - unitListed
  local minGold = db.minDiscountGold or 0
  if minGold > 0 and goldSavedUnit < (minGold * 10000) then
    return nil
  end

  return {
    unitListed = unitListed,
    unitMarket = market,
    percentOfMarket = percentOfMarket,
    percentOff = (market - unitListed) / market * 100,
    goldSavedUnit = goldSavedUnit,
    goldSavedStack = goldSavedUnit * quantity,
    buyoutAmount = buyoutCopper,
    quantity = quantity,
  }
end

function UH.Prices.MultiSearch(name)
  if type(name) ~= "string" or name == "" or not UH.Prices.IsReady() then
    return false
  end
  if type(Auctionator.API.v1.MultiSearch) ~= "function" then
    UH.Print(UH.L.AUCTIONATOR_MISSING)
    return false
  end
  local ok, err = pcall(Auctionator.API.v1.MultiSearch, UH.CALLER_ID, { name })
  if not ok then
    UH.Debug("MultiSearch failed", err)
    return false
  end
  return true
end

function UH.Prices.RegisterUpdates()
  if not UH.Prices.IsReady() then
    return
  end
  if type(Auctionator.API.v1.RegisterForDBUpdate) ~= "function" then
    return
  end
  if UH.pricesRegistered then
    return
  end
  local ok, err = pcall(Auctionator.API.v1.RegisterForDBUpdate, UH.CALLER_ID, function()
    UH.Debug("Auctionator DB update")
    if UH.Results and UH.Results.Reprice then
      UH.Results:Reprice()
    end
    if UH.UI and UH.UI.Refresh then
      UH.UI.Refresh()
    end
  end)
  if ok then
    UH.pricesRegistered = true
  else
    UH.Debug("RegisterForDBUpdate failed", err)
  end
end
