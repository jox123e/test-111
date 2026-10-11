-- yes i made this with ai
-- no i dont really care
-- i am not figuring out rbxmxs and all the fuckery that it has
-- also unions dont work, thats the only thing i know of that doesnt

--update logs

-- 2025-11-23 - fixed udim
-- 2025-12-15 - fixed ref resolution for Part0/Part1 and other instance references
-- 2026-10-11 - added (nothing above was removed or changed): more property types, safe error handling, loader options (Parent / NoScripts), URL input

local propertyMap = {
	["size"] = "Size",
	["shape"] = "Shape",
	["formFactorRaw"] = nil,
	["Color3uint8"] = "Color",
	["MaterialVariantSerialized"] = "MaterialVariant",
	["AttributesSerialize"] = nil,
	["Capabilities"] = nil,
	["DefinesCapabilities"] = nil,
	["SourceAssetId"] = nil,
	["Tags"] = nil,
	["RunContext"] = nil,
	["ScriptGuid"] = nil,
	["Source"] = nil,
	["LocalizationMatchIdentifier"] = nil,
	["LocalizationMatchedSourceText"] = nil,
	["FontFace"] = nil,
	["MetalnessMap"] = nil,
	["NormalMap"] = nil,
	["RoughnessMap"] = nil,
	["TexturePack"] = nil,
	["TexturePackMetadata"] = nil,
	["Part0Internal"] = "Part0",
	["Part1Internal"] = "Part1",
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

local ScriptAddon = [[
local value = select(1,...)
script = value
Script = value
%s
]]

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
			local textStart = i
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

local function parseProperty(ptype, pnode, refs)
	local children = pnode.children
	local tn = tonumber

	local function getText(tagName, parent)
		parent = parent or pnode
		local n = getTagNode(tagName, parent)
		if n and #n.children > 0 then
			return n.children[1].text
		end
		return nil
	end

	if ptype == "string" or ptype == "BinaryString" or ptype == "ProtectedString" then
		return children[1] and children[1].text or ""
	elseif ptype == "Content" then
		if #children == 0 then return "" end
		local sub = children[1]
		if sub.tag == "null" then
			return ""
		elseif sub.tag == "url" then
			return sub.children[1] and sub.children[1].text or ""
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
		local text = children[1] and children[1].text or "null"
		return text
	elseif ptype == "Vector3" then
		return Vector3.new(tn(getText("X")), tn(getText("Y")), tn(getText("Z")))
	elseif ptype == "Vector2" then
		return Vector2.new(tn(getText("X")), tn(getText("Y")))
	elseif ptype == "CoordinateFrame" or ptype == "CFrame" then
		return CFrame.new(
			tn(getText("X")), tn(getText("Y")), tn(getText("Z")),
			tn(getText("R00")), tn(getText("R01")), tn(getText("R02")),
			tn(getText("R10")), tn(getText("R11")), tn(getText("R12")),
			tn(getText("R20")), tn(getText("R21")), tn(getText("R22"))
		)
	elseif ptype == "Color3" then
		local r = getText("R")
		if r then
			return Color3.new(tn(r), tn(getText("G")), tn(getText("B")))
		else
			local uint = getText("uint")
			if uint then
				local u = tn(uint)
				return Color3.new(bit32.rshift(u, 16)/255, bit32.rshift(u, 8) % 256 /255, bit32.band(u, 255)/255)
			end
		end
		return Color3.new(1, 1, 1)
	elseif ptype == "Color3uint8" then
		local u = tn(children[1].text)
		return Color3.new(bit32.rshift(u, 16)/255, bit32.rshift(u, 8) % 256 /255, bit32.band(u, 255)/255)
	elseif ptype == "UDim" then
		local s = tn(getText("S"))
		local o = tn(getText("O"))
		return UDim.new(s or 0, o or 0)
	elseif ptype == "UDim2" then
		local xs = tn(getText("XS"))
		local xo = tn(getText("XO"))
		local ys = tn(getText("YS"))
		local yo = tn(getText("YO"))
		return UDim2.new(xs, xo, ys, yo)
	elseif ptype == "PhysicalProperties" then
		local cp = getTagNode("CustomPhysics", pnode)
		if cp and cp.children[1].text == "false" then
			return nil
		else
			local d = tn(getText("Density"))
			local f = tn(getText("Friction"))
			local e = tn(getText("Elasticity"))
			local fw = tn(getText("FrictionWeight"))
			local ew = tn(getText("ElasticityWeight"))
			return PhysicalProperties.new(d, f, e, fw, ew)
		end
	elseif ptype == "SecurityCapabilities" then
		return tn(children[1].text)
	elseif ptype == "Font" then
		local family = getText("Family", pnode) or "rbxasset://fonts/families/SourceSansPro.json"
		local weightText = getText("Weight", pnode)
		local styleText = getText("Style", pnode)

		local weightMap = {
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
			["Heavy"] = Enum.FontWeight.Heavy
		}

		local weight = weightMap[tostring(weightText)] or Enum.FontWeight.Regular

		local style = Enum.FontStyle[tostring(styleText)] or Enum.FontStyle.Normal

		return Font.new(family, weight, style)
	elseif ptype == "ColorSequence" then
		local keypoints = {}

		local function parseNumbersFromTextNode(node)
			local text = node.children[1] and node.children[1].text or ""
			local nums = {}
			for num in text:gmatch("%S+") do
				table.insert(nums, tonumber(num) or 0)
			end
			return nums
		end

		for _, kpNode in ipairs(pnode.children) do
			if kpNode.tag == "Keypoint" then
				local time = tonumber(getText("Time", kpNode)) or 0
				local r = tonumber(getText("R", kpNode)) or 1
				local g = tonumber(getText("G", kpNode)) or 1
				local b = tonumber(getText("B", kpNode)) or 1
				table.insert(keypoints, ColorSequenceKeypoint.new(time, Color3.new(r, g, b)))
			end
		end

		if #keypoints == 0 then
			local nums = parseNumbersFromTextNode(pnode)
			for i = 1, #nums, 5 do
				if i + 3 <= #nums then
					local time = nums[i] or 0
					local r = nums[i+1] or 1
					local g = nums[i+2] or 1
					local b = nums[i+3] or 1
					table.insert(keypoints, ColorSequenceKeypoint.new(time, Color3.new(r, g, b)))
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


	elseif ptype == "NumberSequence" then
		local keypoints = {}

		local function parseNumbersFromTextNode(node)
			local text = node.children[1] and node.children[1].text or ""
			local nums = {}
			for num in text:gmatch("%S+") do
				table.insert(nums, tonumber(num) or 0)
			end
			return nums
		end

		for _, kpNode in ipairs(pnode.children) do
			if kpNode.tag == "Keypoint" then
				local time = tonumber(getText("Time", kpNode)) or 0
				local value = tonumber(getText("Value", kpNode)) or 0
				local envelope = tonumber(getText("Envelope", kpNode)) or 0
				table.insert(keypoints, NumberSequenceKeypoint.new(time, value, envelope))
			end
		end

		if #keypoints == 0 then
			local nums = parseNumbersFromTextNode(pnode)
			for i = 1, #nums, 3 do
				if i + 1 <= #nums then
					local time = nums[i] or 0
					local value = nums[i+1] or 0
					local envelope = nums[i+2] or 0
					table.insert(keypoints, NumberSequenceKeypoint.new(time, value, envelope))
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


	elseif ptype == "NumberRange" then
		local function parseNumbersFromTextNode(node)
			local text = node.children[1] and node.children[1].text or ""
			local nums = {}
			for num in text:gmatch("%S+") do
				table.insert(nums, tonumber(num) or 0)
			end
			return nums
		end


		local minv = tonumber(getText("min")) 
		local maxv = tonumber(getText("max"))

		if minv ~= nil and maxv ~= nil then
			return NumberRange.new(minv, maxv)
		end


		local nums = parseNumbersFromTextNode(pnode)
		if #nums >= 2 then
			return NumberRange.new(nums[1], nums[2])
		elseif #nums == 1 then
			return NumberRange.new(nums[1], nums[1])
		end


		return NumberRange.new(0, 0)
	end
	warn("Unsupported property type: " .. ptype)
	return nil
end

local function getSourceFromNode(node, refs)
	local propNode = getTagNode("Properties", node)
	if not propNode then return nil end
	for _, p in ipairs(propNode.children) do
		if p.attrs and p.attrs.name == "Source" then
			return parseProperty(p.tag, p, refs)
		end
	end
	return nil
end

local function getMeshIdFromNode(node, refs)
	local propNode = getTagNode("Properties", node)
	if not propNode then return nil end
	for _, p in ipairs(propNode.children) do
		if p.attrs and p.attrs.name == "MeshId" then
			local value = parseProperty(p.tag, p, refs)
			if value and value ~= "" and value ~= "null" then
				return value
			end
		end
	end
	return nil
end

local function getTextureIdFromNode(node, refs)
	local propNode = getTagNode("Properties", node)
	if not propNode then return nil end
	for _, p in ipairs(propNode.children) do
		if p.attrs and p.attrs.name == "TextureId" then
			local value = parseProperty(p.tag, p, refs)
			if value and value ~= "" and value ~= "null" then
				return value
			end
		end
	end
	return nil
end

local function getRunContextFromNode(node)
	local propNode = getTagNode("Properties", node)
	if not propNode then return nil end
	for _, p in ipairs(propNode.children) do
		if p.attrs and p.attrs.name == "RunContext" then
			return tonumber(p.children[1].text)
		end
	end
end

local function rbxmxToInstance(xmlString, debug, waitInterval)
	waitInterval = waitInterval or 10000
	local tree = parseXML(xmlString)
	local root = getTagNode("roblox", tree) or tree.children[1]
	local refs = {}
	local scripts = {}
	local pendingRefs = {}
	local instances = {}
	local visited = {}
	local instanceCount = 0

	local function create(node)
		if node.tag ~= "Item" then return end
		local class = node.attrs.class
		local ref = node.attrs.referent
		local inst
		if class == "Script" then
			local source = getSourceFromNode(node, refs)
			local runContext = getRunContextFromNode(node)

			if runContext == Enum.RunContext.Client.Value then
				inst = newclientruncontext(source)
			else
				inst = newscript(source)
			end
		elseif class == "LocalScript" then
			local source = getSourceFromNode(node, refs)
			if source then
				inst = newlocalscript(source)
			end
		elseif class == "ModuleScript" then
			local source = getSourceFromNode(node, refs)
			if source then
				inst = newmodulescript(source)
			end
		elseif class == "MeshPart" then
			local meshId = getMeshIdFromNode(node, refs)
			if not meshId or meshId == "" then
				warn("No valid MeshId found for MeshPart: " .. (node.attrs.referent or "unknown"))
				inst = Instance.new("MeshPart")
			else
				local insertService = game:GetService("InsertService")
				xpcall(function()
					inst = insertService:CreateMeshPartAsync(meshId, Enum.CollisionFidelity.Default, Enum.RenderFidelity.Automatic)
					local textureId = getTextureIdFromNode(node, refs)
					if textureId and textureId ~= "" then
						inst.TextureID = textureId
					end
				end,function(err)
					warn("Error making meshpart: "..err)
					inst = Instance.new("MeshPart")
				end)
			end
		else
			inst = Instance.new(class)
		end
		
		if debug then
			print("[RBXMX] Created instance: " .. class .. " (ref: " .. (ref or "no-ref") .. ")")
		end
		
		refs[ref] = inst
		pendingRefs[inst] = {}
		local propNode = getTagNode("Properties", node)
		if propNode then
			for _, p in ipairs(propNode.children) do
				local ptype = p.tag
				local pname = p.attrs.name
				local realPname = propertyMap[pname] or pname:gsub("^%l", string.upper)
				if realPname then
					local value = parseProperty(ptype, p, refs)
					if value ~= nil then
						if ptype == "Ref" then
							pendingRefs[inst][realPname] = value
						else
							local success = pcall(function() inst[realPname] = value end)
						end
					end
				elseif pname == "FontFace" then
					local value = parseProperty("Font", p, refs)
					if value then
						local success = pcall(function() inst.FontFace = value end)
						if not success then
							warn("Failed to set FontFace on " .. class)
						end
					end
				elseif pname then
					local value = parseProperty(ptype, p, refs)
					if value ~= nil then
						if ptype == "Ref" then
							pendingRefs[inst][pname] = value
						else
							local success = pcall(function() inst[pname] = value end)
							if not success and not (string.find(pname, "Internal") or string.find(pname, "Serialize")) then
								warn("Failed to set property: " .. pname .. " on " .. class)
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

	for _, inst in ipairs(instances) do
		resolveRefs(inst, visited)
	end
	pendingRefs = nil
	return instances
end


-- ====================================================================
-- ADDITIONS
-- Todo lo de abajo es nuevo. El codigo de arriba no se modifico: lo nuevo
-- "envuelve" las funciones existentes reasignando las variables locales.
-- ====================================================================

local HttpService = game:GetService("HttpService")
local unpack_ = table.unpack or unpack

-- ---------- ayudantes ----------

local function childText(pnode, tag)
	local n = getTagNode(tag, pnode)
	return n and n.children[1] and n.children[1].text or nil
end

-- lee varias etiquetas numericas (<X>, <Y>, ...) de un nodo; si falta alguna usa 0
local function vecComponents(node, ...)
	local out = {}
	for i, tag in ipairs({...}) do
		out[i] = (node and tonumber(childText(node, tag))) or 0
	end
	return unpack_(out)
end

-- ---------- tipos de propiedad extra ----------

local extraTypes = {
	Vector3int16 = function(pnode)
		return Vector3int16.new(vecComponents(pnode, "X", "Y", "Z"))
	end,

	Vector2int16 = function(pnode)
		return Vector2int16.new(vecComponents(pnode, "X", "Y"))
	end,

	Rect2D = function(pnode)
		local x0, y0 = vecComponents(getTagNode("min", pnode), "X", "Y")
		local x1, y1 = vecComponents(getTagNode("max", pnode), "X", "Y")
		return Rect.new(x0, y0, x1, y1)
	end,

	Ray = function(pnode)
		local o = Vector3.new(vecComponents(getTagNode("origin", pnode), "X", "Y", "Z"))
		local d = Vector3.new(vecComponents(getTagNode("direction", pnode), "X", "Y", "Z"))
		return Ray.new(o, d)
	end,

	Faces = function(pnode)
		local bits = tonumber(childText(pnode, "faces")) or 0
		local list = {}
		for i, face in ipairs({"Right", "Top", "Back", "Left", "Bottom", "Front"}) do
			if bit32.band(bits, bit32.lshift(1, i - 1)) ~= 0 then
				table.insert(list, Enum.NormalId[face])
			end
		end
		return Faces.new(unpack_(list))
	end,

	Axes = function(pnode)
		local bits = tonumber(childText(pnode, "axes")) or 0
		local list = {}
		for i, axis in ipairs({"X", "Y", "Z"}) do
			if bit32.band(bits, bit32.lshift(1, i - 1)) ~= 0 then
				table.insert(list, Enum.Axis[axis])
			end
		end
		return Axes.new(unpack_(list))
	end,
}

-- envuelve parseProperty: soporta los tipos extra y evita que UNA propiedad
-- rota detenga la carga de todo el archivo
local baseParseProperty = parseProperty

parseProperty = function(ptype, pnode, refs)
	local handler = extraTypes[ptype]
	local ok, result
	if handler then
		ok, result = pcall(handler, pnode)
	else
		ok, result = pcall(baseParseProperty, ptype, pnode, refs)
	end
	if not ok then
		warn("[RBXMX] No se pudo leer la propiedad '" .. tostring(pnode.attrs and pnode.attrs.name)
			.. "' (" .. tostring(ptype) .. "): " .. tostring(result))
		return nil
	end
	return result
end

-- ---------- opcion NoScripts ----------
-- Si NoScripts es true, los scripts del archivo se crean VACIOS y desactivados
-- (no se les pasa su codigo al modulo que los crea).

local skipScripts = false

local function disabledPlaceholder(className)
	local inst = Instance.new(className)
	pcall(function() inst.Enabled = false end)
	pcall(function() inst.Disabled = true end)
	return inst
end

local baseNewLocalScript = newlocalscript
newlocalscript = function(source, parent)
	if skipScripts then return disabledPlaceholder("LocalScript") end
	return baseNewLocalScript(source, parent)
end

local baseNewClientScript = newclientruncontext
newclientruncontext = function(source, parent)
	if skipScripts then return disabledPlaceholder("Script") end
	return baseNewClientScript(source, parent)
end

local baseNewScript = newscript
newscript = function(source, parent)
	if skipScripts then return disabledPlaceholder("Script") end
	return baseNewScript(source, parent)
end

local baseNewModuleScript = newmodulescript
newmodulescript = function(source, parent)
	if skipScripts then return disabledPlaceholder("ModuleScript") end
	return baseNewModuleScript(source, parent)
end

-- ---------- cargador mejorado ----------
-- Misma firma de siempre: rbxmxToInstance(xml, debug, waitInterval)
-- Nuevo 4to parametro (opcional): options = { Parent = <Instance>, NoScripts = true/false }
-- Tambien acepta un link directo (https://...) en lugar del texto del .rbxmx.

local baseLoader = rbxmxToInstance

rbxmxToInstance = function(source, debug, waitInterval, options)
	options = options or {}

	if type(source) ~= "string" then
		error("[RBXMX] se esperaba el texto del .rbxmx (string), no " .. type(source), 2)
	end

	if source:match("^%s*https?://") then
		local okGet, body = pcall(function()
			return HttpService:GetAsync(source)
		end)
		if not okGet then
			error("[RBXMX] no se pudo descargar el archivo: " .. tostring(body), 2)
		end
		source = body
	end

	if source:sub(1, 8) == "<roblox!" then
		error("[RBXMX] este archivo es un .rbxm binario; exportalo como .rbxmx (XML)", 2)
	end
	if not source:find("<roblox", 1, true) then
		error("[RBXMX] el contenido no parece un .rbxmx valido", 2)
	end

	-- nota: si cargas dos archivos a la vez, la opcion NoScripts es compartida
	skipScripts = options.NoScripts == true
	local ok, result = pcall(baseLoader, source, debug, waitInterval)
	skipScripts = false

	if not ok then
		error("[RBXMX] fallo al convertir el archivo: " .. tostring(result), 2)
	end

	if options.Parent then
		for _, inst in ipairs(result) do
			inst.Parent = options.Parent
		end
	end

	if debug then
		print("[RBXMX] listo: " .. tostring(#result) .. " instancia(s) raiz")
	end

	return result
end

return rbxmxToInstance
