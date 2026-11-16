-- ============================================================
-- Skinning\ElvUI.lua  —  ElvUI integration, fallback backdrops,
--                        and structural frame/panel skinning.
--
-- Centralises everything ElvUI-related: the theme selection
-- (Blizzard / Flat (ElvUI)), the module handles and detection,
-- the plain-backdrop fallback, the theme refresh
-- functions (accent / transparency / scale), and the panel /
-- inner / container / scroll skin helpers.
-- ============================================================
local NS = CleanBotNS

-- ============================================================
-- Themes
--
-- "blizzard" — stock WoW window art (gold dialog border, grey Interface-Options boxes,
--              Options-style tabs) on every CleanBot window, even when ElvUI is installed.
-- "flat"     — the original CleanBot look: ElvUI skinning when ElvUI is installed, otherwise
--              flat accent/transparency panels.
-- The theme is chosen at login (before CB_InitElvUI) and changing it requires a /reload,
-- because ElvUI skinning and widget templates are applied once at creation.
-- ============================================================
NS.THEMES = {
    { key = "blizzard", label = "Blizzard"     },
    { key = "flat",     label = "Flat (ElvUI)" },
}
NS.DEFAULT_THEME = "blizzard"
NS.theme         = NS.DEFAULT_THEME

--- Validates a saved theme key, falling back to the default for nil/unknown values.
---@param saved any  The stored value (CleanBot_SavedVars.theme).
---@return string    A valid theme key.
NS.CB_ResolveTheme = function(saved)
    for _, t in ipairs(NS.THEMES) do
        if t.key == saved then return saved end
    end
    return NS.DEFAULT_THEME
end

--- True when the active theme is the stock Blizzard look.
---@return boolean
NS.CB_IsBlizzardTheme = function()
    return NS.theme ~= "flat"
end

--- Display label for a theme key (e.g. "Flat (ElvUI)").
---@param key string
---@return string
NS.CB_ThemeLabel = function(key)
    for _, t in ipairs(NS.THEMES) do
        if t.key == key then return t.label end
    end
    return key
end

-- ============================================================
-- ElvUI handles (populated by NS.CB_InitElvUI at PLAYER_LOGIN)
--
-- ElvUI_E / ElvUI_S — set only when ElvUI is loaded AND the "flat" theme is active. Every
--   CleanBot-owned frame branches on these, so under the Blizzard theme they stay nil and all
--   CleanBot windows take the stock-art path.
-- ElvUI_HostE / ElvUI_HostS — set whenever ElvUI is loaded, regardless of theme. Used only by
--   pieces CleanBot attaches to Blizzard frames that ElvUI itself reskins (merchant side tabs,
--   the Dungeon Finder recruiter tab, trade-slot highlights) so they keep matching their host.
-- ============================================================
NS.ElvUI_E     = nil
NS.ElvUI_S     = nil
NS.ElvUI_HostE = nil
NS.ElvUI_HostS = nil

-- Detect ElvUI and grab its Skins module. Called once at login,
-- when ElvUI is guaranteed to be loaded. NS.theme must already be resolved.
--- Populates the host handles when ElvUI is installed, and the theme handles for "flat".
NS.CB_InitElvUI = function()
    NS.ElvUI_E, NS.ElvUI_S, NS.ElvUI_HostE, NS.ElvUI_HostS = nil, nil, nil, nil
    if IsAddOnLoaded("ElvUI") then
        local E = unpack(ElvUI)
        local S = E and E:GetModule("Skins") or nil
        NS.ElvUI_HostE, NS.ElvUI_HostS = E, S
        if NS.theme == "flat" then
            NS.ElvUI_E, NS.ElvUI_S = E, S
        end
    end
end

