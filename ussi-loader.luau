--!nonstrict
--[[
	USSI-Improved · loader endurecido
	angeloecontact/USSI-Improved

	Frente al loader de 3 líneas:
	  · versión fijada a un commit, no a "main"
	  · reintentos + mirrors (raw.githubusercontent / jsDelivr / githack)
	  · caché en disco, invalidada sola al cambiar el commit
	  · valida lo descargado (nunca ejecuta una página de error de GitHub)
	  · pcall en cada capa, con mensajes que dicen qué falló
	  · comprueba los globals del executor que exigen TUS opciones
	  · avisa de opciones mal escritas (el script las ignora en silencio)
	  · candado de reentrada, cronómetro y notificación al terminar
--]]

--============================ CONFIG ============================--

local CONFIG = {
	Owner = "angeloecontact",
	Repo  = "USSI-Improved",
	Path  = "saveinstance.luau",

	-- Commit fijo. Con "main", un push cambia el script bajo tus pies
	-- y un bug entra en producción sin que toques nada.
	Ref = "7168de43c0520a55c6b404d8aae0b06a2be72ff9",

	UseCache  = true,               -- guarda el fuente y reutilízalo
	CacheDir  = "USSI-Improved",
	Attempts  = 3,                  -- rondas; cada ronda prueba todos los mirrors
	RetryWait = 1.5,                -- backoff lineal en segundos
	Verbose   = true,
	Notify    = true,
}

-- true  = perfil máximo: coge todo lo que se puede coger. Más lento,
--         archivo mucho más grande y más riesgo de tumbar el cliente.
-- false = perfil equilibrado, el de siempre.
local MAX_COVERAGE = false

-- Opciones de saveinstance. Lo que no toques usa el default del script.
local OPTIONS = {
	AntiIdle   = true,   -- evita el kick por inactividad en places lentos
	ShowStatus = true,   -- progreso en consola
	SafeMode   = true,   -- más lento, menos crashes

	-- FilePath = "USSI-Improved/mi-place.rbxlx",  -- ruta explícita = sabes dónde quedó
}

if MAX_COVERAGE then
	OPTIONS.mode                       = "full"
	OPTIONS.NilInstances               = true   -- lo reparentado a nil
	OPTIONS.SaveNotCreatable           = true
	OPTIONS.SaveBytecode               = true   -- red de seguridad si falla el decompilador
	OPTIONS.IgnoreNotArchivable        = false  -- incluye Archivable = false
	OPTIONS.IgnoreDefaultProperties    = false
	OPTIONS.IgnoreDefaultPlayerScripts = false
	OPTIONS.DecompileTimeout           = 30
end

--============================ UTILIDADES ============================--

local function log(fmt, ...)
	if CONFIG.Verbose then
		print("[USSI] " .. string.format(fmt, ...))
	end
end

local function fail(fmt, ...)
	warn("[USSI] " .. string.format(fmt, ...))
end

local function sleep(seconds)
	if type(task) == "table" and type(task.wait) == "function" then
		task.wait(seconds)
	else
		wait(seconds)
	end
end

local function notify(title, text)
	if not CONFIG.Notify then return end
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", {
			Title = title,
			Text = text,
			Duration = 8,
		})
	end)
end

-- ¿Existe este global del executor? Sin reventar si el entorno está sandboxeado.
local function has(name)
	local ok, value = pcall(function()
		if type(getgenv) == "function" then
			local v = getgenv()[name]
			if v ~= nil then return v end
		end
		return _G[name]
	end)
	return ok and type(value) == "function"
end

local function globalOf(name)
	local ok, value = pcall(function()
		if type(getgenv) == "function" then
			local v = getgenv()[name]
			if v ~= nil then return v end
		end
		return _G[name]
	end)
	if ok then return value end
	return nil
end

--============================ RED ============================--

-- Muchos executors no traen game:HttpGet fiable; casi todos traen request().
local function resolveRequest()
	local getters = {
		function() return syn.request end,
		function() return http.request end,
		function() return http_request end,
		function() return request end,
		function() return fluxus.request end,
	}
	for _, getter in ipairs(getters) do
		local ok, fn = pcall(getter)
		if ok and type(fn) == "function" then
			return fn
		end
	end
	return nil
