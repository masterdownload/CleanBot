-- ============================================================
-- AltArmy.lua  —  every alt on this account, and the connect/logout actions for them.
--
-- Data + action layer behind the Manage tab's "Alt Army" section. It owns two
-- bridge endpoints and nothing else:
--   GET~ALT_ROSTER                        → BEGIN / ENTRY×n / END snapshot of the account
--   RUN~BOT_CONNECT / RUN~BOT_DISCONNECT  → BOT_LIFECYCLE result for one alt
-- plus GET~BOT_LIFECYCLE_STATE, used once per still-connecting alt to settle the row.
--
-- The wire itself is BridgeRpc.lua's job (tokens, timeouts, ERR routing, rate
-- budgets, capability gate); this file only translates packets into a cached
-- model and human-readable row state. Single-alt actions degrade to the old
-- ".playerbots bot add/remove" SAY commands when the bridge or its BOT_LIFECYCLE
-- capability is missing; the bulk buttons have no such fallback and say so.
--
-- Server side: modules/mod-multibot-bridge/src/MultiBotBridge.cpp
--   ALT_ROSTER_ENTRY~<guid>~<url(name)>~<classId>~<level>~ONLINE|OFFLINE
--     (requester excluded, 128 entries max, truncated flag on the BEGIN/END framing)
--   BOT_LIFECYCLE~<token>~<guid>~<url(name)>~<action>~OK|PENDING|ERR~<reason>
--     OK = settled (reason ONLINE / ALREADY_ONLINE / OFFLINE / ALREADY_OFFLINE);
--     PENDING = accepted and still connecting (STARTED / ALREADY_CONNECTING)
--   BOT_LIFECYCLE_STATE~<token>~<guid>~<url(name)>~ONLINE|OFFLINE|CONNECTING~<reason>
--   GET~BOT_TARGET_RESOLVE~<url(name)>~<token> →
--     BOT_TARGET_RESOLVE~<token>~OK|ERR~<reason>~<url(name)>~<guid>~<state>
-- ============================================================
local NS = CleanBotNS

-- Client mirror of the server's per-window limits (every window is 2 s).
local ROSTER_MAX_PER_WINDOW = 4      -- ConsumeAltRosterRequestRateLimit
local QUERY_MAX_PER_WINDOW  = 256    -- bot-lifecycle query group
local MUTATE_MAX_PER_WINDOW = 64     -- ConsumeBotLifecycleMutationRateLimit
local RATE_WINDOW           = 2
-- Bulk runs stagger their sends so a "connect all" neither blows the server's
-- mutation window at once nor the client's addon-message spam protection.
local BULK_STAGGER          = 0.15
-- A connect that answered PENDING is re-checked this many times, once per delay.
local MAX_STATE_CHECKS      = 3
local STATE_CHECK_DELAY     = 2.0

-- Row states: ONLINE / OFFLINE / CONNECTING (transient, from a PENDING answer).
NS.ALT_ARMY_ONLINE     = "ONLINE"
NS.ALT_ARMY_OFFLINE    = "OFFLINE"
NS.ALT_ARMY_CONNECTING = "CONNECTING"

-- Cached snapshot plus per-row live state. Rebuilt wholesale by a refresh;
-- individual rows are then patched by lifecycle results.
NS.altArmy = NS.altArmy or {
    entries   = {},     -- array of { guid, name, class, level, state, note }
    byGuid    = {},     -- [guid] = entry (the same tables held in entries)
    fetchedAt = nil,    -- GetTime() of the last completed snapshot (nil = never)
    truncated = false,  -- the server hit its entry cap: the list is partial
    source    = "none", -- "bridge" once a snapshot landed, else "unavailable"
    lastError = nil,    -- outcome of the failed refresh attempt, for the status line
}

local listeners = {}   -- UI callbacks re-run after any change to the model
local staging   = nil  -- rows collected between ALT_ROSTER_BEGIN and ALT_ROSTER_END
local bulkRun   = nil  -- { action, total, settled, ok } while a bulk run is in flight

