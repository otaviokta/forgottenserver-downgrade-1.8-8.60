local action = Action()

local upFloorIds = {1948, 1968, 5542, 20474, 20475, 31262, 34243, 48493, 48494, 50122, 50123}
function action.onUse(player, item, fromPosition, target, toPosition, isHotkey)
	if table.contains(upFloorIds, item.itemid) then
		fromPosition:moveUpstairs()
	else
		fromPosition.z = fromPosition.z + 1
	end

	if player:isPzLocked() and Tile(fromPosition):hasFlag(TILESTATE_PROTECTIONZONE) then
		player:sendCancelMessage(RETURNVALUE_PLAYERISPZLOCKED)
		return true
	end

	player:teleportTo(fromPosition, false, CONST_ME_NONE)
	return true
end

action:id(435, 1931, 1948, 1968, 5542, 20474, 20475, 31262, 34243, 48493, 48494, 50122, 50123)
action:register()
