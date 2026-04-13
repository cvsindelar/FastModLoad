help([==[

Description
===========
Fast Module Loader for Lmod

More information
================
 - Homepage: https://github.com/cvsindelar/fml
]==])

whatis([==[Description: Fast Module Loader for Lmod-Based HPC Software Stacks]==])
whatis([==[Homepage: https://github.com/cvsindelar/FastModLoad]==])
whatis([==[URL: https://github.com/cvsindelar/FastModLoad]==])

local root = "/vast/palmer/home.mccleary/cvs2/programs/FastModLoad"
local script = pathJoin(root, "fml.sh")

if myShellType() == "sh" then
  -- execute {cmd="eval \"$( bash " .. script .. " init " .. pathJoin(myModuleName(), myModuleVersion()) .. " )\" ", modeA={"load"}}
  execute {cmd="eval \"$( bash " .. script .. " " .. myFileName() .. " init " .. " )\" ; ", modeA={"load"}}

  execute {cmd="eval $( bash " .. script .. " " .. myFileName() .. " exit " .. " ) ; ", modeA={"unload"}}
else
  execute {cmd="echo 'FML: sorry, this is not implemented for shell type ".. myShellType() .. "' >&2", modeA={"load"}}
end
