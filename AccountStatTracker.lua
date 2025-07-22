-- Create a frame to handle game events
local eventFrame = CreateFrame("Frame", "AST_EventFrame")
local addonName, addon = ... -- Standard addon setup
AccountStatTracker = addon -- Make the addon table global for XML access

-- Local variables to track player state
local lastMoney = 0
local isTrading = false
local isAccessingMail = false
local lastTimePlayedUpdate = 0
local selectedGraveIndex = nil
local onConfirmAction = nil

-- Default structure for the saved variables database
local defaults = {
    profile = {
        totalXP = 0, totalDeaths = 0, totalMoneyGained = 0, totalQuests = 0,
        characters = {}, graveyard = {},
    },
    minimap = {}
}

-- A separate table for session data (not saved)
local session = {}

---------------------------------
-- HELPER FUNCTIONS
---------------------------------

local function TitleCase(str)
    if not str or str == "" then return "" end
    return str:sub(1,1):upper() .. str:sub(2):lower()
end

local function FormatTime(totalSeconds)
    if not totalSeconds or totalSeconds < 60 then return "0m" end
    local days = math.floor(totalSeconds / 86400)
    local hours = math.floor((totalSeconds % 86400) / 3600)
    local minutes = math.floor((totalSeconds % 3600) / 60)
    if days > 0 then
        return string.format("%dd %dh", days, hours)
    elseif hours > 0 then
        return string.format("%dh %dm", hours, minutes)
    else
        return string.format("%dm", minutes)
    end
end

local function FormatMoney(money)
    if not money or money == 0 then return "0|TInterface\\MoneyFrame\\UI-CopperIcon:0|t" end
    local g = math.floor(money / 10000)
    local s = math.floor((money % 10000) / 100)
    local c = money % 100
    return string.format("%d|TInterface\\MoneyFrame\\UI-GoldIcon:0|t  %d|TInterface\\MoneyFrame\\UI-SilverIcon:0|t  %d|TInterface\\MoneyFrame\\UI-CopperIcon:0|t", g, s, c)
end

---------------------------------
-- DATA MANAGEMENT
---------------------------------

local function GetCharacterDB()
    local playerName = UnitName("player")
    if AST_DB and AST_DB.profile and AST_DB.profile.characters then
        return AST_DB.profile.characters[playerName]
    end
    return nil
end

local function EnsureCharacterData()
    local playerName = UnitName("player")
    if not AST_DB.profile.characters[playerName] then
        local playerLevel = UnitLevel("player")
        local _, classToken = UnitClass("player")
        local _, raceName = UnitRace("player")
        AST_DB.profile.characters[playerName] = {
            class = classToken, race = raceName, classColor = RAID_CLASS_COLORS[classToken],
            level = playerLevel, xpGained = 0, deaths = 0, quests = 0, moneyGained = 0,
            lastXP = UnitXP("player"), killedBy = "Unknown", totalTimePlayed = 0, timeThisLevel = 0,
            snapshotted = false,
        }
    end
end

function addon:InitializeDB()
    AST_DB = AST_DB or {}
    if AST_DB.totalXP ~= nil or AST_DB.characters ~= nil or AST_DB.graveyard ~= nil then
        print(addonName .. ": Migrating old data to new profile structure.")
        local profile = {
            totalXP = AST_DB.totalXP or 0, totalDeaths = AST_DB.totalDeaths or 0,
            totalMoneyGained = AST_DB.totalMoneyGained or 0, totalQuests = AST_DB.totalQuests or 0,
            characters = AST_DB.characters or {}, graveyard = AST_DB.graveyard or {},
        }
        AST_DB = { profile = profile, minimap = AST_DB.minimap or {} }
    end
    if AST_DB.profile == nil then AST_DB.profile = {} end
    for key, defaultValue in pairs(defaults.profile) do
        if AST_DB.profile[key] == nil then
            AST_DB.profile[key] = type(defaultValue) == "table" and {} or defaultValue
        end
    end
    if AST_DB.minimap == nil then AST_DB.minimap = {} end
end

---------------------------------
-- UI & SETTINGS
---------------------------------

function addon:ShowConfirmation(text, onConfirm)
    AST_ConfirmationFrameText:SetText(text)
    onConfirmAction = onConfirm
    AST_ConfirmationFrame:Show()
end

function addon:ConfirmAction()
    if onConfirmAction then onConfirmAction() end
    onConfirmAction = nil
    AST_ConfirmationFrame:Hide()
end

function addon:ResetSession()
    session = {
        startTime = GetTime(),
        xp = 0,
        quests = 0,
        money = 0,
    }
    print(addonName .. ": Session data has been reset.")
    addon:RefreshVisiblePanels()
end

