--[[
written and planned by @QwinkleTee

   Particle Tools Plugin
    Copyright (C) 2025  QwinkleTee

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.

 
]]

local GraphMod = require(script.Graph)
local RangeMod = require(script.Range)
local ParticlesMod = require(script.Particles)
local MeshFlipMod = require(script.Flipbook)
local pluginscript = script.Parent.Parent
local RunService = game:GetService('RunService')
local Particle = {}
Particle.Beam = {} -- uh dont mind me! teehee fr
Particle.EnabledParts = {}
_G["Part_Icles"] = _G["Part_Icles"] or {}
_G["Part_Icles"]["EnableAllowed"] = _G["Part_Icles"]["EnableAllowed"] or true
local Beam = Particle.Beam
local DirectionVectors = {
	[Enum.NormalId.Top] = {vector = "UpVector", multiplier = 1},
	[Enum.NormalId.Bottom] = {vector = "UpVector", multiplier = -1},
	[Enum.NormalId.Front] = {vector = "LookVector", multiplier = 1},
	[Enum.NormalId.Back] = {vector = "LookVector", multiplier = -1},
	[Enum.NormalId.Left] = {vector = "RightVector", multiplier = -1},
	[Enum.NormalId.Right] = {vector = "RightVector", multiplier = 1},
}
local shapeFunctions = {
	[Enum.ParticleEmitterShape.Box] = function(p, emitter)
		local Px = (math.random() * 2 - 1) * p.Size.X / 2
		local Py = (math.random() * 2 - 1) * p.Size.Y / 2
		local Pz = (math.random() * 2 - 1) * p.Size.Z / 2
		return Vector3.new(Px, Py, Pz)
	end,
	[Enum.ParticleEmitterShape.Sphere] = function(p, emitter)
		local outerRadius = p.Size.X / 2
		local innerRadius = outerRadius * emitter.ShapePartial
		local randomRadius = (math.random() * (outerRadius^3 - innerRadius^3) + innerRadius^3)^(1/3)
		local theta = math.random() * 2 * math.pi
		local phi = math.acos((math.random() * 2) - 1)
		local direction = Vector3.new(
			math.sin(phi) * math.cos(theta),
			math.sin(phi) * math.sin(theta),
			math.cos(phi)
		)
		local localOffset = direction * randomRadius
		local localRotation = CFrame.lookAt(Vector3.new(), -direction)
		return localOffset, localRotation
	end,
	[Enum.ParticleEmitterShape.Cylinder] = function(p, emitter)
		local radius = p.Size.X / 2
		local height = p.Size.Y
		local innerRadiusRatio = emitter.ShapePartial
		local randomRadius = math.sqrt(math.random()) * (1 - innerRadiusRatio) + innerRadiusRatio
		local angle = math.random() * 2 * math.pi
		local x = randomRadius * radius * math.cos(angle)
		local y = (math.random() * 2 - 1) * (height / 2)
		local z = randomRadius * radius * math.sin(angle)
		local localOffset = Vector3.new(x, y, z)
		local direction
		if math.abs(y) > (height / 2) - 0.01 then
			direction = Vector3.new(0, math.sign(y), 0)
		else
			direction = Vector3.new(x, 0, z).Unit
		end
		local localRotation = CFrame.lookAt(Vector3.new(), -direction)
		return localOffset, localRotation
	end,
	[Enum.ParticleEmitterShape.Disc] = function(p, emitter)
		local radius = p.Size.X / 2
		local innerRadiusRatio = emitter.ShapePartial
		local randomRadiusRatio = math.sqrt(math.random()) * (1 - innerRadiusRatio) + innerRadiusRatio
		local angle = math.random() * 2 * math.pi
		local x = randomRadiusRatio * radius * math.cos(angle)
		local z = randomRadiusRatio * radius * math.sin(angle)
		local localOffset = Vector3.new(x, 0, z)
		local direction = localOffset.Unit
		local localRotation = CFrame.lookAt(Vector3.new(), -direction)
		return localOffset, localRotation
	end,
}

