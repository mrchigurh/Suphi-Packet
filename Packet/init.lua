--!strict
-- Version: 1.0


-- Requires
local Cursor = require(script.Cursor)
local Signal = require(script.Signal)
local Task = require(script.Task)
local Types = require(script.Types)


-- Types
export type Packet<A... = (), B... = ()> = {
	Type:					"Packet",
	Id:						number,
	Name:					string,
	Parameters: 			{string | {any}},
	ResponseTimeout:		number,
	ResponseTimeoutValue:	any,
	ResponseParameters: 	{string | {any}},
	OnServerEvent:			Signal.Signal<(Player, A...)>,
	OnClientEvent:			Signal.Signal<A...>,
	OnServerInvoke:			nil | (player: Player, A...) -> B...,
	OnClientInvoke:			nil | (A...) -> B...,
	Response:				(self: Packet<A..., B...>, B...) -> Packet<A..., B...>,
	Fire:					(self: Packet<A..., B...>, A...) -> B...,
	FireClient:				(self: Packet<A..., B...>, player: Player, A...) -> B...,
	Serialize:				(self: Packet<A..., B...>, A...) -> (buffer, {Instance}?),
	Deserialize:			(self: Packet<A..., B...>, serializeBuffer: buffer, instances: {Instance}?) -> A...,
	Destroy:				(self: Packet<A..., B...>) -> (),
}


-- Varables
local ParameterizeTable, TypeCheckParameters, TypeCheckTable, SerializeParameters, SerializeTable, DeserializeParameters, DeserializeTable, Timeout
local RunService = game:GetService("RunService")
local PlayersService = game:GetService("Players")
local types, reads, writes = Types.Types, Types.Reads, Types.Writes
local packets = {}			:: {[string | number]: Packet<...any, ...any>}
local playerCursors			: {[Player]: Cursor.Cursor}
local playerThreads			: {[Player]: {[number]: {Yielded: thread, Timeout: thread}, Index: number}}
local playerBytes			: {[Player]: number}
local playerError			: {[Player]: boolean}
local threads				: {[number]: {Yielded: thread, Timeout: thread}, Index: number}
local packetCounter			: number
local cursor = Cursor()

local Packet = {}			:: Packet<...any, ...any>
Packet["__index"] = Packet
Packet.Type = "Packet"


