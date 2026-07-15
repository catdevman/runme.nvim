local vim = vim

---@class Runme
local runme = {}

---@class RunmeConfig
---@field runme_path string runme executable path
---@field install_path string runme binary installation path
---@field version string runme release to install when no binary is found
---@field auto_save boolean write modified buffers before running (runme reads from disk)
-- default configurations
local defaults = {
	runme_path = vim.fn.exepath("runme"),
	install_path = vim.env.HOME .. "/.local/bin",
	version = "3.17.2",
	auto_save = true,
	-- skip runme's interactive prompts for exported variables; set to false if
	-- you want to fill prompted values in the output terminal instead
	skip_prompts = true,
	output = {
		-- height of the shared output split
		height = 12,
	},
	server = {
		-- run cells through a per-Neovim `runme server` so exported env vars
		-- persist across runs (Jupyter-style session)
		enabled = true,
		-- nil = unix socket under stdpath("run")
		address = nil,
		tls_dir = vim.fn.stdpath("data") .. "/runme/tls",
	},
	ui = {
		-- sign column marker for runnable blocks
		sign = "▶",
	},
}

runme.config = vim.deepcopy(defaults)

local function err(msg)
	vim.notify(msg, vim.log.levels.ERROR, { title = "runme" })
end

---@return string
local function get_executable()
	if runme.config.runme_path ~= "" then
		return runme.config.runme_path
	end
	return vim.fn.exepath("runme")
end

-- Run fn, installing the pinned runme release first if no binary is found.
local function with_binary(fn)
	if get_executable() ~= "" then
		runme.config.runme_path = get_executable()
		return fn()
	end
	vim.notify("runme not found; installing v" .. runme.config.version .. "…", vim.log.levels.INFO, { title = "runme" })
	require("runme.install").install(fn)
end

-- Public API -----------------------------------------------------------------
-- These are meant to be bound by the user, e.g.:
--   vim.keymap.set("n", "]r", require("runme").next)
--   vim.keymap.set("n", "<leader>rr", require("runme").run)

--- Run the cell under the cursor.
runme.run = function()
	with_binary(function()
		require("runme.runner").run()
	end)
end

--- Move the cursor to the next runnable cell (wraps).
runme.next = function()
	require("runme.runner").next()
end

--- Move the cursor to the previous runnable cell (wraps).
runme.prev = function()
	require("runme.runner").prev()
end

--- Jump to the next runnable cell and run it.
runme.run_next = function()
	with_binary(function()
		require("runme.runner").run_next()
	end)
end

--- Rerun the last cell that was run.
runme.rerun = function()
	with_binary(function()
		require("runme.runner").rerun()
	end)
end

--- Run every cell in the current file, top to bottom.
runme.run_all = function()
	with_binary(function()
		require("runme.runner").run_all()
	end)
end

--- Pick and run a task from any markdown file in the project.
runme.tasks = function()
	with_binary(function()
		require("runme.runner").tasks()
	end)
end

--- Open the interactive runme TUI.
---@param file string? defaults to the current file
runme.tui = function(file)
	with_binary(function()
		require("runme.runner").tui(file)
	end)
end

--- Install the pinned runme release into config.install_path.
runme.install = function()
	require("runme.install").install(function()
		vim.notify("runme v" .. runme.config.version .. " installed", vim.log.levels.INFO, { title = "runme" })
	end)
end

-- Buffer attachment ----------------------------------------------------------

local group
local debounce_timers = {}

local function refresh(bufnr)
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end
	local cells = require("runme.cells").get(bufnr)
	require("runme.ui").refresh_signs(bufnr, cells)
end

local function attach(bufnr)
	if vim.b[bufnr].runme_attached then
		return
	end
	vim.b[bufnr].runme_attached = true

	refresh(bufnr)
	if get_executable() ~= "" then
		require("runme.cells").reconcile(bufnr)
	end

	vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
		buffer = bufnr,
		group = group,
		callback = function()
			debounce_timers[bufnr] = debounce_timers[bufnr] or vim.loop.new_timer()
			debounce_timers[bufnr]:start(
				200,
				0,
				vim.schedule_wrap(function()
					refresh(bufnr)
				end)
			)
		end,
	})

	vim.api.nvim_create_autocmd("BufWritePost", {
		buffer = bufnr,
		group = group,
		callback = function()
			if get_executable() ~= "" then
				require("runme.cells").reconcile(bufnr, function()
					refresh(bufnr)
				end)
			end
		end,
	})

	vim.api.nvim_create_autocmd("BufUnload", {
		buffer = bufnr,
		group = group,
		callback = function()
			if debounce_timers[bufnr] then
				debounce_timers[bufnr]:close()
				debounce_timers[bufnr] = nil
			end
		end,
	})
end

-- User command ---------------------------------------------------------------

local subcommands = {
	run = runme.run,
	next = runme.next,
	prev = runme.prev,
	["run-next"] = runme.run_next,
	rerun = runme.rerun,
	["run-all"] = runme.run_all,
	tasks = runme.tasks,
	tui = runme.tui,
	install = runme.install,
}

local function create_user_command()
	vim.api.nvim_create_user_command("Runme", function(opts)
		local arg = opts.fargs[1]
		if arg == nil or arg == "" then
			return runme.tui()
		end
		if subcommands[arg] then
			return subcommands[arg]()
		end
		local file = vim.fn.expand(arg)
		if vim.fn.filereadable(file) == 1 then
			return runme.tui(file)
		end
		err("unknown :Runme subcommand: " .. arg)
	end, {
		nargs = "?",
		complete = function(lead)
			return vim.tbl_filter(function(name)
				return vim.startswith(name, lead)
			end, vim.tbl_keys(subcommands))
		end,
	})
end

---@param params RunmeConfig? custom config
runme.setup = function(params)
	if vim.version().minor < 8 and vim.version().major == 0 then
		vim.notify_once("runme.nvim: you must use neovim 0.8 or higher", vim.log.levels.ERROR)
		return
	end

	runme.config = vim.tbl_deep_extend("force", {}, runme.config, params or {})

	group = vim.api.nvim_create_augroup("runme", { clear = true })

	require("runme.ui").setup_highlights()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			require("runme.ui").setup_highlights()
		end,
	})

	vim.api.nvim_create_autocmd("FileType", {
		pattern = { "markdown", "markdown.pandoc", "markdown.gfm" },
		group = group,
		callback = function(ev)
			attach(ev.buf)
		end,
	})

	-- attach markdown buffers that are already open
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype:match("^markdown") then
			attach(bufnr)
		end
	end

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			require("runme.server").stop()
		end,
	})

	create_user_command()
end

return runme
