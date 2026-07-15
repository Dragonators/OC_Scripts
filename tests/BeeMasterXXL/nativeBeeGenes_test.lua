local sourceRoot = arg[1] or "src/BeeMasterXXL"
package.path = sourceRoot .. "/?.lua;" .. package.path

local mutations = require("mutations")
local nativeBeeGenes = require("nativeBeeGenes")

local forestrySpecies = {}

local function addSpecies(species)
    if type(species) == "string" and species:match("^forestry%.species") then
        forestrySpecies[species] = true
    end
end

local function scanMutation(species, mutation)
    addSpecies(species)
    if mutation[1] then
        for _, alternative in ipairs(mutation) do
            scanMutation(species, alternative)
        end
    elseif mutation.parents then
        addSpecies(mutation.parents[1])
        addSpecies(mutation.parents[2])
    end
end

for species, mutation in pairs(mutations) do
    scanMutation(species, mutation)
end

local count = 0
for species in pairs(forestrySpecies) do
    count = count + 1
    assert(nativeBeeGenes.get(species), "missing native genes for " .. species)
end
assert(count == 44, "expected 44 Forestry species, got " .. tostring(count))

local ended = nativeBeeGenes.get("forestry.speciesEnded")
assert(ended.speed == 2)
assert(ended.effect == "forestry.effectMisanthrope")

local effect, speed = nativeBeeGenes.resolve(
    "forestry.speciesEnded",
    "forestry.effectNone",
    7
)
assert(effect == "forestry.effectMisanthrope")
assert(speed == 2)

effect, speed = nativeBeeGenes.resolve("gregtech.bee.speciesStardust", "gregtech.effect", 6)
assert(effect == "gregtech.effect")
assert(speed == 6)

print("nativeBeeGenes regression tests passed")