end

local function httpGet(url)
	local req = resolveRequest()
	if req then
		local ok, res = pcall(req, { Url = url, Method = "GET" })
		if ok and type(res) == "table" then
			local code = res.StatusCode or res.status_code or 0
			local body = res.Body or res.body
			if code == 200 and type(body) == "string" and #body > 0 then
				return body
			end
			return nil, string.format("HTTP %s", tostring(code))
		end
	end

	-- Fallback. El 2.º argumento de HttpGet no significa lo mismo en todos
	-- los executors, así que no dependemos de él.
	local ok, body = pcall(function()
		return game:HttpGet(url)
	end)
	if ok and type(body) == "string" and #body > 0 then
		return body
	end
	return nil, tostring(body)
end

local function mirrors()
	local o, r, ref, p = CONFIG.Owner, CONFIG.Repo, CONFIG.Ref, CONFIG.Path
	return {
		string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", o, r, ref, p),
		string.format("https://cdn.jsdelivr.net/gh/%s/%s@%s/%s", o, r, ref, p),
		string.format("https://rawcdn.githack.com/%s/%s/%s/%s", o, r, ref, p),
	}
end

-- Un 404 de GitHub es HTML y loadstring lo acepta como "código". Filtrar.
local function looksLikeSource(text)
	if type(text) ~= "string" then return false, "respuesta vacía" end
	if text:match("^%s*<") then return false, "el servidor devolvió HTML" end
	if text:find("404: Not Found", 1, true) then return false, "404 (¿commit o ruta mal?)" end
	if #text < 2048 then return false, string.format("solo %d bytes", #text) end
	return true
end

--============================ CACHÉ ============================--

local function cachePath()
	return string.format("%s/%s-%s.luau", CONFIG.CacheDir, CONFIG.Repo, string.sub(CONFIG.Ref, 1, 12))
end

local function readCache()
	if not (CONFIG.UseCache and has("isfile") and has("readfile")) then return nil end
	local ok, text = pcall(function()
		local path = cachePath()
		if globalOf("isfile")(path) then
			return globalOf("readfile")(path)
		end
		return nil
	end)
	if ok and looksLikeSource(text) then return text end
	return nil
end

local function writeCache(source)
	if not (CONFIG.UseCache and has("writefile")) then return end
	pcall(function()
		if has("isfolder") and has("makefolder") and not globalOf("isfolder")(CONFIG.CacheDir) then
			globalOf("makefolder")(CONFIG.CacheDir)
		end
		globalOf("writefile")(cachePath(), source)
	end)
end

--============================ DESCARGA ============================--

