-- =====================================================================
-- MATRIX YARALANMA MOTORU / server/wound_system.lua
-- (KATMAN 2: Yasal Hastane/EMS Sizinti Döngüsü, KATMAN 3: Arma-Tarzı
--  Bölgesel Bot Yaralanması, KATMAN 4: Kalıcı Sakatlık + Hayalet Cerrah)
--
-- Bu dosya, Matrix.* paylaşımlı ad alanına (aynı kaynağın TÜM server
-- script'leri TEK bir Lua ortamını paylaşır -- exports() yalnızca
-- kaynaklar-arası çağrı için gereklidir) yeni fonksiyonlar EKLER.
-- Mevcut hiçbir Matrix.* fonksiyonu/tablosu/olayı DEĞİŞTİRİLMEZ.
--
-- ENTEGRASYON NOKTALARI (yeniden kullanılan, İCAT EDİLMEYEN motorlar):
--   - server/forensics.lua Matrix.Forensics.RegisterOrGetBallisticId /
--     matrix_forensic_evidence (balistik imza eşleştirme)
--   - server/bureau.lua Matrix.Bureau.OpenTrial/RecordTrialResponse/
--     ExecuteVerdict (mahkeme + Karakter Wipe), GetHeat/CyberLeakMaxIntensity,
--     IssueRaid, GetBureaucraticVelocity
--   - matrix_bureau_intensity ConVar'i (server/bureau.lua'nın OKUDUĞU,
--     burada SetConvar ile ANLIK katlanan AYNI global konfigürasyon)
--   - server/kitchen.lua Matrix.Kitchen.AdjustCortisol (kortizol kilidi)
--   - server/logistics.lua 'matrix:server:reportDealerCombatDamage'
--     (bot-hasar bildirimi -- İKİNCİ bir AddEventHandler burada eklenir,
--     Matrix.Logistics.ApplyCombatDamage'in KENDİSİ DEĞİŞTİRİLMEZ)
--   - Koma Modu (status='comatose', withdrawal_index>=1.0) ZATEN VAR --
--     bu dosya onu YENİDEN İCAT ETMEZ, yalnızca dispatch/telsiz kilidine
--     (ZATEN o motorun kendisinde uygulanan) saygı gösterir.
-- =====================================================================


Matrix.Wounds = Matrix.Wounds or {}


local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_min, math_max, math_floor          = math.min, math.max, math.floor
local math_huge                               = math.huge


local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[YARALANMA]', msg } })
    else
        print(('[MATRIX:WOUNDS:CONSOLE] %s'):format(msg))
    end
end


local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0.0) - (b.z or 0.0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end


local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        local d = VectorDistance(coords, house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId, nearestDist
end


-- ★ RNG YOK: server/blackmarket.lua GenerateScratchedPlate/GenerateWeaponSerial
-- İLE AYNI sağlama toplamı deseni.
local function ChecksumOf(raw, salt)
    local sum = 0
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + salt))) % 0xFFFFFFF
    end
    return sum
end


-- =====================================================================
-- [KATMAN 2] SON ATEŞ EDİLEN SİLAH ÖNBELLEĞİ (src bazlı)
-- server/forensics.lua'nın ZATEN VAR OLAN 'matrix:server:reportWeaponShotFired'
-- event'ine İKİNCİ bir dinleyici eklenir (RegisterNetEvent bir kez yeter,
-- AddEventHandler aynı event adına birden çok dinleyici bağlanabilir --
-- forensics.lua'nın KENDİ mantığı HİÇ değiştirilmez). Bu, "ateş eden
-- oyuncunun/botun balistik imzası" bilgisini oyuncu hasar aldığı anda
-- kimin ateş ettiğini bilmeden bile en-son-atış temelli deterministik
-- bir yaklaşımla türetmemizi sağlar.
-- =====================================================================
local LastFiredWeaponSerial = {} -- [src] = weaponSerial


AddEventHandler('matrix:server:reportWeaponShotFired', function(weaponItemName, weaponSlot)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(weaponSlot) ~= 'number' then return end

    local ok, meta = pcall(Matrix.Inventory.GetSlotMetadata, tostring(src), weaponSlot)
    if not ok or type(meta) ~= 'table' then return end
    if type(meta.weapon_serial) == 'string' and meta.weapon_serial ~= '' then
        LastFiredWeaponSerial[src] = meta.weapon_serial
    end
end)


AddEventHandler('playerDropped', function()
    local src = source
    LastFiredWeaponSerial[src] = nil
end)


