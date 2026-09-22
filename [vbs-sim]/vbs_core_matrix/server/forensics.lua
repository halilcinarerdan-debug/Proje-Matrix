-- =====================================================================
-- MATRIX FORENSICS / forensics.lua
-- In-memory balistik cache, lokal ID allocator, async insert.
--
-- ★ KATMAN 5 REVİZYONU: EVRİLEN BALİSTİK (Gauss Çekirdeği Mutasyonu) ★
--   Silahın KENDİ canı (ox_inventory item durability, weaponInventoryId/
--   weaponSlot üzerinden okunur) artık namlu iz netliğini (Q_kovan)
--   ÇARPIMSAL olarak mutasyona uğratır: Q_kovan = Q_kovan_taban * durability.
--   durability [0,1]'e clamp'li olduğundan bu ASLA taban formülün üstüne
--   çıkmaz — sadece eskimiş silahlar daha da düşük netlik üretir. Silah canı
--   %50'nin altına düşünce eşleşme kesinliği (match_certainty) ÜSTEL olarak
--   baltalanır ("Adli Laboratuvar Körlüğü"); %20'nin altında deterministik
--   Jam_Chance formülü 0.65'in üzerine çıkar ve buna bağlı bir kalıcı-ölüm
--   riski değeri hesaplanır (asıl tutukluk/RNG çözümü — varsa — çatışma
--   sistemine aittir; burada sadece SAF, tekrar üretilebilir formül üretilir).
--   RNG YOK: aynı (weaponWear, cortisol, durability) üçlüsü HER ZAMAN aynı
--   çıktıyı üretir.
--
-- ★ KATMAN 5 SERTLEŞTİRME REVİZYONU (önceki tur, korunuyor):
--   [F1] BallisticCache için FIFO tabanlı bir üst sınır (4096 kayıt):
--        çok uzun uptime'larda (haftalarca açık kalan sunucu) tekil silah
--        serisi sayısı teorik olarak sınırsız büyüyebilir; bu üst sınır RAM
--        şişmesini yapısal olarak engeller. Gerçek LRU DEĞİLDİR — basit
--        "insert-order FIFO" (son eklenenler değil, İLK eklenenler atılır).
--        Atılan bir seri yeniden ateşlenirse DB'de zaten var olduğundan
--        (ON DUPLICATE KEY) sorunsuz yeniden cache'e girer.
--   [F2] Wear flush için retry kuyruğu: bir UPDATE hata verirse (geçici DB
--        kesintisi vb.) kayıp gitmez, bir sonraki 20sn'lik tick'te tekrar
--        denenir.
--   [F3] Adli Laboratuvar Körlüğü formülündeki math.exp çağrısına
--        `math_max(rate, 1e-9)` guard'ı eklendi. NOT — dürüst açıklama:
--        rate=0 durumu zaten NaN ÜRETMEZ (exp(-0*deficit)=exp(0)=1.0,
--        matematiksel olarak tanımlı); bu guard bir NaN riskini KAPATMIYOR,
--        yalnızca "decay rate sıfırsa körlük etkisi tam olarak devre dışı
--        kalsın" niyetini AÇIKÇA ifade eden zararsız bir savunma katmanıdır.
--   [F4] Event bridge'ler ve LoadCaches artık pcall ile sarmalı (bkz.
--        main.lua [H6] ile AYNI disiplin) — tek bir ateşleme olayındaki
--        beklenmedik hata event handler'ı ya da resource başlangıcını
--        düşürmez.
--   [F5] /balistikcache debug komutu: LRU/retry kuyruklarının anlık RAM
--        boyutlarını gösterir (yeni sınırların gerçekten iş gördüğünü
--        doğrulamak için).
--
-- ★ KATMAN 5 ULTIMATE [U3] — GERÇEKÇİ BALİSTİK SABİTLEME (bu sürüm, yeni):
--   Namlu atış ömrü + gerçek-zamanlı mekanik tutukluk (jam) mekaniği.
--   ÖNEMLİ: bu, YUKARIDAKİ Jam_Chance/GetHardDeleteRiskIfJammed formülünün
--   YERİNE GEÇMEZ — o formül SAF bir "adli/kalıcı-ölüm risk değeri" üretici
--   olarak AYNEN korunuyor (kanıt raporlarında hâlâ görünür). Burada
--   eklenen `Mechanical*` ailesi TAMAMEN AYRI, gerçek OYNANIŞ mekaniğidir:
--     - Her atışta (OnWeaponShotFired) silahın canı, o silah tipinin gerçek
--       namlu atış ömrüne göre (Config.Forensics.WeaponShotLifespan)
--       düşürülür: durability = 100 * (1 - shots_fired/lifespan).
--     - Can, Config.Forensics.MechanicalJamThresholdPercent (%40)'ın
--       altına indiğinde her atışta ÜSSEL artan bir olasılık DEĞERİ
--       hesaplanır: Jam_Probability = (1-(Durability/40))^3 * 0.35.
--     - "0 RNG" prensibi HARFİYEN korunur: bu olasılık klasik bir zar
--       atışına DEĞİL, item metadata'sında tutulan deterministik bir
--       biriktiriciye (jam_accumulator) eklenir. Biriktirici 1.0'i
--       GEÇTİĞİ AN tutukluk KESİN olarak tetiklenir ve taşan kısım bir
--       sonraki atışa taşınır (Bresenham-tarzı deterministik oranlama —
--       uzun vadede TAM OLARAK beklenen sıklığı üretir, ama HER adım
--       tekrar-üretilebilirdir; aynı atış dizisi HER ZAMAN aynı anda
--       tutukluk üretir). RNG YOK.
--   Namlu değişimi (/namludegistir, server/blackmarket.lua'nın sattığı
--   Yedek Namlu'yu tüketir) durability/shots_fired/jam_accumulator'ı
--   sıfırlar VE WipeBallisticRecord ile o silahın TÜM balistik/adli
--   kaydını (cache + matrix_ballistic_weapons + matrix_forensic_evidence)
--   kalıcı olarak siler — "Büro tamamen kör edilir".
-- =====================================================================


Matrix.Forensics = Matrix.Forensics or {}


local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, table, math       = tonumber, table, math
local math_max, math_min          = math.max, math.min
local math_exp                    = math.exp
local GetGameTimer                = GetGameTimer


-- [F1] LRU(FIFO) cap
local BALLISTIC_CACHE_MAX = 4096


-- weaponSerial -> { ballistic_id, wear_level }
local BallisticCache = {}
-- Insert sırası (FIFO budama için)
local BallisticInsertOrder = {}
-- ballistic_id -> pendingWear
local PendingWearUpdates = {}
-- [F2] Bir önceki flush'ta başarısız olan yazımlar
local WearRetryQueue = {}


-- Forensic evidence için lokal ID allocator (async INSERT'e izin verir)
local EvidenceNextId     = 1
local EvidenceIdSynced   = false


-- =====================================================================
-- [F1] FIFO BUDAMA
-- En eski eklenmiş kayıtları düşürür (gerçek LRU değil — "insert-order
-- FIFO", basit ve deterministik). KARMAŞIKLIK: O(n) sadece cap aşıldığında
-- çalışır (her insert'te değil), pratikte nadiren tetiklenir.
-- =====================================================================
local function EvictBallisticCacheIfNeeded()
    local n = 0
    for _ in pairs(BallisticCache) do n = n + 1 end
    if n <= BALLISTIC_CACHE_MAX then return end


    local excess = n - BALLISTIC_CACHE_MAX
    local removed = 0
    local i = 1
    while removed < excess and i <= #BallisticInsertOrder do
        local serial = BallisticInsertOrder[i]
        if serial and BallisticCache[serial] then
            BallisticCache[serial] = nil
            removed = removed + 1
        end
        BallisticInsertOrder[i] = nil
        i = i + 1
    end
    -- Kalan sırayı öne sıkıştır (delikli dizi bırakma).
    local j = 1
    for k = i, #BallisticInsertOrder do
        BallisticInsertOrder[j] = BallisticInsertOrder[k]
        j = j + 1
    end
    for k = j, #BallisticInsertOrder do BallisticInsertOrder[k] = nil end
end


local function GetActorDnaId(actor)
    if not actor then return 'UNKNOWN' end
    return actor.dna_id or 'UNKNOWN'
end


local function GetActorCortisol(actor)
    if not actor or not actor.biology then return 0.0 end
    return Matrix.Clamp(actor.biology.cortisol_level or 0.0, 0.0, 1.0)
end


-- ★ KATMAN 5: silahın KENDİ canı (ox_inventory item durability, [0,100])
-- weaponInventoryId/weaponSlot üzerinden okunur ve [0,1]'e normalize edilir.
-- Metadata yoksa (silah hiç ateşlenmemiş/canı hiç ayarlanmamış) varsayılan
-- 1.0 (tam sağlam) - mutasyon formülü bu durumda taban formülü DEĞİŞTİRMEZ.
local function GetWeaponDurability(weaponInventoryId, weaponSlot)
    if not weaponInventoryId or type(weaponSlot) ~= 'number' then return 1.0 end
    local meta = Matrix.Inventory.GetSlotMetadata(weaponInventoryId, weaponSlot)
    local durability = tonumber(meta.durability)
    if not durability then return 1.0 end
    return Matrix.Clamp(durability / 100.0, 0.0, 1.0)
end


-- FORMÜL: Q_iz = clamp(1.0 - cortisol_level * FingerprintQualityCortisolWeight, 0, 1)
-- Yorum: el terlemesi (kortizol/panik) parmak izi netliğini DOĞRUSAL olarak
-- düşürür; ağırlık sabiti (0.4) tek bir çarpandır, RNG YOK. O(1) karmaşıklık -
-- her çağrıda tek bir clamp+çarpma; 0 Resmon açısından maliyetsizdir.
function Matrix.Forensics.ComputeFingerprintQuality(actor)
    local cortisol = GetActorCortisol(actor)
    return Matrix.Clamp(1.0 - (cortisol * Config.Forensics.FingerprintQualityCortisolWeight), 0.0, 1.0)
end


-- FORMÜL (Katman 5 — Tutukluk / Jam Chance):
--   durability >= WeaponJamChanceThreshold  -> 0.0 (risk yok)
--   durability <  WeaponJamChanceThreshold  -> WeaponJamBaseChance * (1 + deficitRatio)
--   deficitRatio = (threshold - durability) / threshold  ∈ (0,1]
-- Yorum: eşiğin hemen altında tabana (%65) sıçrar, sonra durability sıfıra
-- yaklaştıkça DOĞRUSAL büyümeye devam eder (deficitRatio→1 iken chance→2x
-- taban, clamp ile [0,1]'e sınırlanır). RNG YOK; asıl "tutukluk oldu mu"
-- kararı (ve buna bağlı gerçek zaman içi rulet) bu formülü TÜKETEN çatışma
-- sistemine aittir — burada sadece deterministik olasılık DEĞERİ üretilir.
--
-- ★ NOT: Bu SAF adli/kalıcı-ölüm risk formülüdür (DEĞİŞMEDİ). Gerçek-zamanlı
-- oynanış tutukluğu için aşağıdaki Matrix.Forensics.ComputeMechanicalJamProbability
-- + Matrix.Forensics.OnWeaponShotFired'a bakın (Katman 5 ULTIMATE [U3]).
function Matrix.Forensics.ComputeJamChance(weaponDurability)
    weaponDurability = Matrix.Clamp(tonumber(weaponDurability) or 1.0, 0.0, 1.0)
    local threshold = Config.Forensics.WeaponJamChanceThreshold
    if weaponDurability >= threshold then return 0.0 end


    local deficitRatio = (threshold - weaponDurability) / math_max(threshold, 0.0001)
    return Matrix.Clamp(Config.Forensics.WeaponJamBaseChance * (1.0 + deficitRatio), 0.0, 1.0)
end


-- Jam_Chance eşiğin (WeaponJamChanceThreshold) altındaki silahlar için sabit
-- bir kalıcı-ölüm risk DEĞERİ döner (WeaponJamHardDeleteRisk); eşiğin
-- üstündeyse 0.0. Bu da SAF bir formüldür — hangi sistemin bu riski nasıl
-- kullanacağı (RNG'li mi, eşik-tabanlı mı) bu dosyanın kapsamı DIŞINDADIR.
function Matrix.Forensics.GetHardDeleteRiskIfJammed(weaponDurability)
    if Matrix.Forensics.ComputeJamChance(weaponDurability) > 0.0 then
        return Config.Forensics.WeaponJamHardDeleteRisk
    end
    return 0.0
end


-- =====================================================================
-- ★ KATMAN 5 ULTIMATE [U3]: NAMLU ATIŞ ÖMRÜ + MEKANİK TUTUKLUK FORMÜLLERİ
-- =====================================================================


--- Silah item adına göre gerçek namlu atış ömrünü (kaç atışta can 0'a
--- iner) döner. Bilinmeyen bir item için Config.Forensics.
--- WeaponShotLifespanDefault kullanılır (asla nil/0 dönmez -> /0 riski yok).
function Matrix.Forensics.GetWeaponShotLifespan(weaponItemName)
    local table_ = Config.Forensics.WeaponShotLifespan
    local lifespan = (type(weaponItemName) == 'string' and table_[weaponItemName])
        or Config.Forensics.WeaponShotLifespanDefault
        or 15000
    lifespan = tonumber(lifespan) or 15000
    if lifespan <= 0 then lifespan = 15000 end
    return lifespan
end


-- FORMÜL (Katman 5 ULTIMATE — Gerçek-Zamanlı Mekanik Tutukluk):
--   durability (%) >= MechanicalJamThresholdPercent (40) -> 0.0 (risk yok)
--   durability (%) <  40 -> (1.0 - (Durability/40))^3 * 0.35
-- Yorum: eşiğin hemen altında YUMUŞAK başlar (kübik üs sayesinde), can
-- sıfıra yaklaştıkça ÜSSEL hızlanır. Durability=0 iken tam katsayıya
-- (0.35) ulaşır. RNG YOK — bu SAF bir olasılık DEĞERİDİR; gerçek tetikleme
-- Matrix.Forensics.OnWeaponShotFired'daki deterministik biriktirici
-- (jam_accumulator) tarafından yapılır (bkz. dosya başı [U3] açıklaması).
-- KARMAŞIKLIK: O(1).
function Matrix.Forensics.ComputeMechanicalJamProbability(durability)
    durability = Matrix.Clamp(tonumber(durability) or 100.0, 0.0, 100.0)
    local threshold = Config.Forensics.MechanicalJamThresholdPercent
    if durability >= threshold then return 0.0 end


    local ratio = Matrix.Clamp(1.0 - (durability / math_max(threshold, 0.0001)), 0.0, 1.0)
    local exponent = Config.Forensics.MechanicalJamExponent or 3
    local probability = (ratio ^ exponent) * (Config.Forensics.MechanicalJamCoefficient or 0.35)
    return Matrix.Clamp(probability, 0.0, 1.0)
end


-- =====================================================================
-- LOAD CACHE
-- =====================================================================
function Matrix.Forensics.LoadCaches()
    -- Ballistic weapons
    local rows = MySQL.query.await('SELECT weapon_serial, ballistic_id, wear_level FROM matrix_ballistic_weapons', {}) or {}
    for _, row in ipairs(rows) do
        BallisticCache[row.weapon_serial] = {
            ballistic_id = row.ballistic_id,
            wear_level   = row.wear_level or 0.0
        }
        BallisticInsertOrder[#BallisticInsertOrder + 1] = row.weapon_serial
    end
    Matrix.Log('FORENSICS', '%d balistik silah önbelleğe yüklendi.', #rows)
    EvictBallisticCacheIfNeeded()


    -- Evidence id watermark
    local r = MySQL.query.await('SELECT COALESCE(MAX(id),0) AS mx FROM matrix_forensic_evidence', {}) or {}
    local mx = (r[1] and r[1].mx) or 0
    EvidenceNextId   = mx + 1
    EvidenceIdSynced = true
    Matrix.Log('FORENSICS', 'Kanıt ID watermark: %d', EvidenceNextId)
end


-- [F4] pcall: LoadCaches sırasında beklenmedik hata resource başlangıcını
-- (diğer dosyaların CreateThread'lerini) düşürmez.
CreateThread(function()
    local ok, err = pcall(Matrix.Forensics.LoadCaches)
    if not ok then
        Matrix.Log('FORENSICS', '[HATA] LoadCaches basarisiz (yutuldu): %s', tostring(err))
    end
end)


local function NextEvidenceId()
    if not EvidenceIdSynced then return nil end
    local id = EvidenceNextId
    EvidenceNextId = id + 1
    return id
end


-- =====================================================================
-- BALLISTIC REGISTRATION (cache'ten, async upsert)
-- =====================================================================
function Matrix.Forensics.RegisterOrGetBallisticId(weaponSerial, weaponWear)
    if type(weaponSerial) ~= 'string' or weaponSerial == '' then return nil end
    weaponWear = Matrix.Clamp(tonumber(weaponWear) or 0.0, 0.0, 1.0)


    local cached = BallisticCache[weaponSerial]
    if cached then
        if cached.wear_level ~= weaponWear then
            cached.wear_level = weaponWear
            PendingWearUpdates[cached.ballistic_id] = weaponWear
        end
        return cached.ballistic_id
    end


    local ballisticId = ('BAL-%s-%06X'):format(
        weaponSerial:sub(-4),
        (GetGameTimer() + #weaponSerial) % 0xFFFFFF
    )


    BallisticCache[weaponSerial] = {
        ballistic_id = ballisticId,
        wear_level   = weaponWear
    }
    BallisticInsertOrder[#BallisticInsertOrder + 1] = weaponSerial


    MySQL.prepare([[
        INSERT INTO matrix_ballistic_weapons
            (ballistic_id, weapon_serial, wear_level, sealed_as_crime_weapon, first_registered)
        VALUES (?, ?, ?, 0, NOW())
        ON DUPLICATE KEY UPDATE wear_level = VALUES(wear_level)
    ]], { ballisticId, weaponSerial, weaponWear })


    -- [F1] Yeni satır eklendikten sonra üst sınır kontrolü.
    EvictBallisticCacheIfNeeded()


    Matrix.Log('FORENSICS', 'Yeni balistik imza: %s (Seri: %s)', ballisticId, weaponSerial)
    return ballisticId
end


-- =====================================================================
-- WEAPON FIRE SIMULATION
--
-- FORMÜL (Namlu Yiv-Set İmzası / kovan iz netliği):
--   Q_kovan_taban   = clamp(1.0 - weaponWear*CasingWearWeight - cortisol*CasingCortisolWeight, 0, 1)
--   Q_kovan         = clamp(Q_kovan_taban * weaponDurability, 0, 1)      [★ Katman 5 mutasyonu]
--   match_certainty = clamp(Q_kovan * BallisticStriationPrecision, 0, 1)
--   (match_certainty < LabBlindnessThreshold ise ★ üstel körlük uygulanır)
--   sealed_as_crime_weapon = match_certainty > MatchCertaintyThreshold
-- Yorum: iki bağımsız aşınma kaynağı (mekanik weaponWear, biyolojik cortisol)
-- doğrusal olarak Q_kovan_taban'dan çıkarılır; silahın KENDİ canı bunu
-- ÇARPIMSAL olarak mutasyona uğratır (weaponDurability=1.0 iken formül
-- ESKİSİYLE BİREBİR AYNIDIR — geriye dönük uyumlu). Tüm terimler [0,1]
-- aralığına clamp'lidir -> taşma/negatif olasılık riski yok. RNG YOK: aynı
-- (weaponWear, cortisol, weaponDurability) üçlüsü HER ZAMAN aynı
-- match_certainty'i üretir (tekrar edilebilirlik = test edilebilirlik).
-- KARMAŞIKLIK: O(1) - tek çağrıda sabit sayıda aritmetik işlem.
-- =====================================================================
function Matrix.Forensics.SimulateWeaponFire(actorRef, weaponSerial, weaponWear, evidenceType, weaponDurability)
    local actor = Matrix.ResolveActor(actorRef)
    if not actor then return nil end


    weaponWear       = Matrix.Clamp(tonumber(weaponWear) or 0.0, 0.0, 1.0)
    evidenceType     = evidenceType or 'casing'
    weaponDurability = Matrix.Clamp(tonumber(weaponDurability) or 1.0, 0.0, 1.0)


    local ballisticId = Matrix.Forensics.RegisterOrGetBallisticId(weaponSerial, weaponWear)
    if not ballisticId then return nil end


    local cortisol = GetActorCortisol(actor)
    local qKovanBase = Matrix.Clamp(
        1.0 - (weaponWear * Config.Forensics.CasingWearWeight)
            - (cortisol   * Config.Forensics.CasingCortisolWeight),
        0.0, 1.0
    )


    -- ★ GAUSS ÇEKİRDEĞİ MUTASYONU (bkz. dosya başı yorumu).
    local qKovan = Matrix.Clamp(qKovanBase * weaponDurability, 0.0, 1.0)


    local fingerprintQuality = Matrix.Forensics.ComputeFingerprintQuality(actor)
    local dnaId              = GetActorDnaId(actor)
    local matchCertainty     = Matrix.Clamp(qKovan * Config.BallisticStriationPrecision, 0.0, 1.0)


    -- ★ ADLİ LABORATUVAR KÖRLÜĞÜ: silah canı eşiğin altındaysa eşleşme
    -- kesinliği ÜSTEL olarak baltalanır (deficit büyüdükçe çöküş hızlanır).
    -- Eşiğin ÜSTÜNDEKİ silahlar için deficit<=0 -> çarpan=1 -> HİÇ etkisi yok.
    -- [F3] rate en az 1e-9'a sabitlenir (bkz. dosya başı dürüst açıklama:
    -- bu bir NaN riskini KAPATMIYOR, sadece niyeti açıkça ifade ediyor).
    if weaponDurability < Config.Forensics.WeaponDurabilityLabBlindnessThreshold then
        local deficit = Config.Forensics.WeaponDurabilityLabBlindnessThreshold - weaponDurability
        local rate    = math_max(Config.Forensics.WeaponDurabilityBlindnessDecayRate or 0.0, 1e-9)
        matchCertainty = Matrix.Clamp(matchCertainty * math_exp(-rate * deficit), 0.0, 1.0)
    end


    local sealed = matchCertainty > Config.Forensics.MatchCertaintyThreshold


    local stateCoords = actor.state and actor.state.coords
    local cx, cy, cz  = 0.0, 0.0, 0.0
    if stateCoords then cx, cy, cz = stateCoords.x, stateCoords.y, stateCoords.z end


    -- Lokal ID tahsis (async insert)
    local evidenceId = NextEvidenceId()


    if evidenceId then
        MySQL.prepare([[
            INSERT INTO matrix_forensic_evidence
                (id, ballistic_id, evidence_type, striation_quality, fingerprint_id, fingerprint_quality,
                 match_certainty, sealed_as_crime_weapon, coords_x, coords_y, coords_z, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
        ]], {
            evidenceId, ballisticId, evidenceType, qKovan, dnaId, fingerprintQuality,
            matchCertainty, sealed and 1 or 0, cx, cy, cz
        })
    else
        -- watermark henüz hazır değilse fallback async insert (id olmadan)
        MySQL.prepare([[
            INSERT INTO matrix_forensic_evidence
                (ballistic_id, evidence_type, striation_quality, fingerprint_id, fingerprint_quality,
                 match_certainty, sealed_as_crime_weapon, coords_x, coords_y, coords_z, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
        ]], {
            ballisticId, evidenceType, qKovan, dnaId, fingerprintQuality,
            matchCertainty, sealed and 1 or 0, cx, cy, cz
        })
    end


    if sealed then
        MySQL.prepare([[
            UPDATE matrix_ballistic_weapons
            SET sealed_as_crime_weapon = 1, seal_certainty = ?
            WHERE ballistic_id = ?
        ]], { matchCertainty, ballisticId })
        Matrix.Log('FORENSICS', '[MÜHÜRLENDI] %s suç aleti (%.4f)', ballisticId, matchCertainty)
    end


    return {
        evidence_id         = evidenceId or -1,
        ballistic_id        = ballisticId,
        dna_id              = dnaId,
        weapon_wear         = weaponWear,
        weapon_durability   = weaponDurability,
        striation_quality   = qKovan,
        fingerprint_quality = fingerprintQuality,
        match_certainty     = matchCertainty,
        sealed              = sealed,
        jam_chance          = Matrix.Forensics.ComputeJamChance(weaponDurability),
        hard_delete_risk    = Matrix.Forensics.GetHardDeleteRiskIfJammed(weaponDurability)
    }
end


-- ★ KATMAN 5: market.lua'nın undercover ajan tetiği için — bir alıcının
-- gizli ajan olduğu teslimat anında ANLAŞILDIĞINDA (bkz. market.lua
-- Matrix.Market.EvaluateSale) ilgili balistik kaydı otomatik %100
-- kesinlikle mühürlenir. RNG yok, tek bir deterministik DB yazımı.
function Matrix.Forensics.ForceSeal(ballisticId)
    if type(ballisticId) ~= 'string' or ballisticId == '' then return false end


    MySQL.prepare([[
        UPDATE matrix_ballistic_weapons
        SET sealed_as_crime_weapon = 1, seal_certainty = 1.0
        WHERE ballistic_id = ?
    ]], { ballisticId })


    Matrix.Log('FORENSICS', '[UNDERCOVER TETİĞİ] %s otomatik %%100 kesinlikle mühürlendi.', ballisticId)
    return true
end


-- =====================================================================
-- ★ KATMAN 5 ULTIMATE [U3]: TAM BALİSTİK ARŞİV SİLME (Namlu Değişimi)
-- /namludegistir tarafından çağrılır — hem RAM cache'inden hem de kalıcı
-- DB'den (matrix_ballistic_weapons + ona bağlı matrix_forensic_evidence
-- satırları) o silahın TÜM geçmişini kalıcı olarak siler. NOT: bu,
-- dosya başındaki "adli kayıt asla silinmez" politikasının BİLİNÇLİ tek
-- istisnasıdır — "namlu değiştirildiğinde Büro'nun geçmiş kaydı tamamen
-- silinir" doğrudan bu görevin gereğidir (kirli iş: gerçek bir suç
-- organizasyonunun namlu değiştirerek adli geçmişini yok etmesi).
-- =====================================================================
function Matrix.Forensics.WipeBallisticRecord(weaponSerial)
    if type(weaponSerial) ~= 'string' or weaponSerial == '' then return false end


    local cached = BallisticCache[weaponSerial]
    local ballisticId = cached and cached.ballistic_id


    BallisticCache[weaponSerial] = nil
    -- BallisticInsertOrder'daki referans bir sonraki EvictBallisticCacheIfNeeded
    -- çağrısında doğal olarak temizlenir (nil-guard zaten mevcut).


    if not ballisticId then return true end


    PendingWearUpdates[ballisticId] = nil
    WearRetryQueue[ballisticId] = nil


    MySQL.prepare('DELETE FROM matrix_forensic_evidence WHERE ballistic_id = ?', { ballisticId })
    MySQL.prepare('DELETE FROM matrix_ballistic_weapons WHERE ballistic_id = ?', { ballisticId })


    Matrix.Log('FORENSICS', '[BURO KORLESTIRILDI] Namlu degisimi: %s balistik kaydi tamamen silindi.', ballisticId)
    return true
end


-- =====================================================================
-- ★ KATMAN 5 ULTIMATE [U3]: GERÇEK-ZAMANLI ATIŞ İŞLEME (Mekanik Tutukluk)
-- client/hud.lua'daki mermi-sayısı-azalma tespiti (ammo-delta polling,
-- IsPedShooting yerine — tam/otomatik ateş serilerinde daha güvenilir)
-- her atışta 'matrix:server:reportWeaponShotFired' tetikler; bu da bu
-- fonksiyona iner. Mevcut kovan-tabanlı OnWeaponFired/SimulateWeaponFire
-- akışına (ayrı bir fiziksel kovan nesnesi toplanmasını gerektirir) HİÇ
-- DOKUNMAZ — yalnızca o akışın okuduğu `durability` metadata alanını
-- gerçek-zamanlı olarak günceller (bir sonraki kovan tabanlı analizde
-- GetWeaponDurability zaten en güncel değeri okuyacaktır).
-- =====================================================================
function Matrix.Forensics.OnWeaponShotFired(actorRef, weaponItemName, weaponSerial, weaponInventoryId, weaponSlot)
    if not weaponInventoryId or type(weaponSlot) ~= 'number' then return nil, 'bad_slot' end
    if type(weaponSerial) ~= 'string' or weaponSerial == '' then return nil, 'bad_serial' end


    local meta = Matrix.Inventory.GetSlotMetadata(weaponInventoryId, weaponSlot)
    if meta.jammed then return nil, 'already_jammed' end


    local shotsFired = (tonumber(meta.shots_fired) or 0) + 1
    local lifespan    = Matrix.Forensics.GetWeaponShotLifespan(weaponItemName)
    local durability  = Matrix.Clamp(100.0 * (1.0 - (shotsFired / lifespan)), 0.0, 100.0)


    local jamProbability = Matrix.Forensics.ComputeMechanicalJamProbability(durability)


    -- ★ 0 RNG DETERMİNİSTİK TUTUKLUK (bkz. dosya başı [U3] açıklaması):
    -- olasılık değeri bir biriktiriciye eklenir; biriktirici 1.0'i
    -- geçtiği AN tutukluk KESİN tetiklenir, taşan kısım bir sonraki atışa
    -- devreder. Aynı atış dizisi HER ZAMAN aynı tutukluk anını üretir.
    local accumulator = (tonumber(meta.jam_accumulator) or 0.0) + jamProbability
    local jammed = false
    if accumulator >= 1.0 then
        jammed = true
        accumulator = accumulator - 1.0
    end


    Matrix.Inventory.MergeMetadata(weaponInventoryId, weaponSlot, {
        weapon_serial   = weaponSerial,
        shots_fired     = shotsFired,
        durability      = durability,
        jam_accumulator = accumulator,
        jammed          = jammed
    })


    return {
        durability      = durability,
        jam_probability = jamProbability,
        jammed          = jammed,
        shots_fired     = shotsFired
    }
end


--- ★ KATMAN 5 ULTIMATE [U3]: 'X' tuşu / F10 "Sıkışan Silahı Tahliye Et"
--- (6 saniyelik lib.progressCircle, client/hud.lua) tamamlandığında
--- çağrılır. jam_accumulator BİLİNÇLİ OLARAK SIFIRLANMAZ — risk namlu
--- değişene kadar (/namludegistir) yüksek kalmaya devam eder; yalnızca
--- ANLIK tutukluk (jammed) kaldırılır, silah tekrar ateşlenebilir olur.
function Matrix.Forensics.ClearMechanicalJam(weaponInventoryId, weaponSlot)
    if not weaponInventoryId or type(weaponSlot) ~= 'number' then return false end
    local meta = Matrix.Inventory.GetSlotMetadata(weaponInventoryId, weaponSlot)
    if not meta.jammed then return false end


    Matrix.Inventory.MergeMetadata(weaponInventoryId, weaponSlot, { jammed = false })
    return true
end


-- =====================================================================
-- ADLİ KRİMİNAL RAPORU (ASCII, askeri evrak formatı) - ox_inventory
-- item.metadata.description alanına basılır, tooltip'te gösterilir.
-- =====================================================================
local REPORT_WIDTH = 36
local REPORT_BORDER = ('='):rep(REPORT_WIDTH)
local REPORT_DIVIDER = ('-'):rep(REPORT_WIDTH)


local function ReportLine(label, value)
    return ('%-13s: %s'):format(label, tostring(value))
end


function Matrix.Forensics.BuildForensicReport(data)
    local lines = {
        REPORT_BORDER,
        '     ADLI KRIMINAL RAPORU',
        REPORT_DIVIDER,
        ReportLine('BALISTIK ID', data.ballistic_id or 'BILINMIYOR'),
        ReportLine('KANIT TIPI', data.evidence_type or 'casing'),
        ReportLine('STRIASYON', ('%.3f'):format(data.striation_quality or 0.0)),
        ReportLine('PARMAK IZI', data.fingerprint_id or 'BILINMIYOR'),
        ReportLine('IZ NETLIGI', ('%.3f'):format(data.fingerprint_quality or 0.0)),
        ReportLine('ESLESME', ('%.3f'):format(data.match_certainty or 0.0)),
        ReportLine('MUHUR', data.sealed and 'MUHURLENDI' or 'MUHURLENMEDI')
    }


    -- ★ Katman 5: sadece çağıran taraf weapon_durability sağladıysa eklenir
    -- (geriye dönük uyumluluk — eski/DB'den yeniden üretilen raporlar bu
    -- alanı hiç geçmez ve çıktı ESKİSİYLE BİREBİR AYNI kalır).
    if data.weapon_durability ~= nil then
        lines[#lines + 1] = ReportLine('SILAH CANI', ('%.1f%%'):format(data.weapon_durability * 100.0))
        lines[#lines + 1] = ReportLine('TUTUKLUK RISKI', ('%.3f'):format(data.jam_chance or 0.0))
    end


    lines[#lines + 1] = REPORT_DIVIDER
    lines[#lines + 1] = ReportLine('KAYIT', os.date('%Y-%m-%d %H:%M:%S'))
    lines[#lines + 1] = REPORT_BORDER


    return table.concat(lines, '\n')
end


function Matrix.Forensics.OnWeaponFired(actorRef, weaponSerial, casingInventoryId, casingSlot, weaponInventoryId, weaponSlot)
    if not casingInventoryId or type(casingSlot) ~= 'number' then return nil end


    local casingMeta = Matrix.Inventory.GetSlotMetadata(casingInventoryId, casingSlot)
    local durability = tonumber(casingMeta.durability) or 100.0
    durability = Matrix.Clamp(durability, 0.0, 100.0)
    local weaponWear = Matrix.Clamp(1.0 - (durability / 100.0), 0.0, 1.0)


    -- ★ Katman 5: bu, kovanın KENDİ aşınması (weaponWear) İLE AYNI ŞEY
    -- DEĞİLDİR — silahın (weaponInventoryId/weaponSlot) kendi canıdır.
    local weaponDurability = GetWeaponDurability(weaponInventoryId, weaponSlot)


    local result = Matrix.Forensics.SimulateWeaponFire(actorRef, weaponSerial, weaponWear, 'casing', weaponDurability)
    if not result then return nil end


    local report = Matrix.Forensics.BuildForensicReport({
        ballistic_id        = result.ballistic_id,
        evidence_type        = 'casing',
        striation_quality    = result.striation_quality,
        fingerprint_id        = result.dna_id,
        fingerprint_quality  = result.fingerprint_quality,
        match_certainty      = result.match_certainty,
        sealed                = result.sealed
    })


    Matrix.Inventory.MergeMetadata(casingInventoryId, casingSlot, {
        ballistic_id       = result.ballistic_id,
        striation_quality  = result.striation_quality,
        fingerprint_id     = result.dna_id,
        fingerprint_quality= result.fingerprint_quality,
        description        = report
    })


    -- Silahın kendisi de (kovan değil) incelendiğinde aynı adli özet görünsün.
    if weaponInventoryId and type(weaponSlot) == 'number' then
        Matrix.Inventory.MergeMetadata(weaponInventoryId, weaponSlot, {
            ballistic_id      = result.ballistic_id,
            weapon_wear       = result.weapon_wear,
            weapon_durability = result.weapon_durability,
            jam_chance        = result.jam_chance,
            description       = Matrix.Forensics.BuildForensicReport({
                ballistic_id         = result.ballistic_id,
                evidence_type         = 'weapon',
                striation_quality     = result.striation_quality,
                fingerprint_id         = result.dna_id,
                fingerprint_quality   = result.fingerprint_quality,
                match_certainty       = result.match_certainty,
                sealed                 = result.sealed,
                weapon_durability     = result.weapon_durability,
                jam_chance             = result.jam_chance
            })
        })
    end


    return result.evidence_id, result.match_certainty, result.sealed, result.jam_chance, result.hard_delete_risk
end


-- =====================================================================
-- TOUCH STAMP
-- =====================================================================
function Matrix.Forensics.StampTouch(actorRef, inventoryId, slot)
    local actor = Matrix.ResolveActor(actorRef)
    if not actor then return nil end
    if not inventoryId or type(slot) ~= 'number' then return nil end


    local q  = Matrix.Forensics.ComputeFingerprintQuality(actor)
    local dna= GetActorDnaId(actor)


    Matrix.Inventory.MergeMetadata(inventoryId, slot, {
        fingerprint_id      = dna,
        fingerprint_quality = q
    })


    MySQL.prepare([[
        INSERT INTO matrix_touch_log
            (fingerprint_id, fingerprint_quality, inventory_id, slot_id, created_at)
        VALUES (?, ?, ?, ?, NOW())
    ]], { dna, q, tostring(inventoryId), slot })


    return q
end


-- =====================================================================
-- LAB ANALYSIS
-- =====================================================================
function Matrix.Forensics.AnalyzeEvidence(evidenceId)
    if type(evidenceId) ~= 'number' then return nil end


    local rows = MySQL.query.await('SELECT * FROM matrix_forensic_evidence WHERE id = ?', { evidenceId })
    local evidence = rows and rows[1]
    if not evidence then return nil end


    local q        = Matrix.Clamp(tonumber(evidence.striation_quality) or 0.0, 0.0, 1.0)
    local match    = Matrix.Clamp(q * Config.BallisticStriationPrecision, 0.0, 1.0)
    local sealed   = match > Config.Forensics.MatchCertaintyThreshold


    MySQL.prepare([[
        UPDATE matrix_forensic_evidence
        SET match_certainty = ?, sealed_as_crime_weapon = ?
        WHERE id = ?
    ]], { match, sealed and 1 or 0, evidenceId })


    if sealed then
        MySQL.prepare([[
            UPDATE matrix_ballistic_weapons
            SET sealed_as_crime_weapon = 1, seal_certainty = ?
            WHERE ballistic_id = ?
        ]], { match, evidence.ballistic_id })
        Matrix.Log('FORENSICS', 'Lab: kanıt #%d -> %s mühürlendi (%.4f)', evidenceId, evidence.ballistic_id, match)
    else
        Matrix.Log('FORENSICS', 'Lab: kanıt #%d yetersiz eşleşme (%.4f)', evidenceId, match)
    end


    return match, sealed
end


-- =====================================================================
-- WEAR FLUSH (ticker zamanlı, ana ticker'a yük olmasın diye ayrı thread)
-- [F2] Başarısız yazımlar WearRetryQueue'ya düşer, bir sonraki tick'te
-- öncelikli olarak tekrar denenir (kayıp yok, bindirme yok).
-- =====================================================================
CreateThread(function()
    while true do
        Wait(20000)


        for bid, wear in pairs(WearRetryQueue) do
            PendingWearUpdates[bid] = wear
            WearRetryQueue[bid] = nil
        end


        for bid, wear in pairs(PendingWearUpdates) do
            PendingWearUpdates[bid] = nil
            local ok = pcall(function()
                MySQL.prepare('UPDATE matrix_ballistic_weapons SET wear_level = ? WHERE ballistic_id = ?', { wear, bid })
            end)
            if not ok then
                WearRetryQueue[bid] = wear
            end
        end
    end
end)


-- =====================================================================
-- EVENT BRIDGE (guard'lı)
-- =====================================================================
RegisterNetEvent('matrix:server:reportWeaponDischarge', function(weaponSerial, casingInventoryId, casingSlot, weaponInventoryId, weaponSlot)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(weaponSerial) ~= 'string' or #weaponSerial == 0 or #weaponSerial > 64 then return end
    if type(casingInventoryId) ~= 'string' or type(casingSlot) ~= 'number' then return end
    if weaponInventoryId ~= nil and type(weaponInventoryId) ~= 'string' then weaponInventoryId = nil end
    if type(weaponSlot) ~= 'number' then weaponSlot = nil end
    local ok, err = pcall(Matrix.Forensics.OnWeaponFired, { kind = 'player', source = src }, weaponSerial, casingInventoryId, casingSlot, weaponInventoryId, weaponSlot)
    if not ok then Matrix.Log('FORENSICS', '[HATA] reportWeaponDischarge basarisiz (yutuldu): %s', tostring(err)) end
end)


RegisterNetEvent('matrix:server:reportObjectTouch', function(inventoryId, slot)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(inventoryId) ~= 'string' or type(slot) ~= 'number' then return end
    local ok, err = pcall(Matrix.Forensics.StampTouch, { kind = 'player', source = src }, inventoryId, slot)
    if not ok then Matrix.Log('FORENSICS', '[HATA] reportObjectTouch basarisiz (yutuldu): %s', tostring(err)) end
end)


-- ★ KATMAN 5 ULTIMATE [U3]: gerçek-zamanlı atış bildirimi. weaponSerial
-- İSTEMCİDEN GÜVENİLMEZ — sunucu, gönderilen slot'un KENDİ metadata'sından
-- weapon_serial'i okuyup kullanır (bütünlük garantisi). Seri numarası
-- taşımayan bir silah (karaborsa/adli sistemden hiç geçmemiş) bu event
-- tarafından İZLENMEZ.
RegisterNetEvent('matrix:server:reportWeaponShotFired', function(weaponItemName, weaponSlot)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(weaponItemName) ~= 'string' or #weaponItemName == 0 or #weaponItemName > 64 then return end
    if type(weaponSlot) ~= 'number' then return end


    local weaponInventoryId = tostring(src)
    local meta = Matrix.Inventory.GetSlotMetadata(weaponInventoryId, weaponSlot)
    local weaponSerial = meta.weapon_serial
    if type(weaponSerial) ~= 'string' or weaponSerial == '' then return end


    local ok, result = pcall(Matrix.Forensics.OnWeaponShotFired,
        { kind = 'player', source = src }, weaponItemName, weaponSerial, weaponInventoryId, weaponSlot)
    if not ok then
        Matrix.Log('FORENSICS', '[HATA] reportWeaponShotFired basarisiz (yutuldu): %s', tostring(result))
        return
    end


    if type(result) == 'table' and result.jammed then
        TriggerClientEvent('matrix:client:weaponJamStateChanged', src, weaponSlot, true)
        Matrix.Log('FORENSICS', '[MEKANIK TUTUKLUK] src=%d slot=%d silah=%s durability=%.1f%% jam_p=%.3f',
            src, weaponSlot, weaponItemName, result.durability, result.jam_probability)
    end
end)


-- ★ KATMAN 5 ULTIMATE [U3]: 'X' tuşu / F10 tahliye progressCircle
-- tamamlandığında client bunu tetikler. jam_accumulator SIFIRLANMAZ (bkz.
-- Matrix.Forensics.ClearMechanicalJam yorumu) — risk namlu değişene kadar
-- yüksek kalır.
RegisterNetEvent('matrix:server:clearWeaponJam', function(weaponSlot)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(weaponSlot) ~= 'number' then return end


    local weaponInventoryId = tostring(src)
    local ok, cleared = pcall(Matrix.Forensics.ClearMechanicalJam, weaponInventoryId, weaponSlot)
    if not ok then
        Matrix.Log('FORENSICS', '[HATA] clearWeaponJam basarisiz (yutuldu): %s', tostring(cleared))
        return
    end
    if cleared then
        TriggerClientEvent('matrix:client:weaponJamStateChanged', src, weaponSlot, false)
        Matrix.Log('FORENSICS', '[TUTUKLUK GIDERILDI] src=%d slot=%d (risk namlu degisene kadar yuksek kalir).', src, weaponSlot)
    end
end)


-- =====================================================================
-- ★ KATMAN 5 ULTIMATE [U3]: /namludegistir — YEDEK NAMLU DEĞİŞİMİ
-- server/blackmarket.lua'nın sattığı Config.BlackMarket.SpareBarrelItem'ı
-- tüketir; silahı fabrika ayarlarına (durability=100, shots_fired=0,
-- jam_accumulator=0, jammed=false) döndürür VE eski seri numarasının
-- TÜM balistik/adli kaydını (WipeBallisticRecord) kalıcı olarak siler —
-- "Büro tamamen kör edilir". Yeni bir weapon_serial atanır (server/
-- blackmarket.lua ile AYNI deterministik/RNG'siz üretim şemasını kullanır).
-- =====================================================================
RegisterCommand('namludegistir', function(src, args)
    local weaponSlot = tonumber(args[1])
    if type(src) ~= 'number' or src <= 0 or not weaponSlot then
        if type(src) == 'number' and src > 0 then
            TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', 'Kullanim: /namludegistir [silahSlotu] (F10 menusunden kullanin)' } })
        end
        return
    end


    local weaponInventoryId = tostring(src)
    local ok, weaponItem = pcall(exports['ox_inventory'].GetSlot, exports['ox_inventory'], weaponInventoryId, weaponSlot)
    if not ok or type(weaponItem) ~= 'table' or type(weaponItem.name) ~= 'string' then
        TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', 'Belirtilen slotta silah bulunamadi.' } })
        return
    end


    if not (Config.BlackMarket and Config.BlackMarket.ReplaceableWeaponItems and Config.BlackMarket.ReplaceableWeaponItems[weaponItem.name]) then
        TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', 'Bu silah turu icin namlu degisimi desteklenmiyor.' } })
        return
    end


    local barrelItem = Config.BlackMarket and Config.BlackMarket.SpareBarrelItem
    if not barrelItem then
        TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', 'Yedek Namlu sistemi yapilandirilmamis.' } })
        return
    end


    local countOk, barrelCount = pcall(exports['ox_inventory'].Search, exports['ox_inventory'], weaponInventoryId, 'count', barrelItem)
    barrelCount = (countOk and tonumber(barrelCount)) or 0
    if barrelCount < 1 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', 'Yedek Namlu bulunamadi. Once Karaborsa Ticaret Agi uzerinden satin alin.' } })
        return
    end


    local removeOk = pcall(function()
        return exports['ox_inventory']:RemoveItem(weaponInventoryId, barrelItem, 1)
    end)
    if not removeOk then
        TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', 'Yedek Namlu tuketilemedi.' } })
        return
    end


    local oldMeta   = weaponItem.metadata or {}
    local oldSerial = oldMeta.weapon_serial


    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = (state and state.citizenid) or ('SRC-%d'):format(src)


    local newSerial
    if Matrix.BlackMarket and Matrix.BlackMarket.GenerateWeaponSerial then
        newSerial = Matrix.BlackMarket.GenerateWeaponSerial(citizenid, weaponItem.name)
    else
        newSerial = ('BM-%s-%07X'):format(weaponItem.name:sub(-6):upper(), (GetGameTimer() + weaponSlot) % 0xFFFFFFF)
    end


    if type(oldSerial) == 'string' and oldSerial ~= '' then
        pcall(Matrix.Forensics.WipeBallisticRecord, oldSerial)
    end


    Matrix.Inventory.MergeMetadata(weaponInventoryId, weaponSlot, {
        weapon_serial   = newSerial,
        shots_fired     = 0,
        durability      = 100.0,
        jam_accumulator = 0.0,
        jammed          = false,
        description     = '[YENI NAMLU TAKILDI]\nBuro balistik arsivi tamamen silindi.'
    })


    TriggerClientEvent('matrix:client:weaponJamStateChanged', src, weaponSlot, false)
    TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', '[NAMLU DEGISTIRILDI] Buro balistik arsivi tamamen kor edildi. Silah fabrika ayarlarina donduruldu.' } })
    Matrix.Log('FORENSICS', '[NAMLU DEGISIMI] src=%d silah=%s eski-seri=%s yeni-seri=%s', src, weaponItem.name, tostring(oldSerial), newSerial)
end, false)


-- =====================================================================
-- MONOKROM TAKTİK DEBUG PANELİ (herkese açık test grubu, restricted=false)
-- Q_kovan = 1.0 - (weaponWear*0.3) - (cortisol*0.2) ve fingerprint = 1.0 -
-- (cortisol*0.4) formüllerini gerçek bir ateşleme olayı beklemeden manuel
-- gözlemlemek/manipüle etmek için. Hiçbir komut formülün KENDİSİNİ değiştirmez.
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', msg } })
    else
        print(('[MATRIX:FORENSICS:CONSOLE] %s'):format(msg))
    end
end


-- /forensicdump [ballisticId] - bir silahın kalıcı SQL kaydını ve ona bağlı
-- en yeni 10 kanıt satırını (matrix_forensic_evidence, asla silinmez) döker.
RegisterCommand('forensicdump', function(src, args)
    local ballisticId = args[1]
    if type(ballisticId) ~= 'string' then Reply(src, 'Kullanim: /forensicdump [ballisticId]'); return end


    local weaponRows = MySQL.query.await('SELECT * FROM matrix_ballistic_weapons WHERE ballistic_id = ?', { ballisticId }) or {}
    local weapon = weaponRows[1]
    if not weapon then Reply(src, 'Balistik ID bulunamadı.'); return end


    Reply(src, ('Silah: %s | Seri:%s | Aşınma:%.3f | Mühür:%s | Kesinlik:%s'):format(
        weapon.ballistic_id, weapon.weapon_serial, weapon.wear_level,
        tostring(weapon.sealed_as_crime_weapon == 1), tostring(weapon.seal_certainty)))


    local evidenceRows = MySQL.query.await(
        'SELECT * FROM matrix_forensic_evidence WHERE ballistic_id = ? ORDER BY id DESC LIMIT 10', { ballisticId }
    ) or {}
    Reply(src, ('--- %d kanıt satırı (en yeni 10) ---'):format(#evidenceRows))
    for _, ev in ipairs(evidenceRows) do
        Reply(src, ('  #%d [%s] Striasyon:%.3f Eşleşme:%.3f Mühür:%s'):format(
            ev.id, ev.evidence_type, ev.striation_quality, ev.match_certainty, tostring(ev.sealed_as_crime_weapon == 1)))
    end
end, false)


-- /forensicrapor [evidenceId] - kalıcı kanıt satırından ASCII "Adli Kriminal
-- Raporu"nu yeniden üretip konsola basar (BuildForensicReport'un gerçek DB
-- verisiyle tekrar üretilebilir/deterministik olduğunu doğrular).
RegisterCommand('forensicrapor', function(src, args)
    local evidenceId = tonumber(args[1])
    if not evidenceId then Reply(src, 'Kullanim: /forensicrapor [evidenceId]'); return end


    local rows = MySQL.query.await('SELECT * FROM matrix_forensic_evidence WHERE id = ?', { evidenceId })
    local evidence = rows and rows[1]
    if not evidence then Reply(src, 'Kanıt bulunamadı.'); return end


    local report = Matrix.Forensics.BuildForensicReport({
        ballistic_id         = evidence.ballistic_id,
        evidence_type        = evidence.evidence_type,
        striation_quality    = evidence.striation_quality,
        fingerprint_id       = evidence.fingerprint_id,
        fingerprint_quality  = evidence.fingerprint_quality,
        match_certainty      = evidence.match_certainty,
        sealed               = evidence.sealed_as_crime_weapon == 1
    })
    print(report)
    Reply(src, ('Kanıt #%d raporu konsola basıldı.'):format(evidenceId))
end, false)


-- /asinmaayarla [seri] [0.0-1.0] - weapon_wear'ı gerçek bir ateşleme
-- döngüsünü (RegisterOrGetBallisticId) beklemeden doğrudan yazar; Q_kovan
-- formülünün weaponWear ekseni boyunca davranışını test etmek içindir.
RegisterCommand('asinmaayarla', function(src, args)
    local serial = args[1]
    local wear = Matrix.Clamp(tonumber(args[2]) or 0.0, 0.0, 1.0)
    if type(serial) ~= 'string' then Reply(src, 'Kullanim: /asinmaayarla [seri] [0.0-1.0]'); return end


    local cached = BallisticCache[serial]
    if not cached then Reply(src, 'Bu seri henüz balistik olarak kayıtlı değil (önce ateşlenmeli).'); return end


    cached.wear_level = wear
    MySQL.prepare('UPDATE matrix_ballistic_weapons SET wear_level = ? WHERE weapon_serial = ?', { wear, serial })
    Reply(src, ('%s aşınması %.3f olarak ayarlandı.'):format(serial, wear))
end, false)


-- ★ KATMAN 5 debug komutu: /silahasindir [slot] [miktar 0-100] - çağıran
-- oyuncunun KENDİ envanterindeki [slot]'taki silahın ox_inventory durability
-- metadata'sını doğrudan yazar (gerçek bir çatışma/aşınma döngüsü beklemeden
-- Gauss mutasyon formülünü test etmek içindir). Bir sonraki ateşlemede
-- OnWeaponFired bu değeri okuyup Q_kovan'ı mutasyona uğratır.
RegisterCommand('silahasindir', function(src, args)
    local slot = tonumber(args[1])
    local amount = Matrix.Clamp(tonumber(args[2]) or 100.0, 0.0, 100.0)
    if type(src) ~= 'number' or src <= 0 or not slot then
        Reply(src, 'Kullanim: /silahasindir [slot] [miktar 0-100]'); return
    end


    -- ox_inventory: oyuncu envanteri event köprüsündeki diğer inventoryId'ler
    -- gibi string olarak ele alınır (bkz. reportWeaponDischarge guard'ı).
    local inventoryId = tostring(src)
    Matrix.Inventory.MergeMetadata(inventoryId, slot, { durability = amount })


    Reply(src, ('Slot #%d silah canı %.1f olarak ayarlandı (Jam_Chance:%.3f). Bir sonraki ateşlemede Q_kovan mutasyona uğrayacak.'):format(
        slot, amount, Matrix.Forensics.ComputeJamChance(amount / 100.0)))
end, false)


-- [F5] /balistikcache - LRU/retry kuyruklarının anlık RAM boyutlarını gösterir.
RegisterCommand('balistikcache', function(src)
    local n = 0
    for _ in pairs(BallisticCache) do n = n + 1 end
    local pn = 0
    for _ in pairs(PendingWearUpdates) do pn = pn + 1 end
    local rn = 0
    for _ in pairs(WearRetryQueue) do rn = rn + 1 end


    Reply(src, ('BallisticCache: %d/%d | InsertOrder:%d | PendingWear:%d | WearRetry:%d'):format(
        n, BALLISTIC_CACHE_MAX, #BallisticInsertOrder, pn, rn))
end, false)


-- =====================================================================
-- ★★★ KATMAN 7 FAZ 2: REAL-TIME ÜST ARAMA / ÇEVİRME ★★★
-- Bu dosyanın YUKARIDAKİ hiçbir balistik/kovan/mekanik-tutukluk formülüne
-- DOKUNULMADI -- burası TAMAMEN AYRI, ek bir kontrabant tarama/el koyma
-- katmanıdır. İKİ giriş noktası paylaşılan aynı tarama/el-koyma çiftini
-- (ScanInventoryContraband/SeizeContraband) kullanır:
--   1) Matrix.Forensics.InspectBustedBot -- server/main.lua'nın ZATEN VAR
--      OLAN DISPATCH_BUSTED_* dwell mekaniğinin (main.lua'da DEĞİŞTİRİLMEDİ)
--      DOĞAL SONUCU olarak Matrix.CompleteDispatch'in 'busted' dalından
--      çağrılır (bkz. main.lua dosya başı FAZ 2 notu) -- bota AYRI bir
--      taşıma/dwell thread'i İCAT EDİLMEZ.
--   2) Matrix.Forensics.InspectPlayer -- GERÇEK oyuncular için, aşağıdaki
--      YENİ 8m/6sn dwell thread'i tarafından tetiklenir (botların aksine
--      oyuncuların kendi "yakalanma" mekaniği yoktur, bu yüzden burada
--      genuinely yeni, küçük bir tarama thread'i gerekir).
--
-- KONTRABANT TÜRLERİ (hepsi mevcut alanları okur, yeni bir alan İCAT
-- EDİLMEZ):
--   - Silah: metadata.weapon_serial, Config.Forensics.Frisk.
--     WeaponSerialContrabandPrefix ('BM-') ile başlıyorsa -- server/
--     blackmarket.lua Matrix.BlackMarket.GenerateWeaponSerial İLE AYNI format.
--   - Açık Hat (burner phone): metadata.imei_masked + metadata.acquired_at
--     (server/blackmarket.lua bu satırda [KATMAN 7 FAZ 2] eklendi), tutma
--     süresi BurnerPhoneMaxHoldSeconds'ı aşıyorsa.
--   - Uyuşturucu: metadata.purity, Config.Market.GourmetMinPurity (MEVCUT,
--     DEĞİŞTİRİLMEDİ) altındaysa -- server/kitchen.lua Matrix.Kitchen.
--     PackageBatch'in ürettiği meth_bag/coke_brick.
--   - Araç: Matrix.Fleet.GetVehicle(plate).vin_status == 'scratched' (veya
--     verified_stolen_plate) -- server/logistics.lua, DEĞİŞTİRİLMEDİ.
--
-- El koyma, MEVCUT üç fonksiyonu yeniden kullanır (YENİ bir el koyma
-- formülü İCAT EDİLMEZ): ox_inventory:RemoveItem (silah/telefon/uyuşturucu),
-- Matrix.Forensics.WipeBallisticRecord (silah balistik kaydı, yukarıda,
-- DEĞİŞTİRİLMEDİ), Matrix.Fleet.SeizeVehicle (araç, server/logistics.lua,
-- DEĞİŞTİRİLMEDİ). Bulgu varsa, "delil indeksi zıplaması"
-- Matrix.Bureau.AdvanceDecryption'a (MEVCUT deşifre motoru, DEĞİŞTİRİLMEDİ)
-- Config.Forensics.Frisk.EvidenceIndexJumpRatio (%20) sabit kazancıyla
-- yansıtılır -- yeni bir ihbar tablosu İCAT EDİLMEZ.
--
-- SIFIR RNG: tüm eşikler sabit karşılaştırmalardır. 0 RESMON: oyuncu
-- tarama thread'i main.lua/market.lua'nın polis-önbelleği İLE AYNI 5sn
-- yenileme + 1sn dwell-poll disiplinini izler (Wait(0) YOK).
-- =====================================================================
local function IsPackagedProduct(itemName)
    for _, product in ipairs(Config.Kitchen.Packaging.Products) do
        if product.item == itemName then return true end
    end
    return false
end


-- ★ [MADDE 5b] Her bulguya KENDİ kaynak envanterini (inventory_id) damgalar
-- -- InspectPlayer/InspectBustedBot artık İKİ ayrı envanteri (üst/kişisel +
-- bagaj) TEK bir findings listesinde birleştirebiliyor (bkz. aşağıda),
-- SeizeContraband bu yüzden inventoryId'yi ayrı parametre olarak DEĞİL,
-- finding'in kendisinden okur.
local function ScanInventoryContraband(inventoryId)
    local findings = {}
    local invOk, inv = pcall(function() return exports['ox_inventory']:GetInventory(inventoryId) end)
    if not invOk or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return findings end


    local now = Matrix.Now()
    for slot, item in pairs(inv.items) do
        if type(item) == 'table' and type(item.name) == 'string' then
            local meta = item.metadata or {}
            if type(meta.weapon_serial) == 'string'
                and meta.weapon_serial:sub(1, #Config.Forensics.Frisk.WeaponSerialContrabandPrefix) == Config.Forensics.Frisk.WeaponSerialContrabandPrefix then
                findings[#findings + 1] = { kind = 'weapon', inventory_id = inventoryId, slot = slot, item = item.name, count = tonumber(item.count) or 1, serial = meta.weapon_serial }
            elseif meta.imei_masked == true and type(meta.acquired_at) == 'number'
                and (now - meta.acquired_at) > Config.Forensics.Frisk.BurnerPhoneMaxHoldSeconds then
                findings[#findings + 1] = { kind = 'burner_phone', inventory_id = inventoryId, slot = slot, item = item.name, count = tonumber(item.count) or 1 }
            elseif IsPackagedProduct(item.name) and type(meta.purity) == 'number'
                and meta.purity < Config.Market.GourmetMinPurity then
                findings[#findings + 1] = { kind = 'drugs', inventory_id = inventoryId, slot = slot, item = item.name, count = tonumber(item.count) or 1 }
            end
        end
    end
    return findings
end


-- ★ [MADDE 5b] BAGAJ RÖNTGENİ: server/logistics.lua'nın bota KALICI atanmış
-- aracın bagajı için AÇTIĞI AYNI ox_inventory stash'i (Config.Logistics.
-- TrunkOps.StashPrefix .. plaka, DEĞİŞTİRİLMEDİ) — ikinci bir bagaj sistemi
-- İCAT EDİLMEZ. RegisterStash, GetInventory'den ÖNCE tekrar çağrılır (best-
-- effort/pcall) çünkü bagaj bu oturumda hiç kullanılmamışsa ox_inventory'nin
-- stash'i henüz tanımıyor olabilir — logistics.lua'nın kendi yazma yolundaki
-- İLE AYNI disiplin. Plaka Matrix.Fleet'e kayıtlı DEĞİLSE (oyuncunun kendi
-- özel aracı vb.) hiçbir şey taranmaz -- bu sistem yalnızca filo/kurye
-- araçlarının bagajından sorumludur.
local function ScanTrunkContraband(plate)
    if type(plate) ~= 'string' or plate == '' then return {} end
    if not (Matrix.Fleet and Matrix.Fleet.GetVehicle and Matrix.Fleet.GetVehicle(plate)) then return {} end

    local trunkId = Config.Logistics.TrunkOps.StashPrefix .. plate
    pcall(function()
        exports['ox_inventory']:RegisterStash(trunkId, ('%s Bagaji'):format(plate),
            Config.Logistics.TrunkOps.Slots, Config.Logistics.TrunkOps.MaxWeight)
    end)
    return ScanInventoryContraband(trunkId)
end


local function SeizeContraband(finding, dnaId)
    if finding.kind == 'vehicle' then
        pcall(function() Matrix.Fleet.SeizeVehicle(finding.plate, 'frisk_search', dnaId, nil) end)
        return
    end


    pcall(function()
        exports['ox_inventory']:RemoveItem(finding.inventory_id, finding.item, finding.count, nil, finding.slot)
    end)


    if finding.kind == 'weapon' and Matrix.Forensics.WipeBallisticRecord then
        Matrix.Forensics.WipeBallisticRecord(finding.serial)
    end
end


local function FindNearestTrapHouseForFrisk(coords)
    local nearestId, nearestDist = nil, math.huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        local d = #(coords - house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId
end


-- ★ Bota kalıcı atanmış aracın plakası (varsa) da taranır -- server/
-- logistics.lua Matrix.Fleet.GetVehicleByBot'a İHTİYAÇ YOKTUR: main.lua
-- dispatch'in KENDİ dispatch.plate alanı zaten doğrudan parametre olarak
-- gelir (bkz. main.lua dosya başı FAZ 2 notu).
function Matrix.Forensics.InspectBustedBot(botId, trapHouseId, plate)
    local bot = Matrix.Bots[botId]
    if not bot then return false end


    local inventoryId = ('dealer_%d'):format(botId)
    local findings = ScanInventoryContraband(inventoryId)


    if type(plate) == 'string' and plate ~= '' then
        local vehicle = Matrix.Fleet and Matrix.Fleet.GetVehicle and Matrix.Fleet.GetVehicle(plate)
        if vehicle and (vehicle.vin_status == 'scratched' or vehicle.verified_stolen_plate) then
            findings[#findings + 1] = { kind = 'vehicle', plate = plate }
        end

        -- ★ [MADDE 5b] BAGAJ RÖNTGENİ: dealer_<botId> ÜZERİNDEKİ envanterden
        -- AYRI, aracın kendi bagaj stash'i.
        for _, trunkFinding in ipairs(ScanTrunkContraband(plate)) do
            findings[#findings + 1] = trunkFinding
        end
    end


    if #findings == 0 then return false end


    for _, finding in ipairs(findings) do
        SeizeContraband(finding, bot.dna_id)
    end


    if trapHouseId and Matrix.Bureau and Matrix.Bureau.AdvanceDecryption then
        Matrix.Bureau.AdvanceDecryption(trapHouseId, Config.Forensics.Frisk.EvidenceIndexJumpRatio)
    end


    Matrix.Log('FORENSICS', '[UST ARAMA] Bot #%d yakalandi: %d kontrabant bulundu, delil indeksi %.2f ziladi.',
        botId, #findings, Config.Forensics.Frisk.EvidenceIndexJumpRatio)
    return true
end


function Matrix.Forensics.InspectPlayer(officerSrc, suspectSrc)
    -- ★ Bu dosyanın KENDİ konvansiyonu (bkz. /silahasindir yukarıda): oyuncu
    -- envanteri ox_inventory köprüsünde string olarak ele alınır.
    local inventoryId = tostring(suspectSrc)
    local findings = ScanInventoryContraband(inventoryId)


    local ped = GetPlayerPed(suspectSrc)
    if ped and ped ~= 0 then
        local okVeh, veh = pcall(function() return GetVehiclePedIsIn(ped, false) end)
        if okVeh and veh and veh ~= 0 then
            local okPlate, plate = pcall(function() return GetVehicleNumberPlateText(veh) end)
            plate = (okPlate and type(plate) == 'string') and plate:gsub('%s+$', '') or nil
            local vehicle = plate and Matrix.Fleet and Matrix.Fleet.GetVehicle and Matrix.Fleet.GetVehicle(plate)
            if vehicle and (vehicle.vin_status == 'scratched' or vehicle.verified_stolen_plate) then
                findings[#findings + 1] = { kind = 'vehicle', plate = plate }
            end

            -- ★ [MADDE 5b] BAGAJ RÖNTGENİ: oyuncunun İÇİNDE OLDUĞU aracın
            -- bagajı da (filo/kurye aracıysa) üst aramayla AYNI anda taranır.
            if vehicle then
                for _, trunkFinding in ipairs(ScanTrunkContraband(plate)) do
                    findings[#findings + 1] = trunkFinding
                end
            end
        end
    end


    if #findings == 0 then
        Reply(officerSrc, 'Ust arama tamamlandi: kontrabant bulunamadi.')
        return false
    end


    local actor = Matrix.ResolveActor({ kind = 'player', source = suspectSrc })
    local dnaId = (actor and actor.dna_id) or 'UNKNOWN'
    for _, finding in ipairs(findings) do
        SeizeContraband(finding, dnaId)
    end


    local coords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    local trapHouseId = coords and FindNearestTrapHouseForFrisk(coords)
    if trapHouseId and Matrix.Bureau and Matrix.Bureau.AdvanceDecryption then
        Matrix.Bureau.AdvanceDecryption(trapHouseId, Config.Forensics.Frisk.EvidenceIndexJumpRatio)
    end


    Reply(officerSrc, ('Ust arama tamamlandi: %d kontrabant el konuldu.'):format(#findings))
    TriggerClientEvent('chat:addMessage', suspectSrc, { args = { '[UST ARAMA]', ('%d esyaniza el konuldu.'):format(#findings) } })
    Matrix.Log('FORENSICS', '[UST ARAMA] Memur #%d, supheli #%d: %d kontrabant bulundu.', officerSrc, suspectSrc, #findings)
    return true
end


-- ★ main.lua'nın RefreshPoliceCache/PoliceSources İLE AYNI desen -- dosya-
-- yerel kopya, mevcut kod tabanının kendi konvansiyonu (bkz. bureau.lua/
-- logistics.lua'daki FindNearestTrapHouse/HasCommandAuthority kopyaları).
local FriskPoliceSources        = {}
local friskPoliceFailCount      = 0
local friskPoliceDisabledUntil  = 0


local function RefreshFriskPoliceCache()
    if Matrix.Now() < friskPoliceDisabledUntil then return end


    local ok, players = pcall(function() return Matrix.QBX:GetQBPlayers() end)
    if not ok or type(players) ~= 'table' then
        friskPoliceFailCount = friskPoliceFailCount + 1
        if friskPoliceFailCount >= 5 then
            friskPoliceDisabledUntil = Matrix.Now() + 60
            friskPoliceFailCount = 0
            Matrix.Log('FORENSICS', '[UYARI] GetQBPlayers 5 kez ust uste basarisiz oldu; 60sn devre disi birakildi.')
        end
        return
    end
    friskPoliceFailCount = 0


    local fresh = {}
    for src, player in pairs(players) do
        if player and player.PlayerData and player.PlayerData.job then
            local job = player.PlayerData.job
            if job.onduty and (job.name == 'police' or job.name == 'sheriff' or job.type == 'leo') then
                fresh[src] = true
            end
        end
    end
    FriskPoliceSources = fresh
end


CreateThread(function()
    while true do
        Wait(5000)
        RefreshFriskPoliceCache()
    end
end)


local FriskDwellMs       = {}   -- 'officerSrc#suspectSrc' -> birikmis ms
local FriskCooldownUntil = {}   -- suspectSrc -> epoch saniye


-- ★ 0 RESMON: Wait(0) YOK -- 1sn poll main.lua'nın master ticker'ından
-- BAĞIMSIZ, kendi thread'inde. DwellMs (6000) bu 1000ms adımlarla birikir.
CreateThread(function()
    while true do
        Wait(1000)


        local now = Matrix.Now()
        local activePairs = {}


        for officerSrc in pairs(FriskPoliceSources) do
            local officerPed = GetPlayerPed(officerSrc)
            if officerPed and officerPed ~= 0 then
                local officerCoords = GetEntityCoords(officerPed)


                for _, suspectSrcStr in ipairs(GetPlayers()) do
                    local suspectSrc = tonumber(suspectSrcStr)
                    if suspectSrc and suspectSrc ~= officerSrc and not FriskPoliceSources[suspectSrc] then
                        local suspectPed = GetPlayerPed(suspectSrc)
                        if suspectPed and suspectPed ~= 0 and (FriskCooldownUntil[suspectSrc] or 0) <= now then
                            local suspectCoords = GetEntityCoords(suspectPed)
                            if #(officerCoords - suspectCoords) <= Config.Forensics.Frisk.Radius then
                                local pairKey = officerSrc .. '#' .. suspectSrc
                                activePairs[pairKey] = true
                                FriskDwellMs[pairKey] = (FriskDwellMs[pairKey] or 0) + 1000


                                if FriskDwellMs[pairKey] >= Config.Forensics.Frisk.DwellMs then
                                    FriskDwellMs[pairKey] = nil
                                    FriskCooldownUntil[suspectSrc] = now + math.floor(Config.Forensics.Frisk.CooldownMs / 1000)


                                    local ok, err = pcall(Matrix.Forensics.InspectPlayer, officerSrc, suspectSrc)
                                    if not ok then
                                        Matrix.Log('FORENSICS', '[HATA] InspectPlayer hata verdi (yutuldu): %s', tostring(err))
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end


        for key in pairs(FriskDwellMs) do
            if not activePairs[key] then FriskDwellMs[key] = nil end
        end
    end
end)


-- =====================================================================
-- ★★★ [OPSEC FAZ 1 EK] FİZİKSEL VE SİBER DELİL İMHA MEKANİZMASI
-- (FORENSIC SANITIZATION) ★★★
-- Aşağıdaki üç fonksiyon TAMAMEN YENİ bir EKLEMEDİR. Yukarıdaki hiçbir
-- balistik/kovan/mekanik-tutukluk/frisk formülüne DOKUNULMADI.
--
-- ★ "ADLİ KAYIT ASLA SİLİNMEZ" POLİTİKASIYLA İLİŞKİ (dosya başı matrix.sql
-- yorumu): bu dosya ZATEN TEK bir BİLİNÇLİ istisnaya sahip
-- (Matrix.Forensics.WipeBallisticRecord, yukarıda, Katman 5 ULTIMATE
-- [U3] — namlu değişimi). CollectShells DAR kapsamlı, AYNI ilkeyle İKİNCİ
-- bir istisnadır: yalnızca fiziksel olarak ZİYARET EDİLEN koordinattaki
-- (yarıçap ile sınırlı) kovanlar silinir — toplu/uzaktan bir "tüm kanıtları
-- sil" mekanizması DEĞİLDİR (matrix.sql'in KATMAN 8 notu böyle tanımsız,
-- geniş kapsamlı bir toplu-silme mekanizmasını BİLİNÇLİ OLARAK reddetmişti
-- — CollectShells o kararla ÇELİŞMEZ, çünkü kapsamı yapısal olarak dardır).
-- TamperEvidenceLockup ise HİÇ SATIR SİLMEZ — Matrix.Forensics.ForceSeal/
-- AnalyzeEvidence'ın (yukarıda, DEĞİŞTİRİLMEDİ) ZATEN yaptığı gibi yalnızca
-- mevcut satırların certainty/seal alanlarını UPDATE eder.
--
-- ★ SKILL KAPISI: yeni bir 'hacking_stealth' sütunu İCAT EDİLMEZ —
-- matrix_bots.psychology ZATEN skill_chemistry/skill_cyber/skill_logistics
-- taşıyor (server/main.lua CreateBotRecord/LoadBotsFromDatabase,
-- DEĞİŞTİRİLMEDİ). Fiziksel/kurye nitelikli CollectShells skill_logistics'e
-- (ACTIVITY_SKILL_MAP'te distribution/street_dealing İLE AYNI beceri,
-- server/kitchen.lua), siber nitelikli HackCCTVNetwork ise skill_cyber'e
-- (livestream/propaganda İLE AYNI beceri, server/bureau.lua) bağlanır —
-- Matrix.Kitchen.GetEffectiveSkill (server/kitchen.lua, DEĞİŞTİRİLMEDİ)
-- üzerinden okunur, withdrawal cezası dahil MEVCUT tüm etkiler otomatik
-- miras alınır. Skill YÜKSEKSE süre KISALIR ve kortizol sıçraması
-- ENGELLENİR (skill=1.0 iken sıçrama TAM SIFIRDIR) — RNG YOK, saf doğrusal
-- ölçekleme.
-- =====================================================================


local function IsValidWorldCoords(c)
    if type(c) ~= 'table' and type(c) ~= 'userdata' and type(c) ~= 'vector3' and type(c) ~= 'vector4' then return false end
    if c.x == nil or c.y == nil or c.z == nil then return false end
    if type(c.x) ~= 'number' or type(c.y) ~= 'number' or type(c.z) ~= 'number' then return false end
    if c.x ~= c.x or c.y ~= c.y or c.z ~= c.z then return false end
    return true
end


--- Taban süreyi skill ile taban bir tavana kadar doğrusal kısaltır --
--- skill=0 -> baseDurationMs, skill=1.0 -> floorDurationMs (ASLA daha
--- düşüğe inmez, "anlık/istismar edilebilir" bir süre YOK).
local function ComputeSkillGatedDurationMs(baseDurationMs, floorDurationMs, skill)
    skill = Matrix.Clamp(tonumber(skill) or 0.0, 0.0, 1.0)
    local duration = baseDurationMs - ((baseDurationMs - floorDurationMs) * skill)
    if duration < floorDurationMs then duration = floorDurationMs end
    return math.floor(duration)
end


-- =====================================================================
-- [OPSEC-5a] FİZİKSEL KOVAN TOPLAMA — bir sevk edilen kurye/temizlik
-- botunun, belirtilen koordinat civarındaki (Config.Forensics.
-- ShellCollectionRadiusMeters) balistik kovan kayıtlarını fiziksel olarak
-- toplaması. Toplanan her kovan botun KENDİ ox_inventory envanterine
-- (dealer_<id>, MEVCUT envanter kimliği şeması) bir eşya olarak eklenir
-- VE ilgili matrix_forensic_evidence satırı KALICI olarak silinir (bkz.
-- dosya-başı OPSEC yorumu — DAR kapsamlı, bilinçli istisna).
-- =====================================================================
function Matrix.Forensics.CollectShells(botId, coords)
    botId = tonumber(botId)
    local bot = botId and Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    if not IsValidWorldCoords(coords) then return false, 'bad_coords' end


    local radius = Config.Forensics.ShellCollectionRadiusMeters or 3.0
    local rows = MySQL.query.await([[
        SELECT id, ballistic_id, coords_x, coords_y, coords_z FROM matrix_forensic_evidence
        WHERE coords_x BETWEEN ? AND ? AND coords_y BETWEEN ? AND ? AND coords_z BETWEEN ? AND ?
    ]], {
        coords.x - radius, coords.x + radius,
        coords.y - radius, coords.y + radius,
        coords.z - radius, coords.z + radius
    }) or {}


    -- Bounding-box SQL filtresi köşe alanları da döner -- gerçek daire
    -- (kürevi) mesafe burada Lua tarafında kesin olarak süzülür.
    local matched = {}
    for _, row in ipairs(rows) do
        local dx = (tonumber(row.coords_x) or 0.0) - coords.x
        local dy = (tonumber(row.coords_y) or 0.0) - coords.y
        local dz = (tonumber(row.coords_z) or 0.0) - coords.z
        if math.sqrt((dx * dx) + (dy * dy) + (dz * dz)) <= radius then
            matched[#matched + 1] = row
        end
    end
    if #matched == 0 then return false, 'no_evidence_here' end


    local skill = (Matrix.Kitchen and Matrix.Kitchen.GetEffectiveSkill and Matrix.Kitchen.GetEffectiveSkill(bot, 'skill_logistics')) or 0.0
    local durationMs = ComputeSkillGatedDurationMs(
        Config.Forensics.ShellCollectionBaseDurationMs, Config.Forensics.ShellCollectionSkillDurationFloorMs, skill)
    local cortisolSpike = Config.Forensics.ShellCollectionBaseCortisolSpike * (1.0 - Matrix.Clamp(skill, 0.0, 1.0))


    local inventoryId = ('dealer_%d'):format(bot.id)
    local collectedCount = 0
    for _, row in ipairs(matched) do
        local addOk = pcall(function()
            return exports['ox_inventory']:AddItem(inventoryId, Config.Forensics.ShellCasingEvidenceItem, 1, {
                ballistic_id = row.ballistic_id,
                description  = ('[TOPLANMIS KOVAN]\nBalistik ID: %s\nAdli kayit fiziksel olarak imha edildi.'):format(row.ballistic_id)
            })
        end)
        if addOk then
            MySQL.prepare('DELETE FROM matrix_forensic_evidence WHERE id = ?', { row.id })
            collectedCount = collectedCount + 1
        end
    end
    if collectedCount == 0 then return false, 'inventory_full' end


    if cortisolSpike > 0.0 and bot.biology then
        bot.biology.cortisol_level = Matrix.Clamp(bot.biology.cortisol_level + cortisolSpike, 0.0, 1.0)
        Matrix.MarkBotDirty(bot.id)
    end


    Matrix.Log('FORENSICS',
        '[KOVAN TOPLAMA] Bot #%d (%s) (%.1f,%.1f,%.1f) civarinda %d/%d kovan topladi ve matrix_forensic_evidence dan kalici olarak sildi (skill_logistics=%.3f sure=%dms kortizol-sicramasi=%.3f).',
        bot.id, bot.dna_id, coords.x, coords.y, coords.z, collectedCount, #matched, skill, durationMs, cortisolSpike)


    return true, { collected = collectedCount, found = #matched, duration_ms = durationMs, cortisol_spike = cortisolSpike }
end


-- =====================================================================
-- [OPSEC-5b] MOBESE AĞI SİBER MÜDAHALESİ — bir bölgenin (zoneId, MEVCUT
-- Config.Market.Zones id-uzayı, YENİ bir bölge kavramı İCAT EDİLMEZ)
-- mobese dağıtım kutularına sızar; başarılı tetiklenmede o bölgedeki son
-- 30 dakikaya ait MASKESİZ/ŞÜPHELİ kıyafet eşleşme geçmişini
-- (matrix_cctv_logs, bkz. sql/matrix_cctv_network.sql) siler. Maskeli
-- (zaten gizlenmiş) veya 30 dakikadan eski kayıtlara DOKUNULMAZ.
-- =====================================================================
function Matrix.Forensics.HackCCTVNetwork(actorRef, zoneId)
    zoneId = tonumber(zoneId)
    if not zoneId then return false, 'bad_zone' end


    local actor = Matrix.ResolveActor(actorRef)
    if not actor then return false, 'actor_unresolved' end


    local skill = (Matrix.Kitchen and Matrix.Kitchen.GetEffectiveSkill and Matrix.Kitchen.GetEffectiveSkill(actor, 'skill_cyber')) or 0.0
    local durationMs = ComputeSkillGatedDurationMs(
        Config.Forensics.CCTVHackBaseDurationMs, Config.Forensics.CCTVHackSkillDurationFloorMs, skill)
    local cortisolSpike = Config.Forensics.CCTVHackBaseCortisolSpike * (1.0 - Matrix.Clamp(skill, 0.0, 1.0))


    MySQL.prepare([[
        DELETE FROM matrix_cctv_logs
        WHERE zone_id = ? AND masked = 0 AND created_at >= (NOW() - INTERVAL 30 MINUTE)
    ]], { zoneId })


    if cortisolSpike > 0.0 and actor.biology then
        actor.biology.cortisol_level = Matrix.Clamp(actor.biology.cortisol_level + cortisolSpike, 0.0, 1.0)
    end


    Matrix.Log('FORENSICS',
        '[MOBESE HACK] %s -> Bolge #%d son 30dk maskesiz/supheli kiyafet gecmisi silindi (skill_cyber=%.3f sure=%dms kortizol-sicramasi=%.3f).',
        actor.dna_id or 'UNKNOWN', zoneId, skill, durationMs, cortisolSpike)


    return true, { duration_ms = durationMs, cortisol_spike = cortisolSpike }
end


-- =====================================================================
-- [KAMERA VERI TEMIZLIGI] /kameralogutemizle -- oyuncu bir router kutusuna
-- (Config.TrapHouseInterior.Shell.RouterPos) fiziksel olarak yaklastiginda,
-- KENDI dna_id'sine ait son 30 dakikalik TUM matrix_cctv_logs satirlari
-- (mobese gecis hash kayitlari + kiyafet kombinasyon izleri) kalici olarak
-- DB'den kazinir -- HackCCTVNetwork (yukarida, zone-bazli) ILE AYNI
-- tabloyu kullanir, YENİ bir tablo İCAT EDİLMEZ.
-- =====================================================================
local function VerifyAtRouter(src)
    if not (Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetPlayerTrapHouse) then
        return true
    end


    local trapHouseId = Matrix.TrapHouseInterior.GetPlayerTrapHouse(src)
    if not trapHouseId then return false end


    local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
    local routerPos = shell and shell.RouterPos
    if not routerPos then return true end


    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local coords = GetEntityCoords(ped)
    local radius = (Config.Forensics.RouterSanitization and Config.Forensics.RouterSanitization.Radius) or 2.0
    return #(coords - routerPos) <= radius
end


function Matrix.Forensics.SanitizeCCTVTrail(src)
    if type(src) ~= 'number' or src <= 0 then return false, 'bad_src' end


    if not VerifyAtRouter(src) then
        return false, 'not_at_router'
    end


    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.dna_id then return false, 'state_unresolved' end


    local windowMinutes = (Config.Forensics.RouterSanitization and Config.Forensics.RouterSanitization.WindowMinutes) or 30


    -- ★ windowMinutes Config'ten gelir (kullanici girdisi DEGILDIR) --
    -- HackCCTVNetwork'un (yukarida) AYNI "INTERVAL sabiti sorgu icine
    -- gomulur" konvansiyonuyla tutarli (bazi surucularin INTERVAL
    -- konumunda parametre bind'ini desteklememesi riskine karsi).
    local ok, result = pcall(function()
        return MySQL.query.await(
            ('DELETE FROM matrix_cctv_logs WHERE dna_id = ? AND created_at >= (NOW() - INTERVAL %d MINUTE)'):format(windowMinutes),
            { state.dna_id }
        )
    end)
    if not ok then
        Matrix.Log('FORENSICS', '[HATA] SanitizeCCTVTrail DELETE basarisiz: %s', tostring(result))
        return false, 'db_error'
    end


    local affected = (type(result) == 'table' and (result.affectedRows or result.numAffected)) or 0
    Matrix.Log('FORENSICS',
        '[KAMERA VERI TEMIZLIGI] %s -> router kutusu uzerinden son %d dakikalik mobese/kiyafet izi kazindi (%s satir).',
        state.dna_id, windowMinutes, tostring(affected))


    return true, { minutes = windowMinutes, affected = affected }
end


RegisterCommand('kameralogutemizle', function(src, args)
    if type(src) ~= 'number' or src <= 0 then return end


    local ok, resultOrReason = Matrix.Forensics.SanitizeCCTVTrail(src)
    if ok then
        Reply(src, ('[ROUTER SIZMASI] Son %d dakikalik mobese/kiyafet izi kalici olarak kazindi.'):format(resultOrReason.minutes))
    elseif resultOrReason == 'not_at_router' then
        Reply(src, 'Router kutusunun yaninda degilsiniz (bir trap house icine girip router\'a yaklasin).')
    else
        Reply(src, ('Basarisiz: %s'):format(tostring(resultOrReason)))
    end
end, false)


exports('SanitizeCCTVTrail', function(src) return Matrix.Forensics.SanitizeCCTVTrail(src) end)


-- =====================================================================
-- [OPSEC-5c] KANIT ODASI SABOTAJI — server/bureau.lua Matrix.Bureau.
-- ProcessBribeOffer'ın (DEĞİŞTİRİLMEDİ, yalnızca opsiyonel bir 4. caseId
-- parametresi eklendi) BAŞARILI sonucuyla konuşan mekanizma. caseId,
-- dosyanın KENDİ /forensicdump komutuyla AYNI kimlik uzayını kullanan bir
-- ballistic_id'dir (bu şemada "vaka" kavramının en yakın karşılığı budur
-- — YENİ bir "case" tablosu İCAT EDİLMEZ). "Conviction Weight" (Mahkumiyet
-- Skoru), ZATEN VAR OLAN sealed_as_crime_weapon/seal_certainty/
-- match_certainty alanlarına haritalanır (Matrix.Forensics.ForceSeal/
-- AnalyzeEvidence'ın AYNI alanları UPDATE ettiği disiplinle BİREBİR
-- TUTARLI) — HİÇBİR satır SİLİNMEZ, yalnızca sıfırlanır.
-- =====================================================================
function Matrix.Forensics.TamperEvidenceLockup(officerCitizenId, caseId, bribeWasSuccessful)
    if type(officerCitizenId) ~= 'string' or officerCitizenId == '' then return false, 'bad_officer' end
    if type(caseId) ~= 'string' or caseId == '' then return false, 'bad_case' end
    if not bribeWasSuccessful then return false, 'bribe_not_successful' end


    -- ★ 1. Katmandaki yozlaşmış polis genetiğiyle konuşur (server/
    -- bureau.lua, DEĞİŞTİRİLMEDİ) -- forensics.lua bureau.lua'dan ÖNCE
    -- yüklense de bu çağrı RUNTIME'da (tüm dosyalar zaten yüklenmişken)
    -- gerçekleşir, bu yüzden güvenlidir (dosya-yükleme sırası SORUN
    -- DEĞİLDİR — yalnızca dosya-başı top-level erişim olurdu).
    local personality = Matrix.Bureau and Matrix.Bureau.GetPolicePersonality and Matrix.Bureau.GetPolicePersonality(officerCitizenId)
    if not personality then return false, 'officer_personality_unresolved' end


    local greedThreshold = Config.Forensics.TamperGreedThreshold
    if personality.greed < greedThreshold then
        return false, 'officer_not_greedy_enough'
    end


    local weaponRows = MySQL.query.await('SELECT ballistic_id FROM matrix_ballistic_weapons WHERE ballistic_id = ?', { caseId }) or {}
    if not weaponRows[1] then return false, 'case_not_found' end


    MySQL.prepare([[
        UPDATE matrix_ballistic_weapons
        SET sealed_as_crime_weapon = 0, seal_certainty = 0.0
        WHERE ballistic_id = ?
    ]], { caseId })


    MySQL.prepare([[
        UPDATE matrix_forensic_evidence
        SET sealed_as_crime_weapon = 0, match_certainty = 0.0
        WHERE ballistic_id = ?
    ]], { caseId })


    Matrix.Log('FORENSICS',
        '[KANIT ODASI SABOTAJI] Memur %s (greed=%.3f >= esik:%.2f) -> Vaka #%s: Mahkumiyet Skoru (chain of custody) SIFIRLANDI.',
        officerCitizenId, personality.greed, greedThreshold, caseId)


    return true, { case_id = caseId, officer_greed = personality.greed }
end


-- =====================================================================
-- EVENT BRIDGE + DEBUG PANELİ (diğer tüm mekaniklerle AYNI disiplin)
-- =====================================================================
RegisterNetEvent('matrix:server:forensics:collectShells', function(botId, coords)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local ok, resultOrReason = Matrix.Forensics.CollectShells(botId, coords)
    TriggerClientEvent('matrix:client:actionNotify', src, ok,
        ok and ('%d kovan toplandi, adli kayittan silindi.'):format(resultOrReason.collected)
           or ('Kovan toplama basarisiz: %s'):format(tostring(resultOrReason)))
end)


RegisterNetEvent('matrix:server:forensics:hackCCTV', function(zoneId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local ok, resultOrReason = Matrix.Forensics.HackCCTVNetwork({ kind = 'player', source = src }, zoneId)
    TriggerClientEvent('matrix:client:actionNotify', src, ok,
        ok and 'Mobese agina sizildi, gecmis kayitlar silindi.' or ('Mobese hack basarisiz: %s'):format(tostring(resultOrReason)))
end)


-- /kovantopla [botId] [x] [y] [z] -- CollectShells'i test amacli tetikler.
RegisterCommand('kovantopla', function(src, args)
    local botId = tonumber(args[1])
    local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
    if not botId or not x or not y or not z then
        Reply(src, 'Kullanim: /kovantopla [botId] [x] [y] [z]'); return
    end


    local ok, result = Matrix.Forensics.CollectShells(botId, vector3(x, y, z))
    if ok then
        Reply(src, ('%d/%d kovan toplandi (sure:%dms kortizol:+%.3f).'):format(result.collected, result.found, result.duration_ms, result.cortisol_spike))
    else
        Reply(src, ('Basarisiz: %s'):format(tostring(result)))
    end
end, false)


-- /mobesehackle [zoneId] -- HackCCTVNetwork'u test amacli tetikler.
RegisterCommand('mobesehackle', function(src, args)
    local zoneId = tonumber(args[1])
    if not zoneId then Reply(src, 'Kullanim: /mobesehackle [zoneId]'); return end


    local ok, result = Matrix.Forensics.HackCCTVNetwork({ kind = 'player', source = src }, zoneId)
    if ok then
        Reply(src, ('Bolge #%d mobese gecmisi silindi (sure:%dms kortizol:+%.3f).'):format(zoneId, result.duration_ms, result.cortisol_spike))
    else
        Reply(src, ('Basarisiz: %s'):format(tostring(result)))
    end
end, false)


-- /cctvkaydet [zoneId] [dnaId] [maskeli 0|1] [kiyafetEtiketi] -- gercek bir
-- algilama motoru OLMADAN (KAPSAM DISI, bkz. dosya-basi OPSEC yorumu)
-- matrix_cctv_logs'a test amacli bir satir yazar.
RegisterCommand('cctvkaydet', function(src, args)
    local zoneId = tonumber(args[1])
    local dnaId  = args[2]
    local masked = tonumber(args[3]) == 1
    local tag    = args[4] or 'unknown'
    if not zoneId or type(dnaId) ~= 'string' then
        Reply(src, 'Kullanim: /cctvkaydet [zoneId] [dnaId] [maskeli 0|1] [kiyafetEtiketi]'); return
    end


    MySQL.insert('INSERT INTO matrix_cctv_logs (zone_id, dna_id, masked, clothing_tag, created_at) VALUES (?, ?, ?, ?, NOW())',
        { zoneId, dnaId, masked and 1 or 0, tag })
    Reply(src, 'Mobese kaydi eklendi (test).')
end, false)


-- /kanitsabotaj [officerCitizenId] [caseId/ballisticId] -- TamperEvidenceLockup'i
-- basarili bir rusvet SIMULE ederek test amacli tetikler (gercek akista
-- bureau.lua ProcessBribeOffer BASARILI oldugunda otomatik cagrilir).
RegisterCommand('kanitsabotaj', function(src, args)
    local officerCitizenId = args[1]
    local caseId            = args[2]
    if type(officerCitizenId) ~= 'string' or type(caseId) ~= 'string' then
        Reply(src, 'Kullanim: /kanitsabotaj [memurCitizenId] [caseId/ballisticId]'); return
    end


    local ok, result = Matrix.Forensics.TamperEvidenceLockup(officerCitizenId, caseId, true)
    if ok then
        Reply(src, ('Vaka #%s sabote edildi (memur greed=%.3f).'):format(result.case_id, result.officer_greed))
    else
        Reply(src, ('Basarisiz: %s'):format(tostring(result)))
    end
end, false)


exports('CollectShells', function(botId, coords) return Matrix.Forensics.CollectShells(botId, coords) end)
exports('HackCCTVNetwork', function(actorRef, zoneId) return Matrix.Forensics.HackCCTVNetwork(actorRef, zoneId) end)
exports('TamperEvidenceLockup', function(officerCitizenId, caseId, bribeWasSuccessful)
    return Matrix.Forensics.TamperEvidenceLockup(officerCitizenId, caseId, bribeWasSuccessful)
end)