function Particle:GetFolder()
	local emissionfolder
	if workspace.Terrain:FindFirstChild('EmittedPartsUsingPart_icle') then
		emissionfolder = workspace.Terrain["EmittedPartsUsingPart_icle"]
	else
		emissionfolder = Instance.new('Folder')
		emissionfolder.Name = "EmittedPartsUsingPart_icle"
		emissionfolder.Parent = workspace.Terrain
	end
	return emissionfolder
end
function Beam:Emit(beam : Instance)
	if beam:IsA('Beam') and beam:GetAttribute('Transformed') then
		local Factors = beam:FindFirstChild('Factors') :: Folder
		if not Factors then return end

		-- Helper function to check if a NumberSequence is a static value or a graph
		local function isStatic(sequence)
			return not sequence or #sequence.Keypoints <= 1
		end

		-- Helper function to get the value from a static NumberSequence
		local function getStaticValue(sequence, defaultValue)
			if not sequence or #sequence.Keypoints == 0 then
				return defaultValue
			else
				return sequence.Keypoints[1].Value
			end
		end

		local emissionfolder
		if workspace.Terrain:FindFirstChild('EmittedPartsUsingPart_icle') then
			emissionfolder = workspace.Terrain["EmittedPartsUsingPart_icle"]
		else
			emissionfolder = Instance.new('Folder')
			emissionfolder.Name = "EmittedPartsUsingPart_icle"
			emissionfolder.Parent = workspace.Terrain
		end

		local Properties = Factors:FindFirstChild('Properties') :: Folder
		local GraphBlender = Factors:FindFirstChild('GraphBlender') :: Folder
		local KeyFrames = Factors:FindFirstChild('TotalKeyFrames') :: NumberValue
		local LifeTime = Factors:FindFirstChild('LifeTime') :: ParticleEmitter

		beam = beam:Clone()


		-- Table of all NumberSequence-based properties to check
		local propertyObjects = {
			Brightness = Properties:FindFirstChild('Brightness'),
			CurveSize0 = Properties:FindFirstChild('CurveSize0'),
			CurveSize1 = Properties:FindFirstChild('CurveSize1'),
			Width0 = Properties:FindFirstChild('Width0'),
			Width1 = Properties:FindFirstChild('Width1'),
			LightEmission = Properties:FindFirstChild('LightEmission'),
			Segments = Properties:FindFirstChild('Segments'),
			TextureLength = Properties:FindFirstChild('TextureLength'),
			TextureSpeed = Properties:FindFirstChild('TextureSpeed'),
		}

		local animatedProperties = {} -- Will hold graphs that need animating

		for name, object in pairs(propertyObjects) do
			if object then
				--  check the .Size property as that's what's typically used
				local sequence = object.Size

				if isStatic(sequence) then
					-- This is a STATIC property, set it once and forget it.
					local value = getStaticValue(sequence, beam[name]) -- Use beam's current value as default
					--print(name .. " is static. Setting value to: " .. tostring(value))
					beam[name] = value
					print(name, ': is now', beam[name], 'or', value)
				else
					-- This is an ANIMATED property, prepare it for the loop.
					--print(name .. " is a graph. Preparing for animation.")
					local seeds = GraphMod.GenerateSeeds(sequence, 20)
					animatedProperties[name] = {
						Sequence = sequence,
						Seed = seeds[math.random(1, 20)]
					}
				end
			end
		end

		-- The Color and Transparency blending is always considered animated.
		local ColorGraphs = GraphBlender:FindFirstChild('ColorGraphs') :: Folder
		local TransparencyGraphs = GraphBlender:FindFirstChild('TransparencyGraphs') :: Folder

		local Time = RangeMod.RandomValueFromRange(LifeTime.Lifetime)

		local ColorKgs, TransparencyKgs = {}, {}
		for _, v in pairs(TransparencyGraphs:GetChildren()) do table.insert(TransparencyKgs, v) end
		for _, v in pairs(ColorGraphs:GetChildren()) do table.insert(ColorKgs, v) end
		table.sort(TransparencyKgs, function(a, b) return a.Name < b.Name end)
		table.sort(ColorKgs, function(a, b) return a.Name < b.Name end)
		-- (Duration scaling logic would go here if needed)

		local currentcolorindex = 1
		local currentcolorgraph = ColorKgs[currentcolorindex]
		local currentTransparencyIndex = 1
		local currentTransparencygraph = TransparencyKgs[currentTransparencyIndex]

		beam.Enabled = true
		beam.Parent = emissionfolder

		-- =================================================================
		-- Animation Loop
		-- =================================================================

		task.spawn(function()
			local startTime = tick()
			local currentStep = 0
			local totalSteps = 100

			local colorBlendStartTime = 0
			local transparencyBlendStartTime = 0

			if KeyFrames and KeyFrames.Value > 0 then
				totalSteps = KeyFrames.Value
			end

			local connection
			connection = RunService.Heartbeat:Connect(function()
				local elapsedTime = tick() - startTime
				local i = elapsedTime / Time

				if i > 1 or not beam.Parent then
					connection:Disconnect()
					if beam and beam.Parent then beam:Destroy() end
					return
				end

				local targetStep = math.floor(i * totalSteps)
				if targetStep > currentStep then
					currentStep = targetStep
					i = currentStep / totalSteps

					-- Update Color and Transparency (always animated)
					if currentTransparencygraph and currentTransparencygraph.DurationOfBlend then
						local durationTransparency = currentTransparencygraph.DurationOfBlend.Value
						if elapsedTime > transparencyBlendStartTime + durationTransparency then
							if TransparencyKgs[currentTransparencyIndex + 1] then
								transparencyBlendStartTime += durationTransparency
								currentTransparencyIndex += 1
								currentTransparencygraph = TransparencyKgs[currentTransparencyIndex]
							end
						end

						local durationColor = currentcolorgraph.DurationOfBlend.Value
						if elapsedTime > colorBlendStartTime + durationColor then
							if ColorKgs[currentcolorindex + 1] then
								colorBlendStartTime += durationColor
								currentcolorindex += 1
								currentcolorgraph = ColorKgs[currentcolorindex]
							end
						end

						local TransparencyBlendGraph = currentTransparencygraph.Transparency.Transparency
						local TransparencySpeedGraph = currentTransparencygraph.BlendSpeed.Transparency
						beam.Transparency = GraphMod.BlendGraphWithTime(beam.Transparency, TransparencyBlendGraph, TransparencySpeedGraph, i)

						local colorBlendGraph = currentcolorgraph.Color.Color
						local colorSpeedGraph = currentcolorgraph.BlendSpeed.Transparency
						beam.Color = GraphMod.BlendColorGraphWithTime(beam.Color, colorBlendGraph, colorSpeedGraph, i)

					end


					for name, data in pairs(animatedProperties) do
						local value = GraphMod.QueryPointsWithTime(i, data.Sequence, data.Seed)
						beam[name] = value
					end

				end
			end)
		end)
	end