-- =====================================================================
-- [KATMAN 2] OYUNCU-HASAR KANCASI: gameEventTriggered'in sunucuya
-- yansıttığı istemci bildirimi. Şüpheli davranış (kendi kendine yara
-- uydurma) burada bir GÜVEN sorunu DEĞİL -- bu bir RP simülasyon
-- mekaniği, gerçek anti-cheat kapsamı dışındadır (mevcut kodun hiçbir
-- yerinde de böyle bir doğrulama yoktur).
-- =====================================================================
RegisterNetEvent('matrix:server:reportPlayerWounded', function(attackerServerId, attackerWeaponHash)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return end

    local ballisticId = nil

    attackerServerId = tonumber(attackerServerId)
    if attackerServerId and attackerServerId > 0 and LastFiredWeaponSerial[attackerServerId] then
        local serial = LastFiredWeaponSerial[attackerServerId]
        local ok, bId = pcall(Matrix.Forensics.RegisterOrGetBallisticId, serial, 1.0)
        if ok then ballisticId = bId end
    elseif type(attackerWeaponHash) == 'string' and attackerWeaponHash ~= '' then
        -- Saldırgan izlenen bir oyuncu/silah değilse (dünya botu/mermi
        -- kaynağı çözülemedi): deterministik sentetik bir seri no üretilir
        -- -- RNG YOK, girdi doğrudan silah hash'inden türetilir.
        local syntheticSerial = ('NPC-%08X'):format(ChecksumOf(attackerWeaponHash, 41))
        local ok, bId = pcall(Matrix.Forensics.RegisterOrGetBallisticId, syntheticSerial, 1.0)
        if ok then ballisticId = bId end
    end

    if not ballisticId then return end

    MySQL.prepare([[
        INSERT INTO matrix_player_state (citizenid, has_wound, wound_ballistic_id, updated_at)
        VALUES (?, 1, ?, NOW())
        ON DUPLICATE KEY UPDATE has_wound = 1, wound_ballistic_id = VALUES(wound_ballistic_id), updated_at = NOW()
    ]], { state.citizenid, ballisticId })

    state.has_wound          = true
    state.wound_ballistic_id = ballisticId

    Matrix.Log('WOUNDS', '[YARALANMA] %s balistik-imza #%s ile yaralandi.', state.citizenid, tostring(ballisticId))
end)


-- =====================================================================
-- [KATMAN 2] /tedaviol -- Yasal Hastane Check-In + Adli Sorgu
-- =====================================================================
local BedsideSessions = {} -- [citizenid] = { conviction_weight, lie_count }


local function EnsureWoundColumnsLoaded(state)
    if state.has_wound ~= nil then return end
    local row = MySQL.single.await('SELECT has_wound, wound_ballistic_id FROM matrix_player_state WHERE citizenid = ?', { state.citizenid })
    state.has_wound          = row and row.has_wound == 1 or false
    state.wound_ballistic_id = row and row.wound_ballistic_id or nil
end


