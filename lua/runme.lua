local v = vim

---@type integer win id
local win

---@type integer buffer id
local buf

---@type string tmp file path
local tmpfile

---@class Runme
local runme = {}

---@class Config
---@field runme_path string runme executable path
---@field install_path string runme binary installation path
---@field width integer floating window width
---@field height integer floating window height
-- default configurations
local config = {
  runme_path = v.fn.exepath("runme"),
  install_path = v.env.HOME .. "/.local/bin",
  width = 100,
  height = 100,
}

-- default configs
runme.config = config

local function err(msg)
    v.notify(msg, v.log.levels.ERROR, { title = "runme" })
end


---@return string
local function release_file_url()
  local os, arch
  local version = "1.7.3"

  -- check pre-existence of required programs
  if v.fn.executable("curl") == 0 or v.fn.executable("tar") == 0 then
    err("curl and/or tar are required")
    return ""
  end

  -- local raw_os = jit.os
  local raw_os = v.loop.os_uname().sysname
  local raw_arch = jit.arch
  local os_patterns = {
    ["Windows"] = "windows",
    ["Windows_NT"] = "windows",
    ["Linux"] = "linux",
    ["Darwin"] = "darwin",
  }

  local arch_patterns = {
    ["x86"] = "i386",
    ["x64"] = "x86_64",
    ["arm64"] = "arm64",
  }

  os = os_patterns[raw_os]
  arch = arch_patterns[raw_arch]

  if os == nil or arch == nil then
    err("os not supported or could not be parsed")
    return ""
  end

  -- create the url, filename based on os, arch, version
  local filename = "runme_" .. version .. "_" .. os .. "_" .. arch .. (os == "Windows" and ".zip" or ".tar.gz")
  return "https://github.com/stateful/runme/releases/download/v" .. version .. "/" .. filename
end

local function run(opts)
  local file

  -- check if runme binary is valid even if filled in config
  if v.fn.executable(runme.config.runme_path) == 0 then
    err(
      string.format(
        "could not execute runme binary in path=%s . make sure you have the right config",
        runme.config.runme_path
      )
    )
    return
  end

  local filename = opts.fargs[1]

  if filename ~= nil and filename ~= "" then
    -- check file
    file = opts.fargs[1]
    if not v.fn.filereadable(file) then
      err("error on reading file")
      return
    end

    local ext = v.fn.fnamemodify(file, ":e")
    if not is_md_ext(ext) then
      err("preview only works on markdown files")
      return
    end
  else
    if not is_md_ft() then
      err("preview only works on markdown files")
      return
    end

    file = tmp_file()
    if file == nil then
      err("error on preview for current buffer")
      return
    end
    tmpfile = file
  end

  stop_job()

  local cmd_args = { runme.config.runme_path, "-s", runme.config.style }

  if runme.config.pager then
    table.insert(cmd_args, "-p")
  end

  table.insert(cmd_args, file)
  open_window(cmd_args)
end

local function install_runme(opts)
  local release_url = release_file_url()
  if release_url == "" then
    return
  end

  local install_path = runme.config.install_path
  local download_command = { "curl", "-sL", "-o", "runme.tar.gz", release_url }
  local extract_command = { "tar", "-zxf", "runme.tar.gz", "-C", install_path }
  local output_filename = "runme.tar.gz"
  ---@diagnostic disable-next-line: missing-parameter
  local binary_path = v.fn.expand(table.concat({ install_path, "runme" }, "/"))

  -- check for existing files / folders
  if v.fn.isdirectory(install_path) == 0 then
    v.loop.fs_mkdir(runme.config.install_path, tonumber("777", 8))
  end

  ---@diagnostic disable-next-line: missing-parameter
  if v.fn.filereadable(binary_path) == 1 then
    local success = v.loop.fs_unlink(binary_path)
    if not success then
      err("runme binary could not be removed!")
      return
    end
  end

  -- download and install the runme binary
  local callbacks = {
    on_sterr = v.schedule_wrap(function(_, data, _)
      local out = table.concat(data, "\n")
      err(out)
    end),
    on_exit = v.schedule_wrap(function()
      v.fn.system(extract_command)
      -- remove the archive after completion
      if v.fn.filereadable(output_filename) == 1 then
        local success = v.loop.fs_unlink(output_filename)
        if not success then
          err("existing archive could not be removed")
          return
        end
      end
      runme.config.runme_path = binary_path
      run(opts)
    end),
  }
  v.fn.jobstart(download_command, callbacks)
end

---@return string
local function get_executable()
  if runme.config.runme_path ~= "" then
    return runme.config.runme_path
  end

  return v.fn.exepath("runme")
end

local function create_autocmds()
  v.api.nv_create_user_command("Runme", function(opts)
    runme.execute(opts)
  end, { complete = "file", nargs = "?", bang = true })
end

---@param params Config? custom config
runme.setup = function(params)
  runme.config = v.tbl_extend("force", {}, runme.config, params or {})
  create_autocmds()
end

runme.execute = function(opts)
  if v.version().minor < 8 then
    v.notify_once("runme.nv: you must use neov 0.8 or higher", v.log.levels.ERROR)
    return
  end

  local current_win = v.fn.win_getid()
  if current_win == win then
    if opts.bang then
      close_window()
    end
    -- do nothing
    return
  end

  if get_executable() == "" then
    install_runme(opts)
    return
  end

  run(opts)
end

return runme
