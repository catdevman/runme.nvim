-- Manages a single `runme server` per Neovim instance. Routing runs through
-- it (with --session-strategy recent) gives Jupyter-like session persistence:
-- exported environment variables survive across cell runs.
local M = {
	job = nil,
	address = nil,
	ready = false,
	failed = false,
	waiters = {},
}

local function err(msg)
	vim.notify(msg, vim.log.levels.ERROR, { title = "runme" })
end

local function default_address()
	local ok, dir = pcall(vim.fn.stdpath, "run")
	if not ok then
		dir = vim.fn.fnamemodify(vim.fn.tempname(), ":h")
	end
	local sock = dir .. "/runme-" .. vim.fn.getpid() .. ".sock"
	-- unix sockets are limited to ~108 chars; runme fails to bind past that
	if #sock > 100 then
		sock = "/tmp/runme-nvim-" .. vim.fn.getpid() .. ".sock"
	end
	return "unix:" .. sock
end

local function flush(address)
	local waiters = M.waiters
	M.waiters = {}
	for _, cb in ipairs(waiters) do
		cb(address)
	end
end

-- Extra CLI args that route a run through the session server.
---@return string[]
function M.run_args()
	if not M.ready then
		return {}
	end
	local cfg = require("runme").config.server
	return { "-s", M.address, "--tls", cfg.tls_dir, "--session-strategy", "recent" }
end

-- Ensure the server is up, then call cb(address|nil). A nil address means
-- sessions are unavailable and the run should proceed standalone.
---@param cb fun(address: string?)
function M.ensure(cb)
	local config = require("runme").config
	if not config.server.enabled or M.failed then
		return cb(nil)
	end
	if M.ready then
		return cb(M.address)
	end

	table.insert(M.waiters, cb)
	if M.job then -- already starting
		return
	end

	M.address = config.server.address or default_address()
	vim.fn.mkdir(config.server.tls_dir, "p")

	M.job = vim.fn.jobstart({
		config.runme_path,
		"server",
		"--address",
		M.address,
		"--tls",
		config.server.tls_dir,
	}, {
		on_stderr = function(_, data)
			if M.ready then
				return
			end
			for _, line in ipairs(data or {}) do
				if line:find("started listening", 1, true) then
					M.ready = true
					flush(M.address)
					return
				end
			end
		end,
		on_exit = function()
			M.job = nil
			if not M.ready then
				M.failed = true
				err("runme server failed to start; running without session persistence")
				flush(nil)
			end
			M.ready = false
		end,
	})

	if M.job <= 0 then
		M.job = nil
		M.failed = true
		err("could not spawn runme server; running without session persistence")
		return flush(nil)
	end

	-- give up waiting after 10s (first start generates TLS certs)
	vim.defer_fn(function()
		if not M.ready and #M.waiters > 0 then
			M.failed = true
			err("timed out waiting for runme server; running without session persistence")
			flush(nil)
		end
	end, 10000)
end

function M.stop()
	if M.job then
		vim.fn.jobstop(M.job)
		M.job = nil
		M.ready = false
	end
end

return M