--- Default accent color and transparency for a theme, given the CURRENT ElvUI detection.
--- Blizzard: fully opaque stock window, accent unused (kept invisible for when Flat is chosen).
--- Flat + ElvUI: black opaque border, 75% (matches ElvUI's solid 1px border style).
--- Flat without ElvUI: no border tint, 90%.
---@param theme string  Theme key.
---@return table accentColor  { r, g, b, a }
---@return number transparency  0–100
NS.CB_ThemeDefaultValues = function(theme)
    if theme == "flat" and NS.ElvUI_HostS then
        return { r = 0.0, g = 0.0, b = 0.0, a = 1 }, 75
    elseif theme == "flat" then
        return { r = 1.0, g = 1.0, b = 1.0, a = 0 }, 90
    end
    return { r = 1.0, g = 1.0, b = 1.0, a = 0 }, 100
end

--- Carries accent/transparency across a theme switch: a value still at oldTheme's default
--- becomes newTheme's default (so switching to Flat + ElvUI gets its black opaque border instead
--- of persisting the Blizzard accent alpha 0); customised values are kept as-is.
---@param oldTheme     string  Theme key being switched from.
---@param newTheme     string  Theme key being switched to.
---@param accent       table   { r, g, b, a } currently pending.
---@param transparency number  0–100 currently pending.
---@return table  accent        { r, g, b, a } to use for newTheme (a new table).
---@return number transparency
NS.CB_CarryThemeValues = function(oldTheme, newTheme, accent, transparency)
    local oldAc, oldT = NS.CB_ThemeDefaultValues(oldTheme)
    local newAc, newT = NS.CB_ThemeDefaultValues(newTheme)
    local ac = { r = accent.r, g = accent.g, b = accent.b, a = accent.a }
    if accent.r == oldAc.r and accent.g == oldAc.g and accent.b == oldAc.b and accent.a == oldAc.a then
        ac = newAc
    end
    return ac, (transparency == oldT) and newT or transparency
end

-- ============================================================
-- Fallback backdrops (used when ElvUI is absent)
-- ============================================================