end
-- use graphs in beam to play the thing within it
function Beam:EnableEmit(obj: Instance)
	if obj:IsA("Beam") then
		if obj:GetAttribute("EmitDelay") then
			task.delay(obj:GetAttribute('EmitDelay'),function()
				Beam:Emit(obj)
			end)
		end
	end
end
function Particle:Transform(part :Instance)
	if part:IsA('Beam') then
		local PartLayout = pluginscript.Layouts.Beam.Factors:Clone()
		PartLayout.Parent = part
		part:SetAttribute('Transformed',true)
		part:SetAttribute('EmitCount',1)
		part:SetAttribute('EmitDuration',0)
		part:SetAttribute('EmitDelay',0)
		part:SetAttribute('IsEmitter',true)
	elseif part:IsA('Part')or part:IsA('MeshPart') then
		local PartLayout = pluginscript.Layouts.Part.Factors:Clone()
		PartLayout.Parent = part
		part:SetAttribute('Transformed',true)
		part:SetAttribute('EmitCount',0)
		part:SetAttribute('EmitDuration',0)
		part:SetAttribute('EmitDelay',0)
		part:SetAttribute('IsEmitter',true)
	end
end
function Particle:Emit(part : Part, parent) -- parent may be nil
	if part:FindFirstChild('Factors') then

		local WorldDirections = {
			[Enum.NormalId.Top] = part.CFrame.UpVector,
			[Enum.NormalId.Bottom] = -part.CFrame.UpVector,
			[Enum.NormalId.Front] = part.CFrame.LookVector,
			[Enum.NormalId.Back] = -part.CFrame.LookVector,
			[Enum.NormalId.Left] = -part.CFrame.RightVector,
			[Enum.NormalId.Right] = part.CFrame.RightVector,
		}

		local SpecialMesh = part:FindFirstChildOfClass('SpecialMesh') :: SpecialMesh
		local Decal = part:FindFirstChildOfClass('Decal') :: Decal

		local Factors = part:FindFirstChild('Factors') :: Folder
		local KeyFrames = Factors:FindFirstChild('TotalKeyFrames')
		local FlipbookFolder = Factors:FindFirstChild('MeshFlipbooks')
		local particle = Factors:FindFirstChild('Main') :: ParticleEmitter
		local VelocityVectored = Factors:FindFirstChild('VelocityVectored') :: BoolValue
		local Brightness = Factors:FindFirstChild('Main') :: ParticleEmitter

		local Size = Factors:FindFirstChild('Size') :: Folder
		local SizeX = Size:FindFirstChild('X') :: ParticleEmitter
		local SizeY = Size:FindFirstChild('Y') :: ParticleEmitter
		local SizeZ = Size:FindFirstChild('Z') :: ParticleEmitter

		local Rotation = Factors:FindFirstChild('Rotation') :: Folder
		local RotationX = Rotation:FindFirstChild('X') :: ParticleEmitter
		local RotationY = Rotation:FindFirstChild('Y') :: ParticleEmitter
		local RotationZ = Rotation:FindFirstChild('Z') :: ParticleEmitter

		local RotationSpeed = Factors:FindFirstChild('RotationSpeed') :: Folder
		local RotationSpeedX = RotationSpeed:FindFirstChild('X') :: ParticleEmitter
		local RotationSpeedY = RotationSpeed:FindFirstChild('Y') :: ParticleEmitter
		local RotationSpeedZ = RotationSpeed:FindFirstChild('Z') :: ParticleEmitter

		local Speed = Factors:FindFirstChild('Main') :: ParticleEmitter

		local BrightnessSeeds = GraphMod.GenerateSeeds(Brightness.Size,20)

		local SizeXSeeds = GraphMod.GenerateSeeds(SizeX.Size, 20)
		local SizeYSeeds = GraphMod.GenerateSeeds(SizeY.Size, 20)
		local SizeZSeeds = GraphMod.GenerateSeeds(SizeZ.Size, 20)

		local RotationSpeedXSeeds = GraphMod.GenerateSeeds(RotationSpeedX.Squash, 20)
		local RotationSpeedYSeeds = GraphMod.GenerateSeeds(RotationSpeedY.Squash, 20)
		local RotationSpeedZSeeds = GraphMod.GenerateSeeds(RotationSpeedZ.Squash, 20)

		local SpeedSeeds = GraphMod.GenerateSeeds(Speed.Squash,20)

		local transparencySeeds = GraphMod.GenerateSeeds(particle.Transparency, 20)

		local seedIndex = math.random(1, 20)

		local chosenBrightnessSeed = BrightnessSeeds[seedIndex]

		local chosenSizeXSeed = SizeXSeeds[seedIndex]
		local chosenSizeYSeed = SizeYSeeds[seedIndex]
		local chosenSizeZSeed = SizeZSeeds[seedIndex]

		local chosenRotSpeedXSeed = RotationSpeedXSeeds[seedIndex]
		local chosenRotSpeedYSeed = RotationSpeedYSeeds[seedIndex]
		local chosenRotSpeedZSeed = RotationSpeedZSeeds[seedIndex]

		local chosenSpeedSeed = SpeedSeeds[seedIndex]

		local chosenTransparencySeed = transparencySeeds[seedIndex]

		local Time = RangeMod.RandomValueFromRange(particle.Lifetime)
		local RX = RangeMod.RandomValueFromRange(RotationX.Rotation)
		local RY = RangeMod.RandomValueFromRange(RotationY.Rotation)
		local RZ = RangeMod.RandomValueFromRange(RotationZ.Rotation)

		part.Locked = true
		part:SetAttribute('IsEmitter',false)

		for i,v in part:GetDescendants() do
			if v:IsA('ParticleEmitter') then
				v.Enabled = false
			end
		end
		for i,v in part:GetChildren() do
			if v:IsA('Attachment') then
				ParticlesMod.EnableEmitChildrenAndRepeatForAttachments(v)
			end
			ParticlesMod.EnableEmitSingle(v)
		end

		if Decal then
			MeshFlipMod.Flip(particle,FlipbookFolder,Decal,Time)
		end

		-- shape offset handling (unchanged)
		if particle.ShapeInOut == Enum.ParticleEmitterShapeInOut.InAndOut then
			local shapeFunc = shapeFunctions[particle.Shape]
			if shapeFunc then
				local localOffset, localrott = shapeFunc(part, particle)
				if typeof(localrott) == "CFrame" and particle.ShapeStyle == Enum.ParticleEmitterShapeStyle.Surface then
					local rx, ry, rz = part.CFrame:ToEulerAnglesXYZ()
					part:PivotTo(CFrame.new((part.CFrame * CFrame.new(localOffset)).Position) * localrott * CFrame.Angles(rx, ry, rz))
				else
					part:PivotTo(CFrame.new((part.CFrame * CFrame.new(localOffset)).Position) * part.CFrame.Rotation)
				end
			end
		end
		if SpecialMesh then
			SpecialMesh.Scale = Vector3.new(0,0,0)
		else
			part.Size = Vector3.new(0,0,0)
		end
		-- initial random rotation
		part.CFrame = part.CFrame * CFrame.Angles(math.rad(RX), math.rad(RY), math.rad(RZ))

		-- store current world position (used by the motion integrator)
		local currentPosition = part.Position
		local emissionDirection = particle.EmissionDirection

		local baseDirection
		if VelocityVectored.Value == false then
			baseDirection = WorldDirections[emissionDirection]
		else
			local dirinfo = DirectionVectors[emissionDirection] or DirectionVectors[Enum.NormalId.Top]
			baseDirection = part.CFrame[dirinfo.vector] * dirinfo.multiplier
		end

		local spreadAngle = particle.SpreadAngle
		local randomX = 0
		local randomY = 0
		if spreadAngle.X > 0 or spreadAngle.Y > 0 then
			randomX = (math.random() * 2 - 1) * spreadAngle.X
			randomY = (math.random() * 2 - 1) * spreadAngle.Y
			local cf = CFrame.lookAt(Vector3.new(), baseDirection)
			cf = cf * CFrame.Angles(math.rad(randomX),math.rad(randomY), 0)
			baseDirection = cf.LookVector
		end
		local spreadRotation = CFrame.Angles(
			math.rad(randomX),
			math.rad(randomY),
			0)

		local initialSpeed = GraphMod.QueryPointsWithTime(0.1, Speed.Squash, chosenSpeedSeed)
		local velocity = baseDirection * initialSpeed
		local accelerationVector = particle.Acceleration

		-- === parent-relative setup ===
		local parentCF_init = parent and parent.CFrame or CFrame.new()
		-- localCF is the transform of the part relative to its parent (parent may be nil)
		local localCF = parent and parentCF_init:ToObjectSpace(part.CFrame) or part.CFrame
		-- currentPosition is the part's world position (we already have it),
		-- it will be used to compute worldDelta each frame.

		task.spawn(function()
			local startTime = tick()
			local currentStep = 0
			local totalSteps = 100
			if KeyFrames and KeyFrames.Value and KeyFrames.Value > 0 then
				totalSteps = KeyFrames.Value
			end

			local connection
			connection = RunService.Heartbeat:Connect(function(dt)
				local elapsedTime = tick() - startTime
				local i = elapsedTime / Time

				if i >= 1 or currentStep >= totalSteps then
					local partlife = Factors:FindFirstChild('PartLife')
					if partlife ~= nil then
						task.delay(Factors.PartLife.Value or 0, function()
							part:Destroy()
						end)
					else
						part:Destroy()
					end
					connection:Disconnect()
					return
				end

				local targetStep = math.floor(i * totalSteps)
				if targetStep > currentStep then
					currentStep = targetStep
					task.spawn(function()
						local brightness = GraphMod.QueryPointsWithTime(i, Brightness.Size, chosenBrightnessSeed)
						local sizex = GraphMod.QueryPointsWithTime(i, SizeX.Size, chosenSizeXSeed)
						local sizey = GraphMod.QueryPointsWithTime(i, SizeY.Size, chosenSizeYSeed)
						local sizez = GraphMod.QueryPointsWithTime(i, SizeZ.Size, chosenSizeZSeed)
						local RotSpeedx = GraphMod.QueryPointsWithTime(i, RotationSpeedX.Squash, chosenRotSpeedXSeed)
						local RotSpeedy = GraphMod.QueryPointsWithTime(i, RotationSpeedY.Squash, chosenRotSpeedYSeed)
						local RotSpeedz = GraphMod.QueryPointsWithTime(i, RotationSpeedZ.Squash, chosenRotSpeedZSeed)
						local MeshSpeed = GraphMod.QueryPointsWithTime(i, Speed.Squash, chosenSpeedSeed)
						local transparency = GraphMod.QueryPointsWithTime(i, particle.Transparency, chosenTransparencySeed)
						local color = GraphMod.QueryColorPointWithTime(i, particle.Color) :: Color3

						local currentTime = i -- progress, 0-1 val.
						-- independent motion calculation (same as before)
						local accelerationOffset = accelerationVector * currentTime
						local draggedSpeed = MeshSpeed * math.exp(-particle.Drag * currentTime)

						local newPosition = currentPosition
							+ (baseDirection * draggedSpeed * (dt *10) )
							+ (accelerationOffset * (dt *10))

						-- rotation from rotSpeed (rotates in local part space)
						local rotationCFrame = CFrame.Angles(
							math.rad(RotSpeedx),
							math.rad(RotSpeedy),
							math.rad(RotSpeedz)
						)
						-- compute world delta produced by independent motion this frame
						local worldDelta = newPosition - currentPosition

						-- get current parent CFrame (parent can move)
						local parentCF_now = parent and parent.CFrame or CFrame.new()
						-- convert the world delta into parent-local coordinates
						local parentLocalDelta = parentCF_now:VectorToObjectSpace(worldDelta)

						-- update the stored localCF:
						-- newLocalCF = CFrame.new(parentLocalDelta) * localCF * rotationCFrame
						-- This yields: partWorld = parentCF_now * newLocalCF = CFrame.new(worldDelta) * partWorldOld * rotationCFrame
						-- which matches original intention: translate by worldDelta then rotate by rotationCFrame
						localCF = CFrame.new(parentLocalDelta) * localCF

						-- apply final world CFrame (parentCF * localCF)
						part.CFrame = parentCF_now * localCF
						part.CFrame = part.CFrame * rotationCFrame

						-- update currentPosition to the part's new world position (keeps integration stable)
						currentPosition = part.Position

						-- size scaling & color/transparency (unchanged)
						if SpecialMesh then
							SpecialMesh.Scale = Vector3.new(sizex, sizey, sizez)
						else
							part.Size = Vector3.new(sizex, sizey, sizez)
						end

						if Decal then
							Decal.Transparency = transparency
							Decal.Color3 = Color3.fromRGB(
								color.R * 255 * brightness,
								color.G * 255 * brightness,
								color.B * 255 * brightness
							)
						else
							part.Transparency = transparency
							part.Color = color
						end

						-- velocity-based direction adjustment
						if VelocityVectored.Value == true then
							local rotatedCF = part.CFrame * spreadRotation
							local dirInfo = DirectionVectors[emissionDirection] or DirectionVectors[Enum.NormalId.Top]
							baseDirection = rotatedCF[dirInfo.vector] * dirInfo.multiplier
						end
					end)
				end
			end)
		end)
	end
