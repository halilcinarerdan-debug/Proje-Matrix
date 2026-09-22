-- =====================================================================
-- MATRIX CORE / server/main.lua  (KATMAN 5 ULTIMATE — CO-OP & SIGINT/COMINT)
--
-- ★ ÖNCEKİ SERTLEŞTİRME (v1, korunuyor):
--   [H8] BeginPhysicalDispatch HATA YOLLARINDA ENTITY SIZINTISI KAPATILDI:
--        CreatePed/CreateVehicle başarılı olup AwaitEntityCreation başarısız
--        olursa entity artık DeleteEntity ile DÜNYADAN SİLİNİR; task atama
--        (TaskGoStraightToCoord / TaskVehicleDriveToCoord) pcall ile
--        sarmalandı — başarısız olursa yarım kalan ped/araç temizlenip
--        'task_assignment_failed' döner.
--   [H9] CompleteDispatch içinde entity NetID'leri TABLO SIFIRLANMADAN ÖNCE
--        yakalanır ve pcall sınırları içinde tek tek temizlenir. Böylece
--        [H3]'teki iki-fazlı yapıda "bot silinmiş + dispatch düşmüş"
--        durumunda dahi entity'ler (RAM'deki ağ referansları ve dünyadaki
--        ped/araç) ORPHAN KALMAZ.
--   [H10] TickPhysicalDispatches Faz 2'de pcall(CompleteDispatch) başarısız
--        olursa Dispatches[botId] ZORLA nil'lenir (kalıcı RAM sızıntısı yok).
--
-- ★ KATMAN 5 EVRİM (önceki sürüm, korunuyor):
--   [H11] MULTI-WAYPOINT TAKTİK ROTA MOTORU: BeginPhysicalDispatch'in
--        ped/araç doğum mantığı SpawnDispatchActors() içine çıkarılıp
--        ortaklaştırıldı (DRY, [H8] hardening korunarak). Yeni
--        Matrix.BeginRouteDispatch() botu N ara uğraktan geçirip en sonda
--        final hedefe (ana üs) sızdırır: bot bir uğrağa vardığı an
--        (dist <= DISPATCH_ARRIVAL_RADIUS_M) DURAKSAMADAN bir sonraki
--        uğrağa yeniden görevlendirilir (AdvanceRouteWaypoint). Işınlanma
--        koruması HER bacak (origin->wp1->wp2->wp3->final) için ayrı ayrı
--        uygulanır — tek bir bacak bile MinDispatchDistanceMeters'in
--        altındaysa zincir HİÇBİR entity dünyaya doğmadan tamamen reddedilir.
--   [H12] CO-OP MUTEX: bot.state.is_locked, bir dispatch (tekli veya
--        rotalı) aktifken o bota İKİNCİ bir sevk emri verilmesini
--        yapısal olarak engeller. BeginPhysicalDispatch/BeginRouteDispatch
--        başında kontrol edilir, CompleteDispatch/DespawnDispatchEntity'de
--        serbest bırakılır.
--   [H13→E5] (KALDIRILDI) Bu dosyada bir F6-HUD köprüsü (Matrix.Hud.
--        PushSnapshots/HudViewers) vardı; server/market.lua bize
--        paylaşılınca ORADA ZATEN aynı köprünün (farklı, daha zengin bir
--        panel tasarımıyla) OTORİTER sürümünün var olduğu ortaya çıktı —
--        iki `function Matrix.Hud.PushSnapshots()` tanımı SESSİZCE
--        birbirini eziyordu. Bu dosyadaki kopya kaldırıldı; bkz. [E5].
--   [H14] SUNUCU TARAFI PED SPAWN ANTI-CRASH GUARD: 'SetEntityAsMissionEntity'
--        SUNUCU LUA ORTAMINDA TANIMLI DEĞİLDİR (client-only native) — çağrılırsa
--        'attempt to call a nil value' hatasıyla script'i ve canlanma döngüsünü
--        kilitler. Bu sürümde TAMAMEN KALDIRILDI. Kalıcılık/ağ mühürleme artık
--        CreatePed/CreateVehicle/CreatePedInsideVehicle'ın kendi
--        (isNetwork=true, bScriptHostPed=true) bayrakları + doğrulama
--        sonrası 'SetEntityOrphanMode(entity, 2)' [KeepEntity — server'ın
--        entity'yi asla silmemesini garanti eden resmi CFX server-side
--        native'i] ile kurulur. Ayrıca tüm dealer/dispatch ped'leri artık
--        rol bazlı fallback zincirinden (Config.RoleModels/DefaultRoleModel)
--        TAMAMEN AYRIŞTIRILMIŞ, sabit DEALER_PED_MODEL_HASH ('g_m_y_famdnf_01'
--        — kapüşonlu sokak dealer skin'i) kullanır; hiçbir fallback modeline
--        izin verilmez.
--
-- ★ KATMAN 5 ULTIMATE (BU SÜRÜM — yeni işler):
--   [U1] OTOMATİK ROTA TESLİMATI: CompleteDispatch('arrived') artık, varış
--        koordinatı bir Trap House'a Config.Logistics.TrapHouseArrivalStashRadius
--        içindeyse, Matrix.DepositDealerCargoToTrapStash ile botun sırtındaki
--        TÜM kargoyu (dealer_<id> envanteri) o Trap House'un kendi stash'ine
--        (matrix_trap_stash_<id>) otomatik aktarır. Bu, F10 -> "/rotaciz"
--        akışını tamamen kendi kendine yeten (self-contained) hale getirir:
--        oyuncu rotayı çizer, bot kaçış rotasını izler, vardığında kargoyu
--        bırakır, araç zaten mevcut mekanizmayla (aşağıda değişmedi)
--        DeleteEntity ile dünyadan silinir ve bot is_locked=false (STABİL/
--        BEKLEMEDE) durumuna döner.
--   [U2] /operatiftasfiye [botId]: F10 "Canlı Kadro & Hiyerarşi Raporu"
--        menüsündeki "Operatif Tasfiye Et" aksiyonunun arkasındaki komut.
--        Mevcut server/logistics.lua Matrix.Logistics.OnDealerEliminated'i
--        (değiştirilmedi) çağırır — bu fonksiyon zaten hem DB'de gerçek bir
--        DELETE hem de pcall-korumalı RAM/entity Hard-Delete yapıyordu.
--   [U3] Canlı Kadro & Hiyerarşi Raporu callback'i artık düz string dizisi
--        DEĞİL, `{ kind, id, role, mole_flagged, text }` yapılı bir dizi
--        döner — client/hud.lua bot satırlarını TIKLANABİLİR yapabilsin
--        (Operatif Tasfiye Et / Denetleyici Olarak Ata) ve SIGINT köstebek
--        bülteni (Matrix.Inspector.IsMoleFlagged, server/market.lua) rapora
--        kırmızı bir bültene çevrilmeden ham metin olarak işlenebilsin diye.
--   [U7] YAYA BOT TAKILMA/SIKIŞMA MUHAFIZI (Anti-Stuck): yaya (vehicle_type
--        == 'foot') dispatch'lerde TaskGoStraightToCoord (düz çizgi, engel
--        farkında değil — karmaşık mimari/kapalı alanda duvara saplanıp
--        kalabiliyordu) TaskFollowNavMeshToCoord ile DEĞİŞTİRİLDİ: GTA V'in
--        yerel yaya NavMesh ağını kullanan, engellerin etrafından otomatik
--        dolanan asenkron bir görev. Üç çağrı noktası da (ilk sevk, rota
--        zinciri ilerleyişi, periyodik görev-yenileme) güncellendi; araç
--        dispatch'leri (TaskVehicleDriveToCoord) DEĞİŞMEDİ. Yeni bir
--        thread/Wait YOK — ilerleme yine mevcut TickPhysicalDispatches
--        tick döngüsü tarafından izlenir, 0 Resmon bütçesi korunur.
--        DOĞRULAMA: SpawnDispatchActors/AdvanceRouteWaypoint/reissue'nun
--        ÜÇÜNDE de araç dalı (dispatch.vehicle_net_id dolu / vehicle_type
--        'car'|'motorbike') TaskVehicleDriveToCoord kullanmaya devam
--        ediyor — yaya ve araç görevleri HİÇBİR noktada karışmıyor.
--   [U8] ACİL TAHLİYE (PANİK) MOTORU: Matrix.TriggerPanicEvacuation +
--        /panikiptal [botId] (F10 Canlı Kadro -> "Acil Tahliye (Görevi
--        İptal Et)"). Aktif bir dispatch'in Co-Op Mutex'i kırılır, eski
--        rota zinciri terk edilir, AYNI ped/araç (ışınlanma YOK) "son hız"
--        (PANIC_EVAC_*_SPEED_MS) ile tetikleyen oyuncunun canlı konumuna
--        yönlendirilir; PANIC_REISSUE_TICKS periyodunda hedef oyuncunun
--        O ANKİ konumuna yeniden senkronize edilir (bot "kovalamaya"
--        devam eder). Yeni bir thread YOK — mevcut TickPhysicalDispatches
--        döngüsü aynen kullanılır. HUD'da (K/F6) [DURUM: ACİL TAHLİYE —
--        SANA DOĞRU GELİYOR] bülteni server/market.lua BuildSnapshot'a
--        eklendi.
--
-- ★ KATMAN 7 FAZ 2 (bu sürüm — YENİ, guard'lı hook'lar): CompleteDispatch
--   'arrived'/'busted' dallarına, ZATEN VAR OLAN [U1]/Kitchen.OnCaptured
--   hook zincirinin AYNI desenini izleyen İKİ YENİ tek-satırlık gözlemci
--   eklendi. Bureau'nun/Kitchen'ın/Logistics'in KENDİ formülüne HİÇ
--   dokunulmadı:
--     - 'arrived': Matrix.Market.FlushBotStreetCash(botId, nearestTrapId)
--       (yüklüyse) — sokakta satış yapan bir botun elindeki "riskli" kirli
--       nakit, eve sağ salim döndüğü AN ortak kasaya (Matrix.CashDecay.
--       Deposit, MEVCUT) kilitlenir.
--     - 'busted': Matrix.Forensics.InspectBustedBot(botId, nearestId, plate)
--       ve Matrix.Market.SeizeBotStreetCash(botId) (yüklüyse) — Real-Time
--       Üst Arama kontrabant zinciri + üzerindeki riskli nakdin müsaderesi.
--   Her iki hook da modül yüklü değilse (guard nil) davranış BİREBİR
--   ESKİSİYLE AYNIDIR.
-- =====================================================================


-- ---------- Upvalue localization (perf) ----------
local pairs, ipairs, next       = pairs, ipairs, next
local type, tostring, tonumber  = type, tostring, tonumber
local table, string, math, os   = table, string, math, os
local setmetatable              = setmetatable
local tonumber, select          = tonumber, select
local math_floor, math_max      = math.floor, math.max
local math_min, math_huge       = math.min, math.huge
local math_rad, math_sin        = math.rad, math.sin
local math_cos, math_abs        = math.cos, math.abs
local math_sqrt                 = math.sqrt


