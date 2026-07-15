local M = {}

local function err(msg)
	vim.notify(msg, vim.log.levels.ERROR, { title = "runme" })
end

---@return string release tarball url, or "" on unsupported platforms
local function release_file_url()
	local config = require("runme").config

	-- check pre-existence of required programs
	if vim.fn.executable("curl") == 0 or vim.fn.executable("tar") == 0 then
		err("curl and/or tar are required")
		return ""
	end

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

	local os = os_patterns[raw_os]
	local arch = arch_patterns[raw_arch]

	if os == nil or arch == nil then
		err("os not supported or could not be parsed")
		return ""
	end

	-- create the url, filename based on os, arch, version
	local filename = "runme_" .. os .. "_" .. arch .. (os == "windows" and ".zip" or ".tar.gz")
	return "https://github.com/runmedev/runme/releases/download/v" .. config.version .. "/" .. filename
end

-- Download and install the pinned runme release, then call on_done().
function M.install(on_done)
	local config = require("runme").config
	local release_url = release_file_url()
	if release_url == "" then
		return
	end

	local install_path = config.install_path
	local download_command = { "curl", "-sL", "-o", "runme.tar.gz", release_url }
	local extract_command = { "tar", "-zxf", "runme.tar.gz", "-C", install_path }
	local output_filename = "runme.tar.gz"
	local binary_path = vim.fn.expand(table.concat({ install_path, "runme" }, "/"))

	-- check for existing files / folders
	if vim.fn.isdirectory(install_path) == 0 then
		vim.loop.fs_mkdir(install_path, tonumber("777", 8))
	end

	if vim.fn.filereadable(binary_path) == 1 then
		local success = vim.loop.fs_unlink(binary_path)
		if not success then
			err("runme binary could not be removed!")
			return
		end
	end

	local callbacks = {
		on_stderr = vim.schedule_wrap(function(_, data, _)
			local out = table.concat(data or {}, "\n")
			if out ~= "" then
				err(out)
			end
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
			config.runme_path = binary_path
			if on_done then
				on_done()
			end
		end),
	}
	vim.fn.jobstart(download_command, callbacks)
end

return M
