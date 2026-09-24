local UH = UndercutHunter

UH.UI = UH.UI or {}
UH.UI.ROW_H = 20
UH.UI.rows = {}
UH.UI.watchRows = {}
UH.UI.view = {}
UH.UI.watchIndex = nil
UH.UI.visible = 8
UH.UI.syncing = false
UH.UI.scrollLock = false

local function Solid(texture, r, g, b, a)
  if texture.SetColorTexture then
    texture:SetColorTexture(r, g, b, a or 1)
  else
    texture:SetTexture("Interface\\Buttons\\WHITE8X8")
    texture:SetVertexColor(r, g, b, a or 1)
  end
end

local function MakeButton(parent, text, width, height)
  local ok, button = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
  if not ok or not button then
    button = CreateFrame("Button", nil, parent)
    button:SetNormalFontObject(GameFontNormal)
  end
  button:SetSize(width, height or 22)
  button:SetText(text)
  return button
end

local function MakeEdit(parent, width)
  local ok, box = pcall(CreateFrame, "EditBox", nil, parent, "InputBoxTemplate")
  if not ok or not box then
    box = CreateFrame("EditBox", nil, parent)
  end
  box:SetSize(width, 20)
  box:SetAutoFocus(false)
  box:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
  box:SetMaxLetters(48)
  box:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end)
  box:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
  end)
  return box
end

local function MakeSlider(parent)
  local ok, slider = pcall(CreateFrame, "Slider", nil, parent, "OptionsSliderTemplate")
  if not ok or not slider then
    slider = CreateFrame("Slider", nil, parent)
    slider:SetOrientation("HORIZONTAL")
    slider:SetHeight(16)
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  end
  slider:SetWidth(120)
  slider:SetMinMaxValues(1, 100)
  slider:SetValueStep(1)
  if slider.SetObeyStepOnDrag then
    slider:SetObeyStepOnDrag(true)
  end
  local frameName = slider.GetName and slider:GetName()
  if frameName then
    local suffixes = { "Low", "High", "Text" }
    for i = 1, #suffixes do
      local region = _G[frameName .. suffixes[i]]
      if region and region.Hide then
        region:Hide()
      end
    end
  end
  return slider
end

local function MakeBar(parent)
  -- Forever's UIPanelScrollBarTemplate runs Blizzard's secure OnValueChanged,
  -- which calls GetParent():SetVerticalScroll. These bars sit on a normal
  -- frame, so that call is nil and opening the AH errors. A plain slider
  -- keeps the wheel and drag behavior without that script.
  local bar = CreateFrame("Slider", nil, parent)
  bar:SetOrientation("VERTICAL")
  bar:SetWidth(16)
  bar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
  local track = bar:CreateTexture(nil, "BACKGROUND")
  Solid(track, 0, 0, 0, 0.55)
  track:SetWidth(6)
  track:SetPoint("TOP", bar, "TOP", 0, 0)
  track:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
  bar:SetMinMaxValues(0, 0)
  bar:SetValueStep(1)
  if bar.SetObeyStepOnDrag then
    bar:SetObeyStepOnDrag(true)
  end
  bar:SetScript("OnValueChanged", nil)
  bar:SetValue(0)
  return bar
end