end
function Particle:Enable(part: Part,parent)
	if part:FindFirstChild('Factors') then

		_G["Part_Icles"]["EnableAllowed"] = false

		local Factors = part:FindFirstChild('Factors') :: Folder
		local particle = Factors:FindFirstChild('Main') :: ParticleEmitter
		local Enabled = Factors:FindFirstChild('Enabled') :: BoolValue
		local EWRTE = Factors:FindFirstChild('EnableWithRespectToEnable'):: BoolValue

		local Folder = Particle:GetFolder()
		if self.EnabledParts[part] then
			task.cancel(self.EnabledParts[part])
			self.EnabledParts[part] = nil
		end
		self.EnabledParts[part] =
			task.spawn(function()

				local function cleanup()
					_G["Part_Icles"]["EnableAllowed"] = true
					self.EnabledParts[part] = nil
				end

				if not Enabled.Value then
					cleanup()
					return
				end

				if EWRTE and EWRTE.Value == true then
					while Enabled.Value == true do 
						part = part:Clone()
						self:Emit(part,parent)
						part.Parent = Folder
						task.wait(1/particle.Rate)
					end
					_G["Part_Icles"]["EnableAllowed"] = true
				else
					while Enabled.Value == true do 
						local clone = part:Clone()
						self:Emit(clone,parent)
						clone.Parent = Folder
						task.wait(1/particle.Rate)
					end
					_G["Part_Icles"]["EnableAllowed"] = true
				end
				cleanup()
			end)
	else
		warn(part.Name..'- is not Transformed')
	end
