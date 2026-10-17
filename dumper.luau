--!nonstrict
-- ====================================================================
-- 🌐 UNIVERSAL STREAMING HARVESTER & DUMPER (v5.4 - Universal Pool & LOD Master)
-- Repositorio: angeloecontact/USSI-Improved
-- ====================================================================
-- MEJORAS CRÍTICAS v5.4 (Anti-Loss & Object-Pool Immunit):
-- 1. Deduplicación por Firma Espacial Pura (Anti-Pool Loss):
--    Se eliminó el bloqueo por puntero de instancia (mirroredInstances[inst]) que
--    descartaba piezas cuando un object pool las reciclaba o movía a otra posición.
--    Ahora cada posición única en el mundo se clona y preserva sin duplicados.
-- 2. Sincronización Estricta de Cámara (LOD & Streaming Activator):
--    Workspace.CurrentCamera se teletransporta en sincronía exacta con el personaje,
--    forzando a los motores de streaming y chunk renderers basados en cámara a cargar
--    de inmediato todos los detalles del sector.
-- 3. Barrido Espacial Local 3D (GetPartBoundsInBox):
--    En cada sector se realiza una consulta geométrica 3D nativa para capturar cualquier
--    pieza que haya cambiado de CFrame sin disparar eventos de reparenting.
-- 4. Jerarquía de Modelos Estable (Anti-Splintering):
--    Claves de contenedor estables para evitar que modelos grandes se fragmenten
--    a medida que su bounding box se expande con el streaming.
-- 5. Materializador Maestro de Pools en Memoria:
--    Sincroniza y materializa al 100% registros en memoria (KeycapPoolRenderer)
--    garantizando que ninguna tecla, rampa o campo quede vacío.
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
titleLabel.Text = "⚡ UNIVERSAL DUMPER v5.4 (Pool Master)"
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
    CellSize = userConfig.CellSize or 140,              -- 140 studs horizontal
    CellSizeY = userConfig.CellSizeY or 60,             -- 60 studs vertical (pisos y montañas)
    MinWaitPerCell = userConfig.MinWaitPerCell or 0.18, -- 180ms inicial para absorber latencia
    QuiescenceTimeout = userConfig.QuiescenceTimeout or 0.28, -- 280ms sin nuevas piezas antes de avanzar
    MaxWaitPerCell = userConfig.MaxWaitPerCell or 1.8,  -- Techo estricto de 1.8s (imposible trabarse)
    MaxCells = userConfig.MaxCells or 5000,             -- 5000 sectores para cubrir cualquier mapa
    AutoRun = (userConfig.AutoRun ~= false),
}

-- ====================================================================
-- IDENTIFICADORES Y ÁRBOL ESPEJO PROTEGIDO
-- ====================================================================
local mirrorRoot = Instance.new("Folder")
mirrorRoot.Name = "__USSI_UniversalMirror"

local mirrorContainers = {}
local mirrorSignatures = {}
local totalMirroredParts = 0

local function getContainerKey(inst)
    if inst:IsA("Model") then
        local pp = inst.PrimaryPart
        if pp then
            local p = pp.Position
            return string.format("M_%s_%.1f_%.1f_%.1f", inst.Name, p.X, p.Y, p.Z)
        end
        return "M_" .. inst.Name
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
        return
    end

    -- Instancia hoja (BasePart u objeto) deduplicada por posición/firma espacial
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
            totalMirroredParts = totalMirroredParts + 1

            -- Asegurar que los hijos viajen con archivable activo
            local okDescs, descs = pcall(function() return clone:GetDescendants() end)
            if okDescs and descs then
                for _, d in ipairs(descs) do
                    pcall(function() d.Archivable = true end)
                end
            end
        end
    end
end

-- ====================================================================
-- RASTREADOR ESPACIAL ADAPTATIVO (Surface & Camera Guided Sweeper)
-- ====================================================================
local function cellKey(cx, cy, cz)
    return string.format("%d,%d,%d", cx, cy, cz)
end

