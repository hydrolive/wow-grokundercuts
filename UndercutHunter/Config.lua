local UH = UndercutHunter

UH.Config = {}

-- SavedVariables defaults. Copper is the only internal money unit.
UH.DEFAULTS = {
  thresholdPercent = 50,
  minDiscountGold = 0,
  minMarketCopper = 100,
  minQuantity = 1,
  includePoor = true,
  includeBids = false,
  useVendorFallback = false,
  sortMode = "percentThenGold",
  maxResults = 200,
  scanSource = "watchlist",
  limitToWatchlist = false,
  autoScanOnTabOpen = false,
  confirmBuyout = true,
  doubleClickBuyout = true,
  showOwner = false,
  debug = false,
  candidateCap = 500,
  nameFilter = "",
  watchlist = {},
  ignore = {},
  extraItemIDs = {},
}

local SORT_MODES = {
  percent = true,
  goldSaved = true,
  percentThenGold = true,
}

function UH.Config.Apply()
  if type(UndercutHunterDB) ~= "table" then
    UndercutHunterDB = {}
  end
  local db = UndercutHunterDB
  for key, value in pairs(UH.DEFAULTS) do
    if db[key] == nil then
      db[key] = UH.CopyTable(value)
    end
  end
  if type(db.watchlist) ~= "table" then
    db.watchlist = {}
  end
  if type(db.ignore) ~= "table" then
    db.ignore = {}
  end
  if type(db.extraItemIDs) ~= "table" then
    db.extraItemIDs = {}
  end
  if not SORT_MODES[db.sortMode] then
    db.sortMode = "percentThenGold"
  end
  if db.scanSource ~= "watchlist" and db.scanSource ~= "pricedCandidates" then
    db.scanSource = "watchlist"
  end
  if db.limitToWatchlist == nil then
    db.limitToWatchlist = false
  end

  db.thresholdPercent = UH.AsNumber(db.thresholdPercent) or 50
  if db.thresholdPercent < 1 then
    db.thresholdPercent = 1
  end
  if db.thresholdPercent > 100 then
    db.thresholdPercent = 100
  end
  db.minDiscountGold = UH.AsNumber(db.minDiscountGold) or 0
  if db.minDiscountGold < 0 then
    db.minDiscountGold = 0
  end
  db.minMarketCopper = UH.AsNumber(db.minMarketCopper) or 100
  db.minQuantity = math.floor(UH.AsNumber(db.minQuantity) or 1)
  if db.minQuantity < 1 then
    db.minQuantity = 1
  end
  db.maxResults = math.floor(UH.AsNumber(db.maxResults) or 200)
  if db.maxResults < 1 then
    db.maxResults = 1
  end
  if db.maxResults > 2000 then
    db.maxResults = 2000
  end
  db.candidateCap = math.floor(UH.AsNumber(db.candidateCap) or 500)
  if db.candidateCap < 1 then
    db.candidateCap = 1
  end
  if db.candidateCap > 5000 then
    db.candidateCap = 5000
  end
  if type(db.nameFilter) ~= "string" then
    db.nameFilter = ""
  end

  -- SavedVariables may restore ignore keys as strings.
  local ignore = {}
  for key, value in pairs(db.ignore) do
    local itemID = UH.AsNumber(key)
    if itemID and value then
      ignore[itemID] = true
    end
  end
  db.ignore = ignore

  UH.db = db
  return db
end

function UH.Config.DB()
  if not UH.db then
    UH.Config.Apply()
  end
  return UH.db
end
