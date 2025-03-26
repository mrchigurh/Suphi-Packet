--!strict

-- Requires
local Cursor = require(script.Parent.Parent.Cursor)

return {

	Read = function(cursor: Cursor.Cursor)
		return BrickColor.new(cursor:ReadU2())
	end,

	Write = function(cursor: Cursor.Cursor, value: BrickColor)
		cursor:Allocate(2)
		cursor:WriteU2(value.Number)
	end,

}