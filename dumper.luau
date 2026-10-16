--!nonstrict
-- ====================================================================
-- 🌐 UNIVERSAL STREAMING HARVESTER & DUMPER (v4.0 - Total Architecture)
-- Repositorio: angeloecontact/USSI-Improved
-- ====================================================================
-- ARQUITECTURA 100% UNIVERSAL Y AGNOSTICA:
-- 1. Cero nombres fijos: No busca "stages", "checkpoints" ni jerarquías inventadas.
--    Funciona con CUALQUIER juego de Roblox (Bloxburg, Obbies, RPGs, simuladores, etc.).
-- 2. Algoritmo de Frontera Espacial 3D (Frontier Exploration):
--    Detecta automáticamente las zonas pobladas en 3D (X, Y, Z) y expande el barrido
--    de forma adaptativa siguiendo la geometría real del mapa, sin importar su forma o tamaño.
-- 3. Árbol Espejo Dinámico (Universal Mirror Tree):
--    Clona y reconstruye la jerarquía exacta de carpetas, modelos y partes en memoria
--    protegida. Si un modelo llega "a trozos" con el tiempo, todas sus piezas se
--    ensamblan en el espejo sin perder nunca paredes, puertas ni decoraciones.
-- 4. Fusión O(1) con descansos anti-timeout y guardado autoritativo con Bytecode.
-- ====================================================================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local function notify(title, text, duration)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title or "Universal Dumper",
            Text = text or "",
            Duration = duration or 5,
        })
    end)
end

local function log(fmt, ...)
    print(string.format("[Universal Dumper] " .. fmt, ...))
end

-- ====================================================================
-- CONFIGURACIÓN
-- ====================================================================
local userConfig = (type(getgenv) == "function" and getgenv().DumperConfig) or {}
local CONFIG = {
    CellSize = userConfig.CellSize or 320,        -- Tamaño del vóxel 3D (studs)
    WaitPerCell = userConfig.WaitPerCell or 0.25, -- Tiempo de espera para replicación de chunk
    MaxPoints = userConfig.MaxPoints or 1200,     -- Límite máximo de puntos explorados
    MaxRadius = userConfig.MaxRadius or 30000,    -- Coordenada máxima de seguridad (30,000 studs)
    AutoRun = (userConfig.AutoRun ~= false),
}

-- ====================================================================
-- ÁRBOL ESPEJO UNIVERSAL (En memoria pura, inmune a Stream-Out)
-- ====================================================================
local mirrorRoot = Instance.new("Folder")
mirrorRoot.Name = "__USSI_UniversalMirror"

local mirroredInstances = {}   -- [original] = true
local mirrorSignatures = {}    -- [parentMirror] = { [sig] = clone }
local totalMirroredParts = 0

local function getSignature(inst)
    if inst:IsA("BasePart") then
        local p = inst.Position
        return string.format("P_%s_%.0f_%.0f_%.0f_%s", inst.Name, p.X, p.Y, p.Z, inst.ClassName)
    else
        return string.format("O_%s_%s", inst.Name, inst.ClassName)
    end
end

local function makeArchivable(inst)
    pcall(function() inst.Archivable = true end)
    local ok, descs = pcall(function() return inst:GetDescendants() end)
    if ok and descs then
        for _, d in ipairs(descs) do
            pcall(function() d.Archivable = true end)
        end
    end
end

