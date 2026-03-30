help([==[

Description
===========
Module Loader-Quick (for lmod)

More information
================
 - Homepage: https://github.com/cvsindelar/mlq
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
  execute {cmd="echo 'Blarch: ".. myShellType() .. "' >&2", modeA={"load"}}

else
  execute {cmd="echo 'FML: sorry, this is not implemented for shell type ".. myShellType() .. "' >&2", modeA={"load"}}

--   -- tcsh/sh: do the corresponding things with aliases
--   -- execute {cmd="echo alias module 'eval `bash " .. script .. "\!*`'", modeA={"load"}}
--   -- persuade lua to execute the following csh command:
--   --    alias module 'eval `bash fml.sh \!*`'
--   -- To do: 'ml reset' fails due to '__fml_orig_module: Command not found' (2x)
--   execute {cmd="set __fml_orig_module_code=\"`alias module`\"", modeA={"load"}}
--   execute {cmd="alias __fml_orig_module \"$__fml_orig_module_code\"", modeA={"load"}}
--   execute {cmd="alias module 'eval `bash " .. script .. " csh \\!*`'", modeA={"load"}}
--   
--   execute {cmd ="unalias module", modeA = {"unload"}}
--   execute {cmd="alias module \"$__fml_orig_module_code\"", modeA={"unload"}}
--   execute {cmd="unset __fml_orig_module_code", modeA={"unload"}}
--   execute {cmd="unalias __fml_orig_module", modeA={"unload"}}
end
