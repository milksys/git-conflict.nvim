-----------------------------------------------------------------------------//
-- Utils
-----------------------------------------------------------------------------//
local M = {}

local api = vim.api

--- Wrapper for [vim.notify]
---@param msg string|string[]
---@param level "error" | "trace" | "debug" | "info" | "warn"
---@param once boolean?
function M.notify(msg, level, once)
  if type(msg) == 'table' then msg = table.concat(msg, '\n') end
  local lvl = vim.log.levels[level:upper()] or vim.log.levels.INFO
  local opts = { title = 'Git conflict' }
  if once then return vim.notify_once(msg, lvl, opts) end
  vim.notify(msg, lvl, opts)
end

---Call `func` once no further calls have been made for `timeout` ms (trailing edge debounce)
---@param timeout integer
---@param func function
---@return function debounced, function close
function M.debounce(timeout, func)
  local timer = assert(vim.uv.new_timer())
  local debounced = function(...)
    local args = vim.F.pack_len(...)
    timer:stop()
    timer:start(timeout, 0, vim.schedule_wrap(function() func(vim.F.unpack_len(args)) end))
  end
  local close = function()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  return debounced, close
end

---Wrapper around `api.nvim_buf_get_lines` which defaults to the current buffer
---@param start integer
---@param _end integer
---@param buf integer?
---@return string[]
function M.get_buf_lines(start, _end, buf)
  return api.nvim_buf_get_lines(buf or 0, start, _end, false)
end

---Check if the buffer is likely to have actionable conflict markers
---@param bufnr integer?
---@return boolean
function M.is_valid_buf(bufnr)
  bufnr = bufnr or 0
  return #vim.bo[bufnr].buftype == 0 and vim.bo[bufnr].modifiable
end

---@param name string?
---@return vim.api.keyset.get_hl_info
function M.get_hl(name)
  if not name then return {} end
  return api.nvim_get_hl(0, { name = name, link = false })
end

return M
