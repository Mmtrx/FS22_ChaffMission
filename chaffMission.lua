--=======================================================================================================
-- SCRIPT
--
-- Purpose:     Forage contracts.
-- Author:      Mmtrx
-- Changelog:
--  v1.0.0.0    01.08.2023  initial
-- Attribution	modIcon harvester from <a href="https://www.freepik.com">Image by macrovector</a> 
--=======================================================================================================
ChaffMission = {
	debug = false,
	REWARD_PER_HA = 5000,
	SUCCESS_FACTOR = 0.90
}
function debugPrint(text, ...)
	if ChaffMission.debug  then
		Logging.info(text,...)
	end
end

local ChaffMission_mt = Class(ChaffMission, HarvestMission)
InitObjectClass(ChaffMission, "ChaffMission")

function ChaffMission.new(isServer, isClient, customMt)
	local self = HarvestMission.new(isServer, isClient, customMt or ChaffMission_mt)
	self.workAreaTypes = {
		[WorkAreaType.CUTTER] = true,
	}
	self.rewardPerHa = ChaffMission.REWARD_PER_HA
	return self
end

function ChaffMission:loadFromXMLFile(xmlFile, key)
	if not ChaffMission:superClass().loadFromXMLFile(self, xmlFile, key) then
		return false
	end
	self.orgFillType = self.fillType
	self.fillType = FillType.CHAFF
	return true
end

function ChaffMission:init(field, ...)
	local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(field.fruitType)
	self.orgFillType = fruitDesc.fillType.index
	self.fillType = FillType.CHAFF

	if not HarvestMission:superClass().init(self, field, ...) then
		return false
	end
	self.depositedLiters = 0
	
	-- multiply expected by fruit converter:
	local converter = g_fruitTypeManager:getConverterDataByName("forageHarvester")
	local factor = converter[field.fruitType].conversionFactor
	self.expectedLiters = factor * self:getMaxCutLiters()

	self.sellPoint = self:getHighestSellPointPrice()
	if self.sellPoint == nil then
		return false
	end
	return true
end

function ChaffMission.canRunOnField(field, sprayFactor, fieldSpraySet, fieldPlowFactor, limeFactor, maxWeedState, stubbleFactor, rollerFactor)
	-- check for forage fruit
	local fruitType = field.fruitType
	if not table.hasElement(g_fruitTypeManager:getFruitTypesByCategoryNames("MAIZECUTTER"), fruitType) then
		return false
	end

	-- mission can run if growth is in "forage harvest ready" (usually minGrowthState -1), or between min / maxHarvestState
	local maxGrowthState = FieldUtil.getMaxGrowthState(field, fruitType)
	local maxHarvestState = FieldUtil.getMaxHarvestState(field, fruitType)
	if maxGrowthState == nil then 	-- fruitType not found
		return false
	end
	local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitType)
	
	if maxGrowthState == fruitDesc.minForageGrowthState then
		return true, FieldManager.FIELDSTATE_GROWING, maxGrowthState

	elseif maxHarvestState ~= nil and math.random() < 0.4 then -- leave some fields for harvest missions
		return true, FieldManager.FIELDSTATE_GROWING, maxHarvestState
	end
	return false
end

function ChaffMission:getData()
	if self.sellPointId ~= nil then
		self:tryToResolveSellPoint()
	end

	local name = "Unknown"
	if self.sellPoint ~= nil then
		name = self.sellPoint:getName()
	end

	return {
		location = string.format(g_i18n:getText("fieldJob_number"), self.field.fieldId),
		jobType = g_i18n:getText("fieldJob_jobType_forage"),
		action = g_i18n:getText("fieldJob_desc_action_forage"),
			description = string.format(g_i18n:getText("fieldJob_desc_forage"), g_fillTypeManager:getFillTypeByIndex(self.orgFillType).title, self.field.fieldId, name)
	}
end

function ChaffMission:getCompletion()
	local sellCompletion = math.min(self.depositedLiters / self.expectedLiters / ChaffMission.SUCCESS_FACTOR, 1)
	local fieldCompletion = self:getFieldCompletion()
	local harvestCompletion = math.min(fieldCompletion / AbstractMission.SUCCESS_FACTOR, 1)
	return math.min(1, 0.8 * harvestCompletion + 0.2 * sellCompletion)
end

function ChaffMission:validate(event)
	return ChaffMission:superClass():validate(event) and 
		event ~= FieldManager.FIELDEVENT_GROWING -- cancel, if growing from forage-ready to harvest-ready
end

function ChaffMission:updateRewardPerHa()
	return nil
end
function ChaffMission:getVehicleVariant()
	return nil 
end

