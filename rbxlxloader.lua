-- rbxlx loader
-- Version para archivos de LUGAR (.rbxlx) basada en el rbxmx loader.
-- Un .rbxlx es XML igual que un .rbxmx, pero la raiz NO es un modelo: son los
-- SERVICIOS (Workspace, Lighting, ReplicatedStorage, ServerScriptService...).
-- Este loader mete el contenido de cada servicio dentro del servicio REAL del juego.
-- Cosas que no funcionan: unions (igual que antes), terrain (voxels) y atributos binarios.

--update logs

-- 2025-11-23 - fixed udim
-- 2025-12-15 - fixed ref resolution for Part0/Part1 and other instance references
-- 2026-10-11 - rbxmx loader: more property types, safe error handling, loader options (Parent / NoScripts), URL input
-- 2026-10-11 - rbxlx loader: servicios reales, Terrain/Camera existentes, cache de MeshParts, Tags, entidades XML,
--              colores con alpha arreglados, resumen de errores en vez de spam, opciones Isolate/Services/SkipServices/ClearServices

local HttpService = game:GetService("HttpService")
local InsertService = game:GetService("InsertService")
local CollectionService = game:GetService("CollectionService")
local WorkspaceService = game:GetService("Workspace")
local unpack_ = table.unpack or unpack

local propertyMap = {
	["size"] = "Size",
	["shape"] = "Shape",
	["Color3uint8"] = "Color",
	["MaterialVariantSerialized"] = "MaterialVariant",
	["Part0Internal"] = "Part0",
	["Part1Internal"] = "Part1",
	["WorldPivotData"] = "WorldPivot",
}

-- propiedades que se ignoran en silencio (no se pueden o ya se manejan aparte)
local ignoredProps = {
	["formFactorRaw"] = true,
	["AttributesSerialize"] = true,
	["Capabilities"] = true,
	["DefinesCapabilities"] = true,
	["SecurityCapabilities"] = true,
	["SourceAssetId"] = true,
	["Tags"] = true, -- se maneja aparte (CollectionService)
	["RunContext"] = true, -- se maneja al crear el script
	["ScriptGuid"] = true,
	["Source"] = true, -- se maneja al crear el script
	["LinkedSource"] = true,
	["UniqueId"] = true,
	["HistoryId"] = true,
	["LocalizationMatchIdentifier"] = true,
	["LocalizationMatchedSourceText"] = true,
	["MetalnessMap"] = true,
	["NormalMap"] = true,
	["RoughnessMap"] = true,
	["TexturePack"] = true,
	["TexturePackMetadata"] = true,
	["SmoothGrid"] = true, -- voxels del terrain (binario)
	["PhysicsGrid"] = true,
	["MaterialColors"] = true,
}

-- tipos que se leen pero no tienen equivalente util (sin warn)
local silentTypes = {
	SharedString = true,
	UniqueId = true,
}

local newx = require(123068958552495)

local function newlocalscript(source,parent)
	return newx({
		source = source,
		parent = parent,
		type = "LocalScript",
	})
end

local function newclientruncontext(source,parent)
	return newx({
		source = source,
		parent = parent,
		type = "Script",
		runcontext = Enum.RunContext.Client
	})
end

local function newscript(source,parent)
	return newx({
		source = source,
		parent = parent,
		type = "Script"
	})
end

local function newmodulescript(source,parent)
	return newx({
		source = source,
		parent = parent,
		type = "ModuleScript"
	})
end

-- ====================================================================
-- XML
-- ====================================================================

local function decodeEntities(s)
	if not s:find("&", 1, true) then return s end
	s = s:gsub("&#[xX](%x+);", function(h)
		local n = tonumber(h, 16)
		if not n then return nil end
		local ok, c = pcall(utf8.char, n)
		return ok and c or nil
	end)
	s = s:gsub("&#(%d+);", function(d)
		local n = tonumber(d)
		if not n then return nil end
		local ok, c = pcall(utf8.char, n)
		return ok and c or nil
	end)
	s = s:gsub("&lt;", "<")
	s = s:gsub("&gt;", ">")
	s = s:gsub("&quot;", '"')
	s = s:gsub("&apos;", "'")
	s = s:gsub("&amp;", "&")
	return s