function addon:ResetCharacter()
    local playerName = UnitName("player")
    print("Resetting data for " .. playerName)
    AST_DB.profile.characters[playerName] = nil
    EnsureCharacterData()
    addon:RefreshVisiblePanels()
end

function addon:ResetGraveyard()
    print("Clearing the Graveyard.")
    AST_DB.profile.graveyard = {}
    addon:RefreshVisiblePanels()
end

function addon:ResetAll()
    print("WARNING: Resetting all addon data.")
    AST_DB.profile = defaults.profile
    EnsureCharacterData()
    addon:RefreshVisiblePanels()
end

function addon:ToggleMainWindow()
    if AST_MainFrame:IsShown() then
        AST_MainFrame:Hide()
    else
        addon:SelectTab(1)
        AST_MainFrame:Show()
    end
end

function addon:SelectTab(tabId)
    for i = 1, 5 do
        _G["AST_Tab"..i]:SetChecked(i == tabId)
        _G["AST_Panel"..i]:SetShown(i == tabId)
    end
    local panelUpdaters = {
        [1] = addon.UpdateAccountPanel,
        [2] = addon.UpdateCharacterPanel,
        [3] = addon.UpdateGraveyardPanel,
        [4] = addon.UpdateSessionPanel,
    }
    if tabId == 3 then selectedGraveIndex = nil end
    if panelUpdaters[tabId] then
        panelUpdaters[tabId](addon)
    end
end

function addon:RefreshVisiblePanels()
    if not AST_MainFrame or not AST_MainFrame:IsShown() then return end
    for i = 1, 5 do
        if _G["AST_Panel"..i]:IsShown() then
            addon:SelectTab(i)
            return
        end
    end
end

---------------------------------
-- PANEL UPDATE FUNCTIONS
---------------------------------

function addon:UpdateAccountPanel()
    local db = AST_DB.profile
    AST_TotalXPValue:SetText(db.totalXP or 0)
    AST_TotalDeathsValue:SetText(db.totalDeaths or 0)
    AST_TotalQuestsValue:SetText(db.totalQuests or 0)
    AST_TotalMoneyValue:SetText(FormatMoney(db.totalMoneyGained or 0))
end

function addon:UpdateCharacterPanel()
    local charDB = GetCharacterDB()
    local playerName = UnitName("player"):match("([^%-]+)")
    AST_CurrentCharTitle:SetText(playerName)
    if not charDB then
        AST_Char_RaceClass:SetText("N/A"); AST_Char_Level:SetText("N/A"); AST_Char_XP:SetText("N/A");
        AST_Char_Quests:SetText("N/A"); AST_Char_Location:SetText("N/A"); AST_Char_Status:SetText("N/A");
        AST_Char_KilledByLabel:Hide(); AST_Char_KilledBy:Hide(); AST_Char_Money:SetText(FormatMoney(0));
        AST_Char_TimePlayed:SetText("N/A"); AST_Char_TimeThisLevel:SetText("N/A")
        return
    end
    charDB.level = UnitLevel("player")
    local c = charDB.classColor or {r=1,g=1,b=1}
    AST_CurrentCharTitle:SetTextColor(c.r, c.g, c.b)
    AST_Char_RaceClass:SetText(string.format("%s %s", charDB.race or "N/A", TitleCase(charDB.class or "")))
    AST_Char_Level:SetText(charDB.level or 0)
    AST_Char_XP:SetText(charDB.xpGained or 0)
    AST_Char_Quests:SetText(charDB.quests or 0)
    AST_Char_Location:SetText(GetZoneText())
    if UnitIsDeadOrGhost("player") then
        AST_Char_Status:SetText("|cffff0000DEAD|r"); AST_Char_KilledByLabel:Show(); AST_Char_KilledBy:Show()
        AST_Char_KilledBy:SetText(charDB.killedBy or "Unknown")
    else
        AST_Char_Status:SetText("|cff00ff00Alive|r"); AST_Char_KilledByLabel:Hide(); AST_Char_KilledBy:Hide()
    end
    AST_Char_Money:SetText(FormatMoney(charDB.moneyGained or 0))
    if (GetTime() - lastTimePlayedUpdate) > 120 then
        RequestTimePlayed(); lastTimePlayedUpdate = GetTime()
    end
    AST_Char_TimePlayed:SetText(FormatTime(charDB.totalTimePlayed or 0))
    AST_Char_TimeThisLevel:SetText(FormatTime(charDB.timeThisLevel or 0))
end

local function GraveyardButton_OnClick(self)
    selectedGraveIndex = self:GetID()
    addon:UpdateGraveyardPanel()
end

