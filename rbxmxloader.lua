-- yes i made this with ai
-- no i dont really care
-- i am not figuring out rbxmxs and all the fuckery that it has
-- also unions dont work, thats the only thing i know of that doesnt

--update logs

-- 2025-11-23 - fixed udim
-- 2025-12-15 - fixed ref resolution for Part0/Part1 and other instance references
-- 2026-10-11 - Font/FontFace: la familia ahora se lee bien (antes siempre caia en SourceSansPro)
--            - enums: se asignan como EnumItem real (Material, Shape, ScaleType, Face, etc.)
--            - Tags y Attributes (AttributesSerialize) ahora se aplican
--            - Content: soporta <url>, <uri> y texto directo
--            - valores inf / -inf / nan (UISizeConstraint.MaxSize, etc.)
--            - Color3uint8: se arreglo el canal rojo (incluia los bits de alpha)
--            - tipos nuevos: Vector3int16, Vector2int16, Rect (SliceCenter), Ray
--            - ignora <?xml ?> y <!DOCTYPE>, clases invalidas ya no tumban toda la importacion
--            - opciones nuevas: Preload, ApplyTags, ApplyAttributes

local CollectionService = game:GetService("CollectionService")
local ContentProvider = game:GetService("ContentProvider")
local InsertService = game:GetService("InsertService")

local propertyMap = {
	["size"] = "Size",
	["shape"] = "Shape",
	["Color3uint8"] = "Color",
	["MaterialVariantSerialized"] = "MaterialVariant",
	["Part0Internal"] = "Part0",
	["Part1Internal"] = "Part1",
}

-- Propiedades que no se pueden (o no hace falta) asignar directamente
local ignoredProperties = {
	["formFactorRaw"] = true,
	["Capabilities"] = true,
	["DefinesCapabilities"] = true,
	["SourceAssetId"] = true,
	["RunContext"] = true,
	["ScriptGuid"] = true,
	["Source"] = true,
	["LocalizationMatchIdentifier"] = true,
	["LocalizationMatchedSourceText"] = true,
	["UniqueId"] = true,
}

-- Tipos que no se pueden aplicar desde un script: se omiten sin ensuciar la consola
local ignoredTypes = {
	SharedString = true,
	OptionalCoordinateFrame = true,
	UniqueId = true,
	SecurityCapabilities = true,
}

local newx = require(123068958552495)

-- Opciones de la importacion en curso (las rellena rbxmxToInstance)
local activeOptions = {}

local function createScript(info)
	-- AllowScripts = false: los scripts se crean vacios y desactivados (no se ejecuta su codigo)
	if activeOptions.AllowScripts == false then
		local inst = Instance.new(info.type)
		if info.type ~= "ModuleScript" then
			pcall(function() inst.Enabled = false end)
			pcall(function() inst.Disabled = true end)
		end
		return inst
	end
	return newx(info)
end

local function newlocalscript(source,parent)
	return createScript({
		source = source,
		parent = parent,
		type = "LocalScript",
	})
end

local function newclientruncontext(source,parent)
	return createScript({
		source = source,
		parent = parent,
		type = "Script",
		runcontext = Enum.RunContext.Client
	})
end

local function newscript(source,parent)
	return createScript({
		source = source,
		parent = parent,
		type = "Script"
	})
end

local function newmodulescript(source,parent)
	return createScript({
		source = source,
		parent = parent,
		type = "ModuleScript"
	})
end

local ScriptAddon = [[
local value = select(1,...)
script = value
Script = value
%s
]]

-- ============================================================
-- XML
-- ============================================================

