local M = {}

function M.invalidate(files, loaded)
    loaded = loaded or package.loaded
    local invalidated = 0
    for _, relativePath in ipairs(files) do
        -- BeeMasterXXL requires files under lib by basename as well (for
        -- example require("zzlib")), so the cache key is just the filename.
        local moduleName = relativePath:match("([^/]+)%.lua$")
        if moduleName and loaded[moduleName] ~= nil then
            loaded[moduleName] = nil
            invalidated = invalidated + 1
        end
    end
    return invalidated
end

return M
