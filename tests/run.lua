-- Minimal busted-compatible runner, for machines without busted. It supports the subset
-- the specs use: describe, it, before_each, and the assert calls defined below.
-- Usage (from the repo root): lua tests/run.lua [spec files...]
package.path = "./?.lua;./?/init.lua;" .. package.path

local rawAssert = assert
local results = { passed = 0, failed = 0, failures = {} }
local stack = {}

local function fail(message, level)
    error(message, (level or 1) + 1)
end

local function serialize(value, depth)
    depth = depth or 0
    if type(value) ~= "table" or depth > 3 then return tostring(value) end
    local parts = {}
    for k, v in pairs(value) do parts[#parts + 1] = tostring(k) .. "=" .. serialize(v, depth + 1) end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local checks = {
    equal = function(expected, actual)
        if expected ~= actual then
            fail(("expected %s, got %s"):format(serialize(expected), serialize(actual)), 3)
        end
    end,
    same = function(expected, actual)
        if not deepEqual(expected, actual) then
            fail(("expected %s, got %s"):format(serialize(expected), serialize(actual)), 3)
        end
    end,
    is_true = function(v) if v ~= true then fail("expected true, got " .. serialize(v), 3) end end,
    is_false = function(v) if v ~= false then fail("expected false, got " .. serialize(v), 3) end end,
    is_nil = function(v) if v ~= nil then fail("expected nil, got " .. serialize(v), 3) end end,
    is_not_nil = function(v) if v == nil then fail("expected a value, got nil", 3) end end,
    truthy = function(v) if not v then fail("expected truthy, got " .. serialize(v), 3) end end,
    falsy = function(v) if v then fail("expected falsy, got " .. serialize(v), 3) end end,
    matches = function(pattern, s)
        if type(s) ~= "string" or not s:find(pattern) then
            fail(("expected %s to match %q"):format(serialize(s), pattern), 3)
        end
    end,
    has_error = function(fn) if pcall(fn) then fail("expected an error", 3) end end,
    has_no_error = function(fn)
        local ok, err = pcall(fn)
        if not ok then fail("unexpected error: " .. tostring(err), 3) end
    end,
}

assert = setmetatable({
    are = { equal = checks.equal, same = checks.same },
    is_true = checks.is_true,
    is_false = checks.is_false,
    is_nil = checks.is_nil,
    is_not_nil = checks.is_not_nil,
    truthy = checks.truthy,
    falsy = checks.falsy,
    matches = checks.matches,
    has_error = checks.has_error,
    has_no_error = checks.has_no_error,
}, { __call = function(_, ...) return rawAssert(...) end })

local function newBlock(name)
    return { name = name, befores = {}, children = {} }
end

local root = newBlock(nil)
stack[1] = root

function describe(name, fn)
    local block = newBlock(name)
    local parent = stack[#stack]
    parent.children[#parent.children + 1] = { block = block }
    stack[#stack + 1] = block
    fn()
    stack[#stack] = nil
end

function it(name, fn)
    local parent = stack[#stack]
    parent.children[#parent.children + 1] = { test = name, fn = fn }
end

function before_each(fn)
    local parent = stack[#stack]
    parent.befores[#parent.befores + 1] = fn
end

local function run(block, path, befores)
    local chain = {}
    for _, fn in ipairs(befores) do chain[#chain + 1] = fn end
    for _, fn in ipairs(block.befores) do chain[#chain + 1] = fn end
    for _, child in ipairs(block.children) do
        if child.block then
            run(child.block, path .. child.block.name .. " ", chain)
        else
            local ok, err = pcall(function()
                for _, fn in ipairs(chain) do fn() end
                child.fn()
            end)
            if ok then
                results.passed = results.passed + 1
                io.write(".")
            else
                results.failed = results.failed + 1
                results.failures[#results.failures + 1] = path .. child.test .. "\n    " .. tostring(err)
                io.write("F")
            end
        end
    end
end

local files = { ... }
if #files == 0 then
    local windows = package.config:sub(1, 1) == "\\"
    local listing = io.popen(windows and "dir /b tests\\*_spec.lua" or "ls tests/*_spec.lua")
    for line in listing:lines() do
        files[#files + 1] = line:find("/") and line or ("tests/" .. line)
    end
    listing:close()
end

for _, file in ipairs(files) do
    local chunk = rawAssert(loadfile(file))
    chunk()
end
run(root, "", {})

print(("\n%d passed, %d failed"):format(results.passed, results.failed))
for _, failure in ipairs(results.failures) do print("FAIL " .. failure) end
os.exit(results.failed == 0 and 0 or 1)