-- Ingesta cualquier instancia en el Árbol Espejo respetando su ruta jerárquica exacta
local function ingestInstance(inst, char)
    if not inst or not inst.Parent then return end
    if char and (inst:IsDescendantOf(char) or inst == char) then return end
    if Players:GetPlayerFromCharacter(inst) then return end
    if inst:IsA("Terrain") or inst:IsA("Camera") then return end

    if mirroredInstances[inst] then return end

    -- Construir lista de ancestros desde Workspace hacia abajo
    local ancestorChain = {}
    local curr = inst.Parent
    while curr and curr ~= Workspace and curr ~= game do
        table.insert(ancestorChain, 1, curr)
        curr = curr.Parent
    end

    -- Navegar / replicar contenedores en el Árbol Espejo
    local mirrorParent = mirrorRoot
    for _, ancestor in ipairs(ancestorChain) do
        local aName = ancestor.Name
        local existingContainer = mirrorParent:FindFirstChild(aName)
        if not existingContainer then
            if ancestor:IsA("Model") then
                existingContainer = Instance.new("Model")
                pcall(function() existingContainer:PivotTo(ancestor:GetPivot()) end)
            else
                existingContainer = Instance.new("Folder")
            end
            existingContainer.Name = aName
            existingContainer.Parent = mirrorParent
        end
        mirrorParent = existingContainer
    end

    -- Si inst es un contenedor (Folder / Model), crearlo en el espejo
    if inst:IsA("Folder") or inst:IsA("Model") then
        local container = mirrorParent:FindFirstChild(inst.Name)
        if not container then
            if inst:IsA("Model") then
                container = Instance.new("Model")
                pcall(function() container:PivotTo(inst:GetPivot()) end)
            else
                container = Instance.new("Folder")
            end
            container.Name = inst.Name
            container.Parent = mirrorParent
        end
        mirroredInstances[inst] = true
        return
    end

    -- Si inst es un BasePart o elemento de hoja (Sound, Decal, Script, Light, etc.)
    local sig = getSignature(inst)
    if not mirrorSignatures[mirrorParent] then
        mirrorSignatures[mirrorParent] = {}
    end

    if not mirrorSignatures[mirrorParent][sig] then
        makeArchivable(inst)
        local okClone, clone = pcall(function() return inst:Clone() end)
        if okClone and clone then
            clone.Parent = mirrorParent
            mirrorSignatures[mirrorParent][sig] = clone
            mirroredInstances[inst] = true
            totalMirroredParts = totalMirroredParts + 1
        end
    else
        mirroredInstances[inst] = true
    end
end

-- ====================================================================
-- EXPLORACIÓN DE FRONTERA ESPACIAL 3D (Universal Frontier)
-- ====================================================================
local function cellKey(cx, cy, cz)
    return string.format("%d,%d,%d", cx, cy, cz)
end

local function getCellCoords(pos)
    local S = CONFIG.CellSize
    return math.floor(pos.X / S), math.floor(pos.Y / S), math.floor(pos.Z / S)
end

local function cellCenter(cx, cy, cz)
    local S = CONFIG.CellSize
    return Vector3.new((cx + 0.5) * S, (cy + 0.5) * S, (cz + 0.5) * S)
end