-- Thin tooltip-style border — used for inner panels and secondary windows.
NS.PLAIN_BACKDROP = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- Panel backdrop using a pure-white bgFile so that SetBackdropColor(r,g,b,a) maps
-- directly to the displayed color. UI-DialogBox-Background is dark (~20% brightness),
-- which means vertex-color multiplication makes every brightness value look near-black.
-- WHITE8X8 has full (1,1,1) pixel values so brightness = displayed color exactly.
NS.PANEL_BACKDROP = {
    bgFile   = "Interface\\BUTTONS\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- Ornate WoW dialog border — used only for the main CleanBotFrame so it
-- reads as a proper WoW window rather than a generic panel.
NS.OUTER_BACKDROP = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

-- Blizzard theme inner box — the grey tooltip-border box Blizzard's Interface Options uses for
-- its panel containers (OptionsFrameTemplates.xml: UI-Tooltip-Border, border color .6 grey).
-- Same 12px edge / 3px insets as PANEL_BACKDROP so switching theme never shifts the layout.
NS.BLIZZ_BOX_BACKDROP = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
NS.BLIZZ_BOX_BORDER = { r = 0.6, g = 0.6, b = 0.6, a = 1 }
-- Fixed (theme-independent) fills: a faint shade per nested box, darker for recessed lists, and the
-- stock tooltip background (TOOLTIP_DEFAULT_BACKGROUND_COLOR) for boxes floating on UIParent.
local BLIZZ_BOX_FILL_ALPHA  = 0.2
local BLIZZ_LIST_FILL_ALPHA = 0.5
local BLIZZ_FLOAT_FILL      = { 0.09, 0.09, 0.19 }

-- ============================================================
-- Skinning helpers
-- ============================================================

-- Registry of all top-level CleanBot windows (UIParent children).
-- Each named frame registered here receives SetScale on theme apply and is
-- added to UISpecialFrames so WoW closes it through the native Escape flow.
-- Call NS.CB_RegisterRootFrame(f) immediately after creating any
-- top-level CleanBot window.
NS.CB_rootFrames = {}
-- Registers a top-level CleanBot window and immediately applies the current
-- scale so lazily-created frames (inventory, sample layout) get the right
-- value even when they open after the scale was last changed.
--- Registers a named top-level window for scale refresh and native Escape handling.
---@param frame table  The top-level frame (UIParent child) to register.
NS.CB_RegisterRootFrame = function(frame)
    if not frame or not frame.GetName then return end
    local name = frame:GetName()
    if not name or name == "" then return end

    NS.CB_rootFrames[frame] = true
    frame:SetScale((NS.scale or 100) / 100)

    for _, registeredName in ipairs(UISpecialFrames) do
        if registeredName == name then return end
    end
    table.insert(UISpecialFrames, name)
end

-- Registry of frames skinned by CB_ApplyFrameSkin.
-- Each entry stores { skin, brightness, level } so refresh functions can
-- recompute both brightness and per-level alpha without re-calling the skin function.
-- Blizzard-theme entries are { skin, level, fixed = true, window, color }: stock border color
-- (accent is ignored), and only window frames re-apply color+alpha on transparency change.
NS.CB_skinnedFrames = {}

-- Non-ElvUI only: each nesting level multiplies the base alpha by this factor,
-- making deeper frames progressively more transparent to compensate for layering.
-- Applied exponentially: effective_alpha = base_alpha * TRANSPARENCY_FALLOFF ^ level
local TRANSPARENCY_FALLOFF = 0.85

--- Computes the per-nesting-level alpha for the non-ElvUI fallback.
---@param baseAlpha number  The base alpha (0–1) before falloff.
---@param level     number  Nesting depth (0 = outermost).
---@return number           baseAlpha when ElvUI is active, else exponentially reduced.
local function CB_LevelAlpha(baseAlpha, level)
    if NS.ElvUI_S then return baseAlpha end
    local factor = 1
    for _ = 1, level do factor = factor * TRANSPARENCY_FALLOFF end
    return baseAlpha * factor
end

-- Re-applies accent color to every registered skinned frame.
-- a defaults to 1 (fully opaque) when omitted.
--- Re-applies the accent border color to every registered skinned frame.
---@param r number  Red 0–1.
---@param g number  Green 0–1.
---@param b number  Blue 0–1.
---@param a number? Alpha 0–1 (defaults to 1).
NS.CB_RefreshAccentColor = function(r, g, b, a)
    local alpha = a or 1
    for frame, info in pairs(NS.CB_skinnedFrames) do
        if not info.fixed then
            frame:SetBackdropBorderColor(r, g, b, alpha)
        end
    end
end

-- Re-applies background transparency to every registered panel frame.
-- t is 0–100; 100 = fully opaque, 0 = fully transparent.
-- Non-ElvUI frames additionally apply per-level exponential falloff.
-- Blizzard-theme frames: only "window" frames (the outermost dialog and boxes floating on
-- UIParent) follow t; nested boxes keep their fixed shade.
--- Re-applies background transparency to every registered panel frame.
---@param t number  Opacity 0–100 (100 = fully opaque).
NS.CB_RefreshTransparency = function(t)
    local baseAlpha = (t or 100) / 100
    for frame, info in pairs(NS.CB_skinnedFrames) do
        if info.fixed then
            if info.window then
                local c = info.color
                frame:SetBackdropColor(c[1], c[2], c[3], baseAlpha)
            end
        elseif info.skin == "panel" then
            frame:SetBackdropColor(info.brightness, info.brightness, info.brightness,
                CB_LevelAlpha(baseAlpha, info.level))
        end
    end
end

-- Panel factory — creates a bordered child frame, applies CB_ApplyFrameSkin for
-- nestLevel, and stamps paddingTop/Bottom/Left/Right from paddingRole so child
-- helpers such as CB_CreateScrollFrame can read parent.paddingXxx directly.
-- Returns the new frame. Caller is responsible for SetPoint / SetAllPoints.
--- Creates a bordered, skinned child panel with padding fields stamped from its role.
---@param parent      table   Parent frame.
---@param name        string? Optional global frame name.
---@param nestLevel   number? Nesting depth for CB_ApplyFrameSkin (default 1).
---@param paddingRole string? Padding role key into NS.PADDING (default "panel").
---@return table              The created Frame with paddingTop/Bottom/Left/Right stamped.
NS.CB_CreatePanel = function(parent, name, nestLevel, paddingRole)
    local frame = CreateFrame("Frame", name, parent)
    NS.CB_ApplyFrameSkin(frame, nestLevel or 1)
    local role = (paddingRole and NS.PADDING[paddingRole]) and paddingRole or "panel"
    local pad  = NS.PADDING[role]
    frame.paddingTop    = pad.top
    frame.paddingBottom = pad.bottom
    frame.paddingLeft   = pad.left
    frame.paddingRight  = pad.right
    frame._paddingRole  = role           -- re-stamped from NS.PADDING on a live layout change
    NS.CB_RegisterStampable(frame)
    return frame
end

-- Re-applies scale to every registered root frame.
--- Re-applies scale to every registered root frame.
---@param s number  Scale percentage 0–100+ (100 = 1.0).
NS.CB_RefreshScale = function(s)
    local scale = (s or 100) / 100
    for frame, _ in pairs(NS.CB_rootFrames) do
        frame:SetScale(scale)
    end
end

-- The three theme refreshers are reactive: they re-apply to whole frame registries, so they
-- subscribe once to their display-setting event. Producers (Settings Apply, login restore) just
-- emit via CB_EmitDisplaySettings; nothing calls the refreshers directly anymore.
NS.CB_On(NS.EV.SCALE_CHANGED,        NS.CB_RefreshScale)
NS.CB_On(NS.EV.TRANSPARENCY_CHANGED, NS.CB_RefreshTransparency)
NS.CB_On(NS.EV.ACCENT_CHANGED,       NS.CB_RefreshAccentColor)

-- Emits all four display-setting events from the current NS.* values. The single apply path
-- shared by Settings Apply and the PLAYER_LOGIN restore. LAYOUT_CHANGED drives the live re-layout
-- (re-stamp + replay) subscribed in Skinning/Layout.lua.
--- @param includeLayout boolean?  Also emit LAYOUT_CHANGED (the live re-flow). Settings Apply passes
---   true; the login restore omits it — the freshly-built UI is already laid out, so a replay there
---   is redundant (and only risks clobbering build-time positions).
NS.CB_EmitDisplaySettings = function(includeLayout)
    local c = NS.accentColor or {}
    NS.CB_Emit(NS.EV.SCALE_CHANGED,        NS.scale)
    NS.CB_Emit(NS.EV.TRANSPARENCY_CHANGED, NS.transparency)
    NS.CB_Emit(NS.EV.ACCENT_CHANGED,       c.r, c.g, c.b, c.a)
    if includeLayout then NS.CB_Emit(NS.EV.LAYOUT_CHANGED) end
end

-- Applies the title bar ornament and creates the title FontString for an outer frame.
-- Must be called AFTER CB_ApplyFrameSkin (i.e. after any StripTextures call).
--
-- Non-ElvUI: adds the Blizzard dialog header ornament (256×64 OVERLAY texture,
--   elevated 12px so it overlaps the border) and a compact GameFontNormal label
--   nudged to sit in the ornament's visual band.
-- ElvUI: skips the ornament (SetTemplate handles the chrome) and uses the larger
--   GameFontNormalLarge centered in the title area, matching ElvUI frame conventions.
---@param frame     table   The outer frame to add the title bar to.
---@param titleText string? Title string to display (e.g. "CleanBot").
NS.CB_ApplyTitleBar = function(frame, titleText)
    if NS.ElvUI_S then
        local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        lbl:SetText(titleText or "")
        lbl:SetPoint("CENTER", frame, "TOP", 0, -(NS.TITLE_H / 2))
        lbl:SetJustifyH("CENTER")
        return
    end
    -- Ornament texture in OVERLAY — FontStrings render above Textures within the
    -- same draw layer, so the label below will appear on top of the ornament.
    local tex = frame:CreateTexture(nil, "OVERLAY")
    tex:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    tex:SetWidth(256)
    tex:SetHeight(64)
    tex:SetPoint("CENTER", frame, "TOP", 0, -(NS.TITLE_H / 2))
    local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetText(titleText or "")
    lbl:SetPoint("CENTER", frame, "TOP", 0, -2)
    lbl:SetJustifyH("CENTER")
end

-- Places a centered title label for a ContainerFrame-style window (Blizz path only).
-- Reusable for any frame built with CB_ApplyContainerFrameSkin.
-- CONTAINER_TITLE_OFFSET controls how far below the top edge the label sits.
local CONTAINER_TITLE_OFFSET = 2
--- Places a centered title label for a ContainerFrame-style window.
---@param frame table   The container-style frame.
---@param text  string? Title string to display.
NS.CB_ApplyContainerTitleLabel = function(frame, text)
    local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetText(text or "")
    lbl:SetPoint("CENTER", frame, "TOP", 0, -(NS.TITLE_H / 2) - CONTAINER_TITLE_OFFSET)
    lbl:SetJustifyH("CENTER")
end

-- Applies the inventory window title bar label.
-- Blizz: plain centered label via CB_ApplyContainerTitleLabel.
-- ElvUI: centered label using GameFontNormalLarge.
---@param frame   table   The grid frame.
---@param botName string  Bot's display name (label reads "<botName>'s <noun>").
---@param class   string? Bot class (unused for the label; kept for signature parity).
---@param noun    string? Title noun ("Inventory" default, or "Bank").
NS.CB_ApplyInventoryTitleBar = function(frame, botName, class, noun)
    noun = noun or "Inventory"
    if NS.ElvUI_S then
        local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        lbl:SetText(botName .. "'s " .. noun)
        lbl:SetPoint("CENTER", frame, "TOP", 0, -(NS.TITLE_H / 2))
        lbl:SetJustifyH("CENTER")
        return
    end

    NS.CB_ApplyContainerTitleLabel(frame, botName .. "'s " .. noun)
end

-- Assembles the Blizzard ContainerFrame-style backdrop for the inventory frame from
-- sliced pieces of UI-BackpackBackground. Call once when the frame is created.
-- Unlike CB_ApplyFrameSkin, this does NOT register for accent-color or transparency
-- refresh — the ContainerFrame look is fixed art, not theme-driven. Edges and fill
-- are added in CB_UpdateContainerTiles once the frame is sized by CB_RenderInventory.
--
-- Border measurements derived from ContainerFrame1 (192×240, texture 256×256,
-- scale X=192/256=0.75, scale Y=240/256=0.9375):
--   Left  : 23px screen → ~31px texture  → U  = 31/256  ≈ 0.12109
--   Right : 12px screen →  16px texture  → U  = 240/256 = 0.93750 (start of right border)
--   Top   : 51px screen → ~54px texture  → V  = 54/256  ≈ 0.21094
--   Bottom: 32px screen → ~34px texture  → V  = 222/256 ≈ 0.86719 (start of bottom border)
---@param frame table  The inventory frame to skin (stores _skinParams + tile pools on it).
NS.CB_ApplyContainerFrameSkin = function(frame)
    local TEX    = "Interface\\ContainerFrame\\UI-BackpackBackground"
    local TILE_W = 40   -- one item cell: CELL_SIZE(37) + CELL_PAD(3)
    local TILE_H = 40
    local COLS   = 10

    local BL_X1, BL_X2 = 65,  122
    local BR_X1, BR_X2 = 204, 256

    local FILL_X1, FILL_X2 = 122, 162  -- x crop for center and top/bottom edge fill tiles; tune as needed
    local FILL_Y1, FILL_Y2 = 92,  132  -- y crop for center and side fill tiles; tune as needed

    -- Corners and edges are static (BORDER layer so they always render above dynamic fill tiles).
    local function makeCorner(anchor, x1, y1, x2, y2)
        local t = frame:CreateTexture(nil, "BORDER")
        t:SetSize(x2 - x1, y2 - y1)
        t:SetPoint(anchor, frame, anchor, 0, 0)
        t:SetTexture(TEX)
        t:SetTexCoord(x1/256, x2/256, y1/256, y2/256)
        return x2 - x1, y2 - y1
    end

    local function makeEdge(anchor, x1, y1, x2, y2, startX)
        local tileH = y2 - y1
        for i = 0, COLS - 3 do
            local t = frame:CreateTexture(nil, "BORDER")
            t:SetSize(TILE_W, tileH)
            t:SetPoint(anchor, frame, anchor, startX + i * TILE_W, 0)
            t:SetTexture(TEX)
            t:SetTexCoord(x1/256, x2/256, y1/256, y2/256)
        end
    end

    local tlW, tlH = makeCorner("TOPLEFT",      BL_X1,   0, BL_X2,  49)
    local blW      = makeCorner("BOTTOMLEFT",   BL_X1, 213, BL_X2, 240)
    makeCorner("TOPRIGHT",    BR_X1,   0, BR_X2,  49)
    makeCorner("BOTTOMRIGHT", BR_X1, 213, BR_X2, 240)

    makeEdge("TOPLEFT",    FILL_X1,   0, FILL_X2,  49, tlW)
    makeEdge("BOTTOMLEFT", FILL_X1, 213, FILL_X2, 240, blW)

    -- Store params needed by CB_UpdateContainerTiles.
    frame._skinParams = {
        tex    = TEX,
        tileW  = TILE_W, tileH  = TILE_H,
        centerCols = COLS - 2,
        tlW    = tlW,   tlH    = tlH,
        lx1    = BL_X1, lx2    = BL_X2,
        rx1    = BR_X1, rx2    = BR_X2,
        fx1    = FILL_X1, fx2  = FILL_X2,
        fy1    = FILL_Y1, fy2  = FILL_Y2,
    }
    frame._sideLeftPool  = {}
    frame._sideRightPool = {}
    frame._centerPool    = {}
end

-- Updates the dynamic side and center fill tiles to match the current row count.
-- Call from CB_RenderInventory after the row count is known.
---@param frame table   The inventory frame previously passed to CB_ApplyContainerFrameSkin.
---@param rows  number  Number of item rows to fill.
NS.CB_UpdateContainerTiles = function(frame, rows)
    local p = frame._skinParams
    if not p then return end

    local function ensureAndUpdate(pool, needed, createFn, updateFn)
        while #pool < needed do
            pool[#pool + 1] = createFn()
        end
        for i, t in ipairs(pool) do
            if i <= needed then updateFn(t, i) ; t:Show()
            else t:Hide() end
        end
    end

    local lW = p.lx2 - p.lx1
    local rW = p.rx2 - p.rx1

    ensureAndUpdate(frame._sideLeftPool, rows,
        function()
            local t = frame:CreateTexture(nil, "BACKGROUND")
            t:SetTexture(p.tex)
            t:SetTexCoord(p.lx1/256, p.lx2/256, p.fy1/256, p.fy2/256)
            return t
        end,
        function(t, i)
            t:SetSize(lW, p.tileH)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(p.tlH + (i - 1) * p.tileH))
        end)

    ensureAndUpdate(frame._sideRightPool, rows,
        function()
            local t = frame:CreateTexture(nil, "BACKGROUND")
            t:SetTexture(p.tex)
            t:SetTexCoord(p.rx1/256, p.rx2/256, p.fy1/256, p.fy2/256)
            return t
        end,
        function(t, i)
            t:SetSize(rW, p.tileH)
            t:ClearAllPoints()
            t:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -(p.tlH + (i - 1) * p.tileH))
        end)

    local centerNeeded = rows * p.centerCols
    ensureAndUpdate(frame._centerPool, centerNeeded,
        function()
            local t = frame:CreateTexture(nil, "BACKGROUND")
            t:SetTexture(p.tex)
            t:SetTexCoord(p.fx1/256, p.fx2/256, p.fy1/256, p.fy2/256)
            return t
        end,
        function(t, i)
            local col = (i - 1) % p.centerCols
            local row = math.floor((i - 1) / p.centerCols)
            t:SetSize(p.tileW, p.tileH)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", frame, "TOPLEFT",
                p.tlW + col * p.tileW,
                -(p.tlH + row * p.tileH))
        end)
