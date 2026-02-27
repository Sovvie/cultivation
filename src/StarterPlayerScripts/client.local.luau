local StarterPlayer = game:GetService("StarterPlayer")
for _, child in StarterPlayer.StarterPlayerScripts:GetChildren() do
    child:Destroy()
end
