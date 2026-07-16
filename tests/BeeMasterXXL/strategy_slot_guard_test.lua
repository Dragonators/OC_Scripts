local sourceRoot = assert(arg[1], "usage: strategy_slot_guard_test.lua <BeeMasterXXL source directory>")
package.path = sourceRoot .. "/?.lua;" .. package.path

local refreshed = {}
package.loaded.component = {upgrade_me = {}}
package.loaded.robot = {}
package.loaded.mutations = {}
package.loaded.doUntil = {}
package.loaded.device = {}
package.loaded.bot = {
    inventory = {},
    refreshInventorySlot = function(slot)
        table.insert(refreshed, slot)
        return nil
    end
}
package.loaded.beeData = {}
package.loaded.princessTracker = {}

package.loaded.strategy = nil
local strategy = require("strategy")
local ok, err = pcall(strategy.mutate, 4, 5, "test.species", {name="test mutation"})
assert(not ok, "mutate should reject empty bee slots")
assert(tostring(err):find("公主蜂槽位=4", 1, true), "missing diagnostic princess slot: " .. tostring(err))
assert(tostring(err):find("雄蜂槽位=5", 1, true), "missing diagnostic drone slot: " .. tostring(err))
assert(#refreshed == 2 and refreshed[1] == 4 and refreshed[2] == 5, "mutate did not refresh both physical slots")

print("strategy slot guard tests passed")
