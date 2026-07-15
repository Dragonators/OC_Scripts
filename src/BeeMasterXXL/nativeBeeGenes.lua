-- Native Forestry bee genes from GTNH ForestryMC 4.10.17.
-- A database stack containing only the species chromosome fills every other
-- chromosome from Forestry's root default template, not the species template.
-- Keep the authoritative Forestry values here and use the database fallback
-- only for species registered by other mods.

local genes = {
    ["forestry.speciesForest"] = {speed = 1, effect = "forestry.effectNone"},
    ["forestry.speciesMeadows"] = {speed = 1, effect = "forestry.effectNone"},
    ["forestry.speciesCommon"] = {speed = 2, effect = "forestry.effectNone"},
    ["forestry.speciesCultivated"] = {speed = 5, effect = "forestry.effectNone"},
    ["forestry.speciesNoble"] = {speed = 2, effect = "forestry.effectNone"},
    ["forestry.speciesMajestic"] = {speed = 4, effect = "forestry.effectNone"},
    ["forestry.speciesImperial"] = {speed = 2, effect = "forestry.effectBeatific"},
    ["forestry.speciesDiligent"] = {speed = 2, effect = "forestry.effectNone"},
    ["forestry.speciesUnweary"] = {speed = 4, effect = "forestry.effectNone"},
    ["forestry.speciesIndustrious"] = {speed = 2, effect = "forestry.effectNone"},
    ["forestry.speciesSteadfast"] = {speed = 2, effect = "forestry.effectNone"},
    ["forestry.speciesValiant"] = {speed = 3, effect = "forestry.effectNone"},
    ["forestry.speciesHeroic"] = {speed = 3, effect = "forestry.effectHeroic"},
    ["forestry.speciesSinister"] = {speed = 2, effect = "forestry.effectAggressive"},
    ["forestry.speciesFiendish"] = {speed = 4, effect = "forestry.effectAggressive"},
    ["forestry.speciesDemonic"] = {speed = 2, effect = "forestry.effectIgnition"},
    ["forestry.speciesModest"] = {speed = 2, effect = "forestry.effectNone"},
    ["forestry.speciesFrugal"] = {speed = 4, effect = "forestry.effectNone"},
    ["forestry.speciesAustere"] = {speed = 1, effect = "forestry.effectCreeper"},
    ["forestry.speciesTropical"] = {speed = 2, effect = "forestry.effectMiasmic"},
    ["forestry.speciesExotic"] = {speed = 4, effect = "forestry.effectMiasmic"},
    ["forestry.speciesEdenic"] = {speed = 1, effect = "forestry.effectExploration"},
    ["forestry.speciesEnded"] = {speed = 2, effect = "forestry.effectMisanthrope"},
    ["forestry.speciesSpectral"] = {speed = 2, effect = "forestry.effectReanimation"},
    ["forestry.speciesPhantasmal"] = {speed = 1, effect = "forestry.effectResurrection"},
    ["forestry.speciesWintry"] = {speed = 2, effect = "forestry.effectGlacial"},
    ["forestry.speciesIcy"] = {speed = 3, effect = "forestry.effectGlacial"},
    ["forestry.speciesGlacial"] = {speed = 2, effect = "forestry.effectGlacial"},
    ["forestry.speciesVindictive"] = {speed = 2, effect = "forestry.effectRadioactive"},
    ["forestry.speciesVengeful"] = {speed = 4, effect = "forestry.effectRadioactive"},
    ["forestry.speciesAvenging"] = {speed = 1, effect = "forestry.effectRadioactive"},
    ["forestry.speciesLeporine"] = {speed = 2, effect = "forestry.effectFestiveEaster"},
    ["forestry.speciesMerry"] = {speed = 2, effect = "forestry.effectSnowing"},
    ["forestry.speciesTipsy"] = {speed = 2, effect = "forestry.effectDrunkard"},
    ["forestry.speciesTricky"] = {speed = 2, effect = "forestry.effectNone"},
    ["forestry.speciesRural"] = {speed = 2, effect = "forestry.effectNone"},
    ["forestry.speciesFarmerly"] = {speed = 3, effect = "forestry.effectNone"},
    ["forestry.speciesAgrarian"] = {speed = 3, effect = "forestry.effectFertile"},
    ["forestry.speciesMarshy"] = {speed = 1, effect = "forestry.effectNone"},
    ["forestry.speciesMiry"] = {speed = 1, effect = "forestry.effectNone"},
    ["forestry.speciesBoggy"] = {speed = 1, effect = "forestry.effectMycophilic"},
    ["forestry.speciesMonastic"] = {speed = 2, effect = "forestry.effectNone"},
    ["forestry.speciesSecluded"] = {speed = 2, effect = "forestry.effectNone"},
    ["forestry.speciesHermitic"] = {speed = 2, effect = "forestry.effectRepulsion"}
}

local M = {}

function M.get(species)
    return genes[species]
end

function M.resolve(species, fallbackEffect, fallbackSpeed)
    local native = genes[species]
    if native then
        return native.effect, native.speed
    end
    return fallbackEffect, fallbackSpeed
end

return M
