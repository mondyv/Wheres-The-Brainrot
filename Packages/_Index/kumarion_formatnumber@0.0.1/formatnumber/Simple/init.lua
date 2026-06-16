-- Configuration
-- The suffixes for abbreviation in every power of thousands.
local COMPACT_SUFFIX = {
	"K",
	"M",
	"B",
	"T",
	"Qd",
	"Qn",
	"Sx",
	"Sp",
	"O",
	"N",
	"de",
	"Ud",
	"DD",
	"tdD",
	"qdD",
	"QnD",
	"sxD",
	"SpD",
	"OcD",
	"NvD",
	"Vgn",
	"UVg",
	"DVg",
	"TVg",
	"qtV",
	"QnV",
	"SeV",
	"SPG",
	"OVG",
	"NVG",
	"TGN",
	"UTG",
	"DTG",
	"tsTG",
	"qtTG",
	"QnTG",
	"ssTG",
	"SpTG",
	"OcTG",
	"NoAG",
	"UnAG",
	"DuAG",
	"TeAG",
	"QdAG",
	"QnAG",
	"SxAG",
	"SpAG",
	"OcAG",
	"NvAG",
	"CT",
	"Aa",
	"Ab",
	"Ac",
	"Ad",
	"Ae",
	"Af",
	"Ag",
	"Ah",
	"Ai",
	"Aj",
	"Ak",
	"Al",
	"Am",
	"An",
	"Ao",
	"Ap",
	"Aq",
	"Ar",
	"As",
	"At",
	"Au",
	"Av",
	"Aw",
	"Ax",
	"Ay",
	"Az",
	"Ba",
	"Bb",
	"Bc",
	"Bd",
	"Be",
	"Bf",
	"Bg",
	"Bh",
	"Bi",
	"Bj",
	"Bk",
	"Bl",
	"Bm",
	"Bn",
	"Bo",
	"Bp",
	"Bq",
	"Br",
	"Bs",
	"Bt",
	"Bu",
	"Bv",
	"Bw",
	"Bx",
	"By",
	"Bz",
}
local CACHED_SKELETON_SETTINGS = true
--

local MainAPI = require(script.Parent.Main)
local FormatNumberSimpleAPI = {}

local SKELETON_CACHE = if CACHED_SKELETON_SETTINGS then {} else nil
local COMPACT_SKELETON_CACHE = if CACHED_SKELETON_SETTINGS then {} else nil

function FormatNumberSimpleAPI.Format(value: number, skeleton: string?): string
	local success
	local formatter = nil

	assert(type(value) == "number", "Value provided must be a number")

	if skeleton == nil then
		skeleton = ""
	end
	assert(type(skeleton) == "string", "Skeleton provided must be a string")

	if CACHED_SKELETON_SETTINGS then
		formatter = SKELETON_CACHE[skeleton]
	end

	if not formatter then
		success, formatter = MainAPI.NumberFormatter.forSkeleton(skeleton)
		assert(success, formatter :: string)

		if CACHED_SKELETON_SETTINGS then
			SKELETON_CACHE[skeleton] = formatter
		end
	end

	return (formatter :: MainAPI.NumberFormatter):Format(value)
end

function FormatNumberSimpleAPI.FormatCompact(value: number, skeleton: string?): string
	local success
	local formatter = nil

	assert(type(value) == "number", "Value provided must be a number")

	if skeleton == nil then
		skeleton = ""
	end
	assert(type(skeleton) == "string", "Skeleton provided must be a string")

	if CACHED_SKELETON_SETTINGS then
		formatter = COMPACT_SKELETON_CACHE[skeleton]
	end

	if not formatter then
		success, formatter = MainAPI.NumberFormatter.forSkeleton(skeleton)
		assert(success, formatter :: string)

		formatter = (formatter :: MainAPI.NumberFormatter):Notation(
			MainAPI.Notation.compactWithSuffixThousands(COMPACT_SUFFIX)
		)

		if CACHED_SKELETON_SETTINGS then
			COMPACT_SKELETON_CACHE[skeleton] = formatter
		end
	end

	assert(
		#COMPACT_SUFFIX ~= 0,
		"Please provide the suffix abbreviations for FormatCompact at the top of the Simple ModuleScript"
	)

	return formatter:Format(value)
end

return table.freeze(FormatNumberSimpleAPI)
