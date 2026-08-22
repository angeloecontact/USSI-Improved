--!nonstrict
--[[
	USSI-Improved · prefetch de chunks + colector
	Ejecutar ANTES de saveinstance, en un place con StreamingEnabled.

	Qué hace:
	  1. barre el mapa en rejilla llamando a Player:RequestStreamAroundAsync,
	     sin mover tu personaje, para que el servidor te replique cada zona
	  2. expande los límites del barrido a medida que aparece mapa nuevo
	  3. cosecha lo que llega a un Folder fuera de Workspace, para que el
	     stream-out no te lo quite después
	  4. deja el Folder en getgenv().USSI_ExtraInstances para el loader

	Límite que no se puede saltar: StreamingTargetRadius es una propiedad
	no scriptable del servidor. Puedes pedir zonas, no pedir más radio.
--]]

local CONFIG = {
	Step          = 400,    -- studs entre puntos; por debajo del radio del servidor
	Heights       = { 0 },  -- alturas a muestrear; añade capas si el mapa es vertical
	Timeout       = 5,      -- timeOut de RequestStreamAroundAsync
	Settle        = 0.30,   -- espera tras cada petición
	MaxRounds     = 4,      -- rondas de expansión de límites
	MaxPoints     = 900,    -- tope duro de peticiones, por si el mapa es enorme
	Margin        = 600,    -- studs de margen alrededor de lo ya cargado

	Harvest       = true,   -- clonar a un folder que el streaming no toque
	HarvestEvery  = 12,     -- cosechar cada N puntos
	MemoryCeiling = 4500,   -- MB; por encima, deja de cosechar
	SkipNames     = { Terrain = true, Camera = true },

	MoveCharacter = false,  -- fallback si el servidor ignora las peticiones
	Verbose       = true,
}

--============================ SERVICIOS ============================--

local Players = game:GetService("Players")
local Stats = game:GetService("Stats")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local function log(fmt, ...)
	if CONFIG.Verbose then
		print("[PREFETCH] " .. string.format(fmt, ...))
	end
end

local function warnf(fmt, ...)
	warn("[PREFETCH] " .. string.format(fmt, ...))
end

local function sleep(seconds)
	if type(task) == "table" and type(task.wait) == "function" then
		task.wait(seconds)
	else
		wait(seconds)
	end
end

local function memoryMb()
	local ok, mb = pcall(function()
		return Stats:GetTotalMemoryUsageMb()
	end)
	if ok and type(mb) == "number" then return mb end
	return 0
end

--============================ LÍMITES DEL MAPA ============================--

-- Solo podemos medir lo que ya está cargado. Por eso el barrido es iterativo:
-- cada ronda ensancha la caja con lo que apareció en la anterior. De paso
-- marcamos qué celdas ya tienen geometría, para no pedir el interior del mapa.
local function cellKey(x, z)
	return string.format("%d:%d", math.floor(x / CONFIG.Step), math.floor(z / CONFIG.Step))
end

local function scanWorld()
	local minX, minZ = math.huge, math.huge
	local maxX, maxZ = -math.huge, -math.huge
	local occupied = {}
	local found = false

	for _, descendant in ipairs(Workspace:GetDescendants()) do
		local ok, position = pcall(function()
			if descendant:IsA("BasePart") then return descendant.Position end
			return nil
		end)
		if ok and position then
			found = true
			occupied[cellKey(position.X, position.Z)] = true
			if position.X < minX then minX = position.X end
			if position.X > maxX then maxX = position.X end
			if position.Z < minZ then minZ = position.Z end
			if position.Z > maxZ then maxZ = position.Z end
		end
	end

	if not found then return nil, {} end
	local m = CONFIG.Margin
	return { minX = minX - m, maxX = maxX + m, minZ = minZ - m, maxZ = maxZ + m }, occupied
end

-- Celda con geometría y con las cuatro vecinas también cargadas: interior,
-- no hace falta pedirla. Solo nos interesa la frontera.
local function isInterior(occupied, position)
	if not occupied[cellKey(position.X, position.Z)] then return false end
	local s = CONFIG.Step
	local neighbours = {
		{ position.X + s, position.Z }, { position.X - s, position.Z },
		{ position.X, position.Z + s }, { position.X, position.Z - s },
	}
	for _, n in ipairs(neighbours) do
		if not occupied[cellKey(n[1], n[2])] then return false end
	end
	return true
end

local function boundsArea(b)
	if not b then return 0 end
	return (b.maxX - b.minX) * (b.maxZ - b.minZ)
end

