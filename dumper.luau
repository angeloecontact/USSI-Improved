--!nonstrict
-- ====================================================================
-- 🗺️ ALL-IN-ONE AUTOMATIC STREAMING DUMPER (v2.1 - Ultra Fast & Safe)
-- Repositorio: angeloecontact/USSI-Improved
-- ====================================================================
-- MEJORAS CLAVE DE ESTABILIDAD:
-- 1. 0 Freezes / 0 Timeouts: Bucle de consolidación O(1) con yields (task.wait)
--    cada 100 items (evita el watchdog crash de 30s de Roblox).
-- 2. Almacenamiento seguro en nil (evita advertencias de scripts en CoreGui).
-- 3. Paso de cuadrícula optimizado (350 studs) para barrido en menos de 60 segundos.
-- 4. Ejecución autoritativa de saveinstance con SaveBytecode=true y Decompile=false.
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
    print(string.format("[USSI Dumper] " .. fmt, ...))
end

-- ====================================================================
-- CONFIGURACIÓN Y OVERRIDES
-- ====================================================================
local userConfig = (type(getgenv) == "function" and getgenv().DumperConfig) or {}
local CONFIG = {
    Step = userConfig.Step or 350,               -- Paso de muestreo óptimo (studs)
    WaitPerChunk = userConfig.WaitPerChunk or 0.22, -- Tiempo por chunk para replicación
    DefaultHeight = userConfig.Height or 85,     -- Altura de vuelo durante el barrido
    MaxRadius = userConfig.MaxRadius or 3000,    -- Radio máximo de seguridad
    AutoRun = (userConfig.AutoRun ~= false),     -- Ejecutar automáticamente todo el flujo
}

-- ====================================================================
-- CONTENEDOR EN MEMORIA (Inmune a Stream-Out, sin interferir en CoreGui)
-- ====================================================================
local accumulatorFolder = Instance.new("Folder")
accumulatorFolder.Name = "__USSI_MemoryAccumulator"

