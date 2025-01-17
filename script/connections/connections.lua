Connections = {}

-- Connection types --

local type_map = {}

-- Not using metatables, for..... reasons
local c_unlocked = {}
local c_color = {}
local c_connect = {}
local c_recheck = {}
local c_direction = {}
local c_rotate = {}
local c_adjust = {}
local c_tick = {}
local c_destroy = {}
local indicator_names = {}
Connections.indicator_names = indicator_names

local function register_connection_type(ctype, class)
	for _, etype in pairs(class.entity_types) do
		type_map[etype] = ctype
	end
	c_unlocked[ctype] = class.unlocked
	c_color[ctype] = class.color
	c_connect[ctype] = class.connect
	c_recheck[ctype] = class.recheck
	c_direction[ctype] = class.direction
	c_rotate[ctype] = class.rotate
	c_adjust[ctype] = class.adjust
	c_tick[ctype] = class.tick
	c_destroy[ctype] = class.destroy
	for _, name in pairs(class.indicator_settings) do
		indicator_names["factory-connection-indicator-" .. ctype .. "-" .. name] = ctype
	end
end

local function is_connectable(entity)
	return type_map[entity.type] or type_map[entity.name]
end
Connections.is_connectable = is_connectable

-- Connection data structure --

local CYCLIC_BUFFER_SIZE = 600
local function init()
	storage.connections = storage.connections or {}
	storage.delayed_connection_checks = storage.delayed_connection_checks or {}
	for i = 0, CYCLIC_BUFFER_SIZE - 1 do
		storage.connections[i] = storage.connections[i] or {}
	end
end
Connections.init = init

local function add_connection_to_queue(conn)
	local current_pos = (math.floor(game.tick / CONNECTION_UPDATE_RATE) + 1) * CONNECTION_UPDATE_RATE % CYCLIC_BUFFER_SIZE
	table.insert(storage.connections[current_pos], conn)
end

-- Connection settings --

local function get_connection_settings(factory, cid, ctype)
	factory.connection_settings[cid] = factory.connection_settings[cid] or {}
	factory.connection_settings[cid][ctype] = factory.connection_settings[cid][ctype] or {}
	return factory.connection_settings[cid][ctype]
end
Connections.get_connection_settings = get_connection_settings

-- Connection indicators --

local function set_connection_indicator(factory, cid, ctype, setting, dir)
	local old_indicator = factory.connection_indicators[cid]
	if old_indicator and old_indicator.valid then old_indicator.destroy() end
	local cpos = factory.layout.connections[cid]
	local new_indicator = factory.inside_surface.create_entity {
		name = "factory-connection-indicator-" .. ctype .. "-" .. setting,
		force = factory.force,
		position = {x = factory.inside_x + cpos.inside_x + cpos.indicator_dx, y = factory.inside_y + cpos.inside_y + cpos.indicator_dy},
		create_build_effect_smoke = false,
		direction = dir,
		quality = factory.quality
	}
	new_indicator.destructible = false
	factory.connection_indicators[cid] = new_indicator
end

local function delete_connection_indicator(factory, cid, ctype)
	local old_indicator = factory.connection_indicators[cid]
	if old_indicator and old_indicator.valid then old_indicator.destroy() end
end

-- Connection changes --

local function register_connection(factory, cid, ctype, conn, settings)
	conn._id = cid
	conn._type = ctype
	conn._factory = factory
	conn._settings = settings
	conn._valid = true
	factory.connections[cid] = conn
	if conn.do_tick_update then add_connection_to_queue(conn) end
	local setting, dir = c_direction[ctype](conn)
	set_connection_indicator(factory, cid, ctype, setting, dir)
end

local function init_connection(factory, cid, cpos) -- Only call this when factory.connections[cid] == nil!
	if not factory.outside_surface.valid then return end
	if not factory.inside_surface.valid then return end

	local outside_entities = factory.outside_surface.find_entities_filtered {
		position = {cpos.outside_x + factory.outside_x, cpos.outside_y + factory.outside_y},
		force = factory.force
	}
	if (outside_entities == nil or next(outside_entities) == nil) then return end
	local inside_entities = factory.inside_surface.find_entities_filtered {
		position = {cpos.inside_x + factory.inside_x, cpos.inside_y + factory.inside_y},
		force = factory.force
	}
	if (inside_entities == nil or next(inside_entities) == nil) then return end
	for _, outside_entity in pairs(outside_entities) do
		local oct = type_map[outside_entity.type] or type_map[outside_entity.name]
		if oct ~= nil then
			for _, inside_entity in pairs(inside_entities) do
				local ict = type_map[inside_entity.type] or type_map[inside_entity.name]
				if oct == ict then
					if c_unlocked[oct](factory.force) then
						local sound_1 = {path = "entity-close/assembling-machine-3", position = inside_entity.position}
						local sound_2 = {path = "entity-close/assembling-machine-3", position = outside_entity.position}
						local settings = get_connection_settings(factory, cid, oct)
						local conn = c_connect[oct](factory, cid, cpos, outside_entity, inside_entity, settings)
						if conn then
							factory.inside_surface.play_sound(sound_1)
							factory.outside_surface.play_sound(sound_2)
							register_connection(factory, cid, oct, conn, settings)
							return
						end
					else
						create_flying_text {position = inside_entity.position, text = {"research-required"}}
						create_flying_text {position = outside_entity.position, text = {"research-required"}}
					end
				end
			end
		end
	end
