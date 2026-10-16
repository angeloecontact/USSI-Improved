--!nonstrict
-- ====================================================================
-- 🗺️ ALL-IN-ONE AUTOMATIC STREAMING DUMPER (v3.0 - Full Map Harvester)
-- Repositorio: angeloecontact/USSI-Improved
-- ====================================================================
-- NOVEDADES CLAVE v3.0:
-- 1. Barrido de 3D Total (Sin límite artificial de 3000 studs):
--    El mapa mide más de 7,000 studs en X y sube hasta Y=500. Ahora
--    cubre hasta 15,000 studs de radio y muestrea múltiples alturas Y.
-- 2. Barrido Dirigido de Stages & Checkpoints:
--    Teletransporta al personaje directamente a cada Stage (0 al 15) y Checkpoint
--    garantizando que el servidor replique el 100% de los túneles y obstáculos.
-- 3. Cosecha Dinámica Incremental (Anti-Piezas Faltantes):
--    Si un modelo o stage llega "a trozos", detecta cuando se descargan más piezas
--    y actualiza el clon con el modelo completo (soluciona túneles cortados y puertas flotantes).
-- 4. Consolidación O(1) con descansos anti-timeout y guardado seguro con Bytecode.
-- ====================================================================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local function notify(title, text, duration)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title or "USSI Dumper",
            Text = text or "",
            Duration = duration or 5,
        })
    end)
end

local function log(fmt, ...)
    print(string.format("[USSI Dumper v3.0] " .. fmt, ...))
end

-- ====================================================================
-- CONFIGURACIÓN
-- ====================================================================
local userConfig = (type(getgenv) == "function" and getgenv().DumperConfig) or {}
local CONFIG = {
    Step = userConfig.Step or 350,                  -- Tamaño del paso de la cuadrícula (studs)
    WaitPerStage = userConfig.WaitPerStage or 0.60, -- Espera en cada Stage para replicación completa
    WaitPerChunk = userConfig.WaitPerChunk or 0.28, -- Espera en puntos de cuadrícula
    MaxRadius = userConfig.MaxRadius or 15000,      -- Límite de seguridad extendido a 15,000 studs
    Heights = { 45, 180, 360, 490 },               -- Muestreo vertical para túneles aéreos
    AutoRun = (userConfig.AutoRun ~= false),
}

-- ====================================================================
-- ACUMULADOR EN MEMORIA (Inmune a Stream-Out)
-- ====================================================================
local accumulatorFolder = Instance.new("Folder")
accumulatorFolder.Name = "__USSI_MemoryAccumulator"

local capturedItems = {}  -- [original] = { clone = Instance, count = number, parent = Instance, path = string }
local totalHarvested = 0

local function makeArchivableRecursive(root)
    pcall(function() root.Archivable = true end)
    local ok, descs = pcall(function() return root:GetDescendants() end)
    if ok and descs then
        for _, d in ipairs(descs) do
            pcall(function() d.Archivable = true end)
        end
    end
end