--- Saf/yan-etkisiz çarpım formülü (ConVar'a HİÇ DOKUNMAZ) -- LeakToBureauOnTreatment
--- ve matrix_diagnostics.lua'nın deep-sim testi BUNU çağırır, böylece test
--- gerçek matrix_bureau_intensity ConVar'ını okuyup/yazmadan (0 yan etki)
--- ÜRETİMDEKİ AYNI formülü doğrulayabilir. Geçersiz/negatif/NaN girdi 1.0
--- tabanına düşer (production ile BİREBİR AYNI davranış).
function Matrix.Wounds.ComputeBureauLeakMultiplier(currentIntensity)
    if type(currentIntensity) ~= 'number' or currentIntensity ~= currentIntensity or currentIntensity <= 0.0 then
        currentIntensity = 1.0
    end
    local mult = Config.Hospital.LeakIntensityMultiplier or 2.0
    return currentIntensity * mult, mult, currentIntensity
end


--- Tedavi başarıyla tamamlanır (yara kapanır) FAKAT tıbbi rapor ANINDA
--- Büro'ya sızar -- matrix_bureau_intensity ConVar'i bu tekil olayda
--- 2 KATINA çıkar (server/bureau.lua'nın Matrix.Bureau.GetBureaucraticVelocity
--- OKUDUĞU AYNI ConVar).
local function LeakToBureauOnTreatment(citizenid, ballisticId)
    local current = GetConvarFloat('matrix_bureau_intensity', 1.0)
    local spiked, mult, correctedCurrent = Matrix.Wounds.ComputeBureauLeakMultiplier(current)
    current = correctedCurrent
    SetConvar('matrix_bureau_intensity', tostring(spiked))

    local nearestId = nil
    local row = ballisticId and MySQL.single.await(
        'SELECT coords_x, coords_y, coords_z FROM matrix_forensic_evidence WHERE ballistic_id = ? ORDER BY id DESC LIMIT 1',
        { ballisticId })
    if row then
        nearestId = FindNearestTrapHouse(vector3(row.coords_x, row.coords_y, row.coords_z))
    end
    if nearestId and Matrix.Bureau.LogPatternEvent then
        pcall(Matrix.Bureau.LogPatternEvent, nearestId)
    end

    Matrix.Log('WOUNDS', '[TIBBI SIZINTI] %s tedavi oldu -- matrix_bureau_intensity %.3f -> %.3f (x%.1f).',
        citizenid, current, spiked, mult)
end


RegisterCommand(Config.Hospital.TreatmentCommand, function(src)
    if type(src) ~= 'number' or src <= 0 then return end
    if not Config.Hospital.Enabled then return end

    local ped = GetPlayerPed(src)
    local coords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    local nearCheckIn = false
    if coords then
        for _, point in ipairs(Config.Hospital.CheckInPoints) do
            if VectorDistance(coords, point.coords) <= point.radius then nearCheckIn = true; break end
        end
    end
    if not nearCheckIn then
        Reply(src, 'Yasal bir hastane check-in noktasinda degilsiniz.')
        return
    end

    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return end
    EnsureWoundColumnsLoaded(state)

    if not state.has_wound then
        Reply(src, 'Uzerinizde kayitli bir yara izi yok -- tedaviye gerek duyulmadi.')
        return
    end

    local ballisticId = state.wound_ballistic_id

    -- Yara kapatildi (tedavi BASARILI); ANINDA sizinti.
    state.has_wound = false
    MySQL.prepare('UPDATE matrix_player_state SET has_wound = 0 WHERE citizenid = ?', { state.citizenid })
    LeakToBureauOnTreatment(state.citizenid, ballisticId)

    -- Yatak-basi Adli Sorgu oturumu acilir: sanik ya "kabul eder" ya
    -- "inkar eder" (yalan). /yarasorgucevap [itiraf|inkar] ile cevaplanir.
    BedsideSessions[state.citizenid] = {
        defendant_src     = src,
        ballistic_id      = ballisticId,
        conviction_weight = 0.0,
        lie_count         = 0
    }

    Reply(src, 'Tedavi tamamlandi. Yara ANINDA Buro raporuna dustu.')
    Reply(src, ('[YATAK BASI SORGU] Yaranizin kaynagini soruluyor. /yarasorgucevap itiraf VEYA /yarasorgucevap inkar ile yanit verin.'))
end, false)


--- Yatak başı sorguya cevap. İnkar (yalan) ederken kanıt (matrix_forensic_
--- evidence ballistic_id kaydı) VARSA lie_count++ ve Mahkumiyet Skoru
--- (conviction_weight) sabit %40 tırmanır; %100'de Matrix.Bureau.
--- ExecuteVerdict (MEVCUT Karakter Wipe) tetiklenir.
RegisterCommand('yarasorgucevap', function(src, args)
    if type(src) ~= 'number' or src <= 0 then return end
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return end

    local session = BedsideSessions[state.citizenid]
    if not session then
        Reply(src, 'Acik bir yatak-basi sorgu oturumunuz yok.')
        return
    end

    local answer = tostring(args[1] or ''):lower()
    local isLie       = (answer == 'inkar' or answer == 'yalan')
    local isConfession = (answer == 'itiraf' or answer == 'dogru')
    if not isLie and not isConfession then
        Reply(src, 'Kullanim: /yarasorgucevap [itiraf|inkar]')
        return
    end

    if isConfession then
        session.conviction_weight = 1.0
    elseif isLie and session.ballistic_id then
        -- Balistik kovan arsiviyle capraz kontrol: bu balistik_id'ye ait
        -- KAYITLI adli kanit varsa yalan MALIYETLI olur.
        local hasEvidence = MySQL.scalar.await(
            'SELECT COUNT(*) FROM matrix_forensic_evidence WHERE ballistic_id = ?', { session.ballistic_id }) or 0
        if tonumber(hasEvidence) and tonumber(hasEvidence) > 0 then
            session.lie_count = session.lie_count + 1
            session.conviction_weight = math_min(
                session.conviction_weight + (Config.Hospital.ConvictionWeightLiePenalty or 0.40), 1.0)
        end
    end

    Reply(src, ('[YATAK BASI SORGU] Yalan-Sayaci:%d | Mahkumiyet-Skoru:%%%.1f'):format(
        session.lie_count, session.conviction_weight * 100.0))

    if session.conviction_weight >= (Config.Hospital.ConvictionWipeThreshold or 1.0) then
        BedsideSessions[state.citizenid] = nil
        pcall(Matrix.Bureau.ExecuteVerdict, 0, {
            defendant_citizenid = state.citizenid,
            defendant_src        = src,
            lie_count             = session.lie_count
        })
    end
end, false)


-- =====================================================================
-- [KATMAN 3] ARMA-TARZI BÖLGESEL BOT YARALANMASI
-- server/logistics.lua'nın ZATEN VAR OLAN 'matrix:server:reportDealerCombatDamage'
-- event'ine İKİNCİ bir dinleyici -- Matrix.Logistics.ApplyCombatDamage
-- (dolayısıyla combat_damage/OnDealerEliminated eşiği) HİÇ dokunulmadan
-- kendi akışını yürütmeye devam eder; bu yalnızca aynı hasar bildirimini
-- uzuv bazında dağıtan PARALEL (yıkıcı olmayan) bir gözlemcidir.
-- =====================================================================
Matrix.Wounds.Bots = Matrix.Wounds.Bots or {} -- [botId] = { wound_zone, leg_injury, head_injury, arm_injury, permanently_crippled, installed_prosthetic }
local DamageTickCounter = {} -- [botId] = accumulator (deterministik bolge secimi icin)


local function GetOrInitBotWound(botId)
    local w = Matrix.Wounds.Bots[botId]
    if w then return w end
    w = { wound_zone = nil, leg_injury = 0.0, head_injury = 0.0, arm_injury = 0.0,
          permanently_crippled = 0, installed_prosthetic = 0 }
    Matrix.Wounds.Bots[botId] = w
    return w
end


local function PersistBotWound(botId, w)
    MySQL.prepare([[
        UPDATE matrix_bots
        SET wound_zone = ?, leg_injury = ?, head_injury = ?, arm_injury = ?, permanently_crippled = ?, installed_prosthetic = ?
        WHERE id = ?
    ]], { w.wound_zone, w.leg_injury, w.head_injury, w.arm_injury, w.permanently_crippled, w.installed_prosthetic, botId })
end


--- Deterministik bölge seçimi: RNG YOK. Girdi = botId + o bota şimdiye
--- kadar isabet eden vuruş sayısı (monoton sayaç) -- ChecksumOf mod
--- ZoneOrder uzunluğuna kırpılır.
local function PickWoundZone(botId)
    DamageTickCounter[botId] = (DamageTickCounter[botId] or 0) + 1
    local raw = ('%d#%d'):format(botId, DamageTickCounter[botId])
    local idx = (ChecksumOf(raw, 17) % #Config.BotWounds.ZoneOrder) + 1
    return Config.BotWounds.ZoneOrder[idx]
end


-- ★ KATMAN 21 [SimCheck 21.2]: 3. parametre `forcedZone` opsiyoneldir.
-- GERCEK oyun akisi (asagidaki AddEventHandler) bu argumani HICBIR ZAMAN
-- gecmez -- PickWoundZone(botId)'in botId+sayac'a bagli determinizmi
-- BIREBIR korunur. YALNIZCA server/matrix_diagnostics.lua DERIN katmani,
-- bir test botunun ID'sine (auto-increment, restart'lar arasi
-- ONGORULEMEZ) bagimli olmadan hangi uzva hasar dustugunu SABITLEYEREK
-- 4-hane hassasiyet iddialarini FLAKY OLMAYAN sekilde dogrulamak icin
-- gecer.
function Matrix.Wounds.ApplyBotRegionalDamage(botId, rawDamage, forcedZone)
    local bot = Matrix.Bots[botId]
    if not bot then return end
    if bot.status ~= 'active' then return end -- comatose/deceased botlara YENİ hasar dağıtılmaz

    local w = GetOrInitBotWound(botId)
    if w.permanently_crippled == 1 then
        -- Kalici sakat bir bot artik "yeni" bir uzva hasar biriktirmez --
        -- zaten -%90 kalici ceza altindadir (bkz. GetMovementMultiplier/
        -- GetAccuracyMultiplier).
        return
    end

    local zone = forcedZone or PickWoundZone(botId)
    w.wound_zone = zone
    local delta = Matrix.Clamp(tonumber(rawDamage) or 0.05, 0.0, 1.0) * 0.25 -- tekil isabet basina kismi birikim

    if zone == 'leg' then
        w.leg_injury = Matrix.Clamp(w.leg_injury + delta, 0.0, 1.0)
        if w.leg_injury >= (Config.BotWounds.CripplingThreshold or 1.0) then
            w.permanently_crippled = 1
            Matrix.Log('WOUNDS', '[KALICI SAKATLIK] Bot #%d bacaktan KALICI olarak sakat kaldi.', botId)
        end
    elseif zone == 'head' then
        w.head_injury = Matrix.Clamp(w.head_injury + delta, 0.0, 1.0)
    elseif zone == 'arm' then
        w.arm_injury = Matrix.Clamp(w.arm_injury + delta, 0.0, 1.0)
        if w.arm_injury >= (Config.BotWounds.CripplingThreshold or 1.0) then
            w.permanently_crippled = 1
            Matrix.Log('WOUNDS', '[KALICI SAKATLIK] Bot #%d koldan KALICI olarak sakat kaldi.', botId)
        end
    elseif zone == 'torso' then
        -- Govde: cortisol_level %90'a KILITLENIR, denetim-uyarisi anomali
        -- orani +%300, stash hirsizligi tetiklenir.
        if bot.biology then bot.biology.cortisol_level = Config.BotWounds.TorsoCortisolLock or 0.90 end

        local trapId = bot.state and bot.state.trap_house_id
        local zoneId = trapId and Matrix.Inspector and Matrix.Inspector.GetZoneForTrapHouse
            and Matrix.Inspector.GetZoneForTrapHouse(trapId) or nil
        if zoneId then
            MySQL.prepare([[
                INSERT INTO matrix_zone_ledger (zone_id, audit_anomaly_rate, updated_at)
                VALUES (?, ?, NOW())
                ON DUPLICATE KEY UPDATE audit_anomaly_rate = audit_anomaly_rate * ?, updated_at = NOW()
            ]], { zoneId, Config.BotWounds.TorsoAuditAnomalyMultiplier or 3.0, Config.BotWounds.TorsoAuditAnomalyMultiplier or 3.0 })
        end

        if trapId then
            local stashId = ('matrix_trap_stash_%d'):format(trapId)
            local invOk, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], stashId)
            if invOk and inv and inv.items then
                for _, item in pairs(inv.items) do
                    if item and item.name then
                        pcall(function()
                            exports['ox_inventory']:RemoveItem(stashId, item.name,
                                math_min(item.count or 0, math_floor(Config.BotWounds.TorsoStashTheftGrams or 10)))
                        end)
                        break
                    end
                end
            end
        end

        Matrix.Log('WOUNDS', '[GOVDE YARASI] Bot #%d -- kortizol kilitli, denetim anomali +%%%d, stash hirsizligi tetiklendi.',
            botId, math_floor(((Config.BotWounds.TorsoAuditAnomalyMultiplier or 3.0) - 1.0) * 100))
    end

       Matrix.Wounds.Bots[botId] = w
    PersistBotWound(botId, w)

    -- ★ [GEMINI-3] ONESYNC STATEBAG TRAVMA KİLİDİ (Context Drift Önleme)
    local _botForStateBag = Matrix.Bots[botId]
    if _botForStateBag and _botForStateBag.state and _botForStateBag.state.net_id then
        local _pedEntity = NetworkGetEntityFromNetworkId(_botForStateBag.state.net_id)
        if _pedEntity and _pedEntity ~= 0 and DoesEntityExist(_pedEntity) then
            pcall(function()
                Entity(_pedEntity).state.limb_damage = {
                    leg_injury           = w.leg_injury,
                    head_injury          = w.head_injury,
                    arm_injury           = w.arm_injury,
                    wound_zone           = w.wound_zone,
                    permanently_crippled = w.permanently_crippled,
                    installed_prosthetic = w.installed_prosthetic,
                    updated_at           = Matrix.Now()
                }
            end)
        end
    end

    if _botForStateBag then
        local _trapHouseId = _botForStateBag.state and _botForStateBag.state.trap_house_id
        if _trapHouseId then
            pcall(function()
                MySQL.prepare([[
                    INSERT INTO matrix_forensic_evidence
                        (ballistic_id, evidence_type, striation_quality, fingerprint_id,
                         fingerprint_quality, match_certainty, sealed_as_crime_weapon,
                         coords_x, coords_y, coords_z, biological_trauma,
                         inflicted_force_striation, created_at)
                    VALUES (?, 'biological_trauma', 1.0, ?, 1.0, 0.0, 0, 0.0, 0.0, 0.0, 1, ?, NOW())
                ]], {
                    _botForStateBag.dna_id or 'UNKNOWN',
                    _botForStateBag.dna_id or 'UNKNOWN',
                    w.leg_injury + w.head_injury + w.arm_injury
                })
            end)
        end
    end