local CreateThread              = CreateThread
local Wait                      = Wait
local CreatePed                 = CreatePed
local CreatePedInsideVehicle    = CreatePedInsideVehicle
local CreateVehicle             = CreateVehicle
local DoesEntityExist           = DoesEntityExist
local DeleteEntity              = DeleteEntity
-- ★ [H14] SetEntityAsMissionEntity KASITLI OLARAK localize EDİLMEZ: bu
-- native sunucu Lua ortamında TANIMLI DEĞİLDİR (client-only) — burada bir
-- upvalue olarak tutulması bile "kullanılabilir" izlenimi verir. Yerine
-- SetEntityOrphanMode (server-safe, kalıcılık için resmi CFX native'i).
local SetEntityOrphanMode       = SetEntityOrphanMode
local SetEntityCoords           = SetEntityCoords
local SetEntityCoordsNoOffset   = SetEntityCoordsNoOffset
-- ★ KATMAN 7 [T1]: Çıkış Köprüsü — yeni doğan dispatch entity'lerini her
-- zaman Bucket 0'a (dış dünya) açıkça bağlamak için.
local SetEntityRoutingBucket    = SetEntityRoutingBucket
local GetHashKey                = GetHashKey
local GetGameTimer              = GetGameTimer
local NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity
local NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId
local GetPlayerPed              = GetPlayerPed
local GetEntityCoords           = GetEntityCoords
local GetEntityHeading          = GetEntityHeading
local TaskVehicleDriveToCoord   = TaskVehicleDriveToCoord
-- ★ KATMAN 5 ULTIMATE [U7]: yaya botlar için NavMesh tabanlı, engellerin
-- etrafından dolanan asenkron yürüyüş görevi (bkz. dosya içi [U7] notu).
-- TaskGoStraightToCoord (düz çizgi, engel-körü) artık YAYA dispatch'lerde
-- HİÇ KULLANILMIYOR — bu yüzden localize edilmedi.
local TaskFollowNavMeshToCoord  = TaskFollowNavMeshToCoord
local TriggerClientEvent        = TriggerClientEvent
local RegisterCommand           = RegisterCommand
local RegisterNetEvent          = RegisterNetEvent
local AddEventHandler           = AddEventHandler
local GetCurrentResourceName    = GetCurrentResourceName


-- ---------- Namespace ----------
Matrix       = Matrix       or {}
Matrix.Bots  = Matrix.Bots  or {}
Matrix.PlayerState = Matrix.PlayerState or {}
Matrix.Inventory   = Matrix.Inventory   or {}
Matrix.PlayerSourceIndex = Matrix.PlayerSourceIndex or {}
Matrix.NextBotId = Matrix.NextBotId or 1
Matrix.Dispatches = Matrix.Dispatches or {}


Matrix.QBX = exports.qbx_core


local PENDING_EVENTS_MAX = 64


-- =====================================================================
-- ★ [H14→H15] KONFİG DESTEKLİ ROL->PED ATAMASI: dealer/dispatch ped
-- spawn'ları artık Config.BotPedConfiguration (öncelik) ve Config.RoleModels
-- (ikincil) tablolarından bot.role'e karşılık gelen modeli KATI BİR STRING
-- olarak okur -- ChecksumOf/hash tabanlı seçim YOK (0 RNG). Hiçbir tabloda
-- eşleşme yoksa Config.DefaultRoleModel'e, o da yoksa DEALER_PED_MODEL_NAME
-- sabit fallback'ine düşülür.
-- =====================================================================
local DEALER_PED_MODEL_NAME = 'g_m_y_famdnf_01' -- Street Dealer / Hooded Runner Skin

local function ResolveRolePedModel(role)
    local modelName = (Config.BotPedConfiguration and Config.BotPedConfiguration[role])
        or (Config.RoleModels and Config.RoleModels[role])
        or Config.DefaultRoleModel
        or DEALER_PED_MODEL_NAME
    return GetHashKey(modelName), modelName
end


-- =====================================================================
-- CORE MATHEMATICS
-- =====================================================================
function Matrix.Log(tag, fmt, ...)
    if select('#', ...) > 0 then
        print(('[MATRIX:%s] %s'):format(tag, fmt:format(...)))
    else
        print(('[MATRIX:%s] %s'):format(tag, fmt))
    end
end


function Matrix.Clamp(value, minV, maxV)
    if type(value) ~= 'number' or value ~= value or value == math_huge or value == -math_huge then
        return minV
    end
    if value < minV then return minV end
    if value > maxV then return maxV end
    return value
end


function Matrix.Now() return os.time() end


-- =====================================================================
-- ENVANTER SARIMI
-- =====================================================================
function Matrix.Inventory.GetSlotMetadata(inventoryId, slot)
    if not inventoryId or not slot then return {} end
    local ok, item = pcall(exports['ox_inventory'].GetSlot, exports['ox_inventory'], inventoryId, slot)
    if not ok or not item or type(item) ~= 'table' then return {} end
    return item.metadata or {}
end


function Matrix.Inventory.MergeMetadata(inventoryId, slot, patch)
    local current = Matrix.Inventory.GetSlotMetadata(inventoryId, slot)
    if type(current) ~= 'table' then current = {} end
    if type(patch) ~= 'table' then return current end
    for key, value in pairs(patch) do current[key] = value end
    pcall(exports['ox_inventory'].SetMetadata, exports['ox_inventory'], inventoryId, slot, current)
    return current
end


-- =====================================================================
-- TELSİZ KÖPRÜSÜ
-- =====================================================================
Matrix.Radio = Matrix.Radio or {}


function Matrix.Radio.ApplyStatic(targetSrc, intensity, reason)
    if type(targetSrc) ~= 'number' or targetSrc <= 0 then return false end
    intensity = Matrix.Clamp(tonumber(intensity) or 1.0, 0.0, 1.0)


    pcall(function() exports['pma-voice']:SetRadioStatic(targetSrc, intensity) end)
    pcall(function() exports['qb-radio']:SetRadioNoise(targetSrc, intensity) end)


    TriggerClientEvent('matrix:client:applyRadioStatic', targetSrc, intensity, reason or 'unknown')
    return true
end


-- =====================================================================
-- PERSISTENCE QUEUE
-- =====================================================================
Matrix.Persistence = {
    dirtyBots        = {},
    lastBotFlush     = 0,
    botFlushMs       = Config.Persistence.BotFlushIntervalMs,
    botFlushMaxBatch = Config.Persistence.BotFlushMaxBatch
}
local P = Matrix.Persistence


function Matrix.MarkBotDirty(botId)
    if botId then P.dirtyBots[botId] = true end
end


local BOT_ROW_SQL = '(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())'
local BOT_UPSERT_HEAD =
    'INSERT INTO matrix_bots (id, dna_id, name, role, status, handler_citizenid, ' ..
    'fear_factor, resilience, snitch_tendency, economic_pressure, cognitive_shifter, skill_chemistry, ' ..
    'skill_cyber, skill_logistics, loyalty_base, ' ..
    'fatigue_level, cortisol_level, withdrawal_index, addiction_level, base_cortisol_recovery_rate, ' ..
    'trap_house_id, updated_at) VALUES '
local BOT_UPSERT_TAIL =
    ' ON DUPLICATE KEY UPDATE ' ..
    'name=VALUES(name), role=VALUES(role), status=VALUES(status), handler_citizenid=VALUES(handler_citizenid), ' ..
    'fear_factor=VALUES(fear_factor), resilience=VALUES(resilience), ' ..
    'snitch_tendency=VALUES(snitch_tendency), economic_pressure=VALUES(economic_pressure), ' ..
    'cognitive_shifter=VALUES(cognitive_shifter), skill_chemistry=VALUES(skill_chemistry), ' ..
    'skill_cyber=VALUES(skill_cyber), skill_logistics=VALUES(skill_logistics), ' ..
    'loyalty_base=VALUES(loyalty_base), ' ..
    'fatigue_level=VALUES(fatigue_level), cortisol_level=VALUES(cortisol_level), ' ..
    'withdrawal_index=VALUES(withdrawal_index), addiction_level=VALUES(addiction_level), ' ..
    'base_cortisol_recovery_rate=VALUES(base_cortisol_recovery_rate), ' ..
    'trap_house_id=VALUES(trap_house_id), updated_at=NOW()'


local function BuildBotUpsert(botList)
    local n = #botList
    if n == 0 then return nil, nil end


    local rows = {}
    for i = 1, n do rows[i] = BOT_ROW_SQL end


    local params = {}
    local idx = 1
    for i = 1, n do
        local b = botList[i]
        params[idx] = b.id                                   ; idx = idx + 1
        params[idx] = b.dna_id                               ; idx = idx + 1
        params[idx] = b.name                                 ; idx = idx + 1
        params[idx] = b.role                                 ; idx = idx + 1
        params[idx] = b.status                               ; idx = idx + 1
        params[idx] = b.handler_citizenid                    ; idx = idx + 1
        params[idx] = b.psychology.fear_factor               ; idx = idx + 1
        params[idx] = b.psychology.resilience                ; idx = idx + 1
        params[idx] = b.psychology.snitch_tendency           ; idx = idx + 1
        params[idx] = b.psychology.economic_pressure         ; idx = idx + 1
        params[idx] = b.psychology.cognitive_shifter         ; idx = idx + 1
        params[idx] = b.psychology.skill_chemistry           ; idx = idx + 1
        params[idx] = b.psychology.skill_cyber               ; idx = idx + 1
        params[idx] = b.psychology.skill_logistics           ; idx = idx + 1
        params[idx] = b.psychology.loyalty_base              ; idx = idx + 1
        params[idx] = b.biology.fatigue_level                ; idx = idx + 1
        params[idx] = b.biology.cortisol_level               ; idx = idx + 1
        params[idx] = b.biology.withdrawal_index             ; idx = idx + 1
        params[idx] = b.biology.addiction_level              ; idx = idx + 1
        params[idx] = b.biology.base_cortisol_recovery_rate  ; idx = idx + 1
        params[idx] = b.state.trap_house_id                  ; idx = idx + 1
    end


    local query = BOT_UPSERT_HEAD .. table.concat(rows, ',') .. BOT_UPSERT_TAIL
    return query, params
end


-- ★ CRITICAL FIX: eskiden MySQL.prepare(query, params) "ates et ve unut"
-- cagrilir cagrilmaz -- sonuc HIC beklenmeden -- dirtyBots bayraklari ayni
-- dongude ANINDA temizleniyordu. Transaction sessizce basarisiz olsa bile
-- RAM zaten "temiz" sayiliyordu -- degisiklik asla DB'ye yazilmamis
-- OLABILIRDI (sessiz veri kaybi/tutarsizlik). Simdi TUM batch TEK bir
-- MySQL.transaction.await ile kilitlenir; RAM bayraklari SADECE VE SADECE
-- transaction basariyla (true) bittiginde temizlenir.
function Matrix.FlushDirtyBots()
    local dirty = P.dirtyBots
    if not next(dirty) then return 0 end


    local batch, ids, count = {}, {}, 0
    for id in pairs(dirty) do
        local bot = Matrix.Bots[id]
        if bot then
            count = count + 1
            batch[count] = bot
            ids[count] = id
        else
            -- Bot artik mevcut degil -- persist edilecek bir sey kalmadi,
            -- bayrak guvenle hemen temizlenebilir (kayip veri riski YOK).
            dirty[id] = nil
        end
        if count >= P.botFlushMaxBatch then break end
    end
    if count == 0 then return 0 end


    local query, params = BuildBotUpsert(batch)
    if not query then return 0 end


    local ok, result = pcall(function()
        return MySQL.transaction.await({ { query = query, values = params } })
    end)
    if ok and result ~= false then
        for i = 1, count do dirty[ids[i]] = nil end
    else
        Matrix.Log('CORE',
            '[HATA][KRITIK] FlushDirtyBots transaction basarisiz -- dirty bayraklar KORUNDU, tekrar denenecek: %s',
            tostring(result))
    end
    return count
end


local function PersistAllBotsSync()
    local batch, count = {}, 0
    for _, bot in pairs(Matrix.Bots) do
        count = count + 1
        batch[count] = bot
    end
    if count == 0 then return end
    local query, params = BuildBotUpsert(batch)
    if query then
        pcall(function() MySQL.query.await(query, params) end)
    end
end


function Matrix.PersistBot(bot)
    if bot and bot.id then P.dirtyBots[bot.id] = true end
end


-- =====================================================================
-- BOT LIFECYCLE
-- =====================================================================
function Matrix.CreateBotRecord(profile)
    profile = profile or {}
    local id = Matrix.NextBotId
    Matrix.NextBotId = id + 1


    local bot = {
        id     = id,
        dna_id = profile.dna_id or ('DNA-%08d'):format(id),
        name   = profile.name   or ('Operative-%d'):format(id),
        role   = profile.role   or 'runner',
        status = 'active',
        -- ★ [ADLI RPG] bkz. LoadBotsFromDatabase yorumu -- opsiyonel,
        -- botu bir oyuncu citizenid'sine baglar (Karakter Wipe/ExecuteVerdict
        -- bulk-disband hedeflemesi icin).
        handler_citizenid = profile.handler_citizenid,
        psychology = {
            fear_factor       = Matrix.Clamp(profile.fear_factor or 0.0,       0.0, 1.0),
            resilience        = Matrix.Clamp(profile.resilience or 0.5,        0.0, 1.0),
            snitch_tendency   = Matrix.Clamp(profile.snitch_tendency or 0.0,   0.0, 1.0),
            economic_pressure = Matrix.Clamp(profile.economic_pressure or 0.0, 0.0, 1.0),
            cognitive_shifter = Matrix.Clamp(profile.cognitive_shifter or 0.5, 0.0, 1.0),
            skill_chemistry   = Matrix.Clamp(profile.skill_chemistry or 0.3,   0.0, 1.0),
            skill_cyber       = Matrix.Clamp(profile.skill_cyber or 0.0,       0.0, 1.0),
            skill_logistics   = Matrix.Clamp(profile.skill_logistics or 0.0,   0.0, 1.0),
            -- ★ [MADDE 4] Ox_Target ile devsirilen sokak ajanlari icin
            -- 1.0 (mutlak sadik) gecirilir (bkz. server/recruitment.lua
            -- RecruitStreetNpc). Diger tum cagri yerleri profile.loyalty_base
            -- GECMEDIGI icin varsayilan 0.5'te kalir -- ESKI davranis
            -- DEGISMEDI.
            loyalty_base      = Matrix.Clamp(profile.loyalty_base or 0.5,      0.0, 1.0)
        },
        biology = {
            fatigue_level             = 0.0,
            cortisol_level            = 0.0,
            withdrawal_index          = 0.0,
            addiction_level           = Matrix.Clamp(profile.addiction_level or 0.0, 0.0, 100.0),
            base_cortisol_recovery_rate = Config.BaseCortisolRecoveryRate,
            fatigue_critical_since    = nil,
            burned_this_episode       = false
        },
        state = {
            activity        = profile.activity or 'idle',
            trap_house_id   = profile.trap_house_id,
            coords          = profile.coords,
            spawned         = false,
            net_id          = nil,
            elapsed_seconds = 0,
            -- ★ [H12] Co-Op Mutex: aktif bir dispatch (tekli/rotalı) varken
            -- bu bota ikinci bir sevk emri verilmesini engeller.
            is_locked       = false,
            -- ★ [H13] Taktik HUD "Mekanik" bülteni için ham silah aşınması
            -- (1.0 = kusursuz, 0.0 = tamamen erimiş). Bkz. /botmekanik.
            weapon_wear_level = 1.0,
            -- ★ KATMAN 7 [T1]: bot şu an bir trap house'un GTA Online
            -- interior hücresinde (Config.TrapHouseInterior.Shell, harita
            -- dışındaki paylaşımlı "interior cebi") mi sayılıyor? nil ise
            -- hayır. BeginPhysicalDispatch/BeginRouteDispatch bu alanı
            -- görürse Çıkış Köprüsü'nü (bkz. ResolveExteriorBridgeOrigin)
            -- devreye sokar. Yalnızca server/logistics.lua'nın Mühimmat
            -- Dağıtım Görevi gibi "bot depo/stash işlemi yapıyor" akışları
            -- tarafından set edilir (bkz. Matrix.SetBotInteriorTrapHouse).
            interior_trap_house_id = nil
        }
    }


    Matrix.Bots[id] = bot
    Matrix.MarkBotDirty(id)
    Matrix.Log('CORE', 'Bot #%d matrise yazildi: %s (%s)', id, bot.name, bot.role)
    return bot
end

function Matrix.GetBot(id) return Matrix.Bots[id] end

-- ★ [GEMINI-4] PUBLIC READ-ONLY ACCESS (Anti Pointer Mutation)
-- Dış modüllerin bot verilerini KENDİ BELLEK ALANLARINA sızdırmasını
-- engellemek için public getter ReadOnly proxy döner. İç modüller
-- (bu dosya ve main ticker), Matrix.Bots[id] üzerinden MUTABLE erişime
-- devam eder — mevcut davranış KORUNUR.
function Matrix.GetBotReadOnly(id, cellName)
    local bot = Matrix.Bots[id]
    if not bot then return nil end
    if not (Matrix.Diagnostics and Matrix.Diagnostics.WrapReadOnlyCell) then
        return bot   -- savunmacı geri düşüş
    end
    return Matrix.Diagnostics.WrapReadOnlyCell(bot, cellName or ('bot_cell_' .. tostring(id)), id)
end

-- ★ [GEMINI-4] Sınıflar arası güvenli derin kopya.
function Matrix.GetBotDeepCopy(id)
    local bot = Matrix.Bots[id]
    if not bot then return nil end
    if not (Matrix.Diagnostics and Matrix.Diagnostics.DeepCopyCell) then
        return bot
    end
      return Matrix.Diagnostics.DeepCopyCell(bot)
end


function Matrix.RemoveBot(id, reason)
    local bot = Matrix.Bots[id]
    if not bot then return false end


    if Matrix.Dispatches[id] then
        Matrix.DespawnDispatchEntity(id, Matrix.Dispatches[id])
        Matrix.Dispatches[id] = nil
    end


    bot.status = reason or 'burned'
    local query, params = BuildBotUpsert({ bot })
    if query then MySQL.prepare(query, params) end


    -- ★ [OTONOM ALT HUCRE BOLUNMESI] Bot bir cete lideriyse (role=='Leader')
    -- ve 'deceased' olarak dusuyorsa, o trap house'a bagli TUM otonom
    -- Toplu Satis Hub'larinin FragmentTerritory ile Alt Hucrelere
    -- bolunmesini tetikle -- 'matrix:internal:bureauLockdown' ILE AYNI
    -- pasif/loose-coupling event deseni (bkz. server/district_hubs.lua).
    if reason == 'deceased' and bot.role == 'Leader' and bot.state and bot.state.trap_house_id then
        local deadLeaderTrapHouseId = bot.state.trap_house_id
        local fragOk, fragErr = pcall(function()
            TriggerEvent('matrix:internal:gangLeaderDeceased', deadLeaderTrapHouseId, id)
        end)
        if not fragOk then
            Matrix.Log('CORE', '[HATA] gangLeaderDeceased yayini basarisiz (yutuldu): %s', tostring(fragErr))
        end
    end


    P.dirtyBots[id] = nil
    Matrix.Bots[id] = nil
    Matrix.Log('CORE', 'Bot #%d aktif matristen kaldirildi: %s', id, bot.status)
    return true
end


-- =====================================================================
-- ACTOR RESOLUTION
-- =====================================================================
function Matrix.ResolveActor(actorRef)
    if type(actorRef) ~= 'table' then return nil end
    if actorRef.kind == 'bot' and actorRef.id then
        return Matrix.Bots[actorRef.id]
    end
    if actorRef.kind == 'player' and type(actorRef.source) == 'number' then
        return Matrix.GetOrCreatePlayerState(actorRef.source)
    end
    return nil
end


function Matrix.GetOrCreatePlayerState(src)
    if type(src) ~= 'number' or src <= 0 then return nil end


    local ok, player = pcall(function() return Matrix.QBX:GetPlayer(src) end)
    if not ok or not player or not player.PlayerData then return nil end
    local citizenid = player.PlayerData.citizenid
    if not citizenid then return nil end


    local state = Matrix.PlayerState[citizenid]
    if state then
        Matrix.DecayPlayerCortisol(state)
        Matrix.PlayerSourceIndex[src] = citizenid
        return state
    end


    state = {
        id         = citizenid,
        citizenid  = citizenid,
        dna_id     = ('DNA-PLR-%s'):format(citizenid),
        psychology = { skill_chemistry = Config.Player.DefaultSkillChemistry },
        biology    = {
            fatigue_level             = 0.0,
            cortisol_level            = 0.0,
            resilience                = Config.Player.DefaultResilience,
            base_cortisol_recovery_rate = Config.BaseCortisolRecoveryRate,
            last_update               = Matrix.Now()
        },
        state = { activity = 'idle' }
    }


    Matrix.PlayerState[citizenid]       = state
    Matrix.PlayerSourceIndex[src]       = citizenid


    pcall(function()
        MySQL.prepare([[
            INSERT INTO matrix_player_state (citizenid, cortisol_level, fatigue_level, updated_at)
            VALUES (?, 0.0, 0.0, NOW())
            ON DUPLICATE KEY UPDATE citizenid = citizenid
        ]], { citizenid })
    end)


    return state
end


function Matrix.DecayPlayerCortisol(state)
    if not state or not state.biology then return end
    local now = Matrix.Now()
    local last = state.biology.last_update or now
    local elapsedMinutes = math_floor((now - last) / 60)
    if elapsedMinutes <= 0 then return end


    local recovery = state.biology.base_cortisol_recovery_rate
                     * state.biology.resilience
                     * elapsedMinutes
    state.biology.cortisol_level = Matrix.Clamp(state.biology.cortisol_level - recovery, 0.0, 1.0)
    state.biology.last_update    = last + (elapsedMinutes * 60)
end


-- =====================================================================
-- [H1] QBOX onPlayerLoaded — Warm Cache
-- =====================================================================
AddEventHandler('qbx_core:server:onPlayerLoaded', function(payload)
    local src
    if type(payload) == 'table' then
        src = tonumber(payload.source or payload.src or payload[1])
    else
        src = tonumber(payload)
    end
    if not src or src <= 0 then return end
    Matrix.GetOrCreatePlayerState(src)
end)


AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    if type(player) ~= 'table' or not player.PlayerData then return end
    local src = tonumber(player.PlayerData.source)
    if src and src > 0 then Matrix.GetOrCreatePlayerState(src) end
end)