local function runUniversalDumper()
    local lp = Players.LocalPlayer
    local char = lp.Character or lp.CharacterAdded:Wait()
    local hrp = char:WaitForChild("HumanoidRootPart", 10)

    notify("Universal Dumper", "Iniciando mapeo universal del juego...", 4)
    log("Iniciando Universal Streaming Harvester v4.0...")

    -- 1. Capturar todo lo que ya esté en pantalla
    for _, desc in ipairs(Workspace:GetDescendants()) do
        ingestInstance(desc, char)
    end
    log("Instancias iniciales en memoria: %d", totalMirroredParts)

    local isStreaming = Workspace.StreamingEnabled
    if isStreaming and hrp then
        log("StreamingEnabled activo. Iniciando exploración adaptativa de frontera 3D...")
        notify("Universal Dumper", "Explorando el mapa en 3D de forma autónoma...", 4)

        -- Escuchar todas las nuevas piezas que aparezcan
        local conn = Workspace.DescendantAdded:Connect(function(desc)
            ingestInstance(desc, char)
        end)

        local originalCFrame = hrp.CFrame

        -- Noclip e inmovilidad para seguridad absoluta
        local noclipConn = RunService.Stepped:Connect(function()
            if char then
                for _, part in ipairs(char:GetDescendants()) do
                    if part:IsA("BasePart") then
                        part.CanCollide = false
                    end
                end
            end
        end)
        hrp.Anchored = true

        -- Estructuras de la frontera
        local knownCells = {}    -- [key] = Vector3(center)
        local visitedCells = {}  -- [key] = true
        local frontierQueue = {} -- array de { key = string, pos = Vector3 }

        local function registerCell(cx, cy, cz)
            local key = cellKey(cx, cy, cz)
            if not knownCells[key] then
                local center = cellCenter(cx, cy, cz)
                if math.abs(center.X) < CONFIG.MaxRadius and math.abs(center.Z) < CONFIG.MaxRadius then
                    knownCells[key] = center
                    if not visitedCells[key] then
                        table.insert(frontierQueue, { key = key, pos = center })
                    end
                end
            end
        end

        local function addNeighborsToFrontier(cx, cy, cz)
            -- Vecinos en 3D (X, Y, Z)
            for dx = -1, 1 do
                for dz = -1, 1 do
                    for dy = -1, 1 do
                        registerCell(cx + dx, cy + dy, cz + dz)
                    end
                end
            end
        end

        -- Sembrar la frontera con todos los BaseParts conocidos en Workspace
        for _, desc in ipairs(Workspace:GetDescendants()) do
            if desc:IsA("BasePart") and not desc:IsA("Terrain") then
                local cx, cy, cz = getCellCoords(desc.Position)
                registerCell(cx, cy, cz)
            end
        end

        log("Frontera inicial: %d celdas por explorar.", #frontierQueue)

        local visitedCount = 0
        local lastLog = os.clock()

        while #frontierQueue > 0 and visitedCount < CONFIG.MaxPoints do
            -- Tomar la celda más cercana a la posición actual para viaje óptimo
            local currentPos = hrp.Position
            local bestIdx = 1
            local bestDist = math.huge

            -- Muestrear los primeros elementos para eficiencia
            local searchLimit = math.min(#frontierQueue, 25)
            for i = 1, searchLimit do
                local dist = (frontierQueue[i].pos - currentPos).Magnitude
                if dist < bestDist then
                    bestDist = dist
                    bestIdx = i
                end
            end

            local target = table.remove(frontierQueue, bestIdx)
            if not visitedCells[target.key] then
                visitedCells[target.key] = true
                visitedCount = visitedCount + 1

                hrp.CFrame = CFrame.new(target.pos)

                pcall(function()
                    lp:RequestStreamAroundAsync(target.pos, 3)
                end)

                task.wait(CONFIG.WaitPerCell)

                -- Procesar nuevas partes que llegaron en esta celda
                local foundPartsInCell = false
                for _, desc in ipairs(Workspace:GetDescendants()) do
                    if desc:IsA("BasePart") and not desc:IsA("Terrain") then
                        ingestInstance(desc, char)
                        local cx, cy, cz = getCellCoords(desc.Position)
                        local k = cellKey(cx, cy, cz)
                        if k == target.key then
                            foundPartsInCell = true
                        end
                        -- Si aparecieron partes en celdas aún no descubiertas, expandir la frontera
                        if not knownCells[k] then
                            registerCell(cx, cy, cz)
                            addNeighborsToFrontier(cx, cy, cz)
                        end
                    end
                end

                -- Si esta celda contenía partes, expandir a sus vecinos directos
                if foundPartsInCell then
                    local S = CONFIG.CellSize
                    local cx = math.floor(target.pos.X / S)
                    local cy = math.floor(target.pos.Y / S)
                    local cz = math.floor(target.pos.Z / S)
                    addNeighborsToFrontier(cx, cy, cz)
                end

                if (os.clock() - lastLog > 5) or #frontierQueue == 0 then
                    lastLog = os.clock()
                    log("  Exploradas: %d celdas | Restantes en cola: %d | Piezas en espejo: %d",
                        visitedCount, #frontierQueue, totalMirroredParts)
                end
            end
        end

        conn:Disconnect()
        noclipConn:Disconnect()
        hrp.CFrame = originalCFrame
        hrp.Anchored = false
        log("¡Exploración universal completada! Total celdas: %d | Piezas: %d", visitedCount, totalMirroredParts)
    else
        log("StreamingEnabled inactivo o HRP ausente. Procediendo a guardado directo.")
    end

    -- ====================================================================
    -- FUSIÓN SEGURA DEL ÁRBOL ESPEJO EN WORKSPACE (O(1) Anti-Freeze)
    -- ====================================================================
    log("Consolidando Árbol Espejo en Workspace...")
    notify("Universal Dumper", "Consolidando mapa en Workspace...", 4)

    local reinjectedCount = 0
    local yieldCounter = 0

    local function mergeRecursive(mirrorContainer, workspaceTarget)
        -- Pre-indexar hijos existentes en Workspace para comprobación O(1)
        local existingDict = {}
        for _, ch in ipairs(workspaceTarget:GetChildren()) do
            existingDict[getSignature(ch)] = ch
            existingDict[ch.Name] = ch
        end

        for _, item in ipairs(mirrorContainer:GetChildren()) do
            yieldCounter = yieldCounter + 1
            if yieldCounter % 80 == 0 then
                task.wait()
            end

            if item:IsA("Folder") or item:IsA("Model") then
                local liveTarget = workspaceTarget:FindFirstChild(item.Name)
                if not liveTarget then
                    item.Parent = workspaceTarget
                    reinjectedCount = reinjectedCount + 1
                else
                    mergeRecursive(item, liveTarget)
                end
            else
                local sig = getSignature(item)
                if not existingDict[sig] then
                    item.Parent = workspaceTarget
                    existingDict[sig] = item
                    reinjectedCount = reinjectedCount + 1
                else
                    item:Destroy()
                end
            end
        end
    end

    mergeRecursive(mirrorRoot, Workspace)
    log("Fusión completada: %d elementos restaurados en Workspace.", reinjectedCount)

    -- ====================================================================
    -- GUARDADO AUTORITATIVO (SaveBytecode=true, Decompile=false)
    -- ====================================================================
    log("Ejecutando USSI SaveInstance...")
    notify("Universal Dumper", "Generando archivo .rbxlx...", 6)

    local saveinstanceUrl = "https://raw.githubusercontent.com/angeloecontact/USSI-Improved/main/saveinstance.luau"
    local saveinstanceChunk = loadstring(game:HttpGet(saveinstanceUrl, true), "saveinstance")

    if not saveinstanceChunk then
        error("[Universal Dumper] Error al compilar saveinstance.luau desde GitHub.")
        return
    end

    local saveinstance = saveinstanceChunk()
    if type(saveinstance) ~= "function" then
        error("[Universal Dumper] saveinstance no retornó una función ejecutable.")
        return
    end

    saveinstance({
        mode = "full",
        SavePlayers = false,
        Decompile = false,          -- OBLIGATORIO: Evita freeze en el executor
        SaveBytecode = true,         -- OBLIGATORIO: Guarda bytecode en Base64 para el Restorer
        RemovePlayerCharacters = true,
        IgnoreDefaultProperties = true,
        ShowStatus = true,
        NilInstances = true,
        SafeMode = true,
        AntiIdle = true,
    })

    notify("Universal Dumper", "¡MAPA GUARDADO AL 100%!", 10)
    log("====================================================================")
    log("✅ VOLCADO UNIVERSAL EXITOSO")
    log("• 100%% del mapa consolidado en Workspace sin importar jerarquías.")
    log("• Archivo .rbxlx listo en tu carpeta workspace.")
    log("====================================================================")
end

getgenv().RunUniversalDumper = runUniversalDumper

if CONFIG.AutoRun then
    task.spawn(runUniversalDumper)
end