end


AddEventHandler('matrix:server:reportDealerCombatDamage', function(botId, rawDamage)
    botId = tonumber(botId)
    if not botId then return end
    local ok, err = pcall(Matrix.Wounds.ApplyBotRegionalDamage, botId, rawDamage)
    if not ok then
        Matrix.Log('WOUNDS', '[HATA] ApplyBotRegionalDamage basarisiz (yutuldu): %s', tostring(err))
    end
end)


-- =====================================================================
-- [KATMAN 3] EFEKTIF CEZA ÇARPANLARI (client/server tarafından okunur)
-- =====================================================================
function Matrix.Wounds.GetMovementMultiplier(botId)
    local w = Matrix.Wounds.Bots[botId]
    if not w then return 1.0 end
    if w.permanently_crippled == 1 and w.leg_injury >= (Config.BotWounds.CripplingThreshold or 1.0) then
        return 1.0 - (Config.PermanentCrippling.LegMovementPenalty or 0.90)
    end
    if w.leg_injury > 0.0 then
        return 1.0 - (Config.BotWounds.LegSpeedPenalty or 0.60)
    end
    return 1.0
end


function Matrix.Wounds.GetDetectionRangeCap(botId)
    local w = Matrix.Wounds.Bots[botId]
    if not w or w.head_injury <= 0.0 then return nil end
    return Config.BotWounds.HeadDetectionRangeCap or 15.0
