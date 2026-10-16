--!nonstrict
-- ====================================================================
-- 🌐 UNIVERSAL STREAMING HARVESTER & DUMPER (v5.1 - Surface Lock & Deep Dwell)
-- Repositorio: angeloecontact/USSI-Improved
-- ====================================================================
-- NOVEDADES Y CORRECCIONES CRÍTICAS v5.1:
-- 1. Teletransporte a Nivel de Superficie (Surface-Level Lock):
--    Antes el jugador se teletransportaba al centro matemático del vóxel 3D
--    (a veces a 90 studs de altura en el aire o bajo el suelo), dejando los
--    keycaps y plataformas fuera del radio de streaming (StreamingMinRadius = 200).
--    Ahora se sitúa exactamente sobre la superficie de la geometría (Y + 3.5 studs).
-- 2. Streaming Sincrónico Asistido por Motor (RequestStreamAroundAsync):
--    Se ejecuta de forma sincrónica con timeout de 1.8s para obligar al
--    servidor de Roblox a entregar el paquete completo de la zona antes de evaluar.
-- 3. Quiescencia de Red Real (Deep Quiescence):
--    MinWait de 200ms para absorber la latencia (ping) de red, y ventana de
--    quiescencia de 350ms con techo de hasta 3.0s en zonas hiperdensas de keycaps.
-- 4. Tamaño de celda ultra-seguro (140 studs):
--    El radio máximo a cualquier esquina es de ~99 studs (muy por debajo de los 200
--    studs garantizados del juego), eliminando todo corte diagonal o parche ciego.
-- 5. Límite MaxCells ampliado a 3500:
--    Cubre mapas gigantes de más de 25,000 studs de longitud sin cortarse a mitad de camino.
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
banner.Size = UDim2.new(0, 420, 0, 80)
banner.Position = UDim2.new(0.5, -210, 0, 30)
banner.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
banner.BorderSizePixel = 0
banner.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = banner

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, 0, 0, 28)
titleLabel.Position = UDim2.new(0, 0, 0, 6)
titleLabel.BackgroundTransparency = 1
titleLabel.TextColor3 = Color3.fromRGB(0, 230, 140)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 15
titleLabel.Text = "⚡ UNIVERSAL DUMPER v5.1 (Deep Dwell)"
titleLabel.Parent = banner

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -20, 0, 34)
statusLabel.Position = UDim2.new(0, 10, 0, 36)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 13
statusLabel.Text = "Iniciando sistema..."
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
    CellSize = userConfig.CellSize or 140,              -- 140 studs (radio máximo esquina < 100 studs)
    MinWaitPerCell = userConfig.MinWaitPerCell or 0.20, -- Mínimo 200ms para absorber ping de red
    QuiescenceTimeout = userConfig.QuiescenceTimeout or 0.35, -- 350ms sin piezas antes de avanzar
    MaxWaitPerCell = userConfig.MaxWaitPerCell or 3.0,  -- Techo generoso para miles de keycaps
    MaxCells = userConfig.MaxCells or 3500,             -- Suficiente para recorrer cualquier mapa de punta a punta
    AutoRun = (userConfig.AutoRun ~= false),
}

-- ====================================================================
-- IDENTIFICADORES Y ÁRBOL ESPEJO PROTEGIDO
-- ====================================================================
local mirrorRoot = Instance.new("Folder")
mirrorRoot.Name = "__USSI_UniversalMirror"

local mirroredInstances = {}
local mirrorContainers = {}
local mirrorSignatures = {}
local totalMirroredParts = 0

local function getContainerKey(inst)
    if inst:IsA("Model") then
        local ok, cf = pcall(function() return inst:GetPivot() end)
        local p = (ok and cf and cf.Position) or Vector3.zero
        return string.format("M_%s_%.1f_%.1f_%.1f", inst.Name, p.X, p.Y, p.Z)
    else
        return "F_" .. inst.Name
    end
end

local function getPartSignature(inst)
    if inst:IsA("BasePart") then
        local p = inst.Position
        local s = inst.Size
        return string.format("P_%s_%.2f_%.2f_%.2f_%.2f_%.2f_%.2f_%s", 
            inst.Name, p.X, p.Y, p.Z, s.X, s.Y, s.Z, inst.ClassName)
    elseif inst:IsA("Decal") or inst:IsA("Texture") then
        return string.format("D_%s_%s_%s", inst.Name, inst.ClassName, tostring(inst.Face))
    elseif inst:IsA("Attachment") then
        local p = inst.Position
        return string.format("A_%s_%.2f_%.2f_%.2f", inst.Name, p.X, p.Y, p.Z)
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