-- Constructor
local function Constructor<A..., B...>(_, name: string, ...: A...)
	local packet = packets[name] :: Packet<A..., B...>
	if packet then return packet end
	local packet = (setmetatable({}, Packet) :: any) :: Packet<A..., B...>
	packet.Name = name
	if RunService:IsServer() then
		packet.Id = packetCounter
		packet.OnServerEvent = Signal() :: Signal.Signal<(Player, A...)>
		script:SetAttribute(name, packetCounter)
		packets[packetCounter] = packet
		packetCounter += 1
	else
		packet.Id = script:GetAttribute(name)
		packet.OnClientEvent = Signal() :: Signal.Signal<A...>
		if packet.Id then packets[packet.Id] = packet end
	end
	local parameters = table.pack(...)
	packet.Parameters = table.create(#parameters)
	for index, parameterType in ipairs(parameters) do
		if type(parameterType) == "table" then
			packet.Parameters[index] = ParameterizeTable(parameterType)
		else
			packet.Parameters[index] = parameterType
		end
	end
	packets[packet.Name] = packet
	return packet
end


-- Packet
function Packet:Response(...)
	self.ResponseTimeout = self.ResponseTimeout or 10
	local parameters = table.pack(...)
	self.ResponseParameters = table.create(#parameters)
	for index, parameterType in ipairs(parameters) do
		if type(parameterType) == "table" then
			self.ResponseParameters[index] = ParameterizeTable(parameterType)
		else
			self.ResponseParameters[index] = parameterType
		end
	end
	return self
end

function Packet:Fire(...)
	local values = {...}
	--if TypeCheckParameters(self.Parameters, values) == false then error(`Parameters did not match packet: '{self.Name}'`, 2) end
	cursor:Allocate(2)
	cursor:WriteU1(self.Id)
	if self.ResponseParameters then
		local offset = cursor.Index * 8
		buffer.writebits(cursor.Buffer, offset + 0, 1, 0)
		buffer.writebits(cursor.Buffer, offset + 1, 7, threads.Index)
		cursor.Index += 1
		threads[threads.Index] = {Yielded = coroutine.running(), Timeout = Task:Delay(self.ResponseTimeout, Timeout, coroutine.running(), self.ResponseTimeoutValue)}
		threads.Index = (threads.Index + 1) % 128
		SerializeParameters(cursor, self.Parameters, values)
		return coroutine.yield()
	else
		SerializeParameters(cursor, self.Parameters, values)
	end
end

function Packet:FireClient(player, ...)
	if player.Parent == nil then return end
	local values = {...}
	--if TypeCheckParameters(self.Parameters, values) == false then error(`Parameters did not match packet: '{self.Name}'`, 2) end
	local cursor = playerCursors[player]
	if cursor == nil then cursor = Cursor() playerCursors[player] = cursor end
	cursor:Allocate(2)
	cursor:WriteU1(self.Id)
	if self.ResponseParameters then
		local threads = playerThreads[player]
		if threads == nil then threads = {Index = 0} playerThreads[player] = threads end
		local offset = cursor.Index * 8
		buffer.writebits(cursor.Buffer, offset + 0, 1, 0)
		buffer.writebits(cursor.Buffer, offset + 1, 7, threads.Index)
		cursor.Index += 1
		threads[threads.Index] = {Yielded = coroutine.running(), Timeout = Task:Delay(self.ResponseTimeout, Timeout, coroutine.running(), self.ResponseTimeoutValue)}
		threads.Index = (threads.Index + 1) % 128
		SerializeParameters(cursor, self.Parameters, values)
		return coroutine.yield()
	else
		SerializeParameters(cursor, self.Parameters, values)
	end
end

function Packet:Serialize(...)
	local cursor = Cursor()
	SerializeParameters(cursor, self.Parameters, {...})
	if #cursor.Instances == 0 then return cursor:Truncate() else return cursor:Truncate(), cursor.Instances end
end

function Packet:Deserialize(serializeBuffer, instances)
	return DeserializeParameters(Cursor(serializeBuffer, instances), self.Parameters)
end

function Packet:Destroy()
	script:SetAttribute(self.Name, nil)
	if self.Id then packets[self.Id] = nil end
	packets[self.Name] = nil
end


-- Functions
function ParameterizeTable(parameters: {[any]: any})
	if #parameters == 1 then
		local parameterType = parameters[1]
		if type(parameterType) == "table" then parameters[1] = ParameterizeTable(parameterType) end
		return parameters
	else
		local keys = {}
		for key, value in parameters do table.insert(keys, key) end
		table.sort(keys)
		local array = table.create(#keys * 2)
		for index, key in keys do
			table.insert(array, key)
			local parameterType = parameters[key]
			if type(parameterType) == "table" then
				table.insert(array, ParameterizeTable(parameterType))
			else
				table.insert(array, parameterType)
			end
		end
		return array
	end
end

function TypeCheckParameters(parameters: {string | {any}}, values: {[any]: any})
	for index, parameterType in parameters do
		if type(parameterType) == "table" then
			if TypeCheckTable(parameterType, values[index]) == false then return false end
		else
			local type = types[parameterType]
			if type ~= nil and type ~= typeof(values[index]) then return false end
		end
	end
	return true
end

function TypeCheckTable(parameters: {string | {any}}, values: {[any]: any})
	if type(values) ~= "table" then return false end
	if #parameters == 1 then
		local parameterType = parameters[1]
		if type(parameterType) == "table" then
			for index, value in values do if TypeCheckTable(parameterType, value) == false then return false end end
		else
			local type = types[parameterType]
			if type ~= nil then
				for index, value in values do if type ~= typeof(values[index]) then return false end end
			end
		end
	else
		for index = 1, #parameters, 2 do
			local parameterType = parameters[index + 1]
			if type(parameterType) == "table" then
				if TypeCheckTable(parameterType, values[parameters[index]]) == false then return false end
			else
				local type = types[parameterType]
				if type ~= nil and type ~= typeof(values[parameters[index]]) then return false end
			end
		end
	end
	return true
end

function SerializeParameters(cursor: Cursor.Cursor, parameters: {string | {any}}, values: {[any]: any})
	for index, parameterType in parameters do
		if type(parameterType) == "table" then
			SerializeTable(cursor, parameterType, values[index])
		else
			writes[parameterType](cursor, values[index])
		end
	end
end

function SerializeTable(cursor: Cursor.Cursor, parameters: {string | {any}}, values: {[any]: any})
	if #parameters == 1 then
		cursor:WriteU2(#values)
		local parameterType = parameters[1]
		if type(parameterType) == "table" then
			for index, value in values do SerializeTable(cursor, parameterType, value) end
		else
			local write = writes[parameterType]
			for index, value in values do write(cursor, value) end
		end
	else
		for index = 1, #parameters, 2 do
			local parameterType = parameters[index + 1]
			if type(parameterType) == "table" then
				SerializeTable(cursor, parameterType, values[parameters[index]])
			else
				writes[parameterType](cursor, values[parameters[index]])
			end
		end
	end
end

function DeserializeParameters(cursor: Cursor.Cursor, parameters: {string | {any}})
	local values = table.create(#parameters)
	for index, parameterType in parameters do
		if type(parameterType) == "table" then
			values[index] = DeserializeTable(cursor, parameterType)
		else
			values[index] = reads[parameterType](cursor)
		end
	end
	return table.unpack(values)
end

function DeserializeTable(cursor: Cursor.Cursor, parameters: {string | {any}})
	if #parameters == 1 then
		local length = cursor:ReadU2()
		local values = table.create(length)
		local parameterType = parameters[1]
		if type(parameterType) == "table" then
			for index = 1, length do table.insert(values, DeserializeTable(cursor, parameterType)) end
		else
			local read = reads[parameterType]
			for index = 1, length do table.insert(values, read(cursor)) end
		end
		return values
	else
		local values = {}
		for index = 1, #parameters, 2 do
			local parameterType = parameters[index + 1]
			if type(parameterType) == "table" then
				values[parameters[index]] = DeserializeTable(cursor, parameterType)
			else
				values[parameters[index]] = reads[parameterType](cursor)
			end
		end
		return values
	end
end

function Timeout(thread: thread, value: any)
	task.defer(thread, value)
end


-- Initialize
if RunService:IsServer() then
	playerCursors = {}
	playerThreads = {}
	playerBytes = {}
	playerError = {}
	packetCounter = 0
	local remoteEvent = Instance.new("RemoteEvent", script)

	local thread = task.spawn(function()
		while true do
			coroutine.yield()
			if cursor.Index > 0 then
				if #cursor.Instances == 0 then
					remoteEvent:FireAllClients(cursor:Truncate())
				else
					remoteEvent:FireAllClients(cursor:Truncate(), cursor.Instances)
				end
				cursor:Clear()
			end
			for player, cursor in playerCursors do
				if #cursor.Instances == 0 then
					remoteEvent:FireClient(player, cursor:Truncate())
				else
					remoteEvent:FireClient(player, cursor:Truncate(), cursor.Instances)
				end
			end
			table.clear(playerCursors)
			table.clear(playerBytes)
		end
	end)

	local Respond = function(packet: Packet, player: Player, index: number, ...)
		if packet.OnServerInvoke == nil then error(`OnServerInvoke not found for packet: {packet.Name}`) end
		local values = {packet.OnServerInvoke(player, ...)}
		--if TypeCheckParameters(packet.ResponseParameters, values) == false then error(`Response parameters did not match packet: '{packet.Name}'`) end
		if player.Parent == nil then return end
		local cursor = playerCursors[player]
		if cursor == nil then cursor = Cursor() playerCursors[player] = cursor end
		cursor:Allocate(2)
		cursor:WriteU1(packet.Id)
		local offset = cursor.Index * 8
		buffer.writebits(cursor.Buffer, offset + 0, 1, 1)
		buffer.writebits(cursor.Buffer, offset + 1, 7, index)
		cursor.Index += 1
		SerializeParameters(cursor, packet.ResponseParameters, values)
	end

	remoteEvent.OnServerEvent:Connect(function(player: Player, receivedBuffer: buffer, instances: {Instance}?)
		local bytes = (playerBytes[player] or 0) + buffer.len(receivedBuffer)
		if bytes > 8_000 then if playerError[player] then return else playerError[player] = true error(`{player.Name} is exceeding the data limit; some events may be dropped`) end end
		playerBytes[player] = bytes
		local cursor = Cursor(receivedBuffer, instances)
		while cursor.Index < cursor.Length do
			local packet = packets[cursor:ReadU1()]
			if packet.ResponseParameters then
				local offset = cursor.Index * 8
				local response = buffer.readbits(cursor.Buffer, offset + 0, 1)
				local index = buffer.readbits(cursor.Buffer, offset + 1, 7)
				cursor.Index += 1
				if response == 0 then
					Task:Defer(Respond, packet, player, index, DeserializeParameters(cursor, packet.Parameters))
				else
					local threads = playerThreads[player][index]
					if coroutine.status(threads.Yielded) == "suspended" then
						task.cancel(threads.Timeout)
						task.defer(threads.Yielded, DeserializeParameters(cursor, packet.ResponseParameters))
					else
						warn("Response thread not found for packet:", packet.Name, "discarding response:", DeserializeParameters(cursor, packet.ResponseParameters))
					end
				end
			else
				packet.OnServerEvent:Fire(player, DeserializeParameters(cursor, packet.Parameters))
			end
		end
	end)

	PlayersService.PlayerRemoving:Connect(function(player)
		playerCursors[player] = nil
		playerThreads[player] = nil
		playerBytes[player] = nil
		playerError[player] = nil
	end)

	RunService.Heartbeat:Connect(function() task.defer(thread) end)
else
	threads = {Index = 0}
	local remoteEvent = script:WaitForChild("RemoteEvent") :: RemoteEvent

	local thread = task.spawn(function()
		while true do
			coroutine.yield()
			if cursor.Index > 0 then
				if #cursor.Instances == 0 then
					remoteEvent:FireServer(cursor:Truncate())
				else
					remoteEvent:FireServer(cursor:Truncate(), cursor.Instances)
				end
				cursor:Clear()
			end
		end
	end)

	local Respond = function(packet: Packet, index: number, ...)
		if packet.OnClientInvoke == nil then error(`OnClientInvoke not found for packet: {packet.Name}`) end
		local values = {packet.OnClientInvoke(...)}
		--if TypeCheckParameters(packet.ResponseParameters, values) == false then error(`Response parameters did not match packet: '{packet.Name}'`) end
		cursor:Allocate(2)
		cursor:WriteU1(packet.Id)
		local offset = cursor.Index * 8
		buffer.writebits(cursor.Buffer, offset + 0, 1, 1)
		buffer.writebits(cursor.Buffer, offset + 1, 7, index)
		cursor.Index += 1
		SerializeParameters(cursor, packet.ResponseParameters, values)
	end

	remoteEvent.OnClientEvent:Connect(function(receivedBuffer: buffer, instances: {Instance}?)
		local cursor = Cursor(receivedBuffer, instances)
		while cursor.Index < cursor.Length do
			local packet = packets[cursor:ReadU1()]
			if packet.ResponseParameters then
				local offset = cursor.Index * 8
				local response = buffer.readbits(cursor.Buffer, offset + 0, 1)
				local index = buffer.readbits(cursor.Buffer, offset + 1, 7)
				cursor.Index += 1
				if response == 0 then
					Task:Defer(Respond, packet, index, DeserializeParameters(cursor, packet.Parameters))
				else
					local threads = threads[index]
					if coroutine.status(threads.Yielded) == "suspended" then
						task.cancel(threads.Timeout)
						task.defer(threads.Yielded, DeserializeParameters(cursor, packet.ResponseParameters))
					else
						warn("Response thread not found for packet:", packet.Name, "discarding response:", DeserializeParameters(cursor, packet.ResponseParameters))
					end
				end
			else
				packet.OnClientEvent:Fire(DeserializeParameters(cursor, packet.Parameters))
			end
		end
	end)

	script.AttributeChanged:Connect(function(name)
		local packet = packets[name]
		if packet then
			if packet.Id then packets[packet.Id] = nil end
			packet.Id = script:GetAttribute(name)
			if packet.Id then packets[packet.Id] = packet end
		end
	end)

	RunService.Heartbeat:Connect(function() task.defer(thread) end)
end

return setmetatable(Types.Names, {__call = Constructor})