-- =====================================================================
-- DB LOAD
-- =====================================================================
local function LoadBotsFromDatabase()
    local rows = MySQL.query.await('SELECT * FROM matrix_bots WHERE status = ?', { 'active' }) or {}
    for _, row in ipairs(rows) do
        Matrix.Bots[row.id] = {
            id = row.id, dna_id = row.dna_id, name = row.name,
            role = row.role, status = row.status,
            -- ★ [ADLI RPG] Botu bir citizenid'ye baglar (or. /cetelideriata
            -- ile atanan cete lideri) -- server/bureau.lua ExecuteVerdict
            -- (karakter wipe) bu alandan o citizenid'ye bagli TUM botlari
            -- 'disbanded' moduna cekmek icin bulur.
            handler_citizenid = row.handler_citizenid,
            psychology = {
                fear_factor       = row.fear_factor       or 0.0,
                resilience        = row.resilience        or 0.5,
                snitch_tendency   = row.snitch_tendency   or 0.0,
                economic_pressure = row.economic_pressure or 0.0,
                cognitive_shifter = row.cognitive_shifter or 0.5,
                skill_chemistry   = row.skill_chemistry   or 0.3,
                skill_cyber       = row.skill_cyber       or 0.0,
                skill_logistics   = row.skill_logistics   or 0.0,
                loyalty_base      = row.loyalty_base      or 0.5
            },
            biology = {
                fatigue_level             = row.fatigue_level              or 0.0,
                cortisol_level            = row.cortisol_level             or 0.0,
                withdrawal_index          = row.withdrawal_index           or 0.0,
                addiction_level           = row.addiction_level            or 0.0,
                base_cortisol_recovery_rate = row.base_cortisol_recovery_rate or Config.BaseCortisolRecoveryRate,
                fatigue_critical_since    = nil,
                burned_this_episode       = false
            },
            state = {
                activity        = 'idle',
                trap_house_id   = row.trap_house_id,
                coords          = nil,
                spawned         = false,
                net_id          = nil,
                elapsed_seconds = 0,
                is_locked       = false,
                weapon_wear_level = 1.0,
                -- ★ KATMAN 7 [T1]: bkz. CreateBotRecord'daki aynı alan yorumu.
                -- Sunucu yeniden başladığında hiçbir bot fiilen içeride
                -- SAYILMAZ (kalıcı bir sütun değil — salt runtime bayrağı).
                interior_trap_house_id = nil
            }
        }
        if row.id >= Matrix.NextBotId then Matrix.NextBotId = row.id + 1 end
    end
    Matrix.Log('CORE', '%d bot matristen belleğe yüklendi.', #rows)
end


-- =====================================================================
-- PED SPAWN / DESPAWN
-- =====================================================================
local MATRIX_PED_INJECTION_MAX_TICKS   = 50
local MATRIX_PED_INJECTION_POLL_MS     = 10


local function AwaitEntityCreation(entity, maxTicks)
    local ticks = 0
    maxTicks = maxTicks or MATRIX_PED_INJECTION_MAX_TICKS
    while not DoesEntityExist(entity) and ticks < maxTicks do
        Wait(MATRIX_PED_INJECTION_POLL_MS)
        ticks = ticks + 1
    end
    return DoesEntityExist(entity)
end
Matrix.AwaitEntityCreation = AwaitEntityCreation


--- ★ [H8] Entity güvenli imha yardımcısı — hem null hem 0 hem de zaten
--- yok olmuş handle'lara karşı dayanıklı.
local function SafeDeleteEntity(handle)
    if not handle or handle == 0 then return end
    local ok = pcall(function()
        if DoesEntityExist(handle) then
            DeleteEntity(handle)
        end
    end)
    return ok
end


function Matrix.SpawnBot(id, coords)
    local bot = Matrix.Bots[id]
    if not bot then return false, 'bot_missing' end
    if bot.state.spawned then return false, 'already_spawned' end
    if type(coords) ~= 'vector4' and type(coords) ~= 'vector3' then
        return false, 'bad_coords'
    end


    local modelHash, modelName = ResolveRolePedModel(bot.role)
    local x, y, z   = coords.x, coords.y, coords.z
    local heading   = coords.w or 0.0


    -- ★ [H14] ANTI-CRASH GUARD: SetEntityAsMissionEntity SUNUCUDA ÇAĞRILMAZ
    -- (client-only native → nil value → script kilitlenir). Kalıcılık/ağ
    -- mühürleme CreatePed'in kendi bayrakları + SetEntityOrphanMode ile kurulur.
    local ped = CreatePed(0, modelHash, x, y, z, heading, true, true)
    if not AwaitEntityCreation(ped) then
        SafeDeleteEntity(ped)
        Matrix.Log('CORE', '[HATA] Bot #%d OneSync ped doğrulaması zaman aşımı.', id)
        return false, 'timeout'
    end


    pcall(SetEntityOrphanMode, ped, 2) -- KeepEntity: server entity'yi asla silmez
    local netId = NetworkGetNetworkIdFromEntity(ped)


    bot.state.spawned = true
    bot.state.net_id  = netId
    bot.state.coords  = vector3(x, y, z)


    TriggerClientEvent('matrix:client:injectBot', -1, id, bot.role, coords, bot.dna_id, netId)
    Matrix.Log('CORE', 'Bot #%d enjekte edildi [%s / %s] NetID:%d', id, bot.role, modelName, netId)
    return true, netId
end


function Matrix.DespawnBot(id)
    local bot = Matrix.Bots[id]
    if not bot then return false end
    if not bot.state.spawned then return false end


    if bot.state.net_id then
        local ped = NetworkGetEntityFromNetworkId(bot.state.net_id)
        if ped and ped ~= 0 and DoesEntityExist(ped) then SafeDeleteEntity(ped) end
    end


    TriggerClientEvent('matrix:client:extractBot', -1, id)
    bot.state.spawned = false
    bot.state.net_id  = nil
    Matrix.Log('CORE', 'Bot #%d dünyadan çekildi.', id)
    return true
end


-- =====================================================================
-- PHYSICAL DISPATCH RUNTIME  ★ REVİZYON #1 + [H8] + KATMAN 5 [H11][H12] ★
-- =====================================================================


local DISPATCH_VEHICLE_MODELS = {
    car       = 'sultan',
    motorbike = 'bati',
}


local DISPATCH_ARRIVAL_RADIUS_M       = 6.0
local DISPATCH_POLICE_PROXIMITY_M     = 60.0
local DISPATCH_POLICE_DECRYPT_TICK    = 0.015
local DISPATCH_BUSTED_PROXIMITY_M     = 8.0
local DISPATCH_BUSTED_DWELL_TICKS     = 8
local DISPATCH_ALPR_RADIUS_M          = 250.0
local DISPATCH_TASK_REISSUE_TICKS     = 25


-- ★ KATMAN 5 ULTIMATE [U7]: YAYA BOT TAKILMA/SIKIŞMA MUHAFIZI (Anti-Stuck)
-- Yaya (vehicle_type == 'foot') dispatch'ler artık TaskGoStraightToCoord
-- (düz çizgi, engel farkında DEĞİL — karmaşık mimarilerde/kapalı alanlarda
-- duvara saplanıp kalabiliyordu) YERİNE TaskFollowNavMeshToCoord kullanır:
-- bu, GTA V'in yerel yaya NavMesh yol ağını kullanan, engellerin etrafından
-- OTOMATİK dolanan (pathfinding) asenkron bir görevdir. "Asenkron" olma
-- özelliği DEĞİŞMEDİ — tıpkı eski TaskGoStraightToCoord gibi bu da bir
-- "ateşle-unut" (fire-and-forget) görev atamasıdır; ped'in ilerlemesi
-- her zamanki gibi TickPhysicalDispatches'in kendi mesafe/tick döngüsü
-- tarafından asenkron olarak izlenir (bu dosyada 0 Resmon bütçesini bozacak
-- YENİ bir thread/Wait YOKTUR). stoppingRange=0.0 bırakılır — "vardı mı"
-- kararı zaten dışarıdaki DISPATCH_ARRIVAL_RADIUS_M kontrolüne aittir;
-- persistFollowing=false — mevcut DISPATCH_TASK_REISSUE_TICKS periyodik
-- yeniden-görevlendirme güvenlik ağı (aşağıda, değişmedi) zaten görevi
-- düzenli aralıklarla tazeliyor. Araç (vehicle_net_id dolu) dispatch'leri
-- BU DEĞİŞİKLİKTEN ETKİLENMEZ — TaskVehicleDriveToCoord aynen kalıyor.
local NAVMESH_TASK_TIMEOUT            = -1  -- sinirsiz (TaskGoStraightToCoord ile ayni davranis)
local NAVMESH_STOPPING_RANGE_M        = 0.0 -- varis karari TickPhysicalDispatches'e ait
local NAVMESH_PERSIST_FOLLOWING       = false


local DISPATCH_BASE_FOOT_SPEED_MS     = 1.4
local DISPATCH_BASE_VEHICLE_SPEED_MS  = 15.0
local DISPATCH_MIN_SPEED_FRACTION     = 0.25


-- ★ KATMAN 5 ULTIMATE [U8]: ACİL TAHLİYE (PANİK) MOTORU sabitleri.
-- "Son hız" (top speed) normal sevkiyat hızlarının ÜZERİNDE, sabit ve
-- deterministik iki değerdir (RNG yok). PANIC_REISSUE_TICKS, normal
-- DISPATCH_TASK_REISSUE_TICKS'ten (25 tick) BİLİNÇLİ olarak daha kısadır:
-- panik modundaki bot, tetikleyen oyuncunun O ANKİ canlı konumunu HER
-- yenileme turunda yeniden okur (bkz. TickPhysicalDispatches) — oyuncu
-- hareket etse bile "sana doğru geliyor" davranışı sürer. Bu, YENİ bir
-- thread/Wait AÇMAZ — aynı mevcut tick döngüsünün içinde, yalnızca farklı
-- bir eşik değeriyle çalışır; 0 Resmon bütçesi korunur.
local PANIC_EVAC_VEHICLE_SPEED_MS     = 25.0
local PANIC_EVAC_FOOT_SPEED_MS        = 4.0
local PANIC_REISSUE_TICKS             = 5


local PoliceSources       = {}
local policeFailCount     = 0
local policeDisabledUntil = 0


local function RefreshPoliceCache()
    if Matrix.Now() < policeDisabledUntil then return end


    local ok, players = pcall(function() return Matrix.QBX:GetQBPlayers() end)
    if not ok or type(players) ~= 'table' then
        policeFailCount = policeFailCount + 1
        if policeFailCount >= 5 then
            policeDisabledUntil = Matrix.Now() + 60
            policeFailCount = 0
            Matrix.Log('CORE', '[UYARI] GetQBPlayers 5 kez ust uste basarisiz oldu; 60sn devre disi birakildi.')
        end
        return
    end
    policeFailCount = 0


    local fresh = {}
    for src, player in pairs(players) do
        if player and player.PlayerData and player.PlayerData.job then
            local job = player.PlayerData.job
            if job.onduty and (job.name == 'police' or job.name == 'sheriff' or job.type == 'leo') then
                fresh[src] = true
            end
        end
    end
    PoliceSources = fresh
end


CreateThread(function()
    while true do
        Wait(5000)
        RefreshPoliceCache()
    end
end)


local function LocalGetVehicleProfile(vehicleType)
    return Config.Logistics.VehicleTypes[vehicleType]
        or Config.Logistics.VehicleTypes[Config.Logistics.DefaultVehicleType]
end


local function LocalGetBotInventoryWeight(bot)
    local inventoryId = ('dealer_%d'):format(bot.id)
    local ok, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], inventoryId)
    if not ok or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return 0.0 end
    local total = 0.0
    for _, item in pairs(inv.items) do
        if type(item) == 'table' then
            total = total + ((tonumber(item.weight) or 0.0) * (tonumber(item.count) or 0.0))
        end
    end
    return total
end


local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        local d = #(coords - house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId, nearestDist
end


local function FindDeadZone(coords)
    for _, zone in ipairs(Config.Logistics.DeadZones) do
        if #(coords - zone.coords) <= zone.radius then return zone end
    end
    return nil
end


local function FindActiveDeadDropAt(destination)
    for _, drop in ipairs(Config.Supplier.DeadDrops) do
        if #(destination - drop.coords) <= drop.radius then return drop end
    end
    return nil
end


local function _SafeVec(v)
    return v and v.x == v.x and v.y == v.y and v.z == v.z
           and v.x ~= math_huge and v.x ~= -math_huge
           and v.y ~= math_huge and v.y ~= -math_huge
           and v.z ~= math_huge and v.z ~= -math_huge
end


