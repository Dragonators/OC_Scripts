local sourceRoot = arg[1] or "src/BeeMasterXXL"
package.path = sourceRoot .. "/?.lua;" .. package.path

local moduleCache = require("moduleCache")
local files = {
    "beeData.lua",
    "nativeBeeGenes.lua",
    "lib/zzlib.lua",
    "readme.md"
}
local loaded = {
    beeData = {},
    nativeBeeGenes = {},
    zzlib = {},
    unrelated = {}
}

local count = moduleCache.invalidate(files, loaded)
assert(count == 3)
assert(loaded.beeData == nil)
assert(loaded.nativeBeeGenes == nil)
assert(loaded.zzlib == nil)
assert(loaded.unrelated ~= nil)

print("installer module cache regression test passed")