function addon:UpdateGraveyardPanel()
    local graveyard = AST_DB.profile.graveyard
    FauxScrollFrame_Update(AST_GraveyardListScrollFrame, #graveyard, 10, 16)
    for i=1, 10 do
        local button = _G["AST_GraveyardListScrollFrameButton"..i]
        local index = i + FauxScrollFrame_GetOffset(AST_GraveyardListScrollFrame)
        if index <= #graveyard then
            local snapshot = graveyard[index]; local classColor = RAID_CLASS_COLORS[snapshot.class] or {r=1,g=1,b=1}
            button:SetText(string.format("Lvl %d %s", snapshot.level, snapshot.name:match("([^%-]+)")))
            _G[button:GetName().."Text"]:SetTextColor(classColor.r, classColor.g, classColor.b)
            button:SetID(index); button:SetScript("OnClick", GraveyardButton_OnClick)
            if selectedGraveIndex == index then button:LockHighlight() else button:UnlockHighlight() end
            button:Show()
        else
            button:Hide()
        end
    end
    addon:UpdateGraveyardDetailPanel()
end

function addon:UpdateGraveyardDetailPanel()
    if not selectedGraveIndex or not AST_DB.profile.graveyard[selectedGraveIndex] then
        AST_GraveyardDetailFrame:Hide()
        return
    end
    local snapshot = AST_DB.profile.graveyard[selectedGraveIndex]
    local classColor = RAID_CLASS_COLORS[snapshot.class] or {r=1,g=1,b=1}
    AST_Grave_Name:SetText(snapshot.name:match("([^%-]+)")); AST_Grave_Name:SetTextColor(classColor.r, classColor.g, classColor.b)
    AST_Grave_Details:SetText(string.format("Level %d %s %s", snapshot.level, snapshot.race, TitleCase(snapshot.class)))
    AST_Grave_KilledBy:SetText(snapshot.killedBy); AST_Grave_Location:SetText(snapshot.location)
    AST_Grave_TimePlayed:SetText(FormatTime(snapshot.timePlayed)); AST_Grave_XP:SetText(snapshot.xpGained)
    AST_Grave_Quests:SetText(snapshot.quests); AST_Grave_Money:SetText(FormatMoney(snapshot.moneyGained))
    AST_GraveyardDetailFrame:Show()
end

function addon:UpdateSessionPanel()
    local timeElapsed = GetTime() - (session.startTime or GetTime())
    AST_SessionXPValue:SetText(session.xp or 0)
    AST_SessionQuestsValue:SetText(session.quests or 0)
    local xpPerHour = (timeElapsed > 0) and math.floor(((session.xp or 0) / timeElapsed) * 3600) or 0
    AST_SessionXPHourValue:SetText(xpPerHour)
    AST_SessionMoneyValue:SetText(FormatMoney(session.money or 0))
    AST_SessionTimePlayedValue:SetText(FormatTime(timeElapsed))
end

---------------------------------
-- EVENT HANDLERS
---------------------------------
local eventHandlers = {}
local function OnEvent(self, event, ...)
    if eventHandlers[event] then
        local needsRefresh = eventHandlers[event](self, ...)
        if needsRefresh then
            addon:RefreshVisiblePanels()
        end
    end
end

function eventHandlers:PLAYER_LOGIN()
    local charDB = GetCharacterDB(); if charDB and charDB.snapshotted then AST_DB.profile.characters[UnitName("player")] = nil end
    EnsureCharacterData(); lastMoney = GetMoney(); addon:ResetSession(); return true
end

function eventHandlers:PLAYER_XP_UPDATE()
    local charDB = GetCharacterDB(); if not charDB or charDB.snapshotted then return end
    local currentXP = UnitXP("player"); local xpGained = currentXP - (charDB.lastXP or currentXP)
    if xpGained > 0 then
        AST_DB.profile.totalXP = (AST_DB.profile.totalXP or 0) + xpGained
        charDB.xpGained = (charDB.xpGained or 0) + xpGained
        session.xp = (session.xp or 0) + xpGained
    end
    charDB.lastXP = currentXP; return true
end

function eventHandlers:PLAYER_LEVEL_UP(self, level)
    local charDB = GetCharacterDB(); if not charDB or charDB.snapshotted then return end
    local previousLevelMaxXP = GetXPForLevel(level - 1); local currentXP = UnitXP("player")
    local xpFromLevelUp = (previousLevelMaxXP - (charDB.lastXP or 0)) + currentXP
    if xpFromLevelUp > 0 then
        AST_DB.profile.totalXP = (AST_DB.profile.totalXP or 0) + xpFromLevelUp
        charDB.xpGained = (charDB.xpGained or 0) + xpFromLevelUp
        session.xp = (session.xp or 0) + xpFromLevelUp
    end
    charDB.lastXP = currentXP; charDB.timeThisLevel = 0; return true
end

function eventHandlers:QUEST_TURNED_IN()
    local charDB = GetCharacterDB(); if not charDB or charDB.snapshotted then return end
    AST_DB.profile.totalQuests = (AST_DB.profile.totalQuests or 0) + 1
    charDB.quests = (charDB.quests or 0) + 1
    session.quests = (session.quests or 0) + 1; return true
end

function eventHandlers:PLAYER_MONEY()
    local charDB = GetCharacterDB(); if not charDB or charDB.snapshotted or isTrading or isAccessingMail then return end
    local currentMoney = GetMoney()
    if currentMoney > lastMoney then
        local diff = currentMoney - lastMoney
        AST_DB.profile.totalMoneyGained = (AST_DB.profile.totalMoneyGained or 0) + diff
        charDB.moneyGained = (charDB.moneyGained or 0) + diff
        session.money = (session.money or 0) + diff
    end
    lastMoney = currentMoney; return true
end

function eventHandlers:PLAYER_DEAD()
    local charDB = GetCharacterDB(); if not charDB or charDB.snapshotted then return end
    print("|cffff0000["..addonName.."]|r A hero has fallen! Snapshotting final stats.")
    AST_DB.profile.totalDeaths = (AST_DB.profile.totalDeaths or 0) + 1; charDB.snapshotted = true
    local snapshot = {
        name = UnitName("player"), level = charDB.level, race = charDB.race, class = charDB.class,
        xpGained = charDB.xpGained, quests = charDB.quests, moneyGained = charDB.moneyGained,
        killedBy = charDB.killedBy or "Unknown", location = GetZoneText(), timePlayed = charDB.totalTimePlayed or 0,
        deathDate = date("%Y-%m-%d"),
    }
    table.insert(AST_DB.profile.graveyard, snapshot); return true
end

function eventHandlers:TIME_PLAYED_MSG(self, totalTime, timeThisLevel)
    local charDB = GetCharacterDB()
    if charDB then charDB.totalTimePlayed = totalTime; charDB.timeThisLevel = timeThisLevel end
    return true
end

function eventHandlers:COMBAT_LOG_EVENT_UNFILTERED(self, ...)
    local charDB = GetCharacterDB(); if not charDB or charDB.snapshotted then return end
    local _, subEvent, _, _, sourceName, _, _, destGUID, _, _, _, _, spellName = CombatLogGetCurrentEventInfo(...)
    if destGUID == UnitGUID("player") and string.find(subEvent, "_DAMAGE") then
        if sourceName and sourceName ~= UnitName("player") then charDB.killedBy = sourceName
        elseif not sourceName then charDB.killedBy = spellName or "The Environment" end
    end
end

function eventHandlers:TRADE_SHOW() isTrading = true end
function eventHandlers:TRADE_CLOSED() isTrading = false; lastMoney = GetMoney() end
function eventHandlers:MAIL_SHOW() isAccessingMail = true end
function eventHandlers:MAIL_CLOSED() isAccessingMail = false; lastMoney = GetMoney() end

---------------------------------
-- INITIALIZATION
---------------------------------

local function InitializeMinimapButton()
    local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not LDBIcon then return end
    local LDB = LibStub("LibDataBroker-1.1")
    local ldbObject = {
        type = "data source",
        icon = "Interface\\Icons\\inv_misc_book_07",
        OnClick = function(self, button) if button == "LeftButton" then addon:ToggleMainWindow() end end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("Account Stat Tracker"); tooltip:AddLine("|cffeda55fClick|r to open.")
        end
    }
    -- CORRECTED: The function to register a data object is NewDataObject, not Register
    LDB:NewDataObject(addonName, ldbObject)
    LDBIcon:Register(addonName, ldbObject, AST_DB.minimap)
end

local function OnAddonLoaded(self, event, loadedAddon)
    if loadedAddon ~= addonName then return end
    addon:InitializeDB()
    print(addonName .. ": Loaded successfully. Type /ast to open.")
    self:UnregisterEvent("ADDON_LOADED")
    self:SetScript("OnEvent", OnEvent)
    for eventName in pairs(eventHandlers) do
        self:RegisterEvent(eventName)
    end
    InitializeMinimapButton()
    C_Timer.NewTicker(1, function()
        if AST_Panel4 and AST_Panel4:IsShown() then
            addon:UpdateSessionPanel()
        end
    end)
    SLASH_ACCOUNTSTATTRACKER1 = "/ast"
    SlashCmdList["ACCOUNTSTATTRACKER"] = function() addon:ToggleMainWindow() end
end

eventFrame:SetScript("OnEvent", OnAddonLoaded)
eventFrame:RegisterEvent("ADDON_LOADED")