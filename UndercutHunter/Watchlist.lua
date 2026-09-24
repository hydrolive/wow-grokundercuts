local UH = UndercutHunter

UH.Watchlist = {}

local function DB()
  return UH.Config.DB()
end

function UH.Watchlist.IsIgnored(itemID)
  itemID = UH.AsNumber(itemID)
  return itemID ~= nil and DB().ignore[itemID] == true
end

function UH.Watchlist.Find(itemID)
  itemID = UH.AsNumber(itemID)
  if not itemID then
    return nil
  end
  local list = DB().watchlist
  for i = 1, #list do
    if list[i].itemID == itemID then
      return i
    end
  end
  return nil
end

function UH.Watchlist.ParseItem(text)
  text = UH.Trim(text or "")
  if text == "" then
    return nil, nil
  end
  local fromLink = text:match("item:(%d+)")
  if fromLink then
    local name = text:match("%[(.-)%]")
    return tonumber(fromLink), name
  end
  if text:match("^%d+$") then
    return tonumber(text), nil
  end
  return nil, nil
end

function UH.Watchlist.Add(itemID, name)
  itemID = UH.AsNumber(itemID)
  if not itemID or itemID <= 0 then
    return false
  end
  local db = DB()
  db.ignore[itemID] = nil
  local index = UH.Watchlist.Find(itemID)
  local record = UH.GetItemRecord(itemID)
  local resolved = (record and record.name) or name
  if index then
    if resolved and resolved ~= "" then
      db.watchlist[index].name = resolved
    end
  else
    db.watchlist[#db.watchlist + 1] = {
      itemID = itemID,
      name = resolved or ("Item " .. itemID),
    }
  end
  local label = resolved or name or tostring(itemID)
  UH.Print(string.format(UH.L.ADDED, label))
  if UH.UI and UH.UI.RefreshWatchlist then
    UH.UI.RefreshWatchlist()
  end
  return true
end

function UH.Watchlist.AddFromText(text)
  local itemID, name = UH.Watchlist.ParseItem(text)
  if not itemID then
    return false
  end
  return UH.Watchlist.Add(itemID, name)
end

function UH.Watchlist.AddExtraIDs(text)
  text = UH.Trim(text or "")
  if text == "" then
    return 0
  end
  if text:find("item:", 1, true) then
    return UH.Watchlist.AddFromText(text) and 1 or 0
  end
  local db = DB()
  local seen = {}
  for i = 1, #db.extraItemIDs do
    seen[db.extraItemIDs[i]] = true
  end
  local added = 0
  for num in text:gmatch("%d+") do
    local itemID = tonumber(num)
    if itemID and itemID > 0 and not seen[itemID] then
      seen[itemID] = true
      db.extraItemIDs[#db.extraItemIDs + 1] = itemID
      db.ignore[itemID] = nil
      added = added + 1
      UH.RequestItemData(itemID)
    end
  end
  if added > 0 then
    db.scanSource = "pricedCandidates"
    UH.Print(string.format(UH.L.EXTRA_ADDED, added))
    if UH.UI and UH.UI.SyncFromDB then
      UH.UI.SyncFromDB()
    end
  end
  return added
end

function UH.Watchlist.Remove(itemID)
  local index = UH.Watchlist.Find(itemID)
  if not index then
    return false
  end
  table.remove(DB().watchlist, index)
  UH.Print(UH.L.REMOVED)
  if UH.UI and UH.UI.RefreshWatchlist then
    UH.UI.RefreshWatchlist()
  end
  return true
end

function UH.Watchlist.Ignore(itemID, name)
  itemID = UH.AsNumber(itemID)
  if not itemID then
    return false
  end
  DB().ignore[itemID] = true
  local index = UH.Watchlist.Find(itemID)
  if index then
    table.remove(DB().watchlist, index)
  end
  local extras = DB().extraItemIDs
  for i = #extras, 1, -1 do
    if extras[i] == itemID then
      table.remove(extras, i)
    end
  end
  local label = name or tostring(itemID)
  UH.Print(string.format(UH.L.IGNORED, label))
  if UH.Results then
    UH.Results:DropItem(itemID)
  end
  if UH.UI and UH.UI.Refresh then
    UH.UI.Refresh()
  end
  if UH.UI and UH.UI.RefreshWatchlist then
    UH.UI.RefreshWatchlist()
  end
  return true
end

function UH.Watchlist.ResolveName(itemID)
  itemID = UH.AsNumber(itemID)
  local index = itemID and UH.Watchlist.Find(itemID)
  if not index then
    return
  end
  local record = UH.GetItemRecord(itemID)
  if record and record.name and record.name ~= "" then
    DB().watchlist[index].name = record.name
  end
end

function UH.Watchlist.Candidates()
  local db = DB()
  local list = {}
  local seen = {}

  local function push(itemID, name)
    itemID = UH.AsNumber(itemID)
    if not itemID or seen[itemID] or db.ignore[itemID] then
      return
    end
    seen[itemID] = true
    local record = UH.GetItemRecord(itemID)
    list[#list + 1] = {
      itemID = itemID,
      name = (record and record.name) or name or ("Item " .. itemID),
    }
  end

  for i = 1, #db.watchlist do
    local entry = db.watchlist[i]
    if type(entry) == "table" then
      push(entry.itemID, entry.name)
    end
  end

  if db.scanSource == "pricedCandidates" then
    for i = 1, #db.extraItemIDs do
      push(db.extraItemIDs[i], nil)
    end
  end

  return list
end
