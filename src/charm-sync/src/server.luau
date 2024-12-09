local Players = game:GetService("Players")

local Charm = require(script.Parent.Parent.Charm)
local interval = require(script.Parent.interval)
local patch = require(script.Parent.patch)
local types = require(script.Parent.types)
type SyncPayload = types.SyncPayload

type ServerOptions = {
	--[=[
		The atoms to synchronize with the client.
	]=]
	atoms: { [string | number]: Charm.Atom<any> },
	--[=[
		The interval at which to send patches to the client, in seconds.
		Defaults to `0` (patches are sent up to once per frame). Set to a
		negative value to disable automatic syncing.
	]=]
	interval: number?,
	--[=[
		Whether the history of state changes since the client's last update
		should be preserved. This is useful for values that change multiple times
		per frame, where each individual change is important. Defaults to `false`.
	]=]
	preserveHistory: boolean?,
	--[=[
		Whether to convert problematic sparse arrays into dictionaries with
		string keys. Defaults to `true`.

		While this is mandatory for safely syncing arrays over vanilla Roblox
		remotes, it can be disabled if your network library uses a custom
		serialization method (i.e. Zap, ByteNet).
	]=]
	serializeArrays: boolean?,
}

type ServerSyncer = {
	--[=[
		Sets up a subscription to each atom that schedules a patch to be sent to
		the client whenever the state changes. When a change occurs, the `callback`
		is called with the player and the payload to send.

		Note that the `payload` object should not be mutated. If you need to
		modify the payload, apply the changes to a copy of the object.

		@param callback The function to call when the state changes.
		@return A cleanup function that unsubscribes all listeners.
	]=]
	connect: (self: ServerSyncer, callback: (player: Player, ...SyncPayload) -> ()) -> () -> (),
	--[=[
		Hydrates the client's state with the server's state. This should be
		called when a player joins the game and requires the server's state.

		@param player The player to hydrate.
	]=]
	hydrate: (self: ServerSyncer, player: Player) -> (),
	--[=[
		@deprecated For internal use only.
	]=]
	_sendPatch: (self: ServerSyncer, player: Player) -> (),
}

--[=[
	Creates a `ServerSyncer` object that sends patches to the client and
	hydrates the client's state.
	
	@param options The atoms to synchronize with the client.
	@return A `ServerSyncer` object.
]=]
local function server(options: ServerOptions): ServerSyncer
	local self = {} :: ServerSyncer
	local sync: (player: Player, payload: SyncPayload) -> ()

	local function createSnapshot()
		local snapshot = {}

		for key, atom in next, options.atoms do
			snapshot[key] = atom()
		end

		return snapshot
	end

	-- Send the initial state to a player when they join the server.
	function self:hydrate(player)
		assert(sync, "connect() must be called before hydrate()")

		sync(player, {
			type = "init",
			data = createSnapshot(),
		})
	end

	-- If the history of state changes should be preserved, keep a list of
	-- previous snapshots and diff-check each one from the last.
	if options.preserveHistory then
		local snapshots = { createSnapshot() }
		local changed = false

		function self:connect(callback)
			local subscriptions = {}

			sync = callback

			local function pushSnapshot(key: string | number, current: any, previous: any)
				local lastSnapshot = snapshots[#snapshots]
				local previousSnapshot = snapshots[#snapshots - 1]

				-- Optimize snapshots by updating the most recent snapshot if the
				-- previous and current values are the same, since this allows us
				-- to group multiple changes into a single snapshot.
				if previousSnapshot and previousSnapshot[key] == previous and lastSnapshot[key] == previous then
					lastSnapshot[key] = current
				else
					local nextSnapshot = table.clone(lastSnapshot)
					nextSnapshot[key] = current
					table.insert(snapshots, nextSnapshot)
				end
			end

			-- Populate the snapshot with the initial state of each atom.
			-- Subscribe to each atom and update the state when it changes.
			for key, atom in next, options.atoms do
				subscriptions[key] = Charm.subscribe(atom, function(current, previous)
					pushSnapshot(key, current, previous)
					changed = true
				end)
			end

			local disconnect = interval(function()
				if not changed then
					return
				end

				local payloads: { SyncPayload } = {}
				local lastSnapshot

				for index, snapshot in next, snapshots do
					lastSnapshot = snapshot

					if index == 1 then
						continue
					end

					table.insert(payloads, {
						type = "patch",
						data = patch.diff(snapshots[index - 1], snapshot, options.serializeArrays),
					})
				end

				snapshots = { lastSnapshot }
				changed = false

				for _, player in next, Players:GetPlayers() do
					callback(player, unpack(payloads))
				end
			end, options.interval or 0)

			return function()
				disconnect()

				for _, unsubscribe in next, subscriptions do
					unsubscribe()
				end
			end
		end

		function self:_sendPatch(player: Player)
			assert(sync, "connect() must be called before _sendPatch()")

			if not changed then
				return
			end

			local payloads: { SyncPayload } = {}

			for index, snapshot in next, snapshots do
				if index == 1 then
					continue
				end

				table.insert(payloads, {
					type = "patch",
					data = patch.diff(snapshots[index - 1], snapshot, options.serializeArrays),
				})
			end

			snapshots = { snapshots[#snapshots] }
			changed = false

			sync(player, unpack(payloads))
		end

		return self
	end

	local previousSnapshot = createSnapshot()
	local currentSnapshot = table.clone(previousSnapshot)
	local changed = false

	function self:connect(callback)
		local subscriptions = {}

		sync = callback

		-- Subscribe to each atom and update the state when one changes.
		for key, atom in next, options.atoms do
			subscriptions[key] = Charm.subscribe(atom, function(state)
				currentSnapshot[key] = state
				changed = true
			end)
		end

		local disconnect = interval(function()
			if not changed then
				return
			end

			local payload: SyncPayload = {
				type = "patch",
				data = patch.diff(previousSnapshot, currentSnapshot, options.serializeArrays),
			}

			previousSnapshot = table.clone(currentSnapshot)
			changed = false

			for _, player in next, Players:GetPlayers() do
				callback(player, payload)
			end
		end, options.interval or 0)

		return function()
			disconnect()

			for _, unsubscribe in next, subscriptions do
				unsubscribe()
			end
		end
	end

	function self:_sendPatch(player)
		assert(sync, "connect() must be called before _sendPatch()")

		if not changed then
			return
		end

		local payload: SyncPayload = {
			type = "patch",
			data = patch.diff(previousSnapshot, currentSnapshot, options.serializeArrays),
		}

		previousSnapshot = table.clone(currentSnapshot)
		changed = false

		sync(player, payload)
	end

	return self
end

return server
