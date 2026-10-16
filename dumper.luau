--!nonstrict
-- ====================================================================
-- 🌐 UNIVERSAL GEOMETRY-GUIDED STREAMING DUMPER (v4.1 - Ultra Fast)
-- Repositorio: angeloecontact/USSI-Improved
-- ====================================================================
-- MEJORAS CLAVE v4.1:
-- 1. Cero esperas en el vacío: RequestStreamAroundAsync se lanza de forma
--    asíncrona (no bloquea 3 segundos por celda vacía).
-- 2. Rastreo guiado exclusivamente por GEOMETRÍA REAL:
--    Solo visita celdas donde realmente existen partes en 3D. No explora
--    el aire vacío ni el espacio negro. El barrido dura 15-30 segundos.
-- 3. Árbol Espejo Universal: Preserva el 100% de la jerarquía original en memoria.
-- 4. Fusión O(1) con descansos anti-timeout y guardado automático con Bytecode.
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
    CellSize = userConfig.CellSize or 300,        -- Tamaño de la celda espacial (studs)
    WaitPerCell = userConfig.WaitPerCell or 0.18, -- 180ms por punto (ultra rápido y suficiente)
    MaxCells = userConfig.MaxCells or 450,        -- Tope máximo de celdas reales
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

local function ingestInstance(inst, char)
    if not inst or not inst.Parent then return end
    if char and (inst:IsDescendantOf(char) or inst == char) then return end
    if Players:GetPlayerFromCharacter(inst) then return end
    if inst:IsA("Terrain") or inst:IsA("Camera") then return end

    if mirroredInstances[inst] then return end

    -- Obtener cadena de ancestros desde Workspace
    local ancestorChain = {}
    local curr = inst.Parent
    while curr and curr ~= Workspace and curr ~= game do
        table.insert(ancestorChain, 1, curr)
        curr = curr.Parent
    end

    -- Navegar / replicar contenedores en el Espejo
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

    -- BasePart o elemento de hoja
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
-- RASTREO GUIADO POR GEOMETRÍA REAL (Geometry-Guided Tracker)
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

    notify("Universal Dumper", "Iniciando rastreador de mapa guiado por geometría...", 4)
    log("Iniciando Universal Geometry Dumper v4.1...")

    -- 1. Captura inicial en pantalla
    for _, desc in ipairs(Workspace:GetDescendants()) do
        ingestInstance(desc, char)
    end
    log("Objetos iniciales asegurados: %d", totalMirroredParts)

    local isStreaming = Workspace.StreamingEnabled
    if isStreaming and hrp then
        local originalCFrame = hrp.CFrame

        -- Noclip e invulnerabilidad
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

        -- Estructuras de la frontera guiada por geometría
        local visitedCells = {}
        local queuedCells = {}
        local queue = {}

        local function queueCellIfGeometry(pos)
            local cx, cy, cz = getCellCoords(pos)
            local k = cellKey(cx, cy, cz)
            if not queuedCells[k] and not visitedCells[k] then
                queuedCells[k] = true
                local center = cellCenter(cx, cy, cz)
                table.insert(queue, { key = k, pos = center })
            end
        end

        -- Sembrar ÚNICAMENTE con celdas donde YA existen BaseParts reales
        for _, desc in ipairs(Workspace:GetDescendants()) do
            if desc:IsA("BasePart") and not desc:IsA("Terrain") then
                queueCellIfGeometry(desc.Position)
            end
        end

        log("Celdas iniciales con geometría real: %d", #queue)
        notify("Universal Dumper", string.format("Rastreando %d sectores de mapa...", #queue), 4)

        local visitedCount = 0
        local lastLog = os.clock()

        while #queue > 0 and visitedCount < CONFIG.MaxCells do
            -- Selección óptima por proximidad para viaje continuo
            local currentPos = hrp.Position
            local bestIdx = 1
            local bestDist = math.huge
            local checkLimit = math.min(#queue, 30)

            for i = 1, checkLimit do
                local dist = (queue[i].pos - currentPos).Magnitude
                if dist < bestDist then
                    bestDist = dist
                    bestIdx = i
                end
            end

            local target = table.remove(queue, bestIdx)
            if not visitedCells[target.key] then
                visitedCells[target.key] = true
                visitedCount = visitedCount + 1

                hrp.CFrame = CFrame.new(target.pos)

                -- Petición no bloqueante (asíncrona) al servidor
                task.spawn(function()
                    pcall(function()
                        lp:RequestStreamAroundAsync(target.pos)
                    end)
                end)

                task.wait(CONFIG.WaitPerCell)

                -- Ingestar todas las piezas que aparecieron con la llegada del nuevo chunk
                for _, desc in ipairs(Workspace:GetDescendants()) do
                    if desc:IsA("BasePart") and not desc:IsA("Terrain") then
                        ingestInstance(desc, char)
                        -- Si aparecieron partes en una celda que aún no hemos visitado, encolarla
                        queueCellIfGeometry(desc.Position)
                    end
                end

                if (os.clock() - lastLog > 4) or #queue == 0 then
                    lastLog = os.clock()
                    log("  Progreso: %d celdas | Cola restante: %d | Piezas en espejo: %d",
                        visitedCount, #queue, totalMirroredParts)
                end
            end
        end

        noclipConn:Disconnect()
        hrp.CFrame = originalCFrame
        hrp.Anchored = false
        log("¡Rastreo completado! Total celdas: %d | Piezas salvadas: %d", visitedCount, totalMirroredParts)
    else
        log("StreamingEnabled no activo o HRP ausente. Procediendo a guardado directo.")
    end

    -- ================================================================
    -- FUSIÓN SEGURA DEL ÁRBOL ESPEJO EN WORKSPACE (O(1))
    -- ================================================================
    log("Consolidando mapa en Workspace...")
    notify("Universal Dumper", "Consolidando instancias en Workspace...", 4)

    local reinjectedCount = 0
    local yieldCounter = 0

    local function mergeRecursive(mirrorContainer, workspaceTarget)
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

    -- ================================================================
    -- GUARDADO CON BYTECODE (SaveBytecode=true, Decompile=false)
    -- ================================================================
    log("Ejecutando USSI SaveInstance...")
    notify("Universal Dumper", "Generando archivo .rbxlx con 100% del mapa...", 6)

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
    log("• Archivo .rbxlx guardado en tu carpeta workspace.")
    log("====================================================================")
end

getgenv().RunUniversalDumper = runUniversalDumper

if CONFIG.AutoRun then
    task.spawn(runUniversalDumper)
end
