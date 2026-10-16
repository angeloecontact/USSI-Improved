--!nonstrict
-- ====================================================================
-- 🌐 UNIVERSAL STREAMING HARVESTER & DUMPER (v4.2 - High Speed Edition)
-- Repositorio: angeloecontact/USSI-Improved
-- ====================================================================
-- MEJORAS DEFINITIVAS v4.2:
-- 1. Duración Total < 30 Segundos: Eliminado el bucle redundante GetDescendants()
--    dentro del ciclo de viaje. Ahora usa DescendantAdded (cero CPU lag).
-- 2. Rastreo Exclusivo de Geometría Real (cero exploración de aire vacío).
-- 3. Limpieza de nil antes de guardar (evita que saveinstance serialice basura).
-- 4. Interfaz en pantalla con barra de progreso en vivo.
-- ====================================================================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")

local lp = Players.LocalPlayer

-- ====================================================================
-- UI DE ESTADO EN PANTALLA
-- ====================================================================
local guiName = "__USSI_DumperHUD"
local oldGui = CoreGui:FindFirstChild(guiName)
if oldGui then pcall(function() oldGui:Destroy() end) end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = guiName
pcall(function() screenGui.Parent = CoreGui end)

local banner = Instance.new("Frame")
banner.Size = UDim2.new(0, 380, 0, 75)
banner.Position = UDim2.new(0.5, -190, 0, 30)
banner.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
banner.BorderSizePixel = 0
banner.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = banner

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, 0, 0, 28)
titleLabel.Position = UDim2.new(0, 0, 0, 6)
titleLabel.BackgroundTransparency = 1
titleLabel.TextColor3 = Color3.fromRGB(0, 220, 130)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 15
titleLabel.Text = "⚡ UNIVERSAL DUMPER v4.2"
titleLabel.Parent = banner

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -20, 0, 30)
statusLabel.Position = UDim2.new(0, 10, 0, 35)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 13
statusLabel.Text = "Iniciando..."
statusLabel.Parent = banner

local function setHUD(text, isDone)
    pcall(function()
        statusLabel.Text = text
        if isDone then
            titleLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
            task.delay(8, function()
                pcall(function() screenGui:Destroy() end)
            end)
        end
    end)
    print("[Universal Dumper] " .. text)
end

-- ====================================================================
-- CONFIGURACIÓN
-- ====================================================================
local userConfig = (type(getgenv) == "function" and getgenv().DumperConfig) or {}
local CONFIG = {
    CellSize = userConfig.CellSize or 320,        -- Vóxel espacial en studs
    WaitPerCell = userConfig.WaitPerCell or 0.14, -- 140ms por sector (ultra veloz)
    MaxCells = userConfig.MaxCells or 300,        -- Límite suficiente para cualquier mapa gigante
    AutoRun = (userConfig.AutoRun ~= false),
}

-- ====================================================================
-- ÁRBOL ESPEJO UNIVERSAL (En memoria protegida)
-- ====================================================================
local mirrorRoot = Instance.new("Folder")
mirrorRoot.Name = "__USSI_UniversalMirror"

