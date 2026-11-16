-- ============================================================
-- spec/theme_spec.lua  —  Skinning/ElvUI.lua theme selection: saved-theme resolution, which
-- ElvUI handles CB_InitElvUI exposes per theme, per-theme defaults, and the Blizzard-theme
-- frame skin (fixed stock border colors that ignore the accent; only window frames follow
-- transparency). Real rendering is in-game only.
-- ============================================================
if not CleanBotNS.CB_Emit then dofile("Events.lua") end
if not CleanBotNS.CB_ResolveTheme then dofile("Skinning/ElvUI.lua") end
local NS = CleanBotNS

-- Frame stub recording the last backdrop / fill / border calls.
local function frame(parent)
    local f = { parent = parent }
    function f:GetParent()                       return self.parent end
    function f:SetBackdrop(b)                    self.backdrop = b end
    function f:SetBackdropColor(r, g, b, a)      self.fill   = { r, g, b, a } end
    function f:SetBackdropBorderColor(r, g, b, a) self.border = { r, g, b, a } end
    return f
end

-- Installs a fake ElvUI (or none) for CB_InitElvUI; returns the E and S objects.
local function fakeElvUI(loaded)
    local S = { name = "Skins" }
    local E = { GetModule = function(_, m) return m == "Skins" and S or nil end }
    _G.IsAddOnLoaded = function(addon) return loaded and addon == "ElvUI" end
    _G.ElvUI = loaded and { E } or nil
    return E, S
end

local function resetTheme()
    NS.theme = NS.DEFAULT_THEME
    NS.ElvUI_E, NS.ElvUI_S, NS.ElvUI_HostE, NS.ElvUI_HostS = nil, nil, nil, nil
    NS.transparency = 100
    NS.accentColor  = { r = 1, g = 0, b = 0, a = 1 }
end

describe("CB_ResolveTheme", function()
    it("defaults to Blizzard when nothing is saved (fresh install / pre-theme update)", function()
        assert.equals("blizzard", NS.CB_ResolveTheme(nil))
    end)
    it("keeps a valid saved theme", function()
        assert.equals("flat", NS.CB_ResolveTheme("flat"))
        assert.equals("blizzard", NS.CB_ResolveTheme("blizzard"))
    end)
    it("falls back to Blizzard for an unknown value", function()
        assert.equals("blizzard", NS.CB_ResolveTheme("neon"))
        assert.equals("blizzard", NS.CB_ResolveTheme(42))
    end)
end)

describe("CB_InitElvUI", function()
    before_each(resetTheme)

    it("Blizzard theme with ElvUI: only the host handles are set", function()
        local E, S = fakeElvUI(true)
        NS.theme = "blizzard"
        NS.CB_InitElvUI()
        assert.is_nil(NS.ElvUI_E)
        assert.is_nil(NS.ElvUI_S)
        assert.equals(E, NS.ElvUI_HostE)
        assert.equals(S, NS.ElvUI_HostS)
    end)

    it("Flat theme with ElvUI: CleanBot frames get the ElvUI skin handles", function()
        local E, S = fakeElvUI(true)
        NS.theme = "flat"
        NS.CB_InitElvUI()
        assert.equals(E, NS.ElvUI_E)
        assert.equals(S, NS.ElvUI_S)
        assert.equals(S, NS.ElvUI_HostS)
    end)

    it("no ElvUI: every handle stays nil", function()
        fakeElvUI(false)
        NS.theme = "flat"
        NS.CB_InitElvUI()
        assert.is_nil(NS.ElvUI_S)
        assert.is_nil(NS.ElvUI_HostS)
    end)
end)

describe("CB_ThemeDefaultValues", function()
    before_each(resetTheme)

    it("Blizzard: fully opaque window", function()
        local _, t = NS.CB_ThemeDefaultValues("blizzard")
        assert.equals(100, t)
    end)
    it("Flat keeps the original per-ElvUI defaults", function()
        local ac, t = NS.CB_ThemeDefaultValues("flat")
        assert.equals(90, t)
        assert.equals(0, ac.a)
        NS.ElvUI_HostS = {}
        ac, t = NS.CB_ThemeDefaultValues("flat")
        assert.equals(75, t)
        assert.same({ r = 0, g = 0, b = 0, a = 1 }, ac)
    end)
end)

describe("CB_CarryThemeValues", function()
    before_each(resetTheme)

    it("Blizzard defaults switching to Flat with ElvUI become ElvUI's visible border + 75%", function()
        NS.ElvUI_HostS = {}
        local ac, t = NS.CB_CarryThemeValues("blizzard", "flat", { r = 1, g = 1, b = 1, a = 0 }, 100)
        assert.same({ r = 0, g = 0, b = 0, a = 1 }, ac)
        assert.equals(75, t)
    end)

    it("customised values survive a theme switch", function()
        NS.ElvUI_HostS = {}
        local ac, t = NS.CB_CarryThemeValues("blizzard", "flat", { r = 0.2, g = 0.4, b = 0.6, a = 1 }, 60)
        assert.same({ r = 0.2, g = 0.4, b = 0.6, a = 1 }, ac)
        assert.equals(60, t)
    end)
end)

describe("CB_ApplyFrameSkin (Blizzard theme)", function()
    before_each(resetTheme)

    it("outer window: stock dialog art, full-brightness border, fill follows transparency", function()
        local f = frame(UIParent)
        NS.CB_ApplyFrameSkin(f, 0)
        assert.equals(NS.OUTER_BACKDROP, f.backdrop)
        assert.same({ 1, 1, 1, 1 }, f.border)
        NS.CB_RefreshTransparency(40)
        assert.same({ 1, 1, 1, 0.4 }, f.fill)
    end)

    it("nested box: grey Options border that ignores the accent and transparency", function()
        local f = frame({})
        NS.CB_ApplyFrameSkin(f, 3)
        assert.equals(NS.BLIZZ_BOX_BACKDROP, f.backdrop)
        assert.same({ 0.6, 0.6, 0.6, 1 }, f.border)
        local fill = f.fill
        NS.CB_RefreshAccentColor(1, 0, 0, 1)
        NS.CB_RefreshTransparency(10)
        assert.same({ 0.6, 0.6, 0.6, 1 }, f.border)
        assert.equals(fill, f.fill)
    end)

    it("box floating on UIParent: tooltip background that follows transparency", function()
        local f = frame(UIParent)
        NS.CB_ApplyFrameSkin(f, 1)
        NS.CB_RefreshTransparency(50)
        assert.same({ 0.09, 0.09, 0.19, 0.5 }, f.fill)
        assert.same({ 0.6, 0.6, 0.6, 1 }, f.border)
    end)
end)

describe("CB_ApplyFrameSkin (Flat theme, no ElvUI)", function()
    before_each(resetTheme)

    it("keeps the original accent-tinted flat panel", function()
        NS.theme = "flat"
        local f = frame({})
        NS.CB_ApplyFrameSkin(f, 2)
        assert.equals(NS.PANEL_BACKDROP, f.backdrop)
        assert.same({ 1, 0, 0, 1 }, f.border)
        NS.CB_RefreshAccentColor(0, 1, 0, 1)
        assert.same({ 0, 1, 0, 1 }, f.border)
        resetTheme()
    end)
end)