end

local function parseXML(xml)
	local tree = {children = {}}
	local stack = {tree}
	local top = stack[#stack]
	local i = 1
	while i <= #xml do
		if xml:sub(i, i) == '<' then
			i = i + 1
			local c = xml:sub(i, i)
			if c == '/' then
				i = i + 1
				local tagEnd = xml:find(">", i, true)
				if not tagEnd then
					warn("Malformed XML: Unclosed end tag at position " .. i)
					break
				end
				i = tagEnd + 1
				if #stack > 1 then
					table.remove(stack)
					top = stack[#stack]
				else
					warn("Malformed XML: Extra closing tag at position " .. i)
				end
			elseif c == '?' then
				-- <?xml version="1.0"?>
				local pEnd = xml:find("?>", i, true)
				if not pEnd then break end
				i = pEnd + 2
			elseif xml:sub(i, i+7) == '![CDATA[' then
				i = i + 8
				local cdataEnd = xml:find("]]>", i, true)
				if not cdataEnd then
					warn("Malformed XML: Unclosed CDATA at position " .. i)
					break
				end
				local text = xml:sub(i, cdataEnd - 1)
				table.insert(top.children, {text = text})
				i = cdataEnd + 3
			elseif xml:sub(i, i+2) == '!--' then
				i = i + 3
				local commentEnd = xml:find("-->", i, true)
				if not commentEnd then
					warn("Malformed XML: Unclosed comment at position " .. i)
					break
				end
				i = commentEnd + 3
			elseif c == '!' then
				-- <!DOCTYPE ...>
				local dEnd = xml:find(">", i, true)
				if not dEnd then break end
				i = dEnd + 1
			else
				local tagEnd = xml:find(">", i, true)
				if not tagEnd then
					warn("Malformed XML: No closing '>' for tag at position " .. i)
					break
				end
				local tagStr = xml:sub(i, tagEnd - 1)
				i = tagEnd + 1
				local tag = tagStr:match("^([^%s/]+)")
				if not tag then
					warn("Malformed XML: Invalid tag name at position " .. i)
					break
				end
				local attrs = {}
				for k, v in tagStr:gmatch('(%S+)=%s*"([^"]*)"') do
					attrs[k] = decodeEntities(v)
				end
				local new = {tag = tag, attrs = attrs, children = {}}
				table.insert(top.children, new)
				if xml:sub(tagEnd - 1, tagEnd - 1) ~= '/' then
					table.insert(stack, new)
					top = new
				end
			end
		else
			local textEnd = xml:find("<", i, true) or (#xml + 1)
			local text = xml:sub(i, textEnd - 1):gsub("^%s*(.-)%s*$", "%1")
			if text ~= "" then
				table.insert(top.children, {text = decodeEntities(text)})
			end
			i = textEnd
		end
	end
	if #stack > 1 then
		warn("Malformed XML: Unclosed tags remain")
	end
	return tree
end

local function getTagNode(name, node)
	for _, c in ipairs(node.children) do
		if c.tag == name then
			return c
		end
	end
	return nil
end

-- ====================================================================
-- Propiedades
-- ====================================================================

-- estadisticas de la carga actual (se reinician en cada carga)
local stats = {failed = {}, unsupported = {}, unresolved = 0}

local function tn(s)
	if s == nil then return nil end
	local n = tonumber(s)
	if n then return n end
	local u = tostring(s):upper()
	if u == "INF" then return math.huge end
	if u == "-INF" then return -math.huge end
	if u == "NAN" or u == "-NAN" then return 0/0 end
	return nil
end

local function textOf(node, tag)
	local n = getTagNode(tag, node)
	return n and n.children[1] and n.children[1].text or nil
end

-- lee varias etiquetas numericas (<X>, <Y>, ...) de un nodo; si falta alguna usa 0
local function vecComponents(node, ...)
	local out = {}
	for i, tag in ipairs({...}) do
		out[i] = (node and tn(textOf(node, tag))) or 0
	end
	return unpack_(out)
end

local function numbersOf(node)
	local text = node.children[1] and node.children[1].text or ""
	local nums = {}
	for num in text:gmatch("%S+") do
		table.insert(nums, tn(num) or 0)
	end
	return nums
end

-- un uint32 tipo 0xAARRGGBB (o 0xRRGGBB) -> Color3
local function colorFromUint(u)
	local r = bit32.band(bit32.rshift(u, 16), 255)
	local g = bit32.band(bit32.rshift(u, 8), 255)
	local b = bit32.band(u, 255)
	return Color3.new(r / 255, g / 255, b / 255)
end

local function parseCFrameNode(node)
	return CFrame.new(
		tn(textOf(node, "X")), tn(textOf(node, "Y")), tn(textOf(node, "Z")),
		tn(textOf(node, "R00")), tn(textOf(node, "R01")), tn(textOf(node, "R02")),
		tn(textOf(node, "R10")), tn(textOf(node, "R11")), tn(textOf(node, "R12")),
		tn(textOf(node, "R20")), tn(textOf(node, "R21")), tn(textOf(node, "R22"))
	)
end

local fontWeightMap = {
	["100"] = Enum.FontWeight.Thin,
	["200"] = Enum.FontWeight.ExtraLight,
	["300"] = Enum.FontWeight.Light,
	["400"] = Enum.FontWeight.Regular,
	["500"] = Enum.FontWeight.Medium,
	["600"] = Enum.FontWeight.SemiBold,
	["700"] = Enum.FontWeight.Bold,
	["800"] = Enum.FontWeight.ExtraBold,
	["900"] = Enum.FontWeight.Heavy,
	["Thin"] = Enum.FontWeight.Thin,
	["ExtraLight"] = Enum.FontWeight.ExtraLight,
	["Light"] = Enum.FontWeight.Light,
	["Regular"] = Enum.FontWeight.Regular,
	["Medium"] = Enum.FontWeight.Medium,
	["SemiBold"] = Enum.FontWeight.SemiBold,
	["Bold"] = Enum.FontWeight.Bold,
	["ExtraBold"] = Enum.FontWeight.ExtraBold,
	["Heavy"] = Enum.FontWeight.Heavy,
}

local function parsePropertyRaw(ptype, pnode)
	local children = pnode.children

	local function getText(tagName, parent)
		return textOf(parent or pnode, tagName)
	end

	if ptype == "string" or ptype == "BinaryString" or ptype == "ProtectedString" then
		return children[1] and children[1].text or ""
	elseif ptype == "Content" then
		if #children == 0 then return "" end
		local sub = children[1]
		if sub.tag == "null" then
			return ""
		elseif sub.tag == "url" or sub.tag == "uri" then
			return sub.children[1] and sub.children[1].text or ""
		elseif sub.text then
			return sub.text
		end
		return ""
	elseif ptype == "bool" then
		return (children[1].text == "true")
	elseif ptype == "float" or ptype == "double" or ptype == "int" or ptype == "int64" then
		return tn(children[1].text)
	elseif ptype == "token" then
		return tn(children[1].text)
	elseif ptype == "BrickColor" then
		return BrickColor.new(tn(children[1].text))
	elseif ptype == "Ref" then
		return children[1] and children[1].text or "null"
	elseif ptype == "Vector3" then
		return Vector3.new(tn(getText("X")), tn(getText("Y")), tn(getText("Z")))
	elseif ptype == "Vector2" then
		return Vector2.new(tn(getText("X")), tn(getText("Y")))
	elseif ptype == "CoordinateFrame" or ptype == "CFrame" then
		return parseCFrameNode(pnode)
	elseif ptype == "OptionalCoordinateFrame" then
		local inner = getTagNode("CFrame", pnode) or getTagNode("CoordinateFrame", pnode)
		if inner then return parseCFrameNode(inner) end
		return nil
	elseif ptype == "Color3" then
		local r = getText("R")
		if r then
			return Color3.new(tn(r), tn(getText("G")), tn(getText("B")))
		else
			local uint = getText("uint")
			if uint then
				return colorFromUint(tn(uint))
			end
		end
		if children[1] and children[1].text then
			local u = tn(children[1].text)
			if u then return colorFromUint(u) end
		end
		return Color3.new(1, 1, 1)
	elseif ptype == "Color3uint8" then
		return colorFromUint(tn(children[1].text))
	elseif ptype == "UDim" then
		local s = tn(getText("S"))
		local o = tn(getText("O"))
		return UDim.new(s or 0, o or 0)
	elseif ptype == "UDim2" then
		local xs = tn(getText("XS"))
		local xo = tn(getText("XO"))
		local ys = tn(getText("YS"))
		local yo = tn(getText("YO"))
		return UDim2.new(xs or 0, xo or 0, ys or 0, yo or 0)
	elseif ptype == "PhysicalProperties" then
		local cp = getTagNode("CustomPhysics", pnode)
		if cp and cp.children[1] and cp.children[1].text == "false" then
			return nil
		else
			local d = tn(getText("Density"))
			local f = tn(getText("Friction"))
			local e = tn(getText("Elasticity"))
			local fw = tn(getText("FrictionWeight"))
			local ew = tn(getText("ElasticityWeight"))
			return PhysicalProperties.new(d, f, e, fw, ew)
		end
	elseif ptype == "Font" then
		local family
		local famNode = getTagNode("Family", pnode)
		if famNode then
			local u = getTagNode("url", famNode) or getTagNode("uri", famNode)
			family = (u and u.children[1] and u.children[1].text)
				or (famNode.children[1] and famNode.children[1].text)
		end
		family = family or "rbxasset://fonts/families/SourceSansPro.json"

		local weight = fontWeightMap[tostring(getText("Weight"))] or Enum.FontWeight.Regular
		local okStyle, style = pcall(function() return Enum.FontStyle[tostring(getText("Style"))] end)
		if not okStyle or not style then style = Enum.FontStyle.Normal end

		return Font.new(family, weight, style)
	elseif ptype == "ColorSequence" then
		local keypoints = {}

		for _, kpNode in ipairs(pnode.children) do
			if kpNode.tag == "Keypoint" then
				local time = tn(getText("Time", kpNode)) or 0
				local r = tn(getText("R", kpNode)) or 1
				local g = tn(getText("G", kpNode)) or 1
				local b = tn(getText("B", kpNode)) or 1
				table.insert(keypoints, ColorSequenceKeypoint.new(time, Color3.new(r, g, b)))
			end
		end

		if #keypoints == 0 then
			-- formato de texto: time r g b alpha (5 numeros por keypoint)
			local nums = numbersOf(pnode)
			for i = 1, #nums, 5 do
				if i + 3 <= #nums then
					table.insert(keypoints, ColorSequenceKeypoint.new(nums[i], Color3.new(nums[i+1], nums[i+2], nums[i+3])))
				else
					break
				end
			end
		end

		-- una secuencia necesita minimo 2 keypoints; si el dato esta roto se deja el valor por defecto
		if #keypoints < 2 then return nil end
		return ColorSequence.new(keypoints)
	elseif ptype == "NumberSequence" then
		local keypoints = {}

		for _, kpNode in ipairs(pnode.children) do
			if kpNode.tag == "Keypoint" then
				local time = tn(getText("Time", kpNode)) or 0
				local value = tn(getText("Value", kpNode)) or 0
				local envelope = tn(getText("Envelope", kpNode)) or 0
				table.insert(keypoints, NumberSequenceKeypoint.new(time, value, envelope))
			end
		end

		if #keypoints == 0 then
			-- formato de texto: time value envelope (3 numeros por keypoint)
			local nums = numbersOf(pnode)
			for i = 1, #nums, 3 do
				if i + 1 <= #nums then
					table.insert(keypoints, NumberSequenceKeypoint.new(nums[i], nums[i+1], nums[i+2] or 0))
				else
					break
				end
			end
		end

		if #keypoints < 2 then return nil end
		return NumberSequence.new(keypoints)
	elseif ptype == "NumberRange" then
		local minv = tn(getText("min"))
		local maxv = tn(getText("max"))
		if minv ~= nil and maxv ~= nil then
			return NumberRange.new(minv, maxv)
		end

		local nums = numbersOf(pnode)
		if #nums >= 2 then
			return NumberRange.new(nums[1], nums[2])
		elseif #nums == 1 then
			return NumberRange.new(nums[1], nums[1])
		end
		return NumberRange.new(0, 0)
	elseif ptype == "Vector3int16" then
		return Vector3int16.new(vecComponents(pnode, "X", "Y", "Z"))
	elseif ptype == "Vector2int16" then
		return Vector2int16.new(vecComponents(pnode, "X", "Y"))
	elseif ptype == "Rect2D" then
		local x0, y0 = vecComponents(getTagNode("min", pnode), "X", "Y")
		local x1, y1 = vecComponents(getTagNode("max", pnode), "X", "Y")
		return Rect.new(x0, y0, x1, y1)
	elseif ptype == "Ray" then
		local o = Vector3.new(vecComponents(getTagNode("origin", pnode), "X", "Y", "Z"))
		local d = Vector3.new(vecComponents(getTagNode("direction", pnode), "X", "Y", "Z"))
		return Ray.new(o, d)
	elseif ptype == "Faces" then
		local bits = tn(textOf(pnode, "faces")) or 0
		local list = {}
		for i, face in ipairs({"Right", "Top", "Back", "Left", "Bottom", "Front"}) do
			if bit32.band(bits, bit32.lshift(1, i - 1)) ~= 0 then
				table.insert(list, Enum.NormalId[face])
			end
		end
		return Faces.new(unpack_(list))
	elseif ptype == "Axes" then
		local bits = tn(textOf(pnode, "axes")) or 0
		local list = {}
		for i, axis in ipairs({"X", "Y", "Z"}) do
			if bit32.band(bits, bit32.lshift(1, i - 1)) ~= 0 then
				table.insert(list, Enum.Axis[axis])
			end
		end
		return Axes.new(unpack_(list))
	end

	if not silentTypes[ptype] and not stats.unsupported[ptype] then
		stats.unsupported[ptype] = true
		warn("[RBXLX] Tipo de propiedad no soportado (se ignora): " .. tostring(ptype))
	end
	return nil
end

-- una propiedad rota no debe detener la carga de todo el archivo
local function parseProperty(ptype, pnode)
	local ok, result = pcall(parsePropertyRaw, ptype, pnode)
	if not ok then
		local key = "parse:" .. tostring(ptype)
		stats.failed[key] = (stats.failed[key] or 0) + 1
		return nil
	end
	return result
end

local function findPropNode(node, name)
	local propNode = getTagNode("Properties", node)
	if not propNode then return nil end
	for _, p in ipairs(propNode.children) do
		if p.attrs and p.attrs.name == name then
			return p
		end
	end
	return nil
end

local function getPropValue(node, name)
	local p = findPropNode(node, name)
	if p then return parseProperty(p.tag, p) end
	return nil
end

local function nonEmpty(value)
	if value and value ~= "" and value ~= "null" then return value end
	return nil
end

-- ---------- base64 (para Tags) ----------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64lookup = {}
for i = 1, #B64 do
	b64lookup[B64:byte(i)] = i - 1
end

local function base64decode(data)
	local out, buffer, bits = {}, 0, 0
	for i = 1, #data do
		local v = b64lookup[data:byte(i)]
		if v then
			buffer = buffer * 64 + v
			bits = bits + 6
			if bits >= 8 then
				bits = bits - 8
				local divisor = 2 ^ bits
				out[#out + 1] = string.char(math.floor(buffer / divisor))
				buffer = buffer % divisor
			end
		end
	end
	return table.concat(out)
end

-- ---------- scripts deshabilitados (opcion NoScripts) ----------

local function disabledPlaceholder(className)
	local inst = Instance.new(className)
	pcall(function() inst.Enabled = false end)
	pcall(function() inst.Disabled = true end)
	return inst
end

local function enumFromValue(enumType, value, default)
	if value then
		local ok, item = pcall(function() return enumType:FromValue(value) end)
		if ok and item then return item end
	end
	return default
end

-- ====================================================================
-- Cargador
-- ====================================================================

local function loadPlace(xmlString, debug, waitInterval, options)
	waitInterval = waitInterval or 10000
	options = options or {}

	stats = {failed = {}, unsupported = {}, unresolved = 0}

	local tree = parseXML(xmlString)
	local root = getTagNode("roblox", tree) or tree.children[1]
	if not root then error("el archivo no tiene una raiz <roblox>") end

	local refs = {}
	local pendingRefs = {} -- { {instancia, propiedad, referent}, ... }
	local toParent = {}    -- { {instancia, padre}, ... } (se parentea al final)
	local roots = {}
	local instanceCount = 0
	local meshCache = {}

	local isolate = options.Isolate == true
	local noScripts = options.NoScripts == true
	local applyServiceProps = options.ApplyProperties ~= false

	local function allowed(class)
		if options.Services then
			local ok = false
			for _, name in ipairs(options.Services) do
				if name == class then ok = true break end
			end
			if not ok then return false end
		end
		if options.SkipServices then
			for _, name in ipairs(options.SkipServices) do
				if name == class then return false end
			end
		end
		return true
	end

	local function noteFailed(class, name, err)
		local key = tostring(class) .. "." .. tostring(name)
		stats.failed[key] = (stats.failed[key] or 0) + 1
		if debug then
			warn("[RBXLX] No se pudo asignar " .. key .. ": " .. tostring(err))
		end
	end

	-- crea (o reutiliza) la instancia de un <Item>
	local function build(node, parentInst)
		local class = node.attrs.class
		local ref = node.attrs.referent
		if not class then return nil end

		-- la camara del lugar no se importa: se usa la que ya existe
		if class == "Camera" and parentInst == WorkspaceService then
			if ref then refs[ref] = WorkspaceService.CurrentCamera or false end
			return nil
		end

		local inst

		if class == "Script" or class == "LocalScript" or class == "ModuleScript" then
			if noScripts then
				inst = disabledPlaceholder(class)
			else
				local source = getPropValue(node, "Source") or ""
				local ok, res = pcall(function()
					if class == "Script" then
						local rc = findPropNode(node, "RunContext")
						local rcValue = rc and rc.children[1] and tn(rc.children[1].text)
						if rcValue == Enum.RunContext.Client.Value then
							return newclientruncontext(source)
						end
						return newscript(source)
					elseif class == "LocalScript" then
						return newlocalscript(source)
					end
					return newmodulescript(source)
				end)
				if ok and res then
					inst = res
				else
					warn("[RBXLX] No se pudo crear el " .. class .. ": " .. tostring(res))
					inst = disabledPlaceholder(class)
				end
			end
		elseif class == "MeshPart" then
			local meshId = nonEmpty(getPropValue(node, "MeshId"))
			if not meshId then
				if debug then warn("[RBXLX] MeshPart sin MeshId valido: " .. tostring(ref)) end
				inst = Instance.new("MeshPart")
			else
				local collision = enumFromValue(Enum.CollisionFidelity, getPropValue(node, "CollisionFidelity"), Enum.CollisionFidelity.Default)
				local render = enumFromValue(Enum.RenderFidelity, getPropValue(node, "RenderFidelity"), Enum.RenderFidelity.Automatic)
				local key = meshId .. "|" .. collision.Name .. "|" .. render.Name
				local ok, err = pcall(function()
					local template = meshCache[key]
					if not template then
						template = InsertService:CreateMeshPartAsync(meshId, collision, render)
						meshCache[key] = template
					end
					inst = template:Clone()
					local textureId = nonEmpty(getPropValue(node, "TextureID"))
					if textureId then
						inst.TextureID = textureId
					end
				end)
				if not ok then
					warn("Error making meshpart: " .. tostring(err))
					inst = Instance.new("MeshPart")
				end
			end
		else
			local ok, res = pcall(Instance.new, class)
			if ok then
				inst = res
			else
				-- clases que no se pueden crear (Terrain, StarterPlayerScripts...): usar la que ya existe
				if parentInst then
					local okFind, existing = pcall(function() return parentInst:FindFirstChildOfClass(class) end)
					if okFind and existing then
						inst = existing
					end
				end
				if not inst then
					if class == "Terrain" then return nil end
					if debug then warn("[RBXLX] Clase no creable, se usa un Folder: " .. class) end
					inst = Instance.new("Folder")
					inst.Name = class
				end
			end
		end

		if debug then
			print("[RBXLX] Created instance: " .. class .. " (ref: " .. (ref or "no-ref") .. ")")
		end
		return inst
	end

	local function applyProperties(inst, node, class)
		local propNode = getTagNode("Properties", node)
		if not propNode then return end
		for _, p in ipairs(propNode.children) do
			local ptype = p.tag
			local pname = p.attrs and p.attrs.name
			if ptype and pname then
				if pname == "Tags" then
					local decoded = base64decode(p.children[1] and p.children[1].text or "")
					for _, tag in ipairs(string.split(decoded, "\0")) do
						if tag ~= "" then
							pcall(function() CollectionService:AddTag(inst, tag) end)
						end
					end
				elseif not ignoredProps[pname] then
					local realName = propertyMap[pname] or (pname:gsub("^%l", string.upper))
					local value = parseProperty(ptype, p)
					if value ~= nil then
						if ptype == "Ref" then
							if value ~= "null" then
								table.insert(pendingRefs, {inst, realName, value})
							end
						else
							local ok, err = pcall(function() inst[realName] = value end)
							if not ok then
								noteFailed(class, realName, err)
							end
						end
					end
				end
			end
		end
	end

	local function create(node, parentInst)
		if node.tag ~= "Item" then return nil end
		local class = node.attrs.class
		local inst = build(node, parentInst)
		if not inst then return nil end

		local ref = node.attrs.referent
		if ref then refs[ref] = inst end

		applyProperties(inst, node, class)

		for _, child in ipairs(node.children) do
			if child.tag == "Item" then
				local childInst = create(child, inst)
				if childInst and childInst.Parent ~= inst then
					pcall(function() childInst.Parent = inst end)
				end
			end
		end

		instanceCount = instanceCount + 1
		if waitInterval and instanceCount % waitInterval == 0 then
			task.wait()
		end

		return inst
	end

	local function clearService(service)
		for _, child in ipairs(service:GetChildren()) do
			local keep = child:IsA("Terrain") or child:IsA("Camera")
				or child:IsA("StarterPlayerScripts") or child:IsA("StarterCharacterScripts")
				or child:IsA("Player")
				or script:IsDescendantOf(child) -- nunca borrar el propio loader
			if not keep then
				pcall(function() child:Destroy() end)
			end
		end
	end

	-- un <Item> de primer nivel: servicio (rbxlx) o instancia normal (por si te pasan un rbxmx)
	local function loadTopLevel(node)
		if node.tag ~= "Item" then return end
		local class = node.attrs.class
		local ref = node.attrs.referent

		-- algunos exportadores meten todo dentro de un DataModel
		if class == "DataModel" then
			for _, child in ipairs(node.children) do
				loadTopLevel(child)
			end
			return
		end

		local okService, service = pcall(game.GetService, game, class)
		if okService and typeof(service) == "Instance" then
			if not allowed(class) then
				if debug then print("[RBXLX] Servicio omitido: " .. class) end
				return
			end

			local target = service
			if isolate then
				target = Instance.new("Folder")
				target.Name = class
				if options.Parent then
					table.insert(toParent, {target, options.Parent})
				end
			else
				if options.ClearServices then
					clearService(service)
				end
			end

			if ref then refs[ref] = target end
			if applyServiceProps and not isolate then
				applyProperties(service, node, class)
			end

			for _, child in ipairs(node.children) do
				if child.tag == "Item" then
					local childInst = create(child, target)
					if childInst and childInst.Parent ~= target then
						table.insert(toParent, {childInst, target})
					end
				end
			end

			table.insert(roots, target)
		else
			local inst = create(node, nil)
			if inst then
				table.insert(toParent, {inst, options.Parent or WorkspaceService})
				table.insert(roots, inst)
			end
		end
	end

	for _, node in ipairs(root.children) do
		loadTopLevel(node)
	end

	-- referencias (Part0/Part1, PrimaryPart, ObjectValue, etc.)
	for _, entry in ipairs(pendingRefs) do
		local inst, propName, rbxId = entry[1], entry[2], entry[3]
		local target = refs[rbxId]
		if target then
			pcall(function() inst[propName] = target end)
		elseif target == nil then
			stats.unresolved = stats.unresolved + 1
			if debug then
				warn("Unresolved ref '" .. tostring(rbxId) .. "' for " .. propName .. " on " .. inst.Name)
			end
		end
	end

	-- se parentea al final: asi los scripts arrancan con todo ya armado
	for index, entry in ipairs(toParent) do
		pcall(function() entry[1].Parent = entry[2] end)
		if waitInterval and index % waitInterval == 0 then
			task.wait()
		end
	end

	-- resumen (en vez de un warn por cada propiedad que no se pudo asignar)
	if not debug then
		local total = 0
		for _, count in pairs(stats.failed) do total = total + count end
		if total > 0 or stats.unresolved > 0 then
			print(("[RBXLX] %d propiedad(es) no se pudieron asignar y %d referencia(s) no se resolvieron "
				.. "(es normal: muchas propiedades de lugares no son editables por script). "
				.. "Usa debug = true para ver el detalle."):format(total, stats.unresolved))
		end
	end

	return roots, instanceCount
end

-- ====================================================================
-- API publica
-- ====================================================================
-- rbxlxToInstance(xml, debug, waitInterval, options)
--
--   xml          texto del .rbxlx (XML) o un link directo (https://...)
--   debug        true para ver cada instancia creada y cada error
--   waitInterval cada cuantas instancias hace task.wait() (default 10000)
--   options (opcional):
--     Isolate       true  -> NO toca el juego: crea un Folder por servicio (Workspace, Lighting...)
--     Parent        con Isolate, donde poner esos Folders
--     Services      {"Workspace","ServerStorage"}  solo cargar estos servicios
--     SkipServices  {"Lighting","Players"}         no cargar estos servicios
--     ClearServices true  -> borra el contenido actual de cada servicio antes de cargar (cuidado)
--     ApplyProperties false -> no aplica las propiedades de los servicios (Lighting, Workspace...)
--     NoScripts     true  -> los scripts se crean vacios y desactivados
--
-- Devuelve la lista de servicios (o Folders si usas Isolate) y la cantidad de instancias creadas.

local rbxlxToInstance = function(source, debug, waitInterval, options)
	if type(source) ~= "string" then
		error("[RBXLX] se esperaba el texto del .rbxlx (string), no " .. type(source), 2)
	end

	if source:match("^%s*https?://") then
		local okGet, body = pcall(function()
			return HttpService:GetAsync(source)
		end)
		if not okGet then
			error("[RBXLX] no se pudo descargar el archivo: " .. tostring(body), 2)
		end
		source = body
	end

	if source:sub(1, 8) == "<roblox!" then
		error("[RBXLX] este archivo es un .rbxl binario; guardalo como .rbxlx (XML)", 2)
	end
	if not source:find("<roblox", 1, true) then
		error("[RBXLX] el contenido no parece un .rbxlx valido", 2)
	end

	local ok, result, count = pcall(loadPlace, source, debug, waitInterval, options)
	if not ok then
		error("[RBXLX] fallo al convertir el archivo: " .. tostring(result), 2)
	end

	if debug then
		print("[RBXLX] listo: " .. tostring(#result) .. " servicio(s)/raiz, " .. tostring(count) .. " instancia(s)")
	end

	return result, count
end

return rbxlxToInstance
