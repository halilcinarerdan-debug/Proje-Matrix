-- =====================================================================
-- MATRIX HUD / client/hud.lua  (KATMAN 6 — RENDEZVOUS/TAHKİMAT EKİ)
-- Saf metin tabanlı, monokrom (yeşil/beyaz/kırmızı) Taktik Durum HUD'u.
--
-- ★ SERTLEŞTİRME (v1, korunuyor):
--   [S1] lib.inputDialog çıktıları, ExecuteCommand'a girmeden önce KATI
--        sanitizasyondan geçer: sayısal alanlar yalnızca tam sayı,
--        [1, Config.Hud.MaxBotIdInputValue]; plaka yalnızca [%w%-_%.] ve
--        Config.Hud.MaxPlateInputLength sınırında. Boşluk/quote/semicolon/
--        newline İÇEREN hiçbir girdi komuta ULAŞMAZ — ExecuteCommand
--        argüman-ayrıştırıcısına asla kirli string gitmez. Bu, sunucu
--        thread'inde mikrosaniyelik bile bir "parse + yetkisiz arg"
--        oluşmasını yapısal olarak engeller.
--   [S2] Gelen snapshot satırları `#lines <= Config.Hud.MaxHudLines` ile
--        sınırlandırılır (RAM-bomb savunması).
--   [S3] lib.notify varsa geçersiz girdi sessizce YUTULMAZ, kullanıcıya
--        görünür bir uyarı basılır (ama komut TETİKLENMEZ).
--
-- ★ KATMAN 5 EVRİM (korunuyor):
--   [E1] SIFIR SAYI STANDARDI, [E2] MULTI-WAYPOINT TAKTİK ROTA MOTORU.
--
-- ★ KATMAN 5 ULTIMATE (korunuyor):
--   [U1]-[U8]: /sevket kaldırıldı, Canlı Kadro tıklanabilir bot aksiyonları,
--   mekanik tutukluk tahliyesi, karaborsa/mali rapor alt menüleri, COMINT,
--   Acil Tahliye.
--
-- ★ KATMAN 6 (bu sürüm — yeni işler):
--   [K1] F10 -> "Mühimmat / Envanter Ameliyatı": Canlı Kadro'daki bir bota
--        tıklayınca açılan aksiyon menüsüne eklendi. Bot envanterini
--        (server/trap_house_interior.lua, lib.callback) listeler ve
--        oyuncunun kendi envanterindeki bir slotu bota elden teslim
--        etmesini sağlar (sayısal slot/miktar [S1] ile AYNI disiplinde
--        sanitize edilir).
--   [K2] F10 -> "Kapı Sürgü Tahkimatı": trap house ID + hedef seviye
--        (1-3) alır, server/door_reinforcement.lua'ya iletir. Trap House
--        ID ve seviye [S1] ile AYNI SanitizeNumericArg'dan geçer.
--   [K3] 'L' tuşu: Operasyon Not Defterini artık F10 menüsüne girmeden
--        doğrudan açar (mevcut OpenMatrixNotepad'e ek bir giriş noktası —
--        F10 içindeki eski giriş KALDIRILMADI).
--   [K4] 'matrix:client:rendezvousAssigned' event'i: server/rendezvous.lua
--        bir karaborsa silah/mühimmat buluşması ayarladığında GPS
--        waypoint'i otomatik ayarlar VE koordinatı Not Defterine ekler —
--        çiğ koordinat yalnızca oyuncunun KENDİ isteğiyle aldığı bir
--        teslimatın konumu olduğundan (server tarafından üretilip
--        gönderildiğinden) [S1] sanitizasyonuna tabi DEĞİLDİR (giden bir
--        ExecuteCommand argümanı değil, gelen güvenilir veridir).
--   Fiziksel dünya öğeleri (kapı blip'leri, satıcı/pusu ped'leri, tezgah/
--   paketleme prompt'ları, ambient dekor) client/trap_house_client.lua'da
--   AYRI bir dosyada tutulur — bu dosyanın kapsamı HUD + F10 menüsü olarak
--   kalır (mevcut dosya ayrımıyla tutarlı).
-- =====================================================================


local hudActive = false
local hudLines  = {}   -- { { text=..., header=true/false, danger=true/false }, ... }


local COLOR_HEADER = { 235, 235, 235 }
local COLOR_VALUE  = { 110, 255, 140 }
local COLOR_DIM    = { 90, 140, 100 }
local COLOR_DANGER = { 255, 70, 70 } -- ★ [U3][U5]: mekanik tutukluk / sinyal ucgenleme uyarilari


local MAX_HUD_LINES  = (Config.Hud and Config.Hud.MaxHudLines) or 64
local MAX_PLATE_LEN  = (Config.Hud and Config.Hud.MaxPlateInputLength) or 32
local MAX_BOT_ID     = (Config.Hud and Config.Hud.MaxBotIdInputValue) or 999999
local MAX_WAYPOINT_LEN = (Config.Hud and Config.Hud.MaxWaypointInputLength) or 64
local WEAPON_EVAC_MS = ((Config.Forensics and Config.Forensics.WeaponEvacuationSeconds) or 6) * 1000


local function DrawMonoLine(x, y, text, r, g, b, scale)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextScale(scale, scale)
    SetTextColour(r, g, b, 235)
    SetTextDropshadow(1, 0, 0, 0, 200)
    SetTextEdge(1, 0, 0, 0, 180)
    SetTextEntry('STRING')
    AddTextComponentString(text)
    DrawText(x, y)
end


-- ★ [S1] Sanitizasyon yardımcıları -------------------------------------


--- Sayısal string arg: tam sayı, [minVal, maxVal] aralığında. Aksi halde nil.
--- NaN/inf/+/- boşluk/karakter — hepsi reddedilir.
local function SanitizeNumericArg(v, minVal, maxVal)
    if v == nil then return nil end
    local n = tonumber(v)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    n = math.floor(n)
    if n < (minVal or 1) or n > (maxVal or MAX_BOT_ID) then return nil end
    return tostring(n)
end


--- Plaka arg: yalnızca [%w%-_%.] karakterleri, <= MAX_PLATE_LEN. Boş string
--- GEÇERLİDİR (kalıcı araç/foot anlamına gelir). Boşluk/quote/semicolon/nil
--- → nil (reddedilir).
local function SanitizePlateArg(v)
    if v == nil then return '' end
    local s = tostring(v)
    if #s > MAX_PLATE_LEN then return nil end
    if s == '' then return '' end
    -- Boşluk, quote, ; , |, newline, tab: hepsi YASAK (ExecuteCommand parser'ı
    -- boşluktan böler; enjeksiyon vektörünü kapatıyoruz).
    if s:find('[^%w%-_%.]') then return nil end
    return s
end


--- Rank arg: whitelist. Client, sunucudaki Config'i görmez ama bu üç değer
--- sabit — yine de ExecuteCommand'a SADECE bu üç string'den biri geçer.
local VALID_RANK_ARGS = {
    Leader = true, Logistics_Officer = true, Chemist = true
}


local function SanitizeRankArg(v)
    if v == nil then return nil end
    local s = tostring(v)
    if not VALID_RANK_ARGS[s] then return nil end
    return s
end


--- ★ KATMAN 7 [OPSEC] DEAD DROP ID TOKEN — "DD-1"/"DD-2"/"DD-3" gibi
--- Config.Supplier.DeadDrops.id'lerine deterministik olarak eşlenen bir
--- token'ı tanır. Rota motorunun "koordinat mı, trap house mu, dead drop mu"
--- ayrımı ZATEN sunucu tarafında yapılıyordu (bkz. SanitizeWaypointArg'ın
--- dosya-başı yorumu) — burada yalnızca BU ÜÇÜNCÜ formatın karakter kümesi
--- ve GERÇEKTEN var olan bir id'ye karşılık geldiği client tarafında
--- ÖN-DOĞRULANIR. Config.Supplier paylaşımlı (shared/config.lua) olduğundan
--- client bu listeyi zaten görür — yeni bir sunucu round-trip'i GEREKMEZ.
--- Token boşluk/virgül İÇERMEZ (tek bir kelimedir), bu yüzden ExecuteCommand'ın
--- tek-argüman disiplinini BOZMAZ.
local DEAD_DROP_TOKEN_PATTERN = '^[Dd][Dd]%-(%d+)$'


local function SanitizeDeadDropArg(s)
    local idStr = s:match(DEAD_DROP_TOKEN_PATTERN)
    if not idStr then return nil end
    local id = tonumber(idStr)
    if not id then return nil end
    if not (Config.Supplier and Config.Supplier.DeadDrops) then return nil end
    for _, drop in ipairs(Config.Supplier.DeadDrops) do
        if drop.id == id then
            return ('DD-%d'):format(id)
        end
    end
    return nil
end


--- ★ [E2] Waypoint arg: "x,y,z" / "x, y, z" / "x y z" (/coords çıktısı
--- boşlukla gelir) vektörü, salt tam sayı Trap House ID, YA DA (KATMAN 7
--- [OPSEC]) "DD-<sayı>" Dead Drop token'ı kabul eder. Vektör/Trap House
--- dalının kabul ettiği karakter kümesi yalnızca [rakam, nokta, virgül,
--- eksi, boşluk] olarak KALIR — harf/quote/semicolon İÇEREN hiçbir girdi
--- kabul edilmez; DD- token'ı bu genel kurala girmeden, kendi dar/whitelist
--- deseniyle AYRICA ve ÖNCE tanınır. ExecuteCommand tek bir argüman bekler
--- (boşluk argümanı BÖLER), bu yüzden kabul edilen boşluklar/virgüller
--- BURADA tek bir "," ayracına normalize edilir; döndürülen string ASLA
--- boşluk içermez. Format çözümlemesi (trap house mu, koordinat mı, dead
--- drop mu) sunucu tarafında yapılır; client yalnızca karakter kümesini,
--- uzunluğu ve normalize edilmiş biçimi doğrular.
local function SanitizeWaypointArg(v)
    if v == nil then return nil end
    local s = tostring(v)
    s = s:match('^%s*(.-)%s*$') -- baş/son boşlukları kırp
    if s == '' then return nil end
    if #s > MAX_WAYPOINT_LEN then return nil end


    -- ★ KATMAN 7 [OPSEC]: Dead Drop token'ı önce denenir (harf taşıdığı
    -- için aşağıdaki rakam-only filtreye ASLA girmez).
    local ddToken = SanitizeDeadDropArg(s)
    if ddToken then return ddToken end


    -- Yalnızca rakam/nokta/virgül/eksi/boşluk — başka HİÇBİR karakter kabul edilmez.
    if s:find('[^%d%.,%-%s]') then return nil end


    -- "x y z" / "x, y , z" gibi karışık ayraçları TEK "," ayracına indir.
    s = s:gsub('%s+', ','):gsub(',+', ',')
    s = s:match('^,*(.-),*$') -- baş/son ayraçları temizle


    if s == '' then return nil end
    if #s > MAX_WAYPOINT_LEN then return nil end
    return s
end


--- ★ [E3] DİNAMİK WAYPOINT ESNEKLİĞİ: ara uğrak alanları (1-3) artık
--- ZORUNLU DEĞİL. Boş bırakılan bir alan GEÇERLİDİR — sabit bir "atla"
--- placeholder'ı (ROUTE_WAYPOINT_SKIP) döner; ExecuteCommand tek argüman
--- beklediği için boş string GÖNDERİLEMEZ (pozisyonel argümanları kaydırır),
--- bu yüzden boş bırakma her zaman bu sabit, boşluksuz token ile temsil
--- edilir. DOLU bir alan yine [S1] ile aynı katı SanitizeWaypointArg
--- kontrolünden geçer — geçersizse (harf/quote/vb.) nil döner (komut iptal).
local ROUTE_WAYPOINT_SKIP = 'nil'


local function SanitizeOptionalWaypointArg(v)
    if v == nil then return ROUTE_WAYPOINT_SKIP end
    local trimmed = tostring(v):match('^%s*(.-)%s*$')
    if trimmed == '' then return ROUTE_WAYPOINT_SKIP end
    return SanitizeWaypointArg(trimmed)
end