local function ingestInstance(inst)
    if not inst or not inst.Parent then return end

    -- Ignorar personajes de jugadores
    for _, p in ipairs(Players:GetPlayers()) do
        local pChar = p.Character
        if pChar and (inst == pChar or inst:IsDescendantOf(pChar)) then return end
    end
    if inst:IsA("Terrain") or inst:IsA("Camera") then return end

    if mirroredInstances[inst] then return end

    -- Reconstruir la cadena de contenedores ancestros
    local ancestorChain = {}
    local curr = inst.Parent
    while curr and curr ~= Workspace and curr ~= game do
        table.insert(ancestorChain, 1, curr)
        curr = curr.Parent
    end

    local mirrorParent = mirrorRoot
    for _, ancestor in ipairs(ancestorChain) do
        local cKey = getContainerKey(ancestor)
        if not mirrorContainers[mirrorParent] then
            mirrorContainers[mirrorParent] = {}
        end

        local existingContainer = mirrorContainers[mirrorParent][cKey]
        if not existingContainer then
            if ancestor:IsA("Model") then
                existingContainer = Instance.new("Model")
                pcall(function() existingContainer:PivotTo(ancestor:GetPivot()) end)
            else
                existingContainer = Instance.new("Folder")
            end
            existingContainer.Name = ancestor.Name
            existingContainer.Parent = mirrorParent
            mirrorContainers[mirrorParent][cKey] = existingContainer
        end
        mirrorParent = existingContainer
    end

    -- Si la instancia es un contenedor en sí misma
    if inst:IsA("Folder") or inst:IsA("Model") then
        local cKey = getContainerKey(inst)
        if not mirrorContainers[mirrorParent] then
            mirrorContainers[mirrorParent] = {}
        end

        local container = mirrorContainers[mirrorParent][cKey]
        if not container then
            if inst:IsA("Model") then
                container = Instance.new("Model")
                pcall(function() container:PivotTo(inst:GetPivot()) end)
            else
                container = Instance.new("Folder")
            end
            container.Name = inst.Name
            container.Parent = mirrorParent
            mirrorContainers[mirrorParent][cKey] = container
        end
        mirroredInstances[inst] = true
        return
    end

    -- Instancia hoja (BasePart u objeto)
    local sig = getPartSignature(inst)
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

            -- Los hijos ya viajan dentro del clon; marcarlos como procesados
            local okDescs, descs = pcall(function() return inst:GetDescendants() end)
            if okDescs and descs then
                for _, d in ipairs(descs) do
                    mirroredInstances[d] = true
                end
            end
        end
    else
        mirroredInstances[inst] = true
    end
end

-- ====================================================================
-- RASTREADOR ESPACIAL ADAPTATIVO (Surface-Level Guided Sweeper)
-- ====================================================================
local function cellKey(cx, cy, cz)
    return string.format("%d,%d,%d", cx, cy, cz)
end

local function getCellCoords(pos)
    local S = CONFIG.CellSize
    return math.floor(pos.X / S), math.floor(pos.Y / S), math.floor(pos.Z / S)
end

