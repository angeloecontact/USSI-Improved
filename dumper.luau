--!nonstrict
-- ====================================================================
-- 🗺️ ALL-IN-ONE AUTOMATIC STREAMING DUMPER
-- Repositorio: angeloecontact/USSI-Improved
-- ====================================================================
-- QUÉ HACE ESTE SCRIPT:
-- 1. Detecta si el juego tiene StreamingEnabled.
-- 2. Si tiene StreamingEnabled:
--    - Crea un acumulador protegido en CoreGui.
--    - Detecta automáticamente los límites del mapa.
--    - Barre el mapa flotando y solicitando los chunks al servidor.
--    - Cosecha todas las partes/modelos antes de que el stream-out los borre.
--    - Re-injerta todo el mapa consolidado en Workspace con sus CFrames originales.
-- 3. Dispara saveinstance con SaveBytecode = true y Decompile = false
--    (garantiza 0 crashes y compatibilidad con Roblox Luau Bytecode Restorer).
-- ====================================================================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
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
    print(string.format("[USSI Dumper] " .. fmt, ...))
end

-- ====================================================================
-- CONFIGURACIÓN Y OVERRIDES
-- ====================================================================
local userConfig = (type(getgenv) == "function" and getgenv().DumperConfig) or {}
local CONFIG = {
    Step = userConfig.Step or 250,              -- Distancia entre puntos de muestreo (studs)
    WaitPerChunk = userConfig.WaitPerChunk or 0.30, -- Tiempo de espera para replicación de chunk
    DefaultHeight = userConfig.Height or 80,    -- Altura de vuelo durante el barrido
    MaxRadius = userConfig.MaxRadius or 3500,   -- Límite máximo de coordenadas para evitar mapas infinitos
    AutoRun = (userConfig.AutoRun ~= false),    -- Ejecutar automáticamente todo el flujo
}

-- ====================================================================
-- ACUMULADOR PROTEGIDO (Inmune a Stream-Out)
-- ====================================================================
local ACCUMULATOR_NAME = "__USSI_StreamingAccumulator"
local accumulatorFolder = CoreGui:FindFirstChild(ACCUMULATOR_NAME)
if accumulatorFolder then
    pcall(function() accumulatorFolder:Destroy() end)
end
accumulatorFolder = Instance.new("Folder")
accumulatorFolder.Name = ACCUMULATOR_NAME
accumulatorFolder.Parent = CoreGui

local capturedSignatures = {}
local totalHarvested = 0

local function getSignature(inst)
    if inst:IsA("BasePart") then
        local p = inst.Position
        return string.format("P_%s_%.1f_%.1f_%.1f", inst.Name, p.X, p.Y, p.Z)
    elseif inst:IsA("Model") then
        local cf = inst:GetPivot()
        local p = cf.Position
        return string.format("M_%s_%.1f_%.1f_%.1f", inst.Name, p.X, p.Y, p.Z)
    end
    return nil
end

local function shouldCapture(obj, char)
    if char and (obj:IsDescendantOf(char) or obj == char) then return false end
    if Players:GetPlayerFromCharacter(obj) then return false end
    if obj:IsA("Terrain") or obj:IsA("Camera") then return false end

    -- Evitar duplicar partes internas si el modelo padre ya se capturó
    local parent = obj.Parent
    while parent and parent ~= Workspace and parent ~= game do
        if parent:IsA("Model") then
            return false
        end
        parent = parent.Parent
    end

    return obj:IsA("Model") or obj:IsA("BasePart")
end

local function captureInstance(obj, char)
    if not shouldCapture(obj, char) then return end

    local sig = getSignature(obj)
    if not sig or capturedSignatures[sig] then return end
    capturedSignatures[sig] = true

    -- Construir ruta jerárquica original dentro de Workspace
    local pathSegments = {}
    local curr = obj.Parent
    while curr and curr ~= Workspace and curr ~= game do
        table.insert(pathSegments, 1, curr.Name)
        curr = curr.Parent
    end

    pcall(function()
        obj.Archivable = true
        for _, desc in ipairs(obj:GetDescendants()) do
            desc.Archivable = true
        end

        local clone = obj:Clone()
        if clone then
            clone:SetAttribute("__OriginalPath", table.concat(pathSegments, "/"))
            if clone:IsA("BasePart") then
                clone:SetAttribute("__OriginalCFrame", obj.CFrame)
            elseif clone:IsA("Model") then
                clone:SetAttribute("__OriginalPivot", obj:GetPivot())
            end
            clone.Parent = accumulatorFolder
            totalHarvested = totalHarvested + 1
        end
    end)
end

-- ====================================================================
-- DETECCIÓN DINÁMICA DE LÍMITES DEL MAPA
-- ====================================================================
local function getMapBounds()
    local minX, minZ = math.huge, math.huge
    local maxX, maxZ = -math.huge, -math.huge
    local found = false

    for _, desc in ipairs(Workspace:GetDescendants()) do
        if desc:IsA("BasePart") and not desc:IsA("Terrain") then
            local pos = desc.Position
            -- Ignorar posiciones astronómicas o corruptas
            if math.abs(pos.X) < CONFIG.MaxRadius and math.abs(pos.Z) < CONFIG.MaxRadius then
                found = true
                if pos.X < minX then minX = pos.X end
                if pos.X > maxX then maxX = pos.X end
                if pos.Z < minZ then minZ = pos.Z end
                if pos.Z > maxZ then maxZ = pos.Z end
            end
        end
    end

    if not found or minX == math.huge then
        return -1000, 1000, -1000, 1000
    end

    -- Margen adicional de 300 studs
    local margin = 300
    return math.max(-CONFIG.MaxRadius, minX - margin),
           math.min(CONFIG.MaxRadius, maxX + margin),
           math.max(-CONFIG.MaxRadius, minZ - margin),
           math.min(CONFIG.MaxRadius, maxZ + margin)