end

-- Single entry point for skinning any structural frame.
--
-- Blizzard theme: handled by the early branch below (stock dialog window / grey Options boxes).
-- Flat theme — nestLevel controls which backdrop and fill brightness to use:
--   0        — outermost window (CleanBotFrame, inventory windows).
--              Non-ElvUI: ornate OUTER_BACKDROP; ElvUI: SetTemplate("Default").
--   1, 2, … — inner panels. Both paths use PANEL_BACKDROP / SetTemplate("Default");
--              brightness scales per level so nested frames read as progressively
--              inset (ElvUI gets darker inward, Blizzard gets lighter inward).
--
-- ElvUI:     level 0 → 0.10 brightness, each additional level subtracts 0.05 → max 0
-- Non-ElvUI: level 0 → 0.00 brightness, each level adds 0.05
--   SetBackdropColor is a vertex-color multiply; small steps look near-black so
--   0.05 per level keeps contrast visible across at least four nesting levels.
--
-- Registers every frame in CB_skinnedFrames so CB_RefreshAccentColor and
-- CB_RefreshTransparency can re-apply shading without re-calling this function.
---@param frame     table   The structural frame to skin.
---@param nestLevel number? Nesting depth (0 = outermost window, default 1).
NS.CB_ApplyFrameSkin = function(frame, nestLevel)
    local level = nestLevel or 1

    -- Blizzard theme: stock art with fixed colors. Level 0 is the ornate dialog window at full
    -- texture brightness; deeper levels are grey Interface-Options boxes with a faint fixed shade.
    -- A box parented straight to UIParent (vendor/recruiter panels, action bar, debug window) floats
    -- over the world, so it gets the stock tooltip background instead. Only these "window" frames
    -- follow Transparency; the accent color is not used.
    if NS.CB_IsBlizzardTheme() then
        local bc     = NS.BLIZZ_BOX_BORDER
        local alpha  = (NS.transparency or 100) / 100
        local window, color = true, nil
        if level == 0 then
            frame:SetBackdrop(NS.OUTER_BACKDROP)
            frame:SetBackdropBorderColor(1, 1, 1, 1)
            color = { 1, 1, 1 }
        else
            frame:SetBackdrop(NS.BLIZZ_BOX_BACKDROP)
            frame:SetBackdropBorderColor(bc.r, bc.g, bc.b, bc.a)
            if frame.GetParent and frame:GetParent() == UIParent then
                color = BLIZZ_FLOAT_FILL
            else
                window = false
            end
        end
        if window then
            frame:SetBackdropColor(color[1], color[2], color[3], alpha)
        else
            frame:SetBackdropColor(0, 0, 0, BLIZZ_BOX_FILL_ALPHA)
        end
        NS.CB_skinnedFrames[frame] = { skin = "panel", level = level, fixed = true, window = window, color = color }
        return
    end

    if level == 0 then
        -- Outermost window: accent color has no tint by default (a=0 on Blizzard).
        local ac         = NS.accentColor or { r = 0.0, g = 0.0, b = 0.0, a = 0 }
        local alpha      = (NS.transparency or 100) / 100
        local brightness = NS.ElvUI_S and 0.10 or 0.0
        if NS.ElvUI_S then
            frame:StripTextures()
            frame:SetTemplate("Default")
        else
            frame:SetBackdrop(NS.OUTER_BACKDROP)
        end
        frame:SetBackdropColor(brightness, brightness, brightness, CB_LevelAlpha(alpha, 0))
        frame:SetBackdropBorderColor(ac.r, ac.g, ac.b, ac.a or 1)
        NS.CB_skinnedFrames[frame] = { skin = "panel", brightness = brightness, level = 0 }
    else
        -- Inner panel: depth is 0-based for the brightness formula (level 1 = shallowest).
        local ac         = NS.accentColor or { r = 0.3, g = 0.3, b = 0.3, a = 1 }
        local alpha      = (NS.transparency or 100) / 100
        local depth      = level - 1
        local brightness = NS.ElvUI_S and math.max(0, 0.10 - depth * 0.02) or (depth * 0.05)
        if NS.ElvUI_S then
            frame:StripTextures()
            frame:SetTemplate("Default")
        else
            frame:SetBackdrop(NS.PANEL_BACKDROP)
        end
        frame:SetBackdropColor(brightness, brightness, brightness, CB_LevelAlpha(alpha, depth))
        frame:SetBackdropBorderColor(ac.r, ac.g, ac.b, ac.a or 1)
        NS.CB_skinnedFrames[frame] = { skin = "panel", brightness = brightness, level = depth }
    end
