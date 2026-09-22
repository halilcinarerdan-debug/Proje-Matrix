-- =====================================================================
-- MATRIX BUREAU / bureau.lua
-- Dirty-set persistence, ticker'da sıfır await, pattern cache,
-- ★ REVİZYON #2: BÜRO ↔ TOPTANCI İSTİHBARAT KÖPRÜSÜ ★
--
-- KONTRAТ (logistics.lua ile):
--   logistics.lua'nın OnPickup'ında forensic_trace_left == true ise:
--       Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
--   çağrılır. Bureau bu örneği SADECE BİRİKTİRİR (ANINDA trust'a dokunmaz!).
--
-- Bureau tarafı kendi tick'inde (Bureau.TickDropForensics):
--   1) Eski örnekleri unutur (zaman soğuması / üstel decay).
--   2) Match_Certainty hesaplar (aşağıdaki formül).
--   3) certainty >= BureauLeakCertaintyThreshold VE henüz leaked değilse:
--      → EmitSupplierIntelLeak → toptancıya deterministik kanalla sızdırır
--      → trust penalty uygulanır (logistics.lua ApplyBureauIntelLeak hook'u)
--      → leaked = true (tek seferlik; yeniden tetiklenmez).
--
-- MİMARİ GENİŞLETME NOTU (5/6/7/8. katman):
--   • 5. katman: DropForensics'e "witness_corroboration" alanı eklenebilir;
--     certainty formülüne ÇARPIMSAL terim olarak girer. ★ Bu katmanda AYRICA
--     aşağıdaki livestream tick'ine tek satırlık bir "telsiz sessizliği"
--     koruması eklendi (bkz. market.lua Matrix.RadioSilence) — Büro'nun
--     kendi mantığı (üçgenleme/baskın/desifre formülleri) HİÇ değişmedi,
--     sadece siber heatmap artışı market.lua'nın Matrix.RadioSilence.IsActive
--     guard'ıyla koşullandı. Hook yoksa (market.lua yüklü değilse) davranış
--     ESKİSİYLE BİREBİR AYNIDIR.
--   • 6. katman (BU SÜRÜM): ComputeRaidSquad artık server/door_reinforcement.lua
--     yüklüyse escapeWindow'a (kapı kırılma süresi) bir bonus ekler — bkz.
--     [K6] işaretli blok aşağıda. Hook yoksa davranış ESKİSİYLE BİREBİR
--     AYNIDIR. Ayrıca IssueRaid/ResolveRaidOutcome artık kendi server-içi
--     ('matrix:internal:raidIssued' / 'matrix:internal:raidResolved') Lua
--     event'lerini de fırlatır — bureau.lua'nın KENDİ üçgenleme/baskın/
--     deşifre formüllerine HİÇ dokunulmadı, bu yalnızca dış modüllerin
--     (door_reinforcement.lua) main.lua'ya veya bu dosyaya dokunmadan bir
--     baskının ne zaman başladığını/bittiğini öğrenmesini sağlayan pasif
--     bir yayın kanalıdır.
--   • 6. katman: EmitSupplierIntelLeak'in leak_channel parametresi
--     (siber / rüşvet / asılsız) yeni katsayı kanalları açar.
--   • 7. katman: BureauLeakCertaintyThreshold'u trap-house bazında
--     override eden bir "bölgesel federal baskı" vektörü eklenebilir.
--   • 8. katman: Uluslararası kartel diplomasi matrisi aynı kanaldan beslenir.
-- =====================================================================


Matrix.Bureau     = Matrix.Bureau     or {}
Matrix.TrapHouses = Matrix.TrapHouses or {}
Matrix.Supplier   = Matrix.Supplier   or {}
Matrix.Bureau.DropForensics = Matrix.Bureau.DropForensics or {}


local pairs, ipairs, next        = pairs, ipairs, next
local type, tostring, tonumber   = type, tostring, tonumber
local math, table                = math, table
local math_max, math_min         = math.max, math.min
local math_huge                  = math.huge
local math_floor                 = math.floor
local os_date                    = os.date
local os_time                    = os.time
local GetPlayerPed                = GetPlayerPed
local GetEntityCoords             = GetEntityCoords


local propagandaMomentum = 0.0
local cyberLeakHeatmap   = {}
local patternLog         = {}


-- Dirty sets
local dirtyDecryption = {}
local dirtyIntel      = {}
-- ★ [SEC-5] patternLog artik HER olayda degil, toplu (batch) flush
-- edilir -- bkz. LogPatternEvent / FlushDirtyPatternLog.
local dirtyPatternLog  = {}
-- [trapHouseId][gun_saat] = FlushDirtyPatternLog'un DB'ye en son yazdigi
-- deger -- delta hesaplamak icindir (patternLog'un KENDISI resetlenmez,
-- cunku ComputePatternRegularity onu uzun-vadeli bir sinyal olarak okur).
local patternLogFlushed = {}


-- Raid & livestream runtime
local RaidLogIdByTrapHouse = {}
local LivestreamSessions   = {}


-- ★ REVİZYON #2 runtime state
-- [dropId] = {
--     samples          = { { quality=N, at=epoch }, ... },   -- FIFO sınırı uygulanır
--     supplier_id      = N,
--     citizenid        = 'CID',
--     leaked           = false,     -- tek seferlik tetik guard'ı
--     last_activity_at = epoch
-- }
-- MATEMATİKSEL NOT: samples listesi zaman-serisi bir pencere (sliding window)
-- gibi davranır; MaxDropSamplesForLeak sınırını aşan örnekler FIFO olarak
-- atılır. Bu, belleği O(sabit) tutarken "son N kanıt günceldir" varsayımıyla
-- adli mantığa uyar (eski kanıtlar zaten kontaminasyon/aşınma ile geçersizdir).
local DropForensicsByDropId = Matrix.Bureau.DropForensics
local WARNED_MISSING_SUPPLIER_HOOK = false


-- =====================================================================
-- UTILITIES
-- =====================================================================
-- ★ DÜZELTME: FiveM'de vector3/vector4 değerlerinin type() sonucu
-- 'vector3'/'vector4' string'idir — 'table' DEĞİL, 'userdata' DEĞİL. Bu
-- kontrol eskiden yalnızca 'table'/'userdata' kabul ediyordu, yani GERÇEK
-- her vector3 GEÇERSİZ sayılıyor, mesafe her zaman math_huge dönüyordu
-- (FindNearestTrapHouse asla bir trap house bulamıyordu — üçgenleme/
-- deşifre kazancı SESSİZCE hiç işlemiyordu). Artık vector3/vector4 de
-- kabul ediliyor.
local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    if type(a) ~= 'userdata' and type(a) ~= 'table' and type(a) ~= 'vector3' and type(a) ~= 'vector4' then return math_huge end
    if type(b) ~= 'userdata' and type(b) ~= 'table' and type(b) ~= 'vector3' and type(b) ~= 'vector4' then return math_huge end
    local ax, ay, az = a.x, a.y, a.z
    local bx, by, bz = b.x, b.y, b.z
    if type(ax) ~= 'number' or type(ay) ~= 'number' or type(az) ~= 'number' then return math_huge end
    if type(bx) ~= 'number' or type(by) ~= 'number' or type(bz) ~= 'number' then return math_huge end
    if ax ~= ax or ay ~= ay or az ~= az then return math_huge end
    if bx ~= bx or by ~= by or bz ~= bz then return math_huge end
    return #(a - b)
end


-- ★ AYNI DÜZELTME (bkz. VectorDistance yorumu): vector3/vector4 artık kabul
-- ediliyor. Bu satır düzelmeden ÖNCE /traphouseekle'a GEÇERLİ bir koordinat
-- bile versen "gecersiz koordinat" hatası ALIRDI — çünkü CreateTrapHouse
-- her zaman IsValidCoords(vector3(x,y,z))'yi false buluyordu.
local function IsValidCoords(c)
    if type(c) ~= 'table' and type(c) ~= 'userdata' and type(c) ~= 'vector3' and type(c) ~= 'vector4' then return false end
    if c.x == nil or c.y == nil or c.z == nil then return false end
    if type(c.x) ~= 'number' or type(c.y) ~= 'number' or type(c.z) ~= 'number' then return false end
    if c.x ~= c.x or c.y ~= c.y or c.z ~= c.z then return false end
    return true
end


-- =====================================================================
-- LOAD
-- =====================================================================
function Matrix.Bureau.LoadTrapHouses()
    local rows = MySQL.query.await('SELECT * FROM matrix_trap_houses', {}) or {}
    for _, row in ipairs(rows) do
        Matrix.TrapHouses[row.id] = {
            id                   = row.id,
            label                = row.label or ('Trap #' .. row.id),
            coords               = vector3(row.coord_x or 0.0, row.coord_y or 0.0, row.coord_z or 0.0),
            decryption_confidence= Matrix.Clamp(tonumber(row.decryption_confidence) or 0.0, 0.0, 1.0),
            raid_ordered         = row.raid_ordered == 1
        }
        cyberLeakHeatmap[row.id] = Matrix.Clamp(tonumber(row.cyber_leak_intensity) or 0.0, 0.0, 999.0)
        patternLog[row.id]       = {}
    end
    Matrix.Log('BUREAU', '%d trap house yüklendi.', #rows)
end


CreateThread(function()
    Matrix.Bureau.LoadTrapHouses()
end)


function Matrix.Bureau.CreateTrapHouse(label, coords)
    if not IsValidCoords(coords) then return false, 'bad_coords' end
    label = (type(label) == 'string' and label ~= '') and label or 'Yeni Trap'


    MySQL.insert([[
        INSERT INTO matrix_trap_houses (label, coord_x, coord_y, coord_z, decryption_confidence, cyber_leak_intensity, raid_ordered, created_at)
        VALUES (?, ?, ?, ?, 0.0, 0.0, 0, NOW())
    ]], { label, coords.x, coords.y, coords.z },
    function(insertId)
        if not insertId then return end
        Matrix.TrapHouses[insertId] = {
            id = insertId, label = label, coords = vector3(coords.x, coords.y, coords.z),
            decryption_confidence = 0.0, raid_ordered = false
        }
        cyberLeakHeatmap[insertId] = 0.0
        patternLog[insertId] = {}
        Matrix.Log('BUREAU', 'Yeni trap house #%d (%s) oluşturuldu.', insertId, label)
    end)


    return true
end


-- =====================================================================
-- FIND NEAREST
-- =====================================================================
local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses) do
        local d = VectorDistance(coords, house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId, nearestDist
end


-- =====================================================================
-- PATTERN LOG (cache + async upsert)
-- =====================================================================
-- ★ [SEC-5] DB SPAM DÜZELTMESİ: eskiden HER telsiz ihlalinde senkronize bir
-- MySQL.prepare atılıyordu -- yoğun telsiz trafiğinde MariaDB I/O
-- darboğazına girer. Artık yalnızca RAM'deki patternLog güncellenir ve
-- trap house "dirty" işaretlenir; gerçek DB yazımı FlushDirtyPatternLog
-- tarafından periyodik olarak TOPLU (batch) yapılır (bkz. FLUSH LOOP).
function Matrix.Bureau.LogPatternEvent(trapHouseId)
    if type(trapHouseId) ~= 'number' or not Matrix.TrapHouses[trapHouseId] then return false end
    if not patternLog[trapHouseId] then patternLog[trapHouseId] = {} end


    local dt = os_date('*t')
    local key = ('%d_%d'):format(dt.wday, dt.hour)
    patternLog[trapHouseId][key] = (patternLog[trapHouseId][key] or 0) + 1


    dirtyPatternLog[trapHouseId] = true


    return true
end


-- ★ [SEC-5] Dirty trap house'ların TÜM bucket'larını TEK bir
-- MySQL.transaction içinde topluca yazar (deadlock korumalı). patternLog
-- (RAM) KENDİSİ hiç sıfırlanmaz -- ComputePatternRegularity onu uzun vadeli
-- bir sinyal olarak okur -- bunun yerine yalnızca "DB'ye en son yazılan
-- değer" (patternLogFlushed) izlenir ve DELTA (fark) SQL tarafında
-- `occurrence_count + delta` ile toplanır. Böylece DB kolonu, restart'lar
-- boyunca dahi (RAM sıfırlansa da) her zaman GERÇEK toplam olay sayısını
-- taşımaya devam eder -- LogPatternEvent'in ESKİ "her olayda +1" DB
-- davranışıyla BİREBİR AYNI nihai sonuç, yalnızca toplu yazılır.
local function FlushDirtyPatternLog()
    local queries = {}
    for trapHouseId in pairs(dirtyPatternLog) do
        local buckets = patternLog[trapHouseId]
        if buckets then
            local flushedSnap = patternLogFlushed[trapHouseId]
            if not flushedSnap then
                flushedSnap = {}
                patternLogFlushed[trapHouseId] = flushedSnap
            end
            for key, count in pairs(buckets) do
                local already = flushedSnap[key] or 0
                local delta = count - already
                if delta > 0 then
                    local wday, hour = key:match('^(%d+)_(%d+)$')
                    if wday and hour then
                        queries[#queries + 1] = {
                            query = [[
                                INSERT INTO matrix_pattern_log (trap_house_id, day_of_week, hour_of_day, occurrence_count)
                                VALUES (?, ?, ?, ?)
                                ON DUPLICATE KEY UPDATE occurrence_count = occurrence_count + VALUES(occurrence_count)
                            ]],
                            values = { trapHouseId, tonumber(wday), tonumber(hour), delta }
                        }
                        flushedSnap[key] = count
                    end
                end
            end
        end
        dirtyPatternLog[trapHouseId] = nil
    end


    if #queries == 0 then return end


    local ok, err = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or err == false then
        Matrix.Log('BUREAU', '[HATA][SEC-5] FlushDirtyPatternLog transaction basarisiz (yutulmadi, log icin): %s', tostring(err))
    end
end


local function ComputePatternRegularity(trapHouseId)
    local buckets = patternLog[trapHouseId]
    if not buckets then return 0.0 end


    local total, maxBucket = 0, 0
    for _, count in pairs(buckets) do
        total = total + count
        if count > maxBucket then maxBucket = count end
    end
    if total == 0 then return 0.0 end
    return maxBucket / total
end


-- =====================================================================
-- DECRYPTION (dirty-set)
-- =====================================================================
function Matrix.Bureau.AdvanceDecryption(trapHouseId, amount)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end


    amount = tonumber(amount) or 0.0
    if amount ~= amount then amount = 0.0 end


    -- ★ [GLOBAL CONVAR] server.cfg'deki 'matrix_bureau_intensity' ConVar'i
    -- ile CANLI/uzaktan olceklenir (bkz. Matrix.Bureau.GetBureaucraticVelocity,
    -- dosya sonu). Buro'nun TUM ogrenme/desifre kazanclari BU TEK noktadan
    -- gectigi icin ayri bir "devriye frekansi" carpani ICAT EDILMEZ.
    amount = amount * Matrix.Bureau.GetBureaucraticVelocity()


    house.decryption_confidence = Matrix.Clamp(house.decryption_confidence + amount, 0.0, 1.0)
    dirtyDecryption[trapHouseId] = true


    if house.decryption_confidence >= Config.Bureau.RaidDecryptionThreshold and not house.raid_ordered then
        Matrix.Bureau.IssueRaid(trapHouseId)
    end
end


-- ★ [SEC-3] Artık N ayrı MySQL.prepare yerine TEK bir MySQL.transaction
-- (deadlock korumali, atomik commit). NOT: FlushDirtyDecryption bu
-- revizyondan ÖNCE de aşağıdaki FLUSH LOOP tarafından periyodik olarak
-- çağrılıyordu (adli denetim raporundaki "dosyanın hiçbir yerinde
-- çağrılmıyor" iddiası, BU DOSYA için YANLIŞTI) -- burada değişen SADECE
-- yazma stratejisi (batch+transaction) ve aşağıdaki
-- txAdmin:events:serverShuttingDown güvenlik ağıdır.
local function FlushDirtyDecryption()
    local queries = {}
    for id in pairs(dirtyDecryption) do
        local h = Matrix.TrapHouses[id]
        if h then
            queries[#queries + 1] = {
                query  = 'UPDATE matrix_trap_houses SET decryption_confidence = ? WHERE id = ?',
                values = { h.decryption_confidence, id }
            }
        end
        dirtyDecryption[id] = nil
    end
    if #queries == 0 then return end
    local ok, err = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or err == false then
        Matrix.Log('BUREAU', '[HATA][SEC-3] FlushDirtyDecryption transaction basarisiz (yutulmadi, log icin): %s', tostring(err))
    end
end


-- =====================================================================
-- COMMS TRIANGULATION (IDW)
-- =====================================================================
function Matrix.Bureau.OnUnencryptedComms(actorRef, coords)
    if not IsValidCoords(coords) then return nil end


    local actor = Matrix.ResolveActor(actorRef)


    local hitTowers = {}
    for _, tower in ipairs(Config.Bureau.CellTowers) do
        if VectorDistance(coords, tower.coords) <= Config.Bureau.TowerRange then
            hitTowers[#hitTowers + 1] = tower
        end
    end
    if #hitTowers == 0 then return nil end


    local sumX, sumY, sumZ, sumWeight = 0.0, 0.0, 0.0, 0.0
    for _, tower in ipairs(hitTowers) do
        local d = math_max(VectorDistance(coords, tower.coords), 1.0)
        local w = 1.0 / d
        sumX = sumX + (tower.coords.x * w)
        sumY = sumY + (tower.coords.y * w)
        sumZ = sumZ + (tower.coords.z * w)
        sumWeight = sumWeight + w
    end
    if sumWeight <= 0.0 then return nil end


    local estimate = vector3(sumX / sumWeight, sumY / sumWeight, sumZ / sumWeight)
    local narrowedRadius = Config.Bureau.BaseSearchRadius / #hitTowers


    local trapHouseId, distToTrap = FindNearestTrapHouse(estimate)
    if not trapHouseId or distToTrap > narrowedRadius then
        return { estimate = estimate, radius = narrowedRadius }
    end


    Matrix.Bureau.LogPatternEvent(trapHouseId)

    -- ★ [T4] Her gerçek üçgenleme isabeti (telsiz ihlali) aynı zamanda
    -- Büro'nun kalıcı öğrenme hafızasına da işlenir. Bureau'nun KENDİ
    -- üçgenleme/deşifre formülüne (aşağıdaki satırlar) HİÇ dokunulmadı;
    -- bu tek satır yalnızca ek bir gözlemcidir (bkz. dosya sonu [T4] bloğu).
    if Matrix.Bureau.RecordRadioBreach then
        Matrix.Bureau.RecordRadioBreach(trapHouseId)
    end


    local heat = cyberLeakHeatmap[trapHouseId] or 0.0
    local normRadius = math_max(narrowedRadius / Config.Bureau.BaseSearchRadius, 0.01)
    local gain = (Config.Bureau.TriangulationDecryptionGain / normRadius)
                 * (1.0 + heat)
                 / #hitTowers
    gain = Matrix.Clamp(gain, 0.0, 0.5)


    Matrix.Bureau.AdvanceDecryption(trapHouseId, gain)


    Matrix.Log('BUREAU', 'Üçgenleme (%s): %d istasyon, r=%.1fm, trap #%d kazanç=%.4f',
        (actor and actor.dna_id) or 'UNKNOWN', #hitTowers, narrowedRadius, trapHouseId, gain)


    return { estimate = estimate, radius = narrowedRadius, trap_house_id = trapHouseId, gain = gain }
end


-- =====================================================================
-- PROPAGANDA
-- momentum' = min(momentum*GeometricFactor + Increment, MaxMomentum)
-- Doğrusal özyineleme x_(n+1) = a*x_n + b, a>1 → sabit nokta negatif
-- → tavan olmadan sınırsız büyür → MaxMomentum SERT tavanı.
-- =====================================================================
function Matrix.Bureau.TriggerPropaganda(trapHouseId)
    if type(trapHouseId) ~= 'number' or not Matrix.TrapHouses[trapHouseId] then return 0.0, 0.0 end


    propagandaMomentum = math_min(
        (propagandaMomentum * Config.Bureau.PropagandaGeometricFactor)
            + Config.Bureau.PropagandaMomentumIncrement,
        Config.Bureau.PropagandaMaxMomentum
    )


    local currentHeat = cyberLeakHeatmap[trapHouseId] or 0.0
    currentHeat = math_min(
        (currentHeat * Config.Bureau.CyberLeakGeometricFactor)
            + Config.Bureau.CyberLeakIncrement,
        Config.Bureau.CyberLeakMaxIntensity
    )
    cyberLeakHeatmap[trapHouseId] = currentHeat
    dirtyIntel[trapHouseId]       = true


    Matrix.Log('BUREAU', 'Propaganda: momentum=%.2f, trap #%d heat=%.2f',
        propagandaMomentum, trapHouseId, currentHeat)


    return propagandaMomentum, currentHeat
end


function Matrix.Bureau.GetPropagandaMomentum()
    return propagandaMomentum
end


-- ★ KATMAN 5: salt-okunur getter (market.lua'nın Taktik HUD'u için). Var
-- olan cyberLeakHeatmap'i okur — Büro'nun formüllerinin KENDİSİNE dokunmaz.
function Matrix.Bureau.GetHeat(trapHouseId)
    return cyberLeakHeatmap[trapHouseId] or 0.0
end


-- ★ [SEC-3] bkz. FlushDirtyDecryption yorumu -- aynı batch+transaction disiplini.
local function FlushDirtyIntel()
    local queries = {}
    for id in pairs(dirtyIntel) do
        local heat = cyberLeakHeatmap[id] or 0.0
        queries[#queries + 1] = {
            query  = [[
                INSERT INTO matrix_bureau_intel (trap_house_id, category, intensity, updated_at)
                VALUES (?, 'cyber_leak', ?, NOW())
                ON DUPLICATE KEY UPDATE intensity = VALUES(intensity), updated_at = NOW()
            ]],
            values = { id, heat }
        }
        dirtyIntel[id] = nil
    end
    if #queries == 0 then return end
    local ok, err = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or err == false then
        Matrix.Log('BUREAU', '[HATA][SEC-3] FlushDirtyIntel transaction basarisiz (yutulmadi, log icin): %s', tostring(err))
    end
end


-- =====================================================================
-- TICK (pasif örüntü analizi)
-- gain = PatternAnalysisGain * regularity * (1.0 + heat)
-- =====================================================================
function Matrix.Bureau.Tick()
    for trapHouseId, house in pairs(Matrix.TrapHouses) do
        if not house.raid_ordered then
            local regularity = ComputePatternRegularity(trapHouseId)
            local heat       = cyberLeakHeatmap[trapHouseId] or 0.0
            local gain       = Config.Bureau.PatternAnalysisGain * regularity * (1.0 + heat)


            if gain > 0.0 then
                Matrix.Bureau.AdvanceDecryption(trapHouseId, gain)
            end
        end
    end
end


-- =====================================================================
-- RAID (deterministik mürettebat/breach/kaçış matrisi)
-- =====================================================================
local function ComputeRaidSquad(trapHouseId, house)
    local heat = cyberLeakHeatmap[trapHouseId] or 0.0
    local squadSize = math_floor(Config.Bureau.RaidBaseSquadSize + (heat * Config.Bureau.RaidHeatSquadFactor) + 0.5)
    squadSize = math_max(Config.Bureau.RaidBaseSquadSize, math_min(squadSize, Config.Bureau.RaidMaxSquadSize))


    local breachMethod = (house.decryption_confidence >= Config.Bureau.RaidExplosiveBreachThreshold)
        and 'explosive' or 'ram'


    local escapeWindow = Config.Bureau.RaidBaseEscapeWindowSeconds
    for _, zone in ipairs(Config.Logistics.DeadZones) do
        if VectorDistance(house.coords, zone.coords) <= zone.radius then
            escapeWindow = escapeWindow + Config.Bureau.RaidDeadZoneEscapeBonusSeconds
            break
        end
    end


    -- ★ [K6] KAPI SÜRGÜ TAHKİMATI KÖPRÜSÜ (server/door_reinforcement.lua):
    -- sürgü/barikat seviyesi kapı kırılma süresine (escapeWindow) bir bonus
    -- ekler. Hook yoksa (modül yüklü değilse, ya da hata verirse) davranış
    -- BİREBİR ESKİSİ GİBİDİR — bu satırlar Büro'nun kendi mürettebat/breach
    -- formülüne HİÇ dokunmaz, yalnızca sonuca eklenen dışsal bir terimdir.
    if Matrix.DoorReinforcement and Matrix.DoorReinforcement.GetBreachDelaySeconds then
        local ok, bonus = pcall(Matrix.DoorReinforcement.GetBreachDelaySeconds, trapHouseId)
        if ok and type(bonus) == 'number' and bonus == bonus and bonus > 0.0 then
            escapeWindow = escapeWindow + bonus
        end
    end


    return squadSize, breachMethod, escapeWindow
end


function Matrix.Bureau.IssueRaid(trapHouseId)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end
    if house.raid_ordered then return end


    local decryptionAtRaid = house.decryption_confidence
    local squadSize, breachMethod, escapeWindow = ComputeRaidSquad(trapHouseId, house)


    house.raid_ordered          = true
    house.decryption_confidence = Config.Bureau.PostRaidDecryptionReset
    cyberLeakHeatmap[trapHouseId] = (cyberLeakHeatmap[trapHouseId] or 0.0) * Config.Bureau.PostRaidHeatmapDecay
    patternLog[trapHouseId]     = {}
    -- ★ [SEC-5] RAM sıfırlandığında "DB'ye en son yazılan" anlık görüntü de
    -- sıfırlanmalı -- yoksa bir sonraki FlushDirtyPatternLog, yeni (küçük)
    -- RAM değerlerini eski (yüksek) anlık görüntüyle kıyaslayıp negatif
    -- delta üretir ve yazım sessizce durur (bkz. FlushDirtyPatternLog yorumu).
    patternLogFlushed[trapHouseId] = nil


    MySQL.prepare([[
        UPDATE matrix_trap_houses
        SET raid_ordered = 1, last_raid_at = NOW(),
            decryption_confidence = ?, cyber_leak_intensity = ?
        WHERE id = ?
    ]], {
        Config.Bureau.PostRaidDecryptionReset,
        cyberLeakHeatmap[trapHouseId],
        trapHouseId
    })


    MySQL.insert([[
        INSERT INTO matrix_raid_log (
            trap_house_id, squad_size, breach_method, decryption_confidence_at_raid,
            escape_window_seconds, outcome, created_at
        ) VALUES (?, ?, ?, ?, ?, 'pending', NOW())
    ]], { trapHouseId, squadSize, breachMethod, decryptionAtRaid, escapeWindow },
    function(insertId)
        if insertId then RaidLogIdByTrapHouse[trapHouseId] = insertId end
    end)


    TriggerClientEvent('matrix:client:executeRaid', -1, trapHouseId, house.coords, {
        squad_size    = squadSize,
        breach_method = breachMethod,
        escape_window = escapeWindow
    })


    -- ★ [K6] Pasif server-içi yayın: door_reinforcement.lua (yüklüyse) bu
    -- event'i dinleyerek kapı kırılma geri sayımını kendi tarafında başlatır.
    -- Bureau'nun KENDİ mantığı bu event'in var olup olmamasından etkilenmez.
    TriggerEvent('matrix:internal:raidIssued', trapHouseId, escapeWindow, breachMethod, squadSize)

    -- ★ [T4] Bir baskın = Büro'nun eline geçen ürünün saflığı ölçülür. Bu,
    -- learning-core'un average_purity_intercepted'ini besler (bkz. dosya
    -- sonu [T4] bloğu). Kitchen batch verisi yoksa (o trap house hiç üretim
    -- yapmamışsa) sessizce atlanır -- sahte bir 0 örneği EKLENMEZ.
    if Matrix.Bureau.RecordPurityIntercepted then
        Matrix.Bureau.RecordPurityIntercepted(trapHouseId)
    end


    Matrix.Log('BUREAU', '[ŞAFAK BASKINI] Trap house #%d (%s): %d birim, breach=%s, kaçış=%ds.',
        trapHouseId, house.label, squadSize, breachMethod, escapeWindow)
end


local VALID_RAID_OUTCOMES = { captured = true, escaped = true, eliminated = true }


function Matrix.Bureau.ResolveRaidOutcome(trapHouseId, outcome)
    if not VALID_RAID_OUTCOMES[outcome] then return false end
    local logId = RaidLogIdByTrapHouse[trapHouseId]
    if not logId then return false end


    MySQL.prepare('UPDATE matrix_raid_log SET outcome = ?, resolved_at = NOW() WHERE id = ?', { outcome, logId })


    -- ★ [K6] bkz. IssueRaid yorumu — geri sayımı sonlandırmak için simetrik yayın.
    TriggerEvent('matrix:internal:raidResolved', trapHouseId, outcome)


    Matrix.Log('BUREAU', 'Baskın (kayıt #%d, trap #%d) sonuçlandı: %s', logId, trapHouseId, outcome)
    return true
end


function Matrix.Bureau.ReceiveSnitchLeak(trapHouseId)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end


    local target = Config.Bureau.RaidDecryptionThreshold + 0.05
    if house.decryption_confidence < target then
        house.decryption_confidence = target
    end
    dirtyDecryption[trapHouseId] = true


    -- ★ [OPSEC-3] AKILLI ÖĞRENME KÖPRÜSÜ: bir bot kortizol kırılması
    -- yaşayıp köstebek olduğunda (matrix_snitch_events, server/kitchen.lua
    -- Matrix.Kitchen.OnCaptured — DEĞİŞTİRİLMEDİ, o zaten bu fonksiyonu
    -- çağırıyordu) bu istihbarat ARTIK RecordRadioBreach üzerinden [T4]
    -- learning-core'a da işlenir — LockdownCoefficient bu ikinci kanaldan
    -- da kalıcı olarak tırmanır. RecordRadioBreach dosyanın SONUNDA tanımlı
    -- olduğundan (ileri-referans) tanımsızsa (yükleme sırası bozulursa)
    -- guard sessizce atlar — Bureau'nun KENDİ decryption formülüne (yukarıda)
    -- HİÇ dokunulmadı.
    if Matrix.Bureau.RecordRadioBreach then
        Matrix.Bureau.RecordRadioBreach(trapHouseId)
    end
end


-- =====================================================================
-- FLUSH LOOP (dirty-set drene)
-- =====================================================================
CreateThread(function()
    local interval = Config.Persistence.TrapHouseFlushIntervalMs or 20000
    while true do
        Wait(interval)
        FlushDirtyDecryption()
        FlushDirtyIntel()
        FlushDirtyPatternLog()
    end
end)


-- =====================================================================
-- QB-PHONE CANLI YAYIN & SİBER PROPAGANDA
-- =====================================================================
function Matrix.Bureau.StartLivestream(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    if LivestreamSessions[src] then return false end


    -- ★ [ENVANTER MANİFESTOSU] Bir aktörün (oyuncu veya bot -- bu fonksiyon
    -- HER iki cagiran icin de TEK giris noktasidir) canli yayin baslatabilmesi
    -- icin uzerinde aktif bir 'burner_phone' (Config.Logistics.AmmoRunManifest
    -- ile lojistik botlarca sahada dagitilan item, bkz. shared/config.lua)
    -- bulunmasi ZORUNLUDUR.
    local searchOk, phoneCount = pcall(function()
        return exports['ox_inventory']:Search(src, 'count', 'burner_phone')
    end)
    if not searchOk or (tonumber(phoneCount) or 0) <= 0 then
        Matrix.Log('BUREAU', '[YAYIN REDDEDILDI] src=%s ustunde aktif burner_phone yok.', tostring(src))
        return false
    end


    local state = Matrix.GetOrCreatePlayerState(src)
    LivestreamSessions[src] = {
        started    = Matrix.Now(),
        citizenid  = state and state.citizenid,
        hype       = 1.0,
        heat_added = 0.0,
        trap_house_id = nil
    }
    Matrix.Log('BUREAU', '[CANLI YAYIN BAŞLADI] src=%d, IP çıkışı Büro siber taramasına açıldı.', src)
    return true
end


function Matrix.Bureau.StopLivestream(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    local session = LivestreamSessions[src]
    if not session then return false end
    LivestreamSessions[src] = nil


    local duration = Matrix.Now() - session.started
    MySQL.prepare([[
        INSERT INTO matrix_livestream_events (citizenid, duration_seconds, hype_multiplier, heat_added, trap_house_id, created_at)
        VALUES (?, ?, ?, ?, ?, NOW())
    ]], { session.citizenid, duration, session.hype, session.heat_added, session.trap_house_id })


    Matrix.Log('BUREAU', '[CANLI YAYIN BİTTİ] src=%d, süre=%ds, son hype=%.2f, eklenen heat=%.2f',
        src, duration, session.hype, session.heat_added)
    return true
end


RegisterNetEvent('matrix:server:reportLivestreamStart', function()
    Matrix.Bureau.StartLivestream(source)
end)


RegisterNetEvent('matrix:server:reportLivestreamStop', function()
    Matrix.Bureau.StopLivestream(source)
end)


CreateThread(function()
    while true do
        Wait(1000)
        for src, session in pairs(LivestreamSessions) do
            local ped = GetPlayerPed(src)
            -- ★ [KOR NOKTA] Aktif yayin, uzerinde bir 'burner_phone'
            -- (Config.BlackMarket.BurnerPhones) olmasini ZORUNLU kilar --
            -- eldeki hat cebinden cikarsa (satildi/el konuldu/vs.) yayin
            -- ANINDA kesilir. RNG YOK -- salt bir envanter varlik kontrolu.
            local searchOk, phoneCount = pcall(function()
                return exports['ox_inventory']:Search(src, 'count', 'burner_phone')
            end)
            local hasBurnerPhone = searchOk and (tonumber(phoneCount) or 0) > 0


            if not ped or ped == 0 then
                LivestreamSessions[src] = nil
            elseif not hasBurnerPhone then
                Matrix.Log('BUREAU',
                    '[YAYIN ZORLA KESILDI] src=%d ustunde aktif burner_phone bulunamadi -- StopLivestream tetiklendi.', src)
                Matrix.Bureau.StopLivestream(src)
            else
                session.hype = math_min(
                    (session.hype * Config.Bureau.LivestreamHypeGeometricFactor) + Config.Bureau.LivestreamHypeIncrementPerTick,
                    Config.Bureau.PropagandaMaxMomentum
                )


                propagandaMomentum = math_min(
                    (propagandaMomentum * Config.Bureau.PropagandaGeometricFactor) + Config.Bureau.PropagandaMomentumIncrement,
                    Config.Bureau.PropagandaMaxMomentum
                )


                local coords = GetEntityCoords(ped)
                local trapHouseId, dist = FindNearestTrapHouse(coords)
                if trapHouseId and dist <= Config.Bureau.BaseSearchRadius then
                    session.trap_house_id = trapHouseId


                    -- ★ KATMAN 5 KÖPRÜSÜ (market.lua): telsiz sessizliği aktifken
                    -- (/sessizlik) siber heatmap artışı ve buna bağlı deşifre
                    -- kazancı durur. Hook (Matrix.RadioSilence) yüklü değilse
                    -- davranış BİREBİR ESKİSİ GİBİDİR — üçgenleme/baskın/desifre
                    -- formüllerinin KENDİSİ bu revizyonda HİÇ değişmedi.
                    local silent = Matrix.RadioSilence and Matrix.RadioSilence.IsActive
                        and Matrix.RadioSilence.IsActive(session.citizenid)


                    if not silent then
                        local cyberSkill = 1.0
                        for _, bot in pairs(Matrix.Bots) do
                            if bot.state.trap_house_id == trapHouseId then
                                cyberSkill = Matrix.Kitchen.GetEffectiveSkill(bot, 'skill_cyber')
                                break
                            end
                        end
                        cyberSkill = math_max(cyberSkill, 0.1)


                        local heatGain = Config.Bureau.LivestreamHeatIncrementPerTick * cyberSkill
                        cyberLeakHeatmap[trapHouseId] = math_min(
                            ((cyberLeakHeatmap[trapHouseId] or 0.0) * Config.Bureau.CyberLeakGeometricFactor) + heatGain,
                            Config.Bureau.CyberLeakMaxIntensity
                        )
                        dirtyIntel[trapHouseId] = true
                        session.heat_added = session.heat_added + heatGain


                        Matrix.Bureau.AdvanceDecryption(trapHouseId, Config.Bureau.LivestreamDecryptionGainPerTick * cyberSkill)

                        -- ★ [T4 KÖPRÜ] Ayni "acik hat" pencerisi (silent
                        -- degilken) T4 Buro Kilidi ogrenme cekirdegini de
                        -- besler -- bkz. RecordLivestreamRadioLeak yorumu.
                        -- /sessizlik aktifken bu blok HIC calismaz, yani
                        -- radyo sessizligi livestream sizintisini da
                        -- KESER (cyberLeakHeatmap ile AYNI disiplin).
                        Matrix.Bureau.RecordLivestreamRadioLeak(trapHouseId, Config.Bureau.LivestreamRadioBreachMultiplier)
                    end
                end
            end
        end
    end
end)


-- =====================================================================
-- ★ REVİZYON #2: DEAD DROP ADLİ ÖRNEK TOPLAYICI ★
--
-- FORMÜL (Match_Certainty — deterministik birikim, RNG yok):
--   N           = samples listesindeki geçerli örnek sayısı
--   avgQ        = Σ(sample.quality) / N
--   volumeF     = min(1.0, N / RequiredSamplesForLeak)
--   heatF       = 1.0 + min(heat, CyberLeakMaxIntensity) * 0.15
--   recencyF    = exp(-elapsed_minutes * SampleDecayRate)
--   certainty   = clamp(avgQ * volumeF * heatF * recencyF, 0, 1)
--
-- Yorum: Kanıt KALİTESİ (avgQ), kanıt MİKTARI (volumeF — daha çok örnek
-- = daha kesin profil), yerel SİBER YOĞUNLUK (heatF — hedef bölgede
-- Büro gözetimi yoğunsa adli veri daha hızlı işlenir) ve tazelik
-- (recencyF — eski kanıt zamanla kontamine olur) ÇARPIMSAL etkileşir.
-- Çarpımsal zincir matematiksel olarak: certainty ∈ [0,1]; hiçbir terim
-- tek başına eşiği geçiremez, hepsi aynı yönde olmalıdır → gerçekçi
-- adli süreç simülasyonu.
-- =====================================================================


-- Config'te tanımlı olmayan sabitler için güvenli varsayılanlar.
-- (config.lua'ya Config.Bureau.BureauLeak* alanları eklenirse override edilir.)
local function CfgBureau(key, default)
    local v = Config.Bureau[key]
    if v == nil then return default end
    return v
end


local function NowEpoch()
    return os_time()
end


-- Yeni bir adli örnek kaydeder. logistics.lua OnPickup içinde
-- forensic_trace_left == true olduğunda çağrılır.
-- @param dropId      : number — dead drop ID
-- @param quality     : number [0,1] — bu örneğin adli kalitesi (parmak izi)
-- @param supplierId  : number — hangi toptancıya bağlı
-- @param citizenid   : string — teslim alımı kimin adına yapıldı
function Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
    dropId     = tonumber(dropId)
    supplierId = tonumber(supplierId)
    quality    = tonumber(quality) or 0.0
    if not dropId or not supplierId then return false end
    if quality ~= quality then quality = 0.0 end
    quality = Matrix.Clamp(quality, 0.0, 1.0)


    local rec = DropForensicsByDropId[dropId]
    if not rec then
        rec = {
            samples          = {},
            supplier_id      = supplierId,
            citizenid        = citizenid or 'UNKNOWN',
            leaked           = false,
            last_activity_at = NowEpoch()
        }
        DropForensicsByDropId[dropId] = rec
    end


    -- FIFO pencere (bellek O(sabit))
    local maxSamples = CfgBureau('MaxDropSamplesForLeak', 8)
    rec.samples[#rec.samples + 1] = { quality = quality, at = NowEpoch() }
    while #rec.samples > maxSamples do
        table.remove(rec.samples, 1)
    end
    rec.last_activity_at = NowEpoch()
    -- supplier_id / citizenid zaman içinde değişmez varsayımı (drop→toptancı
    -- config eşlemesi sabittir).


    Matrix.Log('BUREAU',
        '[ADLİ ÖRNEK] Drop #%d, kalite=%.3f (toplam örnek: %d, toptancı #%d)',
        dropId, quality, #rec.samples, rec.supplier_id)
    return true
end


-- Bir drop için Match_Certainty hesabı (yukarıdaki formül).
-- Saf fonksiyon: yan etkisi yoktur, RNG yoktur; aynı girdi → aynı çıktı.
local function ComputeDropForensicCertainty(dropId, rec)
    rec = rec or DropForensicsByDropId[dropId]
    if not rec or #rec.samples == 0 then return 0.0, 0.0, 0 end


    -- Zaman soğuması: her örnek kendi yaşına göre ağırlıklandırılır.
    -- Bu, eski kanıtın "unutulmasını" tek bir skalerle çarpmak yerine
    -- ağırlıklı ortalama ile ifade eder → daha doğru adli davranış.
    local decayRate  = CfgBureau('SampleDecayRate', 0.002)  -- dakika başına
    local now        = NowEpoch()
    local wSum, qSum = 0.0, 0.0
    for _, s in ipairs(rec.samples) do
        local ageMin = math_max((now - s.at) / 60.0, 0.0)
        local w      = math.exp(-ageMin * decayRate)
        qSum = qSum + (s.quality * w)
        wSum = wSum + w
    end
    if wSum <= 0.0 then return 0.0, 0.0, #rec.samples end


    local avgQ        = qSum / wSum
    local required    = CfgBureau('RequiredSamplesForLeak', 3)
    local volumeF     = math_min(1.0, #rec.samples / math_max(required, 1))
    -- heat, en yakın trap house üzerinden okunur (drop konumu zaten config'te).
    local heat        = 0.0
    local dropCfg
    if Config.Supplier and Config.Supplier.DeadDrops then
        for _, d in ipairs(Config.Supplier.DeadDrops) do
            if d.id == dropId then dropCfg = d break end
        end
    end
    if dropCfg then
        local trapId, trapDist = FindNearestTrapHouse(dropCfg.coords)
        if trapId and trapDist <= Config.Bureau.BaseSearchRadius then
            heat = cyberLeakHeatmap[trapId] or 0.0
        end
    end
    local heatF       = 1.0 + math_min(heat, Config.Bureau.CyberLeakMaxIntensity) * 0.15
    local certainty   = Matrix.Clamp(avgQ * volumeF * heatF, 0.0, 1.0)
    return certainty, avgQ, #rec.samples
end


-- Toptancıya deterministik istihbarat sızıntısı emisyonu.
-- Bu, "sihirli RNG" yerine tamamen ölçülebilir bir kanaldır: Büro
-- laboratuvarının birikmiş kesinliği + drop heatmap'i.
local function EmitSupplierIntelLeak(citizenid, supplierId, certainty, dropId)
    -- Trust cezası: certainty - threshold aralığını [Base, Max] penalty'ye
    -- DOĞRUSAL haritalar. Bu, kesinlik arttıkça sızıntının "daha ağır"
    -- olduğunu ifade eder.
    local threshold  = CfgBureau('BureauLeakCertaintyThreshold', 0.65)
    local basePen    = CfgBureau('BureauLeakTrustPenaltyBase', 0.15)
    local maxPen     = CfgBureau('BureauLeakTrustPenaltyMax',  0.45)
    local span       = math_max(1.0 - threshold, 0.001)
    local norm       = Matrix.Clamp((certainty - threshold) / span, 0.0, 1.0)
    local penalty    = basePen + (maxPen - basePen) * norm


    -- ★ KÖPRÜ: logistics.lua ApplyBureauIntelLeak hook'unu dene.
    if Matrix.Supplier and Matrix.Supplier.ApplyBureauIntelLeak then
        pcall(Matrix.Supplier.ApplyBureauIntelLeak, citizenid, supplierId, penalty, dropId)
    else
        -- Fallback: hook yoksa, doğrudan DB'ye yaz. Trust = GREATEST(0, trust-penalty).
        -- forensic_leaks sayacını arttır ki toptancı geçmişi izlenebilir kalsın.
        MySQL.prepare([[
            INSERT INTO matrix_supplier_trust
                (citizenid, supplier_id, trust, late_payments, forensic_leaks, created_at, updated_at)
            VALUES (?, ?, 0.5, 0, 1, NOW(), NOW())
            ON DUPLICATE KEY UPDATE
                trust          = GREATEST(0.0, trust - ?),
                forensic_leaks = forensic_leaks + 1,
                updated_at     = NOW()
        ]], { citizenid, supplierId, penalty })


        if not WARNED_MISSING_SUPPLIER_HOOK then
            WARNED_MISSING_SUPPLIER_HOOK = true
            Matrix.Log('BUREAU',
                '[UYARI] Matrix.Supplier.ApplyBureauIntelLeak hooku tanimli degil; dogrudan DB yazimi kullanildi (logistics.lua guncellemesi onerilir).')
        end
    end


    Matrix.Log('BUREAU',
        '[İSTİHBARAT SIZINTISI] Drop #%d → Toptancı #%d | Kesinlik=%.3f | Penalty=%.3f | Mağdur=%s',
        dropId, supplierId, certainty, penalty, tostring(citizenid))


    -- İnfaz mangası / betrayal eşiği tetiklenmesi logistics.lua'nın
    -- ApplyBureauIntelLeak'i içinde kontrol edilir (o dosya BetrayalTrustThreshold
    -- ve TriggerBetrayal'a sahiptir). Hook yoksa fallback DB yazımı sonrası
    -- bir sonraki GetTrust çağrısında otomatik betrayal kontrolü olur.
end


-- Ticker: her N saniyede bir drop forensic kayıtlarını değerlendirir.
-- Bu fonksiyon ayrı bir CreateThread içinde çalışır (master ticker'ı kirletmez).
-- KARMAŞIKLIK: O(D * S) burada D = aktif drop kaydı, S = örnek sayısı (≤8).
function Matrix.Bureau.TickDropForensics()
    local threshold  = CfgBureau('BureauLeakCertaintyThreshold', 0.65)
    local staleAfter = CfgBureau('DropForensicsStaleSeconds', 3600)  -- 1 saat


    local now = NowEpoch()
    local toRemove = {}


    for dropId, rec in pairs(DropForensicsByDropId) do
        -- (1) Tamamen bayat kayıtları buda
        if (now - (rec.last_activity_at or now)) > staleAfter then
            toRemove[#toRemove + 1] = dropId
        else
            -- (2) Kesinlik hesapla
            local certainty, avgQ, N = ComputeDropForensicCertainty(dropId, rec)


            -- (3) Eşik aşıldı VE henüz sızdırılmadıysa → tek seferlik emisyon
            if not rec.leaked and certainty >= threshold then
                rec.leaked = true
                EmitSupplierIntelLeak(rec.citizenid, rec.supplier_id, certainty, dropId)
            end


            -- (4) Debug/log amaçlı: sadece anlamlı değişim olduğunda bas
            if N > 0 and N % 3 == 0 then
                Matrix.Log('BUREAU',
                    '[ADLİ TAKİP] Drop #%d | Örnek:%d | avgQ:%.3f | Kesinlik:%.3f (eşik:%.2f) | Sızdı:%s',
                    dropId, N, avgQ, certainty, threshold, tostring(rec.leaked))
            end
        end
    end


    for _, id in ipairs(toRemove) do
        DropForensicsByDropId[id] = nil
    end
end


CreateThread(function()
    local interval = CfgBureau('DropForensicsTickIntervalSeconds', 30) * 1000
    while true do
        Wait(interval)
        local ok, err = pcall(Matrix.Bureau.TickDropForensics)
        if not ok then
            Matrix.Log('BUREAU', '[HATA] TickDropForensics hata verdi (yutuldu): %s', tostring(err))
        end
    end
end)


-- =====================================================================
-- EVENT BRIDGE (guard'lı)
-- =====================================================================
RegisterNetEvent('matrix:server:reportUnencryptedComms', function(coords)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not IsValidCoords(coords) then return end
    Matrix.Bureau.OnUnencryptedComms({ kind = 'player', source = src }, coords)
end)


RegisterNetEvent('matrix:server:triggerPropaganda', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    Matrix.Bureau.TriggerPropaganda(trapHouseId)
end)


RegisterNetEvent('matrix:server:reportLogisticsRun', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    Matrix.Bureau.LogPatternEvent(trapHouseId)
end)


RegisterNetEvent('matrix:server:reportRaidOutcome', function(trapHouseId, outcome)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    Matrix.Bureau.ResolveRaidOutcome(trapHouseId, outcome)
end)


-- ★ REVİZYON #2: Dış katmanlardan (logistics.lua) manuel adli örnek beslemesi.
-- logistics.lua OnPickup içinden çağrılır VEYA doğrudan bu event tetiklenir.
RegisterNetEvent('matrix:server:reportDeadDropForensic', function(dropId, quality, supplierId, citizenid)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
end)


-- =====================================================================
-- EXPORTLAR
-- =====================================================================
exports('TriggerPropaganda',      function(t) return Matrix.Bureau.TriggerPropaganda(t) end)
exports('ReportUnencryptedComms', function(a, c) return Matrix.Bureau.OnUnencryptedComms(a, c) end)
exports('ReportLogisticsRun',     function(t) return Matrix.Bureau.LogPatternEvent(t) end)
exports('ReceiveSnitchLeak',      function(t) return Matrix.Bureau.ReceiveSnitchLeak(t) end)
exports('IssueRaid',              function(t) return Matrix.Bureau.IssueRaid(t) end)
exports('ResolveRaidOutcome',     function(t, o) return Matrix.Bureau.ResolveRaidOutcome(t, o) end)


-- ★ REVİZYON #2 dışa açılımı (logistics.lua bu export'u çağırır)
exports('OnDeadDropForensicPickup', function(dropId, quality, supplierId, citizenid)
    return Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
end)
exports('TickDropForensics', function()
    return Matrix.Bureau.TickDropForensics()
end)


-- =====================================================================
-- MONOKROM TAKTİK DEBUG PANELİ
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[BUREAU]', msg } })
    else
        print(('[MATRIX:BUREAU:CONSOLE] %s'):format(msg))
    end
end


-- /coords'un ikinci satırı ("vector3(x, y, z)") config dosyalarına
-- yapıştırmak için virgüllüdür; oyuncular bunu (virgüllü haliyle) doğrudan
-- komutlara da yapıştırabiliyor. FiveM komut argümanlarını yalnızca
-- BOŞLUKTAN ayırdığı için "-1464.224," gibi trailing-comma'lı bir token
-- tonumber() ile hiç parse edilemez. Bu yüzden koordinat argümanlarındaki
-- virgüller tonumber'dan ÖNCE temizlenir (boşlukla ayrılmış doğru format
-- hâlâ çalışmaya devam eder — bu salt bir tolerans katmanıdır).
local function ParseCoordNumber(s)
    return tonumber((tostring(s or ''):gsub(',', '')))
end


-- ★ pcall'lı: MySQL.insert (veya IsValidCoords dışında herhangi bir şey)
-- beklenmedik şekilde hata verirse artık SESSİZCE yutulmuyor — chat'e
-- açık bir hata mesajı basılır VE server konsoluna loglanır. Önceki hâl
-- CreateTrapHouse'u pcall'sız çağırıyordu; bir DB hatası (örn. matrix.sql
-- hiç import edilmemişse tablo yok) komutun geri kalanını sessizce
-- durdurup oyuncuya HİÇBİR mesaj göstermeyebiliyordu.
RegisterCommand('traphouseekle', function(src, args)
    local label = args[1]
    local x, y, z = ParseCoordNumber(args[2]), ParseCoordNumber(args[3]), ParseCoordNumber(args[4])
    if not x or not y or not z then
        Reply(src, 'Kullanim: /traphouseekle [label] [x] [y] [z]  (boslukla ayirin, virgul KULLANMAYIN)'); return
    end


    local ok, errOrResult = pcall(Matrix.Bureau.CreateTrapHouse, label, vector3(x, y, z))
    if not ok then
        Reply(src, ('HATA: trap house olusturulamadi (%s). Server konsolunu kontrol edin.'):format(tostring(errOrResult)))
        Matrix.Log('BUREAU', '[HATA] /traphouseekle basarisiz: %s', tostring(errOrResult))
        return
    end
    if errOrResult == false then
        Reply(src, 'HATA: gecersiz koordinat.')
        return
    end


    Reply(src, 'Trap house olusturma istegi gonderildi (async). Birkac saniye sonra /traphousedurum ile dogrulayin.')
end, false)


RegisterCommand('traphousedurum', function(src, args)
    local id = tonumber(args[1])
    local house = id and Matrix.TrapHouses[id]
    if not house then Reply(src, 'Kullanim: /traphousedurum [id]'); return end


    Reply(src, ('#%d %s | Deşifre:%.4f/%.2f | Heat:%.3f | Düzenlilik:%.3f | Baskın:%s'):format(
        id, house.label, house.decryption_confidence, Config.Bureau.RaidDecryptionThreshold,
        cyberLeakHeatmap[id] or 0.0, ComputePatternRegularity(id), tostring(house.raid_ordered)))
end, false)


RegisterCommand('desifreekle', function(src, args)
    local id = tonumber(args[1])
    local amount = tonumber(args[2])
    if not id or not Matrix.TrapHouses[id] or not amount then
        Reply(src, 'Kullanim: /desifreekle [id] [miktar]'); return
    end
    Matrix.Bureau.AdvanceDecryption(id, amount)
    Reply(src, ('Trap #%d deşifre: %.4f'):format(id, Matrix.TrapHouses[id].decryption_confidence))
end, false)


RegisterCommand('propagandatetikle', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /propagandatetikle [id]'); return end
    local momentum, heat = Matrix.Bureau.TriggerPropaganda(id)
    Reply(src, ('Momentum:%.3f Heat:%.3f'):format(momentum, heat))
end, false)


RegisterCommand('baskinzorla', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /baskinzorla [id]'); return end
    Matrix.Bureau.IssueRaid(id)
    Reply(src, ('Trap #%d için baskın ZORLA tetiklendi (test modu).'):format(id))
end, false)


RegisterCommand('baskinsonuclandir', function(src, args)
    local id = tonumber(args[1])
    local outcome = args[2]
    if not id or not outcome then
        Reply(src, 'Kullanim: /baskinsonuclandir [id] [captured|escaped|eliminated]'); return
    end
    local ok = Matrix.Bureau.ResolveRaidOutcome(id, outcome)
    Reply(src, ok and 'Sonuç kaydedildi.' or 'Geçersiz sonuç veya aktif baskın kaydı yok.')
end, false)


RegisterCommand('yayinbaslat', function(src)
    local ok = Matrix.Bureau.StartLivestream(src)
    Reply(src, ok and 'Canlı yayın başlatıldı (test).' or 'Zaten yayında veya geçersiz src.')
end, false)


RegisterCommand('yayinbitir', function(src)
    local ok = Matrix.Bureau.StopLivestream(src)
    Reply(src, ok and 'Canlı yayın bitirildi (test).' or 'Aktif yayın bulunamadı.')
end, false)


RegisterCommand('momentumgoster', function(src)
    Reply(src, ('Propaganda momentum: %.4f'):format(propagandaMomentum))
end, false)


-- ★ REVİZYON #2 debug komutları
-- /dropsizintiekle [dropId] [kalite 0-1] [supplierId] [citizenid]
-- Belirtilen drop için manuel bir adli örnek ekler. Normalde logistics.lua
-- OnPickup içinden otomatik çağrılır; bu komut RNG beklemeden test sağlar.
RegisterCommand('dropsizintiekle', function(src, args)
    local dropId     = tonumber(args[1])
    local quality    = tonumber(args[2])
    local supplierId = tonumber(args[3])
    local citizenid  = args[4] or 'TEST-CID'
    if not dropId or not quality or not supplierId then
        Reply(src, 'Kullanim: /dropsizintiekle [dropId] [kalite 0-1] [supplierId] [citizenid]'); return
    end
    local ok = Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
    Reply(src, ok and ('Örnek eklendi. Toplam: %d'):format(#(DropForensicsByDropId[dropId] and DropForensicsByDropId[dropId].samples or {}))
              or 'Geçersiz parametre.')
end, false)


-- /dropsizintidurum - TÜM drop adli toplayıcılarının anlık durumu:
-- örnek sayısı, ortalama kalite, kesinlik, sızıntı durumu.
RegisterCommand('dropsizintidurum', function(src)
    local count = 0
    for dropId, rec in pairs(DropForensicsByDropId) do
        count = count + 1
        local certainty, avgQ, N = ComputeDropForensicCertainty(dropId, rec)
        Reply(src, ('Drop #%d → Toptancı #%d | Örnek:%d avgQ:%.3f Kesinlik:%.3f | Sızdı:%s | Mağdur:%s'):format(
            dropId, rec.supplier_id, N, avgQ, certainty,
            tostring(rec.leaked), tostring(rec.citizenid)))
    end
    Reply(src, ('--- Toplam %d drop adli kaydi ---'):format(count))
    Reply(src, ('BureauLeakCertaintyThreshold: %.2f'):format(CfgBureau('BureauLeakCertaintyThreshold', 0.65)))
end, false)


-- /dropsizintisifirla [dropId] - Bir drop'un birikmiş adli örneklerini sıfırlar
-- (test amaçlı; yeni bir suç döngüsünü baştan gözlemlemek için).
RegisterCommand('dropsizintisifirla', function(src, args)
    local dropId = tonumber(args[1])
    if not dropId then Reply(src, 'Kullanim: /dropsizintisifirla [dropId]'); return end
    if DropForensicsByDropId[dropId] then
        DropForensicsByDropId[dropId] = nil
        Reply(src, ('Drop #%d adli toplayicisi sifirlandi.'):format(dropId))
    else
        Reply(src, 'Bu drop için aktif adli kayit yok.')
    end
end, false)


-- =====================================================================
-- ★★★ KATMAN 7 [T4] FAZ 1: BÜRO KİLİDİ (NÜKLEER ABLUKA) ★★★
-- Aşağıdaki blok TAMAMEN YENİ bir EKLEMEDİR. Yukarıdaki hiçbir formül/
-- tablo/davranış DEĞİŞTİRİLMEDİ — yalnızca iki tek-satırlık gözlemci
-- (OnUnencryptedComms içinde RecordRadioBreach, IssueRaid içinde
-- RecordPurityIntercepted çağrıları) eklendi; onlar da bu bloktaki
-- fonksiyonlar tanımlı DEĞİLSE hiçbir şey yapmaz.
--
-- AMAÇ: decryption_confidence/IssueRaid (tek trap house, %90 baraj, HER
-- BASKINDA RESETLENİR) zaten var. Bu blok bunun ÜZERİNE, "bu trap house
-- artık yakılmış" diyen İKİNCİ, kalıcı bir eşik ekler: BİRİKMİŞ telsiz
-- ihlali sayısı + ele geçirilen ürünün ortalama saflığı (matrix_kitchen_
-- batches.output_purity, server/kitchen.lua — [0,1] ölçeğinde, YÜZDE
-- DEĞİL). Eşik (%75) aşılınca matrix_bureau_learning_core.lockdown_active=1
-- olur; server/district_hubs.lua (yüklüyse) o trap house'un Toplu Satış
-- Hub'larını dondurur, server/market.lua Matrix.CashDecay.Launder o trap
-- house için kirli nakit aklamayı reddeder. Tek seferlik baskınların
-- aksine lockdown KENDİLİĞİNDEN resetlenmez — yalnızca katsayı yeniden
-- eşiğin altına düşünce kalkar (IssueRaid bu sayaçları da PostRaidHeatmap
-- Decay ile soğutur, aşağıda).
--
-- SIFIR RNG: bu blokta da math.random YOK.
-- =====================================================================

local learningCore      = {}   -- [trapHouseId] = { frequent_zones, radio_breach_count, average_purity_intercepted, lockdown_active }
local dirtyLearningCore = {}


local function GetLearningState(trapHouseId)
    local state = learningCore[trapHouseId]
    if not state then
        state = {
            frequent_zones             = {},
            radio_breach_count         = 0,
            average_purity_intercepted = 0.0,
            lockdown_active            = false
        }
        learningCore[trapHouseId] = state
    end
    return state
end


-- ★ [T4] Sunucu her başladığında matrix_bureau_learning_core RAM'e
-- kilitlenir — LoadTrapHouses ile AYNI kalıp (bkz. dosya başı). Ayrı bir
-- tablo, çünkü matrix_bureau_intel (mevcut) yalnızca heat/triangulation/
-- pattern yoğunluğu taşır; radio_breach_count/average_purity_intercepted/
-- lockdown_active bambaşka, kalıcı bir sözleşmedir (raid'lerde SIFIRLANMAZ).
function Matrix.Bureau.LoadLearningCore()
    local rows = MySQL.query.await('SELECT * FROM matrix_bureau_learning_core', {}) or {}
    for _, row in ipairs(rows) do
        local zones = {}
        if row.frequent_zones and row.frequent_zones ~= '' then
            local ok, decoded = pcall(json.decode, row.frequent_zones)
            if ok and type(decoded) == 'table' then zones = decoded end
        end
        learningCore[row.trap_house_id] = {
            frequent_zones             = zones,
            radio_breach_count         = tonumber(row.radio_breach_count) or 0,
            average_purity_intercepted = tonumber(row.average_purity_intercepted) or 0.0,
            purity_sample_count        = tonumber(row.purity_sample_count) or 0,
            lockdown_active            = row.lockdown_active == 1
        }
    end
    Matrix.Log('BUREAU', '[T4] %d ogrenme hafizasi kaydi RAM onbellege kilitlendi.', #rows)
end


CreateThread(function()
    Matrix.Bureau.LoadLearningCore()
end)


-- ★ [SEC-3] bkz. FlushDirtyDecryption yorumu -- aynı batch+transaction disiplini.
local function FlushDirtyLearningCore()
    local queries = {}
    for trapHouseId in pairs(dirtyLearningCore) do
        local state = learningCore[trapHouseId]
        if state then
            queries[#queries + 1] = {
                query = [[
                    INSERT INTO matrix_bureau_learning_core
                        (trap_house_id, frequent_zones, radio_breach_count, average_purity_intercepted, purity_sample_count, lockdown_active, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, NOW())
                    ON DUPLICATE KEY UPDATE
                        frequent_zones             = VALUES(frequent_zones),
                        radio_breach_count         = VALUES(radio_breach_count),
                        average_purity_intercepted = VALUES(average_purity_intercepted),
                        purity_sample_count        = VALUES(purity_sample_count),
                        lockdown_active            = VALUES(lockdown_active),
                        updated_at                 = NOW()
                ]],
                values = {
                    trapHouseId,
                    json.encode(state.frequent_zones),
                    state.radio_breach_count,
                    state.average_purity_intercepted,
                    state.purity_sample_count or 0,
                    state.lockdown_active and 1 or 0
                }
            }
        end
        dirtyLearningCore[trapHouseId] = nil
    end
    if #queries == 0 then return end
    local ok, err = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or err == false then
        Matrix.Log('BUREAU', '[HATA][SEC-3] FlushDirtyLearningCore transaction basarisiz (yutulmadi, log icin): %s', tostring(err))
    end
end


CreateThread(function()
    local interval = Config.Persistence.TrapHouseFlushIntervalMs or 20000
    while true do
        Wait(interval)
        FlushDirtyLearningCore()
    end
end)


-- =====================================================================
-- ★ [SEC-3] KAPANIŞ GÜVENLİK AĞI: sunucu txAdmin üzerinden (veya normal
-- `stop`/restart) kapanırken periyodik flush thread'lerinin (Wait ile
-- uykuda) bir sonraki tikini BEKLEMEDEN, dört dirty-set'in TAMAMINI
-- senkron biçimde diske yazar. Bu olmadan: son <TrapHouseFlushIntervalMs
-- (varsayılan 20sn) içindeki TÜM deşifre/heat/öğrenme-çekirdeği/pattern
-- ilerlemesi kapanışta buharlaşırdı.
-- =====================================================================
AddEventHandler('txAdmin:events:serverShuttingDown', function()
    Matrix.Log('BUREAU', '[SEC-3] Sunucu kapaniyor -- dirty-set son kurtarma flush islemi baslatildi.')
    local ok, err = pcall(function()
        FlushDirtyDecryption()
        FlushDirtyIntel()
        FlushDirtyPatternLog()
        FlushDirtyLearningCore()
    end)
    if not ok then
        Matrix.Log('BUREAU', '[HATA][SEC-3] Kapanis flush islemi sirasinda hata (yutulmadi, log icin): %s', tostring(err))
    else
        Matrix.Log('BUREAU', '[SEC-3] Kapanis flush islemi tamamlandi.')
    end
end)


-- =====================================================================
-- ★ [SEC-5] PATTERN LOG TAZELİK (DECAY) ROTİNİ
-- DENETİM NOTU: patternLog[trapHouseId] anahtar sayısı zaten sabit bir
-- tavana sahiptir (7 gün × 24 saat = en fazla 168 bucket/trap house,
-- IssueRaid'de sıfırlanır) -- yani klasik anlamda bir "bellek sızıntısı"
-- (tablo boyutu sınırsız büyümüyor) TESPİT EDİLMEDİ. Buna rağmen bucket
-- DEĞERLERİ (occurrence_count) bir trap house hiç baskına uğramadan
-- ay/yıllarca ayakta kalırsa sınırsız büyüyebilir ve ÇOK eski davranış
-- verisi "düzenlilik" (regularity) sinyalini süresiz etkilemeye devam
-- eder (taze olmayan istihbarat). Bu rutin, periyodik olarak TÜM
-- bucket'ları katsayı ile küçülterek (exponential decay) hem değer
-- büyümesini sınırlar hem de eski örüntülerin ağırlığını zamanla azaltır
-- -- ComputePatternRegularity'nin formülüne (maxBucket/total) DOKUNULMADI.
-- =====================================================================
local PATTERN_DECAY_INTERVAL_MS = 24 * 60 * 60 * 1000 -- 24 saat
local PATTERN_DECAY_FACTOR      = 0.5

CreateThread(function()
    while true do
        Wait(PATTERN_DECAY_INTERVAL_MS)
        for trapHouseId, buckets in pairs(patternLog) do
            local changed = false
            for key, count in pairs(buckets) do
                local decayed = math_floor(count * PATTERN_DECAY_FACTOR)
                if decayed ~= count then
                    buckets[key] = decayed
                    changed = true
                end
            end
            if changed then
                dirtyPatternLog[trapHouseId] = true
            end
        end
        Matrix.Log('BUREAU', '[SEC-5] Pattern log tazelik rotini calisti (x%.2f decay).', PATTERN_DECAY_FACTOR)
    end
end)


-- Deterministik kanıt katsayısı: breachRatio*BreachWeight + purityRatio*PurityWeight,
-- her ikisi de [0,1]'e kırpılır. average_purity_intercepted zaten [0,1]
-- ölçeğinde (bkz. matrix_kitchen_batches.output_purity), ayrı bir tavan
-- sabiti İCAT EDİLMEZ.
local function ComputeLockdownCoefficient(trapHouseId)
    local state = GetLearningState(trapHouseId)
    local breachRatio = math_min(state.radio_breach_count / Config.Bureau.LockdownBreachCeiling, 1.0)
    local purityRatio = math_min(state.average_purity_intercepted, 1.0)
    return (breachRatio * Config.Bureau.LockdownBreachWeight) + (purityRatio * Config.Bureau.LockdownPurityWeight)
end


local function EvaluateLockdown(trapHouseId)
    local state       = GetLearningState(trapHouseId)
    local coefficient = ComputeLockdownCoefficient(trapHouseId)

    if coefficient >= Config.Bureau.LockdownEvidenceThreshold and not state.lockdown_active then
        Matrix.Bureau.TriggerLockdown(trapHouseId, coefficient)
    elseif coefficient < Config.Bureau.LockdownEvidenceThreshold and state.lockdown_active then
        Matrix.Bureau.LiftLockdown(trapHouseId, coefficient)
    end

    return coefficient
end


local function MarkLearningZone(state, label)
    local zones = state.frequent_zones
    for i = 1, #zones do
        if zones[i] == label then return end
    end
    zones[#zones + 1] = label
end


-- Her gerçek üçgenleme isabetinde Matrix.Bureau.OnUnencryptedComms
-- tarafından çağrılır (bkz. dosya başındaki tek satırlık hook).
function Matrix.Bureau.RecordRadioBreach(trapHouseId)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    local state = GetLearningState(trapHouseId)
    state.radio_breach_count = state.radio_breach_count + 1
    MarkLearningZone(state, house.label)

    dirtyLearningCore[trapHouseId] = true
    EvaluateLockdown(trapHouseId)
end


-- ★★★ [T4 KÖPRÜ] CANLI YAYIN -> radio_breach_count (talep: "X3 çarpanla
-- üssel tırmanma, doğrudan besleme, deterministik %75 tetik") ★★★
-- RecordRadioBreach (üstte) GERÇEK bir üçgenleme isabetinde +1 TAM SAYI
-- yazar. Canlı yayın ise SÜREKLİ bir olaydır (StartLivestream tick'i,
-- her saniye) — saniyede +3 TAM SAYI yazmak "üssel tırmanma" değil ANLIK
-- patlama (12 saniyede LockdownBreachCeiling'e doyar) olurdu. Bunun
-- yerine KESİRLİ bir biriktirici kullanılır: her tick
-- LivestreamRadioLeakPerTick * multiplier kadar birikir, biriken değer
-- 1.0'ı her geçtiğinde radio_breach_count'a TAM SAYI bir birim düşer.
-- Sonuç AYNI sayaç, AYNI ComputeLockdownCoefficient/EvaluateLockdown
-- (DEĞİŞTİRİLMEDİ) — yeni bir eşik/formül İCAT EDİLMEZ.
-- SIFIR RNG: aynı süre + aynı multiplier HER ZAMAN aynı sayıda sentetik
-- ihlal üretir. Biriktirici DB'ye YAZILMAZ (yalnızca radio_breach_count
-- yazılır, bkz. FlushDirtyLearningCore) — sunucu yeniden başlarsa en
-- fazla <1 birimlik kesir kaybolur, dengeyi etkilemez.
function Matrix.Bureau.RecordLivestreamRadioLeak(trapHouseId, multiplier)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    local state = GetLearningState(trapHouseId)
    state.livestream_leak_accumulator = (state.livestream_leak_accumulator or 0.0)
        + (Config.Bureau.LivestreamRadioLeakPerTick * (multiplier or 1.0))

    local wholeBreaches = math_floor(state.livestream_leak_accumulator)
    if wholeBreaches < 1 then return end

    state.livestream_leak_accumulator = state.livestream_leak_accumulator - wholeBreaches
    state.radio_breach_count = state.radio_breach_count + wholeBreaches
    MarkLearningZone(state, house.label)

    dirtyLearningCore[trapHouseId] = true
    EvaluateLockdown(trapHouseId)
end


-- Matrix.Bureau.IssueRaid tarafından çağrılır (bkz. dosya ortasındaki tek
-- satırlık hook). Trap house'un EN SON kitchen batch'inin output_purity'sini
-- (matrix_kitchen_batches, server/kitchen.lua) hareketli ortalamaya ekler.
-- Kendi bağımsız sayacı (purity_sample_count) kullanır — radio_breach_count
-- İLE KARIŞTIRILMAZ, ikisi farklı olay akışlarını sayar.
function Matrix.Bureau.RecordPurityIntercepted(trapHouseId)
    if not Matrix.TrapHouses[trapHouseId] then return end

    MySQL.query('SELECT output_purity FROM matrix_kitchen_batches WHERE trap_house_id = ? ORDER BY id DESC LIMIT 1',
        { trapHouseId },
        function(rows)
            local row = rows and rows[1]
            if not row or row.output_purity == nil then return end

            local state  = GetLearningState(trapHouseId)
            local sample = Matrix.Clamp(tonumber(row.output_purity) or 0.0, 0.0, 1.0)

            state.purity_sample_count = (state.purity_sample_count or 0) + 1
            local n = state.purity_sample_count
            state.average_purity_intercepted = state.average_purity_intercepted + ((sample - state.average_purity_intercepted) / n)

            dirtyLearningCore[trapHouseId] = true
            EvaluateLockdown(trapHouseId)
        end)
end


function Matrix.Bureau.TriggerLockdown(trapHouseId, coefficient)
    local state = GetLearningState(trapHouseId)
    state.lockdown_active = true
    dirtyLearningCore[trapHouseId] = true

    -- ★ Pasif server-içi yayın (raidIssued/raidResolved İLE AYNI desen) —
    -- server/district_hubs.lua (yüklüyse) bunu dinleyip kendi hub'larını
    -- dondurur/çözer. Bureau'nun KENDİ mantığı bu event'in var olup
    -- olmamasından etkilenmez.
    TriggerEvent('matrix:internal:bureauLockdown', trapHouseId, true)

    local house = Matrix.TrapHouses[trapHouseId]
    Matrix.Log('BUREAU', '[T4][BURO KILIDI] Trap #%d (%s) icin NUKLEER ABLUKA DEVREDE (katsayi=%.3f/%.2f).',
        trapHouseId, (house and house.label) or '?', coefficient, Config.Bureau.LockdownEvidenceThreshold)
end


function Matrix.Bureau.LiftLockdown(trapHouseId, coefficient)
    local state = GetLearningState(trapHouseId)
    state.lockdown_active = false
    dirtyLearningCore[trapHouseId] = true

    TriggerEvent('matrix:internal:bureauLockdown', trapHouseId, false)

    local house = Matrix.TrapHouses[trapHouseId]
    Matrix.Log('BUREAU', '[T4][BURO KILIDI] Trap #%d (%s) ablukasi kalkti (katsayi=%.3f/%.2f).',
        trapHouseId, (house and house.label) or '?', coefficient, Config.Bureau.LockdownEvidenceThreshold)
end


function Matrix.Bureau.IsLockedDown(trapHouseId)
    local state = learningCore[trapHouseId]
    return state ~= nil and state.lockdown_active == true
end


-- ★ server/market.lua BuildSnapshot'un k6Lines bloğuna, Rendezvous/
-- DoorReinforcement İLE AYNI "hook-if-present" deseniyle takılması için
-- salt-okunur getter. Kilit yoksa nil döner (bulletin basılmaz).
function Matrix.Bureau.GetLockdownBulletin(trapHouseId)
    if not trapHouseId or not Matrix.Bureau.IsLockedDown(trapHouseId) then return nil end
    return '[ADLI ANOMALI: BURO KILIDI DEVREDE]', true
end


RegisterCommand('burokilitdurum', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /burokilitdurum [trapHouseId]'); return end

    local state       = GetLearningState(id)
    local coefficient = ComputeLockdownCoefficient(id)
    Reply(src, ('Trap #%d | Telsiz-Ihlali:%d Ort.Saflik:%.3f | Katsayi:%.3f/%.2f | Kilit:%s'):format(
        id, state.radio_breach_count, state.average_purity_intercepted,
        coefficient, Config.Bureau.LockdownEvidenceThreshold, tostring(state.lockdown_active)))
end, false)


-- /burokilitzorla [trapHouseId] - test amacli, esigi beklemeden kilidi
-- manuel tetikler (bkz. /baskinzorla ile AYNI disiplin/kapsam).
RegisterCommand('burokilitzorla', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /burokilitzorla [trapHouseId]'); return end
    Matrix.Bureau.TriggerLockdown(id, ComputeLockdownCoefficient(id))
    Reply(src, ('Trap #%d icin BURO KILIDI ZORLA tetiklendi (test modu).'):format(id))
end, false)


-- =====================================================================
-- ★ KATMAN 7 FAZ 2: F10 "OGRENEN BURO VERILERI / BURO KILIDI" PANELI
-- YENİ bir formül İCAT ETMEZ — dosyanın kendi [T4] blogundaki GetLearningState/
-- ComputeLockdownCoefficient'i (yukarıda tanımlı, DEĞİŞTİRİLMEDİ) aynen
-- /burokilitdurum'un okuduğu şekilde okuyup, client/hud.lua'nın F10 menüsü
-- için yapılandırılmış bir satır listesine döker (getRosterReport/
-- getRegionalFinancialReport İLE AYNI desen: her satırda hem ham alanlar
-- hem hazır 'text').
-- =====================================================================
lib.callback.register('matrix:callback:getLearningCoreReport', function(src)
    local entries = {}

    for trapHouseId, house in pairs(Matrix.TrapHouses) do
        local state       = GetLearningState(trapHouseId)
        local coefficient = ComputeLockdownCoefficient(trapHouseId)

        local text = ('Trap #%d (%s) | Telsiz-Ihlali:%d | Ort.Saflik:%.3f | Katsayi:%.3f/%.2f | Kilit:%s'):format(
            trapHouseId, house.label, state.radio_breach_count, state.average_purity_intercepted,
            coefficient, Config.Bureau.LockdownEvidenceThreshold, state.lockdown_active and 'DEVREDE' or 'kapali')

        entries[#entries + 1] = {
            trap_house_id              = trapHouseId,
            label                      = house.label,
            radio_breach_count         = state.radio_breach_count,
            average_purity_intercepted = state.average_purity_intercepted,
            coefficient                = coefficient,
            threshold                  = Config.Bureau.LockdownEvidenceThreshold,
            lockdown_active            = state.lockdown_active,
            text                       = text
        }
    end

    table.sort(entries, function(a, b) return a.trap_house_id < b.trap_house_id end)
    return entries
end)


-- =====================================================================
-- ★ [T4-3] GELECEKTEKİ OPENAI / CHATGPT ANALİZ KÖPRÜSÜ
-- PASİF, varsayılan KAPALI. Kilit kararı (EvaluateLockdown, yukarıda) bu
-- köprüyü HİÇ beklemez — PerformHttpRequest saf danışma/log amaçlıdır.
-- Devre dışıyken bu thread'in TEK işi Wait() içinde beklemektir: 0 Resmon.
-- İnternet kesilirse veya apiKey yapılandırılmamışsa sistem otomatik
-- olarak deterministik motora (yukarıdaki EvaluateLockdown) düşer — o
-- zaten bu köprüden bağımsız çalışıyordu, "düşmek" için hiçbir ekstra
-- kod gerekmez.
-- =====================================================================
CreateThread(function()
    while true do
        Wait((Config.AI_Matrix_Brain.analysisIntervalMinutes or 60) * 60000)

        if Config.AI_Matrix_Brain.enabled then
            local ok, err = pcall(Matrix.Bureau.RunAIAdvisoryPass)
            if not ok then
                Matrix.Log('BUREAU', '[T4][AI] RunAIAdvisoryPass hata verdi (yutuldu): %s', tostring(err))
            end
        end
    end
end)


function Matrix.Bureau.RunAIAdvisoryPass()
    if Config.AI_Matrix_Brain.provider ~= 'openai' or not Config.AI_Matrix_Brain.apiKey or Config.AI_Matrix_Brain.apiKey == 'sk-...' then
        Matrix.Log('BUREAU', '[T4][AI] enabled=true fakat apiKey yapilandirilmamis, deterministik motor degismeden devam ediyor.')
        return
    end

    local payload = {}
    for trapHouseId, state in pairs(learningCore) do
        payload[#payload + 1] = {
            trap_house_id              = trapHouseId,
            frequent_zones             = state.frequent_zones,
            radio_breach_count         = state.radio_breach_count,
            average_purity_intercepted = state.average_purity_intercepted,
            lockdown_active            = state.lockdown_active
        }
    end

    local body = json.encode({
        model = 'gpt-4o-mini',
        messages = {
            { role = 'system', content = 'You are a deterministic police-heat auditor for a GTA roleplay server. Summarize risk trends only, never invent data, never suggest a course of action.' },
            { role = 'user', content = json.encode(payload) }
        }
    })

    PerformHttpRequest('https://api.openai.com/v1/chat/completions', function(statusCode, response)
        if statusCode ~= 200 then
            Matrix.Log('BUREAU', '[T4][AI] OpenAI istegi basarisiz (HTTP %s); fallbackToDeterministic=%s, ogrenme motoru degismeden calismaya devam ediyor.',
                tostring(statusCode), tostring(Config.AI_Matrix_Brain.fallbackToDeterministic))
            return
        end

        local ok, decoded = pcall(json.decode, response)
        if not ok then
            Matrix.Log('BUREAU', '[T4][AI] OpenAI yaniti cozumlenemedi, deterministik motor etkilenmedi.')
            return
        end

        TriggerEvent('matrix:internal:aiAdvisoryReceived', decoded)
    end, 'POST', body, {
        ['Content-Type']  = 'application/json',
        ['Authorization'] = 'Bearer ' .. Config.AI_Matrix_Brain.apiKey
    })
end


-- =====================================================================
-- ★★★ [OPSEC FAZ 1] GİRDİ-TÜREVLİ POLİS KİŞİLİK GENETİĞİ + RÜŞVET
-- TEKLİFİ DEĞERLENDİRME MOTORU + AKILLI ÖĞRENME KÖPRÜSÜ ★★★
-- Aşağıdaki blok TAMAMEN YENİ bir EKLEMEDİR. Yukarıdaki hiçbir formül/
-- tablo/davranış DEĞİŞTİRİLMEDİ — tek istisna, dosyanın ortasındaki
-- Matrix.Bureau.ReceiveSnitchLeak'in SONUNA eklenen tek satırlık
-- RecordRadioBreach çağrısıdır (bkz. o fonksiyonun güncellenmiş yorumu).
--
-- [OPSEC-1] Memurların integrity/greed statüleri için matrix_bots veya
-- matrix_player_state'e YENİ bir sütun EKLENMEZ. server/blackmarket.lua'nın
-- ChecksumOf(raw, salt) deseni (BİREBİR AYNI formül; bu dosyada bağımsız
-- bir yerel kopya olarak tutulur — server/rendezvous.lua'nın da kendi
-- yerel ChecksumOf kopyasına sahip olmasıyla AYNI dosya-başı-yerel-yardımcı
-- konvansiyonu, paylaşımlı bir export İCAT EDİLMEZ) temel alınır: memurun
-- citizenid'i (veya NPC polis ise model hash + spawn koordinatı) salt=89
-- ile TEK bir sağlama toplamına indirgenir; bu toplam server/rendezvous.lua
-- ComputeHandoffCoords'un açı/mesafe ayrıştırmasıyla AYNI mod/bölme
-- deseniyle iki bağımsız-görünümlü [0,1] değere (integrity, greed) bölünür.
-- SIFIR RNG: aynı girdi HER ZAMAN aynı kişiliği üretir — DB sütunu YOK ama
-- saf/deterministik olduğu için sunucu restart'ında da DEĞİŞMEZ (RAM
-- önbelleği yalnızca tekrar hesaplamayı atlamak içindir, doğruluk için
-- gerekli DEĞİLDİR — Ballistic/Mole cache'leri İLE AYNI "lazy RAM cache"
-- felsefesi, bkz. server/forensics.lua BallisticCache).
--
-- [OPSEC-2] ProcessBribeOffer, Kitchen.ComputeSnitchIndex/SnitchThreshold
-- (server/kitchen.lua) İLE AYNI felsefeyi izler: bir "yozlaşma skoru"
-- sabit bir eşikle (BribeSuccessThreshold) karşılaştırılır — zar atışı
-- YOK. Şüphelinin kortizolü zaten var olan Config.Kitchen.SnitchThreshold
-- (0.75) eşiğini geçmişse (panik), rüşvet HİÇ HESAPLANMADAN reddedilir —
-- yeni bir eşik İCAT EDİLMEZ, mevcut sabit yeniden kullanılır.
--
-- [OPSEC-3] Akıllı Öğrenme Köprüsü: başarısız bir rüşvet teklifi (panik
-- reddi dahil) şüphelinin en yakın trap house'una Matrix.Bureau.
-- RecordRadioBreach çağrısıyla ANINDA işlenir — bu, ZATEN VAR OLAN [T4]
-- learning-core zincirini (EvaluateLockdown -> ComputeLockdownCoefficient)
-- tetikler, yeni bir kilit formülü İCAT EDİLMEZ; LockdownCoefficient bu
-- kanaldan da kalıcı olarak tırmanır.
-- =====================================================================


-- ★ server/blackmarket.lua GenerateScratchedPlate/GenerateWeaponSerial ve
-- server/rendezvous.lua ComputeHandoffCoords İLE BİREBİR AYNI formül —
-- dosyalar arası paylaşılan bir export YOKTUR (mevcut kod tabanının kendi
-- konvansiyonu), bu yüzden burada da bağımsız bir yerel kopya tutulur.
local function ChecksumOf(raw, salt)
    local sum = 0
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + salt))) % 0xFFFFFFF
    end
    return sum
end


-- [identityKey] = { integrity, greed } — saf/deterministik hesaplamayı
-- tekrarlamamak için RAM önbelleği (doğruluk için ZORUNLU değil, yalnızca
-- performans).
local PolicePersonalityCache = {}


-- ★ Memurun benzersiz kimliğini TEK bir string'e indirger: gerçek oyuncu
-- için citizenid yeterlidir (kalıcı, biricik); NPC polis için model hash +
-- spawn koordinatı (aynı NPC HER ZAMAN aynı kişiliği taşır — ikisi de
-- değişmeyen kimlik alanlarıdır, main.lua [H14]'ün sabit DEALER_PED_MODEL_
-- HASH deseniyle AYNI "kimlik = model + konum" mantığı).
function Matrix.Bureau.GetPolicePersonality(citizenid, npcModelHash, npcCoords)
    local identityKey
    if type(citizenid) == 'string' and citizenid ~= '' then
        identityKey = citizenid
    elseif npcModelHash ~= nil and IsValidCoords(npcCoords) then
        identityKey = ('NPC#%s#%.2f#%.2f#%.2f'):format(tostring(npcModelHash), npcCoords.x, npcCoords.y, npcCoords.z)
    else
        return nil
    end


    local cached = PolicePersonalityCache[identityKey]
    if cached then return cached end


    local sum = ChecksumOf(identityKey, 89)
    -- ComputeHandoffCoords'un açı/mesafe ayrıştırmasıyla AYNI mod/bölme
    -- deseni: TEK bir checksum'dan iki BAĞIMSIZ görünümlü [0,1] değer türetilir.
    local personality = {
        integrity = Matrix.Clamp((sum % 1000) / 1000.0, 0.0, 1.0),
        greed     = Matrix.Clamp((math_floor(sum / 1000) % 1000) / 1000.0, 0.0, 1.0)
    }
    PolicePersonalityCache[identityKey] = personality


    Matrix.Log('BUREAU', '[OPSEC][KISILIK GENETIGI] %s -> integrity=%.3f greed=%.3f (salt=89, deterministik)',
        identityKey, personality.integrity, personality.greed)
    return personality
end


-- =====================================================================
-- RÜŞVET EKONOMİSİ — door_reinforcement.lua/blackmarket.lua'nın KENDİ
-- ChargeCash desenleriyle AYNI Matrix.QBX:GetPlayer + Functions.RemoveMoney/
-- AddMoney kalıbı; yeni bir ödeme altyapısı İCAT EDİLMEZ.
-- =====================================================================
local function ChargeSuspectCash(src, amount)
    local ok, player = pcall(function() return Matrix.QBX:GetPlayer(src) end)
    if not ok or not player or not player.PlayerData then return false end


    local cash = (player.PlayerData.money and player.PlayerData.money.cash) or 0
    if cash < amount then return false end


    local removeOk, removeResult = pcall(function() return player.Functions.RemoveMoney('cash', amount, 'bribe-offer') end)
    return removeOk and removeResult == true
end


local function PaySuspectCashToOfficer(officerSrc, amount)
    local ok, officer = pcall(function() return Matrix.QBX:GetPlayer(officerSrc) end)
    if not ok or not officer then return false end
    pcall(function() officer.Functions.AddMoney('cash', amount, 'bribe-accepted') end)
    return true
end


-- =====================================================================
-- [OPSEC-2] RÜŞVET TEKLİFİ DEĞERLENDİRME MOTORU
--
-- FORMÜL (yozlaşma skoru, RNG YOK):
--   panik (suphelinin GUNCEL cortisol_level'i) > Config.Kitchen.
--   SnitchThreshold (0.75, MEVCUT sabit -- yeni esik ICAT EDILMEZ)
--     -> ANINDA red, HESAP YAPILMAZ, ogrenme koprusu tetiklenir.
--   Aksi halde:
--     moneyFactor = clamp(moneyAmount / BribeReferenceAmount, 0, Ceiling)
--                   * BribeMoneyWeight
--     score = greed*GreedWeight - integrity*IntegrityWeight
--             - panik*CortisolWeight + moneyFactor
--     score >= BribeSuccessThreshold -> KABUL (nakit memura gecer)
--     aksi halde -> RED (ogrenme koprusu tetiklenir)
-- =====================================================================
function Matrix.Bureau.ProcessBribeOffer(officerSrc, suspectSrc, moneyAmount, caseId)
    if type(officerSrc) ~= 'number' or officerSrc <= 0 then return false, 'bad_officer' end
    if type(suspectSrc) ~= 'number' or suspectSrc <= 0 then return false, 'bad_suspect' end
    moneyAmount = tonumber(moneyAmount) or 0.0
    if moneyAmount ~= moneyAmount or moneyAmount <= 0.0 then return false, 'bad_amount' end


    local officerState = Matrix.GetOrCreatePlayerState(officerSrc)
    local suspectState = Matrix.GetOrCreatePlayerState(suspectSrc)
    if not officerState or not officerState.citizenid then return false, 'officer_unresolved' end
    if not suspectState or not suspectState.citizenid then return false, 'suspect_unresolved' end


    local cortisol = Matrix.Clamp((suspectState.biology and suspectState.biology.cortisol_level) or 0.0, 0.0, 1.0)


    local suspectPed    = GetPlayerPed(suspectSrc)
    local suspectCoords = (suspectPed and suspectPed ~= 0) and GetEntityCoords(suspectPed) or nil
    local trapHouseId   = suspectCoords and FindNearestTrapHouse(suspectCoords)


    -- ★ [OPSEC-2] Panik eşiği: SnitchThreshold İLE AYNI, YENİ bir eşik
    -- İCAT EDİLMEZ. Panik halindeki şüpheli rüşvet görüşmesi YAPMAZ,
    -- adli süreç işler.
    if cortisol > Config.Kitchen.SnitchThreshold then
        if trapHouseId and Matrix.Bureau.RecordRadioBreach then
            Matrix.Bureau.RecordRadioBreach(trapHouseId)
        end
        Matrix.Log('BUREAU',
            '[RUSVET REDDEDILDI: PANIK] Supheli %s kortizol krizinde (%.3f > %.2f) -- adli surec isliyor.',
            suspectState.citizenid, cortisol, Config.Kitchen.SnitchThreshold)
        return false, { reason = 'suspect_panicking', cortisol = cortisol }
    end


    local personality = Matrix.Bureau.GetPolicePersonality(officerState.citizenid)
    if not personality then return false, 'officer_personality_unresolved' end


    local refAmount   = Config.Bureau.BribeReferenceAmount
    local moneyFactor = Matrix.Clamp(moneyAmount / math_max(refAmount, 1.0), 0.0, Config.Bureau.BribeMoneyFactorCeiling)
        * Config.Bureau.BribeMoneyWeight


    local score =
        (personality.greed * Config.Bureau.BribeGreedWeight)
        - (personality.integrity * Config.Bureau.BribeIntegrityWeight)
        - (cortisol * Config.Bureau.BribeCortisolWeight)
        + moneyFactor


    local threshold = Config.Bureau.BribeSuccessThreshold
    local success    = score >= threshold


    if success then
        local charged = ChargeSuspectCash(suspectSrc, moneyAmount)
        if charged then
            PaySuspectCashToOfficer(officerSrc, moneyAmount)
        end


        -- ★ [OPSEC FAZ 1 EK] KANIT ODASI SABOTAJI KÖPRÜSÜ: rüşvet başarılı
        -- olduğunda VE bir vaka (caseId/ballistic_id) belirtildiyse,
        -- server/forensics.lua Matrix.Forensics.TamperEvidenceLockup
        -- (yüklüyse) çağrılır — o fonksiyon greed eşiğini KENDİSİ AYRICA
        -- doğrular (çift-doğrulama, güvenli varsayılan; forensics.lua
        -- dosya-yükleme sırasında bu dosyadan ÖNCE gelse de bu çağrı
        -- RUNTIME'da yapıldığından güvenlidir).
        local tamperedCaseId = nil
        if type(caseId) == 'string' and caseId ~= '' and Matrix.Forensics and Matrix.Forensics.TamperEvidenceLockup then
            local tOk = Matrix.Forensics.TamperEvidenceLockup(officerState.citizenid, caseId, true)
            if tOk then tamperedCaseId = caseId end
        end


        Matrix.Log('BUREAU',
            '[RUSVET BASARILI] Memur %s (greed=%.3f integrity=%.3f) <- Supheli %s $%.0f | skor=%.3f/%.2f | odeme:%s | sabote-edilen-vaka:%s',
            officerState.citizenid, personality.greed, personality.integrity,
            suspectState.citizenid, moneyAmount, score, threshold, tostring(charged), tostring(tamperedCaseId))


        return true, { score = score, threshold = threshold, charged = charged, tampered_case = tamperedCaseId }
    end


    -- ★ [OPSEC-3] AKILLI ÖĞRENME KÖPRÜSÜ: başarısız teklif ANINDA
    -- learning-core'a (radio_breach_count) işlenir -- ZATEN VAR OLAN [T4]
    -- zincirini (EvaluateLockdown) tetikler, yeni bir formül İCAT EDİLMEZ.
    if trapHouseId and Matrix.Bureau.RecordRadioBreach then
        Matrix.Bureau.RecordRadioBreach(trapHouseId)
    end


    Matrix.Log('BUREAU',
        '[RUSVET REDDEDILDI] Memur %s (greed=%.3f integrity=%.3f) <- Supheli %s $%.0f | skor=%.3f/%.2f | adli surec isliyor',
        officerState.citizenid, personality.greed, personality.integrity,
        suspectState.citizenid, moneyAmount, score, threshold)


    return false, { score = score, threshold = threshold, reason = 'refused' }
end


-- =====================================================================
-- EVENT BRIDGE + DEBUG PANELİ (diğer tüm mekaniklerle AYNI disiplin)
-- =====================================================================
RegisterNetEvent('matrix:server:bureau:offerBribe', function(officerSrc, moneyAmount, caseId)
    local suspectSrc = source
    if type(suspectSrc) ~= 'number' or suspectSrc <= 0 then return end
    officerSrc = tonumber(officerSrc)
    if not officerSrc then return end


    local ok, resultOrReason = Matrix.Bureau.ProcessBribeOffer(officerSrc, suspectSrc, moneyAmount, caseId)
    local detail = (type(resultOrReason) == 'table' and resultOrReason.reason) or tostring(resultOrReason)


    TriggerClientEvent('matrix:client:actionNotify', suspectSrc, ok,
        ok and 'Memur rusveti kabul etti.' or ('Rusvet reddedildi: %s'):format(tostring(detail)))


    if officerSrc > 0 and officerSrc ~= suspectSrc then
        TriggerClientEvent('matrix:client:actionNotify', officerSrc, ok,
            ok and 'Bir supheli rusvet teklif etti ve kabul ettiniz.' or 'Bir supheli rusvet teklif etti, reddettiniz/panikledi.')
    end
end)


-- /rusvetteklifi [memurSrc] [miktar] [caseId(opsiyonel)] — diğer tüm test
-- komutlarıyla AYNI disiplin: kısıtlama YOK, sunucu ACE yapılandırmasına
-- bırakılır. caseId verilirse (bir ballistic_id) VE rüşvet başarılıysa VE
-- memurun greed'i yeterince yüksekse, forensics.lua TamperEvidenceLockup'ı
-- da tetikler (bkz. ProcessBribeOffer'ın güncellenmiş [OPSEC FAZ 1 EK] bloğu).
RegisterCommand('rusvetteklifi', function(src, args)
    local officerSrc  = tonumber(args[1])
    local moneyAmount = tonumber(args[2])
    local caseId      = args[3]
    if not officerSrc or not moneyAmount then
        Reply(src, 'Kullanim: /rusvetteklifi [memurSrc] [miktar] [caseId/ballisticId (opsiyonel)]'); return
    end


    local ok, resultOrReason = Matrix.Bureau.ProcessBribeOffer(officerSrc, src, moneyAmount, caseId)
    if ok then
        Reply(src, ('Rusvet KABUL EDILDI (skor:%.3f/%.2f)%s.'):format(
            resultOrReason.score, resultOrReason.threshold,
            resultOrReason.tampered_case and (' | Vaka #%s sabote edildi'):format(resultOrReason.tampered_case) or ''))
    else
        local detail = (type(resultOrReason) == 'table')
            and ('%s | skor:%.3f/%.2f'):format(tostring(resultOrReason.reason), resultOrReason.score or 0, resultOrReason.threshold or 0)
            or tostring(resultOrReason)
        Reply(src, ('Rusvet REDDEDILDI (%s).'):format(detail))
    end
end, false)


-- /polisgenetigi [citizenid] — memurun deterministik integrity/greed
-- değerlerini test amaçlı gösterir (RAM önbellekten — aynı citizenid HER
-- ZAMAN aynı sonucu döner).
RegisterCommand('polisgenetigi', function(src, args)
    local citizenid = args[1]
    if type(citizenid) ~= 'string' then Reply(src, 'Kullanim: /polisgenetigi [citizenid]'); return end


    local personality = Matrix.Bureau.GetPolicePersonality(citizenid)
    if not personality then Reply(src, 'Kisilik hesaplanamadi.'); return end


    Reply(src, ('%s -> Integrity:%.3f Greed:%.3f'):format(citizenid, personality.integrity, personality.greed))
end, false)


exports('GetPolicePersonality', function(citizenid, npcModelHash, npcCoords)
    return Matrix.Bureau.GetPolicePersonality(citizenid, npcModelHash, npcCoords)
end)
exports('ProcessBribeOffer', function(officerSrc, suspectSrc, moneyAmount)
    return Matrix.Bureau.ProcessBribeOffer(officerSrc, suspectSrc, moneyAmount)
end)


-- =====================================================================
-- ★★★ [OPSEC FAZ 1 EK] FEAR COEFFICIENT — İNFAZ GEÇMİŞİ KORKUSU ★★★
-- TAMAMEN YENİ bir EKLEMEDİR. Cetenin GECMIS infaz sayisi -- matrix_raid_log.
-- outcome='eliminated' (ZATEN VAR OLAN tablo/kolon/enum -- bkz. dosya
-- ortasindaki VALID_RAID_OUTCOMES ve ResolveRaidOutcome, YENI bir sema
-- ICAT EDILMEZ) -- arttikca botlarin yakalanma aninda konusma (snitch)
-- direnci ARTAR. server/kitchen.lua Matrix.Kitchen.OnCaptured bu getter'i
-- (yuklu ise) okuyup Config.Kitchen.SnitchThreshold (DEGISTIRILMEDI) yerine
-- bu DINAMIK, HER ZAMAN taban esigin USTUNDE/ESIT olan efektif esigi
-- kullanir.
--
-- FORMÜL (RNG YOK, saf esik/oran):
--   fear = clamp(eliminatedCount / FearCoefficientEliminationCeiling, 0, 1)
--   effectiveThreshold = clamp(base + (ceiling-base)*fear, base, ceiling)
-- Yorum: fear=0 iken effectiveThreshold TAM OLARAK base'tir (davranış
-- korku katmanı YOKKEN Config.Kitchen.SnitchThreshold ile BİREBİR AYNI) --
-- geriye dönük uyumlu. fear=1 iken tavan (%95) ile doyar, ASLA asmaz.
-- =====================================================================
local cachedFearCoefficient = 0.0
local cachedEliminatedCount = 0


local function RefreshFearCoefficient()
    local rows = MySQL.query.await("SELECT COUNT(*) AS n FROM matrix_raid_log WHERE outcome = 'eliminated'", {})
    local n = (rows and rows[1] and tonumber(rows[1].n)) or 0
    cachedEliminatedCount = n


    local ceiling = CfgBureau('FearCoefficientEliminationCeiling', 20)
    cachedFearCoefficient = Matrix.Clamp(n / math_max(ceiling, 1), 0.0, 1.0)
end


CreateThread(function()
    local ok, err = pcall(RefreshFearCoefficient)
    if not ok then
        Matrix.Log('BUREAU', '[HATA] RefreshFearCoefficient ilk yukleme basarisiz (yutuldu): %s', tostring(err))
    end
    while true do
        Wait(CfgBureau('FearCoefficientRefreshIntervalMs', 120000))
        local tickOk, tickErr = pcall(RefreshFearCoefficient)
        if not tickOk then
            Matrix.Log('BUREAU', '[HATA] RefreshFearCoefficient hata verdi (yutuldu): %s', tostring(tickErr))
        end
    end
end)


--- Salt-okunur getter: RAM önbellekten [0,1] korku katsayısını döner.
function Matrix.Bureau.GetFearCoefficient()
    return cachedFearCoefficient
end


--- ★ Botun panik anındaki EFEKTİF snitch eşiğini döner: taban eşik
--- (Config.Kitchen.SnitchThreshold, DEĞİŞTİRİLMEDİ) FearCoefficient ile
--- yükselir, SERT TAVAN Config.Bureau.FearCoefficientSnitchCeiling (%95)
--- ile kırpılır — taban eşiğin ALTINA ASLA inmez (korku yalnızca direnci
--- ARTIRIR, hiç azaltmaz).
function Matrix.Bureau.GetEffectiveSnitchThreshold()
    local base    = Config.Kitchen.SnitchThreshold
    local ceiling = CfgBureau('FearCoefficientSnitchCeiling', 0.95)
    local raised  = base + ((ceiling - base) * cachedFearCoefficient)
    return Matrix.Clamp(raised, base, ceiling)
end


RegisterCommand('korkudurum', function(src)
    Reply(src, ('Infaz-Sayisi:%d | FearCoefficient:%.3f | Taban-Esik:%.2f -> Efektif-Esik:%.3f (tavan:%.2f)'):format(
        cachedEliminatedCount, cachedFearCoefficient,
        Config.Kitchen.SnitchThreshold, Matrix.Bureau.GetEffectiveSnitchThreshold(),
        CfgBureau('FearCoefficientSnitchCeiling', 0.95)))
end, false)


exports('GetFearCoefficient', function() return Matrix.Bureau.GetFearCoefficient() end)
exports('GetEffectiveSnitchThreshold', function() return Matrix.Bureau.GetEffectiveSnitchThreshold() end)


-- =====================================================================
-- ★★★ [GLOBAL CONVAR] GetBureaucraticVelocity — server.cfg UZAKTAN AYARI ★★★
-- 'matrix_bureau_intensity' ConVar'i (server.cfg icine 'set matrix_bureau_
-- intensity 1.5' eklenerek) Buro'nun TUM ogrenme/desifre kazanclarini
-- (Matrix.Bureau.AdvanceDecryption, dosya basi -- TUM cagiranlarin ORTAK
-- gectigi TEK nokta) VE devriye frekanslarini (server/market.lua Inspector.
-- ScanForMoles dongusu) CANLI/uzaktan olcekler. Varsayilan 1.0 = eski
-- davranisla BIREBIR AYNI. RNG YOK -- salt bir ConVar okuma + guvenli
-- sinir kontrolu (NaN/negatif/sifir degerler 1.0'a duser).
-- =====================================================================
function Matrix.Bureau.GetBureaucraticVelocity()
    local intensity = GetConvarFloat('matrix_bureau_intensity', 1.0)
    if type(intensity) ~= 'number' or intensity ~= intensity or intensity <= 0.0 then
        intensity = 1.0
    end
    return intensity
end


exports('GetBureaucraticVelocity', function() return Matrix.Bureau.GetBureaucraticVelocity() end)


-- =====================================================================
-- ★★★ [ADLİ RPG] MAHKEME İFADE ZİNCİRİ — /davaac + /davasorgula ★★★
-- Çift fazlı diyalog: FAZ 1 (/davaac) kanıtı (matrix_forensic_evidence
-- ballistic_id/match_certainty, ZATEN VAR OLAN alanlar) sunar; FAZ 2
-- (/davasorgula) sanığın ifadesini ('itiraf' | 'yalan') işler. Yalan,
-- kanıt eşiği (Config.Forensics.MatchCertaintyThreshold) aşılmışken
-- verilirse lie_count artar ve conviction_weight Propaganda momentumuyla
-- AYNI geometrik şekilde (a*x+b, tavan 1.0) tırmanır. %100'de
-- ExecuteVerdict (Karakter Wipe) tetiklenir.
--
-- AI_Matrix_Brain.enabled=true iken deterministik veriler AYNEN hesaplanir
-- (kilit/mahkumiyet kararı BU köprüyü ASLA beklemez) -- yalnızca sunulan
-- ANLATI metni asenkron olarak OpenAI'dan istenir (RunAIAdvisoryPass ile
-- AYNI PerformHttpRequest deseni).
-- =====================================================================
local TrialSessions = {} -- [defendantCitizenid] = { defendant_src, defendant_citizenid, dna_id, ballistic_id, match_certainty, lie_count, conviction_weight, opened_at }


function Matrix.Bureau.RequestAITrialNarrative(officerSrc, session)
    if Config.AI_Matrix_Brain.provider ~= 'openai' or not Config.AI_Matrix_Brain.apiKey or Config.AI_Matrix_Brain.apiKey == 'sk-...' then
        Reply(officerSrc, '[ADLİ İFADE] enabled=true fakat apiKey yapılandırılmamış; deterministik veriler değişmeden gösteriliyor.')
        Reply(officerSrc, ('Sanık DNA:%s | Eşleşme: %%%.1f'):format(session.dna_id, session.match_certainty * 100.0))
        return
    end


    local body = json.encode({
        model = 'gpt-4o-mini',
        messages = {
            { role = 'system', content = 'You are a Turkish-speaking courtroom narrator for a fictional GTA roleplay server. Given deterministic forensic match data, write a short reasoned (gerekceli) verdict narrative in Turkish. Never invent data beyond what is given, never claim it is a real legal proceeding.' },
            { role = 'user', content = json.encode({
                dna_id          = session.dna_id,
                ballistic_id    = session.ballistic_id,
                match_certainty = session.match_certainty
            }) }
        }
    })


    PerformHttpRequest('https://api.openai.com/v1/chat/completions', function(statusCode, response)
        if statusCode ~= 200 then
            Reply(officerSrc, ('[ADLİ İFADE] OpenAI istegi basarisiz (HTTP %s); deterministik motor degismeden devam ediyor.'):format(tostring(statusCode)))
            return
        end
        local ok, decoded = pcall(json.decode, response)
        if not ok or not decoded.choices or not decoded.choices[1] then
            Reply(officerSrc, '[ADLİ İFADE] OpenAI yaniti cozumlenemedi.')
            return
        end
        local narrative = decoded.choices[1].message and decoded.choices[1].message.content
        Reply(officerSrc, '[MAHKEME KARARI - AI GEREKCE]')
        Reply(officerSrc, tostring(narrative or 'Anlati uretilemedi.'))
    end, 'POST', body, {
        ['Content-Type']  = 'application/json',
        ['Authorization'] = 'Bearer ' .. Config.AI_Matrix_Brain.apiKey
    })
end


--- FAZ 1: dava dosyasi acar, dnaId'nin matrix_forensic_evidence ortalama
--- match_certainty'sini okur, TrialSessions'a yazar ve matrix_trial_records'a
--- 'pending' bir satir ekler.
function Matrix.Bureau.OpenTrial(officerSrc, defendantSrc, dnaId)
    defendantSrc = tonumber(defendantSrc)
    if not defendantSrc or type(dnaId) ~= 'string' or dnaId == '' then return false, 'bad_args' end


    local defendantState = Matrix.GetOrCreatePlayerState(defendantSrc)
    if not defendantState or not defendantState.citizenid then return false, 'defendant_unresolved' end


    local rows = MySQL.query.await(
        'SELECT ballistic_id, match_certainty FROM matrix_forensic_evidence WHERE fingerprint_id = ? ORDER BY match_certainty DESC',
        { dnaId }) or {}


    local ballisticId, matchCertainty = nil, 0.0
    if rows[1] then
        ballisticId = rows[1].ballistic_id
        local total = 0.0
        for _, r in ipairs(rows) do total = total + (tonumber(r.match_certainty) or 0.0) end
        matchCertainty = total / #rows
    end


    local session = {
        defendant_src       = defendantSrc,
        defendant_citizenid = defendantState.citizenid,
        dna_id              = dnaId,
        ballistic_id        = ballisticId,
        match_certainty     = matchCertainty,
        lie_count           = 0,
        conviction_weight   = matchCertainty,
        opened_at           = Matrix.Now()
    }
    TrialSessions[defendantState.citizenid] = session


    MySQL.insert([[
        INSERT INTO matrix_trial_records
            (defendant_citizenid, dna_id, ballistic_id, match_certainty, lie_count, conviction_weight, verdict, opened_at)
        VALUES (?, ?, ?, ?, 0, ?, 'pending', NOW())
    ]], { defendantState.citizenid, dnaId, ballisticId, matchCertainty, matchCertainty })


    if not Config.AI_Matrix_Brain.enabled then
        Reply(officerSrc,
            ('[ADLİ İFADE - FAZ 1] Sanik DNA:%s | Namlu izi eslesmesi: %%%.1f%s'):format(
                dnaId, matchCertainty * 100.0,
                ballisticId and (' (Balistik #%s)'):format(ballisticId) or ' (eslesen balistik kaydi yok)'))
        Reply(officerSrc,
            matchCertainty >= Config.Forensics.MatchCertaintyThreshold
                and 'Kanitlar saniği dogrudan isaret ediyor. /davasorgula ile ifadesini sorgulayin.'
                or 'Kanitlar zayif. Sanik makul bir itirazla temize cikabilir.')
    else
        Reply(officerSrc, '[ADLİ İFADE - FAZ 1] Dava dosyasi OpenAI analiz koprusune gonderildi, gerekceli karar hazirlaniyor...')
        pcall(Matrix.Bureau.RequestAITrialNarrative, officerSrc, session)
    end


    return true, session
end


--- FAZ 2: sanığın ifadesini işler ('itiraf' -> conviction_weight=1.0 aninda;
--- 'yalan' + kanit esigi asilmisken -> lie_count++, conviction_weight
--- geometrik tirmanir). %100'de ExecuteVerdict tetiklenir.
function Matrix.Bureau.RecordTrialResponse(officerSrc, defendantSrc, responseKind)
    defendantSrc = tonumber(defendantSrc)
    if not defendantSrc then return false, 'bad_args' end


    local defendantState = Matrix.GetOrCreatePlayerState(defendantSrc)
    if not defendantState or not defendantState.citizenid then return false, 'defendant_unresolved' end


    local session = TrialSessions[defendantState.citizenid]
    if not session then return false, 'no_open_case' end


    responseKind = tostring(responseKind or ''):lower()
    local isLie       = (responseKind == 'yalan' or responseKind == 'inkar')
    local isConfession = (responseKind == 'itiraf' or responseKind == 'dogru')
    if not isLie and not isConfession then return false, 'bad_response_kind' end


    if isConfession then
        session.conviction_weight = 1.0
    else
        if session.match_certainty >= Config.Forensics.MatchCertaintyThreshold then
            session.lie_count = session.lie_count + 1
            session.conviction_weight = math_min(
                (session.conviction_weight * Config.Bureau.TrialConvictionGeometricFactor) + Config.Bureau.TrialConvictionIncrement,
                1.0
            )
        end
    end


    MySQL.prepare([[
        UPDATE matrix_trial_records
        SET lie_count = ?, conviction_weight = ?
        WHERE defendant_citizenid = ? AND verdict = 'pending'
        ORDER BY opened_at DESC LIMIT 1
    ]], { session.lie_count, session.conviction_weight, session.defendant_citizenid })


    Reply(officerSrc, ('[ADLİ İFADE - FAZ 2] Yalan-Sayaci:%d | Mahkumiyet-Skoru:%%%.1f'):format(
        session.lie_count, session.conviction_weight * 100.0))


    if session.conviction_weight >= 1.0 then
        Matrix.Bureau.ExecuteVerdict(officerSrc, session)
        TrialSessions[session.defendant_citizenid] = nil
        return true, { verdict = 'imprisoned' }
    end


    return true, { verdict = 'pending' }
end


--- ExecuteVerdict (Karakter Wipe): matrix_player_state.imprisoned=1, dava
--- dosyasi kapatilir, o citizenid'ye bagli (bot.handler_citizenid, bkz.
--- server/main.lua) TUM otonom botlar 'disbanded' moduna cekilir (sahipsiz
--- hucre BIRAKMAZ), ardindan oyuncu DropPlayer ile tekmelenir.
function Matrix.Bureau.ExecuteVerdict(officerSrc, session)
    local citizenid   = session.defendant_citizenid
    local defendantSrc = session.defendant_src


    MySQL.prepare('UPDATE matrix_player_state SET imprisoned = 1 WHERE citizenid = ?', { citizenid })
    MySQL.prepare([[
        UPDATE matrix_trial_records
        SET verdict = 'imprisoned', lie_count = ?, conviction_weight = 1.0, closed_at = NOW()
        WHERE defendant_citizenid = ? AND verdict = 'pending'
    ]], { session.lie_count, citizenid })


    -- ★ [KOR NOKTA] o citizenid'ye bagli TUM otonom botlari topluca
    -- 'disbanded' moduna cek -- sahipsiz hucre BIRAKMA.
    local dbOk, dbErr = pcall(function()
        return MySQL.query.await('UPDATE matrix_bots SET status = ? WHERE handler_citizenid = ?', { 'disbanded', citizenid })
    end)
    if not dbOk then
        Matrix.Log('BUREAU', '[HATA] ExecuteVerdict bulk-disband DB guncellemesi basarisiz: %s', tostring(dbErr))
    end


    local disbandedCount = 0
    for id, bot in pairs(Matrix.Bots) do
        if bot.handler_citizenid == citizenid then
            if Matrix.Dispatches and Matrix.Dispatches[id] then
                Matrix.DespawnDispatchEntity(id, Matrix.Dispatches[id])
                Matrix.Dispatches[id] = nil
            end
            Matrix.Bots[id] = nil
            disbandedCount = disbandedCount + 1
        end
    end


    Matrix.Log('BUREAU',
        '[KARAKTER WIPE - MAHKUM] %s -> imprisoned=1, %d bagli otonom bot disbanded moduna cekildi.',
        citizenid, disbandedCount)


    Reply(officerSrc, ('[MAHKEME KARARI] %s -> %%100 Mahkumiyet Skoru. Karakter kilitlendi ve sunucudan tekmelendi.'):format(citizenid))


    if defendantSrc then
        pcall(function()
            DropPlayer(defendantSrc, 'MAHKUM EDILDINIZ: Adli surec sonucunda karakteriniz kalici olarak muhurlendi.')
        end)
    end
end


RegisterCommand('davaac', function(src, args)
    local defendantSrc = tonumber(args[1])
    local dnaId = args[2]
    if not defendantSrc or type(dnaId) ~= 'string' then
        Reply(src, 'Kullanim: /davaac [defendantRef(src)] [dnaId]'); return
    end
    local ok, resultOrReason = Matrix.Bureau.OpenTrial(src, defendantSrc, dnaId)
    if not ok then
        Reply(src, ('Dava acilamadi: %s'):format(tostring(resultOrReason)))
    end
end, false)


RegisterCommand('davasorgula', function(src, args)
    local defendantSrc = tonumber(args[1])
    local responseKind = args[2]
    if not defendantSrc or not responseKind then
        Reply(src, 'Kullanim: /davasorgula [defendantRef(src)] [itiraf|yalan]'); return
    end
    local ok, resultOrReason = Matrix.Bureau.RecordTrialResponse(src, defendantSrc, responseKind)
    if not ok then
        Reply(src, ('Sorgu basarisiz: %s'):format(tostring(resultOrReason)))
    end
end, false)


exports('OpenTrial', function(officerSrc, defendantSrc, dnaId) return Matrix.Bureau.OpenTrial(officerSrc, defendantSrc, dnaId) end)
exports('RecordTrialResponse', function(officerSrc, defendantSrc, responseKind) return Matrix.Bureau.RecordTrialResponse(officerSrc, defendantSrc, responseKind) end)


-- =====================================================================
-- ★★★ [KOR NOKTA] /telefonuyoket — TELEFON HATTI ADLİ SABOTAJI ★★★
-- Oyuncunun kendi (veya opsiyonel dnaId argumaniyla hedeflenen) hattina ait
-- kriptolu mesajlari (matrix_encrypted_messages, YENİ tablo) VE o hatta
-- bagli, HENUZ 'sealed_as_crime_weapon' ile KESINLESMEMIS siber sinyal
-- delillerini (matrix_forensic_evidence WHERE evidence_type='cyber') TEK
-- bir atomik transaction ile kalici olarak siler.
-- =====================================================================
function Matrix.Bureau.SabotagePhoneLine(src, dnaId)
    if type(src) ~= 'number' or src <= 0 then return false, 'bad_src' end


    if type(dnaId) ~= 'string' or dnaId == '' then
        local state = Matrix.GetOrCreatePlayerState(src)
        dnaId = state and state.dna_id
    end
    if type(dnaId) ~= 'string' or dnaId == '' then return false, 'bad_dna' end


    local queries = {
        { query = 'DELETE FROM matrix_encrypted_messages WHERE dna_id = ?', values = { dnaId } },
        { query = "DELETE FROM matrix_forensic_evidence WHERE fingerprint_id = ? AND evidence_type = 'cyber' AND sealed_as_crime_weapon = 0", values = { dnaId } }
    }


    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or result == false then
        Matrix.Log('BUREAU', '[HATA] SabotagePhoneLine transaction basarisiz: %s', tostring(result))
        return false, 'db_error'
    end


    Matrix.Log('BUREAU',
        '[TELEFON HATTI SABOTAJI] %s -> kriptolu mesajlar + kesinlesmemis siber deliller TEK atomik transaction ile kazindi.',
        dnaId)
    return true, { dna_id = dnaId }
end


RegisterCommand('telefonuyoket', function(src, args)
    local ok, resultOrReason = Matrix.Bureau.SabotagePhoneLine(src, args[1])
    if ok then
        Reply(src, ('[HAT SABOTAJI] %s hattina ait kriptolu mesajlar ve kesinlesmemis siber deliller kalici olarak kazindi.'):format(resultOrReason.dna_id))
    else
        Reply(src, ('Basarisiz: %s'):format(tostring(resultOrReason)))
    end
end, false)


exports('SabotagePhoneLine', function(src, dnaId) return Matrix.Bureau.SabotagePhoneLine(src, dnaId) end)


-- =====================================================================
-- ★★★ [KOR NOKTA] KOMA MODU — withdrawal_index >= 1.0 ★★★
-- MEVCUT bot.biology.withdrawal_index alanini (YENİ bir "under_influence"
-- alani ICAT EDILMEZ) izler. Esik asilinca status='comatose' kilitlenir --
-- sevk emirleri (Matrix.CompleteDispatch ile aninda geri cagrilir) ve
-- telsiz iletisimi (comatose durumdaki bir bot artik hicbir aktif dongude
-- 'active' filtresinden gecmez) TAMAMEN bloke olur. 2 gercek saat (Config.
-- Kitchen.ComaToDeceasedRealHours) mudahalesiz kalirsa 'deceased' arsivine
-- duser (Matrix.RemoveBot -- role=='Leader' ise bu FragmentTerritory'yi de
-- tetikler, bkz. server/main.lua).
-- =====================================================================
local ComaClock = {} -- [botId] = comatose'a girdigi Matrix.Now() zamani


local function ProcessComaCycle()
    for botId, bot in pairs(Matrix.Bots) do
        if bot.status == 'active' and bot.biology and (bot.biology.withdrawal_index or 0.0) >= 1.0 then
            bot.status = 'comatose'
            Matrix.MarkBotDirty(botId)
            ComaClock[botId] = Matrix.Now()


            if Matrix.Dispatches and Matrix.Dispatches[botId] then
                Matrix.CompleteDispatch(botId, 'panic_recall')
            end


            Matrix.Log('CORE',
                '[KOMA MODU] Bot #%d withdrawal_index=%.3f -- sevk emirleri VE telsiz iletisimi TAMAMEN bloke edildi.',
                botId, bot.biology.withdrawal_index)
        elseif bot.status == 'comatose' then
            local since = ComaClock[botId]
            local ceilingHours = Config.Kitchen.ComaToDeceasedRealHours or 2
            if since and (Matrix.Now() - since) >= (ceilingHours * 3600) then
                ComaClock[botId] = nil
                Matrix.Log('CORE',
                    '[KOMA -> OLUM] Bot #%d %d saat mudahalesiz koma modunda kaldi, deceased arsivine dustu.',
                    botId, ceilingHours)
                Matrix.RemoveBot(botId, 'deceased')
            end
        end
    end
end


CreateThread(function()
    while true do
        Wait(Config.Tick.SecondsPerMinute * Config.Tick.IntervalMs)
        local ok, err = pcall(ProcessComaCycle)
        if not ok then
            Matrix.Log('CORE', '[HATA] ProcessComaCycle hata verdi (yutuldu): %s', tostring(err))
        end
    end
end)


-- =====================================================================
-- ★★★ [KOR NOKTA] SAATLİK MALİ DENETİM + VERİ BUDAMA (matrix_purchase_logs) ★★★
-- Büro'nun saatlik mali denetimi -- 24 saatten eski TÜM fatura/işlem log
-- satırlarını otonom olarak kazır (disk sağlığı, sınırsız birikimi önler).
-- =====================================================================
function Matrix.Bureau.RunHourlyFinancialAudit()
    local ok, result = pcall(function()
        return MySQL.query.await('DELETE FROM matrix_purchase_logs WHERE created_at < (NOW() - INTERVAL 24 HOUR)', {})
    end)
    if not ok then
        Matrix.Log('BUREAU', '[HATA] RunHourlyFinancialAudit budama basarisiz: %s', tostring(result))
        return
    end
    local affected = (type(result) == 'table' and (result.affectedRows or result.numAffected)) or 0
    Matrix.Log('BUREAU', '[SAATLIK MALI DENETIM] matrix_purchase_logs budandi (24 saatten eski %s satir silindi).', tostring(affected))
end


CreateThread(function()
    while true do
        Wait(3600000)
        local ok, err = pcall(Matrix.Bureau.RunHourlyFinancialAudit)
        if not ok then
            Matrix.Log('BUREAU', '[HATA] RunHourlyFinancialAudit hata verdi (yutuldu): %s', tostring(err))
        end
    end
end)


exports('RunHourlyFinancialAudit', function() return Matrix.Bureau.RunHourlyFinancialAudit() end)