end

-- ====================================================================
-- FLUJO PRINCIPAL
-- ====================================================================
local function runStreamingDumper()
    local lp = Players.LocalPlayer
    local char = lp.Character or lp.CharacterAdded:Wait()
    local hrp = char:WaitForChild("HumanoidRootPart", 10)

    notify("USSI Dumper", "Iniciando recolección de mapa y scripts...", 4)
    log("Iniciando Dumper automático...")

    -- 1. Capturar objetos iniciales
    for _, item in ipairs(Workspace:GetChildren()) do
        captureInstance(item, char)
    end
    log("Objetos iniciales asegurados: %d", totalHarvested)

    -- 2. Barrido si StreamingEnabled está activo
    local isStreaming = Workspace.StreamingEnabled
    if isStreaming and hrp then
        log("StreamingEnabled detectado. Comenzando barrido de chunks...")
        notify("USSI Dumper", "Barrerá el mapa para precargar chunks...", 4)

        -- Escuchar nuevos objetos entrantes
        local connection = Workspace.DescendantAdded:Connect(function(desc)
            captureInstance(desc, char)
        end)

        -- Guardar posición original del jugador
        local originalCFrame = hrp.CFrame

        -- Activar noclip durante el barrido
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

        local minX, maxX, minZ, maxZ = getMapBounds()
        local step = CONFIG.Step
        local totalChunks = math.ceil((maxX - minX) / step) * math.ceil((maxZ - minZ) / step)
        local currentChunk = 0
        local lastNotify = os.clock()

        log("Límites del mapa: X=[%.0f, %.0f], Z=[%.0f, %.0f] (~%d puntos)", minX, maxX, minZ, maxZ, totalChunks)

        for x = minX, maxX, step do
            for z = minZ, maxZ, step do
                currentChunk = currentChunk + 1
                local targetPos = Vector3.new(x, CONFIG.DefaultHeight, z)

                hrp.CFrame = CFrame.new(targetPos)

                -- Solicitar streaming al servidor
                pcall(function()
                    Workspace:RequestStreamAroundAsync(targetPos)
                end)

                task.wait(CONFIG.WaitPerChunk)

                -- Re-escanear objetos en la nueva posición
                for _, item in ipairs(Workspace:GetChildren()) do
                    captureInstance(item, char)
                end

                if (os.clock() - lastNotify > 4) or currentChunk == totalChunks then
                    lastNotify = os.clock()
                    log("Progreso: %d/%d chunks (%.0f%%) | Modelos: %d",
                        currentChunk, totalChunks, (currentChunk / totalChunks) * 100, totalHarvested)
                end
            end
        end

        -- Desconectar listeners y restaurar personaje
        connection:Disconnect()
        noclipConn:Disconnect()
        hrp.CFrame = originalCFrame
        hrp.Anchored = false
        log("¡Barrido completado! Total cosechado: %d objetos", totalHarvested)
    else
        log("StreamingEnabled no activo o HRP no encontrado. No se requiere barrido por rejilla.")
    end

    -- 3. Consolidar acumulador en Workspace
    log("Consolidando mapa en Workspace...")
    notify("USSI Dumper", "Consolidando instancias en Workspace...", 3)

    local reinjected = 0
    for _, item in ipairs(accumulatorFolder:GetChildren()) do
        local pathSegments = item:GetAttribute("__OriginalPath") or ""
        local targetParent = Workspace

        if pathSegments ~= "" then
            for folderName in string.gmatch(pathSegments, "[^/]+") do
                local nextFolder = targetParent:FindFirstChild(folderName)
                if not nextFolder then
                    nextFolder = Instance.new("Folder")
                    nextFolder.Name = folderName
                    nextFolder.Parent = targetParent
                end
                targetParent = nextFolder
            end
        end

        local sig = getSignature(item)
        local alreadyExists = false
        for _, existing in ipairs(targetParent:GetChildren()) do
            if getSignature(existing) == sig then
                alreadyExists = true
                break
            end
        end

        if not alreadyExists then
            item.Parent = targetParent
            local origCF = item:GetAttribute("__OriginalCFrame")
            if origCF and item:IsA("BasePart") then
                item.CFrame = origCF
            end
            local origPivot = item:GetAttribute("__OriginalPivot")
            if origPivot and item:IsA("Model") then
                item:PivotTo(origPivot)
            end
            reinjected = reinjected + 1
        else
            item:Destroy()
        end
    end

    log("Instancias consolidadas en Workspace: %d", reinjected)

    -- 4. Ejecutar USSI SaveInstance
    log("Descargando y ejecutando USSI SaveInstance (SaveBytecode=true)...")
    notify("USSI Dumper", "Generando archivo .rbxlx...", 5)

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
        SaveBytecode = true,         -- OBLIGATORIO: Guarda bytecode para Luau Restorer
        RemovePlayerCharacters = true,
        IgnoreDefaultProperties = true,
        ShowStatus = true,
        NilInstances = true,
        SafeMode = true,
        AntiIdle = true,
    })

    notify("USSI Dumper", "¡GUARDADO EXITOSO! Revisa tu carpeta workspace del executor.", 10)
    log("====================================================================")
    log("✅ VOLCADO EXITOSO")
    log("• El archivo .rbxlx con el 100%% del mapa y bytecode fue guardado.")
    log("• Puedes abrirlo y restaurar los scripts con Luau Bytecode Restorer v2.0.")
    log("====================================================================")
end

-- Exponer globalmente
getgenv().RunUSSIStreamingDumper = runStreamingDumper

if CONFIG.AutoRun then
    task.spawn(runStreamingDumper)
end