local function parseXML(xml)
	local tree = {children = {}}
	local stack = {tree}
	local top = stack[#stack]
	local i = 1
	while i <= #xml do
		if xml:sub(i, i) == '<' then
			i = i + 1
			if xml:sub(i, i) == '/' then
				i = i + 1
				local tagEnd = xml:find(">", i)
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
			elseif xml:sub(i, i+7) == '![CDATA[' then
				i = i + 8
				local cdataEnd = xml:find("]]>", i)
				if not cdataEnd then
					warn("Malformed XML: Unclosed CDATA at position " .. i)
					break
				end
				local text = xml:sub(i, cdataEnd - 1)
				table.insert(top.children, {text = text})
				i = cdataEnd + 3
			elseif xml:sub(i, i+2) == '!--' then
				i = i + 3
				local commentEnd = xml:find("-->", i)
				if not commentEnd then
					warn("Malformed XML: Unclosed comment at position " .. i)
					break
				end
				i = commentEnd + 3
			elseif xml:sub(i, i) == '?' then
				-- <?xml version="1.0" encoding="utf-8"?>
				local pEnd = xml:find("?>", i, true)
				if not pEnd then
					warn("Malformed XML: Unclosed declaration at position " .. i)
					break
				end
				i = pEnd + 2
			elseif xml:sub(i, i+7) == '!DOCTYPE' then
				local dEnd = xml:find(">", i, true)
				if not dEnd then
					warn("Malformed XML: Unclosed DOCTYPE at position " .. i)
					break
				end
				i = dEnd + 1
			else
				local tagEnd = xml:find(">", i)
				if not tagEnd then
					warn("Malformed XML: No closing '>' for tag at position " .. i)
					break
				end
				local tagStr = xml:sub(i, tagEnd - 1)
				i = tagEnd + 1
				local tag = tagStr:match("^(%S+)")
				if not tag then
					warn("Malformed XML: Invalid tag name at position " .. i)
					break
				end
				local attrs = {}
				for k, v in tagStr:gmatch('(%S+)=%s*"([^"]*)"') do
					attrs[k] = v
				end
				local new = {tag = tag, attrs = attrs, children = {}}
				table.insert(top.children, new)
				if xml:sub(tagEnd - 1, tagEnd - 1) == '/' then
				else
					table.insert(stack, new)
					top = new
				end
			end
		else
			local textEnd = xml:find("<", i) or (#xml + 1)
			local text = xml:sub(i, textEnd - 1):gsub("^%s*(.-)%s*$", "%1")
			if text ~= "" then
				table.insert(top.children, {text = text})
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

-- ============================================================
-- Utilidades
-- ============================================================

local entities = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

-- Convierte &amp; &lt; &gt; &quot; &apos; y &#65; / &#x41;
local function decodeEntities(s)
	if type(s) ~= "string" or not s:find("&", 1, true) then
		return s
	end
	local out = s:gsub("&(#?[xX]?%w+);", function(e)
		if e:sub(1, 1) == "#" then
			local second = e:sub(2, 2)
			local n
			if second == "x" or second == "X" then
				n = tonumber(e:sub(3), 16)
			else
				n = tonumber(e:sub(2))
			end
			if n and n > 0 and n < 0x110000 then
				local ok, ch = pcall(utf8.char, n)
				if ok then
					return ch
				end
			end
			return nil
		end
		return entities[e]
	end)
	return out
end

-- tonumber que tambien entiende INF / -INF / NAN (asi los escribe Studio)
local function num(text)
	if text == nil then
		return nil
	end
	local n = tonumber(text)
	if n ~= nil then
		return n
	end
	local lower = tostring(text):lower()
	if lower == "inf" or lower == "+inf" then
		return math.huge
	elseif lower == "-inf" then
		return -math.huge
	elseif lower:find("nan", 1, true) then
		return 0 / 0
	end
	return nil
end

local function firstText(node)
	local c = node.children[1]
	return c and c.text or nil
end

local function textOf(node, tagName)
	local n = getTagNode(tagName, node)
	return n and n.children[1] and n.children[1].text or nil
end

local function numbersOf(node, ...)
	local out = {}
	for i, tagName in ipairs({ ... }) do
		local v = num(textOf(node, tagName))
		if v == nil then
			return nil
		end
		out[i] = v
	end
	return out
end

local function numbersFromText(node)
	local text = firstText(node) or ""
	local nums = {}
	for n in text:gmatch("%S+") do
		table.insert(nums, num(n) or 0)
	end
	return nums
end

local function colorFromUint(u)
	return Color3.fromRGB(
		bit32.band(bit32.rshift(u, 16), 255),
		bit32.band(bit32.rshift(u, 8), 255),
		bit32.band(u, 255)
	)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64lookup = {}
for i = 1, #B64 do
	b64lookup[B64:byte(i)] = i - 1
end

local function decodeBase64(s)
	local out = {}
	local buffer, bits = 0, 0
	for i = 1, #s do
		local v = b64lookup[s:byte(i)]
		if v then
			buffer = buffer * 64 + v
			bits = bits + 6
			if bits >= 8 then
				bits = bits - 8
				out[#out + 1] = string.char(bit32.rshift(buffer, bits))
				buffer = bit32.band(buffer, bit32.lshift(1, bits) - 1)
			end
		end
	end
	return table.concat(out)
end

-- ============================================================
-- Font / FontFace
-- ============================================================

local function parseFont(pnode)
	-- <Font name="FontFace">
	--   <Family><url>rbxasset://fonts/families/GothamSSm.json</url></Family>
	--   <Weight>700</Weight><Style>Normal</Style>
	-- </Font>
	local family = "rbxasset://fonts/families/SourceSansPro.json"
	local familyNode = getTagNode("Family", pnode)
	if familyNode then
		local urlNode = getTagNode("url", familyNode) or getTagNode("uri", familyNode)
		local text
		if urlNode then
			text = urlNode.children[1] and urlNode.children[1].text
		else
			text = familyNode.children[1] and familyNode.children[1].text
		end
		if text and text ~= "" then
			family = decodeEntities(text)
		end
	end

	local weight = Enum.FontWeight.Regular
	local weightText = textOf(pnode, "Weight")
	if weightText then
		local n = tonumber(weightText)
		local lower = weightText:lower()
		for _, item in ipairs(Enum.FontWeight:GetEnumItems()) do
			if (n and item.Value == n) or item.Name:lower() == lower then
				weight = item
				break
			end
		end
	end

	local style = Enum.FontStyle.Normal
	local styleText = textOf(pnode, "Style")
	if styleText and styleText:lower() == "italic" then
		style = Enum.FontStyle.Italic
	end

	return Font.new(family, weight, style)
end

-- ============================================================
-- Tags y Attributes
-- ============================================================

local function applyTags(inst, base64Text)
	local data = decodeBase64(base64Text or "")
	for _, tag in ipairs(string.split(data, "\0")) do
		if tag ~= "" then
			CollectionService:AddTag(inst, tag)
		end
	end
end

-- Formato binario de AttributesSerialize:
-- u32 cantidad, y por cada atributo: nombre (u32 largo + bytes), u8 tipo, valor
local function decodeAttributes(data)
	local attrs = {}
	local pos = 1
	local count
	count, pos = string.unpack("<I4", data, pos)
	for _ = 1, count do
		local nameLen
		nameLen, pos = string.unpack("<I4", data, pos)
		local name = data:sub(pos, pos + nameLen - 1)
		pos = pos + nameLen

		local atype
		atype, pos = string.unpack("<B", data, pos)

		local value
		if atype == 0x02 then -- String
			local len
			len, pos = string.unpack("<I4", data, pos)
			value = data:sub(pos, pos + len - 1)
			pos = pos + len
		elseif atype == 0x03 then -- Bool
			local b
			b, pos = string.unpack("<B", data, pos)
			value = b ~= 0
		elseif atype == 0x06 then -- Number (Float64)
			value, pos = string.unpack("<d", data, pos)
		elseif atype == 0x09 then -- UDim
			local s, o
			s, o, pos = string.unpack("<fi4", data, pos)
			value = UDim.new(s, o)
		elseif atype == 0x0A then -- UDim2
			local xs, xo, ys, yo
			xs, xo, ys, yo, pos = string.unpack("<fi4fi4", data, pos)
			value = UDim2.new(xs, xo, ys, yo)
		elseif atype == 0x0E then -- BrickColor
			local n
			n, pos = string.unpack("<I4", data, pos)
			value = BrickColor.new(n)
		elseif atype == 0x0F then -- Color3
			local r, g, b
			r, g, b, pos = string.unpack("<fff", data, pos)
			value = Color3.new(r, g, b)
		elseif atype == 0x10 then -- Vector2
			local x, y
			x, y, pos = string.unpack("<ff", data, pos)
			value = Vector2.new(x, y)
		elseif atype == 0x11 then -- Vector3
			local x, y, z
			x, y, z, pos = string.unpack("<fff", data, pos)
			value = Vector3.new(x, y, z)
		else
			warn("[RBXMX] Atributo '" .. name .. "' de tipo no soportado (0x" .. string.format("%02X", atype) .. "), se omiten los siguientes")
			break
		end
		attrs[name] = value
	end
	return attrs
end

local function applyAttributes(inst, base64Text)
	local data = decodeBase64(base64Text or "")
	if #data < 4 then
		return
	end
	local ok, attrs = pcall(decodeAttributes, data)
	if not ok then
		warn("[RBXMX] No se pudieron leer los atributos de " .. inst.ClassName .. ": " .. tostring(attrs))
		return
	end
	for name, value in pairs(attrs) do
		pcall(function() inst:SetAttribute(name, value) end)
	end
end

-- ============================================================
-- Parsers de propiedades (uno por tipo de XML)
-- ============================================================

local parsers = {}

parsers.string = function(pnode)
	return decodeEntities(firstText(pnode) or "")
end

parsers.BinaryString = function(pnode)
	return firstText(pnode) or ""
end
parsers.ProtectedString = parsers.BinaryString

-- Content: <url>, <uri>, <null/> o texto directo
parsers.Content = function(pnode)
	local sub = pnode.children[1]
	if not sub then
		return ""
	end
	if sub.text then
		return decodeEntities(sub.text)
	end
	if sub.tag == "url" or sub.tag == "uri" then
		return decodeEntities(sub.children[1] and sub.children[1].text or "")
	end
	return "" -- <null>, <Object>, etc.
end
parsers.ContentId = parsers.Content

parsers.bool = function(pnode)
	return firstText(pnode) == "true"
end

parsers.number = function(pnode)
	return num(firstText(pnode))
end
parsers.float = parsers.number
parsers.double = parsers.number
parsers.int = parsers.number
parsers.int64 = parsers.number
parsers.token = parsers.number -- enum: se convierte a EnumItem al asignarlo

parsers.BrickColor = function(pnode)
	local n = num(firstText(pnode))
	return n and BrickColor.new(n) or nil
end

parsers.Ref = function(pnode)
	return firstText(pnode) or "null"
end

parsers.Vector3 = function(pnode)
	local n = numbersOf(pnode, "X", "Y", "Z")
	return n and Vector3.new(n[1], n[2], n[3]) or nil
end

parsers.Vector2 = function(pnode)
	local n = numbersOf(pnode, "X", "Y")
	return n and Vector2.new(n[1], n[2]) or nil
end

parsers.CFrame = function(pnode)
	local n = numbersOf(pnode, "X", "Y", "Z", "R00", "R01", "R02", "R10", "R11", "R12", "R20", "R21", "R22")
	if not n then
		return nil
	end
	return CFrame.new(unpack(n))
end
parsers.CoordinateFrame = parsers.CFrame

parsers.Color3 = function(pnode)
	local n = numbersOf(pnode, "R", "G", "B")
	if n then
		return Color3.new(n[1], n[2], n[3])
	end
	local u = num(textOf(pnode, "uint")) or num(firstText(pnode))
	if u then
		return colorFromUint(u)
	end
	return Color3.new(1, 1, 1)
end

parsers.Color3uint8 = function(pnode)
	local u = num(firstText(pnode))
	return u and colorFromUint(u) or nil
end

parsers.UDim = function(pnode)
	return UDim.new(num(textOf(pnode, "S")) or 0, num(textOf(pnode, "O")) or 0)
end

parsers.UDim2 = function(pnode)
	return UDim2.new(
		num(textOf(pnode, "XS")) or 0,
		num(textOf(pnode, "XO")) or 0,
		num(textOf(pnode, "YS")) or 0,
		num(textOf(pnode, "YO")) or 0
	)
end

parsers.PhysicalProperties = function(pnode)
	local cp = getTagNode("CustomPhysics", pnode)
	if cp and firstText(cp) == "false" then
		return nil
	end
	local n = numbersOf(pnode, "Density", "Friction", "Elasticity", "FrictionWeight", "ElasticityWeight")
	return n and PhysicalProperties.new(n[1], n[2], n[3], n[4], n[5]) or nil
end

parsers.Font = parseFont

parsers.ColorSequence = function(pnode)
	local keypoints = {}

	for _, kpNode in ipairs(pnode.children) do
		if kpNode.tag == "Keypoint" then
			local time = num(textOf(kpNode, "Time")) or 0
			local r = num(textOf(kpNode, "R")) or 1
			local g = num(textOf(kpNode, "G")) or 1
			local b = num(textOf(kpNode, "B")) or 1
			table.insert(keypoints, ColorSequenceKeypoint.new(time, Color3.new(r, g, b)))
		end
	end

	-- Formato en texto: "tiempo r g b 0" por cada keypoint
	if #keypoints == 0 then
		local nums = numbersFromText(pnode)
		for i = 1, #nums, 5 do
			if i + 3 <= #nums then
				table.insert(keypoints, ColorSequenceKeypoint.new(nums[i], Color3.new(nums[i + 1], nums[i + 2], nums[i + 3])))
			else
				break
			end
		end
	end

	if #keypoints < 2 then
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(1, Color3.new(1, 1, 1))
		})
	end
	return ColorSequence.new(keypoints)
end

parsers.NumberSequence = function(pnode)
	local keypoints = {}

	for _, kpNode in ipairs(pnode.children) do
		if kpNode.tag == "Keypoint" then
			local time = num(textOf(kpNode, "Time")) or 0
			local value = num(textOf(kpNode, "Value")) or 0
			local envelope = num(textOf(kpNode, "Envelope")) or 0
			table.insert(keypoints, NumberSequenceKeypoint.new(time, value, envelope))
		end
	end

	-- Formato en texto: "tiempo valor envelope" por cada keypoint
	if #keypoints == 0 then
		local nums = numbersFromText(pnode)
		for i = 1, #nums, 3 do
			if i + 1 <= #nums then
				table.insert(keypoints, NumberSequenceKeypoint.new(nums[i], nums[i + 1], nums[i + 2] or 0))
			else
				break
			end
		end
	end

	if #keypoints < 2 then
		return NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1, 0),
			NumberSequenceKeypoint.new(1, 1, 0)
		})
	end
	return NumberSequence.new(keypoints)