--- ★ [E2] Araç tipi arg: whitelist Config.Logistics.VehicleTypes anahtarlarından
--- türetilir (paylaşımlı Config, client'ta da görünür) — sabit metin dışında
--- hiçbir şey ExecuteCommand'a geçmez.
local function SanitizeVehicleTypeArg(v)
    if v == nil then return nil end
    local s = tostring(v)
    if not (Config.Logistics and Config.Logistics.VehicleTypes and Config.Logistics.VehicleTypes[s]) then
        return nil
    end
    return s
end


local function BuildVehicleTypeOptions()
    local options = {}
    for vtype in pairs(Config.Logistics and Config.Logistics.VehicleTypes or {}) do
        options[#options + 1] = { value = vtype, label = vtype }
    end
    table.sort(options, function(a, b) return a.value < b.value end)
    return options
end


local function NotifyInvalidInput(reason)
    if lib and lib.notify then
        lib.notify({
            title       = '[GECERSIZ GIRD]',
            description = reason or 'Komut icin gecersiz parametre.',
            type        = 'error'
        })
    else
        print(('[MATRIX:HUD] Gecersiz girdi: %s'):format(tostring(reason)))
    end
end


-- =====================================================================
-- ★ [E1] SIFIR SAYI STANDARDI — Bültene Çeviri Motoru
-- =====================================================================
local BULLETIN_CORTISOL   = (Config.Hud and Config.Hud.Bulletins and Config.Hud.Bulletins.Cortisol)
    or { CalmMax = 0.20, AnxietyMax = 0.60 }
local BULLETIN_FATIGUE    = (Config.Hud and Config.Hud.Bulletins and Config.Hud.Bulletins.Fatigue)
    or { FreshMax = 0.30, ChronicMax = 0.80 }
local BULLETIN_MECHANICAL = (Config.Hud and Config.Hud.Bulletins and Config.Hud.Bulletins.Mechanical)
    or { PristineMin = 0.80, WornMin = 0.40 }


local function FormatCortisolBulletin(value)
    value = tonumber(value)
    if not value then return nil end
    if value < BULLETIN_CORTISOL.CalmMax then
        return '[NABIZ: SOĞUKKANLI SUBAY]'
    elseif value <= BULLETIN_CORTISOL.AnxietyMax then
        return '[NABIZ: ANKSİYETE BAŞLANGICI — TETİKTE]'
    else
        return '[NABIZ: AKUT PANİK ATAK KRİZİ — ELLERİN TİTRİYOR]'
    end
end


local function FormatFatigueBulletin(value)
    value = tonumber(value)
    if not value then return nil end
    if value < BULLETIN_FATIGUE.FreshMax then
        return '[KONDİSYON: DİNÇ]'
    elseif value <= BULLETIN_FATIGUE.ChronicMax then
        return '[KONDİSYON: KRONİK BİTKİNLİK — REFLEKSLER YAVAŞ]'
    else
        return '[KONDİSYON: NÖRON HASARI SINIRI — BEYİN SAKATLIĞI RİSKİ]'
    end
end


local function FormatMechanicalBulletin(value)
    value = tonumber(value)
    if not value then return nil end
    if value > BULLETIN_MECHANICAL.PristineMin then
        return '[MEKANİK: KUSURSUZ CONDITION]'
    elseif value >= BULLETIN_MECHANICAL.WornMin then
        return '[MEKANİK: YİV-SET AŞINMASI — BALİSTİK MUTASYON AKTİF]'
    else
        return '[MEKANİK: KRİTİK YİV ERİMESİ — TUTUKLUK VE PERMADEATH RİSKİ]'
    end
end


--- Sunucudan gelen tek bir snapshot satırını (ham metrik veya düz metin)
--- nihai ekran metnine çevirir. Bilinmeyen/geçersiz metrik → nil (satır
--- ekrana hiç basılmaz; çiğ sayı asla sızmaz).
local function FormatBulletinLine(metric, value, label)
    label = label or ''
    if metric == 'cortisol_level' then
        local text = FormatCortisolBulletin(value)
        return text and (label .. text) or nil
    elseif metric == 'fatigue_level' then
        local text = FormatFatigueBulletin(value)
        return text and (label .. text) or nil
    elseif metric == 'durability' or metric == 'wear_level' then
        local text = FormatMechanicalBulletin(value)
        return text and (label .. text) or nil
    end
    return nil
end


-- =====================================================================
-- Toggle / snapshot
-- =====================================================================
local function ToggleHud(forceState)
    local newState = (forceState ~= nil) and forceState or (not hudActive)
    if newState == hudActive then return end


    hudActive = newState
    if not hudActive then
        hudLines = {}
    end
    TriggerServerEvent('matrix:server:hudToggled', hudActive)
end


-- ★ [U5] danger alanı da taşınır: sunucu (server/market.lua BuildSnapshot)
-- COMINT üçgenleme uyarısı gibi satırları `danger=true` ile işaretler,
-- render thread bunu kırmızı çizer (bkz. aşağıdaki RENDER THREAD).
RegisterNetEvent('matrix:client:hudSnapshot', function(lines)
    if not hudActive then return end
    if type(lines) ~= 'table' then return end
    -- ★ [S2] RAM-bomb savunması: sunucu kontrollü de olsa, üst sınır koy.
    if #lines > MAX_HUD_LINES then return end


    -- ★ [E1] Dönüşüm TEK SEFERDE burada yapılır (per-frame değil) — 0 Resmon
    -- bütçesi korunur. Render thread'i yalnızca hazır metni çizer.
    local converted = {}
    for i = 1, #lines do
        local line = lines[i]
        if type(line) == 'table' then
            if line.metric ~= nil then
                local text = FormatBulletinLine(line.metric, line.value, line.label)
                if text then
                    converted[#converted + 1] = { text = text, header = line.header and true or false, danger = line.danger and true or false }
                end
            elseif type(line.text) == 'string' then
                converted[#converted + 1] = { text = line.text, header = line.header and true or false, danger = line.danger and true or false }
            end
        end
    end
    hudLines = converted
end)


RegisterCommand('hud', function()
    ToggleHud()
end, false)


RegisterKeyMapping('hud', 'Taktik HUD ac/kapat', 'keyboard', Config.Hud and Config.Hud.ToggleKey or 'F6')


-- ★ [U5] COMINT: aynı HUD'u açan/kapatan ikinci bir tuş bağı. Ayrı bir
-- panel/render thread AÇILMAZ — [COMINT ISTIHBARAT PROFILI] bloğu zaten
-- ana snapshot'ın bir parçasıdır (bkz. server/market.lua BuildSnapshot).
RegisterCommand('comintpanel', function()
    ToggleHud()
end, false)
RegisterKeyMapping('comintpanel', 'COMINT Istihbarat Profili (Taktik HUD) ac/kapat', 'keyboard', (Config.Comint and Config.Comint.ToggleKey) or 'K')


AddEventHandler('onClientResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    hudActive = false
    hudLines  = {}
end)


-- =====================================================================
-- ★ KATMAN 5 ULTIMATE [U3]: MEKANİK TUTUKLUK TESPİTİ & TAHLİYE
--
-- Mermi-sayısı-azalma (ammo-delta) tespiti kullanılır — IsPedShooting'in
-- tam/otomatik ateş serilerinde kaçırabileceği ardışık atışları KAÇIRMAZ
-- (bir frame'de birden fazla mermi azalmışsa o kadar shot event tetiklenir).
-- Silah kimliği/slotu SUNUCUYA GÜVENİLMEDEN, ox_inventory'nin kendi
-- GetCurrentWeapon export'undan okunur; sunucu ayrıca o slot'un weapon_serial
-- metadata'sını kendi okuyarak doğrular (bkz. server/forensics.lua).
-- =====================================================================
local weaponJamActive = false
local weaponJamSlot    = nil


RegisterNetEvent('matrix:client:weaponJamStateChanged', function(slot, jammed)
    weaponJamActive = jammed and true or false
    weaponJamSlot    = jammed and slot or nil
end)


-- =====================================================================
-- ★ DÜZELTME: KOMUT SONUÇ BİLDİRİMİ (silent-failure önleme)
-- F10 menüsünden tetiklenen komutlar (/operatiftasfiye, /panikiptal, vb.)
-- şimdiye kadar YALNIZCA chat:addMessage ile cevap veriyordu — oyuncunun
-- chat penceresi kapalıysa (FiveM'de varsayılan, T'ye basılana kadar) bir
-- rütbe reddi veya hata SESSİZCE kayboluyor, "tıkladım ama hiçbir şey
-- olmuyor" izlenimi veriyordu. Artık bu komutlar SONUCU (başarılı/
-- başarısız, sebebiyle) AYRICA bu event üzerinden de gönderir; burada
-- lib.notify ile EKRANDA gösterilir — chat açık olsun olmasın görülür.
-- =====================================================================
RegisterNetEvent('matrix:client:actionNotify', function(ok, message)
    if lib and lib.notify then
        lib.notify({
            title       = ok and '[ISLEM BASARILI]' or '[ISLEM BASARISIZ]',
            description = tostring(message or ''),
            type        = ok and 'success' or 'error',
            duration    = 6000
        })
    end
end)


local lastWeaponHash = nil
local lastAmmoInClip = nil
-- ★ [DÜZELTME]: FiveM'in backtick hash-literal uzantısı (`WEAPON_UNARMED`)
-- standart Lua sözdizimi DEĞİLDİR — vanilla luac ile syntax-check
-- edilemez. GetHashKey ile ayni joaat hash'i üretir, davranış AYNI kalır.
local WEAPON_UNARMED_HASH = GetHashKey('WEAPON_UNARMED')


CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local weaponHash = GetSelectedPedWeapon(ped)


        if weaponHash and weaponHash ~= 0 and weaponHash ~= WEAPON_UNARMED_HASH then
            local ammo = GetAmmoInPedWeapon(ped, weaponHash)


            if weaponHash ~= lastWeaponHash then
                -- Silah degisti (kusanma/sokma) - taban cizgisini sifirdan kur,
                -- bu geciste "atis" tetiklenmez.
                lastWeaponHash = weaponHash
                lastAmmoInClip = ammo
            elseif type(lastAmmoInClip) == 'number' and type(ammo) == 'number' and ammo < lastAmmoInClip then
                local shotsFired = lastAmmoInClip - ammo
                local ok, current = pcall(function() return exports['ox_inventory']:GetCurrentWeapon() end)
                if ok and type(current) == 'table' and current.weapon and current.slot then
                    for _ = 1, shotsFired do
                        TriggerServerEvent('matrix:server:reportWeaponShotFired', current.weapon, current.slot)
                    end
                end
                lastAmmoInClip = ammo
            elseif type(lastAmmoInClip) ~= 'number' or (type(ammo) == 'number' and ammo > lastAmmoInClip) then
                -- Ilk okuma veya sarjor doldurma/degistirme - taban cizgisi guncellenir.
                lastAmmoInClip = ammo
            end
        else
            lastWeaponHash = nil
            lastAmmoInClip = nil
        end


        -- Tutukluk aktifken DisablePlayerFiring'in her frame calismasi
        -- gerektigi icin bu thread de Wait(0)'a siki tutunur; aksi halde
        -- hafif bir 100ms poll yeterlidir (mermi degisimi tek frame'lik
        -- gecici bir olay degildir, bir sonraki atisa kadar kalici kalir).
        Wait(weaponJamActive and 0 or 100)
    end
end)


CreateThread(function()
    while true do
        if weaponJamActive then
            DisablePlayerFiring(PlayerId(), true)
            DrawMonoLine(0.36, 0.90, '[MEKANIK: SILAH TUTUKLUK YAPTI]', COLOR_DANGER[1], COLOR_DANGER[2], COLOR_DANGER[3], 0.45)
            Wait(0)
        else
            Wait(250)
        end
    end
end)


local function BeginWeaponJamEvacuation()
    if not weaponJamActive or not weaponJamSlot then
        NotifyInvalidInput('Su an tutuklu bir silahiniz yok.')
        return
    end


    local slot = weaponJamSlot
    local completed = lib.progressCircle({
        duration     = WEAPON_EVAC_MS,
        position     = 'bottom',
        label        = 'Silah Kurma Kolu Cekiliyor / Sikisan Kovan Tahliye Ediliyor...',
        useWhileDead = false,
        canCancel    = true,
        disable      = { move = true, car = true, combat = true }
    })


    if completed then
        TriggerServerEvent('matrix:server:clearWeaponJam', slot)
    end
end


RegisterCommand('silahtahliye', function()
    BeginWeaponJamEvacuation()
end, false)
RegisterKeyMapping('silahtahliye', 'Sikisan Silahi Tahliye Et (Tutukluk Giderme)', 'keyboard', 'X')


-- =====================================================================
-- ★ YERALTI GENISLETMESI KATMAN 2: OYUNCU-HASAR TESPITI
-- Vanilla 'CEventNetworkEntityDamage' gameEventTriggered'i, yerel oyuncu
-- kurbanken YALNIZCA sunucuya bir bildirim gonderir -- server/wound_
-- system.lua bunu, o saldirganin EN SON ates ettigi silahin (ZATEN VAR
-- OLAN reportWeaponShotFired onbellegi) balistik imzasiyla eslestirir.
-- =====================================================================
AddEventHandler('gameEventTriggered', function(eventName, args)
    if eventName ~= 'CEventNetworkEntityDamage' then return end

    -- CEventNetworkEntityDamage args: [1]=victim [2]=attacker [3]=weaponDamage(bool)
    -- [4]=victimDied(bool) [5]=weaponType(bool) [6]=weaponHash [7]=baseDamage
    -- -- yalnizca YEREL oyuncu kurbanken ve gercek bir silah hasari varken islenir.
    local victim, attacker, weaponDamage, weaponHash = args[1], args[2], args[3], args[6]
    if victim ~= PlayerPedId() or not weaponDamage then return end

    local attackerServerId = nil
    if attacker and attacker ~= 0 and NetworkGetEntityIsNetworked(attacker) then
        if IsPedAPlayer(attacker) then
            attackerServerId = GetPlayerServerId(NetworkGetPlayerIndexFromPed(attacker))
        end
    end

    local weaponHashStr = weaponHash and tostring(weaponHash) or nil
    TriggerServerEvent('matrix:server:reportPlayerWounded', attackerServerId, weaponHashStr)
end)


--- ★ [U3] F10 -> "/namludegistir": elde tutulan silahin slotunu ox_inventory
--- GetCurrentWeapon export'undan cozup sunucu komutuna [S1] disiplinindeki
--- gibi yalnizca temiz bir tam sayi olarak iletir.
local function OpenNamluDegistirAction()
    local ok, current = pcall(function() return exports['ox_inventory']:GetCurrentWeapon() end)
    if not ok or type(current) ~= 'table' or not current.slot then
        NotifyInvalidInput('Elinizde degistirilebilir bir silah yok.')
        return
    end
    ExecuteCommand(('namludegistir %d'):format(current.slot))
end


--- ★ KATMAN 6 [K1]: F10 -> Tezgahta Tamir. Aynı GetCurrentWeapon deseniyle
--- silah slotunu çözer, ancak /namludegistir'in AKSİNE nakit yerine
--- server/workbench.lua'nın bileşen kontrolünden geçer (para YOK).
local function OpenWorkbenchRepairAction()
    local ok, current = pcall(function() return exports['ox_inventory']:GetCurrentWeapon() end)
    if not ok or type(current) ~= 'table' or not current.slot then
        NotifyInvalidInput('Elinizde tamir edilebilir bir silah yok.')
        return
    end
    TriggerServerEvent('matrix:server:workbench:repairWeapon', current.slot)
end


--- ★ Herhangi bir telefon kaynağının çağrı başlangıcı/bitişinde
--- çağırması beklenen client-side köprü. Üretimde telefon kaynağının
--- kendi event'lerine (qb-phone/lb-phone/vb. — bu dosya hangisinin kurulu
--- olduğunu varsaymaz) bağlanıp bunu tetiklemesi gerekir.
exports('ReportPhoneCallState', function(active, isBurner)
    TriggerServerEvent('matrix:server:reportPhoneCallState', active, isBurner)
end)


-- =====================================================================
-- TAKTİK KOMUTA MENÜSÜ (ox_lib Context Menu, F10) — MÜHÜRLÜ + EVRİM
-- =====================================================================
local function OpenTrapHouseDurumDialog()
    local input = lib.inputDialog('/traphousedurum - Trap House Sorgusu', {
        { type = 'number', label = 'Trap House ID', required = true, min = 1, max = 2147483646 }
    })
    if not input then return end


    local houseId = SanitizeNumericArg(input[1], 1, 2147483646)
    if not houseId then NotifyInvalidInput('Trap House ID gecersiz.'); return end


    ExecuteCommand(('traphousedurum %s'):format(houseId))
end


--- ★ KATMAN 6: "Trap House'a Git" — client/trap_house_client.lua'nın kapı
--- blip'lerini beslemek için zaten kullandığı AYNI
--- 'matrix:callback:getTrapHouseLocations' callback'i (server/
--- trap_house_interior.lua) burada da okunur; yeni bir sunucu-tarafı
--- endpoint icat EDİLMEZ. server/rendezvous.lua'nın otomatik waypoint
--- deseniyle (bkz. dosya başı [K4] notu) AYNI native — SetNewWaypoint —
--- kullanılır; ekstra bir kaynak/bağımlılık GEREKMEZ.
local function OpenTrapHouseWaypointDialog()
    local list = lib.callback.await('matrix:callback:getTrapHouseLocations', false)
    if type(list) ~= 'table' or #list == 0 then
        if lib and lib.notify then
            lib.notify({ title = '[TRAP HOUSE]', description = 'Henuz kayitli bir trap house yok.', type = 'inform' })
        end
        return
    end


    local options = {}
    for i = 1, #list do
        local entry = list[i]
        if type(entry) == 'table' and type(entry.id) == 'number' and type(entry.coords) == 'vector3' then
            options[#options + 1] = { value = tostring(entry.id), label = ('#%d — %s'):format(entry.id, entry.label or 'Trap House') }
        end
    end
    if #options == 0 then return end


    local input = lib.inputDialog('Trap House\'a Git (Waypoint)', {
        { type = 'select', label = 'Trap House', required = true, options = options }
    })
    if not input then return end


    local chosenId = tonumber(input[1])
    local target
    for i = 1, #list do
        if list[i].id == chosenId then target = list[i]; break end
    end
    if not target then return end


    SetNewWaypoint(target.coords.x, target.coords.y)
    if lib and lib.notify then
        lib.notify({ title = '[TRAP HOUSE]', description = ('Waypoint ayarlandi: #%d %s'):format(target.id, target.label or ''), type = 'inform' })
    end
end


local function OpenRutbeAtaDialog()
    local input = lib.inputDialog('/rutbeata - Hiyerarsi Rutbe Atamasi', {
        { type = 'number', label = 'Hedef Server ID', required = true, min = 1, max = 65535 },
        { type = 'select', label = 'Rutbe', required = true, options = {
            { value = 'Leader',            label = 'Leader (Baron)' },
            { value = 'Logistics_Officer', label = 'Logistics_Officer (Lojistik Subayi)' },
            { value = 'Chemist',           label = 'Chemist (Kimyager)' }
        } }
    })
    if not input then return end


    local targetSrc = SanitizeNumericArg(input[1], 1, 65535)
    if not targetSrc then NotifyInvalidInput('Hedef Server ID gecersiz.'); return end


    local rank = SanitizeRankArg(input[2])
    if not rank then NotifyInvalidInput('Rutbe secimi gecersiz.'); return end


    ExecuteCommand(('rutbeata %s %s'):format(targetSrc, rank))
end


--- ★ [E2][E3] "Rota Çiz" — Multi-Waypoint Taktik Rota Motoru diyaloğu.
--- 0-3 ara uğrak (ARTIK ZORUNLU DEĞİL, boş bırakılabilir) + 1 ZORUNLU final
--- hedef toplanır; her alan ya "x,y,z" vektörü ya da bir Trap House ID'sidir.
--- Dolu alanlar [S1] ile aynı sıkılıkta sanitize edilir; boş bırakılan ara
--- uğraklar ROUTE_WAYPOINT_SKIP placeholder'ı ile gönderilip sunucu
--- tarafında (server/main.lua: /rotaciz) rota zincirinden drop edilir.
--- Format çözümlemesi (koordinat mı, trap house mu) ve fiziksel güvenlik
--- guard'ları (ışınlanma koruması, Co-Op Mutex) da sunucu tarafında yürütülür.
--- ★ [U1] Bota bindirip intikali BAŞLATMA işlemi EKSTRA bir /sevket
--- komutuna GEREK DUYMAZ — Matrix.BeginRouteDispatch (server/main.lua)
--- bu dialog onaylandığı AN asenkron olarak tetiklenir ve bot kendiliğinden
--- arabaya binip yola çıkar; varışta kargo otomatik Trap House deposuna
--- aktarılır (bkz. server/main.lua Matrix.DepositDealerCargoToTrapStash).
local function OpenRotaCizDialog()
    local input = lib.inputDialog('/rotaciz - Multi-Waypoint Taktik Rota (Otomatik Intikal)', {
        {
            type = 'number', label = 'Bot ID',
            description = 'Rota cizilecek dealer botunun ID numarasi',
            required = true, min = 1, max = MAX_BOT_ID
        },
        {
            type = 'input', label = '1. Ugrak Noktasi (opsiyonel)',
            description = '"x,y,z" veya "x y z" veya Trap House ID veya "DD-1/2/3" (Dead Drop) — BOS BIRAKILABILIR',
            required = false, max = MAX_WAYPOINT_LEN
        },
        {
            type = 'input', label = '2. Ugrak Noktasi (opsiyonel)',
            description = '"x,y,z" veya "x y z" veya Trap House ID veya "DD-1/2/3" (Dead Drop) — BOS BIRAKILABILIR',
            required = false, max = MAX_WAYPOINT_LEN
        },
        {
            type = 'input', label = '3. Ugrak Noktasi (opsiyonel)',
            description = '"x,y,z" veya "x y z" veya Trap House ID veya "DD-1/2/3" (Dead Drop) — BOS BIRAKILABILIR',
            required = false, max = MAX_WAYPOINT_LEN
        },
        {
            type = 'input', label = 'Final Hedef (Ana Us / Trap House) — ZORUNLU',
            description = '"x,y,z" veya "x y z" veya Trap House ID veya "DD-1/2/3" (Dead Drop) — varista kargo otomatik depoya aktarilir',
            required = true, max = MAX_WAYPOINT_LEN
        },
        {
            type = 'input', label = 'Plaka (bos = kalici arac/foot)',
            required = false, max = MAX_PLATE_LEN
        },
        {
            type = 'select', label = 'Arac Tipi', required = true,
            options = BuildVehicleTypeOptions()
        }
    })
    if not input then return end


    local botId = SanitizeNumericArg(input[1], 1, MAX_BOT_ID)
    if not botId then NotifyInvalidInput('Bot ID gecersiz.'); return end


    -- ★ [E3] Ara uğraklar (1-3): boş bırakma GEÇERLİDİR (atlanır); DOLU
    -- olup da karakter kümesini ihlal eden bir girdi yine REDDEDİLİR.
    local waypointArgs = {}
    for i = 2, 4 do
        local wp = SanitizeOptionalWaypointArg(input[i])
        if not wp then
            NotifyInvalidInput(('Uğrak #%d geçersiz (boş bırakabilirsiniz; doluysa yalnızca rakam, ".", ",", "-", boşluk).'):format(i - 1))
            return
        end
        waypointArgs[#waypointArgs + 1] = wp
    end


    -- Final hedef HALA ZORUNLU — boş bırakılamaz.
    local finalWp = SanitizeWaypointArg(input[5])
    if not finalWp then
        NotifyInvalidInput('Final Hedef geçersiz veya boş bırakılamaz (yalnızca rakam, ".", ",", "-", boşluk).')
        return
    end


    local plate = SanitizePlateArg(input[6])
    if plate == nil then
        NotifyInvalidInput('Plaka yalnizca harf/rakam/-/_/. icerebilir (max ' .. MAX_PLATE_LEN .. ').')
        return
    end


    local vehicleType = SanitizeVehicleTypeArg(input[7])
    if not vehicleType then NotifyInvalidInput('Arac tipi gecersiz.'); return end


    ExecuteCommand(('rotaciz %s %s %s %s %s %s %s'):format(
        botId, waypointArgs[1], waypointArgs[2], waypointArgs[3], finalWp, plate, vehicleType))
end


--- ★ KATMAN 6 [K2]: "Kapı Sürgü Tahkimatı". Trap House ID + hedef seviye
--- (1-3, sıralı yükseltme) [S1] ile AYNI SanitizeNumericArg disiplininden
--- geçer; server/door_reinforcement.lua fiyat/yetki/sıra kontrolünü ayrıca
--- kendi tarafında da yapar (client sanitizasyonu bir GÜVEN kaynağı DEĞİL,
--- yalnızca ExecuteCommand/enjeksiyon yüzeyini kapatan bir ön filtredir).
local function OpenDoorReinforcementDialog()
    local input = lib.inputDialog('Kapı Sürgü Tahkimatı', {
        {
            type = 'number', label = 'Trap House ID',
            required = true, min = 1, max = 2147483646
        },
        {
            type = 'select', label = 'Hedef Seviye (sıralı yükseltilmelidir)', required = true, options = {
                { value = '1', label = 'Seviye 1 — Takviyeli Ahşap Sürgü' },
                { value = '2', label = 'Seviye 2 — Çelik Sürgü Barikatı' },
                { value = '3', label = 'Seviye 3 — Çift Katlı Çelik Barikat (Maks)' }
            }
        }
    })
    if not input then return end


    local houseId = SanitizeNumericArg(input[1], 1, 2147483646)
    if not houseId then NotifyInvalidInput('Trap House ID gecersiz.'); return end


    local level = SanitizeNumericArg(input[2], 1, 3)
    if not level then NotifyInvalidInput('Seviye secimi gecersiz.'); return end


    TriggerServerEvent('matrix:server:doorReinforcement:install', tonumber(houseId), tonumber(level))
end


local function OpenMatrixDump()
    ExecuteCommand('matrixdump')
end


-- =====================================================================
-- ★ KATMAN 5 ULTIMATE [U2]: BOT AKSİYON MENÜSÜ (Tasfiye / Denetleyici Ata)
-- Canlı Kadro raporundaki bir BOT satırına tıklandığında açılır.
-- ★ KATMAN 6 [K1]: "Mühimmat / Envanter Ameliyatı" eklendi.
-- =====================================================================
local OpenAssignInspectorDialog -- ileri bildirim (OpenBotActionsMenu tarafından kullanilir)
local OpenBotInventoryOpsMenu   -- ★ KATMAN 6: ileri bildirim
local OpenGiveItemToBotDialog   -- ★ KATMAN 6: ileri bildirim
local OpenAmmoRunDialog         -- ★ KATMAN 7 [T2]: ileri bildirim


--- ★ DÜZELTME: butona basıldığı AN (sunucu cevabı beklenmeden) küçük bir
--- onay bildirimi basar — böylece "tıkladım ama bir şey olmuyor" hissi
--- ortadan kalkar: tıklama gerçekten kaydedildiyse HER ZAMAN görülür.
--- Kesin sonuç (başarılı/başarısız) 'matrix:client:actionNotify' ile
--- sunucudan ayrıca gelir (bkz. asağıdaki RegisterNetEvent).
local function NotifyActionSent(label)
    if lib and lib.notify then
        lib.notify({
            title       = '[KOMUT GONDERILDI]',
            description = label,
            type        = 'inform',
            duration    = 2000
        })
    end
end


-- ★ KATMAN 7 FAZ 2: BAGAJ / ENVANTER AMELIYATI -- bota kalici atanmis
-- aracin plakasina bagli ox_inventory stash'ine trap house deposundan
-- miktar aktarir (bkz. server/logistics.lua Matrix.Logistics.
-- LoadTrunkFromStash). Esya adi, plaka argumaniyla AYNI karakter kumesiyle
-- ([S1] SanitizePlateArg) sinirlandirilir -- ox_inventory item isimleri
-- zaten bosluksuz/kucuk-harf-alt-cizgi konvansiyonundadir.
local function OpenBotTrunkOpsDialog(botId)
    local input = lib.inputDialog('Arac Bagaji - Envanter Ameliyati', {
        {
            type = 'input', label = 'Esya Adi (ox_inventory item ismi)',
            description = 'Ornek: meth_bag, coke_brick, ammo-9mm', required = true
        },
        { type = 'number', label = 'Miktar', required = true, min = 1, max = 9999, default = 1 }
    })
    if not input then return end


    local itemName = SanitizePlateArg(input[1])
    if not itemName or itemName == '' then NotifyInvalidInput('Esya adi gecersiz (yalnizca harf/rakam/-/_/.).'); return end


    local count = SanitizeNumericArg(input[2], 1, 9999)
    if not count then NotifyInvalidInput('Miktar gecersiz.'); return end


    NotifyActionSent(('Bot #%d bagajina yukleme gonderiliyor...'):format(botId))
    ExecuteCommand(('bagajyukle %d %s %s'):format(botId, itemName, count))
end


local function OpenBotActionsMenu(botId, roleLabel)
    local options = {
        {
            title       = 'Operatif Tasfiye Et (Iliskiyi Kes)',
            description = 'Botu matristen ve RAM onbellekten KALICI olarak siler (Hard-Delete). Geri alinamaz.',
            icon        = 'user-slash',
            iconColor   = '#ff4444',
            onSelect    = function()
                NotifyActionSent(('Bot #%d tasfiye emri gonderiliyor...'):format(botId))
                ExecuteCommand(('operatiftasfiye %d'):format(botId))
            end
        },
        {
            -- ★ KATMAN 5 ULTIMATE [U8]: sunucu, botun su an aktif bir
            -- sevkiyatta olup olmadigini kendi dogrular (Matrix.Dispatches[botId])
            -- - client tarafinda ekstra bir durum kontrolu YAPILMAZ, bu yuzden
            -- aksiyon her bot icin gosterilir; uygun degilse sunucu acik bir
            -- hata mesajiyla geri doner (bkz. server/main.lua /panikiptal).
            title       = 'Acil Tahliye (Gorevi Iptal Et)',
            description = 'Botun mevcut rotasini/mutex kilidini kirar, isinlanma OLMADAN son hizla senin konumuna yollar.',
            icon        = 'truck-medical',
            iconColor   = '#ff4444',
            onSelect    = function()
                NotifyActionSent(('Bot #%d icin acil tahliye emri gonderiliyor...'):format(botId))
                ExecuteCommand(('panikiptal %d'):format(botId))
            end
        },
        {
            -- ★ KATMAN 6 [K1]: bot envanterini görüntüle / elden teslim et.
            title       = 'Muhimmat / Envanter Ameliyati',
            description = 'Botun envanterini goruntule; elinizdeki bir esyayi bota elden teslim edin.',
            icon        = 'boxes-stacked',
            onSelect    = function() OpenBotInventoryOpsMenu(botId) end
        },
        {
            -- ★ KATMAN 7 FAZ 2: Bagaj/Envanter Ameliyati.
            title       = 'Arac Bagaji / Envanter Ameliyati',
            description = 'Bota kalici atanmis aracin bagajina, trap house deposundan miktar aktar.',
            icon        = 'truck-ramp-box',
            onSelect    = function() OpenBotTrunkOpsDialog(botId) end
        }
    }


    -- ★ KATMAN 7 FAZ 2: yalnizca dealer rolundeki botlarda gosterilir --
    -- bkz. server/market.lua Matrix.Market.StreetDealing.SetBotDealing'in
    -- ayni rol kontrolu.
    if roleLabel == 'dealer' then
        options[#options + 1] = {
            title       = 'Sokak Satisina Cikar',
            description = 'Botu surekli sokak "kes" satis dongusune sokar (aktivite: street_dealing).',
            icon        = 'person-walking-arrow-right',
            onSelect    = function()
                NotifyActionSent(('Bot #%d sokak satisina cikariliyor...'):format(botId))
                ExecuteCommand(('botsokaga %d'):format(botId))
            end
        }
        options[#options + 1] = {
            title       = 'Sokaktan Geri Cek',
            description = 'Botu sokak satisi aktivitesinden cikarip bekleme durumuna (idle) alir.',
            icon        = 'person-walking-arrow-loop-left',
            onSelect    = function()
                NotifyActionSent(('Bot #%d sokaktan geri cekiliyor...'):format(botId))
                ExecuteCommand(('botsokaga %d geri'):format(botId))
            end
        }
    end


    if Config.Inspector and Config.Inspector.PromotableRoles and Config.Inspector.PromotableRoles[roleLabel] then
        options[#options + 1] = {
            title       = 'Bolge Denetleyicisi Olarak Ata',
            description = 'Bu kuryeyi bir bolgenin Inspector\'i yapar (SIGINT kostebek taramasi baslar).',
            icon        = 'user-shield',
            onSelect    = function() OpenAssignInspectorDialog(botId) end
        }
    end


    -- ★ KATMAN 7 [T2]: yalnizca Lojistik rutbesindeki (bot.role == 'runner')
    -- botlarda gosterilir -- bkz. server/logistics.lua Matrix.Logistics.
    -- DispatchAmmoRun'daki ayni rol eslemesi yorumu.
    if roleLabel == 'runner' then
        options[#options + 1] = {
            title       = 'Muhimmat Dagitim Gorevi',
            description = 'Bu lojistik botu trap house deposundan silah/muhimmat/yedek namlu cekip belirttiginiz Tetikci bota (Bot-ID) elden teslim eder.',
            icon        = 'truck-fast',
            onSelect    = function() OpenAmmoRunDialog(botId) end
        }
    end


    local menuId = ('matrix_bot_actions_%d'):format(botId)
    lib.registerContext({
        id      = menuId,
        title   = ('=== BOT #%d ISLEMLERI ==='):format(botId),
        menu    = 'matrix_roster_report',
        options = options
    })
    lib.showContext(menuId)
end


OpenAssignInspectorDialog = function(botId)
    local zoneOptions = {}
    for _, z in ipairs(Config.Market and Config.Market.Zones or {}) do
        zoneOptions[#zoneOptions + 1] = { value = tostring(z.id), label = z.label }
    end


    local input = lib.inputDialog('Denetleyici Atamasi', {
        { type = 'select', label = 'Bolge', required = true, options = zoneOptions }
    })
    if not input then return end


    local zoneId = SanitizeNumericArg(input[1], 1, 999999)
    if not zoneId then NotifyInvalidInput('Bolge secimi gecersiz.'); return end


    ExecuteCommand(('denetleyiciata %s %d'):format(zoneId, botId))
end


--- ★ KATMAN 6 [K1]: bota elden teslimat diyaloğu — slot/miktar [S1] ile
--- AYNI SanitizeNumericArg disiplininden geçer. ExecuteCommand'a DEĞİL,
--- structured bir TriggerServerEvent'e gider (mevcut 'matrix:server:
--- blackmarket:buyVehicle(catalogId)' deseniyle AYNI mimari — sayısal
--- veri doğrudan, string ExecuteCommand argümanı DEĞİL).
OpenGiveItemToBotDialog = function(botId)
    local input = lib.inputDialog('Bota Elden Esya Teslimi', {
        {
            type = 'number', label = 'Envanterinizdeki Slot Numarasi',
            description = 'ox_inventory ekranindan gorebileceginiz slot numarasi',
            required = true, min = 1, max = 2000
        },
        {
            type = 'number', label = 'Miktar', required = true, min = 1, max = 9999, default = 1
        }
    })
    if not input then return end


    local slot = SanitizeNumericArg(input[1], 1, 2000)
    if not slot then NotifyInvalidInput('Slot numarasi gecersiz.'); return end


    local count = SanitizeNumericArg(input[2], 1, 9999)
    if not count then NotifyInvalidInput('Miktar gecersiz.'); return end


    NotifyActionSent(('Bot #%d icin teslimat gonderiliyor...'):format(botId))
    TriggerServerEvent('matrix:server:trapHouseInterior:giveItemToBot', botId, tonumber(slot), tonumber(count))
end


--- ★ KATMAN 7 [T2]: Mühimmat Dağıtım Görevi hedef diyaloğu -- yalnızca
--- hedef Tetikçi Bot-ID istenir (kaynak lojistik botun ID'si zaten
--- tıklanan Canlı Kadro satırından biliniyor). Diğer sayısal girdi
--- diyaloglarıyla AYNI SanitizeNumericArg/ExecuteCommand disiplininden
--- geçer -- server/logistics.lua /muhimmatsevk komutu tüm gerçek
--- doğrulamayı (rol, mesafe, sessizlik guard'ı, stash içeriği) sunucu
--- tarafında ayrıca yapar.
OpenAmmoRunDialog = function(sourceBotId)
    local input = lib.inputDialog('Muhimmat Dagitim Gorevi', {
        {
            type = 'number', label = 'Hedef Tetikci Bot-ID',
            description = 'Sokakta pusuya yatmis kurye/tetikci botun Bot-ID numarasi',
            required = true, min = 1, max = MAX_BOT_ID
        }
    })
    if not input then return end


    local targetBotId = SanitizeNumericArg(input[1], 1, MAX_BOT_ID)
    if not targetBotId then NotifyInvalidInput('Hedef Bot-ID gecersiz.'); return end


    NotifyActionSent(('Bot #%d icin muhimmat dagitim gorevi gonderiliyor...'):format(sourceBotId))
    ExecuteCommand(('muhimmatsevk %d %s'):format(sourceBotId, targetBotId))
end


--- ★ KATMAN 6 [K1]: bot envanterini lib.callback ile SORAR (ölü bir liste
--- basar, tıklanabilir değildir — envanterdeki eşyaları oyuncunun KENDİ
--- envanterinden bota TAŞIMASI için ayrı bir aksiyon aşağıda eklenir).
OpenBotInventoryOpsMenu = function(botId)
    local items = lib.callback.await('matrix:callback:getBotInventoryItems', false, botId)


    local options = {}
    if type(items) == 'table' then
        for _, it in ipairs(items) do
            options[#options + 1] = {
                title    = ('%s x%d (Slot %d)'):format(it.label or it.name, it.count or 1, it.slot or 0),
                disabled = true,
                icon     = 'box'
            }
        end
    end
    if #options == 0 then
        options[#options + 1] = { title = 'Bot envanteri bos veya okunamadi.', disabled = true, icon = 'box-open' }
    end


    options[#options + 1] = {
        title       = 'Elindeki Esyayi Bota Teslim Et',
        description = 'Kendi envanterinizden bir slot secip bu bota elden verin',
        icon        = 'hand-holding',
        onSelect    = function() OpenGiveItemToBotDialog(botId) end
    }


    lib.registerContext({
        id      = 'matrix_bot_inventory_ops',
        title   = ('=== BOT #%d MUHIMMAT / ENVANTER ==='):format(botId),
        menu    = ('matrix_bot_actions_%d'):format(botId),
        options = options
    })
    lib.showContext('matrix_bot_inventory_ops')
end


--- ★ KATMAN 5 EK EMİR: "Canlı Kadro & Hiyerarşi Raporu".
--- Sunucudan lib.callback ile TEK SEFERLİK (menü açıldığı an) telemetri
--- çeker — sürekli bir polling thread'i YOKTUR, bu yüzden 0 Resmon bütçesi
--- HUD kapalıyken de açıkken de bozulmaz: rapor yalnızca oyuncu bu menüyü
--- AÇTIĞINDA hesaplanır, saf istek/cevap (callback) yapısıyla.
--- ★ [U2] Artık her BOT satırı TIKLANABİLİR (server/main.lua'nın yapılı
--- `{kind,id,role,mole_flagged,text}` callback sözleşmesine göre).
local function OpenCanliKadroRaporu()
    local entries = lib.callback.await('matrix:callback:getRosterReport', false)
    if type(entries) ~= 'table' or #entries == 0 then
        if lib and lib.notify then
            lib.notify({
                title       = '[KADRO RAPORU]',
                description = 'Aktif unsur bulunamadi (bot veya oyuncu yok).',
                type        = 'inform'
            })
        end
        return
    end


    -- ★ DÜZELTME: bot ID'leri (Matrix.NextBotId) ve oyuncu server ID'leri
    -- (FiveM connection slot) TAMAMEN BAĞIMSIZ iki sayaçtır — aynı sayısal
    -- degere (örn. ikisi de "1") sahip olmaları normaldir ve ÇAKIŞMA
    -- DEĞİLDİR. Ama tek bir düz listede yan yana göründüklerinde "[BOT-ID: 1]"
    -- ile "[PLR-ID: 1]" birbirine KARIŞIYORDU (oyuncular yanlışlıkla
    -- kendi/başka bir oyuncunun devre dışı satırına tıklamaya çalışıyordu).
    -- Bu yüzden liste artık İKİ AYRI, başlıklı bölüme (BOTLAR / OYUNCULAR)
    -- kesin olarak ayrılır; ayrıca yalnızca BOT satırları `arrow = true`
    -- ile (bir alt menü açacağını gösteren sağ ok) işaretlenir — OYUNCU
    -- satırları HİÇBİR ZAMAN tıklanabilir değildir (disabled = true).
    -- `#options + 1` ile eklenir (index bazlı `options[i]` DEĞİL) — böylece
    -- filtrelenen bir satır olsa bile dizide ASLA boşluk (hole) oluşmaz.
    local options = {}
    local botHeaderAdded, playerHeaderAdded = false, false


    for i = 1, #entries do
        local e = entries[i]
        if type(e) == 'table' and type(e.text) == 'string' then
            if e.kind == 'bot' and type(e.id) == 'number' then
                if not botHeaderAdded then
                    options[#options + 1] = { title = '=== BOTLAR (BOT-ID) — TIKLA, ISLEM MENUSU ACILIR ===', disabled = true, icon = 'robot' }
                    botHeaderAdded = true
                end
                options[#options + 1] = {
                    title     = e.text,
                    icon      = e.mole_flagged and 'triangle-exclamation' or 'circle-dot',
                    iconColor = e.mole_flagged and '#ff4444' or nil,
                    arrow     = true,
                    onSelect  = function() OpenBotActionsMenu(e.id, e.role) end
                }
            else
                if not playerHeaderAdded then
                    options[#options + 1] = { title = '=== OYUNCULAR (PLR-ID) — BILGI AMACLI, TIKLANAMAZ ===', disabled = true, icon = 'user' }
                    playerHeaderAdded = true
                end
                options[#options + 1] = { title = e.text, disabled = true, icon = 'circle-dot' }
            end
        end
    end


    lib.registerContext({
        id    = 'matrix_roster_report',
        title = '=== CANLI KADRO & HIYERARSI RAPORU ===',
        menu  = 'matrix_tactical_menu',
        options = options
    })
    lib.showContext('matrix_roster_report')
end


-- =====================================================================
-- ★ KATMAN 5 ULTIMATE [U4]: KARABORSA TİCARET AĞI (F10 alt menüsü)
-- ★ [SEC-4] ROLLING CIPHER / DİNAMİK TOKEN MATRİSİ: artık TriggerServerEvent
-- statik/doğrudan çağrılmıyor. Önce lib.callback.await ile sunucudan tek
-- kullanımlık, zaman damgalı bir handshake token'ı istenir; sunucu
-- (server/blackmarket.lua) bu token'ı src+kind+catalogId'e mühürler, kısa
-- ömürlü tutar (15sn) ve doğrulama SONUCU FARK ETMEKSİZİN anında imha eder.
-- Bir Lua Executor artık TriggerServerEvent'i doğrudan çağırıp sahte
-- payload gönderemez -- önce GEÇERLİ bir token üretmesi gerekir, bu da
-- sunucunun kendi callback'inden geçmeden mümkün değildir.
-- =====================================================================
local function BuyWithHandshake(kind, catalogId, eventName)
    local token = lib.callback.await('matrix:callback:blackmarket:requestToken', false, kind, catalogId)
    if not token then
        lib.notify({ title = 'KARABORSA', description = 'Guvenli el sikisma basarisiz, tekrar deneyin.', type = 'error' })
        return
    end


    if catalogId ~= nil then
        TriggerServerEvent(eventName, catalogId, token)
    else
        TriggerServerEvent(eventName, token)
    end
end


local function OpenBlackMarketVehicles()
    local options = {}
    for _, v in ipairs(Config.BlackMarket and Config.BlackMarket.Vehicles or {}) do
        options[#options + 1] = {
            title       = v.label,
            description = ('Fiyat: $%d | Sinif: %s | Asinma: %.0f%%'):format(math.floor(v.price), v.vehicle_class, v.vehicle_wear * 100.0),
            icon        = 'car-side',
            onSelect    = function() BuyWithHandshake('vehicle', v.id, 'matrix:server:blackmarket:buyVehicle') end
        }
    end
    lib.registerContext({ id = 'matrix_bm_vehicles', title = '=== KARABORSA ARAC FILOSU ===', menu = 'matrix_blackmarket_menu', options = options })
    lib.showContext('matrix_bm_vehicles')
end


local function OpenBlackMarketWeapons()
    local options = {}
    for _, w in ipairs(Config.BlackMarket and Config.BlackMarket.Weapons or {}) do
        options[#options + 1] = {
            title       = w.label,
            description = ('Fiyat: $%d | Baslangic Asinma: %.0f%% | Teslimat: RENDEZVOUS (elden bulusma)'):format(math.floor(w.price), w.durability),
            icon        = 'gun',
            onSelect    = function() BuyWithHandshake('weapon', w.id, 'matrix:server:blackmarket:buyWeapon') end
        }
    end
    lib.registerContext({ id = 'matrix_bm_weapons', title = '=== KARABORSA SILAH KACAKCILIGI ===', menu = 'matrix_blackmarket_menu', options = options })
    lib.showContext('matrix_bm_weapons')
end


--- ★ KATMAN 6: Mühimmat kataloğu — silahlarla AYNI Rendezvous akışı.
local function OpenBlackMarketAmmo()
    local options = {}
    for _, a in ipairs(Config.BlackMarket and Config.BlackMarket.Ammo or {}) do
        options[#options + 1] = {
            title       = a.label,
            description = ('Fiyat: $%d | Teslimat: RENDEZVOUS (elden bulusma)'):format(math.floor(a.price)),
            icon        = 'box',
            onSelect    = function() BuyWithHandshake('ammo', a.id, 'matrix:server:blackmarket:buyAmmo') end
        }
    end
    lib.registerContext({ id = 'matrix_bm_ammo', title = '=== KARABORSA MUHIMMAT ===', menu = 'matrix_blackmarket_menu', options = options })
    lib.showContext('matrix_bm_ammo')
end


local function OpenBlackMarketBarrelAndPhones()
    local options = {
        {
            title       = (Config.BlackMarket and Config.BlackMarket.SpareBarrelLabel) or 'Yedek Namlu',
            description = ('Fiyat: $%d | /namludegistir ile takilir, tutukluk riskini sifirlar ve Buro arsivini kor eder'):format(
                math.floor((Config.BlackMarket and Config.BlackMarket.SpareBarrelPrice) or 0)),
            icon        = 'screwdriver-wrench',
            onSelect    = function() BuyWithHandshake('barrel', nil, 'matrix:server:blackmarket:buySpareBarrel') end
        }
    }
    for _, p in ipairs(Config.BlackMarket and Config.BlackMarket.BurnerPhones or {}) do
        options[#options + 1] = {
            title       = p.label,
            description = ('Fiyat: $%d | IMEI maskeleme aktif (COMINT: GUVENLI ACIK HAT)'):format(math.floor(p.price)),
            icon        = 'mobile-screen',
            onSelect    = function() BuyWithHandshake('burner_phone', p.id, 'matrix:server:blackmarket:buyBurnerPhone') end
        }
    end
    lib.registerContext({ id = 'matrix_bm_barrel_phones', title = '=== YEDEK NAMLU & ACIK HAT ===', menu = 'matrix_blackmarket_menu', options = options })
    lib.showContext('matrix_bm_barrel_phones')
end


local function OpenBlackMarketMenu()
    lib.registerContext({
        id    = 'matrix_blackmarket_menu',
        title = '=== KARABORSA TICARET AGI ===',
        menu  = 'matrix_tactical_menu',
        options = {
            {
                title       = 'Karaborsa Arac Filosu',
                description = 'Sahte plakali, VIN kazinmis calinti araclar',
                icon        = 'car-side',
                onSelect    = OpenBlackMarketVehicles
            },
            {
                title       = 'Silah Kacakciligi',
                description = 'Seri no silinmis, asinmis silahlar (elden Rendezvous teslimati)',
                icon        = 'gun',
                onSelect    = OpenBlackMarketWeapons
            },
            {
                title       = 'Muhimmat',
                description = 'Elden Rendezvous teslimati ile muhimmat',
                icon        = 'box',
                onSelect    = OpenBlackMarketAmmo
            },
            {
                title       = 'Yedek Namlu & Acik Hat',
                description = 'Namlu degisimi malzemesi ve sahte IMEI\'li telefon',
                icon        = 'screwdriver-wrench',
                onSelect    = OpenBlackMarketBarrelAndPhones
            }
        }
    })
    lib.showContext('matrix_blackmarket_menu')
end


RegisterNetEvent('matrix:client:blackmarket:purchaseResult', function(ok, label, ref)
    if lib and lib.notify then
        lib.notify({
            title       = '[KARABORSA]',
            description = ok and ('%s icin islem tamamlandi.'):format(tostring(label)) or ('%s satin alinamadi.'):format(tostring(label)),
            type        = ok and 'success' or 'error'
        })
    end
end)


-- =====================================================================
-- ★ KATMAN 6: RENDEZVOUS — buluşma noktası GPS/Not Defteri otomasyonu.
-- Not: satıcı/pusu ped'lerinin fiziksel spawn/despawn'ı ve mesafe bazlı
-- teslim-al tetiği client/trap_house_client.lua içindedir; bu dosya
-- yalnızca HUD/Not Defteri tarafını (K4) üstlenir.
-- =====================================================================


-- =====================================================================
-- ★ KATMAN 5 ULTIMATE [U6]: BÖLGESEL MALİ RAPOR (F10 alt menüsü)
-- =====================================================================
local function OpenRegionalFinancialReport()
    local lines = lib.callback.await('matrix:callback:getRegionalFinancialReport', false)
    if type(lines) ~= 'table' or #lines == 0 then
        NotifyInvalidInput('Mali rapor alinamadi.')
        return
    end


    local options = {}
    for i = 1, #lines do
        options[i] = { title = lines[i], disabled = true, icon = 'chart-line' }
    end


    lib.registerContext({
        id    = 'matrix_financial_report',
        title = '=== BOLGESEL MALI RAPOR ===',
        menu  = 'matrix_tactical_menu',
        options = options
    })
    lib.showContext('matrix_financial_report')
end


-- =====================================================================
-- ★★★ KATMAN 7 FAZ 2: PAKETLEME ODASI (F10) ★★★
-- =====================================================================
local function SanitizePackagingProductArg(v)
    if v == nil then return nil end
    local s = tostring(v)
    for _, product in ipairs(Config.Kitchen.Packaging.Products) do
        if product.item == s then return s end
    end
    return nil
end


local function BuildPackagingProductOptions()
    local options = {}
    for _, product in ipairs(Config.Kitchen.Packaging.Products) do
        options[#options + 1] = { value = product.item, label = product.label }
    end
    return options
end


local function OpenPackagingDialog()
    local input = lib.inputDialog('Paketleme Odasi - Parti Uret', {
        { type = 'number', label = 'Trap House ID', required = true, min = 1, max = 2147483646 },
        { type = 'select', label = 'Urun', required = true, options = BuildPackagingProductOptions() },
        {
            type = 'number', label = ('Paket Sayisi (maks %d)'):format(Config.Kitchen.Packaging.MaxPackagesPerRun),
            required = true, min = 1, max = Config.Kitchen.Packaging.MaxPackagesPerRun, default = 1
        }
    })
    if not input then return end


    local houseId = SanitizeNumericArg(input[1], 1, 2147483646)
    if not houseId then NotifyInvalidInput('Trap House ID gecersiz.'); return end


    local productItem = SanitizePackagingProductArg(input[2])
    if not productItem then NotifyInvalidInput('Gecersiz urun secimi.'); return end


    local count = SanitizeNumericArg(input[3], 1, Config.Kitchen.Packaging.MaxPackagesPerRun)
    if not count then NotifyInvalidInput('Paket sayisi gecersiz.'); return end


    NotifyActionSent('Paketleme emri gonderiliyor...')
    ExecuteCommand(('paketleuret %s %s %s'):format(houseId, productItem, count))
end


-- =====================================================================
-- ★★★ KATMAN 7 FAZ 2: OTONOM DEPO LOJISTIGI (Toplu Satis Hublari, F10) ★★★
-- =====================================================================
local function OpenHubAssignDialog()
    local input = lib.inputDialog('Otonom Depo Lojistigi - Hub Ata', {
        {
            type = 'number', label = 'Trap House ID',
            description = 'Hub, oyuncunun SU ANKI konumuna otomatik olarak atanir.',
            required = true, min = 1, max = 2147483646
        }
    })
    if not input then return end


    local houseId = SanitizeNumericArg(input[1], 1, 2147483646)
    if not houseId then NotifyInvalidInput('Trap House ID gecersiz.'); return end


    -- ★ Canli oyuncu konumu -- ExecuteCommand string ayristirmasindan
    -- GECMEZ (bkz. OpenGiveItemToBotDialog'un TriggerServerEvent deseni),
    -- dogrudan tipli bir vector3 olarak sunucuya gonderilir; [S1]
    -- sanitizasyonu yalnizca ExecuteCommand'a giden string argumanlar
    -- icindir, bu net event'i kapsamaz.
    local coords = GetEntityCoords(PlayerPedId())
    NotifyActionSent('Hub atama istegi gonderiliyor...')
    TriggerServerEvent('matrix:server:districtHubs:assign', tonumber(houseId), nil, coords)
end


local function OpenHubStatusReport()
    local lines = lib.callback.await('matrix:callback:getDistrictHubsReport', false)
    if type(lines) ~= 'table' or #lines == 0 then
        NotifyInvalidInput('Hub raporu alinamadi.')
        return
    end


    local options = {}
    for i = 1, #lines do
        options[i] = { title = lines[i], disabled = true, icon = 'warehouse' }
    end


    lib.registerContext({
        id      = 'matrix_district_hubs_report',
        title   = '=== OTONOM DEPO LOJISTIGI ===',
        menu    = 'matrix_tactical_menu',
        options = options
    })
    lib.showContext('matrix_district_hubs_report')
end


local function OpenDistrictHubsMenu()
    lib.registerContext({
        id    = 'matrix_district_hubs_menu',
        title = '=== OTONOM DEPO LOJISTIGI ===',
        menu  = 'matrix_tactical_menu',
        options = {
            {
                title       = 'Hub Ata (Su Anki Konumuma)',
                description = 'Bu trap house icin, su anda bulundugunuz konuma bir Toplu Satis Hub kaydeder.',
                icon        = 'location-dot',
                onSelect    = OpenHubAssignDialog
            },
            {
                title       = 'Hub Durumu Raporu',
                description = 'Tum kayitli hublarin aktif/kilit durumunu listele.',
                icon        = 'list',
                onSelect    = OpenHubStatusReport
            }
        }
    })
    lib.showContext('matrix_district_hubs_menu')
end


-- =====================================================================
-- ★★★ KATMAN 7 FAZ 2: OGRENEN BURO VERILERI / BURO KILIDI (F10) ★★★
-- =====================================================================
local function OpenLearningCoreReport()
    local entries = lib.callback.await('matrix:callback:getLearningCoreReport', false)
    if type(entries) ~= 'table' or #entries == 0 then
        NotifyInvalidInput('Ogrenen Buro raporu alinamadi (henuz kayitli trap house yok).')
        return
    end


    local options = {}
    for i = 1, #entries do
        local e = entries[i]
        if type(e) == 'table' and type(e.text) == 'string' then
            options[#options + 1] = {
                title     = e.text,
                disabled  = true,
                icon      = e.lockdown_active and 'lock' or 'unlock',
                iconColor = e.lockdown_active and '#ff4444' or nil
            }
        end
    end


    lib.registerContext({
        id      = 'matrix_learning_core_report',
        title   = '=== OGRENEN BURO VERILERI / BURO KILIDI ===',
        menu    = 'matrix_tactical_menu',
        options = options
    })
    lib.showContext('matrix_learning_core_report')
end


-- =====================================================================
-- ★★★ KATMAN 7 FAZ 2: SOKAKTA CANLI NPC "KES" SATIS DONGUSU ★★★
-- Botlarin headless/gorsel-siz esdegeri server/market.lua Matrix.Market.
-- StreetDealing.SetBotDealing'tedir (bkz. o dosyanin FAZ 2 basligi) -- bu
-- blok YALNIZCA gercek oyuncu tarafidir. K tusu COMINT paneline zaten
-- atanmis oldugundan (bkz. dosya basi), yeni bir tus BAGLANMAZ -- her sey
-- F10 Taktik Menu uzerinden yurutulur.
-- =====================================================================
local streetDealingActive   = false
local streetDealingEligible = false
local streetDealingNpc      = nil   -- { ped = entity, spawnedAt = GetGameTimer() }
-- ★ [MADDE 4] Ileri-bildirim (forward declaration): asagida SpawnStreetNpc
-- (bu isim henuz TANIMLANMADAN once) Ox_Target onSelect kapaninda bu
-- fonksiyonu cagirmasi gerekiyor. `local function X` yerine onceden
-- `local X` bildirip asagida duz atama (`X = function() end`) yapmak,
-- Lua'nin leksikal kapsam kuralina gore SpawnStreetNpc'nin bu ismi dogru
-- upvalue olarak yakalamasini saglar -- aksi halde nil global'a cagri
-- (runtime hatasi) olurdu.
local OpenStreetDealingRecruitAction


local function DespawnStreetNpc()
    if streetDealingNpc and DoesEntityExist(streetDealingNpc.ped) then
        pcall(function() exports.ox_target:removeLocalEntity(streetDealingNpc.ped) end)
        SetEntityAsNoLongerNeeded(streetDealingNpc.ped)
        DeleteEntity(streetDealingNpc.ped)
    end
    streetDealingNpc = nil
end


RegisterNetEvent('matrix:client:streetDealing:modeChanged', function(active)
    streetDealingActive = active and true or false
    if not streetDealingActive then DespawnStreetNpc() end
end)


RegisterNetEvent('matrix:client:streetDealing:saleResult', function(accepted, cash, eligible)
    streetDealingEligible = eligible and true or false
    if lib and lib.notify then
        lib.notify({
            title       = '[SOKAK SATISI]',
            description = accepted and ('Satis basarili: +$%d'):format(tonumber(cash) or 0)
                or 'Musteri malin kalitesinden supheleniyor, satis reddedildi.',
            type        = accepted and 'success' or 'error'
        })
    end
    DespawnStreetNpc()
end)


-- Deterministik model secimi (oyuncunun tam-sayi izdusumu koordinatlarina
-- gore) -- RNG YOK.
-- ★ [DÜZELTME]: backtick hash-literal yerine GetHashKey (bkz. WEAPON_UNARMED_HASH
-- yorumu yukarıda) -- standart Lua, davranış AYNI.
local STREET_NPC_MODELS = { GetHashKey('a_m_y_hipster_01'), GetHashKey('a_m_m_skidrow_01'), GetHashKey('a_f_y_runner_01') }


local function SpawnStreetNpc(coords)
    local idx = (math.floor(coords.x + coords.y) % #STREET_NPC_MODELS) + 1
    local model = STREET_NPC_MODELS[idx]


    RequestModel(model)
    local waited = 0
    while not HasModelLoaded(model) and waited < 2000 do
        Wait(50)
        waited = waited + 50
    end
    if not HasModelLoaded(model) then return nil end


    local ped = CreatePed(4, model, coords.x, coords.y, coords.z, 0.0, true, true)
    SetModelAsNoLongerNeeded(model)
    if not DoesEntityExist(ped) then return nil end


    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    TaskGoToCoordAnyMeans(ped, GetEntityCoords(PlayerPedId()), Config.Market.StreetDealing.NpcWalkSpeed, 0, false, 0, 0.0)

    -- ★ [MADDE 4] Ox_Target: "Kadroya Kat (Ajan Devşir)" -- YENİ bir
    -- devşirme formülü İCAT ETMEZ, F10 menüsüyle AYNI OpenStreetDealing
    -- RecruitAction'ı çağırır (bkz. dosya başı forward-declaration
    -- yorumu). canInteract, streetDealingEligible zaten false iken
    -- seçeneği gizler -- "henüz hazır değil" bildirimini sadece F10
    -- yolunda değil burada da gereksiz açmamak için.
    pcall(function()
        exports.ox_target:addLocalEntity(ped, {
            {
                name        = 'matrix_street_npc_recruit',
                icon        = 'user-plus',
                label       = 'Kadroya Kat (Ajan Devşir)',
                distance    = 2.0,
                canInteract = function() return streetDealingEligible end,
                onSelect    = function() OpenStreetDealingRecruitAction() end
            }
        })
    end)
    return ped
end


-- ★ 0 RESMON: NpcScanIntervalMs (1sn) poll -- Wait(0) YOK. Dealing modu
-- kapaliyken thread yalnizca uyur, hicbir ek islem yapmaz.
CreateThread(function()
    local lastApproachAt = 0
    while true do
        Wait(Config.Market.StreetDealing.NpcScanIntervalMs)


        if streetDealingActive then
            local now = GetGameTimer()
            local playerPed = PlayerPedId()
            local playerCoords = GetEntityCoords(playerPed)


            if streetDealingNpc then
                if not DoesEntityExist(streetDealingNpc.ped) then
                    streetDealingNpc = nil
                elseif #(playerCoords - GetEntityCoords(streetDealingNpc.ped)) <= Config.Market.StreetDealing.NpcArriveDistance then
                    TriggerServerEvent('matrix:server:streetDealing:attemptSale')
                elseif (now - streetDealingNpc.spawnedAt) > Config.Market.StreetDealing.NpcTimeoutMs then
                    DespawnStreetNpc()
                end
            elseif (now - lastApproachAt) >= Config.Market.StreetDealing.NpcApproachIntervalMs then
                lastApproachAt = now
                -- Deterministik yaklasim noktasi: oyuncunun tam onunde,
                -- sabit yaricapta -- RNG YOK.
                local heading = GetEntityHeading(playerPed)
                local rad = math.rad(heading)
                local spawnCoords = vector3(
                    playerCoords.x - (math.sin(rad) * Config.Market.StreetDealing.NpcSearchRadius),
                    playerCoords.y + (math.cos(rad) * Config.Market.StreetDealing.NpcSearchRadius),
                    playerCoords.z
                )
                local ped = SpawnStreetNpc(spawnCoords)
                if ped then streetDealingNpc = { ped = ped, spawnedAt = now } end
            end
        end
    end
end)


OpenStreetDealingRecruitAction = function()
    if not streetDealingEligible then
        NotifyInvalidInput('Su an devsirmeye hazir bir kes yok.')
        return
    end
    if not (streetDealingNpc and DoesEntityExist(streetDealingNpc.ped)) then
        NotifyInvalidInput('Yakinda devsirilecek bir kes yok.')
        return
    end


    local npcCoords = GetEntityCoords(streetDealingNpc.ped)
    NotifyActionSent('Devsirme talebi gonderiliyor...')
    TriggerServerEvent('matrix:server:streetDealing:recruit', npcCoords, 'Sokak Ajani')
end


local function OpenStreetDealingReport()
    local lines = lib.callback.await('matrix:callback:getStreetDealingReport', false)
    if type(lines) ~= 'table' or #lines == 0 then
        NotifyInvalidInput('Sokak satisi raporu alinamadi.')
        return
    end


    local options = {}
    for i = 1, #lines do
        options[i] = { title = lines[i], disabled = true, icon = 'user-tag' }
    end


    lib.registerContext({
        id      = 'matrix_street_dealing_report',
        title   = '=== CANLI KES SATIS SAYAÇLARI ===',
        menu    = 'matrix_tactical_menu',
        options = options
    })
    lib.showContext('matrix_street_dealing_report')
end


local function OpenStreetDealingMenu()
    lib.registerContext({
        id    = 'matrix_street_dealing_menu',
        title = '=== SOKAK SATISI ===',
        menu  = 'matrix_tactical_menu',
        options = {
            {
                title       = streetDealingActive and 'Satis Modunu KAPAT' or 'Satis Modunu AC',
                description = 'Yakinlardaki "kes" musterilerin size yaklasmasini baslatir/durdurur (/torbacilikyap).',
                icon        = 'user-tag',
                onSelect    = function()
                    NotifyActionSent('Sokak satis modu degistiriliyor...')
                    ExecuteCommand('torbacilikyap')
                end
            },
            {
                title       = 'Devsirmeye Calis',
                description = 'Bagimliligi esigi asmis, yakinizdaki bir kesi sokak ajani olarak devsir.',
                icon        = 'user-plus',
                onSelect    = OpenStreetDealingRecruitAction
            },
            {
                title       = 'Canli Kes Satis Sayaçlari',
                description = 'Aktif sokak saticilarini ve bagimlilik/nakit sayaçlarini raporla.',
                icon        = 'chart-simple',
                onSelect    = OpenStreetDealingReport
            }
        }
    })
    lib.showContext('matrix_street_dealing_menu')
end


-- =====================================================================
-- ★ KATMAN 5 EK EMİR: "OPERASYON NOT DEFTERİ" (Matrix Notepad)
-- Saf lib.inputDialog tabanlı, monokrom bir taktik not defteri. Notlar
-- YALNIZCA client RAM'inde (savedMatrixNotes) tutulur — sunucuya HİÇ
-- gönderilmez, bu yüzden ağ/enjeksiyon yüzeyi açmaz. Standart Ctrl+C/
-- Ctrl+V (Windows panosu) davranışı, alan zaten sıradan bir NUI metin
-- kutusu olduğundan NATİF olarak çalışır — bunun için ayrı bir özel NUI
-- köprüsü YAZILMASI GEREKMEZ (ve burada zaten böyle bir şey yok, o yüzden
-- "bozulacak" bir şey de yok). Aktif GPS işaretini (haritaya çift tıkla
-- konan mor waypoint) doğrudan oyun native'lerinden OKUYARAK panoya hiç
-- ihtiyaç duymadan not defterine otomatik ekler — daha güvenilir bir çözüm.
--
-- ★ KATMAN 6 [K3]: artık F10'a girmeden 'L' tuşuyla da doğrudan açılabilir.
-- ★ KATMAN 6 [K4]: server/rendezvous.lua bir buluşma ayarladığında GPS
-- waypoint'i otomatik konur VE koordinat bu deftere otomatik eklenir.
-- =====================================================================
local MAX_NOTEPAD_LENGTH = 4000 -- degenere/asiri buyume savunmasi (RAM-bomb)


local savedMatrixNotes = '' -- oturum boyunca (resource restart'a kadar) kalici RAM onbellegi


local OpenTacticalMenu -- ★ ileri bildirim: not defteri kapanınca F10'a dönmek için


--- Aktif GPS işaretini (haritaya çift tıklamayla konan mor waypoint) yakalar.
--- Waypoint blip'leri 2D'dir (Z taşımaz) — makul bir yaklaşım olarak
--- oyuncunun mevcut Z'si kullanılır.
local function CaptureActiveWaypointText()
    if not IsWaypointActive() then return nil end
    local waypointBlip = GetFirstBlipInfoId(8)
    if not DoesBlipExist(waypointBlip) then return nil end


    local wp  = GetBlipInfoIdCoord(waypointBlip)
    local ped = PlayerPedId()
    local pc  = GetEntityCoords(ped)
    return ('%.1f %.1f %.1f'):format(wp.x, wp.y, pc.z)
end


--- ★ KATMAN 6 [K4]: server/rendezvous.lua Matrix.Rendezvous.ScheduleHandoff
--- çağrıldığında tetiklenir. `data.coords` SUNUCUDAN gelen güvenilir veridir
--- (oyuncunun kendi ExecuteCommand girdisi DEĞİLDİR) — bu yüzden [S1]
--- sanitizasyonuna tabi tutulmaz; yalnızca tip kontrolü yapılır.
RegisterNetEvent('matrix:client:rendezvousAssigned', function(data)
    if type(data) ~= 'table' or type(data.coords) ~= 'vector3' then return end
    local c = data.coords


    SetNewWaypoint(c.x, c.y)


    local noteLine = ('[RENDEZVOUS] %s -> %.1f %.1f %.1f'):format(tostring(data.label or 'Teslimat'), c.x, c.y, c.z)
    if not savedMatrixNotes:find(noteLine, 1, true) then
        if #savedMatrixNotes + #noteLine + 1 > MAX_NOTEPAD_LENGTH then
            -- [S2] ile aynı disiplin: not defteri de sınırsız büyüyemez.
            savedMatrixNotes = savedMatrixNotes:sub(#savedMatrixNotes - (MAX_NOTEPAD_LENGTH - #noteLine - 1) + 1)
        end
        savedMatrixNotes = (savedMatrixNotes ~= '' and (savedMatrixNotes .. '\n') or '') .. noteLine
    end


    if lib and lib.notify then
        lib.notify({
            title       = '[RENDEZVOUS AYARLANDI]',
            description = 'Buluşma noktası GPS ve Operasyon Not Defterine islendi.',
            type        = 'inform',
            duration    = 6000
        })
    end
end)


local function OpenMatrixNotepad()
    -- ★ Kalıcı önbellek: not defteri son kaydedilen haliyle açılır.
    local defaultValue = savedMatrixNotes
    local waypointHint = CaptureActiveWaypointText()
    if waypointHint and not defaultValue:find(waypointHint, 1, true) then
        defaultValue = (defaultValue ~= '' and (defaultValue .. '\n') or '') .. waypointHint
    end


    local input = lib.inputDialog('=== MATRIX NOTEPAD — OPERASYON NOT DEFTERI ===', {
        {
            type        = 'textarea',
            label       = 'Taktik Notlar / Koordinatlar',
            description = 'Ctrl+V ile Windows panosundan yapıştırabilirsiniz. Aktif GPS işareti varsa otomatik eklendi.',
            default     = defaultValue,
            required    = false
        }
    })


    if input then
        local text = tostring(input[1] or '')
        if #text > MAX_NOTEPAD_LENGTH then
            text = text:sub(#text - MAX_NOTEPAD_LENGTH + 1) -- en eski kismi kirp, son yazilani koru
        end
        savedMatrixNotes = text
    end


    -- ★ Kapanış yolundan BAĞIMSIZ (Kaydet ya da İptal/Esc) — oyuncu F10
    -- akışından kopmasın diye Taktik Komuta Menüsüne otomatik döner.
    Wait(50)
    OpenTacticalMenu()
end


--- ★ KATMAN 6 [K3]: F10'a hiç girmeden doğrudan not defterini açar. Bu,
--- OpenMatrixNotepad'in F10'a geri dönme davranışını (Wait(50);
--- OpenTacticalMenu()) DEĞİŞTİRMEZ — 'L' ile açılsa da F10 menüsüyle aynı
--- kapanış akışını izler (tutarlılık, ayrı bir kod yolu YOK).
RegisterCommand('notdefteri', function()
    OpenMatrixNotepad()
end, false)
RegisterKeyMapping('notdefteri', 'Operasyon Not Defterini Ac (F10 disinda dogrudan)', 'keyboard', 'L')


-- =====================================================================
-- ★ YERALTI GENISLETMESI (KATMAN 1-7): fiziksel takipciler, yasal
-- hastane/adli sorgu, Arma-tarzi bot yaralanmasi + Hayalet Cerrah,
-- deterministik satici agi + parcalanmis istihbarat, dusman mahalleleri.
-- Diger F10 alt menuleriyle AYNI lib.inputDialog/ExecuteCommand deseni
-- kullanilir -- yeni bir NUI cercevesi ACILMAZ.
-- =====================================================================
local function OpenPhantomDoctorDialog()
    local input = lib.inputDialog('/hayaletcerrah - Hayalet Cerrah Ameliyati', {
        { type = 'number', label = 'Bot ID (kalici sakat)', required = true, min = 1, max = MAX_BOT_ID }
    })
    if not input then return end
    local botId = SanitizeNumericArg(input[1], 1, MAX_BOT_ID)
    if not botId then NotifyInvalidInput('Bot ID gecersiz.'); return end
    ExecuteCommand(('hayaletcerrah %s'):format(botId))
end


local function OpenTrapHouseTreatmentDialog()
    local input = lib.inputDialog('Karaborsa Ameliyati (Trap House Tedavisi)', {
        { type = 'number', label = 'Bot ID (yarali)', required = true, min = 1, max = MAX_BOT_ID }
    })
    if not input then return end
    local botId = SanitizeNumericArg(input[1], 1, MAX_BOT_ID)
    if not botId then NotifyInvalidInput('Bot ID gecersiz.'); return end
    ExecuteCommand(('kadroameliyat %s'):format(botId))
end


local function OpenWoundInterrogationDialog()
    local input = lib.inputDialog('Yatak Basi Adli Sorgu Cevabi', {
        { type = 'select', label = 'Cevap', required = true, options = {
            { value = 'itiraf', label = 'Itiraf Et' },
            { value = 'inkar',  label = 'Inkar Et (Yalan)' }
        } }
    })
    if not input then return end
    ExecuteCommand(('yarasorgucevap %s'):format(input[1]))
end


local function OpenVendorInterrogateDialog()
    local input = lib.inputDialog('/zorkullan - Satici Sorgusu', {
        { type = 'number', label = 'Satici ID', required = true, min = 1, max = 2147483646 }
    })
    if not input then return end
    local vendorId = SanitizeNumericArg(input[1], 1, 2147483646)
    if not vendorId then NotifyInvalidInput('Satici ID gecersiz.'); return end
    ExecuteCommand(('zorkullan %s'):format(vendorId))
end


local function OpenProsecutorBribeDialog()
    local input = lib.inputDialog('/savcitasaboteet - Savciyi Satin Al', {
        { type = 'input', label = 'Sanik Citizenid', required = true, max = 50 }
    })
    if not input then return end
    ExecuteCommand(('savcitasaboteet %s'):format(input[1]))
end


local function OpenGangHoodDestroyDialog()
    local input = lib.inputDialog('/depoyuyak - Kalan Yagmayi Yok Et', {
        { type = 'number', label = 'Mahalle ID', required = true, min = 1, max = 2147483646 }
    })
    if not input then return end
    local hoodId = SanitizeNumericArg(input[1], 1, 2147483646)
    if not hoodId then NotifyInvalidInput('Mahalle ID gecersiz.'); return end
    ExecuteCommand(('depoyuyak %s'):format(hoodId))
end


local function OpenFrameUpCheckDialog()
    local input = lib.inputDialog('/kanityukle - Suc Yukleme Kontrolu (Ust Arama)', {
        { type = 'number', label = 'Supheli Server ID', required = true, min = 1, max = 65535 },
        { type = 'number', label = 'Silah Slotu',          required = true, min = 0, max = 255 }
    })
    if not input then return end
    local suspectSrc = SanitizeNumericArg(input[1], 1, 65535)
    local slot        = SanitizeNumericArg(input[2], 0, 255)
    if not suspectSrc or not slot then NotifyInvalidInput('Girdi gecersiz.'); return end
    ExecuteCommand(('kanityukle %s %s'):format(suspectSrc, slot))
end


local function OpenUnderworldExpansionMenu()
    lib.registerContext({
        id = 'matrix_underworld_menu',
        title = '=== YERALTI GENISLETMESI ===',
        menu = 'matrix_tactical_menu',
        options = {
            {
                title       = 'Muhafiz Cagir',
                description = ('En fazla %d fiziksel muhafiz/kurye botu cagirir -- catismada seni savunur, araca otonom biner'):format(Config.Mercenary.MaxFollowers or 2),
                icon        = 'user-shield',
                onSelect    = function() ExecuteCommand('muhafizcagir') end
            },
            {
                title       = 'Muhafizlari Salla',
                description = 'Tum aktif fiziksel takipcileri serbest birak',
                icon        = 'user-slash',
                onSelect    = function() ExecuteCommand('muhafizsalla') end
            },
            {
                title       = 'Tedavi Ol (/tedaviol)',
                description = 'Yasal hastane check-in noktasindayken yarayi kapat -- ANINDA Buro sizintisi tetiklenir',
                icon        = 'staff-snake',
                onSelect    = function() ExecuteCommand('tedaviol') end
            },
            {
                title       = 'Yatak Basi Sorgu Cevapla',
                description = 'Acik bir adli sorgu oturumuna itiraf/inkar (yalan mahkumiyet skorunu %40 tirmandirir)',
                icon        = 'comment-medical',
                onSelect    = OpenWoundInterrogationDialog
            },
            {
                title       = 'Karaborsa Ameliyati (Trap House)',
                description = 'Yarali bir botu Trap House tedavisine al -- 12 saat dispatch kabul edemez',
                icon        = 'kit-medical',
                onSelect    = OpenTrapHouseTreatmentDialog
            },
            {
                title       = 'Hayalet Cerrah Ameliyati',
                description = 'Kalici sakat bir botu $60,000 karsiliginda 24s ameliyata al (doktorun o anki konumundayken)',
                icon        = 'user-doctor',
                onSelect    = OpenPhantomDoctorDialog
            },
            {
                title       = '/zorkullan - Satici Sorgusu',
                description = 'Bir saticiyi ele gecir -- basarili olursa dusman kartel guvenli-ev koordinati sizar',
                icon        = 'user-secret',
                onSelect    = OpenVendorInterrogateDialog
            },
            {
                title       = '/savcitasaboteet',
                description = 'Bir sanigin acik davasinin Mahkumiyet Skorunu %20 dusur',
                icon        = 'gavel',
                onSelect    = OpenProsecutorBribeDialog
            },
            {
                title       = '/depoyuyak - Yagmayi Yok Et',
                description = 'Dusman mahalle stashindeki kalan yagmayi yok et, sahnedeki adli kaniti temizle',
                icon        = 'fire',
                onSelect    = OpenGangHoodDestroyDialog
            },
            {
                title       = '/kanityukle - Suc Yukleme Kontrolu',
                description = 'Yagma silahinin [ORIGIN: BLOODY LOOT] etiketini denetle -- tasiyan supheliye islenmemis cinayetleri yukler',
                icon        = 'magnifying-glass',
                onSelect    = OpenFrameUpCheckDialog
            }
        }
    })
    lib.showContext('matrix_underworld_menu')
end


OpenTacticalMenu = function()
    lib.registerContext({
        id = 'matrix_tactical_menu',
        title = '=== TAKTIK KOMUTA MENUSU ===',
        options = {
            {
                title       = 'OPERASYON NOT DEFTERI',
                description = 'Serbest metin taktik not defteri (Matrix Notepad) — RAM önbellekli',
                icon        = 'note-sticky',
                onSelect    = OpenMatrixNotepad
            },
            {
                title       = 'Canlı Kadro & Hiyerarşi Raporu',
                description = 'Tum aktif bot ve oyuncu unsurlarini anlik olarak listele (botlar tiklanabilir)',
                icon        = 'users-gear',
                onSelect    = OpenCanliKadroRaporu
            },
            {
                title       = 'Karaborsa Ticaret Agi',
                description = 'Illegal arac filosu, silah/muhimmat kacakciligi (Rendezvous), yedek namlu, acik hat',
                icon        = 'money-bill-transfer',
                onSelect    = OpenBlackMarketMenu
            },
            {
                title       = 'Bolgesel Mali Rapor',
                description = 'Bolge bazli net kar/zarar, Newton fiyat cokme sonumlenmesi bilancosu',
                icon        = 'chart-line',
                onSelect    = OpenRegionalFinancialReport
            },
            {
                title       = 'Paketleme Odasi (Parti Uret)',
                description = 'Trap house deposundaki ham partiyi kesme ajaniyla karistirip kurye paketlerine (meth_bag/coke_brick) donustur',
                icon        = 'box-open',
                onSelect    = OpenPackagingDialog
            },
            {
                title       = 'Otonom Depo Lojistigi',
                description = 'Toplu Satis Hublarini yonet: hub ata (su anki konum), hub durumu raporu',
                icon        = 'warehouse',
                onSelect    = OpenDistrictHubsMenu
            },
            {
                title       = 'Ogrenen Buro Verileri / Buro Kilidi',
                description = 'Trap house basina birikimli telsiz ihlali/ele gecirilen saflik ve Nukleer Abluka durumu',
                icon        = 'brain',
                onSelect    = OpenLearningCoreReport
            },
            {
                title       = 'Sokak Satisi',
                description = 'Canli NPC "kes" satis modunu ac/kapat, devsirmeye calis, canli satis sayaçlarini goruntule',
                icon        = 'user-tag',
                onSelect    = OpenStreetDealingMenu
            },
            {
                title       = '/rotaciz',
                description = 'Bota 0-3 opsiyonel ara ugrak + final hedeften olusan otomatik kacis rotasi ata',
                icon        = 'map-location-dot',
                onSelect    = OpenRotaCizDialog
            },
            {
                title       = '/namludegistir',
                description = 'Elinizdeki silahin namlusunu degistirir; Buro balistik arsivini tamamen kor eder',
                icon        = 'screwdriver-wrench',
                onSelect    = OpenNamluDegistirAction
            },
            {
                title       = 'Kapı Sürgü Tahkimatı',
                description = 'Trap house kapisina Ahsap/Celik surgu barikati monte et — Baskin kirilma suresini uzatir',
                icon        = 'shield-halved',
                onSelect    = OpenDoorReinforcementDialog
            },
            {
                title       = 'Tezgahta Silah Tamiri',
                description = 'Trap house icindeki tezgahta, nakit yerine bilesen harcayarak namluyu sifirla',
                icon        = 'hammer',
                onSelect    = OpenWorkbenchRepairAction
            },
            {
                title       = 'Sikisan Silahi Tahliye Et',
                description = 'Tutuklu silahi 6sn tahliye prosedurune sokar (X tusu ile de tetiklenir)',
                icon        = 'hand',
                onSelect    = BeginWeaponJamEvacuation
            },
            {
                title       = '/traphousedurum',
                description = 'Trap house desifre/heat/duzenlilik durumunu sorgula',
                icon        = 'house-signal',
                onSelect    = OpenTrapHouseDurumDialog
            },
            {
                title       = 'Trap House\'a Git',
                description = 'Kayitli bir trap house sec, GPS waypoint otomatik ayarlansin',
                icon        = 'signs-post',
                onSelect    = OpenTrapHouseWaypointDialog
            },
            {
                title       = '/rutbeata',
                description = 'Bir oyuncuya hiyerarsi rutbesi ata (rutbe yetkisi gerekir)',
                icon        = 'user-shield',
                onSelect    = OpenRutbeAtaDialog
            },
            {
                title       = '/matrixdump',
                description = 'Tum bot matrisini (biyoloji/psikoloji) dokum et',
                icon        = 'terminal',
                onSelect    = OpenMatrixDump
            },
            {
                title       = 'Yeralti Genisletmesi',
                description = 'Fiziksel muhafizlar, yasal hastane/adli sorgu, Hayalet Cerrah, satici agi, dusman mahalleleri',
                icon        = 'skull-crossbones',
                onSelect    = OpenUnderworldExpansionMenu
            }
        }
    })
    lib.showContext('matrix_tactical_menu')
end


RegisterCommand('taktikmenu', function()
    OpenTacticalMenu()
end, false)


RegisterKeyMapping('taktikmenu', 'Taktik Komuta Menusunu Ac', 'keyboard', 'F10')


-- =====================================================================
-- RENDER THREAD — HUD kapalıyken Wait(500) (neredeyse 0ms), açıkken
-- Wait(0) (DrawText'in gerektirdiği per-frame çağrı). Metin dönüşümü
-- render thread'inde YAPILMAZ (bkz. [E1]) — burada yalnızca hazır string
-- çizilir, bu yüzden HUD açıkken bile 0 Resmon bütçesi korunur.
-- ★ [U5]: `danger` satırları COLOR_DANGER (kırmızı) ile çizilir.
-- =====================================================================
CreateThread(function()
    while true do
        if hudActive then
            local x, y = 0.014, 0.045
            DrawMonoLine(x, y, '=== MATRIX TAKTIK HUD ===', COLOR_DIM[1], COLOR_DIM[2], COLOR_DIM[3], 0.30)
            y = y + 0.026


            if #hudLines == 0 then
                DrawMonoLine(x, y, '...veri bekleniyor...', COLOR_DIM[1], COLOR_DIM[2], COLOR_DIM[3], 0.28)
            else
                for _, line in ipairs(hudLines) do
                    local color = line.danger and COLOR_DANGER or (line.header and COLOR_HEADER or COLOR_VALUE)
                    DrawMonoLine(x, y, line.text or '', color[1], color[2], color[3], line.header and 0.30 or 0.28)
                    y = y + 0.021
                end
            end


            Wait(0)
        else
            Wait(500)
        end
    end
end)