local function fetchSource()
	local cached = readCache()
	if cached then
		log("caché local, %d KB (commit %s)", math.floor(#cached / 1024), string.sub(CONFIG.Ref, 1, 7))
		return cached
	end

	local lastError = "sin intentos"
	for attempt = 1, CONFIG.Attempts do
		for index, url in ipairs(mirrors()) do
			local body, err = httpGet(url)
			if body then
				local valid, why = looksLikeSource(body)
				if valid then
					log("descargado desde el mirror %d, %d KB", index, math.floor(#body / 1024))
					writeCache(body)
					return body
				end
				lastError = why
			else
				lastError = err or "error desconocido"
			end
		end
		if attempt < CONFIG.Attempts then
			log("ronda %d fallida (%s), reintentando…", attempt, lastError)
			sleep(CONFIG.RetryWait * attempt)
		end
	end
	return nil, lastError
end

--============================ OPCIONES ============================--

-- Nombres reales del fork. El script ignora en silencio lo que no reconoce,
-- así que una errata te deja con un guardado sin la opción que creías activa.
local KNOWN_OPTIONS = {
	"mode", "Decompile", "scriptcache", "DecompileTimeout", "__DEBUG_MODE", "Callback",
	"DecompileJobless", "DecompileIgnore", "IgnoreDefaultPlayerScripts", "SaveBytecode",
	"IgnoreProperties", "IgnoreList", "ExtraInstances", "NilInstances", "NilInstancesFixes",
	"SaveCacheInterval", "ShowStatus", "KillAllScripts", "SafeMode", "BoostFPS",
	"ShutdownWhenDone", "AntiIdle", "Anonymous", "ReadMe", "FilePath", "AvoidFileOverwrite",
	"Object", "IsModel", "IgnoreDefaultProperties", "IgnoreNotArchivable",
	"IgnorePropertiesOfNotScriptsOnScriptsMode", "IgnoreSpecialProperties",
	"IsolateLocalPlayer", "IsolateLocalPlayerCharacter", "IsolatePlayers",
	"IsolateStarterPlayer", "SavePlayerCharacters", "SaveNotCreatable", "NotCreatableFixes",
}

-- Globals que exige cada opción, para fallar ANTES y no a medio archivo.
local OPTION_REQUIREMENTS = {
	decompile    = { "getscriptbytecode" },
	savebytecode = { "getscriptbytecode", "base64encode" },
	nilinstances = { "getnilinstances" },
}

local BASE_REQUIREMENTS = { "writefile", "gethiddenproperty" }

local function validateOptions()
	local known = {}
	for _, name in ipairs(KNOWN_OPTIONS) do
		known[string.lower(name)] = name
	end

	local typos = 0
	for key in pairs(OPTIONS) do
		if not known[string.lower(tostring(key))] then
			fail("opción desconocida: %q — el script la ignorará", tostring(key))
			typos = typos + 1
		end
	end
	return typos
end

local function validateEnvironment()
	local missing = {}
	local function check(list)
		for _, name in ipairs(list) do
			if not has(name) then
				missing[#missing + 1] = name
			end
		end
	end

	check(BASE_REQUIREMENTS)
	for key, value in pairs(OPTIONS) do
		local needs = OPTION_REQUIREMENTS[string.lower(tostring(key))]
		if needs and value then
			check(needs)
		end
	end

	if #missing > 0 then
		return false, table.concat(missing, ", ")
	end
	return true
end

--============================ MAIN ============================--

local function main()
	local genv = (type(getgenv) == "function" and getgenv()) or _G

	if genv.__USSI_RUNNING then
		fail("ya hay un guardado en curso; esta ejecución se aborta")
		return
	end

	local okEnv, missing = validateEnvironment()
	if not okEnv then
		fail("tu executor no expone: %s — aborto antes de escribir nada", missing)
		notify("USSI-Improved", "Executor incompatible: " .. missing)
		return
	end

	validateOptions()

	local source, downloadError = fetchSource()
	if not source then
		fail("no se pudo obtener el script: %s", tostring(downloadError))
		notify("USSI-Improved", "Descarga fallida: " .. tostring(downloadError))
		return
	end

	local chunk, compileError = loadstring(source, "@USSI-Improved/saveinstance.luau")
	if not chunk then
		fail("el script no compila: %s", tostring(compileError))
		if has("delfile") then
			pcall(globalOf("delfile"), cachePath()) -- caché corrupta, fuera
		end
		return
	end

	local okInit, saveinstance = pcall(chunk)
	if not okInit or type(saveinstance) ~= "function" then
		fail("el módulo no devolvió una función: %s", tostring(saveinstance))
		return
	end

	-- Si map-prefetch.luau corrió antes, hereda lo que recogió del streaming.
	if OPTIONS.ExtraInstances == nil then
		local collected = genv.USSI_ExtraInstances
		if type(collected) == "table" and #collected > 0 then
			OPTIONS.ExtraInstances = collected
			log("heredando %d contenedor(es) del prefetch", #collected)
		end
	end

	genv.__USSI_RUNNING = true
	log("guardando… (mode=%s, perfil=%s)", tostring(OPTIONS.mode or "default"),
		MAX_COVERAGE and "máximo" or "equilibrado")

	local startedAt = os.clock()
	local okRun, result = pcall(saveinstance, OPTIONS)
	local elapsed = os.clock() - startedAt

	genv.__USSI_RUNNING = false

	if not okRun then
		fail("saveinstance falló tras %.1f s: %s", elapsed, tostring(result))
		notify("USSI-Improved", "Error: " .. tostring(result))
		return
	end

	local where = OPTIONS.FilePath or "la carpeta workspace del executor"
	log("listo en %.1f s → %s", elapsed, where)
	notify("USSI-Improved", string.format("Guardado en %.1f s", elapsed))
	return result
end

return main()