end

-- Internal skin for scrollable list containers (CB_CreateSelectList only).
-- Uses SetTemplate("Transparent") on ElvUI so the list reads as a recessed input
-- area rather than a standard panel. Not registered for transparency refresh —
-- the fixed dark alpha is intentional regardless of the theme setting.
-- Promoted to NS so CB_CreateSelectList (Skinning\Widgets.lua) can reach it.
---@param frame table  The list container frame to skin.
NS.CB_ApplyInnerSkin = function(frame)
    if NS.CB_IsBlizzardTheme() then
        local bc = NS.BLIZZ_BOX_BORDER
        frame:SetBackdrop(NS.BLIZZ_BOX_BACKDROP)
        frame:SetBackdropColor(0, 0, 0, BLIZZ_LIST_FILL_ALPHA)
        frame:SetBackdropBorderColor(bc.r, bc.g, bc.b, bc.a)
        return
    end
    local ac = NS.accentColor or { r = 0.3, g = 0.3, b = 0.3, a = 1 }
    if NS.ElvUI_S then
        frame:StripTextures()
        frame:SetTemplate("Transparent")
    else
        frame:SetBackdrop(NS.PANEL_BACKDROP)
        frame:SetBackdropColor(0, 0, 0, 0.4)
    end
    frame:SetBackdropBorderColor(ac.r, ac.g, ac.b, ac.a or 1)