--- ★ HATA DÜZELTMESİ: FiveM'in vector kütüphanesinde `#` (uzunluk/magnitude)
--- operatörü yalnızca vector3 için tanımlıdır — vector4 üzerinde (veya bir
--- vector4 içeren çıkarma işleminin sonucunda) ÇAĞRILIRSA "attempt to
--- perform unsupported operation on a vector value" hatasıyla script çöker.
--- origin (SafeForwardCoords'tan gelir) DAİMA vector4'tür (heading taşır);
--- ama spawn çağrılarında zaten yalnızca .x/.y/.z okunur, heading hiç
--- kullanılmaz — bu yüzden mesafe/depolama amaçlı TÜM vector'lar dispatch
--- fonksiyonlarına girer girmez burada saf vector3'e indirgenir.
local function _ToVec3(v)
    if type(v) == 'vector4' then return vector3(v.x, v.y, v.z) end
    return v
end


--- ★ [H11] Ortak ped/araç doğum yardımcısı. BeginPhysicalDispatch VE
--- BeginRouteDispatch tarafından paylaşılır; hata yollarında yarım kalan
--- entity'ler DÜNYADAN SİLİNİR (bkz. [H8]) — davranış tek-hedef sürümüyle
--- birebir aynıdır, yalnızca ortaklaştırılmıştır.
local function SpawnDispatchActors(bot, origin, vehicleType, cruiseSpeed, firstDestination)
    -- ★ [H15] Config destekli rol->ped ataması (bkz. ResolveRolePedModel).
    local pedHash = ResolveRolePedModel(bot.role)
    local isFoot  = (vehicleType == 'foot')


    local ped, vehicle
    local vehicleNetId = nil


    if isFoot then
        -- ★ [H14] SetEntityAsMissionEntity SUNUCUDA ÇAĞRILMAZ (client-only
        -- native → nil value → script kilitlenir).
        ped = CreatePed(0, pedHash, origin.x, origin.y, origin.z, 0.0, true, true)
        if not AwaitEntityCreation(ped) then
            SafeDeleteEntity(ped)
            return nil, nil, nil, nil, 'ped_spawn_timeout'
        end
        pcall(SetEntityOrphanMode, ped, 2) -- KeepEntity: server entity'yi asla silmez
        -- ★ KATMAN 7 [T1] FAZ 2: görev atanmadan HEMEN ÖNCE, entity KOŞULSUZ
        -- olarak dış dünyaya (Bucket 0) bağlanır — bkz. ResolveExteriorBridgeOrigin
        -- dosya-başı yorumu. Bot daha önce hangi interior bucket'ında
        -- sayılıyor olursa olsun, buradan itibaren NavMesh yol ağı DAİMA
        -- ana dünya (Bucket 0) rotasını kullanır.
        pcall(SetEntityRoutingBucket, ped, 0)
        SetEntityCoords(ped, origin.x, origin.y, origin.z, false, false, false, false)


        -- ★ [U7] NavMesh tabanli asenkron yuruyus - engellerin etrafindan
        -- dolanir, TaskGoStraightToCoord'un aksine duvara/geometriye saplanip
        -- kalmaz.
        local taskOk = pcall(TaskFollowNavMeshToCoord,
            ped,
            firstDestination.x, firstDestination.y, firstDestination.z,
            cruiseSpeed, NAVMESH_TASK_TIMEOUT, NAVMESH_STOPPING_RANGE_M,
            NAVMESH_PERSIST_FOLLOWING, 0.0
        )
        if not taskOk then
            SafeDeleteEntity(ped)
            return nil, nil, nil, nil, 'task_assignment_failed'
        end
    else
        local vehModelName = DISPATCH_VEHICLE_MODELS[vehicleType] or DISPATCH_VEHICLE_MODELS.car
        local vehHash      = GetHashKey(vehModelName)


        -- ★ [H14] SetEntityAsMissionEntity SUNUCUDA ÇAĞRILMAZ; kalıcılık
        -- CreateVehicle'ın kendi (true, true) bayrakları + SetEntityOrphanMode
        -- ile kurulur.
        vehicle = CreateVehicle(vehHash, origin.x, origin.y, origin.z, 0.0, true, true)
        if not AwaitEntityCreation(vehicle) then
            SafeDeleteEntity(vehicle)
            return nil, nil, nil, nil, 'vehicle_spawn_timeout'
        end
        pcall(SetEntityOrphanMode, vehicle, 2) -- KeepEntity
        -- ★ KATMAN 7 [T1] FAZ 2: bkz. yaya dalındaki aynı çağrı yorumu —
        -- araç da sürüş görevi atanmadan ÖNCE koşulsuz Bucket 0'a bağlanır.
        pcall(SetEntityRoutingBucket, vehicle, 0)


        ped = CreatePedInsideVehicle(vehicle, 0, pedHash, -1, true, true)
        if not AwaitEntityCreation(ped) then
            SafeDeleteEntity(ped)
            SafeDeleteEntity(vehicle)
            return nil, nil, nil, nil, 'ped_in_vehicle_timeout'
        end
        pcall(SetEntityOrphanMode, ped, 2) -- KeepEntity
        pcall(SetEntityRoutingBucket, ped, 0)


        local taskOk = pcall(TaskVehicleDriveToCoord,
            ped,
            vehicle,
            firstDestination.x, firstDestination.y, firstDestination.z,
            cruiseSpeed,
            0,
            vehHash,
            16777216,
            5.0,
            1
        )
        if not taskOk then
            SafeDeleteEntity(ped)
            SafeDeleteEntity(vehicle)
            return nil, nil, nil, nil, 'task_assignment_failed'
        end


        vehicleNetId = NetworkGetNetworkIdFromEntity(vehicle)
    end


    local pedNetId = NetworkGetNetworkIdFromEntity(ped)
    return ped, vehicle, pedNetId, vehicleNetId, nil
end


-- =====================================================================
-- ★ KATMAN 7 [T1]: İKİ-FAZLI GTA ONLINE ÇIKIŞ KÖPRÜSÜ (Exit Bridge)
--
-- SORUN: Config.TrapHouseInterior.Shell (bkz. shared/config.lua), gerçek
-- harita sınırlarının tamamen dışındaki paylaşımlı bir GTA Online interior
-- hücresidir (bob74_ipl GTAOHouseLow1, X:261.46 Y:-998.82 Z:-99.01 — bu
-- "interior cebi" normal sokak NavMesh ağına HİÇ bağlı değildir). Bir bot
-- mantıken bu hücrenin içindeyken (server/logistics.lua Mühimmat Dağıtım
-- Görevi gibi bir depo/stash işlemi onu oraya "koymuşsa" — bkz.
-- Matrix.SetBotInteriorTrapHouse) doğrudan o hücre koordinatından bir
-- fiziksel sevk (TaskVehicleDriveToCoord/TaskFollowNavMeshToCoord)
-- başlatılırsa, NavMesh yol ağı çözülemez ve görev ataması
-- 'task_assignment_failed' ile başarısız olur (bkz. SpawnDispatchActors);
-- yakındaki oyunculara mesafe koruması (Işınlanma Guard'ı) da bu
-- sahte/boşluk koordinatı yüzünden yanlış tetiklenebilir.
--
-- ÇÖZÜM (FAZ 1 — burada): BeginPhysicalDispatch/BeginRouteDispatch'in
-- HER İKİSİ de rota hesaplanmadan ve hiçbir entity dünyaya doğmadan ÖNCE
-- bu fonksiyonu çağırır. Bot interior hücresindeyse (interior_trap_house_id
-- doluysa) origin, o Trap House'un GERÇEK harita-yüzeyi kapı koordinatına
-- (Matrix.TrapHouses[id].coords — Katman 2'den beri var olan, DEĞİŞMEYEN
-- alan) asenkron olarak köprülenir; interior bayrağı hemen temizlenir.
-- Bu fazda MinDispatchDistanceMeters (Işınlanma Koruması) guard'ı
-- YAPISAL OLARAK BAYPAS edilir (ikinci dönüş değeri `true`) — çünkü bu
-- bacak bir "gerçek" fiziksel yer değiştirme değil, asla var olmamış bir
-- interior konumundan haritaya ÇIKIŞTIR; mesafe ölçümü buradaki anlamsız
-- koordinat farkı yüzünden yanlışlıkla sevk'i reddetmemelidir.
--
-- FAZ 2 (SpawnDispatchActors içinde, aşağıda ayrıca işaretli): entity
-- (ped/araç) bu köprülenmiş origin'de doğar doğmaz, herhangi bir görev
-- atanmadan HEMEN ÖNCE SetEntityRoutingBucket(entity, 0) ile KOŞULSUZ
-- olarak dış dünyaya (Bucket 0) bağlanır — bot daha önce hangi interior
-- bucket'ında (Config.TrapHouseInterior.BucketBase+N) sayılıyor olursa
-- olsun, dış dünyanın asfalta bağlı NavMesh düğümleri artık RAM'e kilitli
-- olduğu için TaskVehicleDriveToCoord/TaskFollowNavMeshToCoord sıfır
-- hatayla ateşlenir.
-- =====================================================================
local function ResolveExteriorBridgeOrigin(bot, requestedOrigin)
    local interiorTrapId = bot.state.interior_trap_house_id
    if not interiorTrapId then
        return requestedOrigin, false
    end

    -- İç mekan bayrağı HER DURUMDA temizlenir (bot artık "sahaya çıkıyor") —
    -- trap house sonradan silinmiş olsa bile bayrağın asılı kalmasına izin
    -- verilmez. /interiordurum debug panelinin yansıma tablosu da (yüklüyse)
    -- birlikte temizlenir.
    bot.state.interior_trap_house_id = nil
    if Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.ClearStashRunMark then
        Matrix.TrapHouseInterior.ClearStashRunMark(bot.id)
    end

    local house = Matrix.TrapHouses and Matrix.TrapHouses[interiorTrapId]
    if not house or not _SafeVec(house.coords) then
        Matrix.Log('CORE',
            '[UYARI] Bot #%d interior köprüsü için trap house #%s bulunamadı; orijinal origin kullanıldı.',
            bot.id, tostring(interiorTrapId))
        return requestedOrigin, false
    end

    Matrix.Log('CORE',
        '[CIKIS KOPRUSU] Bot #%d GTA Online interior hücresinden (trap #%d) harita yüzeyindeki fiziki kapı koordinatına çıkartıldı: (%.1f,%.1f,%.1f)',
        bot.id, interiorTrapId, house.coords.x, house.coords.y, house.coords.z)

    return house.coords, true
end


--- ★ KATMAN 7 [T1/T2]: bir botu mantıken bir trap house'un interior
--- hücresinin içinde işaretler (depo/stash işlemi yapıyor). Bir sonraki
--- fiziksel sevk (BeginPhysicalDispatch/BeginRouteDispatch), Çıkış
--- Köprüsü'nü otomatik tetikleyip bu bayrağı tüketir/temizler.
function Matrix.SetBotInteriorTrapHouse(botId, trapHouseId)
    local bot = Matrix.Bots[botId]
    if not bot then return false end
    bot.state.interior_trap_house_id = trapHouseId
    return true
end


--- ★ [H8][H12] Fiziksel sevki başlatır (tek hedef). Hata yollarında yarım
--- kalan entity'ler DÜNYADAN SİLİNİR — hiçbir ped/araç orphan kalmaz.
--- Co-Op Mutex: bot.state.is_locked true ise sevk hiç başlamaz.
function Matrix.BeginPhysicalDispatch(botId, origin, destination, plate, vehicleType, etaSeconds, dispatcherSrc, frictionDivisor)
    botId = tonumber(botId)
    if not botId then return false, 'bad_bot_id' end


    frictionDivisor = Matrix.Clamp(tonumber(frictionDivisor) or 1.0, 1.0, 1.0 / DISPATCH_MIN_SPEED_FRACTION)


    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    if bot.state.is_locked then return false, 'bot_locked' end
    if Matrix.Dispatches[botId] then return false, 'already_dispatched' end
    if type(origin) ~= 'vector3' and type(origin) ~= 'vector4' then return false, 'bad_origin' end
    if type(destination) ~= 'vector3' and type(destination) ~= 'vector4' then return false, 'bad_destination' end


    -- ★ HATA DÜZELTMESİ: vector4 (heading taşıyan origin) ile vector3
    -- arasındaki `#(a - b)` mesafe hesapları "unsupported operation on a
    -- vector value" ile çöker. Buradan itibaren SAF vector3 kullanılır.
    origin      = _ToVec3(origin)
    destination = _ToVec3(destination)


    -- ★ KATMAN 7 [T1] FAZ 1: bot bir interior hücresindeyse origin buradan
    -- itibaren o trap house'un GERÇEK harita-yüzeyi kapı koordinatıdır;
    -- `bridged=true` ise Işınlanma Koruması bu bacak için baypas edilir.
    local bridged
    origin, bridged = ResolveExteriorBridgeOrigin(bot, origin)


    if not _SafeVec(origin) or not _SafeVec(destination) then
        return false, 'corrupt_vector'
    end


    -- ★ Işınlanma koruması: dünyada ped/araç DOĞMADAN ÖNCE mesafe kontrolü.
    -- Çıkış Köprüsü bacağı (bridged=true) yapısal olarak bu kontrolün
    -- dışındadır — bkz. ResolveExteriorBridgeOrigin yorumu.
    if not bridged and #(origin - destination) < Config.Logistics.MinDispatchDistanceMeters then
        return false, 'too_close'
    end


    if bot.state.spawned then
        Matrix.DespawnBot(botId)
        Wait(50)
    end


    local isFoot      = (vehicleType == 'foot')
    local baseSpeed    = isFoot and DISPATCH_BASE_FOOT_SPEED_MS or DISPATCH_BASE_VEHICLE_SPEED_MS
    local cruiseSpeed  = math_max(baseSpeed / frictionDivisor, baseSpeed * DISPATCH_MIN_SPEED_FRACTION)


    local ped, vehicle, pedNetId, vehicleNetId, spawnErr =
        SpawnDispatchActors(bot, origin, vehicleType, cruiseSpeed, destination)
    if spawnErr then return false, spawnErr end


    bot.state.spawned    = true
    bot.state.net_id     = pedNetId
    bot.state.is_locked  = true


    Matrix.Dispatches[botId] = {
        bot_id            = botId,
        entity_net_id     = pedNetId,
        vehicle_net_id    = vehicleNetId,
        plate             = plate,
        vehicle_type      = vehicleType,
        profile           = LocalGetVehicleProfile(vehicleType),
        origin            = origin,
        destination       = destination,
        route_queue       = nil,
        route_index       = nil,
        eta_estimate      = etaSeconds or 0.0,
        cruise_speed      = cruiseSpeed,
        elapsed           = 0.0,
        last_coords       = origin,
        weight_total      = LocalGetBotInventoryWeight(bot),
        dispatcher_src    = dispatcherSrc,
        comms_lost        = false,
        pending_events    = {},
        alpr_logged_traps = {},
        combat_damage     = 0.0,
        police_dwell      = 0,
        task_retry_ticks  = 0,
        started_at        = Matrix.Now()
    }


    bot.state.activity = 'distribution'


    TriggerClientEvent('matrix:client:injectBot', -1, botId, bot.role, origin, bot.dna_id, pedNetId)


    Matrix.Log('CORE',
        'Fiziksel sevk başlatıldı: Bot #%d [%s] Origin=(%.1f,%.1f,%.1f) → Hedef=(%.1f,%.1f,%.1f)',
        botId, vehicleType, origin.x, origin.y, origin.z, destination.x, destination.y, destination.z)


    return true
end


--- ★ [H11][H12] KATMAN 5: Multi-Waypoint Taktik Rota Motoru.
--- `waypointRefs` sırayla ziyaret edilecek ara nokta listesi (vector3'ler);
--- `finalRef` zincirin sonunda bota "sızma" (arrived) emri verecek ana
--- üs/final hedeftir. Bot bir uğrağa vardığı an (dist <= DISPATCH_ARRIVAL_
--- RADIUS_M) DURAKSAMADAN bir sonraki uğrağa yönlendirilir; zincirin son
--- halkası (finalRef) tamamlandığında dispatch normal şekilde 'arrived'
--- olarak kapanır.
---
--- Işınlanma koruması: HER bacak (origin->wp1->wp2->...->final) ayrı ayrı
--- MinDispatchDistanceMeters ile karşılaştırılır — TEK BİR bacak bile
--- eşiğin altındaysa zincir hiçbir entity dünyaya doğmadan reddedilir.
--- Co-Op Mutex: bot.state.is_locked true ise rota hiç başlamaz.
function Matrix.BeginRouteDispatch(botId, origin, waypointRefs, finalRef, plate, vehicleType, dispatcherSrc, frictionDivisor)
    botId = tonumber(botId)
    if not botId then return false, 'bad_bot_id' end


    frictionDivisor = Matrix.Clamp(tonumber(frictionDivisor) or 1.0, 1.0, 1.0 / DISPATCH_MIN_SPEED_FRACTION)


    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    if bot.state.is_locked then return false, 'bot_locked' end
    if Matrix.Dispatches[botId] then return false, 'already_dispatched' end
    if type(origin) ~= 'vector3' and type(origin) ~= 'vector4' then return false, 'bad_origin' end
    -- ★ [E3] DİNAMİK WAYPOINT ESNEKLİĞİ: 0 ara uğrak da GEÇERLİDİR (bu durumda
    -- rota zinciri yalnızca finalRef'ten ibarettir — düz bir sevkle özdeştir).
    -- Zorunlu olan TEK şey finalRef'in geçerli bir vector olmasıdır.
    if type(waypointRefs) ~= 'table' then return false, 'bad_waypoints' end
    if type(finalRef) ~= 'vector3' and type(finalRef) ~= 'vector4' then return false, 'bad_destination' end


    -- ★ HATA DÜZELTMESİ: vector4 (heading taşıyan origin) ile vector3
    -- arasındaki `#(a - b)` mesafe hesapları "unsupported operation on a
    -- vector value" ile çöker (bkz. _ToVec3). Buradan itibaren rota
    -- zincirindeki HER nokta SAF vector3'tür.
    origin   = _ToVec3(origin)
    finalRef = _ToVec3(finalRef)
    for i = 1, #waypointRefs do
        waypointRefs[i] = _ToVec3(waypointRefs[i])
    end


    -- ★ KATMAN 7 [T1] FAZ 1: bkz. BeginPhysicalDispatch'teki aynı çağrı
    -- yorumu. Yalnızca origin (rotanın İLK bacağının başlangıcı) köprülenir
    -- — bu, "interior hücresinden haritaya çıkış" bacağıdır.
    local bridged
    origin, bridged = ResolveExteriorBridgeOrigin(bot, origin)


    if not _SafeVec(origin) or not _SafeVec(finalRef) then return false, 'corrupt_vector' end
    for i = 1, #waypointRefs do
        if not _SafeVec(waypointRefs[i]) then return false, 'corrupt_vector' end
    end


    local routeQueue = {}
    for i = 1, #waypointRefs do routeQueue[i] = waypointRefs[i] end
    routeQueue[#routeQueue + 1] = finalRef


    -- ★ Işınlanma koruması: HER bacak ayrı ayrı doğrulanır, hiçbir entity
    -- dünyaya doğmadan ÖNCE. Hangi bacağın çok kısa olduğunu çağırana
    -- bildirmek için leg index'i (i) ve ölçülen mesafeyi de döndürür.
    -- ★ [T1]: yalnızca İLK bacak (origin -> routeQueue[1]), bridged=true
    -- olduğunda bu kontrolün dışındadır — Çıkış Köprüsü SADECE bu bacağı
    -- kapsar, rotanın geri kalanı normal Işınlanma Koruması'na tabidir.
    local legOrigin = origin
    for i = 1, #routeQueue do
        local legDest = routeQueue[i]
        local legDist = #(legOrigin - legDest)
        if not (bridged and i == 1) and legDist < Config.Logistics.MinDispatchDistanceMeters then
            return false, 'too_close', i, legDist
        end
        legOrigin = legDest
    end


    if bot.state.spawned then
        Matrix.DespawnBot(botId)
        Wait(50)
    end


    local isFoot      = (vehicleType == 'foot')
    local baseSpeed    = isFoot and DISPATCH_BASE_FOOT_SPEED_MS or DISPATCH_BASE_VEHICLE_SPEED_MS
    local cruiseSpeed  = math_max(baseSpeed / frictionDivisor, baseSpeed * DISPATCH_MIN_SPEED_FRACTION)


    local ped, vehicle, pedNetId, vehicleNetId, spawnErr =
        SpawnDispatchActors(bot, origin, vehicleType, cruiseSpeed, routeQueue[1])
    if spawnErr then return false, spawnErr end


    bot.state.spawned    = true
    bot.state.net_id     = pedNetId
    bot.state.is_locked  = true


    Matrix.Dispatches[botId] = {
        bot_id            = botId,
        entity_net_id     = pedNetId,
        vehicle_net_id    = vehicleNetId,
        plate             = plate,
        vehicle_type      = vehicleType,
        profile           = LocalGetVehicleProfile(vehicleType),
        origin            = origin,
        destination       = routeQueue[1],
        route_queue       = routeQueue,
        route_index       = 1,
        eta_estimate      = 0.0,
        cruise_speed      = cruiseSpeed,
        elapsed           = 0.0,
        last_coords       = origin,
        weight_total      = LocalGetBotInventoryWeight(bot),
        dispatcher_src    = dispatcherSrc,
        comms_lost        = false,
        pending_events    = {},
        alpr_logged_traps = {},
        combat_damage     = 0.0,
        police_dwell      = 0,
        task_retry_ticks  = 0,
        started_at        = Matrix.Now()
    }


    bot.state.activity = 'distribution'


    TriggerClientEvent('matrix:client:injectBot', -1, botId, bot.role, origin, bot.dna_id, pedNetId)


    Matrix.Log('CORE',
        'Multi-Waypoint rota başlatıldı: Bot #%d [%s] %d ara nokta + final hedef.',
        botId, vehicleType, #waypointRefs)


    return true
end


--- ★ KATMAN 5 ULTIMATE [U1]: Bot Trap House'a (fiziksel sevk/rota hedefi)
--- vardığında sırtındaki tüm kargoyu (dealer_<id> ox_inventory envanteri)
--- o Trap House'un kendi deposuna (matrix_trap_stash_<id>) otomatik olarak
--- aktarır. Saf/pcall-korumalı best-effort transfer — ox_inventory API'si
--- (GetInventory/RegisterStash/AddItem/RemoveItem) kullanılabilir değilse
--- veya bir item aktarılamazsa sessizce atlanır (bot kargosu elinde kalır,
--- script çökmez); movedAny=false döner. Bu, F10 -> "/rotaciz" akışını
--- ekstra bir komut satırına gerek kalmadan tamamen kendi kendine yeten
--- hale getirir.
function Matrix.DepositDealerCargoToTrapStash(botId, trapHouseId)
    local inventoryId = ('dealer_%d'):format(botId)
    local stashId      = ('matrix_trap_stash_%d'):format(trapHouseId)


    local invOk, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], inventoryId)
    if not invOk or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return false end


    local house = Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]
    local stashLabel = (house and house.label and ('%s Deposu'):format(house.label))
        or ('Trap House #%d Deposu'):format(trapHouseId)


    pcall(function()
        exports['ox_inventory']:RegisterStash(stashId, stashLabel, 100, 200000)
    end)


    -- ★ CRITICAL DUPE FIX: sira KESINLIKLE ONCE-CIKAR SONRA-EKLE olmali.
    -- Eski sira (once AddItem, sonra pcall-ortulu RemoveItem) RemoveItem'in
    -- GERCEK basari degerini hic okumuyordu -- RemoveItem sessizce false
    -- donse bile esya dealer envanterinde KALIYOR ve stash'e de EKLENMIS
    -- oluyordu (sinirsiz dupe). Simdi: esya ONCE kaynaktan (katı guard ile)
    -- cikarilir; ancak bu KANITLANDIKTAN SONRA hedefe eklenir. AddItem
    -- basarisiz olursa, esya ATOMIK TELAFI ile bota (inventoryId) sessizce
    -- geri iade edilir -- ne dupe, ne kayip.
    local movedAny = false
    for slot, item in pairs(inv.items) do
        if type(item) == 'table' and type(item.name) == 'string' and (tonumber(item.count) or 0) > 0 then
            local itemName, itemCount, itemMeta = item.name, item.count, item.metadata

            local removeOk, removed = pcall(function()
                return exports['ox_inventory']:RemoveItem(inventoryId, itemName, itemCount, itemMeta, slot)
            end)

            if removeOk and removed == true then
                local addOk, added = pcall(function()
                    return exports['ox_inventory']:AddItem(stashId, itemName, itemCount, itemMeta)
                end)

                if addOk and added == true then
                    movedAny = true
                else
                    -- ★ ATOMIK TELAFI: AddItem basarisiz oldu (stash dolu/
                    -- reddedildi vb.) -- esya zaten kaynaktan cikarilmisti,
                    -- bu yuzden sessizce bot envanterine (inventoryId) geri
                    -- verilir. Bu adim da basarisiz olursa kayip en azindan
                    -- Matrix.Log ile IZLENEBILIR kalir (sahte bir "tasindi"
                    -- iddiasi asla URETILMEZ).
                    local restoreOk, restored = pcall(function()
                        return exports['ox_inventory']:AddItem(inventoryId, itemName, itemCount, itemMeta)
                    end)
                    if not (restoreOk and restored == true) then
                        Matrix.Log('CORE',
                            '[KRITIK] DepositDealerCargoToTrapStash: Bot #%d, esya (%s x%s) AddItem+telafi ikisi de basarisiz -- olasi kayip.',
                            botId, tostring(itemName), tostring(itemCount))
                    end
                end
            end
        end
    end


    if movedAny then
        Matrix.Log('CORE',
            '[OTOMATIK TESLIMAT] Bot #%d yuku Trap House #%d deposuna (%s) aktarildi, kutle hafifledi.',
            botId, trapHouseId, stashId)
    end
    return movedAny
end


--- ★ [H9][H12] Aktif bir fiziksel sevki (tekli veya rotalı) sonlandırır ve
--- dünyadan çeker. Entity NetID'leri, Dispatches[botId] nil'lenmeden ÖNCE
--- yakalanır; böylece bot kaydı silinmiş olsa dahi ped/araç orphan KALMAZ.
--- Co-Op Mutex burada serbest bırakılır (is_locked = false).
function Matrix.CompleteDispatch(botId, reason)
    local dispatch = Matrix.Dispatches[botId]
    if not dispatch then return false end


    -- ★ [H9] Snapshot al — sonrasında Dispatches[botId]'yi nil'lesek bile
    -- bu referanslar elimizde kalır.
    local pedNetId     = dispatch.entity_net_id
    local vehicleNetId = dispatch.vehicle_net_id
    local plate        = dispatch.plate
    local destination  = dispatch.destination
    local lastCoords   = dispatch.last_coords
    -- ★ KATMAN 7 [T2]: Mühimmat Dağıtım Görevi hedefi (bkz.
    -- server/logistics.lua Matrix.Logistics.DispatchAmmoRun) — doluysa bu
    -- sevk, trap house stash'ine değil bir "Tetikçi" bota elden teslimat
    -- yapıyordu.
    local ammoRunTargetBotId = dispatch.ammo_run_target_bot_id


    Matrix.Dispatches[botId] = nil


    local bot = Matrix.Bots[botId]
    if bot then
        if reason == 'arrived' then
            bot.state.activity = 'idle'
            bot.state.coords   = destination


            local drop = FindActiveDeadDropAt(destination)
            if drop and Matrix.Supplier and Matrix.Supplier.OnPickup then
                pcall(Matrix.Supplier.OnPickup, { kind = 'bot', id = botId }, drop.id, nil)
            end


            -- ★ KATMAN 7 [T2]: Mühimmat Dağıtım Görevi'nin son bacağı —
            -- Lojistik bot, sokakta bekleyen Tetikçi botun (ammoRunTargetBotId)
            -- konumuna vardı. Elden teslimat + geri dönüş server/logistics.lua
            -- Matrix.Logistics.OnAmmoRunArrived içinde ele alınır (best-effort,
            -- pcall-korumalı — bu hook yoksa/başarısız olursa normal 'arrived'
            -- akışı [trap house stash kontrolü dahil] AYNEN devam eder).
            if ammoRunTargetBotId and Matrix.Logistics and Matrix.Logistics.OnAmmoRunArrived then
                local ammoOk, ammoErr = pcall(Matrix.Logistics.OnAmmoRunArrived, botId, ammoRunTargetBotId, destination)
                if not ammoOk then
                    Matrix.Log('CORE', '[HATA] OnAmmoRunArrived basarisiz (yutuldu): %s', tostring(ammoErr))
                end
            end


            -- ★ KATMAN 5 ULTIMATE [U1]: Trap House'a varista otomatik stash
            -- teslimati. Dead drop toplama (yukarida) ile ayni "arrived"
            -- dalinda calisir ama BAGIMSIZ bir hedef turudur (biri
            -- toptancidan ALMA, digeri trap house'a BIRAKMA); ikisi farkli
            -- koordinat kumeleri uzerinde calistigi icin cakismaz.
            local nearestTrapId, nearestTrapDist = FindNearestTrapHouse(destination)
            if nearestTrapId and nearestTrapDist <= Config.Logistics.TrapHouseArrivalStashRadius then
                local depOk, depErr = pcall(Matrix.DepositDealerCargoToTrapStash, botId, nearestTrapId)
                if not depOk then
                    Matrix.Log('CORE', '[HATA] DepositDealerCargoToTrapStash basarisiz (yutuldu): %s', tostring(depErr))
                end

                -- ★ KATMAN 7 FAZ 2: sokak satışından biriken "riskli" kirli
                -- nakit, bot eve (trap house'a) sağ salim döndüğü AN ortak
                -- kasaya kilitlenir (bkz. server/market.lua Matrix.Market.
                -- FlushBotStreetCash — MEVCUT Matrix.CashDecay.Deposit'e
                -- yazar, yeni bir ekonomi hattı İCAT EDİLMEZ). Modül yüklü
                -- değilse davranış BİREBİR ESKİSİYLE AYNIDIR.
                if Matrix.Market and Matrix.Market.FlushBotStreetCash then
                    local ok, err = pcall(Matrix.Market.FlushBotStreetCash, botId, nearestTrapId)
                    if not ok then
                        Matrix.Log('CORE', '[HATA] FlushBotStreetCash basarisiz (yutuldu): %s', tostring(err))
                    end
                end
            end
        elseif reason == 'busted' then
            local nearestId = FindNearestTrapHouse(lastCoords or destination)
            if nearestId then
                if Matrix.Kitchen and Matrix.Kitchen.OnCaptured then
                    pcall(Matrix.Kitchen.OnCaptured, botId, nearestId)
                end
            end

            -- ★ KATMAN 7 FAZ 2: Real-Time Üst Arama kontrabant zinciri —
            -- bu bacak DISPATCH_BUSTED_* dwell mekaniğinin (main.lua'da
            -- ZATEN VAR OLAN, DEĞİŞTİRİLMEYEN kısım) doğal SONUCUDUR;
            -- yalnızca yakalanma ANINDAKI envanter muayenesi/el koyma
            -- burada eklenir (bkz. server/forensics.lua Matrix.Forensics.
            -- InspectBustedBot). Bot RemoveBot/OnDealerEliminated ile
            -- silinmeden ÖNCE çağrılır ki dealer_<id> envanteri hâlâ
            -- okunabilir olsun.
            if Matrix.Forensics and Matrix.Forensics.InspectBustedBot then
                local ok, err = pcall(Matrix.Forensics.InspectBustedBot, botId, nearestId, plate)
                if not ok then
                    Matrix.Log('CORE', '[HATA] InspectBustedBot basarisiz (yutuldu): %s', tostring(err))
                end
            end

            -- ★ KATMAN 7 FAZ 2: yakalanan bir bot elinde tuttuğu "riskli"
            -- sokak nakdini (henüz eve dönüp kasaya kilitlenmemiş) kaybeder.
            if Matrix.Market and Matrix.Market.SeizeBotStreetCash then
                pcall(Matrix.Market.SeizeBotStreetCash, botId)
            end

            if Matrix.Logistics and Matrix.Logistics.OnDealerEliminated then
                pcall(Matrix.Logistics.OnDealerEliminated, botId, 'police_busted')
            end
        end
    end


    if plate and Matrix.Logistics and Matrix.Logistics.ReleaseVehicleLock then
        pcall(Matrix.Logistics.ReleaseVehicleLock, plate)
    end


    -- ★ [H9] Entity'leri yakalanan NetID'ler üzerinden imha et.
    if pedNetId then
        local ped = NetworkGetEntityFromNetworkId(pedNetId)
        if ped and ped ~= 0 and DoesEntityExist(ped) then SafeDeleteEntity(ped) end
    end
    if vehicleNetId then
        local veh = NetworkGetEntityFromNetworkId(vehicleNetId)
        if veh and veh ~= 0 and DoesEntityExist(veh) then SafeDeleteEntity(veh) end
    end


    if bot then
        bot.state.spawned   = false
        bot.state.net_id    = nil
        -- ★ [H12] Co-Op Mutex serbest bırakılır — bota yeniden sevk emri verilebilir.
        bot.state.is_locked = false
    end


    TriggerClientEvent('matrix:client:extractBot', -1, botId)
    Matrix.Log('CORE', '[SEVK SONLANDI] Bot #%d Sebep:%s', botId, tostring(reason or 'unknown'))
    return true
end


-- =====================================================================
-- ★ KATMAN 5 ULTIMATE [U8]: ACİL TAHLİYE (PANİK) MOTORU
--
-- Aktif bir dispatch'in (rotalı veya tekli fark etmez) Co-Op Mutex'ini
-- KIRAR, o dispatch'in ESKİ rota zincirini terk eder ve AYNI ped/araç
-- entity'sini (yeniden doğurmadan — ışınlanma YOK, SpawnDispatchActors/
-- DespawnBot hiç çağrılmaz) tetikleyen oyuncunun (dispatcherSrc) o anki
-- canlı konumuna doğru "son hız" yeni bir göreve yönlendirir.
--
-- Mutex "kırılması" GEÇİCİDİR: is_locked önce false'a çekilir (istenen
-- davranış budur), hemen ardından AYNI dispatch kaydı panik moduna
-- güncellenip yeniden true'ya çekilir — böylece bota ikinci bir çakışan
-- sevk emri (o panik koşusu sürerken) verilemez, ama eski rota zinciri
-- tamamen terk edilmiş olur. TickPhysicalDispatches bu güncellenmiş
-- dispatch'i AYNI tick döngüsünde (yeni thread/Wait YOK) izlemeye devam
-- eder; PANIC_REISSUE_TICKS periyodunda hedef oyuncunun canlı konumuna
-- yeniden senkronize edilir (bkz. yukarıdaki reissue bloğu). Bot hedefe
-- ulaştığında mevcut CompleteDispatch('arrived') akışı AYNEN çalışır —
-- ped/araç dünyadan silinir, bot RAM'de STABİL/BEKLEMEDE'ye döner
-- (aynı "sahadan çekildi" semantiği, ekstra bir kod yolu icat edilmedi).
-- =====================================================================
function Matrix.TriggerPanicEvacuation(botId, dispatcherSrc)
    botId = tonumber(botId)
    if not botId then return false, 'bad_bot_id' end


    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end


    local dispatch = Matrix.Dispatches[botId]
    if not dispatch then return false, 'not_dispatched' end


    if type(dispatcherSrc) ~= 'number' or dispatcherSrc <= 0 then return false, 'bad_dispatcher' end
    local dispatcherPed = GetPlayerPed(dispatcherSrc)
    if not dispatcherPed or dispatcherPed == 0 then return false, 'dispatcher_ped_missing' end


    -- ★ KATMAN 7 [T3]: yolda seyir halindeki (aktif dispatch) bir bota
    -- telsizden müdahale etmek (rota yeniden atamak), dispatcher su an
    -- /sessizlik altındaysa BİLİNÇLİ bir sessizlik ihlalidir. ENGELLENMEZ
    -- (acil tahliye kritik olabilir) ama bedelsiz de değildir: server/
    -- market.lua Matrix.RadioSilence.BreakForRedirect telsiz statik
    -- parazit şiddetini VE Büro'nun ilgili trap house decryption_confidence
    -- katsayısını ÜSSEL olarak sıçratır (bkz. o fonksiyonun yorumu).
    do
        local dState = Matrix.GetOrCreatePlayerState(dispatcherSrc)
        if dState and dState.citizenid and Matrix.RadioSilence
            and Matrix.RadioSilence.IsActive and Matrix.RadioSilence.IsActive(dState.citizenid)
            and Matrix.RadioSilence.BreakForRedirect then
            pcall(Matrix.RadioSilence.BreakForRedirect, dState.citizenid, botId, bot.state.trap_house_id)
        end
    end


    local ped = NetworkGetEntityFromNetworkId(dispatch.entity_net_id)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return false, 'entity_missing' end


    local veh = nil
    if dispatch.vehicle_net_id then
        veh = NetworkGetEntityFromNetworkId(dispatch.vehicle_net_id)
        if not veh or veh == 0 or not DoesEntityExist(veh) then
            return false, 'vehicle_missing'
        end
    end


    local dRaw = GetEntityCoords(dispatcherPed)
    local targetCoords = vector3(dRaw.x, dRaw.y, dRaw.z)
    if not _SafeVec(targetCoords) then return false, 'bad_dispatcher_coords' end


    -- ★ Tüm ön-koşullar doğrulandı — ŞİMDİ görev atamasını dene. Mutex
    -- kırma dahil TÜM state mutasyonları YALNIZCA görev başarıyla
    -- atanırsa uygulanır; böylece başarısız bir native çağrısı dispatch'i
    -- tutarsız bir ara durumda (mutex kırılmış ama hiçbir yeni görev
    -- verilmemiş) BIRAKMAZ.
    local speed = veh and PANIC_EVAC_VEHICLE_SPEED_MS or PANIC_EVAC_FOOT_SPEED_MS
    local taskOk
    if veh then
        taskOk = pcall(TaskVehicleDriveToCoord,
            ped, veh,
            targetCoords.x, targetCoords.y, targetCoords.z,
            speed, 0, 0, 16777216, 5.0, 1
        )
    else
        taskOk = pcall(TaskFollowNavMeshToCoord,
            ped,
            targetCoords.x, targetCoords.y, targetCoords.z,
            speed, NAVMESH_TASK_TIMEOUT, NAVMESH_STOPPING_RANGE_M,
            NAVMESH_PERSIST_FOLLOWING, 0.0
        )
    end
    if not taskOk then return false, 'task_assignment_failed' end


    -- ★ Görev başarıyla atandı — mutex KIRILIR (istenen davranış), eski
    -- rota zinciri terk edilir, dispatch panik moduna alınır, ardından
    -- mutex YENİDEN kurulur (panik koşusu da bir dispatch'tir, bitene
    -- kadar bota ikinci bir çakışan emir verilemez).
    bot.state.is_locked = false


    dispatch.route_queue          = nil
    dispatch.route_index          = nil
    dispatch.destination          = targetCoords
    dispatch.panic_evacuation     = true
    dispatch.panic_dispatcher_src = dispatcherSrc
    dispatch.task_retry_ticks     = 0
    dispatch.police_dwell         = 0
    dispatch.comms_lost           = false
    dispatch.cruise_speed         = speed


    bot.state.is_locked = true
    bot.state.activity   = 'panic_evacuation'


    Matrix.Log('CORE',
        '[ACIL TAHLIYE] Bot #%d gorevi terk etti; dispatcher src=%d konumuna (%.1f,%.1f,%.1f) dogru son hizla yola cikti.',
        botId, dispatcherSrc, targetCoords.x, targetCoords.y, targetCoords.z)


    return true
end


--- Dispatch entity'sini dünyadan siler. Opsiyonel `dispatch` argümanı
--- verilmezse Dispatches[botId] aranır (geriye dönük uyumlu). Co-Op Mutex
--- burada da güvenlik ağı olarak serbest bırakılır.
function Matrix.DespawnDispatchEntity(botId, dispatch)
    dispatch = dispatch or Matrix.Dispatches[botId]
    local bot = Matrix.Bots[botId]


    local pedNetId = dispatch and dispatch.entity_net_id or (bot and bot.state.net_id)


    if pedNetId then
        local ped = NetworkGetEntityFromNetworkId(pedNetId)
        if ped and ped ~= 0 and DoesEntityExist(ped) then SafeDeleteEntity(ped) end
    end


    if dispatch and dispatch.vehicle_net_id then
        local veh = NetworkGetEntityFromNetworkId(dispatch.vehicle_net_id)
        if veh and veh ~= 0 and DoesEntityExist(veh) then SafeDeleteEntity(veh) end
    end


    if bot then
        bot.state.spawned   = false
        bot.state.net_id    = nil
        bot.state.is_locked = false
    end


    TriggerClientEvent('matrix:client:extractBot', -1, botId)
end


local function FlushPendingEvents(dispatch)
    if #dispatch.pending_events == 0 then return end
    Matrix.Log('CORE', '[GECİKMELİ VERİ AKIŞI] Bot #%d için %d olay toplu iletiliyor.',
        dispatch.bot_id, #dispatch.pending_events)
    for _, msg in ipairs(dispatch.pending_events) do
        Matrix.Log('CORE', '  -> %s', msg)
    end
    dispatch.pending_events = {}
end


local function QueueOrEmit(dispatch, message)
    if dispatch.comms_lost then
        local events = dispatch.pending_events
        if #events >= PENDING_EVENTS_MAX then
            table.remove(events, 1)
        end
        events[#events + 1] = message
    else
        Matrix.Log('CORE', message)
    end
end


--- ★ [H11] Bot bir ara uğrağa (route_queue[route_index]) vardığında,
--- DURAKSAMADAN bir sonraki uğrağa yeniden görevlendirilir. Dispatch
--- 'arrived' olarak KAPANMAZ — zincir devam eder.
local function AdvanceRouteWaypoint(ped, dispatch, botId)
    dispatch.route_index      = dispatch.route_index + 1
    dispatch.destination      = dispatch.route_queue[dispatch.route_index]
    dispatch.task_retry_ticks = 0


    local reissueSpeed = dispatch.cruise_speed or DISPATCH_BASE_VEHICLE_SPEED_MS
    if dispatch.vehicle_net_id then
        local veh = NetworkGetEntityFromNetworkId(dispatch.vehicle_net_id)
        if veh and veh ~= 0 and DoesEntityExist(veh) then
            pcall(TaskVehicleDriveToCoord,
                ped, veh,
                dispatch.destination.x, dispatch.destination.y, dispatch.destination.z,
                reissueSpeed, 0, 0, 16777216, 5.0, 1
            )
        end
    else
        -- ★ [U7] NavMesh tabanli asenkron yuruyus (bkz. dosya basi notu).
        pcall(TaskFollowNavMeshToCoord,
            ped,
            dispatch.destination.x, dispatch.destination.y, dispatch.destination.z,
            reissueSpeed, NAVMESH_TASK_TIMEOUT, NAVMESH_STOPPING_RANGE_M,
            NAVMESH_PERSIST_FOLLOWING, 0.0
        )
    end


    QueueOrEmit(dispatch, ('[ROTA ZİNCİRİ] Bot #%d %d/%d. uğrağa ulaştı — %d. noktaya anında yönlendirildi.'):format(
        botId, dispatch.route_index - 1, #dispatch.route_queue, dispatch.route_index))
end


function Matrix.TickPhysicalDispatches()
    local toComplete = {}


    for botId, dispatch in pairs(Matrix.Dispatches) do
        local bot = Matrix.Bots[botId]
        if not bot then
            toComplete[botId] = 'failed'
        else
            dispatch.elapsed = dispatch.elapsed + 1.0
            dispatch.task_retry_ticks = dispatch.task_retry_ticks + 1


            local ped = NetworkGetEntityFromNetworkId(dispatch.entity_net_id)
            if not ped or ped == 0 or not DoesEntityExist(ped) then
                Matrix.Log('CORE', '[SEVK KAYIP] Bot #%d fiziksel varlık bulunamadı, iptal.', botId)
                toComplete[botId] = 'failed'
            else
                local coordsRaw = GetEntityCoords(ped)
                local coords    = vector3(coordsRaw.x, coordsRaw.y, coordsRaw.z)
                dispatch.last_coords = coords
                bot.state.coords     = coords


                local distToDest = #(coords - dispatch.destination)
                if distToDest <= DISPATCH_ARRIVAL_RADIUS_M then
                    -- ★ [H11] Rota zinciri: son halkaya varana kadar HİÇ
                    -- duraksamadan bir sonraki uğrağa geç.
                    if dispatch.route_queue and dispatch.route_index < #dispatch.route_queue then
                        AdvanceRouteWaypoint(ped, dispatch, botId)
                    else
                        toComplete[botId] = 'arrived'
                    end
                else
                    local zone = FindDeadZone(coords)
                    if zone and not dispatch.comms_lost then
                        dispatch.comms_lost = true
                        Matrix.Log('CORE', '[BAĞLANTI KESİLDİ] Bot #%d (%s) kör bölgede: %s',
                            botId, bot.name, zone.label)
                        if type(dispatch.dispatcher_src) == 'number' and dispatch.dispatcher_src > 0 then
                            Matrix.Radio.ApplyStatic(dispatch.dispatcher_src, 1.0, 'dead_zone')
                        end
                    elseif (not zone) and dispatch.comms_lost then
                        dispatch.comms_lost = false
                        Matrix.Log('CORE', '[SİNYAL YENİDEN ALINDI] Bot #%d kör bölgeden çıktı.', botId)
                        SetTimeout(Config.Logistics.DeadZoneLogFlushDelayMs, function()
                            if Matrix.Dispatches[botId] == dispatch then
                                FlushPendingEvents(dispatch)
                            end
                        end)
                    end


                    local policeNearby = false
                    local veryClose    = false
                    for src in pairs(PoliceSources) do
                        local policePed = GetPlayerPed(src)
                        if policePed and policePed ~= 0 then
                            local pd = GetEntityCoords(policePed)
                            local d  = #(vector3(pd.x, pd.y, pd.z) - coords)
                            if d <= DISPATCH_POLICE_PROXIMITY_M then
                                policeNearby = true
                                if d <= DISPATCH_BUSTED_PROXIMITY_M then
                                    veryClose = true
                                end
                            end
                        end
                    end


                    if policeNearby then
                        local nearestId, nearestDist = FindNearestTrapHouse(coords)
                        if nearestId and nearestDist <= Config.Bureau.BaseSearchRadius then
                            Matrix.Bureau.AdvanceDecryption(
                                nearestId,
                                DISPATCH_POLICE_DECRYPT_TICK * (dispatch.profile.PoliceDecryptionMultiplier or 1.0)
                            )
                        end
                    end


                    if veryClose then
                        dispatch.police_dwell = dispatch.police_dwell + 1
                    else
                        dispatch.police_dwell = math_max(0, dispatch.police_dwell - 1)
                    end


                    if dispatch.police_dwell >= DISPATCH_BUSTED_DWELL_TICKS then
                        Matrix.Log('CORE', '[PUSU] Bot #%d polis tarafından kuşatıldı.', botId)
                        toComplete[botId] = 'busted'
                    else
                        if dispatch.plate then
                            for trapId, trapHouse in pairs(Matrix.TrapHouses or {}) do
                                if not dispatch.alpr_logged_traps[trapId] then
                                    if #(coords - trapHouse.coords) <= DISPATCH_ALPR_RADIUS_M then
                                        dispatch.alpr_logged_traps[trapId] = true
                                        local veh = Matrix.Fleet and Matrix.Fleet.GetVehicle and Matrix.Fleet.GetVehicle(dispatch.plate)
                                        if veh then
                                            pcall(Matrix.Fleet.RecordAlprHit, dispatch.plate, bot.dna_id,
                                                veh.registered_by_citizenid, trapId)


                                            local vinMult = Config.Logistics.Fleet.VinDecryptionMultiplier[veh.vin_status] or 1.0
                                            Matrix.Bureau.AdvanceDecryption(
                                                trapId,
                                                DISPATCH_POLICE_DECRYPT_TICK
                                                    * (dispatch.profile.PoliceDecryptionMultiplier or 1.0)
                                                    * vinMult
                                            )
                                            QueueOrEmit(dispatch, ('[ALPR EŞLEŞMESİ] Plaka %s -> DNA %s -> Trap #%d'):format(
                                                dispatch.plate, bot.dna_id, trapId))
                                        end
                                    end
                                end
                            end
                        end


                        -- ★ [U8] Panik tahliye modunda daha kısa (PANIC_REISSUE_TICKS)
                        -- bir yenileme eşiği kullanılır — bot, tetikleyen oyuncuyu
                        -- normal sevkiyattan daha sık "kovalar".
                        local reissueThreshold = dispatch.panic_evacuation
                            and PANIC_REISSUE_TICKS or DISPATCH_TASK_REISSUE_TICKS


                        if dispatch.task_retry_ticks >= reissueThreshold then
                            dispatch.task_retry_ticks = 0


                            -- ★ [U8] Panik modunda hedef, HER yenileme turunda
                            -- tetikleyen oyuncunun O ANKİ canlı konumuna güncellenir
                            -- (oyuncu hareket etse bile bot peşinden gelir). Oyuncu
                            -- artık çözülemiyorsa (çevrimdışı/ped yok) son bilinen
                            -- hedef korunur — görev sessizce iptal OLMAZ.
                            if dispatch.panic_evacuation and dispatch.panic_dispatcher_src then
                                local dispatcherPed = GetPlayerPed(dispatch.panic_dispatcher_src)
                                if dispatcherPed and dispatcherPed ~= 0 then
                                    local dRaw = GetEntityCoords(dispatcherPed)
                                    local liveTarget = vector3(dRaw.x, dRaw.y, dRaw.z)
                                    if _SafeVec(liveTarget) then
                                        dispatch.destination = liveTarget
                                    end
                                end
                            end


                            local reissueSpeed = dispatch.cruise_speed or DISPATCH_BASE_VEHICLE_SPEED_MS
                            if dispatch.vehicle_net_id then
                                local veh = NetworkGetEntityFromNetworkId(dispatch.vehicle_net_id)
                                if veh and veh ~= 0 and DoesEntityExist(veh) then
                                    pcall(TaskVehicleDriveToCoord,
                                        ped, veh,
                                        dispatch.destination.x, dispatch.destination.y, dispatch.destination.z,
                                        reissueSpeed, 0, 0, 16777216, 5.0, 1
                                    )
                                end
                            else
                                -- ★ [U7] NavMesh tabanli asenkron yuruyus (bkz. dosya basi notu).
                                pcall(TaskFollowNavMeshToCoord,
                                    ped,
                                    dispatch.destination.x, dispatch.destination.y, dispatch.destination.z,
                                    reissueSpeed, NAVMESH_TASK_TIMEOUT, NAVMESH_STOPPING_RANGE_M,
                                    NAVMESH_PERSIST_FOLLOWING, 0.0
                                )
                            end
                        end


                        QueueOrEmit(dispatch, ('Bot #%d konum güncellendi: (%.1f, %.1f, %.1f) | Kalan mesafe:%.1fm'):format(
                            botId, coords.x, coords.y, coords.z, distToDest))
                    end
                end
            end
        end
    end


    -- ★ [H10] Faz 2: pcall başarısız olsa bile Dispatches[botId] ZORLA nil'lenir.
    for botId, reason in pairs(toComplete) do
        local ok, err = pcall(Matrix.CompleteDispatch, botId, reason)
        if not ok then
            Matrix.Log('CORE', '[HATA] CompleteDispatch (%s) basarisiz: %s', tostring(botId), tostring(err))
        end
        -- Güvenlik ağı: CompleteDispatch herhangi bir nedenle erken dönmüş/
        -- hata vermişse dispatches kaydı burada zorla düşürülür (RAM sızıntısı yok).
        if Matrix.Dispatches[botId] then
            Matrix.Dispatches[botId] = nil
        end
    end
end


-- =====================================================================
-- ★ [E5] DÜZELTME: server/market.lua ZATEN kendi Matrix.Hud köprüsünü
-- (Matrix.Hud.BuildSnapshot/PushSnapshots, HudViewers, 'matrix:server:
-- hudToggled') ve kendi hiyerarşi sistemini (Matrix.Hierarchy.GetRank/
-- SetRank/HasCommandAuthority, matrix_hierarchy DB tablosu) barındırıyor
-- — market.lua bu proje ile paylaşılana kadar bundan haberimiz yoktu.
-- Buradaki eski [H13] F6-HUD köprüsü DUPLICATE idi: `function Matrix.Hud.
-- PushSnapshots()` iki dosyada da tanımlıydı ve hangisinin son yüklenip
-- diğerini SESSİZCE EZDİĞİ fxmanifest server_scripts sırasına bağlıydı —
-- KALDIRILDI. market.lua'nın sürümü tek/otoriter kaynak olarak kalıyor;
-- master ticker'daki `Matrix.Hud.PushSnapshots()` çağrısı (aşağıda,
-- değişmedi) artık kesin olarak ona gidiyor. Aynı sebeple main.lua'daki
-- ayrı /rutbeata komutu ve Matrix.PlayerRanks tablosu da KALDIRILDI
-- (market.lua'nın DB'ye yazan, retry'li /rutbeata + Matrix.Hierarchy
-- sistemiyle çakışıyordu) — bkz. KOMUTLAR bölümündeki not.
-- =====================================================================


-- =====================================================================
-- ★ [E4] KATMAN 5 EK EMİR: CANLI KADRO & HİYERARŞİ RAPORU
-- F10 menüsünün en tepesindeki "Canlı Kadro & Hiyerarşi Raporu" alt
-- menüsü açıldığı AN bu callback'i çağırır (client: lib.callback.await,
-- bkz. client/hud.lua OpenCanliKadroRaporu). HER tıklamada TAZE bir
-- istek atar — client tarafında statik/cache YOKTUR. Sürekli bir
-- polling/thread da YOKTUR — yalnızca istek anında hesaplanan SAF bir
-- istek/cevap (callback) yapısı; 0 Resmon bütçesi korunur.
--
-- ★ [E5] HATA DÜZELTMESİ: rütbe/yetki artık market.lua'nın OTORİTER
-- kaynağı olan Matrix.Hierarchy.GetRank(citizenid)'den okunur. Önceki
-- sürüm hiçbir yerde YAZILMAYAN kendi Matrix.PlayerRanks tablosunu
-- okuyordu (bu yüzden /rutbeata sonrası rapor hep 'Rutbesiz' kalıyordu) —
-- sorun hiçbir zaman istemcinin eski veri okuması değildi (o zaten her
-- açılışta taze istiyordu), sunucunun YANLIŞ tabloyu okumasıydı.
--
-- ★ KATMAN 5 ULTIMATE [U3]: Callback artık düz string dizisi DEĞİL,
-- `{ kind='bot'|'player', id=, role=, mole_flagged=, text= }` yapılı bir
-- dizi döner. Bu, client/hud.lua'nın bot satırlarını TIKLANABİLİR
-- (Operatif Tasfiye Et / Denetleyici Olarak Ata) yapabilmesi ve
-- server/market.lua'nın SIGINT köstebek tarama sonucunu (Matrix.Inspector.
-- IsMoleFlagged) rapora [SIGINT ANOMALİSİ: KÖSTEBEK / MUHBİR DOĞRULANDI!]
-- bülteni olarak ekleyebilmesi için gereklidir.
-- =====================================================================
local ROSTER_REPORT_MAX_LINES = 100 -- RAM-bomb / menü-taşması savunması


local ROSTER_AUTHORITY_LABELS = {
    Leader            = 'MUTLAK',
    Logistics_Officer = 'YETKILI',
    Chemist           = 'KISITLI'
}


lib.callback.register('matrix:callback:getRosterReport', function(src)
    local entries = {}


    for id, bot in pairs(Matrix.Bots) do
        if #entries >= ROSTER_REPORT_MAX_LINES then break end
        if bot.status == 'active' then
            local durum = bot.state.is_locked and 'MESGUL / INTIKALDE' or 'STABIL / BEKLEMEDE'
            local roleLabel = (bot.role == 'Inspector') and 'BOLGE DENETLEYICISI' or 'STREET DEALER'
            local moleFlagged = (Matrix.Inspector and Matrix.Inspector.IsMoleFlagged and Matrix.Inspector.IsMoleFlagged(id)) or false


            local text = ('[BOT-ID: %d] - %s | Rol: %s | Durum: %s'):format(id, bot.name, roleLabel, durum)
            if moleFlagged then
                text = text .. ' | [SIGINT ANOMALISI: KOSTEBEK / MUHBIR DOGRULANDI!]'
            end


            entries[#entries + 1] = {
                kind         = 'bot',
                id           = id,
                role         = bot.role,
                mole_flagged = moleFlagged,
                text         = text
            }
        end
    end


    local ok, players = pcall(function() return Matrix.QBX:GetQBPlayers() end)
    if ok and type(players) == 'table' then
        for playerSrc, player in pairs(players) do
            if #entries >= ROSTER_REPORT_MAX_LINES then break end
            if player and player.PlayerData then
                local citizenid = player.PlayerData.citizenid
                local rank      = citizenid and Matrix.Hierarchy.GetRank(citizenid)
                local rankDef   = rank and Config.Hierarchy.Ranks[rank]
                local rankLabel = rankDef and rankDef.label or 'Rutbesiz'
                local yetki     = (rank and ROSTER_AUTHORITY_LABELS[rank]) or 'KISITLI'


                local charinfo = player.PlayerData.charinfo
                local name = (charinfo and charinfo.firstname and charinfo.lastname)
                    and ('%s %s'):format(charinfo.firstname, charinfo.lastname)
                    or ('Oyuncu-%d'):format(playerSrc)


                -- ★ HATA DÜZELTMESİ: 'PLR-ID' öneki botların 'BOT-ID'
                -- indeksiyle KESİNLİKLE çakışmaz — aynı sayısal değer
                -- (örn. Bot #1 ile Server ID 1) artık görsel olarak
                -- ayrıştırılmış iki farklı ad alanında listelenir.
                entries[#entries + 1] = {
                    kind = 'player',
                    id   = playerSrc,
                    text = ('[PLR-ID: %d] - %s | Rutbe: %s | Yetki: %s'):format(playerSrc, name, rankLabel, yetki)
                }
            end
        end
    end


    return entries
end)


-- =====================================================================
-- MASTER TICKER
-- =====================================================================
local bureauAccumulator = 0


CreateThread(function()
    LoadBotsFromDatabase()


    local interval       = Config.Tick.IntervalMs
    local secPerMin      = Config.Tick.SecondsPerMinute
    local secPerHour     = Config.Tick.SecondsPerHour
    local bureauInterval = Config.Bureau.AnalysisIntervalSeconds


    while true do
        Wait(interval)
        bureauAccumulator = bureauAccumulator + 1


        for _, bot in pairs(Matrix.Bots) do
            if bot.status == 'active' then
                local s = bot.state.elapsed_seconds + 1
                bot.state.elapsed_seconds = s


                if s % secPerMin == 0 then
                    local ok, err = pcall(Matrix.Kitchen.ProcessMinuteCycle, bot)
                    if not ok then Matrix.Log('CORE', '[HATA] ProcessMinuteCycle (Bot #%d) basarisiz: %s', bot.id, tostring(err)) end
                end
                if s % secPerHour == 0 then
                    local ok, err = pcall(Matrix.Kitchen.ProcessHourCycle, bot)
                    if not ok then Matrix.Log('CORE', '[HATA] ProcessHourCycle (Bot #%d) basarisiz: %s', bot.id, tostring(err)) end
                end
            end
        end


        for src, citizenid in pairs(Matrix.PlayerSourceIndex) do
            local state = Matrix.PlayerState[citizenid]
            if state and state.biology then
                Matrix.DecayPlayerCortisol(state)
                if state.biology.cortisol_level > Config.Kitchen.CortisolDeviationThreshold then
                    Matrix.Radio.ApplyStatic(src, state.biology.cortisol_level, 'panic')
                end
            end
        end


        local ok3, err3 = pcall(Matrix.TickPhysicalDispatches)
        if not ok3 then Matrix.Log('CORE', '[HATA] TickPhysicalDispatches basarisiz (yutuldu): %s', tostring(err3)) end


        if bureauAccumulator >= bureauInterval then
            bureauAccumulator = 0
            local ok4, err4 = pcall(Matrix.Bureau.Tick)
            if not ok4 then Matrix.Log('CORE', '[HATA] Bureau.Tick basarisiz (yutuldu): %s', tostring(err4)) end
            CreateThread(function()
                local okS, errS = pcall(Matrix.Recruitment.ScanCustomerPool)
                if not okS then Matrix.Log('CORE', '[HATA] ScanCustomerPool basarisiz (yutuldu): %s', tostring(errS)) end
            end)
        end


        if Matrix.Hud and Matrix.Hud.PushSnapshots then
            local ok5, err5 = pcall(Matrix.Hud.PushSnapshots)
            if not ok5 then Matrix.Log('CORE', '[HATA] Hud.PushSnapshots basarisiz (yutuldu): %s', tostring(err5)) end
        end
    end
end)


CreateThread(function()
    while true do
        Wait(Matrix.Persistence.botFlushMs)
        Matrix.FlushDirtyBots()
    end
end)


-- =====================================================================
-- SHUTDOWN
-- =====================================================================
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end


    PersistAllBotsSync()


    for citizenid, state in pairs(Matrix.PlayerState) do
        pcall(function()
            MySQL.query.await([[
                INSERT INTO matrix_player_state (citizenid, cortisol_level, fatigue_level, updated_at)
                VALUES (?, ?, ?, NOW())
                ON DUPLICATE KEY UPDATE cortisol_level = VALUES(cortisol_level),
                    fatigue_level = VALUES(fatigue_level), updated_at = NOW()
            ]], { citizenid, state.biology.cortisol_level, state.biology.fatigue_level })
        end)
    end


    Matrix.Log('CORE', 'Tüm veri kalıcı depoya yazıldı. Kapanış tamamlandı.')
end)


-- =====================================================================
-- [H4] PLAYER DROP CLEANUP
-- =====================================================================
AddEventHandler('playerDropped', function()
    local src = source
    local citizenid = Matrix.PlayerSourceIndex[src]


    if citizenid then
        local state = Matrix.PlayerState[citizenid]
        if state then
            MySQL.prepare([[
                INSERT INTO matrix_player_state (citizenid, cortisol_level, fatigue_level, updated_at)
                VALUES (?, ?, ?, NOW())
                ON DUPLICATE KEY UPDATE cortisol_level = VALUES(cortisol_level),
                    fatigue_level = VALUES(fatigue_level), updated_at = NOW()
            ]], { citizenid, state.biology.cortisol_level, state.biology.fatigue_level })


            Matrix.PlayerState[citizenid] = nil
        end
    end
    Matrix.PlayerSourceIndex[src] = nil


    for _, dispatch in pairs(Matrix.Dispatches) do
        if dispatch.dispatcher_src == src then
            dispatch.dispatcher_src = nil
            dispatch.comms_lost = true
        end
    end
end)


-- =====================================================================
-- KOMUTLAR
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[MATRIX]', msg } })
    else
        print(('[MATRIX:CONSOLE] %s'):format(msg))
    end
end


--- ★ DÜZELTME: Reply() YALNIZCA chat:addMessage kullanıyordu — oyuncunun
--- chat penceresi kapalıysa (FiveM'de varsayılan davranış) bir rütbe
--- reddi/hata SESSİZCE kayboluyor, "tıkladım ama hiçbir şey olmuyor"
--- izlenimi veriyordu (bkz. F10 -> Canlı Kadro -> Operatif Tasfiye/Acil
--- Tahliye). Bu yardımcı AYNI mesajı hem chat'e (Reply, geriye dönük
--- uyum) hem de client/hud.lua'nın lib.notify ile EKRANDA gösterdiği
--- 'matrix:client:actionNotify' event'ine gönderir — chat açık olsun
--- olmasın sonuç HER ZAMAN görülür.
local function NotifyResult(src, ok, msg)
    Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('matrix:client:actionNotify', src, ok, msg)
    end
end


local function SafeForwardCoords(src, distance)
    if type(src) ~= 'number' or src <= 0 then return nil end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c  = GetEntityCoords(ped)
    local hd = GetEntityHeading(ped)
    local rad = math_rad(hd)
    return vector4(
        c.x - (math_sin(rad) * distance),
        c.y + (math_cos(rad) * distance),
        c.z,
        (hd + 180.0) % 360.0
    )
end


--- ★ HATA DÜZELTMESİ: Bir sevk/rota komutunun dispatch ORIGIN'i botun
--- KENDİ son bilinen konumu olmalıdır — komutu tetikleyen OYUNCUNUN
--- konumu DEĞİL. (Önceki /rotaciz sürümü SafeForwardCoords(src, ...) ile
--- oyuncunun önünü kullanıyordu; bu, dispatch her tetiklendiğinde botu
--- oyuncunun yanına "ışınlıyordu" — SpawnDispatchActors zaten var olan
--- ped'i despawn edip origin'de yeniden doğuruyor.)
---
--- server/logistics.lua'nın Matrix.Logistics.DispatchDealer fonksiyonu
--- (gerçek /sevket'in arkasındaki motor) AYNI sorunu ZATEN doğru şekilde
--- çözmüş — burası o kanıtlanmış öncelik zincirini BİREBİR izler
--- (tutarlılık için):
---   1) bot.state.coords — botun canlı/son bilinen gerçek konumu.
---   2) Botun kendi trap_house_id'sine bağlı trap house koordinatı.
---   3) Matristeki EN DÜŞÜK ID'li trap house (genel "ana üs" varsayılanı).
---   4) SON ÇARE: dispatcherSrc'nin konumu + 200m Y ofseti — botu
---      oyuncunun YANINA değil, oyuncudan gözle görülür şekilde uzakta
---      makul bir noktaya yerleştirir (ışınlanma hissi vermez).
--- Hiçbiri yoksa nil döner — çağıran taraf oyuncunun konumuna SESSİZCE
--- geri düşmez, açık bir hata ile reddeder.
local function ResolveBotOrigin(bot, dispatcherSrc)
    if not bot then return nil end
    if bot.state.coords then return bot.state.coords end


    local trapHouseId = bot.state.trap_house_id
    local house = trapHouseId and Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]
    if house and house.coords then return house.coords end


    if Matrix.TrapHouses then
        local lowestId = nil
        for id in pairs(Matrix.TrapHouses) do
            if not lowestId or id < lowestId then lowestId = id end
        end
        if lowestId and Matrix.TrapHouses[lowestId].coords then
            return Matrix.TrapHouses[lowestId].coords
        end
    end


    if type(dispatcherSrc) == 'number' and dispatcherSrc > 0 then
        local ped = GetPlayerPed(dispatcherSrc)
        if ped and ped ~= 0 then
            local c = GetEntityCoords(ped)
            return vector3(c.x, c.y + 200.0, c.z)
        end
    end


    return nil
