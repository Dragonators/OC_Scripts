local sourceRoot = arg[1] or "src/BeeMasterXXL"
package.path = sourceRoot .. "/?.lua;" .. package.path

local lastNbt
local setCalls = 0

local database = {}

function database.set(_, _, _, nbt)
    lastNbt = nbt
    setCalls = setCalls + 1
end

function database.get(_)
    if lastNbt:find('Slot:13b', 1, true) then
        return {
            individual = {
                inactive = {
                    effect = "forestry.allele.effect.misanthrope",
                    speed = 0.46
                }
            }
        }
    end
    -- This is the misleading root-template result produced by a species-only
    -- fake bee. getSpeedAndEffect must replace both values with Ended's native
    -- branch values before building the second database stack.
    return {
        individual = {
            inactive = {
                effect = "forestry.allele.effect.none",
                speed = 1.62
            }
        }
    }
end

package.loaded.component = {
    database = database,
    upgrade_me = {}
}
package.loaded.serialization = {
    serialize = function() return "{}" end,
    unserialize = function() return nil end
}
package.loaded.bot = {inventory = {}}
package.loaded.analyzeGenes = function() return {} end
package.loaded.doUntil = function() return nil end

local originalOpen = io.open
io.open = function() return nil end
local beeData = require("beeData")
io.open = originalOpen

local effect, speed = beeData.getSpeedAndEffect("forestry.speciesEnded")
assert(effect == "forestry.effectMisanthrope")
assert(speed == 2)
assert(setCalls == 2)
assert(lastNbt:find('UID0:"forestry.effectMisanthrope"', 1, true))

print("beeData native gene integration test passed")