-- Cosecha segura: Si un modelo crece porque llegaron más piezas, lo actualiza
local function harvestItem(item, parent)
    if not item or not item.Parent then return end
    if item:IsA("Terrain") or item:IsA("Camera") or Players:GetPlayerFromCharacter(item) then return end

    local okCount, descCount = pcall(function() return #item:GetDescendants() end)
    if not okCount then descCount = 0 end

    local record = capturedItems[item]
    if not record or descCount > record.count then
        makeArchivableRecursive(item)
        local okClone, clone = pcall(function() return item:Clone() end)
        if okClone and clone then
            if record and record.clone then
                pcall(function() record.clone:Destroy() end)
            else
                totalHarvested = totalHarvested + 1
            end

            local pathSegments = {}
            local curr = parent
            while curr and curr ~= Workspace and curr ~= game do
                table.insert(pathSegments, 1, curr.Name)
                curr = curr.Parent
            end

            clone:SetAttribute("__OriginalPath", table.concat(pathSegments, "/"))
            clone.Parent = accumulatorFolder

            capturedItems[item] = {
                clone = clone,
                count = descCount,
                parent = parent,
                path = table.concat(pathSegments, "/"),
                cf = item:IsA("BasePart") and item.CFrame or nil,
                pivot = item:IsA("Model") and item:GetPivot() or nil,
            }
        end
    end
end

local function harvestWorkspace()
    for _, rootItem in ipairs(Workspace:GetChildren()) do
        if not (rootItem:IsA("Terrain") or rootItem:IsA("Camera") or Players:GetPlayerFromCharacter(rootItem)) then
            if rootItem:IsA("Folder") then
                for _, sub in ipairs(rootItem:GetChildren()) do
                    harvestItem(sub, rootItem)
                end
            else
                harvestItem(rootItem, Workspace)
            end
        end
    end
end

-- ====================================================================
-- DETECCIÓN DINÁMICA DE LÍMITES 3D REALES
-- ====================================================================
local function getFullWorldBounds()
    local minX, minZ = math.huge, math.huge
    local maxX, maxZ = -math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge
    local found = false

    for _, desc in ipairs(Workspace:GetDescendants()) do
        if desc:IsA("BasePart") and not desc:IsA("Terrain") then
            local p = desc.Position
            if math.abs(p.X) < CONFIG.MaxRadius and math.abs(p.Z) < CONFIG.MaxRadius then
                found = true
                if p.X < minX then minX = p.X end
                if p.X > maxX then maxX = p.X end
                if p.Z < minZ then minZ = p.Z end
                if p.Z > maxZ then maxZ = p.Z end
                if p.Y < minY then minY = p.Y end
                if p.Y > maxY then maxY = p.Y end
            end
        end
    end

    if not found or minX == math.huge then
        return -2000, 2000, 50, 200, -2000, 2000
    end

    local margin = 350
    return math.max(-CONFIG.MaxRadius, minX - margin),
           math.min(CONFIG.MaxRadius, maxX + margin),
           math.max(-100, minY - 50),
           math.min(1500, maxY + 100),
           math.max(-CONFIG.MaxRadius, minZ - margin),
           math.min(CONFIG.MaxRadius, maxZ + margin)
end

-- ====================================================================
-- FLUJO PRINCIPAL
-- ====================================================================
local function runFullStreamingDumper()
    local lp = Players.LocalPlayer
    local char = lp.Character or lp.CharacterAdded:Wait()
    local hrp = char:WaitForChild("HumanoidRootPart", 10)
    local humanoid = char:FindFirstChildOfClass("Humanoid")

    notify("USSI Dumper v3.0", "Iniciando barrido completo 3D...", 4)
    log("Iniciando Dumper v3.0 (Full Map & All Stages)...")

    -- 1. Cosecha inicial
    harvestWorkspace()
    log("Objetos asegurados inicialmente: %d", totalHarvested)

    local isStreaming = Workspace.StreamingEnabled
    if isStreaming and hrp then
        local originalCFrame = hrp.CFrame

        -- Noclip e invulnerabilidad contra caídas/lava
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

        -- ================================================================
        -- FASE 1: BARRIDO DIRIGIDO DE STAGES Y CHECKPOINTS
        -- ================================================================
        log("Fase 1: Recorriendo Stages y Checkpoints directamente...")
        notify("USSI Dumper v3.0", "Fase 1: Cargando cada Stage del mapa...", 4)

        local targetPoints = {}

        -- Buscar carpetas de Stages en Structure
        local structure = Workspace:FindFirstChild("Structure")
        if structure then
            for _, stage in ipairs(structure:GetChildren()) do
                local refPart = stage:FindFirstChildWhichIsA("BasePart", true)
                if refPart then
                    table.insert(targetPoints, { Name = stage.Name, Pos = refPart.Position + Vector3.new(0, 10, 0) })
                end
            end
        end

        -- Buscar Checkpoints y Spawns
        local checkpoints = Workspace:FindFirstChild("Checkpoints")
        if checkpoints then
            for _, cp in ipairs(checkpoints:GetDescendants()) do
                if cp:IsA("BasePart") then
                    table.insert(targetPoints, { Name = "CP_" .. cp.Name, Pos = cp.Position + Vector3.new(0, 8, 0) })
                end
            end
        end

        log("Puntos clave detectados: %d", #targetPoints)
        for idx, pt in ipairs(targetPoints) do
            hrp.CFrame = CFrame.new(pt.Pos)
            pcall(function()
                lp:RequestStreamAroundAsync(pt.Pos, 5)
            end)
            task.wait(CONFIG.WaitPerStage)
            harvestWorkspace()

            if idx % 5 == 0 or idx == #targetPoints then
                log("  Stage %d/%d (%s) cargado | Modelos: %d", idx, #targetPoints, pt.Name, totalHarvested)
            end
        end

        -- ================================================================
        -- FASE 2: BARRIDO DE CUADRÍCULA 3D EXTENDIDO
        -- ================================================================
        local minX, maxX, minY, maxY, minZ, maxZ = getFullWorldBounds()
        local step = CONFIG.Step
        local xSteps = math.ceil((maxX - minX) / step)
        local zSteps = math.ceil((maxZ - minZ) / step)
        local totalGrid = xSteps * zSteps
        local currentGrid = 0
        local lastNotify = os.clock()

        log("Fase 2: Cuadrícula X=[%.0f, %.0f], Y=[%.0f, %.0f], Z=[%.0f, %.0f] (%d celdas)",
            minX, maxX, minY, maxY, minZ, maxZ, totalGrid)
        notify("USSI Dumper v3.0", string.format("Fase 2: Barrido 3D (~%d puntos)...", totalGrid), 4)

        -- Determinar alturas óptimas según la elevación del mapa
        local sweepHeights = {}
        for _, h in ipairs(CONFIG.Heights) do
            if h >= minY - 40 and h <= maxY + 60 then
                table.insert(sweepHeights, h)
            end
        end
        if #sweepHeights == 0 then
            sweepHeights = { math.clamp(minY + 50, 40, 500) }
        end

        for x = minX, maxX, step do
            for z = minZ, maxZ, step do
                currentGrid = currentGrid + 1

                for _, y in ipairs(sweepHeights) do
                    local targetPos = Vector3.new(x, y, z)
                    hrp.CFrame = CFrame.new(targetPos)

                    pcall(function()
                        lp:RequestStreamAroundAsync(targetPos, 3)
                    end)
                end

                task.wait(CONFIG.WaitPerChunk)
                harvestWorkspace()

                if (os.clock() - lastNotify > 5) or currentGrid == totalGrid then
                    lastNotify = os.clock()
                    log("  Progreso 3D: %d/%d (%.0f%%) | Instancias: %d",
                        currentGrid, totalGrid, (currentGrid / totalGrid) * 100, totalHarvested)
                end
            end
        end

        -- Restaurar personaje
        noclipConn:Disconnect()
        hrp.CFrame = originalCFrame
        hrp.Anchored = false
        log("¡Barrido completado! Total cosechado: %d objetos", totalHarvested)
    else
        log("StreamingEnabled no activo o HRP ausente. Guardado directo.")
    end

    -- ================================================================
    -- FASE 3: CONSOLIDACIÓN SEGURA EN WORKSPACE (O(1) Anti-Freeze)
    -- ================================================================
    log("Fase 3: Consolidando mapa en Workspace...")
    notify("USSI Dumper v3.0", "Consolidando instancias en Workspace...", 4)

    local reinjected = 0
    local folderCache = {}
    local yieldCounter = 0

    for originalItem, record in pairs(capturedItems) do
        yieldCounter = yieldCounter + 1
        if yieldCounter % 80 == 0 then
            task.wait()
        end

        local stillAlive = false
        pcall(function()
            if originalItem and originalItem.Parent and originalItem:IsDescendantOf(Workspace) then
                -- Verificar si el original tiene al menos las mismas piezas que nuestro clon
                local currentCount = #originalItem:GetDescendants()
                if currentCount >= record.count then
                    stillAlive = true
                end
            end
        end)

        if not stillAlive and record.clone then
            -- Reinyectar el clon completo
            local targetParent = Workspace
            local path = record.path

            if path ~= "" then
                local cached = folderCache[path]
                if cached and cached.Parent then
                    targetParent = cached
                else
                    for folderName in string.gmatch(path, "[^/]+") do
                        local nextFolder = targetParent:FindFirstChild(folderName)
                        if not nextFolder then
                            nextFolder = Instance.new("Folder")
                            nextFolder.Name = folderName
                            nextFolder.Parent = targetParent
                        end
                        targetParent = nextFolder
                    end
                    folderCache[path] = targetParent
                end
            end

            -- Si el original aún estaba en Workspace pero incompleto, lo quitamos
            pcall(function()
                if originalItem and originalItem.Parent then
                    originalItem:Destroy()
                end
            end)

            record.clone.Parent = targetParent
            if record.cf and record.clone:IsA("BasePart") then
                record.clone.CFrame = record.cf
            elseif record.pivot and record.clone:IsA("Model") then
                record.clone:PivotTo(record.pivot)
            end
            reinjected = reinjected + 1
        elseif record.clone then
            pcall(function() record.clone:Destroy() end)
        end
    end

    log("Instancias completas re-inyectadas: %d", reinjected)

    -- ================================================================
    -- FASE 4: GUARDADO CON USSI SAVEINSTANCE (Bytecode intacto)
    -- ================================================================
    log("Fase 4: Ejecutando USSI SaveInstance...")
    notify("USSI Dumper v3.0", "Generando archivo .rbxlx con 100% del mapa...", 6)

    local saveinstanceUrl = "https://raw.githubusercontent.com/angeloecontact/USSI-Improved/main/saveinstance.luau"
    local saveinstanceChunk = loadstring(game:HttpGet(saveinstanceUrl, true), "saveinstance")

    if not saveinstanceChunk then
        error("[USSI Dumper] Error al compilar saveinstance.luau desde GitHub.")
        return
    end

    local saveinstance = saveinstanceChunk()
    if type(saveinstance) ~= "function" then
        error("[USSI Dumper] saveinstance no retornó una función ejecutable.")
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

    notify("USSI Dumper v3.0", "¡MAPA 100% GUARDADO CON ÉXITO!", 10)
    log("====================================================================")
    log("✅ VOLCADO COMPLETO Y EXITOSO (v3.0)")
    log("• Todos los Stages y túneles fueron asegurados y consolidados.")
    log("• El archivo .rbxlx ya está listo en tu carpeta workspace.")
    log("====================================================================")
end

getgenv().RunUSSIStreamingDumper = runFullStreamingDumper

if CONFIG.AutoRun then
    task.spawn(runFullStreamingDumper)
end