end
function Particle:EnableEmit(part) -- does a proper emission, based on emit count, delay and duration. part will be cloned within it
	local Factors = part:FindFirstChild('Factors')
	if Factors then
		if part:IsA("Beam") then
			Beam:EnableEmit(part)
		else
			local noOFemits = part:GetAttribute('EmitCount') or 0
			local emitDelay = part:GetAttribute('EmitDelay') or 0
			local emitDuration = part:GetAttribute('EmitDuration') or 0
			local EnabledProperty = Factors:FindFirstChild('Enabled')
			local Folder = self:GetFolder()
			local Cloned = {}
			for i = 1,noOFemits do
				local p = part:Clone()
				Cloned[i]= p
			end
			task.delay(emitDelay,function()
				for i,v in Cloned do
					self:Emit(v)
					v.Parent = Folder
					self:EnableEmitChildren(v)
				end
				if emitDuration > 0 then
					EnabledProperty.Value = true
					self:Enable(part)
					task.wait(emitDuration)
					EnabledProperty.Value = false
				end
			end)
		end
	end
end
function Particle:EnableEmitChildren(parent)
	for i,v in parent:GetChildren() do
		local part = v 
		if v:GetAttribute("Transformed") then
			local Factors = part:FindFirstChild('Factors')
			if Factors then
				if part:IsA("Beam") then
					Beam:EnableEmit(part)
				else
					local noOFemits = part:GetAttribute('EmitCount') or 0
					local emitDelay = part:GetAttribute('EmitDelay') or 0
					local emitDuration = part:GetAttribute('EmitDuration') or 0
					local EnabledProperty = Factors:FindFirstChild('Enabled')
					local Folder = self:GetFolder()
					local Cloned = {}
					for i = 1,noOFemits do
						local p = part:Clone()
						Cloned[i]= p
					end
					task.delay(emitDelay,function()
						for i,cc in Cloned do
							self:Emit(cc,parent)
							self:EnableEmitChildren(cc,v)
							cc.Parent = Folder
						end
						if emitDuration > 0 then
							EnabledProperty.Value = true
							self:Enable(part,parent)
							task.wait(emitDuration)
							EnabledProperty.Value = false
						end
					end)
				end
			end
		end
	end
end
function Particle:_RecurCheck(obj: Instance) -- Loop through a parent that is not a transformed parent, and find transformed parts in them and emit it.
	for _, v in obj:GetChildren() do
		if v:GetAttribute("Transformed") then
			self:EnableEmit(v)
		else
			self:_RecurCheck(v) -- drill until we hit a transformed child
		end
	end
end
function Particle:AbsoluteEmit(Object: Instance)
	-- if object itself is transformed, emit it and layer its children
	if Object:GetAttribute("Transformed") then
		self:EnableEmit(Object)
	else
		-- otherwise, recurse into its children until we find transformed ones
		self:_RecurCheck(Object)
		for i,v in Object:GetChildren() do
			if v:IsA("BasePart") and v:GetAttribute("Transformed") == nil then
				ParticlesMod.EnableEmit(v)
			end
		end
	end
end

return Particle
