local loader    = require "cosy.loader.lua" {
  logto = false,
}
local Lfs       = loader.require "lfs"
local Lustache  = loader.require "lustache"
local Colors    = loader.require 'ansicolors'
local Reporter  = loader.require "luacov.reporter"
local Arguments = loader.require "argparse"

local prefix = loader.prefix
os.execute (prefix .. [[/bin/cosy-server start --force --clean ]])

local source
do
  local path    = package.searchpath ("cosy.check.cli", package.path)
  local handler = assert (io.popen ([[
    source "{{{prefix}}}/bin/realpath.sh"
    path="{{{path}}}"
    path=$(dirname "${path}")
    path=$(dirname "${path}")
    realpath "${path}"
  ]] % {
    prefix = loader.prefix,
    path   = path,
  }, "r"))
  source = assert (handler:read "*l")
  handler:close ()
end

local parser = Arguments () {
  name        = "cosy-check",
  description = "Perform various checks on the cosy sources",
}
parser:option "--test-format" {
  description = "format for the test results (supported by busted)",
  default     = "TAP",
}

local arguments = parser:parse ()

local string_mt = getmetatable ""

function string_mt.__mod (pattern, variables)
  return Lustache:render (pattern, variables)
end

function _G.string.split (s, delimiter)
  local result = {}
  for part in s:gmatch ("[^" .. delimiter .. "]+") do
    result [#result+1] = part
  end
  return result
end

-- Compute path:
local main = package.searchpath ("cosy.check.cli", package.path)
if main:sub (1, 2) == "./" then
  main = Lfs.currentdir () .. "/" .. main:sub (3)
end
main = main:gsub ("/check/cli.lua", "")

local status = true

-- luacheck
-- ========

do
  status = os.execute ([[
    "{{{prefix}}}/bin/luacheck" --std max --std +busted "{{{source}}}"
  ]] % {
    prefix = prefix,
    source = source,
  }) and status
end

-- busted
-- ======

do
  Lfs.mkdir "test"
  local test_id = 1
  for module in Lfs.dir (main) do
    local path = main .. "/" .. module
    if  module ~= "." and module ~= ".."
    and Lfs.attributes (path, "mode") == "directory" then
      if Lfs.attributes (path .. "/test.lua", "mode") == "file" then
        print ("Testing {{{module}}} module:" % {
          module = module,
        })
        status = os.execute ([[ "{{{prefix}}}/bin/lua" {{{path}}}/test.lua --verbose ]] % {
          prefix = prefix,
          path   = path,
        }) and status
        status = os.execute ([[ "{{{prefix}}}/bin/lua" {{{path}}}/test.lua --verbose --coverage --output={{{format}}} >> {{{output}}} ]] % {
          prefix   = prefix,
          path     = path,
          format   = arguments.test_format,
          output   = "test/" .. tostring (test_id),
        }) and status
        test_id = test_id + 1
      end
    end
  end
  print ()
end

-- luacov
-- ======

do
  Reporter.report ()

  local report = {}
  Lfs.mkdir "coverage"

  local file      = "luacov.report.out"
  local output    = nil
  local in_header = false
  local current
  for line in io.lines (file) do
    if     not in_header
    and    line:find ("==============================================================================") == 1
    then
      in_header = true
      if output then
        output:close ()
        output = nil
      end
    elseif in_header
    and    line:find ("==============================================================================") == 1
    then
      in_header = false
    elseif in_header
    then
      current = line
      if current ~= "Summary" then
        local filename = line:match "/(cosy/.-%.lua)$"
        if filename and filename:match "^cosy" then
          local parts = {}
          for part in filename:gmatch "[^/]+" do
            parts [#parts+1] = part
            if not part:match ".lua$" then
              Lfs.mkdir ("coverage/" .. table.concat (parts, "/"))
            end
          end
          output = io.open ("coverage/" .. table.concat (parts, "/"), "w")
        end
      end
    elseif output then
      output:write (line .. "\n")
    else
      local filename = line:match "/(cosy/.-%.lua)$"
      if filename and filename:match "^cosy" then
        line = line:gsub ("\t", " ")
        local parts = line:split " "
        if #parts == 4 and parts [4] ~= "" then
          report [filename] = tonumber (parts [3]:match "([0-9%.]+)%%")
        end
      end
    end
  end
  if output then
    output:close ()
  end

  local max_size = 0
  for k, _ in pairs (report) do
    max_size = math.max (max_size, #k)
  end
  max_size = max_size + 3

  local keys = {}
  for k, _ in pairs (report) do
    keys [#keys + 1] = k
  end
  table.sort (keys)

  for i = 1, #keys do
    local k = keys   [i]
    local v = report [k]
    local color
    if v == 100 then
      color = "%{bright green}"
    elseif v < 100 and v >= 90 then
      color = "%{green}"
    elseif v < 90 and v >= 80 then
      color = "%{yellow}"
    elseif v < 80 and v >= 50 then
      color = "%{red}"
    else
      color = "%{bright red}"
    end
    local line = k
    for _ = #k, max_size do
      line = line .. " "
    end
    print ("Coverage " .. line .. Colors (color .. string.format ("%3d", v) .. "%"))
  end
end

print ()

-- i18n
-- ====

do
  local messages = {}
  local problems = 0

  for module in Lfs.dir (main) do
    local path = main .. "/" .. module
    if  module ~= "." and module ~= ".."
    and Lfs.attributes (path, "mode") == "directory" then
      if Lfs.attributes (path .. "/i18n.lua", "mode") == "file" then
        local translations = loader.load ("cosy.{{{module}}}.i18n" % {
          module = module,
        })
        for key, t in pairs (translations) do
          if not messages [key] then
            messages [key] = {
              defined = {},
              used    = {},
            }
          end
          messages [key].defined [module] = (messages [key].defined [module] or 0) + 1
          if not t.en then
            print (Colors ("Translation key %{red}{{{key}}}%{reset} defined in %{blue}{{{module}}}%{reset} does not have an 'en' translation." % {
              key    = key,
              module = "cosy." .. module,
            }))
            problems = problems + 1
          end
        end
      end
    end
  end

  for module in Lfs.dir (main) do
    local path = main .. "/" .. module
    if  module ~= "." and module ~= ".."
    and Lfs.attributes (path, "mode") == "directory" then
      for submodule in Lfs.dir (path) do
        submodule = submodule:sub (1, #submodule-4)
        local subpath = path .. "/" .. submodule .. ".lua"
        if  submodule ~= "." and submodule ~= ".."
        and Lfs.attributes (subpath, "mode") == "file" then
          for line in io.lines (subpath) do
            local key = line:match 'i18n%s*%[%s*"([%w%:%-%_]+)"%s*%]'
                     or line:match "i18n%s*%[%s*'([%w%:%-%_]+)'%s*%]"
                     or line:match 'methods%s*%[%s*"([%w%:%-%_]+)"%s*%]'
                     or line:match "methods%s*%[%s*'([%w%:%-%_]+)'%s*%]"
--                     or line:match [[i18n%s*%.([_%a][_%w]*)]]
            if key and key:find "_" ~= 1 then
              if messages [key] then
                messages [key].used [module .. "." .. submodule] = true
              else
                print (Colors ("Translation key %{red}{{{key}}}%{reset} is used in %{blue}{{{module}}}%{reset}, but never defined." % {
                  key    = key,
                  module = "cosy." .. module .. "." .. submodule,
                }))
                problems = problems + 1
              end
            end
          end
        end
      end
    end
  end

  for key, t in pairs (messages) do
    for module, times in pairs (t.defined) do
      if times > 1 then
        print (Colors ("Translation key %{red}{{{key}}}%{reset} is defined {{{n}}} times in {{{module}}}." % {
          key    = key,
          module = module,
          n      = times,
        }))
        problems = problems + 1
      end
    end
    local uses = 0
    for _ in pairs (t.used) do
      uses = uses + 1
    end
    if uses == 0 then
      local modules = {}
      for m in pairs (t.defined) do
        local module_name = "cosy." .. m
        -- the modules below define translations for the user only,
        -- so we do not want to take them into account.
        if  module_name ~= "cosy.methods"
        and module_name ~= "cosy.parameters" then
          modules [#modules+1] = Colors ("%{blue}" .. module_name .. "%{reset}")
        end
      end
      if #modules ~= 0 then
        print (Colors ("Translation key %{red}{{{key}}}%{reset} is defined in {{{module}}}, but never used." % {
          key    = key,
          module = table.concat (modules, ", "),
        }))
        problems = problems + 1
      end
    end
  end

  if problems == 0 then
    print (Colors ("Translations checks detect %{bright green}no problems%{reset}."))
    status = status and true
  else
    print (Colors ("Translations checks detect %{bright red}{{{problems}}} problems%{reset}.") % {
      problems = problems,
    })
  status = status and false
  end

end

print ()

-- shellcheck
-- ==========

do
  -- We know that we are in developper mode. Thus, there is a link to the user
  -- sources of cosy library.
  if os.execute "command -v shellcheck > /dev/null 2>&1" then
    status = os.execute ([[
source "{{{prefix}}}/bin/realpath.sh"
shellcheck --exclude=SC2024 $(realpath "{{{path}}}")/../../bin/*
    ]] % {
      prefix = loader.prefix,
      path   = source,
    }) and status
  end
end

os.execute (prefix .. [[/bin/cosy-server stop --force ]])

os.exit (status and 0 or 1)