local function gridPoints(bounds)
	local points = {}
	local step = CONFIG.Step
	local x = bounds.minX
	while x <= bounds.maxX do
		local z = bounds.minZ
		while z <= bounds.maxZ do
			for _, y in ipairs(CONFIG.Heights) do
				points[#points + 1] = Vector3.new(x, y, z)
			end
			z = z + step
		end
		x = x + step
	end
	return points
end

--============================ COSECHA ============================--

local Holder = Instance.new("Folder")
Holder.Name = "USSI_Collected"
-- Sin Parent: fuera de Workspace, el streaming no lo puede vaciar.

local captured = {}   -- instancia original -> nº de descendientes ya capturados
local cloneOf = {}    -- instancia original -> clon
local harvestedCount = 0

local function makeArchivable(root)
	pcall(function()
		root.Archivable = true
	end)
	local ok, descendants = pcall(function()
		return root:GetDescendants()
	end)
	if not ok then return end
	for _, descendant in ipairs(descendants) do
		if not descendant.Archivable then
			pcall(function()
				descendant.Archivable = true
			end)
		end
	end
end

local function harvest()
	if not CONFIG.Harvest then return end

	local mb = memoryMb()
	if mb > 0 and mb > CONFIG.MemoryCeiling then
		warnf("memoria en %d MB, por encima del techo (%d) — dejo de cosechar", mb, CONFIG.MemoryCeiling)
		CONFIG.Harvest = false
		return
	end

	local ok, children = pcall(function()
		return Workspace:GetChildren()
	end)
	if not ok then return end

	for _, child in ipairs(children) do
		local skip = CONFIG.SkipNames[child.Name] or CONFIG.SkipNames[child.ClassName]
		if not skip and not (Players:GetPlayerFromCharacter(child)) then
			local okCount, count = pcall(function()
				return #child:GetDescendants()
			end)
			if okCount then
				local previous = captured[child]
				-- Un modelo puede llegar a trozos: si creció, se reclona.
				if previous == nil or count > previous then
					makeArchivable(child)
					local okClone, clone = pcall(function()
						return child:Clone()
					end)
					if okClone and clone then
						local old = cloneOf[child]
						if old then
							pcall(function()
								old:Destroy()
							end)
						end
						clone.Parent = Holder
						cloneOf[child] = clone
						captured[child] = count
						if previous == nil then
							harvestedCount = harvestedCount + 1
						end
					end
				end
			end
		end
	end
end

--============================ BARRIDO ============================--

local function requestAt(position)
	local ok, err = pcall(function()
		LocalPlayer:RequestStreamAroundAsync(position, CONFIG.Timeout)
	end)
	if not ok then
		return false, tostring(err)
	end
	return true
end

local function moveCharacterTo(position)
	if not CONFIG.MoveCharacter then return end
	pcall(function()
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			root.CFrame = CFrame.new(position)
		end
	end)
end

local function sweep()
	if not Workspace.StreamingEnabled then
		log("este place no usa StreamingEnabled — ya tienes todo el mapa cargado")
		return false
	end

	local totalRequests = 0
	local visited = {}
	local previousArea = 0

	for round = 1, CONFIG.MaxRounds do
		local bounds, occupied = scanWorld()
		if not bounds then
			warnf("no hay nada cargado todavía; ¿ya entró la partida?")
			return false
		end

		local area = boundsArea(bounds)
		if round > 1 and area <= previousArea * 1.02 then
			log("ronda %d: el mapa dejó de crecer, paro", round)
			break
		end
		previousArea = area

		local points = gridPoints(bounds)
		log("ronda %d: %d puntos, caja %.0f x %.0f studs",
			round, #points, bounds.maxX - bounds.minX, bounds.maxZ - bounds.minZ)

		local sinceHarvest = 0
		local skipped = 0
		local harvestedAtRoundStart = harvestedCount
		for _, position in ipairs(points) do
			local key = string.format("%d,%d,%d", position.X, position.Y, position.Z)
			if not visited[key] then
				visited[key] = true
				if isInterior(occupied, position) then
					skipped = skipped + 1
				else
				totalRequests = totalRequests + 1
				if totalRequests > CONFIG.MaxPoints then
					warnf("tope de %d peticiones alcanzado", CONFIG.MaxPoints)
					harvest()
					return true
				end

				moveCharacterTo(position)
				local ok, err = requestAt(position)
				if not ok then
					warnf("petición fallida en %s: %s", key, err)
				end
				sleep(CONFIG.Settle)

				sinceHarvest = sinceHarvest + 1
				if sinceHarvest >= CONFIG.HarvestEvery then
					sinceHarvest = 0
					harvest()
					log("  %d peticiones · %d objetos guardados · %d MB",
						totalRequests, harvestedCount, memoryMb())
				end
				end
			end
		end
		harvest()

		if skipped > 0 then
			log("  %d puntos saltados por estar ya cargados", skipped)
		end
		if round > 1 and harvestedCount == harvestedAtRoundStart then
			log("ronda %d: nada nuevo, paro", round)
			break
		end
	end

	log("barrido terminado: %d peticiones", totalRequests)
	return true
end

--============================ MAIN ============================--

local function main()
	if not LocalPlayer then
		warnf("no hay LocalPlayer")
		return
	end

	local startedAt = os.clock()
	sweep()
	harvest()

	local genv = (type(getgenv) == "function" and getgenv()) or _G
	genv.USSI_ExtraInstances = { Holder }
	genv.USSI_Collected = Holder

	log("listo en %.0f s · %d objetos en USSI_Collected · %d MB",
		os.clock() - startedAt, harvestedCount, memoryMb())
	log("ahora ejecuta el loader con: ExtraInstances = getgenv().USSI_ExtraInstances")

	return Holder
end

return main()
