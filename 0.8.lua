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
  execute {cmd="source " .. script, modeA={"load"}}
  execute {cmd="echo '' >&2", modeA={"load"}}
  execute {cmd="echo 'Fast Module Loading activated.' >&2", modeA={"load"}}
  execute {cmd="echo Note: to turn off Fast Module Loading, do 'module purge' or 'module unload fml'  >&2", modeA={"load"}}

  execute {cmd = "__fml_exit", modeA = {"unload"}}
else
  execute {cmd="echo 'FML: sorry, this is not implemented for shell type ".. myShellType() .. "' >&2", modeA={"load"}}
end