end


function Matrix.Wounds.GetAccuracyMultiplier(botId)
    local w = Matrix.Wounds.Bots[botId]
    if not w then return 1.0 end
    if w.permanently_crippled == 1 and w.arm_injury >= (Config.BotWounds.CripplingThreshold or 1.0) then
        return 1.0 - (Config.PermanentCrippling.ArmCraftingShootingPenalty or 0.90)
    end
    if w.arm_injury > 0.0 then
        return 1.0 - (Config.BotWounds.ArmAccuracyPenalty or 0.50)
    end
    return 1.0
end


--- Kol yaralı bir bot ateş ettiğinde bıraktığı kovan kalitesi -- Config.
--- BotWounds.ArmPerfectCasingQuality (1.0, "kusursuz") sabitlenir.
function Matrix.Wounds.GetShellCasingQualityOverride(botId)
    local w = Matrix.Wounds.Bots[botId]
    if not w or w.arm_injury <= 0.0 then return nil end
    return Config.BotWounds.ArmPerfectCasingQuality or 1.0
end


-- =====================================================================
-- [KATMAN 3] KARABORSA AMELİYATI — F10 panelinden bota Trap House
-- tedavisi ata: 12 saat dispatch kabul edemez, sonunda (KALICI OLMAYAN)
-- uzuv hasarları sıfırlanır.
-- =====================================================================
function Matrix.Wounds.BeginTrapHouseTreatment(botId)
    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    local w = GetOrInitBotWound(botId)
    if w.permanently_crippled == 1 then return false, 'permanently_crippled' end
    if (w.leg_injury or 0.0) <= 0.0 and (w.head_injury or 0.0) <= 0.0 and (w.arm_injury or 0.0) <= 0.0 then
        return false, 'no_injury'
    end

    local until_ = Matrix.Now() + (Config.BotWounds.TrapHouseTreatmentHours or 12) * 3600
    bot.state.medical_lock_until = until_
    if Matrix.Dispatches and Matrix.Dispatches[botId] then
        Matrix.CompleteDispatch(botId, 'panic_recall')
    end

    MySQL.prepare('UPDATE matrix_bots SET medical_lock_until = FROM_UNIXTIME(?) WHERE id = ?', { until_, botId })
    Matrix.Log('WOUNDS', '[KARABORSA AMELIYATI] Bot #%d tedaviye alindi -- %d saat dispatch KABUL EDEMEZ.',
        botId, Config.BotWounds.TrapHouseTreatmentHours or 12)
    return true
