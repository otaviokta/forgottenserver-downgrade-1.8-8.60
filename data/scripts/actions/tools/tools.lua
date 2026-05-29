local tools = {
	{ ids = {3304}, callback = onUseCrowbar },
	{ ids = {3469}, callback = onUseKitchenKnife },
	{ ids = {3308, 3330}, callback = onUseMachete },
	{ ids = {3456}, callback = onUsePick },
	{ ids = {3003, 646}, callback = onUseRope },
	{ ids = {3453}, callback = onUseScythe },
	{ ids = {3457, 5710}, callback = onUseShovel }
}

for _, tool in ipairs(tools) do
	local action = Action()

	function action.onUse(player, item, fromPosition, target, toPosition, isHotkey)
		return tool.callback(player, item, fromPosition, target, toPosition, isHotkey)
	end

	action:id(table.unpack(tool.ids))
	action:register()
end