-- ── Reason tokens → text ─────────────────────────────────────────────────────
-- The server reports machine reasons on BOT_LIFECYCLE; the UI shows these.
-- Anything unmapped falls through as the raw token, so a new server reason is
-- visible instead of silently blank.
local REASON_TEXT = {
    OK                   = "Ready",
    ONLINE               = "Online",
    ALREADY_ONLINE       = "Already online",
    OFFLINE              = "Offline",
    ALREADY_OFFLINE      = "Already offline",
    PENDING              = "Connecting...",
    STARTED              = "Connecting...",
    ALREADY_CONNECTING   = "Connecting...",
    CONNECTING           = "Connecting...",
    TIMEOUT              = "Timed out",
    IN_USE               = "In use by another player",
    FORBIDDEN            = "Not one of your alts",
    MAX_BOTS             = "Bot limit reached",
    TOO_MANY_PENDING     = "Too many connects in flight",
    NO_MANAGER           = "No bot manager",
    STATE_MISMATCH       = "State changed - refresh",
    NOT_ALLOWED          = "Not allowed",
    RATE_LIMIT           = "Server rate limit - try again",
    REPLAY               = "Duplicate request",
}

-- Refresh failures — BridgeRpc settle outcomes, lowercase — for the status line. Kept apart
-- from REASON_TEXT above, which holds server-side lifecycle reasons in CAPS.
local OUTCOME_TEXT = {
    ["no-bridge"]  = "no bridge answered; join a group or check MultiBotBridge, then Refresh",
    unsupported    = "this bridge has no ALT_ROSTER endpoint",
    timeout        = "the bridge did not answer in time",
    error          = "the bridge rejected the request",
    ["rate-limit"] = "server rate limit - try again in a moment",
    ["too-long"]   = "reply too large for one addon packet",
    cancelled      = "cancelled",
}

---@param reason string|nil  Server reason token.
---@return string            Text for the UI (never nil).
NS.CB_AltArmyReasonText = function(reason)
    if not reason or reason == "" then return "" end
    return REASON_TEXT[reason] or reason
end

-- Same text, but nil for an empty reason so a row's note is cleared, not blanked.
---@param reason string|nil  Server reason token.
---@return string|nil        Text, or nil when there is nothing to show.
local function CB_ReasonNote(reason)
    local text = NS.CB_AltArmyReasonText(reason)
    return (text ~= "") and text or nil
end

-- ── Model helpers ────────────────────────────────────────────────────────────

---@param guid number  Low (counter) part of the character GUID, as sent on the wire.
---@return table|nil   The cached row for that alt.
NS.CB_AltArmyByGuid = function(guid)
    if not guid then return nil end
    return NS.altArmy.byGuid[guid]
end

---Cached row by character name (case-insensitive), nil when never seen.
---@param name string  Character name.
---@return table|nil   The cached row.
NS.CB_AltArmyByName = function(name)
    if type(name) ~= "string" or name == "" then return nil end
    for _, entry in ipairs(NS.altArmy.entries) do
        if string.lower(entry.name or "") == string.lower(name) then return entry end
    end
    return nil
end

---@return number  How many cached alts are currently logged in as bots.
NS.CB_AltArmyOnlineCount = function()
    local count = 0
    for _, entry in ipairs(NS.altArmy.entries) do
        if entry.state == NS.ALT_ARMY_ONLINE then count = count + 1 end
    end
    return count
end

-- Re-runs every subscriber; one broken listener must not stop the others.
local function CB_NotifyArmy()
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn)
        if not ok then NS.CB_Print("Alt Army listener error: " .. tostring(err)) end
    end
end

---Subscribes to Alt Army model changes. Returns an unsubscribe function.
---@param fn fun()  Called after the snapshot or any row state changes.
---@return fun()    Call to stop listening.
NS.CB_AltArmySubscribe = function(fn)
    if type(fn) ~= "function" then return function() end end
    listeners[#listeners + 1] = fn
    return function()
        for i, listener in ipairs(listeners) do
            if listener == fn then table.remove(listeners, i) break end
        end
    end
end

---Drops the cached snapshot (relog / bridge reset), so nothing stale is shown.
---@param reason string|nil  Only used for the /cbdebug rpc trace.
NS.CB_AltArmyReset = function(reason)
    NS.altArmy.entries, NS.altArmy.byGuid = {}, {}
    NS.altArmy.fetchedAt, NS.altArmy.truncated = nil, false
    NS.altArmy.source, NS.altArmy.lastError    = "none", nil
    staging, bulkRun = nil, nil
    if NS.debugRpc and NS.CB_RpcTrace then
        NS.CB_RpcTrace("alt army reset (" .. tostring(reason) .. ")")
    end
    CB_NotifyArmy()
end

-- Sort: online first, then connecting, then offline; inside each group level
-- descending, then name A-Z — so the alts you can act on are at the top.
---@param entries table  Array of rows to sort in place.
local function CB_SortArmy(entries)
    local rank = {
        [NS.ALT_ARMY_ONLINE] = 1, [NS.ALT_ARMY_CONNECTING] = 2, [NS.ALT_ARMY_OFFLINE] = 3,
    }
    table.sort(entries, function(a, b)
        local ra, rb = rank[a.state] or 9, rank[b.state] or 9
        if ra ~= rb then return ra < rb end
        if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) > (b.level or 0) end
        return string.lower(a.name or "") < string.lower(b.name or "")
    end)
