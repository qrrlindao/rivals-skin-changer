local PREV = _G.RivalsSkins
if PREV and PREV.stop then
    pcall(PREV.stop)
end

local CFG = {
    toggleKey = 0xA1,
    dir = "rivals_skins",
    allowMisfit = true,
    rows = 14,
    startOpen = true,
}

local Players = game:GetService("Players")

-- loaded = 0x130 was found at runtime by deriveLoaded on this build (log "module-loaded field moved: 150 -> 130"); heuristic, still re-derived if it stops matching
local O = { children = 0x70, parent = 0x60, name = 0x68, primary = 0x240, scale = 0x12c, loaded = 0x130 }
-- Luau layout, checked against raw dumps from rivals_skins_diag.txt (Roblox version-2c6fd5e09aaf4cfa):
-- gcTT: GC object type tag is byte +1 (byte +0 is the mark byte); tMask: nodemask8 byte; tLsz: lsizenode byte (only used for 256+ node tables)
local L = { gcTT = 1, strLen = 0x14, strText = 0x18, tMask = 7, tLsz = 4, tSizeArr = 8, tArr = 0x20, tNode = 0x28 }

local S = {
    running = true,
    dead = false,
    stopReq = false,
    inTick = false,
    enabled = true,
    wasEnabled = false,
    status = "starting",
    statusOk = true,
    uiDirty = true,
    desired = {},
    desiredChanged = false,
    picksPending = false,
    queue = {},
    applied = {},
    over = {},
    retry = {},
    defRetry = {},
    defFails = {},
    unsafe = {},
    equipped = {},
    invWeapons = {},
    weapons = {},
    skins = {},
    skinIndex = {},
    skinsByWeapon = {},
    folders = {},
    root = nil,
    offsetsOk = false,
    loadedOk = false,
    world = 0,
    journalChecked = false,
    fpB = 0,
    fpE = 0,
    donors = nil,
    donorsAt = 0,
    catalogGrew = false,
    verifyAt = nil,
    learned = {},
    ownersTried = false,
    log = {},
}

local Core = {}
local Cos = {}
S.cos = {
    desired = { charm = {}, finisher = {} },
    applied = { charm = {}, finisher = {} },
    lists = { charm = {}, finisher = {} },
    cache = {},
    retry = {},
}
local Defs = {}
local UI = { items = {}, buttons = {}, x = 240, y = 120, open = true }