-----------------------------------------------------------------------------------------------
function getIsAccessible(self, superf, farmId, x, z, workAreaType)
	-- need this to prevent player from combine harvesting a chaff mission field with harvest-ready growth
	local accessible, landOwner, canBuy = superf(self, farmId, x, z, workAreaType)

	if workAreaType ~= WorkAreaType.CUTTER then
		return accessible, landOwner, canBuy
	end

	local mission = g_missionManager:getMissionAtWorldPosition(x, z)
	if mission and mission.type.name ~= "chaff"	then 
		return accessible, landOwner, canBuy
	end
	-- is mission vehicle:
	if self.propertyState == Vehicle.PROPERTY_STATE_MISSION and 
		g_missionManager:getIsMissionWorkAllowed(farmId, x, z, workAreaType) then
			return self.spec_cutter.allowsForageGrowthState, farmId, true
	end

	-- is owned vehicle
	if accessible then 
		local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
		local landOwner = g_farmlandManager:getFarmlandOwner(farmlandId)
		accessible = landOwner ~= 0 and g_currentMission.accessHandler:canFarmAccessOtherId(farmId, landOwner) 
	
		if accessible and mission == nil then -- not on a mission field
			return accessible, landOwner, true
		end
		accessible = g_missionManager:getIsMissionWorkAllowed(farmId, x, z, workAreaType) and 
			self.spec_cutter.allowsForageGrowthState
	end

	return accessible, landOwner, canBuy
end

function adjustMissionTypes(name)
	-- move last missiontype to pos index in g_missionManager.missionTypes
	-- before: mow, plow, cult, sow, harv, weed, spray, fert, trans, lime
	-- after : mow, lime, plow, cult, sow, harv, weed, spray, fert, trans
	local typeToMove = g_missionManager:getMissionType(name)
	if typeToMove == nil then
		Logging.error("* invalid mission type %s in adjustMissionTypes()")
		return
	end
	local index = typeToMove.typeId
	local types = g_missionManager.missionTypes
	local idToType = g_missionManager.missionTypeIdToType

	local type = table.remove(types) 		-- remove last type defined
	table.insert(types, index, type)

	for i = 1, g_missionManager.nextMissionTypeId -1 do
		types[i].typeId = i
		idToType[i] = types[i]
	end
end

function addSellingStation(self, superFunc, components, xmlFile, key, ...)
  -- add chaff only for normal sellingstations that allow missions
	local added = false
	if key == "placeable.sellingStation" and xmlFile:getBool(key.."#allowMissions", true) 
		and not xmlFile:getBool(key.."#hideFromPricesMenu", false) then

		xmlFile:iterate(key..".unloadTrigger", function(index,  unloadTriggerKey)
			local fillTypes = xmlFile:getString(unloadTriggerKey.."#fillTypes") 

			-- add only to triggers with wheat or straw:
			if string.find(fillTypes, "WHEAT") or string.find(fillTypes, "STRAW") then 
				added = true 
				xmlFile:setString(unloadTriggerKey.."#fillTypes", fillTypes.." CHAFF")
			end
		end)

		if added then
			local numberOfFillTypes = -1
			xmlFile:iterate(key..".fillType", function(_, _)
			  numberOfFillTypes = numberOfFillTypes + 1
			end)
			local nextKey = string.format("%s.fillType(%d)", key, numberOfFillTypes + 1)
			xmlFile:setString(nextKey.."#name", "CHAFF")
			xmlFile:setFloat(nextKey.."#priceScale", 1)
			xmlFile:setBool(nextKey.."#supportsGreatDemand", false)
			xmlFile:setBool(nextKey.."#disablePriceDrop", true)
			debugPrint("* added CHAFF to sellPoint %s", self:getName())
		end
	end
	return superFunc(self, components, xmlFile, key, ...)
end

function bcCheck()
	bcName = "FS22_BetterContracts"
	bcVer = "1.2.8.2"
	if g_modIsLoaded[bcName] then 
		if g_modManager:getModByName(bcName).version < bcVer then 
			Logging.error("FS22_ChaffMission is incompatible with BetterContracts versions below %s. Mod will shut down.", bcVer)
			g_gui:showInfoDialog({
			text = string.format(g_i18n:getText("bcCheck"), bcVer)
			})
			return false
		end
	end
	return true
end
-----------------------------------------------------------------------------------------------

-- check BetterContracts sufficient version:
if bcCheck() then 
	WorkArea.getIsAccessibleAtWorldPosition = Utils.overwrittenFunction(WorkArea.getIsAccessibleAtWorldPosition,
	 	getIsAccessible)
	SellingStation.load = Utils.overwrittenFunction(SellingStation.load, addSellingStation)
	
	g_missionManager:registerMissionType(ChaffMission, "chaff")
	
	-- move chaff mission type before harvest: 
	adjustMissionTypes("harvest")
	addConsoleCommand("chGenerateFieldMission", "Force generating a new mission for given field", "	consoleGenerateFieldMission", g_missionManager)
end