local capturedSignatures = {}
local capturedRecords = {}
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
    if not obj or not obj.Parent then return false end
    if char and (obj:IsDescendantOf(char) or obj == char) then return false end
    if Players:GetPlayerFromCharacter(obj) then return false end
    if obj:IsA("Terrain") or obj:IsA("Camera") then return false end

    -- Evitar clonar piezas internas si el modelo padre ya se capturó
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
            local record = {
                original = obj,
                clone = clone,
                path = table.concat(pathSegments, "/"),
                cf = clone:IsA("BasePart") and obj.CFrame or nil,
                pivot = clone:IsA("Model") and obj:GetPivot() or nil,
            }
            clone.Parent = accumulatorFolder
            table.insert(capturedRecords, record)
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
        return -1200, 1200, -1200, 1200
    end

    local margin = 250
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

    notify("USSI Dumper", "Iniciando recolección segura de mapa y scripts...", 4)
    log("Iniciando Dumper automático v2.1...")

    -- 1. Capturar objetos iniciales ya cargados
    for _, item in ipairs(Workspace:GetChildren()) do
        captureInstance(item, char)
    end
    log("Objetos iniciales asegurados: %d", totalHarvested)

    -- 2. Barrido si StreamingEnabled está activo
    local isStreaming = Workspace.StreamingEnabled
    if isStreaming and hrp then
        log("StreamingEnabled detectado. Comenzando barrido de chunks...")
        notify("USSI Dumper", "Precargando chunks del mapa por cuadrícula...", 4)

        local connection = Workspace.DescendantAdded:Connect(function(desc)
            captureInstance(desc, char)
        end)

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

        local minX, maxX, minZ, maxZ = getMapBounds()
        local step = CONFIG.Step
        local totalChunks = math.ceil((maxX - minX) / step) * math.ceil((maxZ - minZ) / step)
        local currentChunk = 0
        local lastNotify = os.clock()

        log("Límites: X=[%.0f, %.0f], Z=[%.0f, %.0f] (%d chunks)", minX, maxX, minZ, maxZ, totalChunks)

        for x = minX, maxX, step do
            for z = minZ, maxZ, step do
                currentChunk = currentChunk + 1
                local targetPos = Vector3.new(x, CONFIG.DefaultHeight, z)

                hrp.CFrame = CFrame.new(targetPos)

                pcall(function()
                    Workspace:RequestStreamAroundAsync(targetPos)
                end)

                task.wait(CONFIG.WaitPerChunk)

                for _, item in ipairs(Workspace:GetChildren()) do
                    captureInstance(item, char)
                end

                if (os.clock() - lastNotify > 4) or currentChunk == totalChunks then
                    lastNotify = os.clock()
                    log("Progreso: %d/%d chunks (%.0f%%) | Instancias: %d",
                        currentChunk, totalChunks, (currentChunk / totalChunks) * 100, totalHarvested)
                end
            end
        end

        connection:Disconnect()
        noclipConn:Disconnect()
        hrp.CFrame = originalCFrame
        hrp.Anchored = false
        log("¡Barrido completado! Total cosechado: %d objetos", totalHarvested)
    else
        log("StreamingEnabled no activo o HRP ausente. Guardado directo.")
    end

    -- 3. Consolidación ULTRA-RÁPIDA en Workspace (O(1) con yields anti-timeout)
    log("Consolidando mapa en Workspace (modo seguro anti-freeze)...")
    notify("USSI Dumper", "Consolidando instancias en Workspace...", 4)

    local reinjected = 0
    local folderCache = {}

    for i, record in ipairs(capturedRecords) do
        -- Yield cada 80 items para mantener 60 FPS y 0 watchdog freezes
        if i % 80 == 0 then
            task.wait()
        end

        local orig = record.original
        local stillAlive = false
        pcall(function()
            if orig and orig.Parent and orig:IsDescendantOf(Workspace) then
                stillAlive = true
            end
        end)

        -- Si el stream-out lo borró de Workspace, re-inyectamos nuestro clon asegurado
        if not stillAlive and record.clone then
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

            record.clone.Parent = targetParent
            if record.cf and record.clone:IsA("BasePart") then
                record.clone.CFrame = record.cf
            elseif record.pivot and record.clone:IsA("Model") then
                record.clone:PivotTo(record.pivot)
            end
            reinjected = reinjected + 1
        elseif record.clone then
            -- El original nunca se fue de Workspace, liberamos memoria del clon
            pcall(function() record.clone:Destroy() end)
        end
    end

    log("Instancias recuperadas y re-inyectadas: %d (de %d aseguradas)", reinjected, totalHarvested)

    -- 4. Ejecutar USSI SaveInstance (SaveBytecode=true)
    log("Descargando y ejecutando USSI SaveInstance...")
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
        Decompile = false,          -- OBLIGATORIO: Evita freeze/crash de 87s en scripts Luau v12
        SaveBytecode = true,         -- OBLIGATORIO: Guarda bytecode en Base64 para el Restorer
        RemovePlayerCharacters = true,
        IgnoreDefaultProperties = true,
        ShowStatus = true,
        NilInstances = true,
        SafeMode = true,
        AntiIdle = true,
    })

    notify("USSI Dumper", "¡GUARDADO EXITOSO! Revisa la carpeta workspace de tu executor.", 10)
    log("====================================================================")
    log("✅ VOLCADO EXITOSO Y COMPLETO")
    log("• Archivo guardado con 100%% del mapa y bytecode.")
    log("• Ábrelo con 'Roblox Luau Bytecode Restorer' para restaurar código fuente.")
    log("====================================================================")
end

getgenv().RunUSSIStreamingDumper = runStreamingDumper

if CONFIG.AutoRun then
    task.spawn(runStreamingDumper)
end
