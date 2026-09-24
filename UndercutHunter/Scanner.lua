local UH = UndercutHunter

-- Scan engine for Forever 1.60.1.
-- Modern path: SearchForItemKeys in chunks of at most 100, then SendSearchQuery
-- for items whose summary price can still be under the threshold.
-- Legacy path is used only when QueryAuctionItems exists and C_AuctionHouse does not.
-- Nothing here purchases. Queries yield with C_Timer.After. No busy-wait.

UH.Scanner = {
  running = false,
  generation = 0,
  queue = {},
  job = nil,
  waiting = nil,
  batchIndex = 0,
  batchTotal = 0,
  deep = nil,
  throttleToken = 0,
}

local function Status(text)
  if UH.UI and UH.UI.SetStatus then
    UH.UI.SetStatus(text)
  end
end

local function Refresh()
  if UH.UI and UH.UI.Refresh then
    UH.UI.Refresh()
  end
end

function UH.Scanner:Bump()
  self.generation = self.generation + 1
  self.throttleToken = self.throttleToken + 1
  return self.generation
end

function UH.Scanner:Stop(silent)
  local wasRunning = self.running or self.deep ~= nil
  self:Bump()
  self.running = false
  self.queue = {}
  self.job = nil
  self.waiting = nil
  self.readyFn = nil
  self.deep = nil
  UH.SetQueryLock(false)
  if not silent and wasRunning then
    Status(string.format(UH.L.STOPPED, UH.Results:Count()))
  end
  if UH.UI and UH.UI.UpdateButtons then
    UH.UI.UpdateButtons()
  end
end

function UH.Scanner:Finish()
  self.running = false
  self.waiting = nil
  self.job = nil
  self.readyFn = nil
  self.deep = nil
  UH.SetQueryLock(false)
  Status(string.format(UH.L.FOUND_DEALS, UH.Results:Count()))
  Refresh()
end