end

-- Frame factory — creates a child frame nested inside parent, inset by parent's
-- padding (chosen by paddingRole) plus the child's own margin (chosen by marginType).
--
-- paddingRole: "frame" | "panel" | "section"  — selects NS.PADDING[paddingRole]
-- marginType:  "panel" | "section" | nil       — selects NS.MARGIN[marginType];
--              nil means no extra margin (pure padding placement).
-- widthPct / heightPct: fraction of the parent's interior to fill (default 1.0).
--   Full fill (both 1.0): dual anchors so the layout engine handles resizing.
--   Partial fill: TOPLEFT anchor + OnSizeChanged to recompute size dynamically.
-- nestLevel:   passed to CB_ApplyFrameSkin to control fill brightness relative to parent.
--
-- The child's margin values are stamped onto it so CB_AnchorBelow / CB_AnchorAhead
-- can treat it the same as any other widget in a flow chain.
---@param parent      table   Parent frame.
---@param name        string? Optional global frame name.
---@param paddingRole string? Padding role key into NS.PADDING (default "panel").
---@param marginType  string? Margin type key into NS.MARGIN, or nil for none.
---@param widthPct    number? Fraction of parent interior width to fill (default 1).
---@param heightPct   number? Fraction of parent interior height to fill (default 1).
---@param nestLevel   number? Nesting depth for CB_ApplyFrameSkin (default 1).
---@return table              The created Frame with margins stamped.
NS.CB_CreateInnerFrame = function(parent, name, paddingRole, marginType, widthPct, heightPct, nestLevel)
    local child = CreateFrame("Frame", name, parent)

    local pad = NS.PADDING[paddingRole] or NS.PADDING.panel
    local mar = (marginType and NS.MARGIN[marginType]) or {}

    local mTop    = mar.top    or 0
    local mBottom = mar.bottom or 0
    local mLeft   = mar.left   or 0
    local mRight  = mar.right  or 0

    child.marginTop    = mTop
    child.marginBottom = mBottom
    child.marginLeft   = mLeft
    child.marginRight  = mRight
    if marginType then child._marginType = marginType; NS.CB_RegisterStampable(child) end

    local wPct = widthPct  or 1
    local hPct = heightPct or 1

    if wPct == 1 and hPct == 1 then
        child:SetPoint("TOPLEFT", parent, "TOPLEFT",
             pad.left   + mLeft,
            -(pad.top   + mTop))
        child:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT",
            -(pad.right  + mRight),
              pad.bottom + mBottom)
    else
        child:SetPoint("TOPLEFT", parent, "TOPLEFT",
             pad.left + mLeft,
            -(pad.top + mTop))

        local function resize(w, h)
            local availW = w - pad.left - pad.right - mLeft - mRight
            local availH = h - pad.top  - pad.bottom - mTop - mBottom
            child:SetSize(math.max(availW * wPct, 1), math.max(availH * hPct, 1))
        end

        parent:HookScript("OnSizeChanged", function(self, w, h) resize(w, h) end)

        local w, h = parent:GetWidth(), parent:GetHeight()
        if w > 0 and h > 0 then resize(w, h) end
    end

    NS.CB_ApplyFrameSkin(child, nestLevel or 1)

    return child