local function Checkbox(parent, text, key)
  local wrap = CreateFrame("Frame", nil, parent)
  local ok, box = pcall(CreateFrame, "CheckButton", nil, wrap, "UICheckButtonTemplate")
  if not ok or not box then
    box = CreateFrame("CheckButton", nil, wrap)
  end
  box:SetSize(22, 22)
  box:SetPoint("LEFT", wrap, "LEFT", 0, 0)
  local label = wrap:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetText(text)
  label:SetPoint("LEFT", box, "RIGHT", 1, 0)
  local width = 26 + math.max(label:GetStringWidth(), #text * 5.5)
  wrap:SetSize(width, 22)
  box.key = key
  box:SetScript("OnClick", function(self)
    if UH.UI.syncing then
      return
    end
    UH.Config.DB()
    UH.db[key] = self:GetChecked() and true or false
    if key == "includePoor" or key == "includeBids" or key == "useVendorFallback" then
      UH.Results:Reprice()
    end
    UH.UI.Refresh()
  end)
  return wrap, box
end

local function ColumnSpec(width, showOwner)
  local owner = showOwner and 72 or 0
  local fixed = 20 + 34 + 72 + 72 + 46 + 46 + 108 + 58 + owner
  local name = width - fixed - 8
  if name < 70 then
    name = 70
  end
  return {
    icon = 20,
    name = name,
    qty = 34,
    listed = 72,
    market = 72,
    pctOf = 46,
    pctOff = 46,
    saved = 108,
    time = 58,
    owner = owner,
  }
end

function UH.UI.SetStatus(text)
  UH.lastStatus = text or ""
  if UH.UI.statusFS then
    UH.UI.statusFS:SetText(UH.lastStatus)
  end
end

function UH.UI.SetBuyoutLabel(text)
  if UH.UI.buyoutButton then
    UH.UI.buyoutButton:SetText(text)
  end
end

function UH.UI.UpdateOverlay()
  local overlay = UH.UI.overlay
  if not overlay then
    return
  end
  if not UH.supportedAH then
    overlay:SetText(UH.L.NO_API)
    overlay:Show()
    return
  end
  if not UH.Prices.IsReady() then
    overlay:SetText(UH.L.AUCTIONATOR_MISSING)
    overlay:Show()
    return
  end
  overlay:Hide()
end

function UH.UI.UpdateButtons()
  UH.UI.UpdateOverlay()
  if not UH.UI.scanButton then
    return
  end
  local confirmOpen = UH.Buyout and UH.Buyout.fresh and not UH.Buyout.armed
  local busy = UH.queryLock or (UH.Scanner and UH.Scanner.running) or confirmOpen or (UH.Buyout and UH.Buyout.commodity)
  local ready = UH.supportedAH and UH.Prices.IsReady()
  UH.UI.scanButton:SetEnabled(ready and not busy)
  UH.UI.stopButton:SetEnabled(UH.Scanner and UH.Scanner.running and true or false)
  if UH.UI.deepButton then
    UH.UI.deepButton:SetEnabled(ready and not busy and UH.modernAH)
  end
  local selected = UH.Results:Selected()
  local armed = UH.Buyout and UH.Buyout.armed
  local canBuy = false
  if armed and not busy then
    canBuy = true
  elseif ready and not busy and selected and not selected.bidOnly and (selected.buyoutAmount or 0) > 0 then
    canBuy = true
  end
  UH.UI.buyoutButton:SetEnabled(canBuy)
end

function UH.UI.SyncFromDB()
  local db = UH.Config.DB()
  UH.UI.syncing = true
  if UH.UI.slider then
    UH.UI.slider:SetValue(db.thresholdPercent or 50)
  end
  if UH.UI.thresholdBox then
    UH.UI.thresholdBox:SetText(tostring(db.thresholdPercent or 50))
  end
  if UH.UI.minGoldBox then
    UH.UI.minGoldBox:SetText(tostring(db.minDiscountGold or 0))
  end
  if UH.UI.minQtyBox then
    UH.UI.minQtyBox:SetText(tostring(db.minQuantity or 1))
  end
  if UH.UI.capBox then
    UH.UI.capBox:SetText(tostring(db.candidateCap or 500))
  end
  if UH.UI.filterBox and UH.UI.filterBox:GetText() ~= (db.nameFilter or "") then
    UH.UI.filterBox:SetText(db.nameFilter or "")
  end
  if UH.UI.checks then
    for key, box in pairs(UH.UI.checks) do
      box:SetChecked(db[key] and true or false)
    end
  end
  if UH.UI.sortButton then
    UH.UI.sortButton:SetText(UH.UI.SortLabel())
  end
  if UH.UI.sourceButton then
    UH.UI.sourceButton:SetText(UH.UI.SourceLabel())
  end
  UH.UI.syncing = false
end

function UH.UI.SortLabel()
  local mode = UH.Config.DB().sortMode
  if mode == "percent" then
    return UH.L.SORT_PERCENT
  end
  if mode == "goldSaved" then
    return UH.L.SORT_GOLD
  end
  return UH.L.SORT_PERCENT_GOLD
end

function UH.UI.SourceLabel()
  if UH.Config.DB().scanSource == "pricedCandidates" then
    return UH.L.SOURCE_PASTED
  end
  return UH.L.SOURCE_WATCHLIST
end

function UH.UI.ApplyColumns(row)
  local cols = UH.UI.cols or ColumnSpec(400, false)
  local x = 1
  local function place(widget, key, justify)
    local width = cols[key] or 0
    widget:ClearAllPoints()
    if width <= 0 then
      widget:Hide()
      return
    end
    widget:Show()
    widget:SetPoint("LEFT", row, "LEFT", x + 1, 0)
    if widget.SetWidth then
      widget:SetWidth(math.max(8, width - 2))
    end
    if widget.SetJustifyH and justify then
      widget:SetJustifyH(justify)
    end
    x = x + width
  end
  row.icon:ClearAllPoints()
  row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
  x = cols.icon
  place(row.name, "name", "LEFT")
  place(row.qty, "qty", "RIGHT")
  place(row.listed, "listed", "RIGHT")
  place(row.market, "market", "RIGHT")
  place(row.pctOf, "pctOf", "RIGHT")
  place(row.pctOff, "pctOff", "RIGHT")
  place(row.saved, "saved", "RIGHT")
  place(row.time, "time", "LEFT")
  place(row.owner, "owner", "LEFT")
end

function UH.UI.PaintRow(row)
  local data = row.data
  if not data or not row.bg then
    return
  end
  local selected = UH.Results.selectedKey == UH.RowKey(data)
  local r, g, b, a
  if selected then
    r, g, b, a = 0.38, 0.32, 0.08, 0.95
  elseif (data.percentOff or 0) >= 70 then
    r, g, b, a = 0.07, 0.30, 0.11, 0.95
  elseif (data.percentOff or 0) >= 50 then
    r, g, b, a = 0.26, 0.22, 0.07, 0.90
  else
    r, g, b, a = 0.07, 0.07, 0.07, 0.55
  end
  if row.hover and not selected then
    r, g, b = r + 0.07, g + 0.07, b + 0.04
  end
  Solid(row.bg, r, g, b, a)
end

local function RowLink(data)
  if data.link and data.link ~= "" then
    return data.link
  end
  if not data.itemID then
    return nil
  end
  local hex = UH.QualityHex(data.quality)
  local name = data.name or "Item"
  return hex .. "|Hitem:" .. tostring(data.itemID) .. ":::::::::::::|h[" .. name .. "]|h|r"
end

function UH.UI.FillRow(row, data)
  UH.UI.ApplyColumns(row)
  if data.icon then
    row.icon:SetTexture(data.icon)
    row.icon:Show()
  else
    row.icon:Hide()
  end
  row.name:SetText(UH.QualityHex(data.quality) .. (data.name or "?") .. "|r")
  row.qty:SetText(tostring(data.quantity or 0))
  if data.bidOnly then
    row.listed:SetText("bid")
    row.saved:SetText("-")
  else
    row.listed:SetText(UH.FormatMoneyPlain(data.unitListed))
    row.saved:SetText(UH.FormatMoneyPlain(data.goldSavedUnit) .. " / " .. UH.FormatMoneyPlain(data.goldSavedStack))
  end
  if data.unitMarket and data.unitMarket > 0 then
    row.market:SetText(UH.FormatMoneyPlain(data.unitMarket))
  else
    row.market:SetText("-")
  end
  row.pctOf:SetText(string.format("%.0f", data.percentOfMarket or 0))
  row.pctOff:SetText(string.format("%.0f", data.percentOff or 0))
  row.time:SetText(data.timeLeftText or "")
  row.owner:SetText(data.owner or "")
  UH.UI.PaintRow(row)
end

local function ShowTooltip(row)
  local data = row.data
  if not data or not GameTooltip then
    return
  end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  local shown = false
  local link = RowLink(data)
  if link and GameTooltip.SetHyperlink then
    local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, link)
    shown = ok
  end
  if not shown and data.itemID and GameTooltip.SetItemByID then
    pcall(GameTooltip.SetItemByID, GameTooltip, data.itemID)
  end
  GameTooltip:Show()