end

-- ── Snapshot: GET~ALT_ROSTER ─────────────────────────────────────────────────

-- ALT_ROSTER_BEGIN~<count>~<truncated> — start collecting. The count is advisory;
-- rows come from the ENTRY packets, so a dropped packet cannot desync the model.
---@param fields table  Split packet (fields[1] is the tag).
local function CB_ArmyBegin(fields)
    staging = { rows = {}, truncated = tonumber(fields[3]) == 1 }
end

-- ALT_ROSTER_ENTRY~<guid>~<url(name)>~<classId>~<level>~ONLINE|OFFLINE
---@param fields table  Split packet.
local function CB_ArmyEntry(fields)
    staging = staging or { rows = {}, truncated = false }   -- tolerate a lost BEGIN
    local guid = tonumber(fields[2])
    local name = NS.CB_UrlDecode(fields[3])
    if not guid or name == "" then return end
    staging.rows[#staging.rows + 1] = {
        guid  = guid,
        name  = name,
        class = (NS.CLASS_ID_TOKENS and NS.CLASS_ID_TOKENS[tonumber(fields[4])]) or "WARRIOR",
        level = tonumber(fields[5]) or 0,
        state = (fields[6] == NS.ALT_ARMY_ONLINE) and NS.ALT_ARMY_ONLINE or NS.ALT_ARMY_OFFLINE,
    }
end

-- ALT_ROSTER_END~<count>~<truncated> — swap the collected rows in as the new model.
---@param fields table  Split packet.
local function CB_ArmyEnd(fields)
    local rows      = staging and staging.rows or {}
    local truncated = (staging and staging.truncated) or tonumber(fields[3]) == 1
    staging = nil

    local byGuid = {}
    for _, entry in ipairs(rows) do
        -- Keep the note a lifecycle result wrote between BEGIN and END.
        local previous = NS.altArmy.byGuid[entry.guid]
        if previous and previous.note then entry.note = previous.note end
        byGuid[entry.guid] = entry
    end

    CB_SortArmy(rows)
    NS.altArmy.entries   = rows
    NS.altArmy.byGuid    = byGuid
    NS.altArmy.fetchedAt = GetTime()
    NS.altArmy.truncated = truncated
    NS.altArmy.source    = "bridge"
    NS.altArmy.lastError = nil
    CB_NotifyArmy()
end

---Requests a fresh account snapshot. Concurrent calls coalesce onto the request
---already in flight, and calls inside the server's rate window are queued by
---BridgeRpc rather than dropped (the endpoint sends no token, so copies of it are
---indistinguishable — hence coalescing is mandatory here).
---@param reason string|nil  Why the refresh happened (traced with /cbdebug rpc).
---@return table|nil         Request handle, or nil when nothing was sent.
---@return string            Send status from CB_Request ("sent"/"queued"/"coalesced"/...).
NS.CB_AltArmyRefresh = function(reason)
    local req, status = NS.CB_Request({
        type          = "ALT_ROSTER",
        noToken       = true,      -- GET~ALT_ROSTER takes no token (the server checks the count)
        coalesce      = true,      -- and echoes nothing back, so identical requests must share one
        cap           = "ALT_ROSTER",
        done          = "ALT_ROSTER_END",
        -- END is both the last streaming packet and the completion marker: tag handlers
        -- run before the request settles, so the rows are published by then.
        tags          = { ALT_ROSTER_BEGIN = CB_ArmyBegin, ALT_ROSTER_ENTRY = CB_ArmyEntry,
                          ALT_ROSTER_END   = CB_ArmyEnd },
        rateKey       = "ALT_ROSTER",
        maxPerWindow  = ROSTER_MAX_PER_WINDOW,
        window        = RATE_WINDOW,
        onDone = function(outcome)
            -- "ok" is handled by CB_ArmyEnd, which publishes the rows it collected.
            if outcome == "ok" then return end
            staging = nil
            NS.altArmy.source    = "unavailable"
            NS.altArmy.lastError = outcome
            if NS.debugRpc and NS.CB_RpcTrace then
                NS.CB_RpcTrace("alt roster refresh failed (" .. tostring(outcome)
                    .. ", " .. tostring(reason) .. ")")
            end
            CB_NotifyArmy()
        end,
    })
    return req, status