end

parsers.NumberRange = function(pnode)
	local minv = num(textOf(pnode, "min"))
	local maxv = num(textOf(pnode, "max"))
	if minv ~= nil and maxv ~= nil then
		return NumberRange.new(minv, maxv)
	end

	local nums = numbersFromText(pnode)
	if #nums >= 2 then
		return NumberRange.new(nums[1], nums[2])
	elseif #nums == 1 then
		return NumberRange.new(nums[1], nums[1])
	end

	return NumberRange.new(0, 0)
end

-- Tipos extra
parsers.Vector3int16 = function(pnode)
	local n = numbersOf(pnode, "X", "Y", "Z")
	return n and Vector3int16.new(n[1], n[2], n[3]) or nil
end

parsers.Vector2int16 = function(pnode)
	local n = numbersOf(pnode, "X", "Y")
	return n and Vector2int16.new(n[1], n[2]) or nil
end

-- Rect: ImageLabel.SliceCenter y similares
parsers.Rect = function(pnode)
	local mn, mx = getTagNode("min", pnode), getTagNode("max", pnode)
	if mn and mx then
		local a, b = numbersOf(mn, "X", "Y"), numbersOf(mx, "X", "Y")
		if a and b then
			return Rect.new(a[1], a[2], b[1], b[2])
		end
	end
	return nil