end

local function CreateResultRow(parent)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(UH.UI.ROW_H)
  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints()
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(16, 16)
  local function text(justify)
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
  end
  row.name = text("LEFT")
  row.qty = text("RIGHT")
  row.listed = text("RIGHT")
  row.market = text("RIGHT")
  row.pctOf = text("RIGHT")
  row.pctOff = text("RIGHT")
  row.saved = text("RIGHT")
  row.time = text("LEFT")
  row.owner = text("LEFT")
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", function(self, button)
    if not self.data then
      return
    end
    if button == "RightButton" then
      UH.UI.ShowMenu(self.data)
      return
    end
    if IsModifiedClick and IsModifiedClick("CHATLINK") then
      local link = RowLink(self.data)
      if link and ChatEdit_InsertLink then
        ChatEdit_InsertLink(link)
      end
      return
    end
    UH.Results:Select(self.data)
  end)
  row:SetScript("OnDoubleClick", function(self)
    if self.data and UH.Config.DB().doubleClickBuyout then
      UH.Buyout:Request(self.data)
    end
  end)
  row:SetScript("OnEnter", function(self)
    self.hover = true
    UH.UI.PaintRow(self)
    ShowTooltip(self)
  end)
  row:SetScript("OnLeave", function(self)
    self.hover = false
    UH.UI.PaintRow(self)
    if GameTooltip then
      GameTooltip:Hide()
    end
  end)
  return row
end

function UH.UI.EnsureRows()
  local height = UH.UI.list and UH.UI.list:GetHeight() or 0
  local count = math.floor(height / UH.UI.ROW_H)
  if count < 1 then
    count = 1
  end
  if count > 24 then
    count = 24
  end
  UH.UI.visible = count
  for i = #UH.UI.rows + 1, count do
    UH.UI.rows[i] = CreateResultRow(UH.UI.list)
  end
  for i = 1, #UH.UI.rows do
    local row = UH.UI.rows[i]
    if i <= count then
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", UH.UI.list, "TOPLEFT", 0, -((i - 1) * UH.UI.ROW_H))
      row:SetPoint("TOPRIGHT", UH.UI.list, "TOPRIGHT", 0, -((i - 1) * UH.UI.ROW_H))
    else
      row:Hide()
      row.data = nil
    end
  end
end

