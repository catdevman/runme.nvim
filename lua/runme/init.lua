local vim = vim

---@class Runme
local runme = {}

---@class Config
---@field runme_path string runme executable path
---@field install_path string runme binary installation path
-- default configurations
local config = {
	runme_path = vim.fn.exepath("runme"),
	install_path = vim.env.HOME .. "/.local/bin",
}

-- default configs
runme.config = config

local function err(msg)
	vim.notify(msg, vim.log.levels.ERROR, { title = "runme" })
end

---@return string
local function release_file_url()
	local os, arch
	local version = "3.13.2"

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

---@return string
local function get_file_name(file)
	return file:match("([^/]-([^.]+))$")
end

local function run(opts)
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

	local file = opts.fargs[1]

	if file ~= nil and file ~= "" then
		-- check file
		if vim.fn.filereadable(file) == 0 then
			err("error on reading file")
			return
		end

		local ext = vim.fn.fnamemodify(file, ":e")
		if not is_md_ext(ext) then
			err("runme only works on markdown files")
			return
		end
	else
		if not is_md_ft() then
			err("runme only works on markdown files")
			return
		end

		file = vim.fn.expand("%")
	end

	vim.fn.termopen(runme.config.runme_path .. " --filename " .. get_file_name(file))
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
	end, { complete = "file", nargs = "?" })
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

	if get_executable() == "" then
		install_runme(opts)
		return
	end

	run(opts)
end

return runme
