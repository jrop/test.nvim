--- ANSI styling for the command line's output.

--- @alias test.color.Style 'bold'|'dim'|'red'|'green'|'yellow'

--- @type table<test.color.Style, string>
local CODES = { bold = '1', dim = '2', red = '31', green = '32', yellow = '33' }

--- @alias test.color.Paint fun(style: test.color.Style, text: string): string

--- Return a function that wraps text in a style's escape codes when `enabled`,
--- and returns the text unchanged otherwise.
--- @param enabled boolean
--- @return test.color.Paint
return function(enabled)
  return function(style, text)
    if not enabled then return text end
    return ('\27[%sm%s\27[0m'):format(CODES[style], text)
  end
end