function UH.UI.Refresh()
  if not UH.UI.list or UH.UI.refreshing then
    return
  end
  UH.UI.refreshing = true
  local width = UH.UI.list:GetWidth()
  if width and width > 40 then
    UH.UI.cols = ColumnSpec(width, UH.Config.DB().showOwner)
  end
  UH.UI.LayoutHeader()
  UH.UI.EnsureRows()
  local view = UH.Results:GetView()
  UH.UI.view = view
  local maxScroll = math.max(0, #view - UH.UI.visible)
  local bar = UH.UI.scrollBar
  if bar then
    UH.UI.scrollLock = true
    bar:SetMinMaxValues(0, maxScroll)
    if bar:GetValue() > maxScroll then
      bar:SetValue(maxScroll)
    end
    UH.UI.scrollLock = false
  end
  local offset = bar and math.floor((bar:GetValue() or 0) + 0.5) or 0
  for i = 1, UH.UI.visible do
    local row = UH.UI.rows[i]
    local data = view[offset + i]
    row.data = data
    if data then
      row:Show()
      UH.UI.FillRow(row, data)
    else
      row:Hide()
    end
  end
  UH.UI.RefreshWatchlist()
  UH.UI.UpdateButtons()
  UH.UI.refreshing = false
end

function UH.UI.LayoutHeader()
  local header = UH.UI.header
  local cols = UH.UI.cols
  if not header or not cols then
    return
  end
  local labels = {
    { key = "name", text = UH.L.COL_ITEM, sort = "percentThenGold" },
    { key = "qty", text = UH.L.COL_QTY },
    { key = "listed", text = UH.L.COL_LISTED },
    { key = "market", text = UH.L.COL_MARKET },
    { key = "pctOf", text = UH.L.COL_PCT_MKT },
    { key = "pctOff", text = UH.L.COL_PCT_OFF, sort = "percent" },
    { key = "saved", text = UH.L.COL_SAVED, sort = "goldSaved" },
    { key = "time", text = UH.L.COL_LEFT },
    { key = "owner", text = UH.L.COL_OWNER },
  }
  local hits = {}
  local x = cols.icon
  for i = 1, #labels do
    local info = labels[i]
    local fs = header.labels[i]
    local width = cols[info.key] or 0
    fs:ClearAllPoints()
    if width > 0 then
      fs:SetPoint("LEFT", header, "LEFT", x + 1, 0)
      fs:SetWidth(math.max(8, width - 2))
      fs:SetText(info.text)
      fs:Show()
      fs.sortMode = info.sort
      if info.sort then
        hits[#hits + 1] = { x = x, width = width, sort = info.sort }
      end
    else
      fs:Hide()
    end
    x = x + width
  end
  UH.UI.headerHits = hits
end

function UH.UI.RefreshWatchlist()
  local list = UH.UI.watchList
  if not list then
    return
  end
  local entries = UH.Config.DB().watchlist
  local height = list:GetHeight()
  local count = math.floor(height / 18)
  if count < 1 then
    count = 1
  end
  if count > 20 then
    count = 20
  end
  UH.UI.watchVisible = count
  for i = #UH.UI.watchRows + 1, count do
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(18)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.label:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row:SetScript("OnClick", function(self)
      UH.UI.watchIndex = self.itemID
      UH.UI.RefreshWatchlist()
    end)
    UH.UI.watchRows[i] = row
  end
  local maxScroll = math.max(0, #entries - count)
  local bar = UH.UI.watchBar
  local offset = 0
  if bar then
    UH.UI.scrollLock = true
    bar:SetMinMaxValues(0, maxScroll)
    if bar:GetValue() > maxScroll then
      bar:SetValue(maxScroll)
    end
    offset = math.floor((bar:GetValue() or 0) + 0.5)
    UH.UI.scrollLock = false
  end
  for i = 1, #UH.UI.watchRows do
    local row = UH.UI.watchRows[i]
    if i <= count then
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -((i - 1) * 18))
      row:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, -((i - 1) * 18))
      local entry = entries[offset + i]
      if entry then
        row.itemID = entry.itemID
        row.label:SetText(entry.name or ("Item " .. tostring(entry.itemID)))
        if UH.UI.watchIndex == entry.itemID then
          Solid(row.bg, 0.25, 0.22, 0.05, 0.9)
        else
          Solid(row.bg, 0.08, 0.08, 0.08, 0.4)
        end
        row:Show()
      else
        row.itemID = nil
        row:Hide()
      end
    else
      row:Hide()
    end
  end
end

function UH.UI.HideMenu()
  if UH.UI.menu then
    UH.UI.menu:Hide()
  end
  if UH.UI.menuCatcher then
    UH.UI.menuCatcher:Hide()
  end
end

function UH.UI.EnsureMenu()
  if UH.UI.menu then
    return
  end
  local ok, menu = pcall(CreateFrame, "Frame", "UndercutHunterMenu", UIParent, "BackdropTemplate")
  if not ok or not menu then
    menu = CreateFrame("Frame", "UndercutHunterMenu", UIParent)
  end
  menu:SetFrameStrata("DIALOG")
  menu:SetSize(188, 84)
  menu:Hide()
  if menu.SetBackdrop then
    pcall(menu.SetBackdrop, menu, {
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
  else
    local bg = menu:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    Solid(bg, 0.05, 0.05, 0.05, 0.95)
  end
  local catcher = CreateFrame("Button", nil, UIParent)
  catcher:SetAllPoints(UIParent)
  catcher:SetFrameStrata("DIALOG")
  catcher:SetFrameLevel(10)
  catcher:Hide()
  catcher:SetScript("OnClick", function()
    UH.UI.HideMenu()
  end)
  menu:SetFrameLevel(30)
  UH.UI.menu = menu
  UH.UI.menuCatcher = catcher
  UH.UI.menuButtons = {}
  for i = 1, 3 do
    local button = MakeButton(menu, "", 170, 20)
    button:SetPoint("TOP", menu, "TOP", 0, -8 - ((i - 1) * 24))
    button:SetFrameLevel(40)
    UH.UI.menuButtons[i] = button
  end
end

function UH.UI.ShowMenu(data)
  UH.UI.EnsureMenu()
  local buttons = UH.UI.menuButtons
  local actions = {
    {
      text = UH.L.MENU_SEARCH,
      fn = function()
        UH.Prices.MultiSearch(data.name)
      end,
    },
    {
      text = UH.L.MENU_WATCH,
      fn = function()
        UH.Watchlist.Add(data.itemID, data.name)
      end,
    },
    {
      text = UH.L.MENU_IGNORE,
      fn = function()
        UH.Watchlist.Ignore(data.itemID, data.name)
      end,
    },
  }
  for i = 1, 3 do
    local button = buttons[i]
    button:SetText(actions[i].text)
    button:SetScript("OnClick", function()
      actions[i].fn()
      UH.UI.HideMenu()
    end)
  end
  local x, y = GetCursorPosition()
  local scale = UIParent:GetEffectiveScale()
  UH.UI.menu:ClearAllPoints()
  UH.UI.menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
  UH.UI.menuCatcher:Show()
  UH.UI.menu:Show()
end

function UH.UI.ToggleChoice(anchor, choices)
  UH.UI.EnsureMenu()
  local buttons = UH.UI.menuButtons
  for i = 1, 3 do
    local choice = choices[i]
    local button = buttons[i]
    if choice then
      button:Show()
      button:SetText(choice.text)
      button:SetScript("OnClick", function()
        choice.fn()
        UH.UI.HideMenu()
      end)
    else
      button:Hide()
    end
  end
  UH.UI.menu:SetHeight(16 + (#choices * 24))
  UH.UI.menu:ClearAllPoints()
  UH.UI.menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
  UH.UI.menuCatcher:Show()
  UH.UI.menu:Show()
end

local function CommitNumber(box, key, minValue, maxValue, integer)
  if UH.UI.syncing then
    return
  end
  local value = tonumber(box:GetText())
  if not value then
    box:SetText(tostring(UH.db[key] or minValue))
    return
  end
  if integer then
    value = math.floor(value + 0.5)
  end
  if value < minValue then
    value = minValue
  end
  if maxValue and value > maxValue then
    value = maxValue
  end
  UH.Config.DB()
  UH.db[key] = value
  box:SetText(tostring(value))
  if key == "thresholdPercent" and UH.UI.slider then
    UH.UI.syncing = true
    UH.UI.slider:SetValue(value)
    UH.UI.syncing = false
  end
  UH.Results:Reprice()
  UH.UI.Refresh()
end

function UH.UI.CreatePanel(parent, classic)
  if UH.UI.panel then
    return UH.UI.panel
  end
  local panel = CreateFrame("Frame", "UndercutHunterPanel", parent)
  panel:SetPoint("TOPLEFT", parent, "TOPLEFT", classic and 18 or 8, classic and -72 or -30)
  panel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 34)
  panel:SetFrameLevel((parent:GetFrameLevel() or 1) + 20)
  panel:Hide()
  panel:SetScript("OnHide", function()
    UH.UI.HideMenu()
  end)
  UH.UI.panel = panel

  local L = UH.L
  local scan = MakeButton(panel, L.SCAN, 64, 22)
  scan:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
  scan:SetScript("OnClick", function()
    UH.Scanner:Start()
  end)
  local stop = MakeButton(panel, L.STOP, 64, 22)
  stop:SetPoint("LEFT", scan, "RIGHT", 4, 0)
  stop:SetScript("OnClick", function()
    UH.Scanner:Stop(false)
  end)
  local buyout = MakeButton(panel, L.BUYOUT, 110, 22)
  buyout:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
  buyout:SetScript("OnClick", function()
    local row = UH.Results:Selected()
    if UH.Buyout.armed then
      if not row or UH.RowKey(row) == UH.RowKey(UH.Buyout.armed) then
        row = UH.Buyout.armed
      else
        UH.Buyout.armed = nil
        UH.Buyout.fresh = nil
        UH.UI.SetBuyoutLabel(UH.L.BUYOUT)
      end
    end
    UH.Buyout:Request(row)
  end)
  local status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("LEFT", stop, "RIGHT", 8, 0)
  status:SetPoint("RIGHT", buyout, "LEFT", -8, 0)
  status:SetJustifyH("LEFT")
  status:SetWordWrap(false)
  status:SetText(L.IDLE)

  local thresholdLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  thresholdLabel:SetPoint("TOPLEFT", scan, "BOTTOMLEFT", 0, -10)
  thresholdLabel:SetText(L.AT_OR_BELOW)
  local slider = MakeSlider(panel)
  slider:SetPoint("LEFT", thresholdLabel, "RIGHT", 8, 0)
  slider:SetScript("OnValueChanged", function(self, value)
    if UH.UI.syncing then
      return
    end
    value = math.floor((value or 50) + 0.5)
    UH.Config.DB()
    UH.db.thresholdPercent = value
    if UH.UI.thresholdBox then
      UH.UI.thresholdBox:SetText(tostring(value))
    end
    UH.Results:Reprice()
    UH.UI.Refresh()
  end)
  local thresholdBox = MakeEdit(panel, 36)
  thresholdBox:SetMaxLetters(3)
  thresholdBox:SetPoint("LEFT", slider, "RIGHT", 6, 0)
  thresholdBox:SetScript("OnEnterPressed", function(self)
    CommitNumber(self, "thresholdPercent", 1, 100, true)
    self:ClearFocus()
  end)
  thresholdBox:SetScript("OnEditFocusLost", function(self)
    CommitNumber(self, "thresholdPercent", 1, 100, true)
  end)
  local ofMarket = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  ofMarket:SetPoint("LEFT", thresholdBox, "RIGHT", 4, 0)
  ofMarket:SetText(L.OF_MARKET)

  local minGoldLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  minGoldLabel:SetPoint("TOPLEFT", thresholdLabel, "BOTTOMLEFT", 0, -12)
  minGoldLabel:SetText(L.MIN_GOLD)
  local minGoldBox = MakeEdit(panel, 48)
  minGoldBox:SetPoint("LEFT", minGoldLabel, "RIGHT", 6, 0)
  minGoldBox:SetScript("OnEnterPressed", function(self)
    CommitNumber(self, "minDiscountGold", 0, 1000000, false)
    self:ClearFocus()
  end)
  minGoldBox:SetScript("OnEditFocusLost", function(self)
    CommitNumber(self, "minDiscountGold", 0, 1000000, false)
  end)
  local minQtyLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  minQtyLabel:SetPoint("LEFT", minGoldBox, "RIGHT", 10, 0)
  minQtyLabel:SetText(L.MIN_QTY)
  local minQtyBox = MakeEdit(panel, 36)
  minQtyBox:SetPoint("LEFT", minQtyLabel, "RIGHT", 4, 0)
  minQtyBox:SetScript("OnEnterPressed", function(self)
    CommitNumber(self, "minQuantity", 1, 10000, true)
    self:ClearFocus()
  end)
  minQtyBox:SetScript("OnEditFocusLost", function(self)
    CommitNumber(self, "minQuantity", 1, 10000, true)
  end)
  local capLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  capLabel:SetPoint("LEFT", minQtyBox, "RIGHT", 10, 0)
  capLabel:SetText(L.CAP)
  local capBox = MakeEdit(panel, 48)
  capBox:SetPoint("LEFT", capLabel, "RIGHT", 4, 0)
  capBox:SetScript("OnEnterPressed", function(self)
    CommitNumber(self, "candidateCap", 1, 5000, true)
    self:ClearFocus()
  end)
  capBox:SetScript("OnEditFocusLost", function(self)
    CommitNumber(self, "candidateCap", 1, 5000, true)
  end)

  local checks = {}
  local checkKeys = {
    { "includePoor", L.CHECK_POOR },
    { "useVendorFallback", L.CHECK_VENDOR },
    { "showOwner", L.CHECK_OWNER },
    { "includeBids", L.CHECK_BIDS },
    { "confirmBuyout", L.CHECK_CONFIRM },
    { "doubleClickBuyout", L.CHECK_DOUBLE },
    { "autoScanOnTabOpen", L.CHECK_AUTOSCAN },
  }
  local previous = nil
  for i = 1, #checkKeys do
    local wrap, box = Checkbox(panel, checkKeys[i][2], checkKeys[i][1])
    checks[checkKeys[i][1]] = box
    if i == 1 then
      wrap:SetPoint("TOPLEFT", minGoldLabel, "BOTTOMLEFT", -2, -6)
    elseif i == 5 then
      wrap:SetPoint("TOPLEFT", checks.includePoor, "BOTTOMLEFT", -2, -2)
      wrap:SetParent(panel)
      -- The wrap's parent is panel; anchor to the first checkbox's wrap.
    else
      wrap:SetPoint("LEFT", previous, "RIGHT", 8, 0)
    end
    previous = wrap
    if i == 4 then
      previous = nil
    end
  end
  -- Re-anchor the second row cleanly. The loop above leaves row 2's first
  -- box pointed at the check widget rather than its wrap. Fix that now.
  local row1 = checks.includePoor:GetParent()
  local row2 = checks.confirmBuyout:GetParent()
  row2:ClearAllPoints()
  row2:SetPoint("TOPLEFT", row1, "BOTTOMLEFT", 0, -2)
  checks.doubleClickBuyout:GetParent():ClearAllPoints()
  checks.doubleClickBuyout:GetParent():SetPoint("LEFT", row2, "RIGHT", 8, 0)
  checks.autoScanOnTabOpen:GetParent():ClearAllPoints()
  checks.autoScanOnTabOpen:GetParent():SetPoint("LEFT", checks.doubleClickBuyout:GetParent(), "RIGHT", 8, 0)

  local source = MakeButton(panel, L.SOURCE_WATCHLIST, 150, 20)
  source:SetPoint("TOPLEFT", row2, "BOTTOMLEFT", 2, -6)
  source:SetScript("OnClick", function(self)
    UH.UI.ToggleChoice(self, {
      {
        text = L.SOURCE_WATCHLIST,
        fn = function()
          UH.db.scanSource = "watchlist"
          self:SetText(L.SOURCE_WATCHLIST)
        end,
      },
      {
        text = L.SOURCE_PASTED,
        fn = function()
          UH.db.scanSource = "pricedCandidates"
          self:SetText(L.SOURCE_PASTED)
        end,
      },
    })
  end)
  local sort = MakeButton(panel, L.SORT_PERCENT_GOLD, 160, 20)
  sort:SetPoint("LEFT", source, "RIGHT", 6, 0)
  sort:SetScript("OnClick", function(self)
    UH.UI.ToggleChoice(self, {
      {
        text = L.SORT_PERCENT_GOLD,
        fn = function()
          UH.db.sortMode = "percentThenGold"
          self:SetText(L.SORT_PERCENT_GOLD)
          UH.UI.Refresh()
        end,
      },
      {
        text = L.SORT_PERCENT,
        fn = function()
          UH.db.sortMode = "percent"
          self:SetText(L.SORT_PERCENT)
          UH.UI.Refresh()
        end,
      },
      {
        text = L.SORT_GOLD,
        fn = function()
          UH.db.sortMode = "goldSaved"
          self:SetText(L.SORT_GOLD)
          UH.UI.Refresh()
        end,
      },
    })
  end)
  local filterBox = MakeEdit(panel, 120)
  filterBox:SetPoint("LEFT", sort, "RIGHT", 8, 0)
  filterBox:SetScript("OnTextChanged", function(self)
    if UH.UI.syncing then
      return
    end
    UH.Config.DB()
    UH.db.nameFilter = self:GetText() or ""
    UH.UI.Refresh()
  end)
  local deep = MakeButton(panel, L.DEEP, 90, 20)
  deep:SetPoint("LEFT", filterBox, "RIGHT", 6, 0)
  deep:SetScript("OnClick", function()
    UH.Scanner:StartDeep()
  end)

  local watchTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  watchTitle:SetPoint("TOPLEFT", source, "BOTTOMLEFT", 0, -8)
  watchTitle:SetText(L.WATCHLIST)
  local watch = CreateFrame("Frame", nil, panel)
  watch:SetPoint("TOPLEFT", watchTitle, "BOTTOMLEFT", 0, -2)
  watch:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 48)
  watch:SetWidth(168)
  watch:EnableMouseWheel(true)
  local watchBar = MakeBar(panel)
  watchBar:SetPoint("TOPLEFT", watch, "TOPRIGHT", 0, -16)
  watchBar:SetPoint("BOTTOMLEFT", watch, "BOTTOMRIGHT", 0, 16)
  watchBar:SetScript("OnValueChanged", function()
    if UH.UI.scrollLock then
      return
    end
    UH.UI.RefreshWatchlist()
  end)
  watch:SetScript("OnMouseWheel", function(_, delta)
    watchBar:SetValue(watchBar:GetValue() - delta)
  end)

  local itemBox = MakeEdit(panel, 168)
  itemBox:SetMaxLetters(200)
  itemBox:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 24)
  itemBox:SetWidth(168)
  local add = MakeButton(panel, L.ADD, 52, 20)
  add:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
  add:SetScript("OnClick", function()
    local text = itemBox:GetText()
    if not UH.Watchlist.AddFromText(text) then
      UH.Print(L.NEED_ITEM)
    else
      itemBox:SetText("")
    end
  end)
  itemBox:SetScript("OnEnterPressed", function(self)
    if UH.Watchlist.AddFromText(self:GetText()) then
      self:SetText("")
    else
      UH.Print(L.NEED_ITEM)
    end
    self:ClearFocus()
  end)
  local addIDs = MakeButton(panel, L.ADD_IDS, 64, 20)
  addIDs:SetPoint("LEFT", add, "RIGHT", 2, 0)
  addIDs:SetScript("OnClick", function()
    local added = UH.Watchlist.AddExtraIDs(itemBox:GetText())
    if added > 0 then
      itemBox:SetText("")
    else
      UH.Print(L.NEED_ITEM)
    end
  end)

  local remove = MakeButton(panel, L.REMOVE, 64, 20)
  remove:SetPoint("TOPLEFT", watch, "TOPRIGHT", 24, 0)
  remove:SetScript("OnClick", function()
    if UH.UI.watchIndex then
      UH.Watchlist.Remove(UH.UI.watchIndex)
      UH.UI.watchIndex = nil
    end
  end)
  local ignore = MakeButton(panel, L.IGNORE, 64, 20)
  ignore:SetPoint("LEFT", remove, "RIGHT", 4, 0)
  ignore:SetScript("OnClick", function()
    if not UH.UI.watchIndex then
      return
    end
    local name = nil
    local list = UH.db.watchlist
    for i = 1, #list do
      if list[i].itemID == UH.UI.watchIndex then
        name = list[i].name
      end
    end
    UH.Watchlist.Ignore(UH.UI.watchIndex, name)
    UH.UI.watchIndex = nil
  end)

  local header = CreateFrame("Frame", nil, panel)
  header:SetPoint("TOPLEFT", remove, "BOTTOMLEFT", 0, -6)
  header:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -18, 0)
  header:SetHeight(16)
  header.labels = {}
  for i = 1, 9 do
    local fs = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetJustifyH("LEFT")
    header.labels[i] = fs
  end
  header:EnableMouse(true)
  header:SetScript("OnMouseUp", function(self, button)
    if button ~= "LeftButton" or not UH.UI.headerHits then
      return
    end
    local cursorX = GetCursorPosition()
    local scale = self:GetEffectiveScale()
    if scale and scale > 0 then
      cursorX = cursorX / scale
    end
    local localX = cursorX - (self:GetLeft() or 0)
    for i = 1, #UH.UI.headerHits do
      local hit = UH.UI.headerHits[i]
      if localX >= hit.x and localX < hit.x + hit.width then
        UH.Config.DB()
        UH.db.sortMode = hit.sort
        if UH.UI.sortButton then
          UH.UI.sortButton:SetText(UH.UI.SortLabel())
        end
        UH.UI.Refresh()
        return
      end
    end
  end)

  local list = CreateFrame("Frame", nil, panel)
  list:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
  list:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -18, 0)
  list:EnableMouseWheel(true)
  local bar = MakeBar(panel)
  bar:SetPoint("TOPLEFT", list, "TOPRIGHT", 2, -16)
  bar:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 2, 16)
  bar:SetScript("OnValueChanged", function()
    if UH.UI.scrollLock then
      return
    end
    UH.UI.Refresh()
  end)
  list:SetScript("OnMouseWheel", function(_, delta)
    bar:SetValue((bar:GetValue() or 0) - delta)
  end)
  list:SetScript("OnSizeChanged", function()
    UH.UI.Refresh()
  end)

  local overlay = list:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  overlay:SetPoint("TOPLEFT", list, "TOPLEFT", 8, -8)
  overlay:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -8, 8)
  overlay:SetJustifyH("LEFT")
  overlay:SetJustifyV("TOP")
  overlay:SetWordWrap(true)
  overlay:Hide()

  UH.UI.scanButton = scan
  UH.UI.stopButton = stop
  UH.UI.buyoutButton = buyout
  UH.UI.statusFS = status
  UH.UI.slider = slider
  UH.UI.thresholdBox = thresholdBox
  UH.UI.minGoldBox = minGoldBox
  UH.UI.minQtyBox = minQtyBox
  UH.UI.capBox = capBox
  UH.UI.filterBox = filterBox
  UH.UI.checks = checks
  UH.UI.sortButton = sort
  UH.UI.sourceButton = source
  UH.UI.deepButton = deep
  UH.UI.watchList = watch
  UH.UI.watchBar = watchBar
  UH.UI.header = header
  UH.UI.list = list
  UH.UI.scrollBar = bar
  UH.UI.overlay = overlay
  UH.UI.itemBox = itemBox

  if UH.lastStatus then
    status:SetText(UH.lastStatus)
  end
  UH.UI.SyncFromDB()

  panel:SetScript("OnShow", function()
    UH.UI.SyncFromDB()
    UH.UI.Refresh()
    if not UH.supportedAH then
      UH.UI.SetStatus(UH.L.NO_API)
      return
    end
    if not UH.Prices.IsReady() then
      UH.UI.SetStatus(UH.L.STATUS_MISSING)
      return
    end
    if not UH.lastStatus or UH.lastStatus == "" then
      UH.UI.SetStatus(UH.L.IDLE)
    end
    if UH.db.autoScanOnTabOpen and not UH.didAutoScan and not (UH.Scanner and UH.Scanner.running) then
      UH.didAutoScan = true
      UH.Scanner:Start()
    end
  end)
  return panel