local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    local t = S.log
    t[#t + 1] = string.format("%.1f %s", os.clock(), msg)
    if #t > 300 then table.remove(t, 1) end
end

local function setStatus(ok, fmt, ...)
    local good, msg = pcall(string.format, fmt, ...)
    if not good then msg = tostring(fmt) end
    if S.status ~= msg or S.statusOk ~= ok then
        S.status = msg
        S.statusOk = ok
        S.uiDirty = true
        log("status: %s", msg)
    end
end

local function rp(a)
    return memory_read("uintptr", a) or 0
end

local function wp(a, v)
    memory_write("uintptr", a, v)
end

local function rb(a)
    return memory_read("byte", a) or 0
end

local function okp(p)
    return p ~= nil and p > 0x10000 and p < 0x7FFFFFFFFFFF
end

local function ptrOrZero(p)
    return p == 0 or okp(p)
end

local function ru32slow(a)
    return rb(a) + rb(a + 1) * 256 + rb(a + 2) * 65536 + rb(a + 3) * 16777216
end

local FAST32 = false
do
    local dm = game.Address or 0
    if dm > 0x10000 then
        local same, nonzero = true, false
        for k = 0, 7 do
            local a = dm + k * 8
            local ok, v = pcall(memory_read, "uint", a)
            if not ok or type(v) ~= "number" or v ~= ru32slow(a) then
                same = false
                break
            end
            if v ~= 0 then nonzero = true end
        end
        FAST32 = same and nonzero
    end
    S.fast32 = FAST32
    log("fast 32-bit reads: %s", tostring(FAST32))
end

local function ru32(a)
    if FAST32 then return memory_read("uint", a) or 0 end
    return ru32slow(a)
end

local function gctt(p)
    return rb(p + L.gcTT)
end

local function tlsz(t)
    local m = rb(t + L.tMask)
    if m == 0 then return 0 end
    if m < 255 then
        local n = m + 1
        local lsz = 0
        while n > 1 do
            if n % 2 ~= 0 then return nil end
            n = n / 2
            lsz += 1
        end
        return lsz
    end
    local v = rb(t + L.tLsz)
    if v >= 8 and v <= 10 then return v end
    return nil
end

local function bytes(a, n)
    local t = table.create(n)
    local i = 0
    if FAST32 then
        while i + 4 <= n do
            local w = memory_read("uint", a + i) or 0
            t[i + 1] = string.char(w % 256)
            t[i + 2] = string.char(math.floor(w / 256) % 256)
            t[i + 3] = string.char(math.floor(w / 65536) % 256)
            t[i + 4] = string.char(math.floor(w / 16777216) % 256)
            i += 4
        end
    end
    while i < n do
        t[i + 1] = string.char(rb(a + i))
        i += 1
    end
    return table.concat(t)
end

local sliceAt = os.clock()
local function breathe()
    if S.inTick and os.clock() - sliceAt > 0.004 then
        task.wait()
        sliceAt = os.clock()
    end
end

local CATEGORY = {}
local CATEGORIES = { "All", "Rifles", "Marksman", "Shotguns", "Pistols", "Heavy", "Melee", "Utility", "Charms", "Finishers" }

do
    local function cat(name, list)
        for w in string.gmatch(list, "[^|]+") do
            CATEGORY[w] = name
        end
    end
    cat("Rifles", "Assault Rifle|Burst Rifle|Energy Rifle|Permafrost|Wildcat|Distortion|Gunblade|Paintball Gun|Flamethrower")
    cat("Marksman", "Sniper|Bow|Crossbow")
    cat("Shotguns", "Shotgun|Shorty")
    cat("Pistols", "Handgun|Energy Pistols|Revolver|Uzi|Spray|Flare Gun|Exogun|Slingshot|Warper|Daggers|Glass Cannon")
    cat("Heavy", "Minigun|RPG|Grenade Launcher")
    cat("Melee", "Knife|Katana|Fists|Battle Axe|Maul|Chainsaw|Scythe|Spear|Trowel|Riot Shield")
end

local nameCache = {}
local nameCacheAt = os.clock()

local function stdstr(p)
    local size = rp(p + 0x10)
    local cap = rp(p + 0x18)
    if size == 0 or size > 128 or cap < size then return nil end
    local d = p
    if cap > 15 then
        d = rp(p)
        if not okp(d) then return nil end
    end
    return bytes(d, size)
end

local function nameFresh(inst)
    if not okp(inst) then return "" end
    local np = rp(inst + O.name)
    if not okp(np) then return "" end
    return stdstr(np) or ""
end

local function nameOf(inst)
    if not okp(inst) then return "" end
    local np = rp(inst + O.name)
    if not okp(np) then return "" end
    local c = nameCache[np]
    if c then return c end
    local s = stdstr(np) or ""
    if s ~= "" then nameCache[np] = s end
    return s
end

local function readVec(parent)
    if not okp(parent) then return nil end
    local start = rp(parent + O.children)
    if not okp(start) then return nil end
    local b, e, c = rp(start), rp(start + 8), rp(start + 16)
    if not okp(b) or e < b or c < e or (e - b) % 16 ~= 0 then return nil end
    local n = (e - b) / 16
    if n > 4096 then return nil end
    return { start = start, b = b, e = e, n = n }
end

local function kids(parent)
    local h = readVec(parent)
    if not h then return nil end
    local t = {}
    for i = 0, h.n - 1 do
        local p = rp(h.b + i * 16)
        if okp(p) then t[#t + 1] = p end
    end
    return t, h
end

local function children(parent)
    local out = {}
    local list = kids(parent)
    if not list then return out end
    for i = 1, #list do
        local n = nameOf(list[i])
        if n ~= "" then out[#out + 1] = { addr = list[i], name = n } end
    end
    return out
end

local function findChild(parent, name)
    local list = kids(parent)
    if not list then return 0 end
    for i = 1, #list do
        if nameOf(list[i]) == name then return list[i] end
    end
    return 0
end

local function parentOf(inst)
    if not okp(inst) then return 0 end
    return rp(inst + O.parent)
end

local function swapContents(a, b)
    if not okp(a) or not okp(b) or a == b then return false end
    local cs = O.children
    local ca0, ca1 = rp(a + cs), rp(a + cs + 8)
    local cb0, cb1 = rp(b + cs), rp(b + cs + 8)
    if not okp(ca0) or not okp(cb0) or not ptrOrZero(ca1) or not ptrOrZero(cb1) then return false end
    local sa = kids(a)
    local sb = kids(b)
    if not sa or not sb then return false end

    wp(a + cs, cb0)
    wp(a + cs + 8, cb1)
    wp(b + cs, ca0)
    wp(b + cs + 8, ca1)
    for i = 1, #sb do wp(sb[i] + O.parent, a) end
    for i = 1, #sa do wp(sa[i] + O.parent, b) end

    local pp = O.primary
    local pa0, pa1 = rp(a + pp), rp(a + pp + 8)
    local pb0, pb1 = rp(b + pp), rp(b + pp + 8)
    if ptrOrZero(pa0) and ptrOrZero(pa1) and ptrOrZero(pb0) and ptrOrZero(pb1) then
        wp(a + pp, pb0)
        wp(a + pp + 8, pb1)
        wp(b + pp, pa0)
        wp(b + pp + 8, pa1)
    end
    local fa = memory_read("float", a + O.scale) or 0
    local fb = memory_read("float", b + O.scale) or 0
    if fa > 0 and fb > 0 and fa ~= fb then
        memory_write("float", a + O.scale, fb)
        memory_write("float", b + O.scale, fa)
    end
    return true
end

local function swapNames(a, b)
    if not okp(a) or not okp(b) or a == b then return false end
    local na, nb = rp(a + O.name), rp(b + O.name)
    if not okp(na) or not okp(nb) then return false end
    wp(a + O.name, nb)
    wp(b + O.name, na)
    return true
end

local function swapKids(a, b)
    if not okp(a) or not okp(b) or a == b then return nil end
    local cs = O.children
    local a0, a1 = rp(a + cs), rp(a + cs + 8)
    local b0, b1 = rp(b + cs), rp(b + cs + 8)
    if not okp(a0) or not okp(b0) or a0 == b0 or not ptrOrZero(a1) or not ptrOrZero(b1) then return nil end
    local ka, kb = kids(a), kids(b)
    if not ka or not kb or #ka == 0 or #kb == 0 then return nil end
    wp(a + cs, b0)
    wp(a + cs + 8, b1)
    wp(b + cs, a0)
    wp(b + cs + 8, a1)
    for i = 1, #kb do wp(kb[i] + O.parent, a) end
    for i = 1, #ka do wp(ka[i] + O.parent, b) end
    return { a = a, b = b, ka = a0, kb = b0, ea = a1, eb = b1 }
end

local function undoKids(a, b, ka, kb, ea, eb)
    if not okp(a) or not okp(b) or not okp(ka) or not okp(kb) or not ptrOrZero(ea) or not ptrOrZero(eb) then return false end
    local cs = O.children
    if rp(a + cs) ~= kb or rp(b + cs) ~= ka then return false end
    local la, lb = kids(a) or {}, kids(b) or {}
    wp(a + cs, ka)
    wp(a + cs + 8, ea)
    wp(b + cs, kb)
    wp(b + cs + 8, eb)
    for i = 1, #la do wp(la[i] + O.parent, b) end
    for i = 1, #lb do wp(lb[i] + O.parent, a) end
    return true
end

local function validateOffsets(r)
    if parentOf(r.weapons) ~= r.viewmodels or parentOf(r.viewmodels) ~= r.assets then return false, "parent" end
    local lp = Players.LocalPlayer
    local ps = lp and lp:FindFirstChild("PlayerScripts")
    if not r.fallback and ps and ps.Address ~= r.scripts then return false, "children" end
    local list = kids(r.weapons)
    if not list or #list == 0 then return false, "weapons" end
    local seen = 0
    for i = 1, #list do
        local m = list[i]
        if nameOf(m) ~= "Unobtainable" then
            local sc = memory_read("float", m + O.scale) or 0
            local p0, p1 = rp(m + O.primary), rp(m + O.primary + 8)
            local c0, c1 = rp(m + O.children), rp(m + O.children + 8)
            if sc < 0.01 or sc > 100 or not ptrOrZero(p0) or not ptrOrZero(p1) or not okp(c0) or not ptrOrZero(c1) then
                return false, "model " .. nameOf(m)
            end
            if p0 ~= 0 then
                local p = p0
                local found = false
                for _ = 1, 8 do
                    p = parentOf(p)
                    if p == m then found = true break end
                    if not okp(p) then break end
                end
                if not found then return false, "primary part " .. nameOf(m) end
            end
            seen += 1
            if seen >= 16 then break end
        end
    end
    return seen > 0
end

local function deriveLoaded(r)
    local vms = findChild(findChild(r.scripts, "Modules"), "ViewModels")
    local list = kids(vms)
    if not list or #list == 0 then return false end
    local function test(off)
        local zero, non, val = 0, 0, nil
        for i = 1, #list do
            local v = rp(list[i] + off)
            if v == 0 then
                zero += 1
            elseif val == nil or v == val then
                val = v
                non += 1
            else
                return false, 0, 0
            end
        end
        return true, zero, non
    end
    local ok, zero, non = test(O.loaded)
    if ok and zero > 0 and non > 0 then return true end
    local found = nil
    for off = 0x100, 0x200, 8 do
        local good, z, n = test(off)
        if good and z > 0 and n > 0 then
            if found then return false end
            found = off
        end
    end
    if found then
        log("module-loaded field moved: %x -> %x", O.loaded, found)
        O.loaded = found
        return true
    end
    return ok and (non == 0 or zero > 0)
end

local function isLoaded(module)
    return S.loadedOk and okp(module) and rp(module + O.loaded) ~= 0
end

local function resolve()
    local r = { datamodel = game.Address or 0, player = 0, scripts = 0, assets = 0, viewmodels = 0, weapons = 0, fallback = false, starter = 0 }
    local lp = Players.LocalPlayer
    r.player = lp and lp.Address or 0
    local sp = game:GetService("StarterPlayer")
    local spa = sp and sp.Address or 0
    if okp(r.player) then
        r.scripts = findChild(r.player, "PlayerScripts")
        r.assets = findChild(r.scripts, "Assets")
        if r.assets ~= 0 then r.starter = findChild(spa, "StarterPlayerScripts") end
    end
    if r.assets == 0 then
        r.scripts = findChild(spa, "StarterPlayerScripts")
        r.assets = findChild(r.scripts, "Assets")
        r.fallback = true
    end
    r.viewmodels = findChild(r.assets, "ViewModels")
    r.weapons = findChild(r.viewmodels, "Weapons")
    return r
end

local function rootValid(r)
    return r ~= nil and r.viewmodels ~= 0 and r.weapons ~= 0
end

local function stillValid(r)
    if not rootValid(r) then return false end
    local lp = Players.LocalPlayer
    if r.datamodel ~= (game.Address or 0) or r.player ~= (lp and lp.Address or 0) then return false end
    if parentOf(r.weapons) ~= r.viewmodels then return false end
    if parentOf(r.viewmodels) ~= r.assets then return false end
    if parentOf(r.assets) ~= r.scripts then return false end
    if nameFresh(r.viewmodels) ~= "ViewModels" then return false end
    if r.fallback and okp(r.player) and findChild(findChild(r.player, "PlayerScripts"), "Assets") ~= 0 then return false end
    return true
end

local function journalPath()
    return CFG.dir .. "/journal.txt"
end

local function writeJournal()
    local lines = {}
    for _, ov in pairs(S.over) do
        for i = 1, #ov.writes do
            local w = ov.writes[i]
            lines[#lines + 1] = string.format("W %x %x %x", w.slot, w.orig, w.value)
        end
    end
    for _, ap in pairs(S.applied) do
        if ap.a ~= 0 then
            lines[#lines + 1] = string.format("C %x %x %x %x", ap.a, ap.b, ap.va, ap.vb)
        end
        for i = 1, #ap.names do
            local n = ap.names[i]
            lines[#lines + 1] = string.format("N %x %x %x %x", n.a, n.b, n.pa, n.pb)
        end
    end
    for _, set in pairs(S.cos.applied) do
        for _, rec in pairs(set) do
            if rec.ka then
                lines[#lines + 1] = string.format("K %x %x %x %x %x %x", rec.a, rec.b, rec.ka, rec.kb, rec.ea, rec.eb)
            end
            if rec.na then
                lines[#lines + 1] = string.format("N %x %x %x %x", rec.ma, rec.mb, rec.na, rec.nb)
            end
        end
    end
    if #lines == 0 then
        if isfile(journalPath()) then pcall(delfile, journalPath()) end
        return
    end
    local head = string.format("%s\nO %x %x %x %x %x\n", tostring(game.JobId), O.children, O.parent, O.name, O.primary, O.scale)
    pcall(writefile, journalPath(), head .. table.concat(lines, "\n") .. "\n")
end

local function undoJournal()
    if not isfile(journalPath()) then return end
    local ok, text = pcall(readfile, journalPath())
    pcall(delfile, journalPath())
    if not ok or type(text) ~= "string" then return end
    local lines = {}
    for line in string.gmatch(text, "[^\r\n]+") do lines[#lines + 1] = line end
    if #lines < 3 or lines[1] ~= tostring(game.JobId) then return end
    local o = {}
    for v in string.gmatch(lines[2], "%x+") do o[#o + 1] = tonumber(v, 16) end
    if string.sub(lines[2], 1, 2) ~= "O " or #o ~= 5 then return end
    local keep = { children = O.children, parent = O.parent, name = O.name, primary = O.primary, scale = O.scale }
    O.children, O.parent, O.name, O.primary, O.scale = o[1], o[2], o[3], o[4], o[5]
    local undone = 0
    for i = #lines, 3, -1 do
        local kind = string.sub(lines[i], 1, 1)
        local p = {}
        for v in string.gmatch(string.sub(lines[i], 3), "%x+") do p[#p + 1] = tonumber(v, 16) end
        if kind == "W" and #p == 3 then
            if okp(p[1]) and rp(p[1]) == p[3] then
                wp(p[1], p[2])
                undone += 1
            end
        elseif kind == "C" and #p == 4 then
            if okp(p[1]) and okp(p[2]) and rp(p[1] + O.children) == p[4] and rp(p[2] + O.children) == p[3] then
                if swapContents(p[1], p[2]) then undone += 1 end
            end
        elseif kind == "N" and #p == 4 then
            if okp(p[1]) and okp(p[2]) and rp(p[1] + O.name) == p[4] and rp(p[2] + O.name) == p[3] then
                if swapNames(p[1], p[2]) then undone += 1 end
            end
        elseif kind == "K" and #p == 6 then
            if undoKids(p[1], p[2], p[3], p[4], p[5], p[6]) then undone += 1 end
        end
    end
    for k, v in pairs(keep) do O[k] = v end
    log("undid %d changes left by an earlier session", undone)
end

local function savePicks()
    local names = {}
    for w in pairs(S.desired) do names[#names + 1] = w end
    table.sort(names)
    local parts = {}
    for i = 1, #names do parts[#parts + 1] = names[i] .. ":" .. S.desired[names[i]] end
    pcall(writefile, CFG.dir .. "/picks.txt", table.concat(parts, "|"))
end

local function loadPicks()
    if not isfile(CFG.dir .. "/picks.txt") then return end
    local ok, text = pcall(readfile, CFG.dir .. "/picks.txt")
    if not ok or type(text) ~= "string" then return end
    for item in string.gmatch(text, "[^|]+") do
        local c = string.find(item, ":", 1, true)
        if c and c > 1 and c < #item then
            S.desired[string.sub(item, 1, c - 1)] = string.sub(item, c + 1)
        end
    end
    if next(S.desired) then S.desiredChanged = true end
end

local function saveCos()
    local lines = {}
    for kind, set in pairs(S.cos.desired) do
        for from, to in pairs(set) do
            lines[#lines + 1] = kind .. "\t" .. from .. "\t" .. to
        end
    end
    table.sort(lines)
    pcall(writefile, CFG.dir .. "/cosmetics.txt", table.concat(lines, "\n"))
end

local function loadCos()
    if not isfile(CFG.dir .. "/cosmetics.txt") then return end
    local ok, text = pcall(readfile, CFG.dir .. "/cosmetics.txt")
    if not ok or type(text) ~= "string" then return end
    for line in string.gmatch(text, "[^\r\n]+") do
        local kind, from, to = string.match(line, "^(%a+)\t([^\t]+)\t([^\t]+)$")
        if kind and S.cos.desired[kind] and from ~= to then
            S.cos.desired[kind][from] = to
            S.desiredChanged = true
        end
    end
end

function Core.scan()
    S.scanAt = os.clock()
    local r = S.root
    local weapons = {}
    local skins = {}
    if rootValid(r) then
        local wk = children(r.weapons)
        for i = 1, #wk do
            if wk[i].name ~= "Unobtainable" then weapons[#weapons + 1] = wk[i].name end
        end
        table.sort(weapons)
        local wset = {}
        for i = 1, #weapons do wset[weapons[i]] = true end

        local seen = {}
        local folders = children(r.viewmodels)
        for f = 1, #folders do
            local folder = folders[f]
            if folder.name ~= "Weapons" and folder.name ~= "WIP" and folder.name ~= "Unobtainable" then
                local h = readVec(folder.addr)
                if h then
                    local fc = S.folders[folder.addr]
                    if not (fc and fc.b == h.b and fc.e == h.e) then
                        fc = { b = h.b, e = h.e, names = {} }
                        local list = children(folder.addr)
                        for i = 1, #list do fc.names[#fc.names + 1] = list[i].name end
                        breathe()
                    end
                    for i = 1, #fc.names do
                        local n = fc.names[i]
                        local si = { name = n, folder = folder.name, weapon = "" }
                        if wset[folder.name] then
                            si.weapon = folder.name
                        elseif S.learned[n] and wset[S.learned[n]] then
                            si.weapon = S.learned[n]
                        else
                            local best = 0
                            for k = 1, #weapons do
                                local w = weapons[k]
                                if #n > #w + 1 and #w > best and string.sub(n, -#w) == w and string.sub(n, -#w - 1, -#w - 1) == " " then
                                    si.weapon = w
                                    best = #w
                                end
                            end
                        end
                        skins[#skins + 1] = si
                    end
                    seen[folder.addr] = fc
                end
            end
        end
        S.folders = seen
    end

    table.sort(skins, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        local x = a.folder == a.weapon and 1 or 0
        local y = b.folder == b.weapon and 1 or 0
        return x > y
    end)
    local uniq = {}
    for i = 1, #skins do
        if i == 1 or skins[i].name ~= skins[i - 1].name then uniq[#uniq + 1] = skins[i] end
    end
    skins = uniq

    local changed = #weapons ~= #S.weapons or #skins ~= #S.skins
    if not changed then
        for i = 1, #weapons do
            if weapons[i] ~= S.weapons[i] then changed = true break end
        end
    end
    if not changed then
        for i = 1, #skins do
            if skins[i].name ~= S.skins[i].name or skins[i].folder ~= S.skins[i].folder then changed = true break end
        end
    end
    if not changed then return end

    local index = {}
    local byWeapon = {}
    for i = 1, #skins do
        index[skins[i].name] = skins[i]
        local w = skins[i].weapon
        if w ~= "" then
            local t = byWeapon[w]
            if not t then t = {} byWeapon[w] = t end
            t[#t + 1] = skins[i].name
        end
    end
    S.weapons = weapons
    S.skins = skins
    S.skinIndex = index
    S.skinsByWeapon = byWeapon
    S.catalogGrew = true
    S.uiDirty = true
    log("catalog: %d weapons, %d skins", #weapons, #skins)
end

local EFFECT_FOLDERS = {
    "Misc/MuzzleFlashes", "Misc/SmokeClouds", "Misc/BurningEffects", "Misc/MolotovExplosionEffects",
    "Misc/FlamethrowerFlames", "Misc/FlamethrowerAirblasts", "Misc/DeflectHitEffects",
    "Misc/DeflectActiveEffects", "Misc/BlipEffects", "Misc/ChainsawParticles", "Misc/WarHornEffects",
    "Projectiles", "Throwables",
}

local function effectFolder(path)
    local at = S.root.assets
    for part in string.gmatch(path, "[^/]+") do
        if at == 0 then break end
        at = findChild(at, part)
    end
    return at
end

local cfCache = {}

local function codeVms()
    local r = S.root
    local c = cfCache.vms
    if c and c.root == r and okp(c.addr) and os.clock() - c.at < 5 and nameFresh(c.addr) == "ViewModels" then
        return c.addr
    end
    local addr = findChild(findChild(r.scripts, "Modules"), "ViewModels")
    cfCache.vms = { root = r, addr = addr, at = os.clock() }
    return addr
end

local function codeFolder(weapon)
    local vms = codeVms()
    if vms == 0 then return 0 end
    local r = S.root
    local now = os.clock()
    local c = cfCache[weapon]
    if c and c.root == r and c.vms == vms and now - c.at < 1.5 and okp(c.addr)
        and parentOf(c.addr) == vms and nameFresh(c.addr) == c.name then
        return c.addr
    end
    local name = "Base" .. weapon
    local addr = findChild(vms, name)
    if addr == 0 then
        name = weapon
        addr = findChild(vms, name)
    end
    cfCache[weapon] = { root = r, vms = vms, addr = addr, name = name, at = now }
    return addr
end

local function buildDonors()
    local idx = {}
    local budget = 60000
    local count = 0
    local function walk(inst, depth)
        if depth > 8 or budget < 0 or S.stopReq then return end
        local list = kids(inst)
        if not list then return end
        for i = 1, #list do
            budget -= 1
            if budget < 0 then return end
            local c = list[i]
            local n = nameOf(c)
            if n ~= "" then
                local t = idx[n]
                if not t then
                    t = {}
                    idx[n] = t
                    count += 1
                end
                t[#t + 1] = c
                walk(c, depth + 1)
            end
        end
        breathe()
    end
    walk(S.root.starter, 0)
    S.donors = idx
    S.donorsAt = os.clock()
    S.donorMissed = false
    log("%d donor names indexed", count)
end

local function donorInUse(inst)
    for _, ap in pairs(S.applied) do
        for i = 1, #ap.names do
            if ap.names[i].a == inst or ap.names[i].b == inst then return true end
        end
    end
    return false
end

local function donor(name, pending)
    local r = S.root
    if r.starter == 0 or r.fallback or not S.donors then return 0 end
    local list = S.donors[name]
    if list then
        for i = 1, #list do
            local d = list[i]
            local busy = donorInUse(d)
            if not busy then
                for k = 1, #pending do
                    if pending[k].a == d or pending[k].b == d then busy = true break end
                end
            end
            if not busy and nameFresh(d) == name then
                local p = d
                for _ = 1, 12 do
                    if p == 0 or p == r.starter then break end
                    p = parentOf(p)
                end
                if p == r.starter then return d end
            end
        end
    end
    if not S.donorRetry and S.inTick and not S.stopReq and os.clock() - S.donorsAt >= 3 then
        S.donorRetry = true
        buildDonors()
        local d = donor(name, pending)
        S.donorRetry = false
        return d
    end
    S.donorMissed = true
    return 0
end

local function recordSwap(a, b, out)
    local pa, pb = rp(a + O.name), rp(b + O.name)
    if not swapNames(a, b) then return false end
    out[#out + 1] = { a = a, b = b, pa = pa, pb = pb }
    return true
end

local function redirectName(folder, key, pick, toDefault, out, missed)
    if folder == 0 or key == pick then return false end
    local k, p = findChild(folder, key), findChild(folder, pick)
    if k ~= 0 and p ~= 0 then return recordSwap(k, p, out) end
    local want = p ~= 0 or (k ~= 0 and toDefault and findChild(folder, "Default") ~= 0)
    if not want then return false end
    local d = donor(p ~= 0 and key or pick, out)
    if d == 0 then
        missed[#missed + 1] = nameOf(folder)
        log("%s: no spare \"%s\" name left to lend, %s keeps its own here", nameOf(folder), p ~= 0 and key or pick, key)
        return false
    end
    return recordSwap(p ~= 0 and p or k, d, out)
end

local function isDefaultCodeFolder(folder, weapon, key)
    return folder ~= 0 and key == weapon and nameOf(folder) == weapon and findChild(folder, key) == 0
end

local function redirectCode(folder, weapon, key, pick, out, missed)
    if folder == 0 or key == pick then return false, false end
    if not isDefaultCodeFolder(folder, weapon, key) then
        local k, p = findChild(folder, key), findChild(folder, pick)
        if k ~= 0 and p == 0 and key ~= weapon then
            local d = donor(pick, out)
            if d == 0 then
                missed[#missed + 1] = nameOf(folder)
                log("%s: no spare \"%s\" name left to lend, %s keeps its own code", nameOf(folder), pick, key)
                return false, false
            end
            return recordSwap(k, d, out), false
        end
        return redirectName(folder, key, pick, false, out, missed), false
    end
    local p = findChild(folder, pick)
    if p == 0 then return false, false end
    if not isLoaded(p) then
        log("%s code is not loaded by the game yet; the default %s keeps its own code until it is", pick, weapon)
        return false, true
    end
    return recordSwap(folder, p, out), false
end

local function missingNeededPart(weapon, base, pick)
    if weapon == "Flare Gun" then
        if findChild(findChild(base, "ItemVisual"), "Shell") ~= 0 and findChild(findChild(pick, "ItemVisual"), "Shell") == 0 then
            return true
        end
    end
    return false
end

local function templates(weapon, skin)
    local si = S.skinIndex[skin]
    if not si then return 0, 0 end
    local base = findChild(S.root.weapons, weapon)
    local pick = findChild(findChild(S.root.viewmodels, si.folder), skin)
    local ap = S.applied[weapon]
    if ap and ap.skin == skin and ap.a ~= 0 and rp(ap.a + O.children) == ap.vb then
        base = ap.b
        pick = ap.a
    end
    return base, pick
end

local function missingNeededPartByName(weapon, skin)
    local base, pick = templates(weapon, skin)
    return base ~= 0 and pick ~= 0 and missingNeededPart(weapon, base, pick)
end

local UNNAMED = { MeshPart = true, Primary = true, Part = true, _charm_attachment_model = true }

local function modelFits(weapon, skin)
    if not S.skinIndex[skin] then return false end
    local base, pick = templates(weapon, skin)
    if base == 0 or pick == 0 then return false end
    if weapon == "Medkit" then
        local tops = children(base)
        for i = 1, #tops do
            if not UNNAMED[tops[i].name] and findChild(pick, tops[i].name) == 0 then return false end
        end
    end
    if missingNeededPart(weapon, base, pick) then return false end
    return skin ~= "Keynade"
end

function Core.restoreOverride(weapon)
    local ov = S.over[weapon]
    if not ov then return end
    Defs.restore(ov.writes)
    S.over[weapon] = nil
end

function Core.restoreSwaps(weapon)
    local ap = S.applied[weapon]
    if not ap then return end
    if ap.a ~= 0 and rp(ap.a + O.children) == ap.vb and rp(ap.b + O.children) == ap.va then
        swapContents(ap.a, ap.b)
    end
    for i = #ap.names, 1, -1 do
        local n = ap.names[i]
        if rp(n.a + O.name) == n.pb and rp(n.b + O.name) == n.pa then
            swapNames(n.a, n.b)
        end
        if rp(n.a + O.name) ~= n.pa or rp(n.b + O.name) ~= n.pb then
            log("%s: names not back after undo: %s / %s", weapon, nameFresh(n.a), nameFresh(n.b))
        end
    end
    S.applied[weapon] = nil
end

function Core.restore(weapon)
    Core.restoreOverride(weapon)
    Core.restoreSwaps(weapon)
end

function Core.restoreAll()
    local names = {}
    for w in pairs(S.applied) do names[#names + 1] = w end
    for w in pairs(S.over) do names[#names + 1] = w end
    for i = 1, #names do Core.restore(names[i]) end
    Cos.undoAll()
end

local function undoNames(list)
    for i = #list, 1, -1 do swapNames(list[i].a, list[i].b) end
end

function Core.apply(weapon, skinName)
    local info = S.skinIndex[skinName]
    if not info then
        setStatus(false, "%s is not loaded yet", skinName)
        return false
    end

    local base = ""
    local eq = S.equipped[weapon]
    if eq and eq ~= "" and S.skinIndex[eq] then base = eq end

    if base == skinName then
        Core.restoreSwaps(weapon)
        S.applied[weapon] = { weapon = weapon, skin = skinName, base = base, a = 0, b = 0, va = 0, vb = 0, names = {}, missed = {}, code = false, codeWait = false, codePrime = false, codeModule = 0 }
        setStatus(true, "%s is already equipped on %s", skinName, weapon)
        return true
    end

    local cur = S.applied[weapon]
    if cur and cur.skin == skinName and cur.base == base then return true end

    local kick = {}
    for w, ap in pairs(S.applied) do
        if ap.skin == skinName and w ~= weapon then kick[#kick + 1] = w end
    end
    for i = 1, #kick do Core.restoreSwaps(kick[i]) end
    Core.restoreSwaps(weapon)

    local r = S.root
    local wep
    if base == "" then
        wep = findChild(r.weapons, weapon)
    else
        wep = findChild(findChild(r.viewmodels, S.skinIndex[base].folder), base)
    end
    if wep == 0 then
        setStatus(false, "%s template not found", base == "" and weapon or base)
        return false
    end
    local skin = findChild(findChild(r.viewmodels, info.folder), skinName)
    if skin == 0 then
        setStatus(false, "%s is not loaded yet", skinName)
        return false
    end

    local rec = { weapon = weapon, skin = skinName, base = base, a = 0, b = 0, va = 0, vb = 0, names = {}, missed = {}, code = false, codeWait = false, codePrime = false, codeModule = 0 }
    local key = base == "" and weapon or base
    local folder = codeFolder(weapon)
    local codeModule = findChild(folder, skinName)
    local defaultFolder = isDefaultCodeFolder(folder, weapon, key)
    local keyModule = not defaultFolder and key ~= weapon and findChild(folder, key) ~= 0

    local okCode, wait = redirectCode(folder, weapon, key, skinName, rec.names, rec.missed)
    rec.codeWait = wait
    if okCode then
        rec.code = true
        log("%s code runs as %s", skinName, key)
    end
    if (codeModule ~= 0 or keyModule) and not rec.code and not (defaultFolder and rec.codeWait) then
        undoNames(rec.names)
        S.unsafe[weapon] = true
        log("%s -> %s: its code cannot run as %s, so nothing is applied (no half sets)", weapon, skinName, key)
        setStatus(false, "%s: its code cannot run as %s here - not applied (a half set can remove the weapon)", skinName, key)
        return false
    end
    S.unsafe[weapon] = nil
    rec.codePrime = base ~= "" and codeModule ~= 0 and not isLoaded(codeModule) and isDefaultCodeFolder(folder, weapon, weapon)
    if rec.codeWait or rec.codePrime then rec.codeModule = codeModule end

    local va = rp(wep + O.children)
    local vb = rp(skin + O.children)
    if not swapContents(wep, skin) then
        undoNames(rec.names)
        setStatus(false, "%s: the client refused the swap", skinName)
        return false
    end
    rec.a = wep
    rec.b = skin
    rec.va = va
    rec.vb = vb
    S.applied[weapon] = rec
    writeJournal()

    local effects = 0
    for i = 1, #EFFECT_FOLDERS do
        if redirectName(effectFolder(EFFECT_FOLDERS[i]), key, skinName, true, rec.names, rec.missed) then
            effects += 1
            log("%s: %s effects follow %s", EFFECT_FOLDERS[i], key, skinName)
        end
    end
    local missed = #rec.missed
    writeJournal()

    local via = base == "" and weapon or base
    if rec.codeWait then
        setStatus(true, "%s on the default %s - respawn to see it", skinName, weapon)
    elseif S.equipped[weapon] == nil then
        setStatus(true, "%s on %s - hold %s once, then re-equip", skinName, weapon, weapon)
    elseif missed > 0 then
        setStatus(true, "%s via %s (%d effect sets, %d kept as %s: no spare name) - respawn to see it", skinName, via, effects, missed, via)
    else
        setStatus(true, "%s via %s (%d effect sets) - respawn to see it", skinName, via, effects)
    end
    return true
end

function Core.checkSwaps()
    local stale = {}
    for w, ap in pairs(S.applied) do
        local what = nil
        if ap.a ~= 0 and (rp(ap.a + O.children) ~= ap.vb or rp(ap.b + O.children) ~= ap.va) then what = "model" end
        if not what then
            for i = 1, #ap.names do
                local n = ap.names[i]
                if rp(n.a + O.name) ~= n.pb or rp(n.b + O.name) ~= n.pa then what = "name" break end
            end
        end
        if what == "model" and (rp(ap.a + O.children) == 0 or rp(ap.b + O.children) == 0) then what = nil end
        if what then
            log("self-check: %s -> %s: a %s swap is no longer in place, redoing", w, ap.skin, what)
            stale[#stale + 1] = w
        end
    end
    for i = 1, #stale do
        Core.restoreSwaps(stale[i])
        S.retry[stale[i]] = nil
    end
    local loaded = {}
    for w, ap in pairs(S.applied) do
        if ap.codeWait and ap.codeModule ~= 0 and isLoaded(ap.codeModule) then loaded[#loaded + 1] = w end
    end
    for i = 1, #loaded do
        log("self-check: %s code is loaded now, redoing %s", S.applied[loaded[i]].skin, loaded[i])
        Core.restoreSwaps(loaded[i])
        S.retry[loaded[i]] = nil
    end
    for w, ap in pairs(S.applied) do
        if ap.codePrime and ap.codeModule ~= 0 and isLoaded(ap.codeModule) then
            ap.codePrime = false
            setStatus(true, "%s code is loaded - switch back to the default %s now (it stays loaded until you leave this server)", ap.skin, w)
        end
    end
    return #stale > 0 or #loaded > 0
end

local function defKey(weapon)
    local eq = S.equipped[weapon]
    if eq and eq ~= "" then return eq end
    return weapon
end

local SKIN_CODED = { Daggers = true, Crossbow = true, Chainsaw = true, RPG = true, Slingshot = true, Gunblade = true }

local function blocked(weapon, skin, force)
    local eq = defKey(weapon)
    local ap = S.applied[weapon]
    local swapped = ap and ap.skin == skin and ap.code
    if swapped or eq == skin then return false end
    local folder = codeFolder(weapon)
    local pick = findChild(folder, skin)
    if not SKIN_CODED[weapon] then
        if not CFG.allowMisfit and missingNeededPartByName(weapon, skin) and not (pick ~= 0 and isLoaded(pick)) then
            if force then
                setStatus(false, "%s can't go on the default %s: the default code waits for a part it doesn't have. It works over a %s skin you own once its code is loaded", skin, weapon, weapon)
            end
            return true
        end
        if pick == 0 or not isDefaultCodeFolder(folder, weapon, eq) or isLoaded(pick) or CFG.allowMisfit or modelFits(weapon, skin) then
            return false
        end
        if force then
            setStatus(false, "%s needs its code loaded first: equip an owned %s skin with it picked, hold it once, then go back to the default", skin, weapon)
        end
        return true
    end
    if pick == 0 or not isDefaultCodeFolder(folder, weapon, eq) or isLoaded(pick) then return false end
    if force then
        setStatus(false, "%s needs its code loaded first: equip an owned %s skin with %s picked, hold it once, then go back to the default %s", skin, weapon, skin, weapon)
    end
    return true
end

function Core.applyDefs(weapon, skin)
    local from = defKey(weapon)
    Core.restoreOverride(weapon)
    if from == skin then
        S.over[weapon] = { skin = skin, from = from, writes = {}, verifiedAt = os.clock() }
        return true, false
    end
    setStatus(true, "loading %s animations and sounds (the menu pauses for a few seconds)...", skin)
    S.uiDirty = true
    task.wait(0.05)
    local writes, why = Defs.redirect(from, skin)
    if not writes then
        setStatus(false, "%s: %s", skin, why)
        log("definition redirect %s -> %s failed: %s", from, skin, why)
        return false, why == "definitions not loaded yet"
    end
    log("definition redirect %s -> %s (%d entries)", from, skin, #writes)
    S.over[weapon] = { skin = skin, from = from, writes = writes, verifiedAt = os.clock() }
    writeJournal()
    setStatus(true, "%s is on %s with its animations and sounds - respawn to see it", skin, weapon)
    return true, false
end

function Core.reconcile(force)
    local changed = force
    local desired = {}
    for w, s in pairs(S.desired) do desired[w] = s end

    local drop = {}
    for w, ap in pairs(S.applied) do
        if desired[w] ~= ap.skin then drop[w] = true end
    end
    for w, ov in pairs(S.over) do
        if desired[w] ~= ov.skin then drop[w] = true end
    end
    for w in pairs(drop) do
        Core.restore(w)
        changed = true
    end

    if S.root.starter ~= 0 and not S.root.fallback and next(desired) then
        if not S.donors or (S.donorMissed and os.clock() - S.donorsAt >= 3) then buildDonors() end
        if S.stopReq then return end
    end

    local now = os.clock()
    for w, skin in pairs(desired) do
        if blocked(w, skin, force) then
            if S.applied[w] or S.over[w] then
                Core.restore(w)
                changed = true
            end
        elseif not S.applied[w] then
            local r = S.retry[w]
            if not r then
                r = { attempts = 0, next = now }
                S.retry[w] = r
            end
            if force or (r.attempts < 10 and now >= r.next) then
                if Core.apply(w, skin) then
                    S.retry[w] = { attempts = 0, next = now }
                else
                    r.attempts += 1
                    r.next = now + 1.5
                end
                if S.unsafe[w] and S.retry[w] then S.retry[w].attempts = 10 end
                changed = true
            end
        end
    end

    for w, skin in pairs(desired) do
        if S.stopReq then break end
        if not blocked(w, skin, false) then
            local ap = S.applied[w]
            if not ap or ap.skin ~= skin then
                if S.over[w] then
                    Core.restoreOverride(w)
                    changed = true
                end
            else
                local ov = S.over[w]
                local on = ov ~= nil and ov.skin == skin and ov.from == defKey(w) and Defs.stillApplied(ov.writes)
                if on and ov.stale then on = false end
                if not on then
                    local fails = S.defFails[w] or 0
                    local due = S.defRetry[w] or now
                    if (force and fails == 0) or now >= due then
                        local ok, soon = Core.applyDefs(w, skin)
                        if ok then
                            S.defFails[w] = 0
                            S.defRetry[w] = now
                        else
                            S.defFails[w] = fails + 1
                            S.defRetry[w] = os.clock() + (fails >= 2 and 120 or (soon and 10 or 30))
                        end
                        changed = true
                    end
                end
            end
        end
    end

    if changed then
        writeJournal()
        S.uiDirty = true
    end
end

function Core.reset(why)
    local r = S.root
    if r and r.datamodel ~= 0 and r.datamodel == (game.Address or 0) then
        for _, ap in pairs(S.applied) do
            if ap.a ~= 0 and rp(ap.a + O.children) == ap.vb and rp(ap.b + O.children) == ap.va then
                swapContents(ap.a, ap.b)
            end
            for i = #ap.names, 1, -1 do
                local n = ap.names[i]
                if rp(n.a + O.name) == n.pb and rp(n.b + O.name) == n.pa then swapNames(n.a, n.b) end
            end
        end
    end
    if r and r.datamodel ~= 0 and r.datamodel == (game.Address or 0) then
        Cos.undoAll()
    else
        S.cos.applied = { charm = {}, finisher = {} }
    end
    S.cos.cache = {}
    S.cos.retry = {}
    S.applied = {}
    S.retry = {}
    S.folders = {}
    S.fpB, S.fpE = 0, 0
    S.defRetry = {}
    S.defFails = {}
    S.donors = nil
    S.root = nil
    S.offsetsOk = false
    nameCache = {}
    writeJournal()
    S.uiDirty = true
    log("asset root reset (%s)", why)
end

function Cos.folders(kind)
    if kind == "charm" then
        local r = S.root
        return findChild(r.assets, "Charms"), findChild(findChild(r.scripts, "Modules"), "Charms")
    end
    local rs = game:GetService("ReplicatedStorage")
    return findChild(findChild(rs and rs.Address or 0, "Modules"), "Finishers"), 0
end

function Cos.scan()
    for _, kind in ipairs({ "charm", "finisher" }) do
        local folder = Cos.folders(kind)
        local h = readVec(folder)
        local c = S.cos.cache[kind]
        if h and not (c and c.b == h.b and c.e == h.e) then
            local names = {}
            local list = children(folder)
            for i = 1, #list do names[#names + 1] = list[i].name end
            table.sort(names)
            S.cos.cache[kind] = { b = h.b, e = h.e }
            S.cos.lists[kind] = names
            S.uiDirty = true
            log("%d %ss found", #names, kind)
            breathe()
        end
    end
end

function Cos.inPlace(rec)
    if rec.ka and (rp(rec.a + O.children) ~= rec.kb or rp(rec.b + O.children) ~= rec.ka) then return false end
    if rec.na and (rp(rec.ma + O.name) ~= rec.nb or rp(rec.mb + O.name) ~= rec.na) then return false end
    return true
end

function Cos.undo(kind, from)
    local rec = S.cos.applied[kind][from]
    if not rec then return end
    if rec.ka then undoKids(rec.a, rec.b, rec.ka, rec.kb, rec.ea, rec.eb) end
    if rec.na and rp(rec.ma + O.name) == rec.nb and rp(rec.mb + O.name) == rec.na then
        swapNames(rec.ma, rec.mb)
    end
    S.cos.applied[kind][from] = nil
end

function Cos.undoAll()
    for kind, set in pairs(S.cos.applied) do
        local names = {}
        for from in pairs(set) do names[#names + 1] = from end
        for i = 1, #names do Cos.undo(kind, names[i]) end
    end
end

function Cos.busy(kind, from, to)
    for f, rec in pairs(S.cos.applied[kind]) do
        if f ~= from and (f == to or rec.to == from or rec.to == to) then return true end
    end
    return false
end

function Cos.apply(kind, from, to)
    local folder, mods = Cos.folders(kind)
    if folder == 0 then return false, "the " .. kind .. " folder is not loaded yet" end
    local a, b = findChild(folder, from), findChild(folder, to)
    if a == 0 or b == 0 then return false, (a == 0 and from or to) .. " is not loaded yet" end
    local rec = { to = to }
    if kind == "finisher" then
        local na, nb = rp(a + O.name), rp(b + O.name)
        if not swapNames(a, b) then return false, "the client refused the swap" end
        rec.ma, rec.mb, rec.na, rec.nb = a, b, na, nb
    else
        if mods ~= 0 then
            local ma, mb = findChild(mods, from), findChild(mods, to)
            if ma ~= 0 and mb ~= 0 then
                local na, nb = rp(ma + O.name), rp(mb + O.name)
                if swapNames(ma, mb) then
                    rec.ma, rec.mb, rec.na, rec.nb = ma, mb, na, nb
                end
            end
        end
        local k = swapKids(a, b)
        if not k then
            if rec.na then swapNames(rec.ma, rec.mb) end
            return false, "the client refused the swap"
        end
        rec.a, rec.b, rec.ka, rec.kb, rec.ea, rec.eb = k.a, k.b, k.ka, k.kb, k.ea, k.eb
    end
    S.cos.applied[kind][from] = rec
    return true
end

function Cos.reconcile(force)
    local changed = false
    local now = os.clock()
    for _, kind in ipairs({ "charm", "finisher" }) do
        local desired = S.cos.desired[kind]
        local applied = S.cos.applied[kind]
        local drop = {}
        for from, rec in pairs(applied) do
            if desired[from] ~= rec.to or not Cos.inPlace(rec) then drop[#drop + 1] = from end
        end
        for i = 1, #drop do
            Cos.undo(kind, drop[i])
            if desired[drop[i]] == nil then setStatus(true, "%s restored", drop[i]) end
            changed = true
        end
        for from, to in pairs(desired) do
            local key = kind .. "\t" .. from
            if not applied[from] and (force or now >= (S.cos.retry[key] or 0)) then
                if Cos.busy(kind, from, to) then
                    S.cos.retry[key] = now + 2
                    if force then setStatus(false, "%s or %s is already part of another %s swap - clear that one first", from, to, kind) end
                else
                    local ok, why = Cos.apply(kind, from, to)
                    if ok then
                        changed = true
                        S.cos.retry[key] = nil
                        if kind == "charm" then
                            setStatus(true, "%s now shows as %s - respawn to see it", from, to)
                        else
                            setStatus(true, "%s now plays as %s on your next elimination", from, to)
                        end
                    else
                        S.cos.retry[key] = now + 2
                        if force then setStatus(false, "%s -> %s: %s", from, to, tostring(why)) end
                    end
                end
            end
        end
    end
    if changed then S.uiDirty = true end
    return changed
end

local strCache = {}
local strCacheAt = os.clock()

local function tstr(p)
    if not okp(p) then return nil end
    local c = strCache[p]
    if c then return c end
    local len = ru32(p + L.strLen)
    if len == 0 or len > 64 then return nil end
    local s = bytes(p + L.strText, len)
    strCache[p] = s
    return s
end

local function tfind(t, key)
    if not okp(t) then return nil end
    local lsz = tlsz(t)
    if not lsz or lsz > 10 then return nil end
    local node = rp(t + L.tNode)
    if not okp(node) then return nil end
    for i = 0, 2 ^ lsz - 1 do
        local n = node + i * 32
        local kp = rp(n + 16)
        if okp(kp) then
            local ktt = rb(n + 28) % 16
            if gctt(kp) == ktt and tstr(kp) == key then
                return n, rp(n), rb(n + 12) % 16, ktt
            end
        end
    end
    return nil
end

local function tfindString(t, key)
    local n, v, vtt, ktt = tfind(t, key)
    if not n or vtt ~= ktt or not okp(v) or gctt(v) ~= vtt then return nil end
    return tstr(v)
end

local function tfindTable(t, key)
    local n, v, vtt, ktt = tfind(t, key)
    if not n or vtt == ktt or not okp(v) or gctt(v) ~= vtt or gctt(v) ~= gctt(t) then return nil end
    return v
end

local function keysOf(t)
    local lsz = tlsz(t)
    local node = rp(t + L.tNode)
    local names = {}
    if lsz and lsz <= 10 and okp(node) then
        for i = 0, 2 ^ lsz - 1 do
            local kp = rp(node + i * 32 + 16)
            if okp(kp) and gctt(kp) == rb(node + i * 32 + 28) % 16 then
                local s = tstr(kp)
                if s then names[#names + 1] = s end
                if #names >= 24 then break end
            end
        end
    end
    return table.concat(names, ",")
end

function Defs.slots(name)
    local out = {}
    local ok, hits = pcall(getgc, name)
    if not ok or type(hits) ~= "table" then return out end
    local seen = {}
    for i = 1, #hits do
        local h = hits[i]
        local node = type(h) == "table" and h.addr or nil
        if type(node) == "number" and okp(node) and node % 8 == 0 and not seen[node] then
            seen[node] = true
            local kp = rp(node + 16)
            local ktt = rb(node + 28) % 16
            if okp(kp) and gctt(kp) == ktt and tstr(kp) == name then
                local val = rp(node)
                local vtt = rb(node + 12) % 16
                if okp(val) and vtt ~= ktt and gctt(val) == vtt and tfind(val, "Image") then
                    local kind = 1
                    if tfind(val, "Animations") then kind += 2 end
                    if tfind(val, "Rarity") then kind += 4 end
                    out[#out + 1] = { slot = node, value = val, kind = kind, vtt = vtt }
                end
            end
        end
    end
    return out
end

local nodeOk = {}
local nodeOkAt = os.clock()

function Defs.sameArray(a, b)
    local lo, hi = math.min(a, b), math.max(a, b)
    local n = (hi - lo) / 32
    if n > 8192 then return true end
    local now = os.clock()
    if now - nodeOkAt > 8 then
        nodeOk = {}
        nodeOkAt = now
    end
    local ktt = rb(a + 28) % 16
    for i = 1, n - 1 do
        local node = lo + i * 32
        if nodeOk[node] ~= ktt then
            local kt = rb(node + 28) % 16
            if kt ~= 0 then
                local kp = rp(node + 16)
                if kt ~= ktt or not okp(kp) or gctt(kp) ~= ktt then return false end
            end
            nodeOk[node] = ktt
        end
    end
    return true
end

function Defs.fastSlots(name)
    local e = S.defIndex and S.defIndex[name]
    if not e then return nil end
    local node = e.slot
    if not okp(node) or rp(node) ~= e.value or rb(node + 12) % 16 ~= e.vtt then return nil end
    local kp = rp(node + 16)
    local ktt = rb(node + 28) % 16
    if not okp(kp) or gctt(kp) ~= ktt or tstr(kp) ~= name then return nil end
    local val = e.value
    if not okp(val) or ktt == e.vtt or gctt(val) ~= e.vtt or not tfind(val, "Image") then return nil end
    local kind = 1
    if tfind(val, "Animations") then kind += 2 end
    if tfind(val, "Rarity") then kind += 4 end
    return { { slot = node, value = val, kind = kind, vtt = e.vtt } }
end

function Defs.pair(fs, ts)
    local writes = {}
    local used = {}
    for i = 1, #fs do
        local f = fs[i]
        if not used[f.slot] then
            local best, bestD = nil, math.huge
            for k = 1, #ts do
                local d = ts[k]
                if d.kind == f.kind and d.vtt == f.vtt and not used[d.slot] then
                    local dist = math.abs(d.slot - f.slot)
                    if dist % 32 == 0 and dist <= 32 * 65536 and dist < bestD then
                        bestD = dist
                        best = d
                    end
                end
            end
            if best and not Defs.sameArray(f.slot, best.slot) then best = nil end
            if best and best.value ~= f.value and rp(f.slot) == f.value and rp(best.slot) == best.value
                and rb(f.slot + 12) % 16 == f.vtt and rb(best.slot + 12) % 16 == best.vtt then
                used[f.slot] = true
                used[best.slot] = true
                wp(f.slot, best.value)
                wp(best.slot, f.value)
                writes[#writes + 1] = { slot = f.slot, orig = f.value, value = best.value }
                writes[#writes + 1] = { slot = best.slot, orig = best.value, value = f.value }
            end
        end
    end
    return writes
end

function Defs.indexAround(ref, wanted, lens, idx, seen)
    local ktt = rb(ref + 28) % 16
    local vtt = rb(ref + 12) % 16
    local function visit(n)
        seen[n] = true
        local kt = rb(n + 28) % 16
        local vt = rb(n + 12) % 16
        if kt == 0 or vt == 0 then return 0 end
        local kp = rp(n + 16)
        if kt ~= ktt or vt ~= vtt or not okp(kp) or gctt(kp) ~= ktt then return -1 end
        local val = rp(n)
        if not okp(val) or gctt(val) ~= vt then return -1 end
        if lens[math.floor(rp(kp + 0x10) / 4294967296)] then
            local name = tstr(kp)
            if name and wanted[name] and not idx[name] then
                idx[name] = { slot = n, value = val, vtt = vt }
            end
        end
        return 1
    end
    for dir = -1, 1, 2 do
        local empty = 0
        for i = (dir == 1 and 0 or 1), 8192 do
            local r = visit(ref + dir * i * 32)
            if r < 0 then break end
            if r == 0 then
                empty += 1
                if empty > 64 then break end
            else
                empty = 0
            end
            if i % 64 == 0 then breathe() end
        end
    end
end

function Defs.remember(from, to, writes)
    S.defIndex = S.defIndex or {}
    S.defIndex[from] = { slot = writes[1].slot, value = writes[1].orig, vtt = rb(writes[1].slot + 12) % 16 }
    S.defIndex[to] = { slot = writes[2].slot, value = writes[2].orig, vtt = rb(writes[2].slot + 12) % 16 }
end

function Defs.preload(a, b, extraFrom, extraTo)
    S.defRefs = { a, b }
    local wanted, lens, total = {}, {}, 0
    local function want(nm)
        if nm and not S.defIndex[nm] and not wanted[nm] then
            wanted[nm] = true
            lens[#nm] = true
            total += 1
        end
    end
    for w, skin in pairs(S.desired) do
        want(w)
        want(skin)
    end
    want(extraFrom)
    want(extraTo)
    if total == 0 then return end
    local t0 = os.clock()
    local seen = {}
    Defs.indexAround(a, wanted, lens, S.defIndex, seen)
    if not seen[b] then Defs.indexAround(b, wanted, lens, S.defIndex, seen) end
    local found = 0
    for nm in pairs(wanted) do
        if S.defIndex[nm] then found += 1 end
    end
    log("definition index preloaded: %d of %d names in %.2fs", found, total, os.clock() - t0)
end

function Defs.redirect(from, to)
    strCache = {}
    local t0 = os.clock()
    if S.defIndex then
        local qf = Defs.fastSlots(from)
        local qt = qf and Defs.fastSlots(to)
        if (not qf or not qt) and S.defRefs and (not S.defIndex[from] or not S.defIndex[to]) then
            Defs.preload(S.defRefs[1], S.defRefs[2], from, to)
            qf = Defs.fastSlots(from)
            qt = qf and Defs.fastSlots(to)
        end
        if qf and qt then
            local quick = Defs.pair(qf, qt)
            if #quick > 0 then
                log("definition timing %s -> %s: indexed, %.2fs", from, to, os.clock() - t0)
                return quick
            end
        end
    end
    local fs = Defs.slots(from)
    local t1 = os.clock()
    task.wait(0.05)
    if S.stopReq then return nil, "stopped" end
    local t2 = os.clock()
    local ts = Defs.slots(to)
    local t3 = os.clock()
    if #fs == 0 or #ts == 0 then
        log("definition slots found: %s=%d %s=%d", from, #fs, to, #ts)
        return nil, "definitions not loaded yet"
    end
    local writes = Defs.pair(fs, ts)
    log("definition timing %s -> %s: slots(from) %.2fs, slots(to) %.2fs, match %.2fs", from, to, t1 - t0, t3 - t2, os.clock() - t3)
    if #writes == 0 then return nil, "no definitions to redirect from " .. from .. " to " .. to end
    if #writes == 2 then
        Defs.remember(from, to, writes)
        if not S.defPreloaded then
            S.defPreloaded = true
            Defs.preload(writes[1].slot, writes[2].slot)
        end
    end
    return writes
end

function Defs.stillApplied(writes)
    for i = 1, #writes do
        if rp(writes[i].slot) ~= writes[i].value then return false end
    end
    return true
end

function Defs.restore(writes)
    for i = #writes, 1, -1 do
        local w = writes[i]
        if rp(w.slot) == w.value then wp(w.slot, w.orig) end
    end
end

function Defs.rebuilt(ov)
    strCache = {}
    local mine = {}
    for i = 1, #ov.writes do mine[ov.writes[i].slot] = true end
    local slots = Defs.slots(ov.from)
    for i = 1, #slots do
        if slots[i].kind % 4 >= 2 and not mine[slots[i].slot] then return true end
    end
    return false
end

function Defs.harvestOwners(seed)
    strCache = {}
    local slots = Defs.slots(seed)
    local start = nil
    for i = 1, #slots do
        if slots[i].kind >= 4 then start = slots[i] end
    end
    if not start then
        log("harvest: no skin definition slot for %s (%d candidates)", seed, #slots)
        return 0
    end
    local ktt = rb(start.slot + 28) % 16
    local count = 0
    local function visit(n)
        local kp = rp(n + 16)
        local kt = rb(n + 28) % 16
        local vt = rb(n + 12) % 16
        if kt == 0 or vt == 0 then return 0 end
        if kt ~= ktt or not okp(kp) or gctt(kp) ~= ktt then return -1 end
        local val = rp(n)
        if vt ~= start.vtt or not okp(val) or gctt(val) ~= vt then return -1 end
        local name = tstr(kp)
        if name then
            local item = tfindString(val, "ItemName")
            if item then
                S.learned[name] = item
                count += 1
            end
        end
        return 1
    end
    for dir = -1, 1, 2 do
        local empty = 0
        for i = (dir == 1 and 0 or 1), 8192 do
            local r = visit(start.slot + dir * i * 32)
            if r < 0 then break end
            if r == 0 then
                empty += 1
                if empty > 64 then break end
            else
                empty = 0
            end
            if i % 64 == 0 then breathe() end
        end
    end
    if count == 0 then log("harvest: %s definition keys: %s", seed, keysOf(start.value)) end
    return count
end

local Inv = { list = 0, searchedAt = -1000, wait = 30, suspect = false, ok = false, entries = {} }

local function readEntries()
    local list = Inv.list
    if not okp(list) then return nil end
    local n = ru32(list + L.tSizeArr)
    local arr = rp(list + L.tArr)
    if n == 0 or n > 512 or not okp(arr) then return nil end
    local tt = gctt(list)
    local out = {}
    for i = 0, n - 1 do
        local c = arr + i * 16
        if rb(c + 12) % 16 == tt then
            local entry = rp(c)
            if not okp(entry) or gctt(entry) ~= tt then return nil end
            local weapon = tfindString(entry, "Name")
            if not weapon then return nil end
            local e = { weapon = weapon, skin = "" }
            local skin = tfindTable(entry, "Skin")
            if skin then e.skin = tfindString(skin, "Name") or "" end
            out[#out + 1] = e
        end
    end
    if #out == 0 then return nil end
    return out
end

local function findInventory()
    Inv.list = 0
    strCache = {}
    local ok, hits = pcall(getgc, "WeaponInventory")
    if not ok or type(hits) ~= "table" then return false end
    for i = 1, #hits do
        local h = hits[i]
        local node = type(h) == "table" and h.addr or nil
        if type(node) == "number" and okp(node) then
            local kp = rp(node + 16)
            local val = rp(node)
            local vtt = rb(node + 12) % 16
            if okp(kp) and tstr(kp) == "WeaponInventory" and okp(val) and gctt(val) == vtt and vtt ~= rb(node + 28) % 16 then
                Inv.list = val
                if readEntries() then return true end
            end
        end
    end
    Inv.list = 0
    log("inventory search: %d WeaponInventory candidates, none readable", #hits)
    return false
end

local function readInventory(allowSearch)
    local entries = readEntries()
    local since = os.clock() - Inv.searchedAt
    if allowSearch and ((not entries and since >= Inv.wait) or (Inv.suspect and since >= 15)) then
        Inv.searchedAt = os.clock()
        Inv.suspect = false
        if findInventory() then
            entries = readEntries()
            Inv.wait = 30
        else
            entries = nil
            Inv.wait = math.min(Inv.wait * 2, 300)
        end
    end
    Inv.ok = entries ~= nil
    Inv.entries = entries or {}
    return Inv.ok
end

local function setEquipped(weapon, cosmetic, changed, source)
    if S.equipped[weapon] == cosmetic then return end
    S.equipped[weapon] = cosmetic
    changed[#changed + 1] = weapon
    S.uiDirty = true
    log("%s has %s equipped (%s)", weapon, cosmetic == "" and "the default" or cosmetic, source)
end

local function observeInventory(changed)
    local wset = {}
    for i = 1, #S.weapons do wset[S.weapons[i]] = true end
    local inv = {}
    for i = 1, #Inv.entries do
        local e = Inv.entries[i]
        if wset[e.weapon] then
            inv[e.weapon] = true
            local cosmetic = e.skin
            if cosmetic == e.weapon then cosmetic = "" end
            setEquipped(e.weapon, cosmetic, changed, "inventory")
        end
    end
    S.invWeapons = inv
end

local function observeHeld(changed)
    local ws = game:GetService("Workspace")
    local fp = findChild(findChild(ws and ws.Address or 0, "ViewModels"), "FirstPerson")
    local h = readVec(fp)
    if not h then return end
    if h.b == S.fpB and h.e == S.fpE then return end
    S.fpB, S.fpE = h.b, h.e
    local wset = {}
    for i = 1, #S.weapons do wset[S.weapons[i]] = true end
    local list = children(fp)
    for i = 1, #list do
        local name = list[i].name
        local a = string.find(name, " - ", 1, true)
        if a then
            local b = string.find(name, " - ", a + 3, true)
            local weapon = b and string.sub(name, a + 3, b - 1) or string.sub(name, a + 3)
            if wset[weapon] then
                local cosmetic = b and string.sub(name, b + 3) or ""
                if cosmetic == weapon then cosmetic = "" end
                if not S.invWeapons[weapon] then
                    setEquipped(weapon, cosmetic, changed, "held")
                elseif S.equipped[weapon] ~= cosmetic and S.desired[weapon] ~= cosmetic then
                    Inv.suspect = true
                end
            end
        end
    end
end

local function finalize()
    if S.dead then return end
    S.dead = true
    S.running = false
    pcall(Core.restoreAll)
    pcall(writeJournal)
    for i = 1, #UI.items do
        pcall(function() UI.items[i].d:Remove() end)
    end
    UI.items = {}
    log("stopped: everything restored")
end

local T = { checkAt = 0, invAt = 0, swapsAt = 0, recAt = 0 }

local function timed(label, fn, ...)
    local t0 = os.clock()
    local a, b = fn(...)
    local dt = os.clock() - t0
    if dt > 0.3 then log("slow: %s took %.2fs", label, dt) end
    return a, b
end

local function settled()
    for w, skin in pairs(S.desired) do
        local ap, ov = S.applied[w], S.over[w]
        if not ap or ap.skin ~= skin or not ov or ov.skin ~= skin or ov.stale then return false end
    end
    for _, kind in ipairs({ "charm", "finisher" }) do
        for from, to in pairs(S.cos.desired[kind]) do
            local rec = S.cos.applied[kind][from]
            if not rec or rec.to ~= to then return false end
        end
    end
    return true
end

local function tick()
    local work = S.queue
    S.queue = {}
    if S.desiredChanged then S.picksPending = true end
    S.desiredChanged = false
    local desiredChanged = S.picksPending

    local dm = game.Address or 0
    if not okp(dm) then
        if rootValid(S.root) then Core.reset("no datamodel") end
        return
    end
    if not S.journalChecked then
        S.journalChecked = true
        undoJournal()
    end
    if dm ~= S.world then
        if S.world ~= 0 then
            S.over = {}
            S.defRetry = {}
            S.defFails = {}
            Inv.list = 0
            Inv.searchedAt = -1000
            Inv.wait = 30
            S.ownersTried = false
            S.defIndex = nil
            S.defPreloaded = nil
            S.defRefs = nil
            S.ownerTries = 0
            S.ownersRetryAt = nil
            strCache = {}
            writeJournal()
            S.picksPending = true
            desiredChanged = true
            log("new game world: applying the picks again")
        end
        S.world = dm
    end

    local now = os.clock()
    if now - nameCacheAt > 3 then
        nameCache = {}
        nameCacheAt = now
    end
    if now - strCacheAt > 5 then
        strCache = {}
        strCacheAt = now
    end

    if #work > 0 or desiredChanged or now - T.checkAt >= 0.5 then
        T.checkAt = now
        if not stillValid(S.root) then
            if rootValid(S.root) then Core.reset("viewmodels rebuilt") end
            S.root = resolve()
            if rootValid(S.root) then
                local ok, what = validateOffsets(S.root)
                S.offsetsOk = ok
                if ok then
                    S.loadedOk = deriveLoaded(S.root)
                    if not S.loadedOk then log("module-loaded field not found: skins with their own code wait") end
                    Core.scan()
                    log("asset root %x", S.root.assets)
                else
                    log("offset check failed: %s", tostring(what))
                end
            else
                S.root = nil
                setStatus(false, "Join a match to apply picks.")
            end
        elseif UI.open and now - (S.scanAt or 0) >= 3 then
            Core.scan()
        end
    end

    if not rootValid(S.root) then
        if #work > 0 then setStatus(false, "Join a match first.") end
        return
    end
    if (not S.offsetsOk or not S.loadedOk) and now - (T.validAt or 0) >= 3 then
        T.validAt = now
        if not S.offsetsOk then
            local ok, what = validateOffsets(S.root)
            S.offsetsOk = ok
            S.offsetFails = ok and 0 or (S.offsetFails or 0) + 1
            if ok then
                Core.scan()
            else
                log("offset check failed: %s", tostring(what))
            end
        end
        if S.offsetsOk and not S.loadedOk then S.loadedOk = deriveLoaded(S.root) end
    end
    if not S.offsetsOk then
        if (S.offsetFails or 0) >= 2 then
            setStatus(false, "The offsets do not match this Roblox build - nothing is written. Update the offsets at the top of the script.")
        end
        return
    end

    if S.ownersRetryAt and now >= S.ownersRetryAt then
        S.ownersRetryAt = nil
        S.ownersTried = false
    end
    if not S.ownersTried and #S.skins > 0 then
        S.ownersTried = true
        local seed, any, unknown = nil, nil, 0
        for i = 1, #S.skins do
            local si = S.skins[i]
            any = any or si.name
            if si.weapon ~= "" then
                seed = seed or si.name
            elseif S.learned[si.name] == nil then
                unknown += 1
            end
        end
        seed = seed or any
        local first = S.status == "starting"
        if unknown > 0 and seed then
            if unknown > 0 then setStatus(true, "reading the game's skin list (%d skins, a few seconds)...", unknown) end
            task.wait(0.05)
            local n = Defs.harvestOwners(seed)
            log("skin list read from %s: %d entries", seed, n)
            if n > 0 then
                if unknown > 0 then
                    for i = 1, #S.skins do
                        local si = S.skins[i]
                        if si.weapon == "" and S.learned[si.name] == nil then S.learned[si.name] = "?" end
                    end
                    S.skins = {}
                    Core.scan()
                end
            else
                S.ownerTries = (S.ownerTries or 0) + 1
                S.ownersRetryAt = os.clock() + (S.ownerTries < 10 and 15 or 60)
            end
            first = true
        end
        if first then setStatus(true, "%d weapons, %d skins - pick a weapon, then a skin", #S.weapons, #S.skins) end
    end

    local force = false
    local changed = {}
    local calm = settled()
    if now - T.invAt >= (calm and 1.5 or 0.5) then
        T.invAt = now
        local want = S.enabled and next(S.desired) ~= nil
        if timed("inventory read", readInventory, want) then observeInventory(changed) else S.invWeapons = {} end
    end
    observeHeld(changed)
    for i = 1, #changed do
        local w = changed[i]
        S.defFails[w] = nil
        if S.over[w] then force = true end
        if S.unsafe[w] then
            S.unsafe[w] = nil
            S.retry[w] = nil
            force = true
        end
        local ap = S.applied[w]
        if ap and ap.base ~= S.equipped[w] then
            Core.restoreSwaps(w)
            S.retry[w] = nil
            force = true
            setStatus(true, "%s loadout changed - picks moved over, respawn to see them", w)
        end
    end
    if #changed > 0 and next(S.over) then
        S.verifyAt = now + 1.5
        S.verifySet = S.verifySet or {}
        for i = 1, #changed do S.verifySet[changed[i]] = true end
    end

    for i = 1, #work do
        local q = work[i]
        if q.cmd == "apply" then
            S.retry[q.weapon] = nil
            S.defRetry[q.weapon] = nil
            S.defFails[q.weapon] = nil
            if not S.skinIndex[q.skin] then Core.scan() end
            force = true
        elseif q.cmd == "restore" then
            Core.restore(q.weapon)
            writeJournal()
            setStatus(true, "%s restored", q.weapon)
        elseif q.cmd == "restoreall" then
            Core.restoreAll()
            writeJournal()
            setStatus(true, "all weapons restored")
        end
    end

    if not S.enabled then
        if S.wasEnabled or next(S.applied) or next(S.over) or next(S.cos.applied.charm) or next(S.cos.applied.finisher) then
            Core.restoreAll()
            writeJournal()
            setStatus(true, "off - weapons restored")
        end
        S.wasEnabled = false
        return
    end

    if S.root.fallback then
        local picks = 0
        for _ in pairs(S.desired) do picks += 1 end
        if picks > 0 then setStatus(true, "waiting for your scripts to load before applying %d pick(s)", picks) end
        return
    end

    if not S.wasEnabled then
        force = true
        S.retry = {}
    end
    S.wasEnabled = true

    if now - T.swapsAt >= 2 then
        T.swapsAt = now
        if Core.checkSwaps() then force = true end
    end

    if S.verifyAt and now >= S.verifyAt then
        S.verifyAt = nil
        local vset = S.verifySet or {}
        S.verifySet = {}
        local vt0 = os.clock()
        for w, ov in pairs(S.over) do
            if vset[w] and #ov.writes > 0 and os.clock() - (ov.verifiedAt or 0) > 8 then
                if Defs.rebuilt(ov) then
                    ov.stale = true
                    S.defFails[w] = 0
                    S.defRetry[w] = now
                    log("%s: definitions were rebuilt, redoing", w)
                end
                ov.verifiedAt = os.clock()
                task.wait(0.05)
                if S.stopReq then return end
            end
        end
        if os.clock() - vt0 > 0.3 then log("slow: definition verify took %.2fs", os.clock() - vt0) end
    end

    if S.catalogGrew then
        S.catalogGrew = false
        if not S.ownersRetryAt then S.ownersTried = false end
        S.retry = {}
        S.defRetry = {}
        S.defFails = {}
    end

    if force or desiredChanged or now - T.recAt >= (calm and 2 or 0.5) then
        T.recAt = now
        if now - (T.cosAt or 0) >= 3 then
            T.cosAt = now
            timed("cosmetics scan", Cos.scan)
        end
        if timed("cosmetics reconcile", Cos.reconcile, force or desiredChanged) then writeJournal() end
        timed("reconcile", Core.reconcile, force or desiredChanged)
        S.picksPending = false
    end
end

local function pick(weapon, name)
    if not weapon then return end
    if name == nil or name == "(default)" or S.desired[weapon] == name then
        if S.desired[weapon] == nil then return end
        S.desired[weapon] = nil
        S.queue[#S.queue + 1] = { cmd = "restore", weapon = weapon }
    else
        S.desired[weapon] = name
        S.queue[#S.queue + 1] = { cmd = "apply", weapon = weapon, skin = name }
    end
    S.desiredChanged = true
    S.uiDirty = true
    savePicks()
end

local function pickCos(kind, from, to)
    local set = S.cos.desired[kind]
    if not from or not set then return end
    if to == nil or to == "(default)" or to == from or set[from] == to then
        if set[from] == nil then return end
        set[from] = nil
    else
        set[from] = to
        S.cos.retry[kind .. "\t" .. from] = nil
    end
    S.desiredChanged = true
    S.uiDirty = true
    saveCos()
end

local function uiKind()
    if UI.cat == "Charms" then return "charm" end
    if UI.cat == "Finishers" then return "finisher" end
    return nil
end

local function choose(sel, s, keep)
    local kind = uiKind()
    if kind then
        if keep and S.cos.desired[kind][sel] == s then return end
        pickCos(kind, sel, s)
    else
        if keep and S.desired[sel] == s then return end
        pick(sel, s)
    end
end

local function clearAll()
    S.cos.desired = { charm = {}, finisher = {} }
    saveCos()
    S.desired = {}
    S.queue[#S.queue + 1] = { cmd = "restoreall" }
    S.desiredChanged = true
    S.uiDirty = true
    savePicks()
end

local COL = {
    black = Color3.fromRGB(0, 0, 0),
    edge = Color3.fromRGB(44, 44, 44),
    bg = Color3.fromRGB(17, 17, 17),
    box = Color3.fromRGB(22, 22, 22),
    rowHover = Color3.fromRGB(30, 30, 30),
    rowSel = Color3.fromRGB(35, 35, 35),
    btn = Color3.fromRGB(28, 28, 28),
    btnHover = Color3.fromRGB(38, 38, 38),
    bright = Color3.fromRGB(235, 235, 235),
    text = Color3.fromRGB(190, 190, 190),
    dim = Color3.fromRGB(105, 105, 105),
    accent = Color3.fromRGB(154, 197, 39),
    warn = Color3.fromRGB(206, 164, 62),
    bad = Color3.fromRGB(214, 86, 86),
}

local WIN_W, WIN_H = 600, 414
local ROWS = CFG.rows
local ROW_H = 18
local BOX_Y = 56
local LIST_Y = BOX_Y + 22
local BOX_H = 22 + ROWS * ROW_H + 4
local LEFT_X, LEFT_W = 10, 190
local RIGHT_X, RIGHT_W = 208, 382
local CHAR_W = 7

local function mkSquare(rx, ry, w, h, color, z)
    local d = Drawing.new("Square")
    d.Filled = true
    d.Color = color
    d.Size = Vector2.new(w, h)
    d.Transparency = 1
    d.ZIndex = z or 50
    d.Visible = false
    local it = { d = d, rx = rx, ry = ry, w = w, h = h, show = true, vis = false, color = color, placed = false }
    UI.items[#UI.items + 1] = it
    return it
end

local function mkText(rx, ry, text, color)
    local d = Drawing.new("Text")
    d.Text = text
    d.Size = 13
    d.Font = Drawing.Fonts and Drawing.Fonts.UI or 0
    d.Color = color
    d.Outline = false
    d.Center = false
    d.Transparency = 1
    d.ZIndex = 56
    d.Visible = false
    local it = { d = d, rx = rx, ry = ry, show = true, vis = false, color = color, text = text, placed = false }
    UI.items[#UI.items + 1] = it
    return it
end

local function setText(it, s)
    if it.text ~= s then
        it.text = s
        it.d.Text = s
    end
end

local function setColor(it, c)
    if it.color ~= c then
        it.color = c
        it.d.Color = c
    end
end

local function setShow(it, b)
    it.show = b
end

local function setRight(it, right, s)
    setText(it, s)
    local rx = right - #s * CHAR_W
    if it.rx ~= rx then
        it.rx = rx
        it.placed = false
    end
end

local function fit(s, px)
    local n = math.floor(px / CHAR_W)
    if #s <= n then return s end
    return string.sub(s, 1, math.max(1, n - 2)) .. ".."
end

local function textButton(rx, ry, label, fn)
    local b = { rx = rx - 5, ry = ry - 4, w = #label * CHAR_W + 10, h = 21, fn = fn, on = true, label = label }
    b.tx = mkText(rx, ry, label, COL.dim)
    UI.buttons[#UI.buttons + 1] = b
    return b
end

local function boxButton(rx, ry, label, fn)
    local w = #label * CHAR_W + 20
    local b = { rx = rx, ry = ry, w = w, h = 20, fn = fn, on = true, boxed = true }
    b.edge = mkSquare(rx, ry, w, 20, COL.edge, 52)
    b.sq = mkSquare(rx + 1, ry + 1, w - 2, 18, COL.btn, 53)
    b.tx = mkText(rx + 10, ry + 3, label, COL.text)
    UI.buttons[#UI.buttons + 1] = b
    return b
end

local function makeRow(x, w, i, fn)
    local y = LIST_Y + (i - 1) * ROW_H
    local b = { rx = x + 1, ry = y, w = w - 2, h = ROW_H, fn = fn, on = false, right = x + w - 10, textW = w - 20 }
    b.sq = mkSquare(x + 1, y, w - 2, ROW_H, COL.rowHover, 53)
    b.bar = mkSquare(x + 1, y, 2, ROW_H, COL.accent, 54)
    b.tx = mkText(x + 10, y + 2, "", COL.text)
    b.mark = mkText(x + w - 40, y + 2, "", COL.dim)
    UI.buttons[#UI.buttons + 1] = b
    return b
end

local function makeBox(x, w)
    mkSquare(x, BOX_Y, w, BOX_H, COL.edge, 51)
    mkSquare(x + 1, BOX_Y + 1, w - 2, BOX_H - 2, COL.box, 52)
    mkSquare(x + 1, BOX_Y + 19, w - 2, 1, COL.edge, 53)
end

local function buildUI()
    UI.cat = "All"
    UI.wsel = nil
    UI.wpage = 1
    UI.spage = 1
    UI.wlist = {}
    UI.slist = {}
    UI.moved = true
    UI.hover = nil
    UI.boxed = {}

    mkSquare(0, 0, WIN_W, WIN_H, COL.black, 48)
    mkSquare(1, 1, WIN_W - 2, WIN_H - 2, COL.edge, 49)
    mkSquare(2, 2, WIN_W - 4, WIN_H - 4, COL.bg, 50)
    mkSquare(2, 2, WIN_W - 4, 2, COL.accent, 51)

    mkText(12, 12, "rivals", COL.bright)
    mkText(12 + 7 * CHAR_W, 12, "skinchanger", COL.accent)

    UI.modes = {}
    local modes = { { "skins", "All" }, { "charms", "Charms" }, { "finishers", "Finishers" } }
    local mx = WIN_W - 12
    for i = #modes, 1, -1 do
        local label, cat = modes[i][1], modes[i][2]
        mx -= #label * CHAR_W
        local b = textButton(mx, 12, label, function()
            local before = uiKind()
            UI.cat = cat
            if uiKind() ~= before then
                UI.wsel = nil
                UI.spage = 1
                UI.wpage = 1
            end
            S.uiDirty = true
        end)
        b.cat = cat
        b.line = mkSquare(mx, 27, #label * CHAR_W, 1, COL.accent, 52)
        UI.modes[#UI.modes + 1] = b
        mx -= 16
    end

    UI.filters = {}
    local fx = 12
    for i = 1, 8 do
        local name = CATEGORIES[i]
        local label = string.lower(name)
        local b = textButton(fx, 36, label, function()
            UI.cat = name
            UI.wpage = 1
            S.uiDirty = true
        end)
        b.name = name
        UI.filters[i] = b
        fx += #label * CHAR_W + 14
    end
    UI.hint = mkText(12, 36, "", COL.dim)

    makeBox(LEFT_X, LEFT_W)
    makeBox(RIGHT_X, RIGHT_W)
    UI.leftHead = mkText(LEFT_X + 10, BOX_Y + 4, "weapon", COL.dim)
    UI.rightHead = mkText(RIGHT_X + 10, BOX_Y + 4, "", COL.dim)

    local function pager(x, w, key)
        local right = x + w - 10
        local p = {}
        p.next = textButton(right - CHAR_W, BOX_Y + 4, ">", function()
            local list = key == "w" and UI.wlist or UI.slist
            local page = key == "w" and UI.wpage or UI.spage
            if page * ROWS >= #list then return end
            if key == "w" then
                UI.wpage += 1
            else
                UI.spage += 1
            end
            S.uiDirty = true
        end)
        p.text = mkText(right - 7 * CHAR_W, BOX_Y + 4, "1/1", COL.dim)
        p.textRight = right - 2 * CHAR_W - 4
        p.prev = textButton(right - 9 * CHAR_W - 4, BOX_Y + 4, "<", function()
            local page = key == "w" and UI.wpage or UI.spage
            if page <= 1 then return end
            if key == "w" then
                UI.wpage -= 1
            else
                UI.spage -= 1
            end
            S.uiDirty = true
        end)
        return p
    end
    UI.wpager = pager(LEFT_X, LEFT_W, "w")
    UI.spager = pager(RIGHT_X, RIGHT_W, "s")

    UI.wrows = {}
    UI.srows = {}
    for i = 1, ROWS do
        UI.wrows[i] = makeRow(LEFT_X, LEFT_W, i, function()
            local w = UI.wlist[(UI.wpage - 1) * ROWS + i]
            if w then
                UI.wsel = w
                UI.spage = 1
                S.uiDirty = true
            end
        end)
        UI.srows[i] = makeRow(RIGHT_X, RIGHT_W, i, function()
            local s = UI.slist[(UI.spage - 1) * ROWS + i]
            if s and UI.wsel then
                choose(UI.wsel, s, false)
            end
        end)
    end

    local by = BOX_Y + BOX_H + 10
    UI.enable = { rx = 10, ry = by, w = 11 + 8 + 7 * CHAR_W, h = 20, on = true, fn = function()
        S.enabled = not S.enabled
        S.uiDirty = true
    end }
    mkSquare(10, by + 4, 11, 11, COL.edge, 52)
    mkSquare(11, by + 5, 9, 9, COL.box, 53)
    UI.enable.fill = mkSquare(12, by + 6, 7, 7, COL.accent, 54)
    UI.enable.tx = mkText(10 + 11 + 8, by + 3, "enabled", COL.text)
    UI.buttons[#UI.buttons + 1] = UI.enable

    local labels = {
        { "clear all", function() clearAll() end },
        { "restore", function() if UI.wsel then choose(UI.wsel, "(default)", false) end end },
    }
    local bx = WIN_W - 10
    for i = 1, #labels do
        local w = #labels[i][1] * CHAR_W + 20
        bx -= w
        UI.boxed[#UI.boxed + 1] = boxButton(bx, by, labels[i][1], labels[i][2])
        bx -= 6
    end

    mkSquare(10, by + 30, WIN_W - 20, 1, COL.edge, 51)
    UI.dot = mkSquare(12, by + 43, 5, 5, COL.accent, 52)
    UI.status1 = mkText(24, by + 38, "", COL.text)
    UI.status2 = mkText(24, by + 53, "", COL.text)

    local cam = workspace.CurrentCamera
    local vs = cam and cam.ViewportSize
    if vs and vs.X and vs.X > WIN_W and vs.Y > WIN_H then
        UI.x = math.floor((vs.X - WIN_W) / 2)
        UI.y = math.floor((vs.Y - WIN_H) / 2)
    end
end

local function styleRow(row, shown, hover, chosen, textColor)
    row.on = shown
    setShow(row.tx, shown)
    setShow(row.mark, shown)
    setShow(row.bar, shown and chosen)
    setShow(row.sq, shown and (hover or chosen))
    if shown then
        setColor(row.sq, chosen and COL.rowSel or COL.rowHover)
        setColor(row.tx, textColor)
    end
end

local function stylePager(p, page, pages)
    local many = pages > 1
    p.prev.on = many
    p.next.on = many
    setShow(p.prev.tx, many)
    setShow(p.next.tx, many)
    setShow(p.text, many)
    if many then
        setRight(p.text, p.textRight, page .. "/" .. pages)
        setColor(p.prev.tx, UI.hover == p.prev and COL.bright or COL.dim)
        setColor(p.next.tx, UI.hover == p.next and COL.bright or COL.dim)
    end
end

local function refreshUI()
    S.uiDirty = false

    local kind = uiKind()
    local desired = kind and S.cos.desired[kind] or S.desired
    local wl = {}
    if kind then
        wl = S.cos.lists[kind]
    else
        for i = 1, #S.weapons do
            local w = S.weapons[i]
            local cat = CATEGORY[w] or "Utility"
            if UI.cat == "All" or cat == UI.cat then wl[#wl + 1] = w end
        end
    end
    UI.wlist = wl
    local wpages = math.max(1, math.ceil(#wl / ROWS))
    UI.wpage = math.clamp(UI.wpage, 1, wpages)

    for i = 1, #UI.modes do
        local b = UI.modes[i]
        local active = (b.cat == "All" and kind == nil) or b.cat == UI.cat
        setColor(b.tx, active and COL.bright or (UI.hover == b and COL.text or COL.dim))
        setShow(b.line, active)
    end
    for i = 1, #UI.filters do
        local b = UI.filters[i]
        b.on = kind == nil
        setShow(b.tx, kind == nil)
        setColor(b.tx, b.name == UI.cat and COL.accent or (UI.hover == b and COL.text or COL.dim))
    end
    setShow(UI.hint, kind ~= nil)
    if kind then
        setText(UI.hint, "left: the " .. kind .. " you have equipped in game    right: what it shows as")
    end
    setText(UI.leftHead, kind and ("equipped " .. kind) or "weapon")

    for i = 1, ROWS do
        local idx = (UI.wpage - 1) * ROWS + i
        local w = wl[idx]
        local row = UI.wrows[i]
        local selected = w ~= nil and w == UI.wsel
        local hover = UI.hover == row
        styleRow(row, w ~= nil, hover, selected, selected and COL.bright or COL.text)
        if w then
            local d = desired[w]
            local mark = ""
            if d then
                local on
                if kind then
                    local rec = S.cos.applied[kind][w]
                    on = rec ~= nil and rec.to == d
                else
                    local ap = S.applied[w]
                    on = ap and ap.skin == d
                end
                mark = on and "on" or "wait"
                setColor(row.mark, on and COL.accent or COL.warn)
            end
            setRight(row.mark, row.right, mark)
            setText(row.tx, fit(w, row.textW - (#mark > 0 and (#mark + 1) * CHAR_W or 0)))
        end
    end
    stylePager(UI.wpager, UI.wpage, wpages)

    local sel = UI.wsel
    local sl = {}
    if sel then
        sl[1] = "(default)"
        local list = S.skinsByWeapon[sel]
        if kind then list = S.cos.lists[kind] end
        if list then
            for i = 1, #list do
                if list[i] ~= sel then sl[#sl + 1] = list[i] end
            end
        end
    end
    UI.slist = sl
    local spages = math.max(1, math.ceil(#sl / ROWS))
    UI.spage = math.clamp(UI.spage, 1, spages)

    local headW = RIGHT_W - 20 - (spages > 1 and 11 * CHAR_W or 0)
    if kind then
        if sel then
            setText(UI.rightHead, fit(string.lower(sel) .. " shows as", headW))
        else
            setText(UI.rightHead, "shows as")
        end
    elseif sel then
        local eq = S.equipped[sel]
        local eqText = eq == nil and "hold it once" or (eq == "" and "default" or eq)
        setText(UI.rightHead, fit("skin  /  equipped: " .. string.lower(eqText), headW))
    else
        setText(UI.rightHead, "skin")
    end

    for i = 1, ROWS do
        local idx = (UI.spage - 1) * ROWS + i
        local s = sl[idx]
        local row = UI.srows[i]
        local d = sel and desired[sel] or nil
        local chosen = s ~= nil and ((s == "(default)" and d == nil) or s == d)
        local hover = UI.hover == row
        styleRow(row, s ~= nil, hover, chosen, chosen and COL.bright or COL.text)
        if s then
            local mark, color = "", COL.accent
            if s ~= "(default)" and s == d then
                if kind then
                    local rec = S.cos.applied[kind][sel]
                    if not (rec and rec.to == s) then
                        mark = "wait"
                        color = COL.warn
                    else
                        mark = "on"
                    end
                else
                    local ap = S.applied[sel]
                    local ov = S.over[sel]
                    if ap and ap.skin == s then
                        if ov and ov.skin == s then
                            mark = "on"
                        else
                            mark = "model only"
                            color = COL.warn
                        end
                    else
                        mark = "wait"
                        color = COL.warn
                    end
                end
            elseif not kind and s ~= "(default)" and S.equipped[sel] == s then
                mark = "equipped"
                color = COL.dim
            end
            setColor(row.mark, color)
            setRight(row.mark, row.right, mark)
            setText(row.tx, fit(s, row.textW - (#mark > 0 and (#mark + 1) * CHAR_W or 0)))
        end
    end
    stylePager(UI.spager, UI.spage, spages)

    setShow(UI.enable.fill, S.enabled)
    setColor(UI.enable.tx, UI.hover == UI.enable and COL.bright or COL.text)
    for i = 1, #UI.boxed do
        local b = UI.boxed[i]
        setColor(b.sq, UI.hover == b and COL.btnHover or COL.btn)
        setColor(b.tx, UI.hover == b and COL.bright or COL.text)
    end

    local st = S.status or ""
    local max = math.floor((WIN_W - 36) / CHAR_W)
    local a, b = st, ""
    if #st > max then
        local cut = max
        for i = max, math.floor(max / 2), -1 do
            if string.sub(st, i, i) == " " then
                cut = i
                break
            end
        end
        a = string.sub(st, 1, cut)
        b = fit(string.sub(st, cut + 1), WIN_W - 36)
    end
    setText(UI.status1, a)
    setText(UI.status2, b)
    setColor(UI.dot, S.statusOk and COL.accent or COL.bad)
end

local function placeUI()
    local moved = UI.moved
    UI.moved = false
    for i = 1, #UI.items do
        local it = UI.items[i]
        local vis = UI.open and it.show
        if vis and (moved or not it.placed) then
            it.d.Position = Vector2.new(UI.x + it.rx, UI.y + it.ry)
            it.placed = true
        elseif moved then
            it.placed = false
        end
        if vis ~= it.vis then
            it.vis = vis
            it.d.Visible = vis
        end
    end
end

local function uiLoop()
    local mouse = nil
    local prevDown = false
    local prevKeys = {}
    local dragging, dox, doy = false, 0, 0
    local vx, vy, vAt = 0, 0, -10
    local refreshAt = 0

    local function edge(vk)
        local d = iskeypressed(vk) == true
        local e = d and not prevKeys[vk]
        prevKeys[vk] = d
        return e
    end

    while S.running and not S.dead do
        local ok, err = pcall(function()
            if not mouse then
                local lp = Players.LocalPlayer
                mouse = lp and lp:GetMouse()
                if not mouse then return end
            end
            local active = isrbxactive() == true
            local toggled = edge(CFG.toggleKey)
            if toggled and active then
                UI.open = not UI.open
                S.uiDirty = true
            end
            local mdown = ismouse1pressed() == true
            local hover = nil

            if UI.open and active then
                local now = os.clock()
                if now - vAt > 1 then
                    vAt = now
                    local cam = workspace.CurrentCamera
                    local vs = cam and cam.ViewportSize
                    if vs then vx, vy = vs.X, vs.Y end
                end
                local mx, my = mouse.X or 0, mouse.Y or 0
                local locked = math.abs(mx - vx / 2) < 1.5 and math.abs(my - vy / 2) < 1.5
                local lx, ly = mx - UI.x, my - UI.y

                if not locked and not dragging then
                    for i = 1, #UI.buttons do
                        local b = UI.buttons[i]
                        if b.on and lx >= b.rx and lx < b.rx + b.w and ly >= b.ry and ly < b.ry + b.h then
                            hover = b
                            break
                        end
                    end
                end

                if mdown and not prevDown and not locked then
                    if hover then
                        hover.fn()
                    elseif lx >= 0 and lx <= WIN_W and ly >= 0 and ly <= 30 then
                        dragging = true
                        dox, doy = lx, ly
                    end
                end
                if dragging then
                    if mdown and not locked then
                        local nx, ny = mx - dox, my - doy
                        if nx ~= UI.x or ny ~= UI.y then
                            UI.x, UI.y = nx, ny
                            UI.moved = true
                        end
                    else
                        dragging = false
                    end
                end

            else
                dragging = false
            end
            prevDown = mdown
            if hover ~= UI.hover then
                UI.hover = hover
                S.uiDirty = true
            end

            if UI.open and (S.uiDirty or os.clock() - refreshAt > 0.5) then
                refreshAt = os.clock()
                refreshUI()
            end
            placeUI()
        end)
        if not ok then log("ui error: %s", tostring(err)) end
        task.wait(0.016)
    end
end

_G.RivalsSkins = {
    state = S,
    pick = pick,
    pickCos = pickCos,
    clearAll = clearAll,
    stop = function()
        S.stopReq = true
        if not S.inTick then finalize() end
    end,
}

UI.open = CFG.startOpen

task.spawn(function()
    local waited = 0
    while PREV and PREV.state and not PREV.state.dead and waited < 60 do
        task.wait(0.1)
        waited += 0.1
    end
    PREV = nil
    pcall(makefolder, CFG.dir)
    loadPicks()
    loadCos()
    while S.running and not S.stopReq do
        S.inTick = true
        sliceAt = os.clock()
        local ok, err = pcall(tick)
        S.inTick = false
        if not ok then
            log("error: %s", tostring(err))
            setStatus(false, "error - rescanning")
            S.root = nil
            S.offsetsOk = false
        end
        if S.stopReq then break end
        task.wait(0.1)
    end
    finalize()
end)

task.spawn(function()
    local ok, err = pcall(buildUI)
    if not ok then
        log("ui build failed: %s", tostring(err))
        return
    end
    uiLoop()
end)