function UH.Scanner:SearchJobs(items)
  local jobs = {}
  for i = 1, #items do
    if items[i] and items[i].itemID then
      jobs[#jobs + 1] = { type = "search", item = items[i], pages = 0, lastCount = -1, retries = 0 }
    end
  end
  return jobs
end

function UH.Scanner:EnqueueFront(jobs)
  for i = #jobs, 1, -1 do
    table.insert(self.queue, 1, jobs[i])
  end
  self.batchTotal = self.batchIndex + #self.queue
end

function UH.Scanner:BuildCandidates()
  local list = UH.Watchlist.Candidates()
  local cap = UH.Config.DB().candidateCap or 500
  local priced = {}
  for i = 1, #list do
    if UH.Prices.GetMarket(list[i].itemID) then
      priced[#priced + 1] = list[i]
    end
  end
  local truncated = false
  if #priced > cap then
    local trimmed = {}
    for i = 1, cap do
      trimmed[i] = priced[i]
    end
    priced = trimmed
    truncated = true
  end
  return priced, truncated, #list
end

function UH.Scanner:EnqueueBrowse(candidates)
  local chunk = {}
  local byID = {}
  for i = 1, #candidates do
    local entry = candidates[i]
    chunk[#chunk + 1] = entry
    byID[entry.itemID] = entry
    if #chunk >= UH.MAX_BROWSE_KEYS then
      self.queue[#self.queue + 1] = { type = "browse", items = chunk, byID = byID, pages = 0, seen = {}, retries = 0 }
      chunk = {}
      byID = {}
    end
  end
  if #chunk > 0 then
    self.queue[#self.queue + 1] = { type = "browse", items = chunk, byID = byID, pages = 0, seen = {}, retries = 0 }
  end
end

function UH.Scanner:EnqueueLegacy(candidates)
  for i = 1, #candidates do
    self.queue[#self.queue + 1] = { type = "legacy", item = candidates[i], page = 0, retries = 0, waitTries = 0 }
  end
end

function UH.Scanner:Start()
  if self.running then
    Status(UH.L.ALREADY_SCANNING)
    return
  end
  if not UH.AHOpen() then
    UH.Print(UH.L.AH_CLOSED)
    return
  end
  UH.DetectAPI()
  if not UH.supportedAH then
    Status(UH.L.NO_API)
    UH.Print(UH.L.NO_API)
    return
  end
  if not UH.Prices.IsReady() then
    Status(UH.L.STATUS_MISSING)
    UH.Print(UH.L.AUCTIONATOR_MISSING)
    return
  end
  if UH.Buyout then
    UH.Buyout:CancelPending(false)
  end

  if not UH.Config.DB().limitToWatchlist
    and UH.HasFn(C_AuctionHouse, "ReplicateItems")
    and UH.HasFn(C_AuctionHouse, "GetReplicateItemInfo") then
    self:StartHouse()
    return
  end

  local candidates, truncated, rawCount = self:BuildCandidates()
  if #candidates == 0 then
    if rawCount == 0 then
      Status(UH.L.NO_WATCHLIST)
    else
      Status(UH.L.NO_PRICES)
      UH.Print(UH.L.NO_PRICES)
    end
    return
  end
  if truncated then
    UH.Print(string.format(UH.L.SCAN_TRUNCATED, UH.Config.DB().candidateCap))
  end

  local gen = self:Bump()
  self.running = true
  self.queue = {}
  self.job = nil
  self.waiting = nil
  self.deep = nil
  UH.Results:Clear()
  UH.SetQueryLock(true)

  if UH.modernAH then
    self:EnqueueBrowse(candidates)
  else
    self:EnqueueLegacy(candidates)
  end
  self.batchTotal = #self.queue
  self.batchIndex = 0
  Status(string.format(UH.L.SCANNING_BATCH, 0, self.batchTotal))
  self:Pump(gen)
end

function UH.Scanner:Pump(gen)
  if gen ~= self.generation or not self.running then
    return
  end
  if self.waiting then
    return
  end
  local job = table.remove(self.queue, 1)
  if not job then
    self:Finish()
    return
  end
  self.batchIndex = self.batchIndex + 1
  self.job = job
  Status(string.format(UH.L.SCANNING_BATCH, self.batchIndex, math.max(self.batchTotal, self.batchIndex)))
  if job.type == "browse" then
    self:RunBrowse(gen, job)
  elseif job.type == "search" then
    self:RunSearch(gen, job)
  elseif job.type == "legacy" then
    self:RunLegacy(gen, job)
  else
    self:Continue(gen)
  end
end

function UH.Scanner:Continue(gen)
  if gen ~= self.generation then
    return
  end
  self.waiting = nil
  self.job = nil
  self.readyFn = nil
  UH.After(UH.BATCH_GAP, function()
    self:Pump(gen)
  end)
end

function UH.Scanner:WhenReady(gen, fn)
  if gen ~= self.generation or not self.running then
    return
  end
  if UH.ThrottleReady() then
    fn()
    return
  end
  self.waiting = "throttle"
  self.throttleToken = self.throttleToken + 1
  local token = self.throttleToken
  self.readyFn = fn
  UH.After(UH.QUERY_TIMEOUT, function()
    if gen ~= self.generation or self.throttleToken ~= token or self.waiting ~= "throttle" then
      return
    end
    UH.Debug("throttle timeout")
    self.waiting = nil
    self.readyFn = nil
    fn()
  end)
end

function UH.Scanner:OnThrottleReady()
  if UH.Buyout and UH.Buyout:OnThrottleReady() then
    return
  end
  if self.waiting ~= "throttle" or not self.readyFn then
    return
  end
  local fn = self.readyFn
  self.readyFn = nil
  self.throttleToken = self.throttleToken + 1
  self.waiting = nil
  fn()
end

function UH.Scanner:RunBrowse(gen, job)
  self:WhenReady(gen, function()
    if gen ~= self.generation or not self.running or self.job ~= job then
      return
    end
    local keys = {}
    for i = 1, #job.items do
      local key = UH.ItemKey(job.items[i].itemID)
      if key then
        keys[#keys + 1] = key
      end
    end
    if #keys == 0 or #keys > UH.MAX_BROWSE_KEYS then
      self:FallbackSearch(gen, job)
      return
    end
    self.waiting = "browse"
    local ok, err = pcall(C_AuctionHouse.SearchForItemKeys, keys, UH.PriceSorts())
    if not ok then
      UH.Debug("SearchForItemKeys failed", err)
      self.waiting = nil
      self:FallbackSearch(gen, job)
      return
    end
    UH.After(UH.QUERY_TIMEOUT, function()
      if gen == self.generation and self.waiting == "browse" and self.job == job then
        UH.Debug("browse timeout")
        self:FinishBrowse(gen, job)
      end
    end)
  end)
end

function UH.Scanner:CollectBrowse(job)
  if not UH.HasFn(C_AuctionHouse, "GetBrowseResults") then
    return
  end
  local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
  if not ok or type(results) ~= "table" then
    return
  end
  for i = 1, #results do
    local info = results[i]
    local key = type(info) == "table" and info.itemKey or nil
    local itemID = key and UH.AsNumber(key.itemID)
    if itemID and job.byID[itemID] then
      job.seen[itemID] = info
    end
  end
end

function UH.Scanner:ShouldDetail(itemID, info)
  local db = UH.Config.DB()
  local minPrice = UH.AsNumber(info and info.minPrice) or 0
  if minPrice <= 0 then
    return db.includeBids and true or false
  end
  local market = UH.Prices.GetMarket(itemID)
  if not market or market <= 0 then
    return false
  end
  local threshold = (db.thresholdPercent or 50) / 100
  local asUnit = minPrice / market
  -- Forever 1.60.1: browse minPrice is a unit price on the modern API.
  -- Slack also keeps a stack whose reported price is the stack total.
  local asStack = (minPrice / UH.STACK_SLACK) / market
  return asUnit <= threshold or asStack <= threshold
end

function UH.Scanner:FinishBrowse(gen, job)
  if gen ~= self.generation or self.job ~= job then
    return
  end
  self.waiting = nil
  self:CollectBrowse(job)
  local anySeen = false
  local follow = {}
  for itemID, info in pairs(job.seen) do
    anySeen = true
    if self:ShouldDetail(itemID, info) then
      follow[#follow + 1] = job.byID[itemID]
    end
  end
  if not anySeen then
    UH.Debug("browse empty, searching items directly")
    self:EnqueueFront(self:SearchJobs(job.items))
  else
    self:EnqueueFront(self:SearchJobs(follow))
  end
  self.job = nil
  UH.After(UH.BATCH_GAP, function()
    self:Pump(gen)
  end)
end

function UH.Scanner:FallbackSearch(gen, job)
  self.waiting = nil
  self:EnqueueFront(self:SearchJobs(job.items))
  self.job = nil
  UH.After(UH.BATCH_GAP, function()
    self:Pump(gen)
  end)
end

function UH.Scanner:OnBrowse()
  local job = self.job
  if self.waiting ~= "browse" or not job or job.type ~= "browse" then
    return false
  end
  self:CollectBrowse(job)
  local full = true
  if UH.HasFn(C_AuctionHouse, "HasFullBrowseResults") then
    local ok, hasFull = pcall(C_AuctionHouse.HasFullBrowseResults)
    if ok then
      full = hasFull and true or false
    end
  end
  if not full and job.pages < 6 and UH.HasFn(C_AuctionHouse, "RequestMoreBrowseResults") and UH.ThrottleReady() then
    job.pages = job.pages + 1
    pcall(C_AuctionHouse.RequestMoreBrowseResults)
    return true
  end
  self:FinishBrowse(self.generation, job)
  return true
end

function UH.Scanner:OnBrowseFailure()
  if self.waiting ~= "browse" or not self.job then
    return
  end
  UH.Debug("browse failure")
  local job = self.job
  local gen = self.generation
  self.waiting = nil
  self:FallbackSearch(gen, job)
end

function UH.Scanner:RunSearch(gen, job)
  self:WhenReady(gen, function()
    if gen ~= self.generation or not self.running or self.job ~= job then
      return
    end
    local itemKey = UH.ItemKey(job.item.itemID)
    job.itemKey = itemKey
    self.waiting = "search"
    local ok, err = pcall(C_AuctionHouse.SendSearchQuery, itemKey, UH.PriceSorts(), false)
    if not ok then
      UH.Debug("SendSearchQuery failed", job.item.itemID, err)
      self:Continue(gen)
      return
    end
    UH.After(UH.QUERY_TIMEOUT, function()
      if gen == self.generation and self.waiting == "search" and self.job == job then
        UH.Debug("search timeout", job.item.itemID)
        self:Continue(gen)
      end
    end)
  end)
end

function UH.Scanner:IngestItemResults(job, itemKey)
  local ok, count = pcall(C_AuctionHouse.GetNumItemSearchResults, itemKey)
  count = ok and UH.AsNumber(count) or 0
  if not count or count < 1 then
    return false, true
  end
  local added = false
  local lastUnit = nil
  local market = UH.Prices.GetMarket(job.item.itemID)
  for i = 1, count do
    local okInfo, info = pcall(C_AuctionHouse.GetItemSearchResultInfo, itemKey, i)
    if okInfo and type(info) == "table" and not info.containsOwnerItem then
      local qty = UH.AsNumber(info.quantity) or 1
      local buyout = UH.AsNumber(info.buyoutAmount) or 0
      if qty > 0 and buyout > 0 then
        lastUnit = buyout / qty
      end
      if UH.Results:Consider({
        itemID = job.item.itemID,
        name = job.item.name,
        link = info.itemLink,
        quantity = qty,
        buyoutAmount = buyout,
        bidAmount = UH.AsNumber(info.bidAmount) or UH.AsNumber(info.minBid),
        auctionID = info.auctionID,
        timeLeft = info.timeLeft,
        timeLeftSeconds = info.timeLeftSeconds,
        owner = UH.Results.OwnerName(info.owners),
        itemKey = itemKey,
        isCommodity = false,
      }) then
        added = true
      end
    end
  end
  local over = false
  local threshold = UH.Config.DB().thresholdPercent or 50
  if market and lastUnit and lastUnit > 0 and (lastUnit / market * 100) > threshold then
    over = true
  end
  if count == job.lastCount then
    over = true
  end
  job.lastCount = count
  return added, over
end

function UH.Scanner:OnItemResults(itemKey)
  local job = self.job
  if self.waiting ~= "search" or not job or job.type ~= "search" then
    return false
  end
  local itemID = type(itemKey) == "table" and UH.AsNumber(itemKey.itemID) or nil
  if itemID ~= job.item.itemID then
    return false
  end
  local added, over = self:IngestItemResults(job, itemKey)
  if added then
    Refresh()
  end
  if not over and job.pages < 4 and UH.HasFn(C_AuctionHouse, "RequestMoreItemSearchResults") and UH.ThrottleReady() then
    local full = true
    if UH.HasFn(C_AuctionHouse, "HasFullItemSearchResults") then
      local okFull, hasFull = pcall(C_AuctionHouse.HasFullItemSearchResults, itemKey)
      if okFull then
        full = hasFull and true or false
      end
    end
    if not full then
      job.pages = job.pages + 1
      pcall(C_AuctionHouse.RequestMoreItemSearchResults, itemKey)
      return true
    end
  end
  self:Continue(self.generation)
  return true
end

function UH.Scanner:OnCommodityResults(itemID)
  local job = self.job
  itemID = UH.AsNumber(itemID)
  if self.waiting ~= "search" or not job or job.type ~= "search" or itemID ~= job.item.itemID then
    return false
  end
  if not UH.HasFn(C_AuctionHouse, "GetNumCommoditySearchResults") then
    self:Continue(self.generation)
    return true
  end
  local ok, count = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)
  count = ok and UH.AsNumber(count) or 0
  local added = false
  local lastUnit = nil
  for i = 1, (count or 0) do
    local okInfo, info = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, i)
    if okInfo and type(info) == "table" and not info.containsOwnerItem then
      local unit = UH.AsNumber(info.unitPrice) or 0
      local qty = UH.AsNumber(info.quantity) or 0
      if unit > 0 then
        lastUnit = unit
      end
      if UH.Results:Consider({
        itemID = itemID,
        name = job.item.name,
        quantity = qty,
        unitPrice = unit,
        buyoutAmount = unit * qty,
        auctionID = info.auctionID,
        timeLeftSeconds = info.timeLeftSeconds,
        owner = UH.Results.OwnerName(info.owners),
        itemKey = job.itemKey,
        isCommodity = true,
      }) then
        added = true
      end
    end
  end
  if added then
    Refresh()
  end
  local market = UH.Prices.GetMarket(itemID)
  local threshold = UH.Config.DB().thresholdPercent or 50
  local over = true
  if market and lastUnit and lastUnit > 0 and (lastUnit / market * 100) <= threshold then
    over = false
  end
  if not over and job.pages < 3 and UH.HasFn(C_AuctionHouse, "RequestMoreCommoditySearchResults") and UH.ThrottleReady() then
    local full = true
    if UH.HasFn(C_AuctionHouse, "HasFullCommoditySearchResults") then
      local okFull, hasFull = pcall(C_AuctionHouse.HasFullCommoditySearchResults, itemID)
      if okFull then
        full = hasFull and true or false
      end
    end
    if not full then
      job.pages = job.pages + 1
      pcall(C_AuctionHouse.RequestMoreCommoditySearchResults, itemID)
      return true
    end
  end
  self:Continue(self.generation)
  return true
end

function UH.Scanner:RunLegacy(gen, job)
  local function attempt()
    if gen ~= self.generation or not self.running or self.job ~= job then
      return
    end
    local ready = UH.ThrottleReady()
    if type(CanSendAuctionQuery) == "function" then
      local ok, allowed = pcall(CanSendAuctionQuery)
      if ok and not allowed then
        ready = false
      end
    end
    if not ready then
      job.waitTries = (job.waitTries or 0) + 1
      if job.waitTries > 40 then
        UH.Debug("legacy query never became ready", job.item and job.item.itemID)
        self:Continue(gen)
        return
      end
      self.waiting = "legacy-wait"
      UH.After(0.35, function()
        if gen == self.generation and self.job == job and self.running then
          self.waiting = nil
          attempt()
        end
      end)
      return
    end
    self.waiting = "legacy"
    local name = job.item.name or ""
    local page = job.page or 0
    local ok, err = pcall(QueryAuctionItems, name, nil, nil, page, false, nil, false, true)
    if not ok then
      UH.Debug("QueryAuctionItems failed", err)
      ok = pcall(QueryAuctionItems, name, 0, 0, page, 0, 0, false, false)
    end
    if not ok then
      self:Continue(gen)
      return
    end
    UH.After(UH.QUERY_TIMEOUT, function()
      if gen == self.generation and self.waiting == "legacy" and self.job == job then
        UH.Debug("legacy timeout", name)
        self:Continue(gen)
      end
    end)
  end
  attempt()
end

function UH.Scanner:OnLegacyUpdate()
  local job = self.job
  if self.waiting ~= "legacy" or not job or job.type ~= "legacy" then
    return false
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
  local me = type(UnitName) == "function" and UnitName("player") or nil
  local added = false
  for index = 1, batch do
    local okInfo, values = pcall(function()
      return { GetAuctionItemInfo("list", index) }
    end)
    if okInfo and type(values) == "table" then
      local name = values[1]
      local texture = values[2]
      local count = UH.AsNumber(values[3]) or 0
      local quality = UH.AsNumber(values[4])
      local minBid = UH.AsNumber(values[8])
      local buyout = UH.AsNumber(values[10]) or 0
      local owner = values[14]
      local itemID = UH.AsNumber(values[17]) or job.item.itemID
      if itemID == job.item.itemID and (not owner or not me or owner ~= me) then
        local link = nil
        if type(GetAuctionItemLink) == "function" then
          local okLink, itemLink = pcall(GetAuctionItemLink, "list", index)
          if okLink and type(itemLink) == "string" then
            link = itemLink
          end
        end
        local timeLeft = nil
        if type(GetAuctionItemTimeLeft) == "function" then
          local okTime, left = pcall(GetAuctionItemTimeLeft, "list", index)
          if okTime then
            timeLeft = left
          end
        end
        if UH.Results:Consider({
          itemID = itemID,
          name = (type(name) == "string" and name ~= "" and name) or job.item.name,
          link = link,
          icon = texture,
          quality = quality,
          quantity = count,
          buyoutAmount = buyout,
          bidAmount = minBid,
          owner = type(owner) == "string" and owner or nil,
          timeLeft = timeLeft,
          listIndex = index,
          page = job.page,
          legacyName = job.item.name,
          isCommodity = false,
        }) then
          added = true
        end
      end
    end
  end
  if added then
    Refresh()
  end
  local shown = ((job.page or 0) + 1) * perPage
  if batch >= perPage and shown < total and (job.page or 0) < 20 then
    self:EnqueueFront({
      { type = "legacy", item = job.item, page = (job.page or 0) + 1, retries = 0, waitTries = 0 },
    })
  end
  self:Continue(self.generation)
  return true
end

function UH.Scanner:OnDropped()
  local job = self.job
  if not job or not self.running then
    return
  end
  UH.Debug("throttled message dropped", job.type)
  job.retries = (job.retries or 0) + 1
  local gen = self.generation
  if job.retries > 2 then
    self:Continue(gen)
    return
  end
  self.waiting = nil
  table.insert(self.queue, 1, job)
  self.job = nil
  self.batchIndex = math.max(0, self.batchIndex - 1)
  UH.After(0.3, function()
    self:Pump(gen)
  end)
end

function UH.Scanner:StartHouse()
  if self.running then
    Status(UH.L.ALREADY_SCANNING)
    return
  end
  if not UH.AHOpen() then
    UH.Print(UH.L.AH_CLOSED)
    return
  end
  if not UH.HasFn(C_AuctionHouse, "ReplicateItems") or not UH.HasFn(C_AuctionHouse, "GetReplicateItemInfo") then
    UH.Print(UH.L.DEEP_UNSUPPORTED)
    Status(UH.L.DEEP_UNSUPPORTED)
    return
  end
  if not UH.Prices.IsReady() then
    UH.Print(UH.L.AUCTIONATOR_MISSING)
    Status(UH.L.STATUS_MISSING)
    return
  end
  if UH.Buyout then
    UH.Buyout:CancelPending(false)
  end
  self:StartDeepConfirmed()
end

function UH.Scanner:StartDeep()
  if self.running then
    Status(UH.L.ALREADY_SCANNING)
    return
  end
  if not UH.AHOpen() then
    UH.Print(UH.L.AH_CLOSED)
    return
  end
  if not UH.HasFn(C_AuctionHouse, "ReplicateItems") or not UH.HasFn(C_AuctionHouse, "GetReplicateItemInfo") then
    UH.Print(UH.L.DEEP_UNSUPPORTED)
    return
  end
  if not UH.Prices.IsReady() then
    UH.Print(UH.L.AUCTIONATOR_MISSING)
    Status(UH.L.STATUS_MISSING)
    return
  end
  if type(StaticPopup_Show) ~= "function" then
    self:StartDeepConfirmed()
    return
  end
  StaticPopup_Show("UNDERCUTHUNTER_DEEP")
end

function UH.Scanner:StartDeepConfirmed()
  if not UH.AHOpen() or not UH.HasFn(C_AuctionHouse, "ReplicateItems") then
    return
  end
  if UH.Buyout then
    UH.Buyout:CancelPending(false)
  end
  local gen = self:Bump()
  self.running = true
  self.queue = {}
  self.job = nil
  self.waiting = nil
  UH.Results:Clear()
  UH.SetQueryLock(true)
  self.deep = { gen = gen, stage = "request", index = 0, total = 0, prices = {} }
  Status(string.format(UH.L.DEEP_PROGRESS, 0, 0))
  local ok, err = pcall(C_AuctionHouse.ReplicateItems)
  if not ok then
    UH.Debug("ReplicateItems failed", err)
    self.deep = nil
    self:Finish()
    return
  end
  UH.After(30, function()
    if gen == self.generation and self.deep and self.deep.stage == "request" then
      UH.Debug("replicate timeout")
      self:Finish()
    end
  end)
end

function UH.Scanner:OnReplicate()
  if not self.deep or self.deep.stage ~= "request" then
    return false
  end
  self.deep.stage = "read"
  self.deep.index = 0
  local ok, count = pcall(C_AuctionHouse.GetNumReplicateItems)
  self.deep.total = ok and (UH.AsNumber(count) or 0) or 0
  self:ReadDeepSlice()
  return true
end

function UH.Scanner:ReadDeepSlice()
  local deep = self.deep
  local gen = self.generation
  if not deep or not self.running or gen ~= self.generation or deep.stage ~= "read" then
    return
  end
  local total = deep.total or 0
  local db = UH.Config.DB()
  local watch = nil
  if db.limitToWatchlist then
    watch = {}
    local candidates = UH.Watchlist.Candidates()
    for i = 1, #candidates do
      watch[candidates[i].itemID] = candidates[i]
    end
  end
  local prices = deep.prices or {}
  deep.prices = prices
  local threshold = db.thresholdPercent or 50
  local last = math.min(total, deep.index + 250)
  for i = deep.index, last - 1 do
    local ok, values = pcall(function()
      return { C_AuctionHouse.GetReplicateItemInfo(i) }
    end)
    if ok and type(values) == "table" then
      local name = values[1]
      local texture = values[2]
      local count = UH.AsNumber(values[3]) or 0
      local quality = UH.AsNumber(values[4])
      local buyout = UH.AsNumber(values[10]) or 0
      local owner = values[14]
      local itemID = UH.AsNumber(values[17])
      local me = type(UnitName) == "function" and UnitName("player") or nil
      local priced = itemID and prices[itemID]
      if itemID and priced == nil then
        priced = UH.Prices.GetAuctionatorByID(itemID) or false
        prices[itemID] = priced
      end
      local cheap = false
      if priced and count > 0 and buyout > 0 then
        cheap = (buyout / count) / priced * 100 <= threshold
      elseif priced and db.includeBids and count > 0 then
        cheap = true
      end
      if cheap and itemID and (not watch or watch[itemID]) and (not owner or not me or owner ~= me) then
        local known = watch and watch[itemID]
        UH.Results:Consider({
          itemID = itemID,
          name = (type(name) == "string" and name ~= "" and name) or (known and known.name) or nil,
          icon = texture,
          quality = quality,
          quantity = count,
          buyoutAmount = buyout,
          owner = type(owner) == "string" and owner or nil,
          isCommodity = false,
        })
      end
    end
  end
  deep.index = last
  if #UH.Results.rows > (db.maxResults or 200) then
    local savedFilter = db.nameFilter
    db.nameFilter = ""
    UH.Results.rows = UH.Results:GetView()
    db.nameFilter = savedFilter
  end
  Status(string.format(UH.L.DEEP_PROGRESS, math.min(deep.index, total), total))
  if deep.index % 1000 < 250 then
    Refresh()
  end
  if deep.index >= total then
    self.deep = nil
    if total == 0 then
      self.running = false
      self.waiting = nil
      UH.SetQueryLock(false)
      Status(UH.L.HOUSE_EMPTY)
      UH.Print(UH.L.HOUSE_EMPTY)
      Refresh()
      return
    end
    Refresh()
    self:Finish()
    return
  end
  UH.After(0.01, function()
    if gen == self.generation then
      self:ReadDeepSlice()
    end
  end)
end

local function RoutedSearch(_, itemKey)
  if UH.Buyout and UH.Buyout:OnItemResults(itemKey) then
    return
  end
  UH.Scanner:OnItemResults(itemKey)
end

local function RoutedCommodity(_, itemID)
  if UH.Buyout and UH.Buyout:OnCommodityResults(itemID) then
    return
  end
  UH.Scanner:OnCommodityResults(itemID)
end

local function RoutedLegacy()
  if UH.Buyout and UH.Buyout:OnLegacyList() then
    return
  end
  UH.Scanner:OnLegacyUpdate()
end

UH.On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function()
  UH.Scanner:OnBrowse()
end)
UH.On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function()
  UH.Scanner:OnBrowse()
end)
UH.On("AUCTION_HOUSE_BROWSE_FAILURE", function()
  UH.Scanner:OnBrowseFailure()
end)
UH.On("ITEM_SEARCH_RESULTS_UPDATED", RoutedSearch)
UH.On("ITEM_SEARCH_RESULTS_ADDED", RoutedSearch)
UH.On("COMMODITY_SEARCH_RESULTS_UPDATED", RoutedCommodity)
UH.On("COMMODITY_SEARCH_RESULTS_ADDED", RoutedCommodity)
UH.On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
  UH.Scanner:OnThrottleReady()
end)
UH.On("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
  UH.Scanner:OnDropped()
end)
UH.On("AUCTION_ITEM_LIST_UPDATE", RoutedLegacy)
UH.On("REPLICATE_ITEM_LIST_UPDATE", function()
  UH.Scanner:OnReplicate()
end)
