--------------------------------------------------
-- Default Locale Provider (Development & Fallback)
--------------------------------------------------
-- In production bundles, scripts/build.lua injects the target
-- locale catalog (e.g. src/locales/en.lua or src/locales/ru.lua)
-- directly as the "locale" module.
local ok, catalog = pcall(require, "locales.en")
if ok and catalog then
    return catalog
end

local ok_rel, catalog_rel = pcall(require, "src.locales.en")
if ok_rel and catalog_rel then
    return catalog_rel
end

-- Fallback loadfile
local chunk = loadfile("src/locales/en.lua") or loadfile("../src/locales/en.lua")
if chunk then
    return chunk()
end

error("Failed to load default locale catalog")
