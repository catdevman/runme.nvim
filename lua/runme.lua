local vim = vim
---@type integer win id
local win

---@type integer buffer id
local buf

---@type string tmp file path
local tmpfile

local job = {}

---@class Runme
local runme = {}

---@class Config
---@field runme_path string runme executable path
---@field install_path string runme binary installation path
---@field width integer floating window width
---@field height integer floating window height
-- default configurations
local config = {
  runme_path = vim.fn.exepath("runme"),
  install_path = vim.env.HOME .. "/.local/bin",
  width = 100,
  height = 100,
}

-- default configs
runme.config = config

local function cleanup()
  if tmpfile ~= nil then
    vim.fn.delete(tmpfile)
  end
end

local function err(msg)
  vim.notify(msg, vim.log.levels.ERROR, { title = "runme" })
end

local function safe_close(h)
  if not h:is_closing() then
    h:close()
  end
end

local function stop_job()
  if job == nil then
    return
  end
  if not job.stdout == nil then
    job.stdout:read_stop()
    safe_close(job.stdout)
  end
  if not job.stderr == nil then
    job.stderr:read_stop()
    safe_close(job.stderr)
  end
  if not job.handle == nil then
    safe_close(job.handle)
  end
  job = nil
end

local function close_window()
  stop_job()
  cleanup()
  vim.api.nvim_win_close(win, true)
end

---@return string
local function tmp_file()
  local output = vim.api.nvim_buf_get_lines(0, 0, vim.api.nvim_buf_line_count(0), false)
  if vim.tbl_isempty(output) then
    err("buffer is empty")
    return ""
  end
  local tmp = vim.fn.tempname() .. ".md"
  vim.fn.writefile(output, tmp)
  return tmp
end

---@param cmd_args table runme command arguments
local function open_window(cmd_args)
  local width = vim.o.columns
  local height = vim.o.lines
  local height_ratio = runme.config.height_ratio or 0.7
  local width_ratio = runme.config.width_ratio or 0.7
  local win_height = math.ceil(height * height_ratio)
  local win_width = math.ceil(width * width_ratio)
  local row = math.ceil((height - win_height) / 2 - 1)
  local col = math.ceil((width - win_width) / 2)

  if runme.config.width and runme.config.width < win_width then
    win_width = runme.config.width
  end

  if runme.config.height and runme.config.height < win_height then
    win_height = runme.config.height
  end

  local win_opts = {
    style = "minimal",
    relative = "editor",
    width = win_width,
    height = win_height,
    row = row,
    col = col,
  }

  -- create preview buffer and set local options
  buf = vim.api.nvim_create_buf(false, true)
  win = vim.api.nvim_open_win(buf, true, win_opts)

  -- options
  vim.api.nvim_win_set_option(win, "winblend", 0)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "filetype", "runmepreview")


  -- keymaps
  local keymaps_opts = { silent = true, buffer = buf }
  vim.keymap.set("n", "q", close_window, keymaps_opts)
  vim.keymap.set("n", "<Esc>", close_window, keymaps_opts)

  -- term to receive data
  local chan = vim.api.nvim_open_term(buf, {})

  -- callback for handling output from process
  local function on_output(err, data)
    if err then
      -- what should we really do here?
      err(vim.inspect(err))
    end
    if data then
      local lines = vim.split(data, "\n", {})
      for _, d in ipairs(lines) do
        vim.api.nvim_chan_send(chan, d .. "\r\n")
      end
    end
  end

  -- setup pipes
  job = {}
  job.stdout = vim.loop.new_pipe(false)
  job.stderr = vim.loop.new_pipe(false)

  -- callback when process completes
  local function on_exit()
    stop_job()
    cleanup()
  end

  -- setup and kickoff process
  local cmd = table.remove(cmd_args, 1)
  local job_opts = {
    args = cmd_args,
    stdio = { nil, job.stdout, job.stderr },
  }

  job.handle = vim.loop.spawn(cmd, job_opts, vim.schedule_wrap(on_exit))
  vim.loop.read_start(job.stdout, vim.schedule_wrap(on_output))
  vim.loop.read_start(job.stderr, vim.schedule_wrap(on_output))

end

---@return string
local function release_file_url()
  local os, arch
  local version = "1.7.3"

  -- check pre-existence of required programs
  if vim.fn.executable("curl") == 0 or vim.fn.executable("tar") == 0 then
    err("curl and/or tar are required")
    return ""
  end

  -- local raw_os = jit.os
  local raw_os = vim.loop.os_uname().sysname
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
  local filename = "runme_" .. os .. "_" .. arch .. (os == "Windows" and ".zip" or ".tar.gz")
  return "https://github.com/stateful/runme/releases/download/v" .. version .. "/" .. filename
end

---@return boolean
local function is_md_ft()
  local allowed_fts = { "markdown", "markdown.pandoc", "markdown.gfm" }
  if not vim.tbl_contains(allowed_fts, vim.bo.filetype) then
    return false
  end
  return true
end

---@return boolean
local function is_md_ext(ext)
  local allowed_exts = { "md", "markdown", "mkd", "mkdn", "mdwn", "mdown", "mdtxt", "mdtext", "rmd", "wiki" }
  if not vim.tbl_contains(allowed_exts, string.lower(ext)) then
    return false
  end
  return true
end

local function run(opts)
  local file

  -- check if runme binary is valid even if filled in config
  if vim.fn.executable(runme.config.runme_path) == 0 then
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
    if not vim.fn.filereadable(file) then
      err("error on reading file")
      return
    end

    local ext = vim.fn.fnamemodify(file, ":e")
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

  vim.fn.termopen(runme.config.runme_path)
  --open_window(cmd_args)
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
  local binary_path = vim.fn.expand(table.concat({ install_path, "runme" }, "/"))

  -- check for existing files / folders
  if vim.fn.isdirectory(install_path) == 0 then
    vim.loop.fs_mkdir(runme.config.install_path, tonumber("777", 8))
  end

  ---@diagnostic disable-next-line: missing-parameter
  if vim.fn.filereadable(binary_path) == 1 then
    local success = vim.loop.fs_unlink(binary_path)
    if not success then
      err("runme binary could not be removed!")
      return
    end
  end

  -- download and install the runme binary
  local callbacks = {
    on_sterr = vim.schedule_wrap(function(_, data, _)
      local out = table.concat(data, "\n")
      err(out)
    end),
    on_exit = vim.schedule_wrap(function()
      vim.fn.system(extract_command)
      -- remove the archive after completion
      if vim.fn.filereadable(output_filename) == 1 then
        local success = vim.loop.fs_unlink(output_filename)
        if not success then
          err("existing archive could not be removed")
          return
        end
      end
      runme.config.runme_path = binary_path
      run(opts)
    end),
  }
  vim.fn.jobstart(download_command, callbacks)
end

---@return string
local function get_executable()
  if runme.config.runme_path ~= "" then
    return runme.config.runme_path
  end

  return vim.fn.exepath("runme")
end

local function create_autocmds()
  vim.api.nvim_create_user_command("Runme", function(opts)
    runme.execute(opts)
  end, { complete = "file", nargs = "?", bang = true })
end

---@param params Config? custom config
runme.setup = function(params)
  runme.config = vim.tbl_extend("force", {}, runme.config, params or {})
  create_autocmds()
end

runme.execute = function(opts)
  if vim.version().minor < 8 then
    vim.notify_once("runme.nvim: you must use neovim 0.8 or higher", vim.log.levels.ERROR)
    return
  end

  local current_win = vim.fn.win_getid()
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