end
parsers.Rect2D = parsers.Rect

parsers.Ray = function(pnode)
	local o, d = getTagNode("origin", pnode), getTagNode("direction", pnode)
	if o and d then
		local a, b = numbersOf(o, "X", "Y", "Z"), numbersOf(d, "X", "Y", "Z")
		if a and b then
			return Ray.new(Vector3.new(a[1], a[2], a[3]), Vector3.new(b[1], b[2], b[3]))
		end
	end
	return nil
end

local warnedTypes = {}

-- Tolerante a errores: un valor ilegible nunca tumba la importacion
local function parseProperty(ptype, pnode, refs)
	if ignoredTypes[ptype] then
		return nil
	end

	local parser = parsers[ptype]
	if not parser then
		if not warnedTypes[ptype] then
			warnedTypes[ptype] = true
			warn("Unsupported property type: " .. tostring(ptype))
		end
		return nil
	end

	local ok, result = pcall(parser, pnode, refs)
	if not ok then
		warn("[RBXMX] Propiedad de tipo '" .. tostring(ptype) .. "' ilegible: " .. tostring(result))
		return nil
	end
	return result
end

-- ============================================================
-- Asignacion de propiedades
-- ============================================================

local enumCache = {}

-- Los <token> llegan como numero. Se busca el EnumItem real mirando el valor
-- actual de la propiedad (asi sirve para cualquier enum sin tener que listarlos).
local function resolveEnumItem(inst, propName, value)
	local ok, current = pcall(function() return inst[propName] end)
	if ok and typeof(current) == "EnumItem" then
		local enumType = current.EnumType
		local byValue = enumCache[enumType]
		if not byValue then
			byValue = {}
			for _, item in ipairs(enumType:GetEnumItems()) do
				byValue[item.Value] = item
			end
			enumCache[enumType] = byValue
		end
		return byValue[value]
	end
	return nil