end

-- Restyles a SpellBookSkillLineTabTemplate side-tab to ElvUI's flat dark backdrop + border (the same
-- StripTextures + StyleButton + SetTemplate recipe ElvUI uses on the real skill-line tabs), replacing
-- the gold Blizzard frame so the tab matches a skinned attached window. These tabs hang off Blizzard
-- frames ElvUI itself reskins (MerchantFrame, LFDParentFrame), so this follows the HOST handle: it
-- applies whenever ElvUI is loaded, regardless of CleanBot's theme. No-op without ElvUI. Shared by
-- the vendor strip (Merchant.lua) and the Dungeon Finder recruiter tab (Recruiter.lua).
---@param button table  A button built from SpellBookSkillLineTabTemplate.
NS.CB_SkinSideTab = function(button)
    if not NS.ElvUI_HostS then return end
    if button.StripTextures then button:StripTextures()       end
    if button.StyleButton  then button:StyleButton(nil, true) end
    if button.SetTemplate  then button:SetTemplate("Default", true) end
end

-- Scroll frame factory — creates a scroll frame inset from parent by parent's
-- stamped padding, wires up the scroll child, mouse wheel, and ElvUI scroll bar
-- skinning. The scroll bar is accessed via the standard UIPanelScrollFrameTemplate
-- naming convention: name .. "ScrollBar".
--
-- Both the scroll frame and scroll child have paddingTop/Bottom/Left/Right = 0
-- stamped onto them — they are borderless containers with no visual inset.
-- Content inside the scroll child uses only its own margins; there is no
-- border to escape from.
---@param parent table   Parent frame (reads its paddingTop/Bottom/Left/Right).
---@param name   string  Global name; the scroll bar is looked up as name.."ScrollBar".
---@return table         scrollFrame  The created ScrollFrame.
---@return table         scrollChild  The scroll child Frame.
NS.CB_CreateScrollFrame = function(parent, name)
    local sf = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
    -- Inset by the parent's padding (+20 on the right for the scroll bar). Recorded so a live padding
    -- change re-insets the scroll region; the child width self-heals via the OnSizeChanged hook below.
    NS.CB_Anchor(sf, function()
        sf:ClearAllPoints()
        sf:SetPoint("TOPLEFT",     parent, "TOPLEFT",      (parent.paddingLeft  or 0),        -(parent.paddingTop or 0))
        sf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -((parent.paddingRight or 0) + 20),  (parent.paddingBottom or 0))
    end)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local max = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.max(0, math.min(max, cur - delta * 20)))
    end)

    sf.paddingTop    = 0 ; sf.paddingBottom = 0
    sf.paddingLeft   = 0 ; sf.paddingRight  = 0

    local sc = CreateFrame("Frame", name .. "Child", sf)
    sc:SetHeight(1)
    sf:SetScrollChild(sc)
    sf:SetScript("OnSizeChanged", function(self, w, _)
        sc:SetWidth(w)
    end)

    sc.paddingTop    = 0 ; sc.paddingBottom = 0
    sc.paddingLeft   = 0 ; sc.paddingRight  = 0

    local scrollBar = _G[name .. "ScrollBar"]
    if scrollBar and NS.ElvUI_S then
        NS.ElvUI_S:HandleScrollBar(scrollBar)
    end

    return sf, sc
end