end


function Matrix.Wounds.IsUnderMedicalLock(botId)
    local bot = Matrix.Bots[botId]
    if not bot or not bot.state or not bot.state.medical_lock_until then return false end
    return Matrix.Now() < bot.state.medical_lock_until
end


local function ProcessMedicalLockCycle()
    for botId, bot in pairs(Matrix.Bots) do
        local until_ = bot.state and bot.state.medical_lock_until
        if until_ and Matrix.Now() >= until_ then
            bot.state.medical_lock_until = nil
            local w = GetOrInitBotWound(botId)
            if w.permanently_crippled ~= 1 then
                w.leg_injury, w.head_injury, w.arm_injury, w.wound_zone = 0.0, 0.0, 0.0, nil
                PersistBotWound(botId, w)
                Matrix.Log('WOUNDS', '[TEDAVI TAMAMLANDI] Bot #%d uzuv hasarlari sifirlandi, dispatch tekrar aktif.', botId)
            end
            MySQL.prepare('UPDATE matrix_bots SET medical_lock_until = NULL WHERE id = ?', { botId })
        end
    end
end


CreateThread(function()
    while true do
        Wait(Config.Tick.SecondsPerMinute * Config.Tick.IntervalMs)
        local ok, err = pcall(ProcessMedicalLockCycle)
        if not ok then Matrix.Log('WOUNDS', '[HATA] ProcessMedicalLockCycle basarisiz (yutuldu): %s', tostring(err)) end
    end
end)


