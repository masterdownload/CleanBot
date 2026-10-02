-- ============================================================
-- BridgeRpc.lua  —  MBOT wire-protocol plumbing shared by every bridge feature.
--
-- Owns the three parts of the protocol that must not be re-implemented per
-- feature:
--   * capability discovery — HELLO_ACK carries no flags; a successful HELLO is
--     answered with CAPS_BEGIN / CAPS~NAME,NAME / CAPS_END (see
--     SendCapabilitiesPackets in modules/mod-multibot-bridge/src/MultiBotBridge.cpp).
--   * inbound fan-out — features subscribe to a tag instead of appending another
--     branch to the long if/elseif chain in Bridge.lua.
--   * token-tracked requests — one place for request tokens, timeouts, server
--     ERR routing, client-side rate-limit budgets (the server allows 4 / 2 s for
--     ALT_ROSTER and 256 / 2 s for the bot-lifecycle request group) and an
--     optional no-bridge fallback callback.
--
-- Nothing here knows what a feature *means*: it moves packets and reports
-- outcomes (ok / reason). Feature adapters live in their own files.
--
-- Wire format (server constants in MultiBotBridge.cpp): envelope "MBOT\t", field
-- separator '~', whole line capped at 255 bytes.
--   HELLO~1                          -> HELLO_ACK~<version>~<bridgeName>, then CAPS_*
--   PING~<token>                     -> PONG~<token>
--   GET~/RUN~<TYPE>~[args]~<token>   -> feature packets; the token is echoed (usually field 1)
--   any protocol failure             -> ERR~<url opcode>~<url requestType>~<token>~<url reason>
-- ============================================================
local NS = CleanBotNS

local MAX_REQUEST_LENGTH = 250   -- SendAddonMessage caps a line at 255 bytes; leave headroom
local DEFAULT_TIMEOUT    = 10    -- seconds to wait for the expected packets
local CAPS_GRACE         = 2.5   -- seconds after HELLO_ACK to wait for a CAPS burst
local MAX_ERR_LOG        = 12    -- ERR packets remembered for /cbdebug caps
local RATE_WINDOW        = 2     -- seconds; the server rate-limits per 2 s window
local MAX_PENDING_REQUESTS = 32  -- safety ceiling: a stuck bridge must not grow forever

-- Set with /cbdebug rpc on: traces every RPC outcome into the chat frame.
NS.debugRpc = NS.debugRpc or false

--- Gated internal trace line (off unless /cbdebug rpc turned it on).
---@param msg string  Text to print when tracing is enabled.
NS.CB_RpcTrace = function(msg)
    if NS.debugRpc then NS.CB_Print("|cff808080rpc|r " .. msg) end
end

-- ============================================================
-- Wire splitting / URL decoding
-- ============================================================

