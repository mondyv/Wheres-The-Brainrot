local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local Logger = require(script.Parent.Logger)

return function(itemId, type)
	return Promise.try(function()
		local success, result = pcall(function()
			return MarketplaceService:GetProductInfoAsync(itemId, type)
		end)

		if success then
			return result
		end
	end):catch(function(issue)
		Logger.warn(tostring(issue))

		return {
			Error = true,
			Message = "Failed to retrieve product information.",
			ItemId = itemId,
			Name = "?",
			Description = "?",
			PriceInRobux = 0,
		}
	end)
end
