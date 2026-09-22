-- =====================================================================
-- ★★★ client/humint_stalking.lua — HUMINT ADAPTIF TAKİP MOTORU ★★★
--
-- ★ v1.0 RED TEAM HARDENING (BU SÜRÜM)
--
-- [HS-1] ADAPTİF ÖNBELLEK (ADAPTIVE CACHE):
--   Eski sistem: 1500ms SABİT mesafe kontrolü — araç 100+ km/s ile
--   giderken ışınlanma/atlamalar tespit edilemiyordu (check aralığı
--   ışınlanma penceresinden daha yavaştı).
--   Yeni sistem: `ComputeAdaptiveInterval(speedMs)` — hedef aracın HIZI
--   arttıkça kontrol periyodu DOĞRUSAL olarak düşer:
--     Duruyor (0 km/s)     -> 1500ms (temel)
--     100 km/s ve üzeri    ->  300ms (hızlı)
--   Interval = 1500 - ((1500-300) * min(1.0, speedKmh/100))
--   Ara değerler doğrusal interpolasyon.
--
-- [HS-2] DİKİZ AYNASI VEKTÖREL FOV SİNYALİ:
--   İki araç arasındaki görüş hattını doğrulamak için:
--     u = takipçinin forward vektörü (GetEntityHeading'den türetilir)
--     v = hedefe doğru birim vektör (normalize)
--     cos(θ) = (u·v) / (||u||·||v||)     [u zaten birim vektör]
--     FOV kontrolü: cos(θ) >= cos(FOV/2)
--   GTA V heading konvansiyonu: 0°=Kuzey(+Y), 90°=Batı(-X).
--
-- [HS-3] ONESYNC DESPAWN SAFE-GUARD:
--   `DoesEntityExist` + `tonumber` çift guard'ı ile GetEntityCoords/
--   GetEntityHeading'in OneSync despawn penceresinde nil/0 dönme riskine
--   karşı korunur. Despawn olan bir entity'ye koordinat sorgusu bir
--   STALKING_STATE_LOST olayı olarak işaretlenir ve takip yumuşakça
--   sonlandırılır (crash YOK, hitch YOK).
--
-- SIFIR RNG: adaptif interval saf doğrusal formül; FOV saf trigonometri.
-- =====================================================================

local STALKING_BASE_INTERVAL_MS = 1500  -- duruyorken
local STALKING_FAST_INTERVAL_MS = 300   -- 100+ km/s üzerinde
local STALKING_SPEED_THRESHOLD_KMH = 100.0
local STALKING_FOV_DEGREES = 90.0       -- Toplam FOV (simetrik, ±45°)

local stalkedTargets = {}   -- [targetNetId] = { vehicleEntity, startedAt, lastKnownCoords }
local stalkingRunning = false


local function ReplyLocal(msg)
    if lib and lib.notify then
        lib.notify({ title = '[HUMINT]', description = msg, type = 'inform', duration = 4000 })
    else
        print(('[MATRIX:HUMINT] %s'):format(msg))
    end
end


--- ★ [HS-1] Adaptif önbellek formülü — saf, RNG yok, doğrusal interpolasyon.
--- @param speedMs number — araç hızı (m/s, native GetEntitySpeed'den)
--- @return number — önerilen kontrol periyodu (milisaniye)
local function ComputeAdaptiveInterval(speedMs)
    speedMs = tonumber(speedMs) or 0.0
    if speedMs ~= speedMs or speedMs < 0 then speedMs = 0.0 end

    local speedKmh = speedMs * 3.6

    if speedKmh <= 0.0 then
        return STALKING_BASE_INTERVAL_MS
    end
    if speedKmh >= STALKING_SPEED_THRESHOLD_KMH then
        return STALKING_FAST_INTERVAL_MS
    end

    local ratio = speedKmh / STALKING_SPEED_THRESHOLD_KMH
    return math.floor(STALKING_BASE_INTERVAL_MS - ((STALKING_BASE_INTERVAL_MS - STALKING_FAST_INTERVAL_MS) * ratio))
end


--- ★ [HS-2] Vektör yardımcıları (saf matematik, no RNG).
local function VectorDot(a, b)
    return (a.x * b.x) + (a.y * b.y) + (a.z * b.z)
end

local function VectorLength(v)
    return math.sqrt((v.x * v.x) + (v.y * v.y) + (v.z * v.z))
end


--- ★ [HS-2] GTA V heading'inden forward vektörü türetir (birim vektör).
--- Heading 0=N(+Y), 90=W(-X), 180=S(-Y), 270=E(+X).
local function ForwardVectorFromHeading(headingDegrees)
    local rad = math.rad(headingDegrees)
    return {
        x = -math.sin(rad),
        y =  math.cos(rad),
        z =  0.0
    }
end


--- ★ [HS-2] Dikiz aynası vektörel FOV sinyali.
--- cos(θ) = (u·v) / (||u||·||v||)  — u birim vektör olduğu için ||u||=1.
--- @return boolean — hedef FOV konisinin içinde mi
--- @return number  — hesaplanan cos(θ) değeri (debug için)
local function IsTargetInFOV(observerCoords, observerHeading, targetCoords, fovDegrees)
    fovDegrees = tonumber(fovDegrees) or STALKING_FOV_DEGREES
    if fovDegrees <= 0.0 or fovDegrees >= 360.0 then return true, 1.0 end

    -- ★ [HS-3] DoesEntityExist guard yukarıda yapılır; burada coords'un
    -- geçerliliğini ikinci bir katmanda doğrula.
    if not observerCoords or not targetCoords then return false, -1.0 end
    if type(observerCoords.x) ~= 'number' or type(targetCoords.x) ~= 'number' then
        return false, -1.0
    end

    local u = ForwardVectorFromHeading(observerHeading)

    local dx = targetCoords.x - observerCoords.x
    local dy = targetCoords.y - observerCoords.y
    local dz = targetCoords.z - observerCoords.z

    local dlen = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
    if dlen < 0.001 then return true, 1.0 end   -- aynı noktadaysa tam FOV içinde

    local v = { x = dx / dlen, y = dy / dlen, z = dz / dlen }

    local dot = VectorDot(u, v)                 -- u birim, v birim → dot = cos(θ)
    dot = math.max(-1.0, math.min(1.0, dot))    -- sayısal hata emniyeti

    local halfFovRad = math.rad(fovDegrees * 0.5)
    local threshold = math.cos(halfFovRad)

    return dot >= threshold, dot
end


--- ★ [HS-3] OneSync despawn-safe entity koordinat okuyucu.
--- @return vector3|nil, boolean — koordinat, entity canlı mı
local function SafeReadEntityCoords(entity)
    if not entity or entity == 0 then return nil, false end

    local ok, exists = pcall(DoesEntityExist, entity)
    if not ok or not exists then return nil, false end

    local okCoords, coords = pcall(GetEntityCoords, entity)
    if not okCoords or not coords then return nil, false end

    local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not x or not y or not z then return nil, false end
    if x ~= x or y ~= y or z ~= z then return nil, false end   -- NaN guard

    return vector3(x, y, z), true
end


--- ★ [HS-3] OneSync despawn-safe heading okuyucu.
local function SafeReadEntityHeading(entity)
    if not entity or entity == 0 then return nil end

    local ok, exists = pcall(DoesEntityExist, entity)
    if not ok or not exists then return nil end

    local okHeading, heading = pcall(GetEntityHeading, entity)
    if not okHeading then return nil end

    local h = tonumber(heading)
    if not h or h ~= h then return nil end
    return h
end


-- =====================================================================
-- ANA TAKİP DÖNGÜSÜ — adaptif interval
-- =====================================================================
CreateThread(function()
    while true do
        if not stalkingRunning or next(stalkedTargets) == nil then
            Wait(1000)
        else
            local playerPed = PlayerPedId()
            local playerVehicle = GetVehiclePedIsIn(playerPed, false)

            -- ★ Takipçi (bizim) forward heading okuması — despawn-safe.
            local myCoords  = SafeReadEntityCoords(playerVehicle ~= 0 and playerVehicle or playerPed)
            local myHeading = SafeReadEntityHeading(playerVehicle ~= 0 and playerVehicle or playerPed)

            -- ★ [HS-1] Adaptif interval hesapla — takip edilen ilk aracın
            -- hızına göre. Birden çok hedef varsa EN HIZLI olan referans alınır.
            local maxSpeedMs = 0.0
            for _, target in pairs(stalkedTargets) do
                if target.vehicleEntity then
                    local okSpeed, speed = pcall(GetEntitySpeed, target.vehicleEntity)
                    if okSpeed and type(speed) == 'number' and speed == speed then
                        if speed > maxSpeedMs then maxSpeedMs = speed end
                    end
                end
            end

            local interval = ComputeAdaptiveInterval(maxSpeedMs)

            if myCoords and myHeading then
                for netId, target in pairs(stalkedTargets) do
                    local targetCoords, alive = SafeReadEntityCoords(target.vehicleEntity)

                    if not alive then
                        -- ★ [HS-3] OneSync despawn: entity kapsam dışına çıktı.
                        -- Takip sessizce sonlandırılır (crash/hitch YOK).
                        stalkedTargets[netId] = nil
                        ReplyLocal('Hedef arac kapsam disina cikti (OneSync despawn). Takip sonlandirildi.')
                    else
                        -- ★ [HS-2] Vektörel FOV kontrolü
                        local inFov, cosTheta = IsTargetInFOV(myCoords, myHeading, targetCoords, STALKING_FOV_DEGREES)

                        if inFov then
                            -- Görüş hattı içindeyiz — takip aktif.
                            target.lastKnownCoords = targetCoords
                            if target.onVisualConfirm then
                                pcall(target.onVisualConfirm, netId, targetCoords, cosTheta)
                            end
                        else
                            -- ★ Hedef yan/arka pencereden kaçtı — "dikiz aynası kaybı".
                            if target.onVisualLoss then
                                pcall(target.onVisualLoss, netId, cosTheta)
                            end
                        end
                    end
                end
            end

            Wait(interval)
        end
    end
end)


-- =====================================================================
-- PUBLIC API — humint_stalking modülünü kullanmak isteyen diğer client
-- modülleri (hud.lua, trap_house_client.lua) bu export'ları çağırır.
-- =====================================================================
exports('StartStalking', function(targetNetId, vehicleEntity, callbacks)
    targetNetId = tonumber(targetNetId)
    if not targetNetId or not vehicleEntity or vehicleEntity == 0 then return false end

    local exists = DoesEntityExist(vehicleEntity)
    if not exists then return false end

    stalkedTargets[targetNetId] = {
        vehicleEntity    = vehicleEntity,
        startedAt        = GetGameTimer(),
        lastKnownCoords  = nil,
        onVisualConfirm  = callbacks and callbacks.onVisualConfirm or nil,
        onVisualLoss     = callbacks and callbacks.onVisualLoss or nil
    }
    stalkingRunning = true
    return true
end)


exports('StopStalking', function(targetNetId)
    targetNetId = tonumber(targetNetId)
    if not targetNetId then return false end
    if stalkedTargets[targetNetId] then
        stalkedTargets[targetNetId] = nil
        if next(stalkedTargets) == nil then stalkingRunning = false end
        return true
    end
    return false
end)


exports('IsTargetInFov', function(observerCoords, observerHeading, targetCoords, fovDegrees)
    return IsTargetInFOV(observerCoords, observerHeading, targetCoords, fovDegrees)
end)


exports('ComputeAdaptiveInterval', function(speedMs)
    return ComputeAdaptiveInterval(speedMs)
end)


AddEventHandler('onClientResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    stalkedTargets = {}
    stalkingRunning = false
end)