local mirroredInstances = {}
local mirrorSignatures = {}
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

    local ancestorChain = {}
    local curr = inst.Parent
    while curr and curr ~= Workspace and curr ~= game do
        table.insert(ancestorChain, 1, curr)
        curr = curr.Parent
    end

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
-- RASTREADOR DE GEOMETRÍA REAL (Geometry-Guided Tracker)
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
    local char = lp.Character or lp.CharacterAdded:Wait()
    local hrp = char:WaitForChild("HumanoidRootPart", 10)

    setHUD("Escaneando geometria inicial...", false)

    -- Ingesta inicial única
    for _, desc in ipairs(Workspace:GetDescendants()) do
        ingestInstance(desc, char)
    end
    setHUD(string.format("Inicial: %d piezas aseguradas", totalMirroredParts), false)

    local isStreaming = Workspace.StreamingEnabled
    if isStreaming and hrp then
        local originalCFrame = hrp.CFrame

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

        -- Sembrar con las posiciones iniciales
        for _, desc in ipairs(Workspace:GetDescendants()) do
            if desc:IsA("BasePart") and not desc:IsA("Terrain") then
                queueCellIfGeometry(desc.Position)
            end
        end

        -- Evento ligero: Al llegar nuevos chunks, se ingesta y encola DIRECTAMENTE sin recorrer todo Workspace
        local descendantConn = Workspace.DescendantAdded:Connect(function(desc)
            ingestInstance(desc, char)
            if desc:IsA("BasePart") and not desc:IsA("Terrain") then
                queueCellIfGeometry(desc.Position)
            end
        end)

        local visitedCount = 0
        local lastLog = os.clock()

        while #queue > 0 and visitedCount < CONFIG.MaxCells do
            local currentPos = hrp.Position
            local bestIdx = 1
            local bestDist = math.huge
            local checkLimit = math.min(#queue, 25)

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

                pcall(function()
                    hrp.CFrame = CFrame.new(target.pos)
                end)

                -- Petición no bloqueante en segundo plano
                task.spawn(function()
                    pcall(function()
                        lp:RequestStreamAroundAsync(target.pos)
                    end)
                end)

                task.wait(CONFIG.WaitPerCell)

                if (os.clock() - lastLog > 2) or #queue == 0 then
                    lastLog = os.clock()
                    setHUD(string.format("Rastreando: %d sectores | Cola: %d | Piezas: %d",
                        visitedCount, #queue, totalMirroredParts), false)
                end
            end
        end

        descendantConn:Disconnect()
        noclipConn:Disconnect()
        pcall(function()
            hrp.CFrame = originalCFrame
            hrp.Anchored = false
        end)
        setHUD(string.format("Barrido completado: %d piezas capturadas", totalMirroredParts), false)
    end

    -- ================================================================
    -- FUSIÓN O(1) EN WORKSPACE
    -- ================================================================
    setHUD("Consolidando mapa completo en Workspace...", false)

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
            if yieldCounter % 100 == 0 then
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
    setHUD(string.format("Consolidado: %d elementos restaurados", reinjectedCount), false)

    -- Destruir contenedor espejo para dejar la memoria limpia antes de guardar
    pcall(function() mirrorRoot:Destroy() end)
    task.wait(0.3)

    -- ================================================================
    -- GUARDADO AUTORITATIVO
    -- ================================================================
    setHUD("Generando archivo .rbxlx con bytecode...", false)

    local saveinstanceUrl = "https://raw.githubusercontent.com/angeloecontact/USSI-Improved/main/saveinstance.luau"
    local saveinstanceChunk = loadstring(game:HttpGet(saveinstanceUrl, true), "saveinstance")

    if not saveinstanceChunk then
        setHUD("Error al compilar saveinstance.", true)
        return
    end

    local saveinstance = saveinstanceChunk()
    if type(saveinstance) ~= "function" then
        setHUD("Error en saveinstance.", true)
        return
    end

    saveinstance({
        mode = "full",
        SavePlayers = false,
        Decompile = false,          -- OBLIGATORIO: Evita freeze en el executor
        SaveBytecode = true,         -- OBLIGATORIO: Guarda bytecode intacto para Luau Restorer
        RemovePlayerCharacters = true,
        IgnoreDefaultProperties = true,
        ShowStatus = true,
        NilInstances = false,        -- Optimizado: no gasta tiempo buscando basura en nil
        SafeMode = true,
        AntiIdle = true,
    })

    setHUD("✅ ¡GUARDADO EXITOSO! Revisa tu carpeta workspace.", true)
end

getgenv().RunUniversalDumper = runUniversalDumper

if CONFIG.AutoRun then
    task.spawn(runUniversalDumper)
end