end

-- ── Single alt: RUN~BOT_CONNECT / RUN~BOT_DISCONNECT ─────────────────────────

---@return boolean  Whether the bridge can run lifecycle actions right now.
local function CB_ArmyBridgeReady()
    return (NS.CB_BridgePresent and NS.CB_BridgePresent()
            and NS.CB_HasCap("BOT_LIFECYCLE")) or false
end

---Whether the wire path is available (drives button wording and bulk actions).
---@return boolean
NS.CB_AltArmyCanUseBridge = CB_ArmyBridgeReady

-- The old text-command path. Kept ONLY for single-alt actions, and only when the
-- bridge or its BOT_LIFECYCLE capability is missing — never after a rejected wire
-- request, which would turn one failure into chat spam.
---@param action string  "CONNECT" | "DISCONNECT".
---@param name string    Character name.
local function CB_ArmySayCommand(action, name)
    if not name or name == "" then return end
    if action == "CONNECT" then
        SendChatMessage(".playerbots bot add " .. name, "SAY")
    else
        SendChatMessage(".playerbots bot remove " .. name, "SAY")
    end
end

-- Applies a lifecycle verdict to a cached row and repaints.
---@param entry table|nil  Row to patch (nil: nothing to update).
---@param state string|nil New row state, or nil to keep the current one.
---@param note  string|nil Per-row status text (cleared when nil/empty).
local function CB_SetArmyRow(entry, state, note)
    if not entry then return end
    if state then entry.state = state end
    entry.note = (note and note ~= "") and note or nil
    CB_NotifyArmy()
end

-- Settles a row that answered PENDING with one follow-up state query, repeated at
-- most MAX_STATE_CHECKS times so a stuck connect stops asking instead of polling.
---@param entry   table  Row still connecting.
---@param attempt number  Which check this is (1-based).
local function CB_ArmyStateCheck(entry, attempt)
    if not entry or attempt > MAX_STATE_CHECKS then return end
    NS.CB_Request({
        type         = "BOT_LIFECYCLE_STATE",
        args         = { entry.guid, "<token>" },
        done         = "BOT_LIFECYCLE_STATE",
        cap          = "BOT_LIFECYCLE",
        rateKey      = "BOT_LIFECYCLE_QUERY",
        maxPerWindow = QUERY_MAX_PER_WINDOW,
        window       = RATE_WINDOW,
        queue        = false,     -- a stale row is not worth buffering for
        onDone = function(outcome, fields)
            if outcome ~= "ok" or not fields then return end
            -- BOT_LIFECYCLE_STATE~<token>~<guid>~<url(name)>~<state>~<reason>
            local state, reason = fields[5], fields[6]
            entry.note = CB_ReasonNote(reason)
            if state == NS.ALT_ARMY_CONNECTING then
                NS.CB_After(STATE_CHECK_DELAY, function() CB_ArmyStateCheck(entry, attempt + 1) end)
                return
            end
            if state == NS.ALT_ARMY_ONLINE or state == NS.ALT_ARMY_OFFLINE then
                CB_SetArmyRow(entry, state, nil)
            else
                CB_NotifyArmy()
            end
        end,
    })
end

-- Bulk bookkeeping: one summary line after the last staggered request reports, so a
-- 20-alt run does not print 20 lines. Also what suppresses per-row error prints.
-- A PENDING answer counts: the server accepted that alt, it is just not online yet.
---@param success boolean  Whether that step ended OK or PENDING.
local function CB_FinishBulkStep(success)
    if not bulkRun then return end
    bulkRun.settled = bulkRun.settled + 1
    if success then bulkRun.ok = bulkRun.ok + 1 end
    if bulkRun.settled < bulkRun.total then return end
    NS.CB_Print(string.format("Alt Army: %s %d of %d alt(s).",
        bulkRun.action == "CONNECT" and "connected" or "disconnected", bulkRun.ok, bulkRun.total))
    bulkRun = nil