end

local function applyProperty(inst, name, value, ptype, debug)
	if ptype == "token" and type(value) == "number" then
		local item = resolveEnumItem(inst, name, value)
		if item ~= nil then
			value = item
		end
	end
	local ok = pcall(function() inst[name] = value end)
	if not ok and debug then
		warn("[RBXMX] No se pudo asignar " .. inst.ClassName .. "." .. name)
	end
	return ok
end

local function getPropertyFromNode(node, name, refs)
	local propNode = getTagNode("Properties", node)
	if not propNode then return nil end
	for _, p in ipairs(propNode.children) do
		if p.attrs and p.attrs.name == name then
			local value = parseProperty(p.tag, p, refs)
			return value
		end
	end
	return nil
end

local function getValidAssetFromNode(node, name, refs)
	local value = getPropertyFromNode(node, name, refs)
	if value and value ~= "" and value ~= "null" then
		return value
	end
	return nil
end

-- ============================================================
-- Importacion
-- ============================================================

local function importCore(xmlString, debug, waitInterval)
	waitInterval = waitInterval or 10000
	local tree = parseXML(xmlString)
	local root = getTagNode("roblox", tree) or tree.children[1]
	local refs = {}
	local pendingRefs = {}
	local instances = {}
	local instanceCount = 0

	local function create(node)
		if node.tag ~= "Item" then return end
		local class = node.attrs.class
		local ref = node.attrs.referent
		local inst
		if class == "Script" then
			local source = getPropertyFromNode(node, "Source", refs) or ""
			local runContext = getPropertyFromNode(node, "RunContext", refs)

			if runContext == Enum.RunContext.Client.Value then
				inst = newclientruncontext(source)
			else
				inst = newscript(source)
			end
		elseif class == "LocalScript" then
			inst = newlocalscript(getPropertyFromNode(node, "Source", refs) or "")
		elseif class == "ModuleScript" then
			inst = newmodulescript(getPropertyFromNode(node, "Source", refs) or "")
		elseif class == "MeshPart" then
			local meshId = getValidAssetFromNode(node, "MeshId", refs)
			if not meshId then
				warn("No valid MeshId found for MeshPart: " .. (node.attrs.referent or "unknown"))
				inst = Instance.new("MeshPart")
			else
				xpcall(function()
					inst = InsertService:CreateMeshPartAsync(meshId, Enum.CollisionFidelity.Default, Enum.RenderFidelity.Automatic)
					local textureId = getValidAssetFromNode(node, "TextureId", refs)
					if textureId then
						inst.TextureID = textureId
					end
				end,function(err)
					warn("Error making meshpart: "..err)
					inst = Instance.new("MeshPart")
				end)
			end
		else
			local ok, made = pcall(Instance.new, class)
			if not ok then
				warn("[RBXMX] No se pudo crear la clase '" .. tostring(class) .. "', se omite junto con sus hijos")
				return nil
			end
			inst = made
		end

		if not inst then
			return nil
		end

		if debug then
			print("[RBXMX] Created instance: " .. class .. " (ref: " .. (ref or "no-ref") .. ")")
		end

		if ref then
			refs[ref] = inst
		end
		pendingRefs[inst] = {}

		local propNode = getTagNode("Properties", node)
		if propNode then
			-- Si existe FontFace, el enum viejo "Font" se ignora (FontFace manda)
			local hasFontFace = false
			for _, p in ipairs(propNode.children) do
				if p.attrs and p.attrs.name == "FontFace" then
					hasFontFace = true
					break
				end
			end

			for _, p in ipairs(propNode.children) do
				local ptype = p.tag
				local pname = p.attrs and p.attrs.name
				if pname and not ignoredProperties[pname] then
					if pname == "Tags" then
						if activeOptions.ApplyTags ~= false then
							applyTags(inst, firstText(p))
						end
					elseif pname == "AttributesSerialize" then
						if activeOptions.ApplyAttributes ~= false then
							applyAttributes(inst, firstText(p))
						end
					elseif not (pname == "Font" and ptype == "token" and hasFontFace) then
						local realPname = propertyMap[pname] or pname:gsub("^%l", string.upper)
						local value = parseProperty(ptype, p, refs)
						if value ~= nil then
							if ptype == "Ref" then
								pendingRefs[inst][realPname] = value
							else
								applyProperty(inst, realPname, value, ptype, debug)
							end
						end
					end
				end
			end
		end

		for _, child in ipairs(node.children) do
			if child.tag == "Item" then
				local childInst = create(child)
				if childInst then
					childInst.Parent = inst
				end
			end
		end

		instanceCount = instanceCount + 1
		if waitInterval and instanceCount % waitInterval == 0 then
			task.wait()
		end

		return inst
	end

	for _, node in ipairs(root.children) do
		if node.tag == "Item" then
			local inst = create(node)
			if inst then
				table.insert(instances, inst)
			end
		end
	end

	local function resolveRefs(inst, visited)
		if visited[inst] then return end
		visited[inst] = true
		for propName, rbxId in pairs(pendingRefs[inst] or {}) do
			if rbxId == "null" then
				pcall(function() inst[propName] = nil end)
			elseif refs[rbxId] then
				pcall(function() inst[propName] = refs[rbxId] end)
			else
				warn("Unresolved ref '" .. tostring(rbxId) .. "' for " .. propName .. " on " .. inst.Name)
			end
		end
		for _, child in ipairs(inst:GetChildren()) do
			if child:IsA("Instance") then
				resolveRefs(child, visited)
			end
		end
	end

	local visited = {}
	for _, inst in ipairs(instances) do
		resolveRefs(inst, visited)
	end
	pendingRefs = nil
	return instances