RegisterCommand('kadroameliyat', function(src, args)
    local botId = tonumber(args[1])
    if not botId then Reply(src, 'Kullanim: /kadroameliyat [botId] (F10 panelinden kullanin)'); return end
    local ok, reason = Matrix.Wounds.BeginTrapHouseTreatment(botId)
    TriggerClientEvent('matrix:client:actionNotify', src, ok, ok and 'Bot tedaviye alindi.' or ('Ameliyat basarisiz: ' .. tostring(reason)))
end, false)


-- =====================================================================
-- [KATMAN 4] HAYALET CERRAH (PHANTOM SURGEON) — deterministik 6 saatlik
-- rotasyon, epoch-saat sağlama toplamı (RNG YOK).
-- =====================================================================
-- ★ KATMAN 21 [SimCheck 21.3]: saf hesaplama epochBucket'i parametre
-- olarak alacak sekilde AYRISTIRILDI (davranis DEGISMEDI -- Get
-- PhantomDoctorLocation asagida AYNI formulu Matrix.Now()'dan turetilen
-- gercek bucket ile cagirir). Bu, diagnostics'in "10.000 epoch ileri/geri"
-- determinizm testini GERCEK uretim formulunu (bir kopyasini DEGIL)
-- cagirarak yapmasini saglar.
local function ComputePhantomIndexForBucket(epochBucket, coordsList)
    local raw = ('PHANTOM#%d'):format(epochBucket)
    return (ChecksumOf(raw, 71) % #coordsList) + 1
end


function Matrix.Wounds.GetPhantomDoctorLocation()
    local coordsList = Config.PhantomDoctor.Coords
    local intervalSeconds = (Config.PhantomDoctor.RotationIntervalHours or 6) * 3600
    local epochBucket = math_floor(Matrix.Now() / intervalSeconds)
    local idx = ComputePhantomIndexForBucket(epochBucket, coordsList)
    return coordsList[idx], idx
end


-- ★ TANI-YALNIZCA: matrix_diagnostics.lua disinda cagirmayin.
function Matrix.Wounds.__ComputePhantomIndexForEpochBucket(epochBucket)
    return ComputePhantomIndexForBucket(epochBucket, Config.PhantomDoctor.Coords)
end


--- Karaborsa Ameliyat Sözleşmesi: $60,000 (bank='front company' ya da
--- cash) karşılığında botu 24 saatlik 'surgery' (comatose durumu, MEVCUT
--- status enum'unun bir üyesi) durumuna alır. Ameliyat sirasinda klinikte
--- bir siber sizinti uretilir; Buro yogunlugu yuksekse federal bir baskin
--- tetiklenebilir.
function Matrix.Wounds.BeginPhantomSurgery(src, botId)
    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    local w = GetOrInitBotWound(botId)
    if w.permanently_crippled ~= 1 then return false, 'not_crippled' end

    local doctorCoords = Matrix.Wounds.GetPhantomDoctorLocation()
    local ped = GetPlayerPed(src)
    local playerCoords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    if not playerCoords or VectorDistance(playerCoords, doctorCoords) > 25.0 then
        return false, 'not_at_doctor'
    end

    local player = Matrix.QBX:GetPlayer(src)
    if not player then return false, 'player_not_found' end

    local price = Config.PhantomDoctor.SurgeryPrice or 60000.0
    local bank = (player.PlayerData.money and player.PlayerData.money.bank) or 0
    local cash = (player.PlayerData.money and player.PlayerData.money.cash) or 0
    local account = nil
    if bank >= price then account = 'bank' elseif cash >= price then account = 'cash' end
    if not account then return false, 'insufficient_funds' end

    local removeOk, removeResult = pcall(function() return player.Functions.RemoveMoney(account, price, 'phantom-surgery') end)
    if not removeOk or removeResult ~= true then return false, 'charge_failed' end

    bot.status = 'comatose'
    Matrix.MarkBotDirty(botId)
    if Matrix.Dispatches and Matrix.Dispatches[botId] then
        Matrix.CompleteDispatch(botId, 'panic_recall')
    end

    local surgeryUntil = Matrix.Now() + (Config.PhantomDoctor.SurgeryHours or 24) * 3600
    bot.state.medical_lock_until = surgeryUntil

    -- Klinikte üretilen siber sızıntı -- en yakın trap house'un MEVCUT
    -- cyber_leak_intensity biriktiricisine eklenir (Matrix.Bureau.
    -- TriggerPropaganda İLE AYNI birimin bir kerelik enjeksiyonu).
    local nearestTrapId = FindNearestTrapHouse(doctorCoords)
    if nearestTrapId then
        pcall(Matrix.Bureau.TriggerPropaganda, nearestTrapId)

        local velocity = Matrix.Bureau.GetBureaucraticVelocity and Matrix.Bureau.GetBureaucraticVelocity() or 1.0
        if velocity >= (Config.PhantomDoctor.FederalStingIntensityThreshold or 1.5) then
            pcall(Matrix.Bureau.IssueRaid, nearestTrapId)
            Reply(src, '[FEDERAL BASKIN] Buro yogunlugu ameliyat sirasinda kliniginizi buldu!')
        end
    end

    MySQL.prepare('UPDATE matrix_bots SET medical_lock_until = FROM_UNIXTIME(?) WHERE id = ?', { surgeryUntil, botId })
    Reply(src, ('[HAYALET CERRAH] $%.0f odendi. Bot #%d %d saatlik ameliyata alindi.'):format(
        price, botId, Config.PhantomDoctor.SurgeryHours or 24))
    return true
end


local function ProcessPhantomSurgeryCycle()
    for botId, bot in pairs(Matrix.Bots) do
        if bot.status == 'comatose' and bot.state and bot.state.medical_lock_until
            and Matrix.Now() >= bot.state.medical_lock_until then
            local w = GetOrInitBotWound(botId)
            if w.permanently_crippled == 1 then
                w.permanently_crippled = 0
                w.installed_prosthetic = 1
                w.leg_injury, w.head_injury, w.arm_injury, w.wound_zone = 0.0, 0.0, 0.0, nil
                PersistBotWound(botId, w)
                bot.status = 'active'
                bot.state.medical_lock_until = nil
                Matrix.MarkBotDirty(botId)
                MySQL.prepare('UPDATE matrix_bots SET medical_lock_until = NULL WHERE id = ?', { botId })
                Matrix.Log('WOUNDS', '[AMELIYAT BASARILI] Bot #%d protez takildi, kalici sakatlik giderildi.', botId)
            end
        end
    end
end


CreateThread(function()
    while true do
        Wait(Config.Tick.SecondsPerMinute * Config.Tick.IntervalMs)
        local ok, err = pcall(ProcessPhantomSurgeryCycle)
        if not ok then Matrix.Log('WOUNDS', '[HATA] ProcessPhantomSurgeryCycle basarisiz (yutuldu): %s', tostring(err)) end
    end
end)


RegisterCommand('hayaletcerrah', function(src, args)
    local botId = tonumber(args[1])
    if not botId then Reply(src, 'Kullanim: /hayaletcerrah [botId] (doktorun konumundayken)'); return end
    local ok, reason = Matrix.Wounds.BeginPhantomSurgery(src, botId)
    TriggerClientEvent('matrix:client:actionNotify', src, ok, ok and 'Ameliyat basladi.' or ('Ameliyat basarisiz: ' .. tostring(reason)))
end, false)


lib.callback.register('matrix:callback:getPhantomDoctorLocation', function(src)
    return Matrix.Wounds.GetPhantomDoctorLocation()
end)


-- =====================================================================
-- BOOT: matrix_bots'un YENİ kolonlarını RAM önbelleğine yükle (ilk
-- açılışta veya restart sonrası -- BuildBotUpsert/LoadBotsFromDatabase
-- İLE AYNI 'once at start' deseni, o fonksiyonların KENDİSİ DEĞİŞTİRİLMEZ).
-- =====================================================================
CreateThread(function()
    Wait(2000) -- server/main.lua'nın LoadBotsFromDatabase'i tamamlamasi icin kisa bir bekleme
    local ok, rows = pcall(function()
        return MySQL.query.await(
            'SELECT id, wound_zone, leg_injury, head_injury, arm_injury, permanently_crippled, installed_prosthetic FROM matrix_bots')
    end)
    if not ok or type(rows) ~= 'table' then return end
    for _, row in ipairs(rows) do
        Matrix.Wounds.Bots[row.id] = {
            wound_zone            = row.wound_zone,
            leg_injury              = tonumber(row.leg_injury) or 0.0,
            head_injury             = tonumber(row.head_injury) or 0.0,
            arm_injury               = tonumber(row.arm_injury) or 0.0,
            permanently_crippled    = tonumber(row.permanently_crippled) or 0,
            installed_prosthetic    = tonumber(row.installed_prosthetic) or 0
        }
    end
    Matrix.Log('WOUNDS', 'Bot yara profilleri yuklendi (%d satir).', #rows)
end)