end

-- One lifecycle request for one alt. The reply carries the verdict, so nothing here
-- parses chat text. The server answers with three statuses: OK (done, reason says which
-- state it landed in), PENDING (accepted, still connecting — arms a state check) and
-- ERR (row unchanged, translated reason shown). Anything else is reported as-is.
---@param action string  "CONNECT" | "DISCONNECT".
---@param entry  table   Row to act on (must have .guid).
local function CB_ArmyMutate(action, entry)
    NS.CB_Request({
        type         = action == "CONNECT" and "BOT_CONNECT" or "BOT_DISCONNECT",
        verb         = "RUN",
        args         = { entry.guid, "<token>" },   -- fresh token per attempt: they are single-use
        done         = "BOT_LIFECYCLE",
        cap          = "BOT_LIFECYCLE",
        rateKey      = "BOT_LIFECYCLE_MUTATE",
        maxPerWindow = MUTATE_MAX_PER_WINDOW,
        window       = RATE_WINDOW,
        queue        = false,     -- a button press should answer now, not silently buffer
        onDone = function(outcome, fields)
            local status, reason
            if outcome == "ok" and fields then
                -- BOT_LIFECYCLE~<token>~<guid>~<url(name)>~<action>~<OK|ERR>~<reason>
                status, reason = fields[6], fields[7]
            elseif fields and fields[1] == "ERR" then
                status, reason = "ERR", NS.CB_UrlDecode(fields[5])
            else
                status, reason = "ERR", outcome
            end

            -- Status, not reason, decides success: a connect that was accepted answers
            -- PENDING~STARTED, and only later does the row learn it is really online.
            local settledState = nil
            if status == "OK" then
                settledState = (action == "CONNECT") and NS.ALT_ARMY_ONLINE or NS.ALT_ARMY_OFFLINE
            end
            local success = (status ~= "ERR")

            if status == "PENDING" then
                CB_SetArmyRow(entry, NS.ALT_ARMY_CONNECTING, NS.CB_AltArmyReasonText(reason))
                NS.CB_After(STATE_CHECK_DELAY, function() CB_ArmyStateCheck(entry, 1) end)
            elseif settledState then
                CB_SetArmyRow(entry, settledState, nil)
            else
                -- Failed: keep the previous state, show why.
                CB_SetArmyRow(entry, nil, NS.CB_AltArmyReasonText(reason))
                if not bulkRun then
                    NS.CB_Print((entry.name or "Alt") .. ": " .. NS.CB_AltArmyReasonText(reason))
                end
            end
            CB_FinishBulkStep(success)
        end,
    })
end

-- Resolves a name that is not in the cache over the wire (GET~BOT_TARGET_RESOLVE),
-- then runs the action against the answer. Used by the Target buttons and by preset
-- invites when the alt was never part of a fetched snapshot.
-- Every exit settles a bulk step: a resolve that fails or answers without a GUID must
-- still count, or the run it belongs to waits forever and blocks every later bulk action.
---@param action string  "CONNECT" | "DISCONNECT".
---@param name   string  Character name as typed/targeted.
local function CB_ArmyResolveAndMutate(action, name)
    NS.CB_Request({
        type         = "BOT_TARGET_RESOLVE",
        args         = { NS.CB_UrlEncode(name), "<token>" },
        done         = "BOT_TARGET_RESOLVE",
        cap          = "BOT_LIFECYCLE",
        rateKey      = "BOT_LIFECYCLE_QUERY",
        maxPerWindow = QUERY_MAX_PER_WINDOW,
        window       = RATE_WINDOW,
        queue        = false,
        onDone = function(outcome, fields)
            -- BOT_TARGET_RESOLVE~<token>~<OK|ERR>~<reason>~<url(name)>~<guid>~<state>
            if outcome ~= "ok" or not fields or fields[3] ~= "OK" then
                local reason = (fields and NS.CB_UrlDecode(fields[4])) or outcome
                NS.CB_Print(name .. ": " .. NS.CB_AltArmyReasonText(reason))
                CB_FinishBulkStep(false)
                return
            end
            local resolvedName = NS.CB_UrlDecode(fields[5])
            local resolved = {
                guid  = tonumber(fields[6]),
                name  = (resolvedName ~= "") and resolvedName or name,
                state = fields[7],
            }
            if not resolved.guid then
                NS.CB_Print(name .. ": " .. NS.CB_AltArmyReasonText("BAD_GUID"))
                CB_FinishBulkStep(false)
                return
            end
            CB_ArmyMutate(action, resolved)
        end,
    })
