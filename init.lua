-- vivero mod for Luanti / Minetest
-- Spawns a nursery NPC that wanders around and plants saplings in valid spots.

vivero = vivero or {}
vivero.registered_saplings = {}

-- Dynamically find all registered nodes that have "sapling" in their item name
-- Helper function to check if a node name represents a valid plantable sapling (excluding potted saplings)
local function is_valid_sapling(nodename)
	if not nodename or not string.find(nodename, "sapling") then
		return false
	end
	local lower = string.lower(nodename)
	if string.find(lower, "pot") or string.find(lower, "potted") then
		return false
	end
	if minetest.get_item_group(nodename, "flowerpot") > 0 or
	   minetest.get_item_group(nodename, "potted") > 0 or
	   minetest.get_item_group(nodename, "pot") > 0 or
	   minetest.get_item_group(nodename, "potted_node") > 0 then
		return false
	end
	return true
end

-- Dynamically find all registered nodes that have "sapling" in their item name (excluding potted variants)
minetest.register_on_mods_loaded(function()
	vivero.registered_saplings = {}
	for name, def in pairs(minetest.registered_nodes) do
		if is_valid_sapling(name) then
			table.insert(vivero.registered_saplings, name)
		end
	end
	table.sort(vivero.registered_saplings)
	minetest.log("action", "[vivero] Discovered " .. #vivero.registered_saplings .. " sapling nodes.")
end)

-- Helper function to get a random sapling node name
function vivero.get_random_sapling()
	if #vivero.registered_saplings > 0 then
		return vivero.registered_saplings[math.random(1, #vivero.registered_saplings)]
	end
	-- Fallbacks if mods_loaded hasn't run or no saplings found
	if minetest.registered_nodes["default:sapling"] then
		return "default:sapling"
	elseif minetest.registered_nodes["mcl_core:sapling_oak"] then
		return "mcl_core:sapling_oak"
	end
	return nil
end

-- Helper function to check if a node is soil/dirt
local function is_soil(nodename)
	if not nodename or nodename == "air" or nodename == "ignore" then
		return false
	end
	if minetest.get_item_group(nodename, "soil") > 0 then
		return true
	end
	if minetest.get_item_group(nodename, "crumbly") > 0 then
		return true
	end
	local lower = string.lower(nodename)
	if string.find(lower, "dirt") or string.find(lower, "grass") or string.find(lower, "soil") then
		return true
	end
	return false
end

-- Helper function to check if a node can be replaced by a sapling
local function is_replaceable(nodename)
	if not nodename or nodename == "air" then
		return true
	end
	local def = minetest.registered_nodes[nodename]
	if def and (def.buildable_to or def.drawtype == "airlike") then
		return true
	end
	return false
end

-- Check if location is suitable for planting a sapling
-- Requirements:
-- 1. Dirt/soil underneath
-- 2. Target spot is air/replaceable
-- 3. Sufficient light (daylight / light >= 8)
-- 4. At least 3x3 horizontal open space and overhead clearance (height >= 3)
local function is_valid_planting_spot(pos)
	local rounded_pos = vector.round(pos)
	local under_pos = {x = rounded_pos.x, y = rounded_pos.y - 1, z = rounded_pos.z}
	local under_node = minetest.get_node_or_nil(under_pos)

	if not under_node or not is_soil(under_node.name) then
		return false
	end

	local target_node = minetest.get_node_or_nil(rounded_pos)
	if not target_node or not is_replaceable(target_node.name) then
		return false
	end

	-- Check light level (needs light >= 8 for natural growth)
	local light = minetest.get_node_light(rounded_pos) or 0
	if light < 8 then
		return false
	end

	-- Check 3x3 area around and overhead space (height 3)
	for dx = -1, 1 do
		for dz = -1, 1 do
			for dy = 0, 3 do
				if not (dx == 0 and dz == 0 and dy == 0) then
					local chk_pos = {x = rounded_pos.x + dx, y = rounded_pos.y + dy, z = rounded_pos.z + dz}
					local chk_node = minetest.get_node_or_nil(chk_pos)
					if chk_node then
						local name = chk_node.name
						if name ~= "air" and not is_replaceable(name) then
							-- Allow leaves or saplings, but block solid trunk/stone structures
							local is_leaves = string.find(name, "leaves") or string.find(name, "leaf")
							local is_sapling = is_valid_sapling(name)
							if not is_leaves and not is_sapling then
								return false
							end
						end
					end
				end
			end
		end
	end

	return true
end

-- Animation constants
local ANIM_STAND = {x = 0, y = 79}
local ANIM_WALK = {x = 168, y = 187}
local ANIM_MINE = {x = 189, y = 198}

-- vivero NPC Entity Definition
minetest.register_entity("vivero:vivero_npc", {
	initial_properties = {
		hp_max = 20,
		physical = true,
		collide_with_objects = true,
		collisionbox = {-0.3, 0.0, -0.3, 0.3, 1.7, 0.3},
		visual = "mesh",
		mesh = "vivero_char.b3d",
		textures = {"skin_vivero_npc.png"},
		visual_size = {x = 1, y = 1},
		makes_footstep_sound = true,
		stepheight = 0.6,
	},

	state = "idle", -- idle, walk, run, plant
	state_timer = 0,
	yaw = 0,
	target_yaw = 0,
	anim = "",
	damage_timer = 0,
	plant_cooldown = 0,
	submerged_air = 10,

	set_animation = function(self, anim_name, speed)
		if self.anim == anim_name then return end
		self.anim = anim_name
		speed = speed or 30
		if anim_name == "stand" then
			self.object:set_animation(ANIM_STAND, speed, 0, true)
		elseif anim_name == "walk" or anim_name == "run" then
			self.object:set_animation(ANIM_WALK, speed, 0, true)
		elseif anim_name == "plant" then
			self.object:set_animation(ANIM_MINE, speed, 0, false)
		end
	end,

	on_activate = function(self, staticdata, dtime_s)
		self.object:set_armor_groups({fleshy = 100})
		self.object:set_acceleration({x = 0, y = -9.81, z = 0})
		self.yaw = math.random() * math.pi * 2
		self.target_yaw = self.yaw
		self.object:set_yaw(self.yaw)
		self:set_animation("stand")
		self.state = "idle"
		self.state_timer = math.random(2, 5)
		self.plant_cooldown = math.random(3, 8)
	end,

	on_step = function(self, dtime)
		if not self.object or not self.object:get_pos() then return end

		local pos = self.object:get_pos()
		local hp = self.object:get_hp()

		if hp <= 0 then
			self:die()
			return
		end

		self.state_timer = self.state_timer - dtime
		self.damage_timer = self.damage_timer - dtime
		self.plant_cooldown = self.plant_cooldown - dtime

		-- Check environmental conditions: Water & Lava damage
		local node_feet = minetest.get_node_or_nil(pos)
		local head_pos = {x = pos.x, y = pos.y + 1.2, z = pos.z}
		local node_head = minetest.get_node_or_nil(head_pos)

		local in_lava = (node_feet and (minetest.get_item_group(node_feet.name, "lava") > 0 or string.find(node_feet.name, "lava"))) or
		                (node_head and (minetest.get_item_group(node_head.name, "lava") > 0 or string.find(node_head.name, "lava")))

		local in_water = (node_feet and (minetest.get_item_group(node_feet.name, "water") > 0 or string.find(node_feet.name, "water"))) or
		                 (node_head and (minetest.get_item_group(node_head.name, "water") > 0 or string.find(node_head.name, "water")))

		-- Set standard gravity or buoyancy acceleration
		if in_water then
			self.object:set_acceleration({x = 0, y = -1.0, z = 0})
		else
			self.object:set_acceleration({x = 0, y = -9.81, z = 0})
		end

		-- Lava damage logic
		if in_lava and self.damage_timer <= 0 then
			self.damage_timer = 0.5
			self.object:set_hp(hp - 4)
			minetest.add_particlespawner({
				amount = 8, time = 0.2,
				minpos = vector.subtract(pos, {x = 0.3, y = 0.3, z = 0.3}),
				maxpos = vector.add(pos, {x = 0.3, y = 0.3, z = 0.3}),
				minvel = {x = -0.5, y = 1, z = -0.5}, maxvel = {x = 0.5, y = 2, z = 0.5},
				texture = "smoke_puff.png",
			})
			if self.object:get_hp() <= 0 then
				self:die()
				return
			end
		end

		-- Water buoyancy / swimming logic
		local vel = self.object:get_velocity() or {x = 0, y = 0, z = 0}
		if in_water then
			-- NPC swims up naturally
			vel.y = math.max(vel.y, 1.8)
			self.object:set_velocity(vel)

			-- Drowning if submerged
			if node_head and (minetest.get_item_group(node_head.name, "water") > 0 or string.find(node_head.name, "water")) then
				self.submerged_air = self.submerged_air - dtime
				if self.submerged_air <= 0 and self.damage_timer <= 0 then
					self.damage_timer = 1.0
					self.object:set_hp(hp - 2)
					if self.object:get_hp() <= 0 then
						self:die()
						return
					end
				end
			else
				self.submerged_air = 10
			end
		else
			self.submerged_air = 10
		end

		-- State Machine logic for movement and planting
		if self.state == "plant" then
			if self.state_timer <= 0 then
				-- Finish planting action
				if is_valid_planting_spot(pos) then
					local sapling = vivero.get_random_sapling()
					if sapling then
						local rounded_pos = vector.round(pos)
						minetest.set_node(rounded_pos, {name = sapling})
						-- Visual effect & particle when planting
						minetest.add_particlespawner({
							amount = 12,
							time = 0.3,
							minpos = {x = rounded_pos.x - 0.3, y = rounded_pos.y, z = rounded_pos.z - 0.3},
							maxpos = {x = rounded_pos.x + 0.3, y = rounded_pos.y + 0.5, z = rounded_pos.z + 0.3},
							minvel = {x = -0.5, y = 0.5, z = -0.5},
							maxvel = {x = 0.5, y = 1.5, z = 0.5},
							texture = "vivero_npc_spawn_egg.png",
						})
					end
				end
				self.state = "idle"
				self.state_timer = math.random(1, 3)
				self.plant_cooldown = math.random(5, 12)
			end
			return
		end

		-- Try planting if cooldown is ready and position is good
		if self.plant_cooldown <= 0 and is_valid_planting_spot(pos) then
			self.state = "plant"
			self.state_timer = 1.2
			self:set_animation("plant", 20)
			self.object:set_velocity({x = 0, y = vel.y, z = 0})
			return
		end

		-- State switching
		if self.state_timer <= 0 then
			local r = math.random()
			if r < 0.3 then
				self.state = "idle"
				self.state_timer = math.random(2, 6)
			elseif r < 0.8 then
				self.state = "walk"
				self.state_timer = math.random(4, 10)
				self.target_yaw = math.random() * math.pi * 2
			else
				self.state = "run"
				self.state_timer = math.random(3, 7)
				self.target_yaw = math.random() * math.pi * 2
			end
		end

		-- Smooth Yaw rotation
		if math.abs(self.yaw - self.target_yaw) > 0.05 then
			local diff = self.target_yaw - self.yaw
			-- Normalize angle difference
			while diff < -math.pi do diff = diff + math.pi * 2 end
			while diff > math.pi do diff = diff - math.pi * 2 end
			self.yaw = self.yaw + diff * math.min(dtime * 4, 1)
			self.object:set_yaw(self.yaw)
		end

		-- Movement execution
		if self.state == "idle" then
			self:set_animation("stand")
			self.object:set_velocity({x = 0, y = vel.y, z = 0})
		elseif self.state == "walk" or self.state == "run" then
			local move_speed = (self.state == "run") and 3.5 or 2.0
			local anim_speed = (self.state == "run") and 40 or 25
			self:set_animation(self.state, anim_speed)

			-- Calculate forward direction vector
			local dir_x = -math.sin(self.yaw)
			local dir_z = math.cos(self.yaw)

			-- Obstacle detection & auto-jump
			local front_pos = {
				x = pos.x + dir_x * 0.7,
				y = pos.y + 0.5,
				z = pos.z + dir_z * 0.7
			}
			local front_node = minetest.get_node_or_nil(front_pos)

			if front_node and front_node.name ~= "air" and not is_replaceable(front_node.name) then
				-- Check block above front node
				local front_above = minetest.get_node_or_nil({x = front_pos.x, y = pos.y + 1.5, z = front_pos.z})
				if not front_above or front_above.name == "air" or is_replaceable(front_above.name) then
					-- Jump over 1-block height obstacle
					vel.y = 5.0
				else
					-- Wall ahead too high, change direction
					self.target_yaw = self.target_yaw + math.pi + (math.random() - 0.5)
					self.state_timer = math.random(2, 5)
				end
			end

			self.object:set_velocity({
				x = dir_x * move_speed,
				y = vel.y,
				z = dir_z * move_speed
			})
		end
	end,

	on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
		local hp = self.object:get_hp()
		damage = damage or 2
		if tool_capabilities and tool_capabilities.damage_groups then
			damage = tool_capabilities.damage_groups.fleshy or damage
		end

		hp = hp - damage
		self.object:set_hp(hp)

		-- Apply knockback
		if dir then
			local kb = 6
			self.object:set_velocity({
				x = dir.x * kb,
				y = 2.5,
				z = dir.z * kb
			})
		end

		if hp <= 0 then
			self:die()
		end
	end,

	die = function(self)
		local pos = self.object:get_pos()
		if pos then
			-- Drop spawn egg or random sapling on death
			local drop_item = "vivero:spawn_egg"
			local sapling = vivero.get_random_sapling()
			if math.random() < 0.5 and sapling then
				drop_item = sapling
			end
			minetest.add_item(pos, drop_item)

			-- Death particles
			minetest.add_particlespawner({
				amount = 20, time = 0.2,
				minpos = vector.subtract(pos, {x = 0.4, y = 0.4, z = 0.4}),
				maxpos = vector.add(pos, {x = 0.4, y = 0.4, z = 0.4}),
				minvel = {x = -1, y = 1, z = -1}, maxvel = {x = 1, y = 3, z = 1},
				texture = "smoke_puff.png",
			})
		end
		self.object:remove()
	end,
})

-- Register NPC Spawn Egg
minetest.register_craftitem("vivero:spawn_egg", {
	description = "Vivero NPC Spawn Egg",
	inventory_image = "vivero_npc_spawn_egg.png",
	on_place = function(itemstack, placer, pointed_thing)
		if pointed_thing.type ~= "node" then return itemstack end
		local pos = pointed_thing.above
		pos.y = pos.y + 0.5
		local entity = minetest.add_entity(pos, "vivero:vivero_npc")
		if entity and not (minetest.settings:get_bool("creative_mode") or false) then
			itemstack:take_item()
		end
		return itemstack
	end,
})

-- Craft Recipe for Spawn Egg
minetest.register_craft({
	output = "vivero:spawn_egg",
	recipe = {
		{"group:sapling", "group:sapling", "group:sapling"},
		{"group:sapling", "group:soil",    "group:sapling"},
		{"group:sapling", "group:sapling", "group:sapling"},
	}
})