end

local function HookBlizzardTabs(ah)
  local tabs = ah.Tabs
  if type(tabs) ~= "table" then
    return
  end
  for i = 1, #tabs do
    local tab = tabs[i]
    -- The display-mode tab template inserts our button into AuctionHouseFrame.Tabs.
    -- Hooking that button would hide the Bargains panel in the same click that shows it.
    if tab and tab ~= UH.UI.tabButton and not tab.undercutHunterHooked and tab.HookScript then
      tab.undercutHunterHooked = true
      tab:HookScript("OnClick", function()
        if UH.UI.panel and UH.attached ~= "lib" then
          UH.UI.panel:Hide()
        end
      end)
    end
  end
end

-- Fallback when LibAHTab-1-0 is missing or CreateTab fails.
-- Forever 1.60.1 normally exposes AuctionHouseFrame. This path adds a tab
-- button beside the existing tabs and does not call PanelTemplates_SetNumTabs,
-- which is the call that taints bags. Bargains hides Blizzard display frames
-- with SetDisplayMode({}) when that call succeeds, then shows our panel.
-- Clicking a Blizzard tab hides the panel again.
local function ShowModernPanel(ah)
  if ah.SetDisplayMode then
    pcall(ah.SetDisplayMode, ah, {})
  end
  local names = {
    "CategoriesList", "ItemBuyFrame", "CommoditiesBuyFrame", "ItemSellFrame",
    "ItemSellList", "CommoditiesSellFrame", "CommoditiesSellList",
    "AuctionsFrame", "WoWTokenFrame",
  }
  for i = 1, #names do
    local frame = ah[names[i]]
    if frame and frame.Hide then
      frame:Hide()
    end
  end
  if UH.UI.panel then
    UH.UI.panel:Show()
  end