end

-- Resolve any caller spelling into a cached row: the row itself, a guid, or a name.
---@param target table|number|string  Row, low GUID, or character name.
---@return table|nil  The cached row, or nil when unknown.
local function CB_ResolveArmyTarget(target)
    if type(target) == "table" then return target end
    if type(target) == "number" then return NS.CB_AltArmyByGuid(target) end
    if type(target) == "string" then return NS.CB_AltArmyByName(target) end
    return nil
end

-- Shared body of CB_AltArmyConnect / CB_AltArmyDisconnect.
---@param action string               "CONNECT" | "DISCONNECT".
---@param target table|number|string  Row, low GUID, or character name.
---@return boolean                    Whether an action was attempted at all.
local function CB_ArmySetPresence(action, target)
    local entry = CB_ResolveArmyTarget(target)

    if not CB_ArmyBridgeReady() then
        local name = entry and entry.name or (type(target) == "string" and target or nil)
        if not name then return false end
        CB_ArmySayCommand(action, name)     -- the one remaining text-command fallback
        return true
    end

    if entry then
        CB_ArmyMutate(action, entry)
        return true
    end

    if type(target) == "string" and target ~= "" then
        CB_ArmyResolveAndMutate(action, target)
        return true
    end
    return false
end

---Brings one alt online. Uses RUN~BOT_CONNECT when the bridge offers BOT_LIFECYCLE,
---otherwise falls back to ".playerbots bot add <name>" (SAY).
---@param target table|number|string  Row, low GUID, or character name.
---@return boolean                    Whether an action was attempted.
NS.CB_AltArmyConnect = function(target) return CB_ArmySetPresence("CONNECT", target) end

---Logs one alt out. Mirror of CB_AltArmyConnect (RUN~BOT_DISCONNECT / ".playerbots bot remove").
---@param target table|number|string  Row, low GUID, or character name.
---@return boolean                    Whether an action was attempted.
NS.CB_AltArmyDisconnect = function(target) return CB_ArmySetPresence("DISCONNECT", target) end

-- ── Bulk runs (bridge-only: no chat-command fallback for these) ──────────────