local function runUniversalDumper()
    local char = lp.Character or lp.CharacterAdded:Wait()
    local hrp = char:WaitForChild("HumanoidRootPart", 10)

    local function getActiveHRP()
        if hrp and hrp.Parent and hrp.Parent.Parent then return hrp end
        local c = lp.Character
        if c then
            local root = c:FindFirstChild("HumanoidRootPart")
            if root then
                hrp = root
                return hrp
            end
        end
        return nil
    end

    setHUD("Escaneando geometria inicial...", false)

    -- Ingesta inicial
    for _, desc in ipairs(Workspace:GetDescendants()) do
        ingestInstance(desc)
    end
    setHUD(string.format("Inicial: %d piezas aseguradas", totalMirroredParts), false)

    local isStreaming = Workspace.StreamingEnabled
    local activeHRP = getActiveHRP()
    if isStreaming and activeHRP then
        local originalCFrame = activeHRP.CFrame

        local noclipConn = RunService.Stepped:Connect(function()
            local c = lp.Character
            if c then
                for _, part in ipairs(c:GetDescendants()) do
                    if part:IsA("BasePart") then
                        part.CanCollide = false
                    end
                end
            end
        end)
        pcall(function() activeHRP.Anchored = true end)

        local visitedCells = {}
        local queuedCells = {}
        local queue = {}

        local function queueCellIfGeometry(pos)
            local cx, cy, cz = getCellCoords(pos)
            local k = cellKey(cx, cy, cz)
            if not queuedCells[k] and not visitedCells[k] then
                queuedCells[k] = true
                -- Teletransportarse directamente al nivel de la superficie (Y + 3.5 studs)
                table.insert(queue, { key = k, pos = Vector3.new(pos.X, pos.Y + 3.5, pos.Z) })
            end
        end

        for _, desc in ipairs(Workspace:GetDescendants()) do
            if desc:IsA("BasePart") and not desc:IsA("Terrain") then
                queueCellIfGeometry(desc.Position)
            end
        end

        local lastStreamedTime = os.clock()

        local descendantConn = Workspace.DescendantAdded:Connect(function(desc)
            lastStreamedTime = os.clock()
            ingestInstance(desc)
            if desc:IsA("BasePart") and not desc:IsA("Terrain") then
                queueCellIfGeometry(desc.Position)
            end
        end)

        local visitedCount = 0
        local lastLog = os.clock()

        while #queue > 0 and visitedCount < CONFIG.MaxCells do
            local currentHRP = getActiveHRP()
            local currentPos = (currentHRP and currentHRP.Position) or Vector3.zero
            local bestIdx = 1
            local bestDist = math.huge

            -- Buscar el sector más cercano en TODA la cola para una ruta continua y óptima
            for i = 1, #queue do
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
                    local curRoot = getActiveHRP()
                    if curRoot then
                        curRoot.CFrame = CFrame.new(target.pos)
                        curRoot.Anchored = true
                    end
                end)

                -- Solicitar activamente el streaming de la zona alrededor de la posición exacta
                pcall(function()
                    lp:RequestStreamAroundAsync(target.pos, 1.8)
                end)

                -- Quiescencia de red profunda: esperar mientras el servidor siga entregando paquetes
                local dwellStart = os.clock()
                task.wait(CONFIG.MinWaitPerCell)

                while (os.clock() - lastStreamedTime < CONFIG.QuiescenceTimeout) and (os.clock() - dwellStart < CONFIG.MaxWaitPerCell) do
                    task.wait(0.05)
                end

                if (os.clock() - lastLog > 1.5) or #queue == 0 then
                    lastLog = os.clock()
                    setHUD(string.format("Rastreando: %d sectores | Cola: %d | Piezas: %d",
                        visitedCount, #queue, totalMirroredParts), false)
                end
            end
        end

        descendantConn:Disconnect()
        noclipConn:Disconnect()
        pcall(function()
            local finalHRP = getActiveHRP()
            if finalHRP then
                finalHRP.CFrame = originalCFrame
                finalHRP.Anchored = false
            end
        end)
        setHUD(string.format("Barrido completado: %d piezas capturadas", totalMirroredParts), false)
    end

    -- ================================================================
    -- FUSIÓN ROBUSTA BASADA EN PIVOTS (Sin colapso de modelos)
    -- ================================================================
    setHUD("Consolidando mapa completo en Workspace...", false)

    local reinjectedCount = 0
    local yieldCounter = 0

    local function mergeRecursive(mirrorContainer, workspaceTarget)
        local existingParts = {}
        local liveContainers = {}

        for _, ch in ipairs(workspaceTarget:GetChildren()) do
            if ch:IsA("Folder") or ch:IsA("Model") then
                liveContainers[getContainerKey(ch)] = ch
            else
                existingParts[getPartSignature(ch)] = ch
            end
        end

        for _, item in ipairs(mirrorContainer:GetChildren()) do
            yieldCounter = yieldCounter + 1
            if yieldCounter % 80 == 0 then
                task.wait()
            end

            if item:IsA("Folder") or item:IsA("Model") then
                local cKey = getContainerKey(item)
                local liveTarget = liveContainers[cKey]
                if not liveTarget then
                    item.Parent = workspaceTarget
                    liveContainers[cKey] = item
                    reinjectedCount = reinjectedCount + 1
                else
                    mergeRecursive(item, liveTarget)
                end
            else
                local sig = getPartSignature(item)
                if not existingParts[sig] then
                    item.Parent = workspaceTarget
                    existingParts[sig] = item
                    reinjectedCount = reinjectedCount + 1
                else
                    item:Destroy()
                end
            end
        end
    end

    mergeRecursive(mirrorRoot, Workspace)
    setHUD(string.format("Consolidado: %d elementos restaurados", reinjectedCount), false)

    -- Destruir contenedor espejo
    pcall(function() mirrorRoot:Destroy() end)
    task.wait(0.3)

    -- ================================================================
    -- GUARDADO SEGURO ANTI-CRASH (SafeMode=false, KillAllScripts=false)
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
        Decompile = false,          -- OBLIGATORIO: Evita freeze de decompilación
        SaveBytecode = true,         -- OBLIGATORIO: Bytecode Base64 intacto
        RemovePlayerCharacters = true,
        IgnoreDefaultProperties = true,
        ShowStatus = true,
        SafeMode = false,           -- ¡OBLIGATORIO FALSE! Evita que te eche (Kick) y tumbe el juego
        KillAllScripts = false,     -- ¡OBLIGATORIO FALSE! Evita corromper threads y getgc() en el executor
        NilInstances = false,        -- Evita escanear memoria basura de nil
        SaveCacheInterval = 8000,    -- Escritura en bloques con descansos frecuentes
    })

    setHUD("✅ ¡GUARDADO EXITOSO! Revisa tu carpeta workspace.", true)
end

getgenv().RunUniversalDumper = runUniversalDumper

if CONFIG.AutoRun then
    task.spawn(runUniversalDumper)
end