end

function UH.UI.AttachModernFallback(ah)
  if UH.attached then
    return
  end
  UH.UI.CreatePanel(ah, false)
  -- The display-mode template inserts the new button into ah.Tabs during
  -- creation. A second attempt in the same open inserts it again, so the
  -- last tab is this button and SetPoint anchors it to itself.
  local button = _G.UndercutHunterTabButton
  if not button then
    pcall(CreateFrame, "Button", "UndercutHunterTabButton", ah, "AuctionHouseFrameDisplayModeTabTemplate")
    button = _G.UndercutHunterTabButton
  end
  if not button then
    button = MakeButton(ah, UH.L.TAB, 90, 22)
  end
  button:SetText(UH.L.TAB)
  if type(PanelTemplates_TabResize) == "function" then
    pcall(PanelTemplates_TabResize, button, 20, nil, 70)
  end
  UH.UI.tabButton = button
  local last = nil
  local tabs = ah.Tabs
  if type(tabs) == "table" then
    for i = #tabs, 1, -1 do
      if tabs[i] == button then
        table.remove(tabs, i)
      end
    end
    last = tabs[#tabs]
  end
  button:ClearAllPoints()
  local placed = false
  if last and last ~= button then
    placed = pcall(function()
      button:SetPoint("TOPLEFT", last, "TOPRIGHT", 4, 0)
    end)
  end
  if not placed then
    button:SetPoint("BOTTOMLEFT", ah, "BOTTOMLEFT", 60, 2)
  end
  button:SetScript("OnClick", function()
    ShowModernPanel(ah)
  end)
  HookBlizzardTabs(ah)
  if type(hooksecurefunc) == "function" and ah.SetDisplayMode and not UH.UI.hookedDisplay then
    UH.UI.hookedDisplay = true
    hooksecurefunc(ah, "SetDisplayMode", function(_, mode)
      if type(mode) == "string" and mode ~= "" and UH.UI.panel then
        UH.UI.panel:Hide()
      end
    end)
  end
  UH.attached = "fallback"
  UH.Debug("attached with AH tab fallback")
end

-- Classic AuctionFrame fallback, used only if AuctionHouseFrame does not exist.
-- The button sits beside the stock tabs. It does not call PanelTemplates_SetNumTabs.
-- Showing Bargains hides the Browse / Bid / Auctions pages. Their tab clicks hide us.
function UH.UI.AttachClassicFallback(ah)
  if UH.attached then
    return
  end
  UH.UI.CreatePanel(ah, true)
  local button = MakeButton(ah, UH.L.TAB, 90, 22)
  local anchor = AuctionFrameTab3 or AuctionFrameTab2 or AuctionFrameTab1 or ah
  button:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
  button:SetScript("OnClick", function()
    if AuctionFrameBrowse then
      AuctionFrameBrowse:Hide()
    end
    if AuctionFrameBid then
      AuctionFrameBid:Hide()
    end
    if AuctionFrameAuctions then
      AuctionFrameAuctions:Hide()
    end
    if UH.UI.panel then
      UH.UI.panel:Show()
    end
  end)
  if type(hooksecurefunc) == "function" and type(AuctionFrameTab_OnClick) == "function" and not UH.UI.hookedClassic then
    UH.UI.hookedClassic = true
    hooksecurefunc("AuctionFrameTab_OnClick", function()
      if UH.UI.panel then
        UH.UI.panel:Hide()
      end
    end)
  end
  UH.UI.tabButton = button
  UH.attached = "classic"
  UH.Debug("attached to AuctionFrame")
end

function UH.UI.TryAttach()
  if UH.attached then
    return
  end
  local modern = AuctionHouseFrame
  if modern then
    local lib = nil
    if type(LibStub) == "function" then
      local ok, result = pcall(LibStub, "LibAHTab-1-0")
      if ok and type(result) == "table" and type(result.CreateTab) == "function" then
        if not result.DoesIDExist or not result:DoesIDExist("UndercutHunterBargains") then
          lib = result
        else
          UH.attached = "lib"
          return
        end
      end
    end
    if lib then
      local panel = UH.UI.CreatePanel(modern, false)
      local ok, err = pcall(function()
        lib:CreateTab("UndercutHunterBargains", panel, UH.L.TAB, UH.L.TAB)
      end)
      if ok then
        UH.attached = "lib"
        UH.Debug("attached via LibAHTab")
        return
      end
      UH.Debug("LibAHTab CreateTab failed", err)
    end
    UH.UI.AttachModernFallback(modern)
    return
  end
  if AuctionFrame then
    UH.UI.AttachClassicFallback(AuctionFrame)
  end
end

local function WatchFrames()
  if AuctionHouseFrame and not AuctionHouseFrame.undercutHunterShowHook and AuctionHouseFrame.HookScript then
    AuctionHouseFrame.undercutHunterShowHook = true
    AuctionHouseFrame:HookScript("OnShow", function()
      UH.UI.TryAttach()
    end)
  end
  if AuctionFrame and not AuctionFrame.undercutHunterShowHook and AuctionFrame.HookScript then
    AuctionFrame.undercutHunterShowHook = true
    AuctionFrame:HookScript("OnShow", function()
      UH.UI.TryAttach()
    end)
  end
end

UH.On("ADDON_LOADED", function()
  WatchFrames()
end)
UH.On("AUCTION_HOUSE_SHOW", function()
  WatchFrames()
  UH.After(0, function()
    UH.UI.TryAttach()
  end)
end)