-- Sends one request per matching row, staggered so a large army stays inside the
-- server's mutation window and the client's spam protection.
---@param action string  "CONNECT" (offline rows) | "DISCONNECT" (online rows).
---@return number        How many requests were scheduled.
local function CB_ArmyBulk(action)
    if not CB_ArmyBridgeReady() then
        NS.CB_Print("Alt Army: bulk actions need the bridge (BOT_LIFECYCLE).")
        return 0
    end
    if bulkRun then
        NS.CB_Print("Alt Army: a bulk action is still running - wait for it to finish.")
        return 0
    end

    local want   = (action == "CONNECT") and NS.ALT_ARMY_OFFLINE or NS.ALT_ARMY_ONLINE
    local targets = {}
    for _, entry in ipairs(NS.altArmy.entries) do
        if entry.state == want then targets[#targets + 1] = entry end
    end
    if #targets == 0 then
        NS.CB_Print(action == "CONNECT" and "Alt Army: no offline alts to connect."
                                        or "Alt Army: no online alts to disconnect.")
        return 0
    end

    bulkRun = { action = action, total = #targets, settled = 0, ok = 0 }
    NS.CB_Print(string.format("Alt Army: %s %d alt(s)...",
        action == "CONNECT" and "connecting" or "disconnecting", #targets))
    for i, entry in ipairs(targets) do
        NS.CB_After((i - 1) * BULK_STAGGER, function() CB_ArmyMutate(action, entry) end)
    end
    return #targets
end

---Connects every cached alt that is currently offline (bridge only).
---@return number  How many requests were scheduled.
NS.CB_AltArmyConnectAllOffline = function() return CB_ArmyBulk("CONNECT") end

-- Brings a list of *names* online — what "Invite Preset" and "Invite by Name" need, since
-- presets are name lists in SavedVars while the wire wants GUIDs. Cached names go straight to
-- RUN~BOT_CONNECT; the rest resolve first. Same stagger and one-summary-line rule as the row
-- bulk runs, and the same boundary: without a bridge nothing is sent and the caller keeps its
-- chat command.
---@param names string[]  Character names to bring online.
---@return boolean        Whether the bridge took the job (false = caller falls back to SAY).
NS.CB_AltArmyConnectNames = function(names)
    if type(names) ~= "table" or #names == 0 then return false end
    if not CB_ArmyBridgeReady() then return false end
    if bulkRun then
        NS.CB_Print("Alt Army: a bulk action is still running - wait for it to finish.")
        return true     -- a run owns the queue; falling back to chat would double-add
    end

    bulkRun = { action = "CONNECT", total = #names, settled = 0, ok = 0 }
    for i, name in ipairs(names) do
        NS.CB_After((i - 1) * BULK_STAGGER, function()
            local entry = (type(name) == "string" and name ~= "")
                and NS.CB_AltArmyByName(name) or nil
            if entry then
                CB_ArmyMutate("CONNECT", entry)
            elseif type(name) == "string" and name ~= "" then
                CB_ArmyResolveAndMutate("CONNECT", name)
            else
                CB_FinishBulkStep(false)
            end
        end)
    end
    return true
end

---Logs out every cached alt that is currently online (bridge only).
---@return number  How many requests were scheduled.
NS.CB_AltArmyDisconnectAllOnline = function() return CB_ArmyBulk("DISCONNECT") end

-- ── View helpers (used by the Manage tab's Alt Army section) ─────────────────

local STATE_TEXT  = { ONLINE = "online", OFFLINE = "offline", CONNECTING = "connecting..." }
-- RGB only: the format string supplies "|cff", and WoW reads exactly 8 hex digits after
-- "|c" (AA is always ff here), so these must be 6 chars — an "ff" prefix here leaked "5e"/
-- "99" into the row text.
local STATE_COLOR = {
    ONLINE = "5ec25e", OFFLINE = "999999", CONNECTING = "e6c84b",
}

---List items for CB_CreateSelectList: class-colored name, level and presence.
---Offline rows are grayed by the list widget (item.gray); the state word carries
---the detail, so a row never depends on color alone.
---@return table  Array of { text = string, value = guid, class = token, gray = bool }.
NS.CB_AltArmyRows = function()
    local items = {}
    for _, entry in ipairs(NS.altArmy.entries) do
        local state = entry.state or NS.ALT_ARMY_OFFLINE
        items[#items + 1] = {
            text  = string.format("%s |cffaaaaaa%d|r |cff%s%s|r",
                entry.name or "?", entry.level or 0,
                STATE_COLOR[state] or "999999",
                STATE_TEXT[state] or string.lower(state)),
            value = entry.guid,
            class = entry.class,
            gray  = (state == NS.ALT_ARMY_OFFLINE),
        }
    end
    return items
end

-- "just now" / "12s ago" / "4m ago" for the snapshot timestamp.
---@param when number  GetTime() value of the snapshot.
---@return string      Age text.
local function CB_ArmyAge(when)
    local seconds = math.max(0, math.floor(GetTime() - when))
    if seconds < 5 then return "just now" end
    if seconds < 120 then return tostring(seconds) .. "s ago" end
    return tostring(math.floor(seconds / 60)) .. "m ago"
end

---Status line(s) for the section's info label: counts, partial marker, age, and
---what happens without the bridge.
---@return string  Text (may contain newlines and color codes).
NS.CB_AltArmyStatusText = function()
    local army = NS.altArmy
    if army.source ~= "bridge" then
        -- A failure has to be reported even when nothing was ever fetched. Gating on
        -- fetchedAt made a solo no-bridge refresh read as an untouched panel.
        if army.lastError then
            return "|cffffa54eRefresh failed: "
                .. (OUTCOME_TEXT[army.lastError] or tostring(army.lastError)) .. "|r"
        end
        return "|cff808080Not loaded yet - press Refresh.|r"
    end

    local lines = { string.format("%d alt(s), %d online", #army.entries, NS.CB_AltArmyOnlineCount()) }
    -- The server caps the snapshot and only says so through this flag.
    if army.truncated then
        lines[#lines + 1] = "|cffffa54ePartial list (server entry cap).|r"
    end
    if army.fetchedAt then
        lines[#lines + 1] = "|cff808080Updated " .. CB_ArmyAge(army.fetchedAt) .. ".|r"
    end
    if not CB_ArmyBridgeReady() then
        lines[#lines + 1] = "|cff808080No bridge: single-alt buttons type chat commands.|r"
    end
    return table.concat(lines, "\n")
end