end
Connections.init_connection = init_connection

local function destroy_connection(conn)
	if conn._valid then
		c_destroy[conn._type](conn)
		conn._valid = false                 -- _valid should be true iff conn._factory.connections[conn._id] == conn
		conn._factory.connections[conn._id] = nil -- Lua can handle this
		delete_connection_indicator(conn._factory, conn._id, conn._type)
	end
end
Connections.destroy_connection = destroy_connection

local function in_area(x, y, area)
	return (x >= area.left_top.x and x <= area.right_bottom.x and y >= area.left_top.y and y <= area.right_bottom.y)
end

local function recheck_factory(factory, outside_area, inside_area) -- Areas are optional
	if (not factory.built) then return end
	for cid, cpos in pairs(factory.layout.connections) do
		if (outside_area == nil or in_area(cpos.outside_x + factory.outside_x, cpos.outside_y + factory.outside_y, outside_area))
			and (inside_area == nil or in_area(cpos.inside_x + factory.inside_x, cpos.inside_y + factory.inside_y, inside_area)) then
			local conn = factory.connections[cid]
			if conn then
				if c_recheck[conn._type](conn) then
					-- Everything is fine
				else
					destroy_connection(conn)
					init_connection(factory, cid, cpos)
				end
			else
				init_connection(factory, cid, cpos)
			end
		end
	end
end
Connections.recheck_factory = recheck_factory

-- During deconstruction events of an entity that is part of a connection, the entity is still valid and built, so recheck_factory would not destroy the connection involved.
-- Delaying the recheck causes these connections to be properly deconstructed immediately, instead of having to wait until the connection ticks again.
local function recheck_factory_delayed(factory, outside_area, inside_area)
	-- Note that connections should still be designed such that absolutely nothing would break even if this function was empty!
	storage.delayed_connection_checks[1 + #(storage.delayed_connection_checks)] = {
		factory = factory,
		outside_area = outside_area,
		inside_area = inside_area
	}
end
Connections.recheck_factory_delayed = recheck_factory_delayed

local function disconnect_factory(factory)
	for cid, conn in pairs(factory.connections) do
		destroy_connection(conn)
	end
end
Connections.disconnect_factory = disconnect_factory

-- Connection effects --

local function update()
	-- First let's run all them delayed connection checks
	for _, check in ipairs(storage.delayed_connection_checks) do
		recheck_factory(check.factory, check.outside_area, check.inside_area)
	end
	storage.delayed_connection_checks = {}

	local current_pos = game.tick % CYCLIC_BUFFER_SIZE
	local connections = storage.connections
	local current_slot = connections[current_pos]
	connections[current_pos] = {}
	for _, conn in pairs(current_slot) do
		local delay = (conn._valid and c_tick[conn._type](conn))
		if delay then
			-- Reinsert connection after delay
			-- Not checking for inappropriate delays, so keep your delays civil
			local queue_pos = (current_pos + delay) % CYCLIC_BUFFER_SIZE
			local new_slot = connections[queue_pos]
			new_slot[1 + #new_slot] = conn
		elseif conn._valid then
			destroy_connection(conn)
			init_connection(conn._factory, conn._id, conn._factory.layout.connections[conn._id])
		end
	end
end
Connections.update = update

local function rotate(factory, indicator)
	for cid, ind2 in pairs(factory.connection_indicators) do
		if ind2 and ind2.valid then
			if (ind2.unit_number == indicator.unit_number) then
				local conn = factory.connections[cid]
				local text, noop = c_rotate[conn._type](conn)
				create_flying_text {position = indicator.position, color = c_color[conn._type], text = text}
				if noop then return end
				local setting, dir = c_direction[conn._type](conn)
				set_connection_indicator(factory, cid, conn._type, setting, dir)
				return
			end
		end
	end
end
Connections.rotate = rotate

local function adjust(factory, indicator, positive)
	for cid, ind2 in pairs(factory.connection_indicators) do
		if ind2 and ind2.valid then
			if (ind2.unit_number == indicator.unit_number) then
				local conn = factory.connections[cid]
				local text, noop = c_adjust[conn._type](conn, positive)
				create_flying_text {position = indicator.position, color = c_color[conn._type], text = text}
				if noop then return end
				local setting, dir = c_direction[conn._type](conn)
				set_connection_indicator(factory, cid, conn._type, setting, dir)
				return
			end
		end
	end
end
Connections.adjust = adjust

local beeps = {"Beep", "Boop", "Beep", "Boop", "Beeple"}
Connections.beep = function()
	local t = game.tick
	return beeps[t % 5 + 1], true
end

register_connection_type("belt", require("belt"))
register_connection_type("chest", require("chest"))
register_connection_type("fluid", require("fluid"))
register_connection_type("circuit", require("circuit"))
register_connection_type("heat", require("heat"))