end


RegisterCommand('coords', function(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then Reply(src, 'Ped bulunamadi.'); return end
    local c  = GetEntityCoords(ped)
    local hd = GetEntityHeading(ped)
    Reply(src, ('KOMUTLAR ICIN (boslukla): %.3f %.3f %.3f  |Heading:%.1f'):format(c.x, c.y, c.z, hd))
    Reply(src, ('CONFIG ICIN (virgullu):  vector3(%.3f, %.3f, %.3f)'):format(c.x, c.y, c.z))
end, false)


RegisterCommand('botyarat', function(src, args)
    local name = args[1]
    local role = args[2] or 'runner'
    if type(name) ~= 'string' or name == '' then
        Reply(src, 'Kullanim: /botyarat [isim] [rol]'); return
    end
    if not Config.RoleModels[role] and role ~= Config.DefaultRoleModel then
        role = 'runner'
    end


    local bot = Matrix.CreateBotRecord({ name = name, role = role })
    Reply(src, ('Bot #%d matrise yazıldı: %s (%s)'):format(bot.id, bot.name, bot.role))
end, false)


RegisterCommand('botspawn', function(src, args)
    local botId = tonumber(args[1])
    if not botId then Reply(src, 'Kullanim: /botspawn [id]'); return end
    local coords = SafeForwardCoords(src, 2.0)
    if not coords then Reply(src, 'Spawn için geçerli bir ped gerekli.'); return end
    local ok = Matrix.SpawnBot(botId, coords)
    Reply(src, ok and ('Bot #%d enjekte edildi.'):format(botId)
              or  ('Bot #%d enjekte edilemedi.'):format(botId))
end, false)


RegisterCommand('botdespawn', function(src, args)
    local botId = tonumber(args[1])
    if not botId then Reply(src, 'Kullanim: /botdespawn [id]'); return end
    local ok = Matrix.DespawnBot(botId)
    Reply(src, ok and ('Bot #%d hafıza matrisine geri çekildi.'):format(botId)
              or  ('Bot #%d geri çekilemedi.'):format(botId))
end, false)


-- =====================================================================
-- ★ KATMAN 5 ULTIMATE [U2]: /operatiftasfiye — CO-OP KADRO TASFİYESİ
-- F10 "Canlı Kadro & Hiyerarşi Raporu" menüsünde bir bota tıklanınca
-- açılan "Operatif Tasfiye Et (İlişiği Kes)" aksiyonunun arkasındaki
-- komut. Yeniden icat ETMEZ — server/logistics.lua'nın halihazırda hem
-- gerçek bir DB DELETE hem de pcall-korumalı RAM/entity Hard-Delete
-- yapan Matrix.Logistics.OnDealerEliminated'ini çağırır.
-- =====================================================================
RegisterCommand('operatiftasfiye', function(src, args)
    local botId = tonumber(args[1])
    if not botId then NotifyResult(src, false, 'Kullanim: /operatiftasfiye [botId]'); return end


    if Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority then
        local assignerState = Matrix.GetOrCreatePlayerState(src)
        if not assignerState or not assignerState.citizenid or not Matrix.Hierarchy.HasCommandAuthority(assignerState.citizenid) then
            NotifyResult(src, false, 'Bu emri vermek icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'); return
        end
    end


    if not Matrix.Bots[botId] then
        NotifyResult(src, false, ('Bot #%d matriste bulunamadi.'):format(botId)); return
    end


    local ok
    if Matrix.Logistics and Matrix.Logistics.OnDealerEliminated then
        ok = Matrix.Logistics.OnDealerEliminated(botId, 'command_purge')
    else
        ok = Matrix.RemoveBot(botId, 'command_purge')
    end


    if ok then
        NotifyResult(src, true, ('[TASFIYE TAMAMLANDI] Bot #%d matristen ve RAM onbellekten kalici olarak silindi (Hard-Delete).'):format(botId))
    else
        NotifyResult(src, false, ('Bot #%d tasfiye edilemedi.'):format(botId))
    end
end, false)


-- =====================================================================
-- ★ [OTONOM ALT HUCRE BOLUNMESI] /cetelideriata — bir botu, F10 "Denetleyici
-- Ata" (Matrix.Inspector.AssignInspector) ILE AYNI yetki/terfi desenini
-- kullanarak o trap house'un otonom cete lideri ('Leader') olarak isaretler.
-- Lider status='deceased' oldugunda (bkz. Matrix.RemoveBot yukarida) bu
-- isaret, server/district_hubs.lua FragmentTerritory'yi tetikler.
-- =====================================================================
RegisterCommand('cetelideriata', function(src, args)
    local botId       = tonumber(args[1])
    local trapHouseId = tonumber(args[2])
    if not botId or not trapHouseId or not Matrix.Bots[botId] or not Matrix.TrapHouses[trapHouseId] then
        Reply(src, 'Kullanim: /cetelideriata [botId] [trapHouseId (gecerli olmali)]'); return
    end


    if Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority then
        local assignerState = Matrix.GetOrCreatePlayerState(src)
        if not assignerState or not assignerState.citizenid or not Matrix.Hierarchy.HasCommandAuthority(assignerState.citizenid) then
            Reply(src, 'Bu atamayi yapmak icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'); return
        end
    end


    local bot = Matrix.Bots[botId]
    bot.role = 'Leader'
    bot.state.trap_house_id = trapHouseId
    local assignerState = Matrix.GetOrCreatePlayerState(src)
    bot.handler_citizenid = assignerState and assignerState.citizenid
    Matrix.MarkBotDirty(botId)


    Reply(src, ('Bot #%d, Trap #%d icin otonom cete lideri ("Leader") olarak atandi.'):format(botId, trapHouseId))
    Matrix.Log('CORE', '[CETE LIDERI ATANDI] Bot #%d -> Trap #%d', botId, trapHouseId)
end, false)


-- =====================================================================
-- ★ KATMAN 5 ULTIMATE [U8]: /panikiptal — ACİL TAHLİYE (GÖREVİ İPTAL ET)
-- F10 "Canlı Kadro" menüsünde bir bota tıklanınca açılan "Acil Tahliye
-- (Görevi İptal Et)" aksiyonunun arkasındaki komut; bkz. Matrix.
-- TriggerPanicEvacuation (yukarıda) için tam davranış açıklaması.
-- =====================================================================
local PANIC_EVAC_FAILURE_MESSAGES = {
    bad_bot_id              = 'Gecersiz bot ID.',
    bot_missing              = 'Bot matriste bulunamadi.',
    not_dispatched           = 'Bot su anda aktif bir sevkiyatta degil (sahada degil), acil tahliye tetiklenemez.',
    bad_dispatcher           = 'Komutu tetikleyen oyuncu cozulemedi.',
    dispatcher_ped_missing   = 'Ped\'iniz bulunamadi.',
    entity_missing           = 'Botun fiziksel varligi (ped) dunyada bulunamadi.',
    vehicle_missing          = 'Botun aracı dunyada bulunamadi.',
    bad_dispatcher_coords    = 'Konumunuz cozulemedi.',
    task_assignment_failed   = 'Gorev atamasi basarisiz oldu.'
}


RegisterCommand('panikiptal', function(src, args)
    local botId = tonumber(args[1])
    if not botId then NotifyResult(src, false, 'Kullanim: /panikiptal [botId]'); return end


    if Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority then
        local callerState = Matrix.GetOrCreatePlayerState(src)
        if not callerState or not callerState.citizenid or not Matrix.Hierarchy.HasCommandAuthority(callerState.citizenid) then
            NotifyResult(src, false, 'Bu emri vermek icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'); return
        end
    end


    local ok, reason = Matrix.TriggerPanicEvacuation(botId, src)
    if ok then
        NotifyResult(src, true, ('[ACIL TAHLIYE TETIKLENDI] Bot #%d gorevini terk etti, son hizla sana dogru geliyor.'):format(botId))
    else
        NotifyResult(src, false, PANIC_EVAC_FAILURE_MESSAGES[reason] or ('Acil tahliye tetiklenemedi: %s'):format(tostring(reason)))
    end
end, false)


-- =====================================================================
-- ★ KATMAN 5 [H11]: /rotaciz — MULTI-WAYPOINT TAKTİK ROTA MOTORU
--
-- Her waypoint argümanı ya salt tam sayı bir Trap House ID'si ya da
-- "x,y,z" biçiminde bir vector3'tür. Argümanlar client/hud.lua'nın F10
-- "Rota Çiz" diyaloğu tarafından ZATEN sanitize edilmiş şekilde gelir
-- (yalnızca rakam/nokta/virgül/eksi) — burada yalnızca FORMAT çözümlemesi
-- ve fiziksel/mesafe guard'ları uygulanır.
-- =====================================================================
local WAYPOINT_INTEGER_PATTERN  = '^%d+$'
local WAYPOINT_COORD_PATTERN    = '^%-?%d+%.?%d*,%-?%d+%.?%d*,%-?%d+%.?%d*$'
-- ★ KATMAN 7 [OPSEC]: client/hud.lua'nın SanitizeWaypointArg'ının ZATEN
-- doğruladığı (yalnızca gerçek bir Config.Supplier.DeadDrops.id'sine
-- karşılık gelen) "DD-<sayı>" token'ı — burada YALNIZCA format ÇÖZÜMLEMESİ
-- yapılır, ikinci bir varlık kontrolü aşağıda tekrar uygulanır (client
-- sanitizasyonu bir GÜVEN kaynağı DEĞİL, salt bir ön-filtredir).
local WAYPOINT_DEAD_DROP_PATTERN = '^[Dd][Dd]%-(%d+)$'


local function ResolveWaypointRef(refString)
    if type(refString) ~= 'string' or refString == '' then return nil, 'empty_waypoint' end


    local deadDropIdStr = refString:match(WAYPOINT_DEAD_DROP_PATTERN)
    if deadDropIdStr then
        local dropId = tonumber(deadDropIdStr)
        local dropCfg
        for _, d in ipairs(Config.Supplier.DeadDrops) do
            if d.id == dropId then dropCfg = d break end
        end
        if not dropCfg or not dropCfg.coords then return nil, 'dead_drop_not_found' end
        return dropCfg.coords
    end


    if refString:match(WAYPOINT_INTEGER_PATTERN) then
        local houseId = tonumber(refString)
        local house = Matrix.TrapHouses and Matrix.TrapHouses[houseId]
        if not house or not house.coords then return nil, 'trap_house_not_found' end
        return house.coords
    end


    if refString:match(WAYPOINT_COORD_PATTERN) then
        local xs, ys, zs = refString:match('^(%-?%d+%.?%d*),(%-?%d+%.?%d*),(%-?%d+%.?%d*)$')
        local x, y, z = tonumber(xs), tonumber(ys), tonumber(zs)
        if not x or not y or not z then return nil, 'bad_coord_numbers' end
        if x ~= x or y ~= y or z ~= z then return nil, 'nan_coord' end
        return vector3(x, y, z)
    end


    return nil, 'unrecognized_waypoint_format'
end


RegisterCommand('rotaciz', function(src, args)
    local botId = tonumber(args[1])
    local bot   = botId and Matrix.Bots[botId]
    if not bot then
        Reply(src, 'Kullanim: /rotaciz [botId] [wp1|nil] [wp2|nil] [wp3|nil] [finalHedef] [plaka] [aracTipi] (wp1-3 bos/"nil" olabilir)')
        return
    end


    -- ★ [E3] DİNAMİK WAYPOINT ESNEKLİĞİ: boş bırakılan ('nil' placeholder'ı
    -- veya boş string) ara uğrak argümanları BURADA — senkron, saf bir
    -- filtre olarak (ek thread/coroutine YOK, 0 Resmon korunur) — rota
    -- zincirinden drop edilir. Yalnızca DOLU ve GEÇERLİ olanlar sıralı
    -- (boşluksuz) bir diziye toplanıp BeginRouteDispatch'e iletilir.
    local waypoints = {}
    for i, rawIdx in ipairs({ 2, 3, 4 }) do
        local raw = args[rawIdx]
        if raw ~= nil and raw ~= '' and raw ~= 'nil' then
            local coords, err = ResolveWaypointRef(raw)
            if not coords then
                Reply(src, ('Ugrak #%d cozumlenemedi: %s'):format(i, tostring(err)))
                return
            end
            waypoints[#waypoints + 1] = coords
        end
    end


    local finalCoords, finalErr = ResolveWaypointRef(args[5])
    if not finalCoords then
        Reply(src, ('Final hedef cozumlenemedi: %s'):format(tostring(finalErr)))
        return
    end


    local plate = args[6]
    if plate == nil or plate == '' or plate == 'nil' then plate = nil end


    local vehicleType = args[7]
    if not vehicleType or not Config.Logistics.VehicleTypes[vehicleType] then
        vehicleType = Config.Logistics.DefaultVehicleType
    end


    -- ★ HATA DÜZELTMESİ: origin BOTUN kendi son bilinen konumudur — komutu
    -- tetikleyen oyuncunun konumu DEĞİL (bkz. ResolveBotOrigin). Bot artık
    -- rota her çizildiğinde oyuncunun yanına ışınlanmıyor; dünyaya
    -- enjekte edildiği/en son bulunduğu uzak noktadan asfalttan yola çıkıyor.
    -- dispatcherSrc (src) yalnızca EN SON çare fallback'inde kullanılır.
    local origin = ResolveBotOrigin(bot, src)
    if not origin then
        Reply(src, ('Bot #%d icin gecerli bir baslangic konumu bulunamadi (trap house yok, dispatcher ped cozulemedi).'):format(botId))
        return
    end


    local ok, err, legIndex, legDist = Matrix.BeginRouteDispatch(botId, origin, waypoints, finalCoords, plate, vehicleType, src)
    if ok then
        Reply(src, ('[ROTA CIZILDI] Bot #%d icin %d ugraklik taktik kacis rotasi baslatildi.'):format(botId, #waypoints + 1))
    elseif err == 'too_close' and legIndex then
        local totalLegs = #waypoints + 1
        local fromLabel = (legIndex == 1) and 'Bot Konumu' or ('Ugrak #%d'):format(legIndex - 1)
        local toLabel   = (legIndex == totalLegs) and 'Final Hedef' or ('Ugrak #%d'):format(legIndex)
        Reply(src, ('Rota baslatilamadi: %s -> %s arasi cok yakin (%.1fm < %.1fm gerekli). Isinlanma korumasi engelledi.'):format(
            fromLabel, toLabel, legDist or 0.0, Config.Logistics.MinDispatchDistanceMeters))
    else
        Reply(src, ('Rota baslatilamadi: %s'):format(tostring(err)))
    end
end, false)


-- ★ [E5] /rutbeata (KALDIRILDI): server/market.lua ZATEN bunu tanımlıyor
-- (Matrix.Hierarchy.SetRank ile matrix_hierarchy tablosuna yazan, 3
-- denemeli citizenid çözümlemesi olan, DB-kalıcı bir sürüm). Buradaki
-- kopya RegisterCommand aynı komut adını İKİNCİ KEZ kaydediyordu ve kendi
-- (yazılmayan/okunmayan) Matrix.PlayerRanks tablosuna yazıyordu — gerçek
-- rütbe sistemiyle tamamen kopuktu. Kaldırıldı; "Canlı Kadro & Hiyerarşi
-- Raporu" artık market.lua'nın Matrix.Hierarchy.GetRank'ini okuyor.


RegisterCommand('balistiktest', function(src, args)
    local weaponSerial = tostring(args[1] or 'TEST-SERIAL-0001')
    local weaponWear   = Matrix.Clamp(tonumber(args[2]) or 0.0, 0.0, 1.0)


    local result = Matrix.Forensics.SimulateWeaponFire({ kind = 'player', source = src }, weaponSerial, weaponWear, 'test_fire')
    if not result then Reply(src, 'Test başarısız: oyuncu profili çözülemedi.'); return end


    Reply(src, ('BalistikID:%s | Q_kovan:%.3f | Parmak izi:%.3f | Eşleşme:%.3f | Mühür:%s'):format(
        result.ballistic_id, result.striation_quality, result.fingerprint_quality,
        result.match_certainty, tostring(result.sealed)))
end, false)


RegisterCommand('botbalistik', function(src, args)
    local botId = tonumber(args[1])
    if not botId or not Matrix.Bots[botId] then
        Reply(src, 'Kullanim: /botbalistik [id] [seri] [asinma 0-1]'); return
    end
    local weaponSerial = tostring(args[2] or ('TEST-SERIAL-BOT-%d'):format(botId))
    local weaponWear   = Matrix.Clamp(tonumber(args[3]) or 0.0, 0.0, 1.0)


    local result = Matrix.Forensics.SimulateWeaponFire({ kind = 'bot', id = botId }, weaponSerial, weaponWear, 'test_fire')
    if not result then Reply(src, 'Test başarısız.'); return end


    Reply(src, ('Bot #%d | BalistikID:%s | Q_kovan:%.3f | Eşleşme:%.3f | Mühür:%s'):format(
        botId, result.ballistic_id, result.striation_quality,
        result.match_certainty, tostring(result.sealed)))
end, false)


RegisterCommand('kortizolum', function(src)
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state then Reply(src, 'Profil çözülemedi.'); return end
    Reply(src, ('Kortizol:%.2f | Yorgunluk:%.2f | Direnç:%.2f | Toparlanma:%.4f'):format(
        state.biology.cortisol_level, state.biology.fatigue_level,
        state.biology.resilience, state.biology.base_cortisol_recovery_rate))
end, false)


RegisterCommand('kortizoltetikle', function(src, args)
    local spikeType = args[1] or 'gunshot'
    if spikeType ~= 'gunshot' and spikeType ~= 'bureau_vehicle' then
        Reply(src, 'Kullanim: /kortizoltetikle [gunshot|bureau_vehicle]'); return
    end
    Matrix.Kitchen.AdjustCortisol({ kind = 'player', source = src }, spikeType)
    local state = Matrix.GetOrCreatePlayerState(src)
    if state then
        Reply(src, ('Kortizol sıçraması (%s). Yeni seviye: %.2f'):format(spikeType, state.biology.cortisol_level))
    end
end, false)


RegisterCommand('botdurum', function(src, args)
    local botId = tonumber(args[1])
    local bot = botId and Matrix.Bots[botId]
    if not bot then Reply(src, 'Kullanim: /botdurum [id]'); return end
    Reply(src, ('Bot #%d [%s] Kortizol:%.2f Yorgunluk:%.2f Yoksunluk:%.2f Direnç:%.2f'):format(
        bot.id, bot.name, bot.biology.cortisol_level, bot.biology.fatigue_level,
        bot.biology.withdrawal_index, bot.psychology.resilience))
end, false)


-- =====================================================================
-- EXPORTLAR
-- =====================================================================
exports('CreateBot',   function(p) return Matrix.CreateBotRecord(p) end)
exports('SpawnBot',    function(id, c) return Matrix.SpawnBot(id, c) end)
exports('DespawnBot',  function(id) return Matrix.DespawnBot(id) end)
exports('RemoveBot',   function(id, r) return Matrix.RemoveBot(id, r) end)
exports('GetBot',      function(id) return Matrix.GetBot(id) end)
exports('GetBotReadOnly', function(id, cellName) return Matrix.GetBotReadOnly(id, cellName) end)
exports('GetBotDeepCopy', function(id) return Matrix.GetBotDeepCopy(id) end)
exports('SetBotInteriorTrapHouse', function(id, trapHouseId)
    return Matrix.SetBotInteriorTrapHouse(id, trapHouseId)
end)

exports('BeginPhysicalDispatch', function(botId, origin, destination, plate, vehicleType, eta, src, frictionDivisor)
    return Matrix.BeginPhysicalDispatch(botId, origin, destination, plate, vehicleType, eta, src, frictionDivisor)
end)
exports('BeginRouteDispatch', function(botId, origin, waypoints, finalDest, plate, vehicleType, src, frictionDivisor)
    return Matrix.BeginRouteDispatch(botId, origin, waypoints, finalDest, plate, vehicleType, src, frictionDivisor)
end)
exports('CompleteDispatch', function(botId, reason)
    return Matrix.CompleteDispatch(botId, reason)
end)
exports('GetActiveDispatches', function()
    return Matrix.Dispatches
end)
exports('DepositDealerCargoToTrapStash', function(botId, trapHouseId)
    return Matrix.DepositDealerCargoToTrapStash(botId, trapHouseId)
end)
exports('TriggerPanicEvacuation', function(botId, dispatcherSrc)
    return Matrix.TriggerPanicEvacuation(botId, dispatcherSrc)
end)


exports('ReportWeaponDischarge', function(actorRef, weaponSerial, invId, slot)
    return Matrix.Forensics.OnWeaponFired(actorRef, weaponSerial, invId, slot)
end)
exports('SimulateWeaponFire', function(actorRef, weaponSerial, wear, evType, durability)
    return Matrix.Forensics.SimulateWeaponFire(actorRef, weaponSerial, wear, evType, durability)
end)
exports('StampTouch',     function(actorRef, invId, slot) return Matrix.Forensics.StampTouch(actorRef, invId, slot) end)
exports('AnalyzeEvidence',function(evId) return Matrix.Forensics.AnalyzeEvidence(evId) end)


exports('ProcessCook',  function(a, t, rw, rp, aw) return Matrix.Kitchen.ProcessCook(a, t, rw, rp, aw) end)
exports('AdjustCortisol',function(a, s) return Matrix.Kitchen.AdjustCortisol(a, s) end)
exports('OnBotCaptured', function(b, t) return Matrix.Kitchen.OnCaptured(b, t) end)


exports('TriggerPropaganda',     function(t) return Matrix.Bureau.TriggerPropaganda(t) end)
exports('ReportUnencryptedComms',function(a, c) return Matrix.Bureau.OnUnencryptedComms(a, c) end)
exports('ReportLogisticsRun',    function(t) return Matrix.Bureau.LogPatternEvent(t) end)


exports('ScanCustomerPool',       function() return Matrix.Recruitment.ScanCustomerPool() end)
exports('BeginInterrogation',     function(c, s) return Matrix.Recruitment.BeginInterrogation(c, s) end)
exports('ApplyInterrogationPressure', function(s, a) return Matrix.Recruitment.ApplyPressure(s, a) end)
exports('EvaluateInterrogation',  function(s) return Matrix.Recruitment.EvaluateOutcome(s) end)


-- =====================================================================
-- TAKTİK DEBUG PANELİ
-- =====================================================================
local VALID_PSYCHOLOGY_FIELDS = {
    fear_factor = true, resilience = true, snitch_tendency = true,
    economic_pressure = true, cognitive_shifter = true,
    skill_chemistry = true, skill_cyber = true, skill_logistics = true,
    loyalty_base = true
}
local VALID_BIOLOGY_FIELDS = {
    fatigue_level = true, cortisol_level = true, withdrawal_index = true,
    addiction_level = true, base_cortisol_recovery_rate = true
}


RegisterCommand('botskill', function(src, args)
    local botId = tonumber(args[1])
    local field = args[2]
    local value = tonumber(args[3])
    local bot = botId and Matrix.Bots[botId]
    if not bot or not VALID_PSYCHOLOGY_FIELDS[field] or not value then
        Reply(src, 'Kullanim: /botskill [id] [fear_factor|resilience|snitch_tendency|economic_pressure|cognitive_shifter|skill_chemistry|skill_cyber|skill_logistics|loyalty_base] [0.0-1.0]')
        return
    end
    bot.psychology[field] = Matrix.Clamp(value, 0.0, 1.0)
    Matrix.MarkBotDirty(botId)
    Reply(src, ('Bot #%d %s = %.3f olarak ayarlandı.'):format(botId, field, bot.psychology[field]))
end, false)


RegisterCommand('botbio', function(src, args)
    local botId = tonumber(args[1])
    local field = args[2]
    local value = tonumber(args[3])
    local bot = botId and Matrix.Bots[botId]
    if not bot or not VALID_BIOLOGY_FIELDS[field] or not value then
        Reply(src, 'Kullanim: /botbio [id] [fatigue_level|cortisol_level|withdrawal_index|addiction_level|base_cortisol_recovery_rate] [deger]')
        return
    end
    local maxV = (field == 'addiction_level') and 100.0 or 1.0
    bot.biology[field] = Matrix.Clamp(value, 0.0, maxV)
    Matrix.MarkBotDirty(botId)
    Reply(src, ('Bot #%d %s = %.3f olarak ayarlandı.'):format(botId, field, bot.biology[field]))
end, false)


--- ★ KATMAN 5 [H13]: Bot'un HUD "Mekanik" bültenine (silah aşınması)
--- yansıyan ham durability/wear değerini ayarlar (debug/test amaçlı,
--- botskill/botbio ile aynı desen). Ham float BURADA basılır (dev cockpit
--- istisnası) — HUD'da her zaman edebi bültene çevrilmiş halde görünür.
RegisterCommand('botmekanik', function(src, args)
    local botId = tonumber(args[1])
    local value = tonumber(args[2])
    local bot = botId and Matrix.Bots[botId]
    if not bot or not value then
        Reply(src, 'Kullanim: /botmekanik [id] [asinma 0.0-1.0] (1.0=kusursuz, 0.0=eriimis)')
        return
    end
    bot.state.weapon_wear_level = Matrix.Clamp(value, 0.0, 1.0)
    Reply(src, ('Bot #%d silah asinmasi (ham) = %.3f olarak ayarlandi.'):format(botId, bot.state.weapon_wear_level))
end, false)


RegisterCommand('radyoparazit', function(src, args)
    local targetSrc = tonumber(args[1]) or src
    local intensity = tonumber(args[2]) or 1.0
    Matrix.Radio.ApplyStatic(targetSrc, intensity, 'debug')
    Reply(src, ('Telsiz statiği src=%d yoğunluk=%.2f olarak tetiklendi.'):format(targetSrc, intensity))
end, false)


RegisterCommand('matrixdump', function(src)
    local count = 0
    for id, bot in pairs(Matrix.Bots) do
        count = count + 1
        Reply(src, ('#%d [%s|%s|%s] Fat:%.2f Cort:%.2f With:%.2f | Chem:%.2f Cyber:%.2f Log:%.2f | Res:%.2f Snitch:%.2f Loyal:%.2f | Mekanik:%.2f'):format(
            id, bot.name, bot.role, bot.status,
            bot.biology.fatigue_level, bot.biology.cortisol_level, bot.biology.withdrawal_index,
            bot.psychology.skill_chemistry, bot.psychology.skill_cyber, bot.psychology.skill_logistics,
            bot.psychology.resilience, bot.psychology.snitch_tendency, bot.psychology.loyalty_base or 0.5,
            bot.state.weapon_wear_level or 1.0))
    end
    Reply(src, ('--- Toplam %d bot ---'):format(count))
end, false)


RegisterCommand('fizikselsevk', function(src, args)
    local count = 0
    for botId, d in pairs(Matrix.Dispatches) do
        count = count + 1
        local lc = d.last_coords or d.origin
        local routeInfo = d.route_queue and (' Rota:%d/%d'):format(d.route_index, #d.route_queue) or ''
        Reply(src, ('Bot #%d [%s] Plaka:%s Konum:(%.1f,%.1f,%.1f) Hedef-Mesafe:%.1fm Hiz:%.2fm/s Sinyal:%s Polis-Dwell:%d Bekleyen:%d%s'):format(
            botId, d.vehicle_type, tostring(d.plate),
            lc.x, lc.y, lc.z,
            #(lc - d.destination),
            d.cruise_speed or 0.0,
            d.comms_lost and 'KESİK' or 'VAR',
            d.police_dwell,
            #d.pending_events,
            routeInfo))
    end
    Reply(src, ('--- Toplam %d fiziksel dispatch ---'):format(count))
end, false)