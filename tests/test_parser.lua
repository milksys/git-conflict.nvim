local parser = require('git-conflict.parser')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function split(s) return vim.split(s, '\n', { plain = true }) end

T['simple conflict'] = function()
  local positions = parser.detect(split([[
before
<<<<<<< HEAD
ours
=======
theirs
>>>>>>> branch
after]]))
  eq(#positions, 1)
  local p = positions[1]
  eq(p.current, { range_start = 1, content_start = 2, range_end = 2, content_end = 2 })
  eq(p.middle, { range_start = 3, range_end = 4 })
  eq(p.incoming, { range_start = 4, content_start = 4, range_end = 5, content_end = 4 })
  eq(p.ancestor, {})
end

T['diff3 conflict'] = function()
  local p = parser.detect(split([[
<<<<<<< HEAD
ours
||||||| base
base
=======
theirs
>>>>>>> branch]]))[1]
  eq(p.current, { range_start = 0, content_start = 1, range_end = 1, content_end = 1 })
  eq(p.ancestor, { range_start = 2, content_start = 3, range_end = 3, content_end = 3 })
  eq(p.incoming, { range_start = 5, content_start = 5, range_end = 6, content_end = 5 })
end

T['empty sides'] = function()
  local p = parser.detect(split([[
<<<<<<< HEAD
=======
>>>>>>> branch]]))[1]
  eq(p.current.content_start > p.current.content_end, true)
  eq(p.incoming.content_start > p.incoming.content_end, true)
end

T['multiple conflicts'] = function()
  eq(#parser.detect(split([[
<<<<<<< HEAD
a
=======
b
>>>>>>> x
middle
<<<<<<< HEAD
c
=======
d
>>>>>>> x]])), 2)
end

T['separator inside incoming is content'] = function()
  local p = parser.detect(split([[
<<<<<<< HEAD
ours
=======
Title
=======
>>>>>>> branch]]))[1]
  eq(p.middle.range_start, 2)
  eq(p.incoming, { range_start = 3, content_start = 3, range_end = 5, content_end = 4 })
end

T['ancestor marker after separator is content'] = function()
  local p = parser.detect(split([[
<<<<<<< HEAD
ours
=======
||||||| not a marker
>>>>>>> branch]]))[1]
  eq(p.ancestor, {})
  eq(p.incoming.content_end, 3)
end

T['markers must be exactly seven characters'] = function()
  eq(#parser.detect(split([[
<<<<<<<<<< HEAD
ours
==========
theirs
>>>>>>>>>> branch]])), 0)
end

T['unterminated conflict is discarded and a new start restarts'] = function()
  local positions = parser.detect(split([[
<<<<<<< HEAD
dangling
<<<<<<< HEAD
ours
=======
theirs
>>>>>>> branch
<<<<<<< HEAD
never closed
=======]]))
  eq(#positions, 1)
  eq(positions[1].current.range_start, 2)
end

T['stray end marker is ignored'] = function()
  eq(#parser.detect(split('>>>>>>> branch\n=======\nfoo')), 0)
end

T['CRLF lines'] = function()
  local positions = parser.detect({
    '<<<<<<< HEAD\r',
    'ours\r',
    '=======\r',
    'theirs\r',
    '>>>>>>> branch\r',
  })
  eq(#positions, 1)
end

return T
