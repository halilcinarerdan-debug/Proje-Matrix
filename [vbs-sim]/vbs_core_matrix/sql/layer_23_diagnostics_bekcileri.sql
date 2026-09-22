-- =====================================================================
-- ★ KATMAN 23: DIAGNOSTICS BEKÇİLERİ — EKSİK KOLON MİGRASYONU ★
-- server/matrix_diagnostics.lua'nın [ADDITIVE] bekçilik kontrolleri
-- (KATMAN 5/6 GM emirleri) dayandığı kolonları ekler. Yukarıdaki hiçbir
-- tabloya/kolona DOKUNULMAZ — yalnızca ADD COLUMN IF NOT EXISTS.
-- =====================================================================

SET FOREIGN_KEY_CHECKS = 0;

-- [KATMAN 6] Satıcı lisansı — düşman finansmanlı satıcıların kimlik izi
ALTER TABLE `matrix_vendor_pool`
    ADD COLUMN IF NOT EXISTS `vendor_license` VARCHAR(64) NULL
        COMMENT 'Sahte/belgeli satici kimlik izi';

-- [KATMAN 5] 24 Saatlik Data Recovery — müsadere edilen cihazın çözülme
-- hedefi (Unix epoch, restart'ta geri sarmaz)
ALTER TABLE `matrix_player_state`
    ADD COLUMN IF NOT EXISTS `recovery_target_epoch` BIGINT NULL
        COMMENT 'Musadere edilen cihazin cozulme hedef zamani (Unix epoch)';

-- [KATMAN 4] Taktiksel Güç Uygulaması — adli kanıt zinciri bayrakları
ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `evidence_tampering` TINYINT(1) NOT NULL DEFAULT 0
        COMMENT 'Kanit odasi sabotaji gordu mu (TamperEvidenceLockup)';
ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `biological_trauma` TINYINT(1) NOT NULL DEFAULT 0
        COMMENT 'Biyolojik tramva kaniti mi (kontrollugucuyula)';
ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `inflicted_force_striation` FLOAT NOT NULL DEFAULT 0.0
        COMMENT 'Uygulanan fiziksel gucun uzuv bazli hasar katsayisi';

SET FOREIGN_KEY_CHECKS = 1;

-- Doğrulama (4 satir donmeli):
-- SELECT TABLE_NAME, COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
-- WHERE TABLE_SCHEMA = DATABASE()
--   AND COLUMN_NAME IN ('vendor_license','recovery_target_epoch',
--     'evidence_tampering','biological_trauma','inflicted_force_striation');