local function getCellCoords(pos)
    local S = CONFIG.CellSize
    local SY = CONFIG.CellSizeY or 60
    return math.floor(pos.X / S), math.floor(pos.Y / SY), math.floor(pos.Z / S)
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

    -- ⚡ Optimización universal para configuraciones de streaming y pools en cliente
    pcall(function()
        local repStorage = game:GetService("ReplicatedStorage")
        local utilities = repStorage:FindFirstChild("Utilities")
        if utilities then
            local kr = utilities:FindFirstChild("KeycapsRendering")
            if kr then
                local cfgMod = kr:FindFirstChild("KeycapStreamConfig")
                if cfgMod then
                    local ok, cfg = pcall(require, cfgMod)
                    if ok and cfg then
                        cfg.ParentBatchSize = 500
                        cfg.LoadFrameBudgetSec = 0.05
                        cfg.MaxInstancesPerChar = 100000
                    end
                end
            end
        end
    end)

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

        local function getSurfacePos(rawPos)
            local rayParams = RaycastParams.new()
            rayParams.FilterType = Enum.RaycastFilterType.Exclude
            local c = lp.Character
            if c then rayParams.FilterDescendantsInstances = { c, mirrorRoot } end
            
            -- Detectar superficie real hacia abajo hasta 250 studs para encontrar piso, terreno o plataformas
            local hit = Workspace:Raycast(rawPos + Vector3.new(0, 5, 0), Vector3.new(0, -250, 0), rayParams)
            if hit then
                return hit.Position + Vector3.new(0, 3.5, 0)
            end
            return rawPos + Vector3.new(0, 3.5, 0)
        end

        local function queueCellIfGeometry(pos)
            local cx, cy, cz = getCellCoords(pos)
            local k = cellKey(cx, cy, cz)
            if not queuedCells[k] and not visitedCells[k] then
                queuedCells[k] = true
                table.insert(queue, { key = k, pos = pos })
            end
        end

        -- Encolar exclusivamente BaseParts reales (evita pivotes fantasma en el cielo)
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

                local targetPos = getSurfacePos(target.pos)

                -- Teletransportar Personaje Y Cámara (activa LOD y streaming basados en cámara)
                pcall(function()
                    local curRoot = getActiveHRP()
                    if curRoot then
                        curRoot.CFrame = CFrame.new(targetPos)
                        curRoot.Anchored = true
                    end
                    local cam = Workspace.CurrentCamera
                    if cam then
                        cam.CFrame = CFrame.new(targetPos + Vector3.new(0, 8, 0))
                    end
                end)

                -- Solicitar streaming en hilo aislado (evita que un cuelgue de Roblox congele el bucle)
                task.spawn(function()
                    pcall(function()
                        lp:RequestStreamAroundAsync(targetPos, 1.5)
                    end)
                end)

                -- Quiescencia de red adaptativa con techo estricto anti-freeze
                local dwellStart = os.clock()
                task.wait(CONFIG.MinWaitPerCell)

                while (os.clock() - lastStreamedTime < CONFIG.QuiescenceTimeout) and (os.clock() - dwellStart < CONFIG.MaxWaitPerCell) do
                    task.wait(0.04)
                end

                -- 🔍 Barrido espacial 3D local nativo: captura cualquier pieza movida o cargada por pools
                pcall(function()
                    local overlap = OverlapParams.new()
                    overlap.FilterType = Enum.RaycastFilterType.Exclude
                    local c = lp.Character
                    if c then overlap.FilterDescendantsInstances = { c, mirrorRoot } end

                    local nearbyParts = Workspace:GetPartBoundsInBox(
                        CFrame.new(targetPos),
                        Vector3.new(CONFIG.CellSize * 1.5, 300, CONFIG.CellSize * 1.5),
                        overlap
                    )
                    if nearbyParts then
                        for _, p in ipairs(nearbyParts) do
                            ingestInstance(p)
                            if p:IsA("BasePart") and not p:IsA("Terrain") then
                                queueCellIfGeometry(p.Position)
                            end
                        end
                    end
                end)

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
    -- MATERIALIZADOR MAESTRO DE POOLS EN MEMORIA (Zero-Loss Keycaps & Obbies)
    -- ================================================================
    pcall(function()
        setHUD("Sincronizando registros completos del pool de renderizado...", false)
        local repStorage = game:GetService("ReplicatedStorage")
        local utilities = repStorage:FindFirstChild("Utilities")
        if utilities then
            local kr = utilities:FindFirstChild("KeycapsRendering")
            if kr then
                local debugStateMod = kr:FindFirstChild("KeycapRenderDebugState")
                if debugStateMod then
                    local ok, debugState = pcall(require, debugStateMod)
                    if ok and debugState and debugState.renderer then
                        local renderer = debugState.renderer
                        local byId = renderer._byId
                        local template = renderer._template
                        local appearances = renderer._surfaceAppearances
                        local keycapsFolder = renderer._folder or Workspace:FindFirstChild("Keycaps")

                        if byId and template and keycapsFolder then
                            local createdCount = 0
                            local yieldStep = 0
                            for id, record in pairs(byId) do
                                yieldStep = yieldStep + 1
                                if yieldStep % 150 == 0 then
                                    task.wait()
                                end

                                local pos = record.Position
                                local char = record.Char
                                local sig = string.format("P_Keycap_%.2f_%.2f_%.2f_%.2f_%.2f_%.2f_MeshPart",
                                    pos.X, pos.Y, pos.Z, record.Size.X, record.Size.Y, record.Size.Z)

                                if not mirrorSignatures[keycapsFolder] or not mirrorSignatures[keycapsFolder][sig] then
                                    local kc = template:Clone()
                                    kc.Name = "Keycap"
                                    kc.Color = record.Color
                                    kc.Size = record.Size
                                    kc.CFrame = record.Rotation + pos
                                    kc.Anchored = true
                                    kc.CanCollide = true

                                    if appearances and char then
                                        local sa = appearances:FindFirstChild(char)
                                        if sa then
                                            local saClone = sa:Clone()
                                            saClone.Parent = kc
                                        end
                                    end

                                    if record.MusicType then
                                        kc:SetAttribute("MusicType", record.MusicType)
                                    end
                                    if record.KeyType then
                                        kc:SetAttribute("Type", record.KeyType)
                                    end

                                    kc.Parent = keycapsFolder
                                    if not mirrorSignatures[keycapsFolder] then
                                        mirrorSignatures[keycapsFolder] = {}
                                    end
                                    mirrorSignatures[keycapsFolder][sig] = kc
                                    createdCount = createdCount + 1
                                end
                            end
                            setHUD(string.format("Pool sincronizado: %d keycaps completados al 100%%", createdCount), false)
                        end
                    end
                end
            end
        end
    end)

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