end

-- Uso:
--   rbxmxToInstance(xml, debug, waitInterval, {
--       AllowScripts    = false,      -- scripts vacios y desactivados
--       Parent          = workspace,  -- donde poner las instancias raiz
--       CatchErrors     = true,       -- no lanza error, devuelve {}
--       Preload         = true,       -- precarga imagenes/sonidos/fuentes (util para GUIs)
--       ApplyTags       = false,      -- no aplica CollectionService tags (por defecto si)
--       ApplyAttributes = false,      -- no aplica atributos (por defecto si)
--   })
-- Sin el 4to argumento funciona como siempre.
local function rbxmxToInstance(xmlString, debug, waitInterval, options)
	options = options or {}

	if type(xmlString) ~= "string" or xmlString == "" then
		warn("[RBXMX] El contenido esta vacio o no es texto")
		return {}
	end
	if xmlString:sub(1, 8) == "<roblox!" then
		warn("[RBXMX] Esto es un .rbxm binario; este loader solo lee .rbxmx (XML)")
		return {}
	end
	if not xmlString:find("<roblox", 1, true) then
		warn("[RBXMX] El texto no parece un archivo rbxmx")
		return {}
	end

	activeOptions = options
	local ok, result = pcall(importCore, xmlString, debug, waitInterval)
	activeOptions = {}

	if not ok then
		if options.CatchErrors then
			warn("[RBXMX] Error al importar: " .. tostring(result))
			return {}
		end
		error(result, 0)
	end

	if options.Parent then
		for _, inst in ipairs(result) do
			inst.Parent = options.Parent
		end
	end

	if options.Preload and #result > 0 then
		pcall(function()
			ContentProvider:PreloadAsync(result)
		end)
	end

	return result
end

return rbxmxToInstance
