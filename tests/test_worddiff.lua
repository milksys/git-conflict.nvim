local worddiff = require('git-conflict.worddiff')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function texts(lines, ranges)
  return vim.tbl_map(function(r) return lines[r.line]:sub(r.col_start + 1, r.col_end) end, ranges)
end

T['highlights changed words and merges ranges separated by whitespace'] = function()
  local a, b = { 'local value = 5 + 7' }, { 'local value = 1 - 1' }
  local ra, rb = worddiff.compute(a, b)
  eq(texts(a, ra), { '5 + 7' })
  eq(texts(b, rb), { '1 - 1' })
end

T['separate changes stay separate'] = function()
  local a, b = { 'foo(alpha, beta, gamma)' }, { 'foo(ALPHA, beta, GAMMA)' }
  local ra, rb = worddiff.compute(a, b)
  eq(texts(a, ra), { 'alpha', 'gamma' })
  eq(texts(b, rb), { 'ALPHA', 'GAMMA' })
end

T['added lines are not highlighted'] = function()
  local a, b = { 'same', 'x = 1' }, { 'same', 'new line', 'x = 2' }
  local ra, rb = worddiff.compute(a, b)
  -- "x = 1" is compared with "new line" (first changed pair) which shares nothing
  eq(ra, {})
  eq(rb, {})
end

T['completely different lines are not highlighted'] = function()
  local ra, rb = worddiff.compute({ 'abc def' }, { 'xyz' })
  eq({ ra, rb }, { {}, {} })
end

T['multibyte characters are not split'] = function()
  local a, b = { '안녕 세상' }, { '안녕 우주' }
  local ra, rb = worddiff.compute(a, b)
  eq(texts(a, ra), { '세상' })
  eq(texts(b, rb), { '우주' })
end

T['empty sides'] = function() eq({ worddiff.compute({}, { 'a' }) }, { {}, {} }) end

return T