-- Splits an inbound MBOT line into {"TAG", field1, field2, …}, keeping empty
-- fields (a trailing "~" means an empty final field, which several senders use).
---@param msg string  Message body (the "MBOT\t" envelope is stripped by the chat prefix).
---@return table      Array of fields; fields[1] is the tag.
local function CB_SplitWire(msg)
    local fields = {}
    local pos = 1
    while true do
        local sep = strfind(msg, "~", pos, true)
        if not sep then
            fields[#fields + 1] = strsub(msg, pos)
            break
        end
        fields[#fields + 1] = strsub(msg, pos, sep - 1)
        pos = sep + 1
    end
    return fields
end

-- Percent-decodes a field the server URL-encoded (ERR reasons and names).
---@param s string|nil  Encoded field.
---@return string       Decoded field ("" for nil).
local function CB_Decode(s)
    if not s then return "" end
    return ((s:gsub("%%(%x%x)", function(hex) return strchar(tonumber(hex, 16)) end)))
end

-- Effective bridge state, mirroring the local helper in Bridge.lua: a debug
-- override wins over the handshake result.
---@return string  "present" | "absent" | "unknown"
local function CB_EffectiveState()
    return NS.debugBridgeOverride or NS.bridgeState or "unknown"
end

-- Exported form of the same check, so features do not re-read bridgeState directly
-- and cannot forget the /cbdebug bridge override.
---@return boolean  Whether requests may go out on this session.
NS.CB_BridgePresent = function()
    return CB_EffectiveState() == "present"
end

-- Percent-encodes an outbound field. Mirrors UrlEncodeField in MultiBotBridge.cpp:
-- only '%', '~' and control characters are escaped ('~' is the field separator), so
-- a name containing one still arrives as a single field.
---@param s string|nil  Plain field value.
---@return string       Wire-safe value ("" for nil).
NS.CB_UrlEncode = function(s)
    if not s then return "" end
    local encoded = tostring(s):gsub("%%", "%%25")
    encoded = encoded:gsub("~", "%%7E")
    return (encoded:gsub("%c", function(c) return string.format("%%%02X", string.byte(c)) end))
end

-- Exported decoder: every field the bridge URL-encoded (names, ERR reasons) must be
-- decoded before it is compared or displayed.
---@param s string|nil  Encoded field.
---@return string       Decoded field ("" for nil).
NS.CB_UrlDecode = CB_Decode

-- ============================================================
-- Capability registry
-- ============================================================
NS.bridgeCaps         = {}    -- [CAPABILITY_NAME] = true (only after a completed burst)
NS.bridgeCapsComplete = false -- true once CAPS_END (or the grace timer) closed the burst
NS.bridgeCapsMissing  = false -- true when the bridge never sent a CAPS burst (older server)
NS.bridgeProtocol     = nil   -- protocol version echoed by HELLO_ACK, e.g. "1"
NS.bridgeName         = nil   -- bridge implementation name, e.g. "mod-multibot-bridge"

local capsChunk  = nil   -- CAPS~ chunks collected between CAPS_BEGIN and CAPS_END
local capsWaiter = {}    -- callbacks queued through CB_WhenCapsReady
local capsTimer  = 0     -- handshake generation: invalidates stale grace timers

-- Fires and clears the queued capability waiters.
local function CB_ReleaseWaiters()
    local waiters = capsWaiter
    capsWaiter    = {}
    for _, fn in ipairs(waiters) do
        local ok, err = pcall(fn, NS.bridgeCapsComplete)
        if not ok then NS.CB_RpcTrace("caps waiter error: " .. tostring(err)) end
    end
end

-- Capability names arrive versioned (ALT_ROSTER_V1, INVENTORY_EXACT_V1). Features ask for
-- the unversioned name so a bridge bumping V1→V2 does not silently disable them; an exact
-- query still works because NS.bridgeCaps keeps the raw advertised spelling.
local capAliases = {}

---@param name string  Name as advertised (or as a feature asks for it).
---@return string      The same name with a trailing _V<number> removed.
local function CB_CapKey(name)
    return (gsub(name, "_V%d+$", ""))
end

-- Drops all capability state. Called on every handshake and whenever the bridge
-- stops being present, so no feature can act on a previous session's caps.
---@param reason string|nil  Why the reset happened (recorded in NS.lastCapsReset).
NS.CB_ResetBridgeCaps = function(reason)
    NS.bridgeCaps         = {}
    for alias in pairs(capAliases) do capAliases[alias] = nil end
    NS.bridgeCapsComplete = false
    NS.bridgeCapsMissing  = false
    NS.bridgeProtocol     = nil
    NS.bridgeName         = nil
    capsChunk             = nil
    capsTimer             = capsTimer + 1
    NS.lastCapsReset      = reason or "reset"
end

-- Parses HELLO_ACK and re-arms capability collection for the new session. Must
-- run before the CAPS_* packets of the same handshake are dispatched.
---@param msg string  The raw HELLO_ACK line.
NS.CB_ParseHelloAck = function(msg)
    local fields = CB_SplitWire(msg)
    NS.CB_ResetBridgeCaps("hello")
    NS.bridgeProtocol = fields[2]
    NS.bridgeName     = fields[3]

    -- A bridge that predates capabilities answers HELLO_ACK and nothing else. Without
    -- this grace timer, features waiting on CB_WhenCapsReady would wait forever; with it
    -- they see an empty capability set and take their fallback path.
    local generation = capsTimer
    NS.CB_After(CAPS_GRACE, function()
        if generation ~= capsTimer then return end      -- superseded by a newer handshake
        if not NS.bridgeCapsComplete then
            NS.bridgeCapsMissing  = true
            NS.bridgeCapsComplete = true
            CB_ReleaseWaiters()
        end
    end)
end

-- Runs fn once the capability set is final; immediately if it already is.
---@param fn fun(complete:boolean)  true = caps are final (never "unknown").
NS.CB_WhenCapsReady = function(fn)
    if type(fn) ~= "function" then return end
    if NS.bridgeCapsComplete then fn(true) return end
    capsWaiter[#capsWaiter + 1] = fn
end

-- Adds one CAPS~ chunk (comma-separated names) to the collected set.
---@param chunk string|nil  e.g. "ALT_ROSTER_V1,BOT_LIFECYCLE_V1".
local function CB_AppendCapsChunk(chunk)
    if chunk == nil or chunk == "" then return end
    for name in gmatch(chunk, "[^,]+") do
        if name ~= "" then
            NS.bridgeCaps[name] = true
            local base = CB_CapKey(name)
            if base ~= name then capAliases[base] = name end
        end
    end
end

---@param name string  Capability name, versioned ("ALT_ROSTER_V1") or bare ("ALT_ROSTER").
---@return boolean     Whether the connected bridge advertises it (bare names match any version).
NS.CB_HasCap = function(name)
    if type(name) ~= "string" then return false end
    if NS.bridgeCaps[name] == true then return true end
    local base = CB_CapKey(name)
    return capAliases[base] ~= nil or NS.bridgeCaps[base] == true
end

-- Sorted list of the advertised capability names (for /cbdebug caps).
---@return table  Array of capability names.
NS.CB_CapList = function()
    local names = {}
    for name in pairs(NS.bridgeCaps) do names[#names + 1] = name end
    table.sort(names)
    return names
end

-- ============================================================
-- Inbound fan-out (tag subscriptions)
-- ============================================================
local tagHandlers = {}   -- [TAG] = { fn, fn, … }

-- Subscribes to one inbound tag (e.g. "ALT_ROSTER_ENTRY"). The returned function
-- removes the subscription again.
---@param tag string  Tag to match exactly (case-sensitive, as sent by the bridge).
---@param fn  fun(fields:table, msg:string)  Called with the split line (fields[1] == tag).
---@return fun()      Unsubscribe function.
NS.CB_OnBridgeTag = function(tag, fn)
    local handlers = tagHandlers[tag]
    if not handlers then
        handlers = {}
        tagHandlers[tag] = handlers
    end
    handlers[#handlers + 1] = fn
    return function()
        for i, h in ipairs(handlers) do
            if h == fn then table.remove(handlers, i) break end
        end
    end
end

-- Notifies the plain listeners of a tag. Errors are contained per listener so one
-- broken feature cannot abort dispatch (nor Bridge.lua's own packet chain).
---@return boolean  Whether anybody listened.
NS.CB_FireTag = function(tag, fields, msg)
    local handlers = tagHandlers[tag]
    if not handlers or #handlers == 0 then return false end
    for _, fn in ipairs(handlers) do
        local ok, err = pcall(fn, fields, msg)
        if not ok then NS.CB_RpcTrace("tag " .. tag .. " listener error: " .. tostring(err)) end
    end
    return true
end

-- ============================================================
-- Rate-limit budgets (client-side mirror of the server windows)
-- ============================================================
local budgets = {}   -- [key] = { times = { sendTime, … }, blockedUntil = 0 }

---@param key string  Budget key.
---@return table      The budget record for key, created on first use.
local function CB_Budget(key)
    local record = budgets[key]
    if not record then
        record = { times = {}, blockedUntil = 0 }
        budgets[key] = record
    end
    return record
end

-- Seconds a caller must still wait before key may be sent again (0 = clear).
-- Covers both the local sliding window and any server RATE_LIMIT backoff.
---@param key string            Budget key (usually the request type).
---@param maxPerWindow number|nil  Local limit to mirror (default: unlimited).
---@param window number|nil        Window in seconds that limit applies to (default 2).
---@return number                 Seconds of cooldown left.
NS.CB_RequestCooldown = function(key, maxPerWindow, window)
    local record = budgets[key]
    if not record then return 0 end

    local wait = record.blockedUntil - GetTime()
    if wait > 0 then return wait end

    if maxPerWindow and window then
        local cutoff, seen, oldest = GetTime() - window, 0, nil
        for _, sentAt in ipairs(record.times) do
            if sentAt > cutoff then
                seen = seen + 1
                if not oldest or sentAt < oldest then oldest = sentAt end
            end
        end
        if seen >= maxPerWindow and oldest then
            return math.max(0, (oldest + window) - GetTime())
        end
    end
    return 0
end

-- Records a send against the budget; called by CB_Request for every wire request.
local function CB_RecordSend(key)
    if not key then return end
    local record, now = CB_Budget(key), GetTime()
    -- Drop stale entries while collecting, so the record never grows unbounded.
    for i = #record.times, 1, -1 do
        if now - record.times[i] > RATE_WINDOW then table.remove(record.times, i) end
    end
    record.times[#record.times + 1] = now
end

-- Applies a server-side backoff (ERR~…~RATE_LIMIT or a local "too many" verdict).
---@param key string      Budget key.
---@param seconds number  How long to block the key from now.
NS.CB_BackoffRequest = function(key, seconds)
    if not key then return end
    local record = CB_Budget(key)
    record.blockedUntil = math.max(record.blockedUntil or 0, GetTime() + (tonumber(seconds) or RATE_WINDOW))
end

-- Seconds left on a server backoff for key (0 = not blocked).
---@param key string  Budget key.
---@return number     Seconds remaining.
NS.CB_BackoffRemaining = function(key)
    local record = budgets[key]
    if not record then return 0 end
    return math.max(0, (record.blockedUntil or 0) - GetTime())
end

-- ============================================================
-- Token-tracked requests
-- ============================================================
local pending      = {}   -- [token] = request record
local tokenSeq     = 0
local CB_Settle                       -- defined below, used by CB_ArmRequest above it
NS.lastBridgeErr   = nil  -- { opcode, type, token, reason, time } of the most recent ERR

---@return string  A fresh request token, unique for this client session.
local function CB_NewToken()
    tokenSeq = tokenSeq + 1
    return "R" .. tostring(tokenSeq)
end

-- Sends one wire line to the bridge. Mirrors CB_SendBridge in Bridge.lua: RAID in a raid,
-- PARTY in a party, otherwise a self-whisper. Solo is a real channel, not a dead end — the
-- account-scoped endpoints (ALT_ROSTER, BOT_CONNECT) are used precisely when nothing is
-- grouped yet, and the server answers a self-whisper like any other bridge line.
---@param line string  Message body without the "MBOT" prefix (e.g. "GET~ALT_ROSTER~R7").
local function CB_SendBridgeLine(line)
    if GetNumRaidMembers() > 0 then
        SendAddonMessage("MBOT", line, "RAID")
    elseif GetNumPartyMembers() > 0 then
        SendAddonMessage("MBOT", line, "PARTY")
    else
        SendAddonMessage("MBOT", line, "WHISPER", UnitName("player"))
        NS.CB_RpcTrace("send " .. line .. " (self-whisper)")
    end
end

-- Arms the "no answer" timer. Started when the line actually goes out, so a request
-- that waited behind a rate window is not charged for the time it spent queued.
---@param req table   Pending request record.
---@param spec table  Original request description (timeout applies from the send).
---@param line string The wire line, kept for the "no answer" trace.
local function CB_ArmTimeout(req, spec, line)
    NS.CB_After(spec.timeout or DEFAULT_TIMEOUT, function()
        if not req.settled then
            NS.CB_RpcTrace("timeout " .. line)
            CB_Settle(req, "timeout")
        end
    end)
end

-- Registers a sent request and arms its timeout. Completion happens in CB_RpcInbound.
---@param req table   Request record returned by CB_Request.
---@param spec table  Original request description (timeout / matchToken / done tags).
---@param line string The wire line, kept for the "no answer" trace.
local function CB_ArmRequest(req, spec, line)
    pending[req.token] = req
    CB_ArmTimeout(req, spec, line)
end

---@param msg string  Wire body of an ERR packet.
---@return table|nil  { opcode, type, token, reason } (reason already URL-decoded).
local function CB_ParseErr(msg)
    local fields = CB_SplitWire(msg)
    if fields[1] ~= "ERR" then return nil end
    return {
        opcode = fields[2], type = fields[3], token = fields[4],
        reason = CB_Decode(fields[5]), time = GetTime(),
    }
end

-- Settles one request: cancels its timer, fires onDone once, then forgets it.
---@param req table   Pending request record.
---@param outcome string  "ok" | "timeout" | "error" | "rate-limit" | "no-bridge" | "unsupported" | "cancelled"
---@param fields table|nil  Split packet that settled it, when there was one.
CB_Settle = function(req, outcome, fields)
    if req.settled then return end
    req.settled = true
    pending[req.token] = nil

    local ok, err = pcall(function()
        if req.onDone then req.onDone(outcome, fields) end
        if outcome ~= "ok" and outcome ~= "cancelled" then
            -- Anything the bridge could not answer is the feature's cue for its
            -- whisper path — one hook so no feature re-implements degradation.
            if req.fallback then req.fallback(outcome, fields) end
        end
    end)
    if not ok then NS.CB_RpcTrace("request " .. tostring(req.type) .. " callback error: " .. tostring(err)) end
end

-- Cancels one in-flight request — a UI closing before the answer arrives. A request
-- still waiting out a rate window is cancelled too: it never reaches the wire.
---@param req table|nil  Handle returned by CB_Request.
---@return boolean       Whether anything was cancelled.
NS.CB_CancelRequest = function(req)
    if not req or req.settled then return false end
    CB_Settle(req, "cancelled")
    return true
end

-- Cancels every in-flight request (relog, bridge lost, /cbdebug bridge reset).
---@param reason string  Outcome handed to the pending callbacks.
NS.CB_CancelPendingRequests = function(reason)
    for _, req in pairs(pending) do CB_Settle(req, reason or "cancelled") end
end

---@class CBRequestSpec
---@field type string             RequestType sent on the wire (e.g. "ALT_ROSTER").
---@field verb string|nil         "GET" (default) or "RUN".
---@field args table|nil          Positional fields; the literal "<token>" is replaced by the token.
---@field noToken boolean|nil     Do not append a token at all (ROSTER-style endpoints; also
--                                implies matchToken = false — pair it with coalesce = true,
--                                since concurrent copies of such a request cannot be told apart)
---@field done string|table|nil   Tag(s) whose arrival complete the request.
---@field tags table|nil          {[TAG] = fn} streaming handlers while the request is live.
---@field matchToken boolean|nil  Default true; false for endpoints that never echo tokens.
---@field cap string|nil          Capability required, checked against the negotiated set.
---@field rateKey string|nil      Budget key (defaults to type).
---@field maxPerWindow number|nil Client-side mirror of the server's per-window limit.
---@field window number|nil       Window for that limit (default 2 s).
---@field queue boolean|nil       false = fail fast as "rate-limit" instead of queueing.
---@field timeout number|nil      Seconds without an answer before "timeout" (default 10).
---@field coalesce boolean|nil    Reuse an identical in-flight request instead of sending twice.
---@field coalesceKey string|nil  Distinguishes coalescing groups (defaults to type).
---@field onDone fun(outcome:string, fields:table)|nil  Runs exactly once with the outcome.
---@field fallback fun(outcome:string, fields:table)|nil Runs instead when not "ok"/"cancelled".

-- Sends one tracked bridge request. Nothing goes on the wire when the bridge is absent
-- or lacks the capability: those cases go straight to onDone/fallback, so a feature can
-- degrade to its whisper path instead of hanging.
---@param spec CBRequestSpec
---@return table|nil  Request handle (has .token; cancellable via CB_CancelRequest), nil if not sent
---@return string     "sent" | "queued" | "coalesced" | "no-bridge" | "unsupported" | "rate-limit" | "too-long"
NS.CB_Request = function(spec)
    if type(spec) ~= "table" or not spec.type then return nil, "invalid" end

    local done  = spec.done
    if type(done) == "string" then done = { done } end
    local verb  = spec.verb or "GET"
    local key   = spec.rateKey or spec.type
    local token = CB_NewToken()
    -- Endpoints that echo nothing (ROSTER, ALT_ROSTER) can only be matched loosely, and a
    -- request that sends no token can never have one echoed back — so loose is the default
    -- whenever the caller does not say otherwise.
    local matchToken = spec.matchToken
    if matchToken == nil then matchToken = not spec.noToken end
    local req   = {
        type = spec.type, token = token, onDone = spec.onDone, fallback = spec.fallback,
        tags = spec.tags, done = done, rateKey = key,
        matchToken = matchToken,
        coalesceKey = spec.coalesce and (spec.coalesceKey or spec.type) or nil,
    }

    -- 1. Bridge absent or capability missing: never touch the wire.
    if CB_EffectiveState() ~= "present" then
        NS.CB_RpcTrace(spec.type .. ": no bridge (" .. CB_EffectiveState() .. ")")
        CB_Settle(req, "no-bridge")
        return nil, "no-bridge"
    end

    -- 2. Capability gate: an older bridge simply does not have the endpoint.
    if spec.cap and not NS.CB_HasCap(spec.cap) then
        NS.CB_RpcTrace(spec.type .. ": bridge lacks cap " .. tostring(spec.cap))
        CB_Settle(req, "unsupported")
        return nil, "unsupported"
    end

    -- 3. Same request already in flight: share its result instead of spending budget.
    if spec.coalesce then
        for _, other in pairs(pending) do
            if other.coalesceKey and other.coalesceKey == req.coalesceKey then
                local prevDone = other.onDone
                other.onDone = function(outcome, fields)
                    if prevDone then prevDone(outcome, fields) end
                    if spec.onDone then spec.onDone(outcome, fields) end
                end
                local prevFallback = other.fallback
                other.fallback = function(outcome, fields)
                    if prevFallback then prevFallback(outcome, fields) end
                    if spec.fallback then spec.fallback(outcome, fields) end
                end
                NS.CB_RpcTrace(spec.type .. ": coalesced onto " .. other.token)
                return other, "coalesced"
            end
        end
    end

    -- 4. Assemble the wire line; "<token>" marks where this endpoint wants the token.
    local parts, placed = { verb, spec.type }, false
    for _, arg in ipairs(spec.args or {}) do
        local value = tostring(arg)
        parts[#parts + 1] = (value == "<token>") and token or value
        if value == "<token>" then placed = true end
    end
    if not placed and not spec.noToken then parts[#parts + 1] = token end

    local line = table.concat(parts, "~")
    if #line > MAX_REQUEST_LENGTH then
        NS.CB_RpcTrace(spec.type .. ": request too long (" .. #line .. " bytes)")
        CB_Settle(req, "too-long")
        return nil, "too-long"
    end

    -- 5. Respect the rate window: send now, or settle as rate-limited when the
    --    caller asked not to queue (spec.queue == false).
    local cooldown = NS.CB_RequestCooldown(key, spec.maxPerWindow, spec.window or RATE_WINDOW)
    if cooldown > 0 then
        if spec.queue == false or NS.CB_PendingCount() >= MAX_PENDING_REQUESTS then
            NS.CB_BackoffRequest(key, cooldown)
            NS.CB_RpcTrace(spec.type .. ": rate-limited for " .. string.format("%.1f", cooldown) .. "s")
            CB_Settle(req, "rate-limit")
            return nil, "rate-limit"
        end
        -- Registered immediately so it can be cancelled or coalesced onto while it waits.
        req.queued = true
        pending[req.token] = req
        NS.CB_After(cooldown, function()
            if req.settled then return end        -- cancelled / failed while queued
            req.queued = nil
            CB_SendBridgeLine(line)
            CB_RecordSend(key)
            CB_ArmTimeout(req, spec, line)
        end)
        return req, "queued"
    end

    CB_SendBridgeLine(line)
    CB_RecordSend(key)
    CB_ArmRequest(req, spec, line)
    return req, "sent"
end

-- ============================================================
-- Inbound routing
-- ============================================================
local pongWaiter = nil   -- callback awaiting the next PONG

---@param fields table  Split packet.
---@param token string  Token to look for.
---@return boolean      Whether any field equals the token (endpoints echo it at different indices).
local function CB_HasToken(fields, token)
    if not token then return false end
    for i = 2, #fields do
        if fields[i] == token then return true end
    end
    return false
end

---@param req table   Pending request.
---@param tag string  Inbound tag.
---@return boolean    Whether this packet belongs to req.
local function CB_RequestWants(req, tag)
    if req.tags and req.tags[tag] then return true end
    if req.done then
        for _, name in ipairs(req.done) do
            if name == tag then return true end
        end
    end
    -- Requests with no declared tags are settled by the first tagged answer.
    return (not req.tags and not req.done) and tag ~= "ERR" or false
end

-- Finds the pending request an ERR belongs to when the server sent no token at all — which is what
-- the bridge does for its generic rejections (ERR~GET~FORMATIONS~~UNKNOWN_GET passes an empty one).
-- Without this the request sits out its whole timeout before the feature's whisper fallback runs.
-- Only for an EMPTY token: an ERR naming a token we do not know belongs to a request already
-- forgotten (timed out, cancelled) and must stay ignored. And only when exactly ONE in-flight
-- request has that type, so an ambiguous error can never settle the wrong one by guesswork.
---@param errType string|nil  Request type named by the ERR packet (fields[3]).
---@return table|nil          The sole matching request, or nil when none or several match.
local function CB_FindSoleRequestOfType(errType)
    if not errType or errType == "" then return nil end

    local wanted, found, matches = string.upper(errType), nil, 0
    for _, req in pairs(pending) do
        if not req.settled and not req.queued and string.upper(req.type or "") == wanted then
            matches = matches + 1
            found = req
        end
    end
    return matches == 1 and found or nil
end

-- Finds the pending request a packet answers, preferring an exact token match.
---@param tag string      Inbound tag.
---@param fields table    Split packet.
---@return table|nil      Matching request record.
local function CB_FindRequest(tag, fields)
    local fallbackMatch = nil
    for _, req in pairs(pending) do
        -- req.queued: still waiting out a rate window, so no answer can belong to it yet.
        if not req.settled and not req.queued and CB_RequestWants(req, tag) then
            -- matchToken === false: the endpoint does not echo tokens (ROSTER~).
            if req.matchToken == false then
                if not fallbackMatch then fallbackMatch = req end
            elseif CB_HasToken(fields, req.token) then
                return req
            end
        end
    end
    return fallbackMatch
end

-- Hands one inbound MBOT line to the protocol layer. Bridge.lua calls this for every
-- packet its own chain did not claim; CAPS_*, PONG and ERR are handled here entirely.
---@param msg string  Wire body without the "MBOT" prefix.
---@return boolean    Whether this layer handled (or deliberately swallowed) the line.
NS.CB_RpcInbound = function(msg)
    if type(msg) ~= "string" or msg == "" then return false end

    local fields = CB_SplitWire(msg)
    local tag    = fields[1]

    -- Capability burst (part of the handshake; never a feature response).
    if tag == "CAPS_BEGIN" then
        capsChunk = {}
        NS.CB_ResetBridgeCaps("caps")
        return true
    elseif tag == "CAPS" then
        capsChunk = capsChunk or {}
        capsChunk[#capsChunk + 1] = fields[2]
        return true
    elseif tag == "CAPS_END" then
        for _, chunk in ipairs(capsChunk or {}) do CB_AppendCapsChunk(chunk) end
        capsChunk             = nil
        NS.bridgeCapsComplete = true
        NS.CB_RpcTrace("caps: " .. table.concat(NS.CB_CapList(), ","))
        CB_ReleaseWaiters()
        return true
    elseif tag == "PONG" then
        NS.bridgeLastPong  = GetTime()
        NS.bridgePingLoss  = 0
        local waiter       = pongWaiter
        pongWaiter         = nil
        if waiter then pcall(waiter, true) end
        return true
    elseif tag == "ERR" then
        local err = CB_ParseErr(msg)
        NS.lastBridgeErr = err
        NS.CB_RpcTrace("ERR " .. tostring(err.opcode) .. " " .. tostring(err.type) .. " " .. err.reason)
        if err.reason == "RATE_LIMIT" then NS.CB_BackoffRequest(err.type or "", RATE_WINDOW) end

        local req = err.token and pending[err.token]
        if not req and (not err.token or err.token == "") then
            req = CB_FindSoleRequestOfType(err.type)
        end
        if req and not req.settled then
            CB_Settle(req, "error", fields)
        else
            NS.CB_FireTag("ERR", fields, msg)
        end
        NS.CB_FireTag("ERR~" .. tostring(err.opcode), fields, msg)
        return true
    end

    -- Feature packets: request-scoped handler first, then global subscribers.
    local req     = CB_FindRequest(tag, fields)
    local handled = false
    if req then
        handled = true
        if req.tags and req.tags[tag] then
            local ok, err = pcall(req.tags[tag], fields, msg)
            if not ok then NS.CB_RpcTrace("request " .. tostring(req.type) .. " tag error: " .. tostring(err)) end
        end
        for _, name in ipairs(req.done or {}) do
            if name == tag then CB_Settle(req, "ok", fields) break end
        end
    end

    local fired = NS.CB_FireTag(tag, fields, msg)
    return handled or fired
end

-- ============================================================
-- Liveness check
-- ============================================================
NS.bridgeLastPong = nil   -- GetTime() of the last PONG (nil = never answered)
NS.bridgePingLoss = 0     -- consecutive unanswered pings

-- Sends a PING and reports whether the bridge answered in time. One-shot on purpose:
-- nothing here polls, so an idle UI costs no addon traffic.
---@param callback fun(reachable:boolean)|nil  Receives true on PONG, false on timeout.
---@param timeout number|nil                    Seconds to wait (default 5).
NS.CB_PingBridge = function(callback, timeout)
    if CB_EffectiveState() ~= "present" then
        if callback then pcall(callback, false) end
        return
    end

    local token  = CB_NewToken()
    local done   = false
    local finish = function(reachable)
        if done then return end
        done = true
        pongWaiter = nil
        if callback then pcall(callback, reachable) end
    end

    pongWaiter = function() finish(true) end
    NS.CB_After(timeout or 5, function()
        if not done then NS.bridgePingLoss = (NS.bridgePingLoss or 0) + 1 end
        finish(false)
    end)
    CB_SendBridgeLine("PING~" .. token)
end

-- ============================================================
-- State reset and debug surface
-- ============================================================

-- Drops every bit of protocol state: called on relog and whenever the bridge stops
-- being present, so no feature can act on a previous session's caps or tokens.
---@param reason string|nil  Recorded in NS.lastCapsReset.
NS.CB_ResetRpcState = function(reason)
    NS.CB_ResetBridgeCaps(reason or "reset")
    NS.CB_CancelPendingRequests("cancelled")
    for _, record in pairs(budgets) do record.times, record.blockedUntil = {}, 0 end
    pongWaiter, NS.bridgeLastPong, NS.bridgePingLoss = nil, nil, 0
end

-- Number of requests awaiting an answer (asserted by tests, shown by /cbdebug caps).
---@return number  Pending request count.
NS.CB_PendingCount = function()
    local count = 0
    for _ in pairs(pending) do count = count + 1 end
    return count
end

-- One-line bridge summary for the Debug tab and /cbdebug caps.
---@return string  Status text (never nil).
NS.CB_BridgeStatusLine = function()
    return string.format("bridge=%s proto=%s name=%s caps=%d pending=%d",
        CB_EffectiveState(), NS.bridgeProtocol or "-", NS.bridgeName or "-",
        #NS.CB_CapList(), NS.CB_PendingCount())
end

-- Prints the protocol state to the chat frame: caps set, cooldowns, last error.
NS.CB_DebugCapsReport = function()
    NS.CB_Print(NS.CB_BridgeStatusLine())
    NS.CB_Print("caps: " .. (next(NS.bridgeCaps) and table.concat(NS.CB_CapList(), ", ") or "(none)"))

    for key, record in pairs(budgets) do
        local blocked = math.max(0, (record.blockedUntil or 0) - GetTime())
        if blocked > 0 or #record.times > 0 then
            NS.CB_Print(string.format("  %-22s sends=%d backoff=%.1fs", key, #record.times, blocked))
        end
    end

    local err = NS.lastBridgeErr
    if err then
        NS.CB_Print("last ERR: " .. tostring(err.opcode) .. " " .. tostring(err.type) .. " " .. tostring(err.reason))
    end
end
