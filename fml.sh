######################
# FastModLoad: Fast Module Loader for Lmod-Based HPC Software Stacks
# Chuck Sindelar, Yale Center for Research Computing (March 2026)

# Remaining features to implement:
# 0. Final intended use case:
#  - HPC curated list of 'safe' fast modules
#  - User can force fast module loading of new environments with --fml
#  - User can revert to ordinary module loading with --ml
# 1. Auto-rebuilding out of date fast modules
# 3. --fmldebug to mirror lines output by __fml_load
# 4. "module list" -> prints the archived output of the original module load
#    "module --<any option> list -> prints the raw lmod 'module list' results
# 5. --fmlinstall to copy fast module builds to the global directory, if user has write permissions.
# 6. Auto-deleting local fast module builds when they are identical to the global builds
#    (works for all users, minimizes file count burden on the filesystem)
# 7. __fml_unpack upon unloading fml (find the solution for the bug which has been identified)
# 8. instead of saving external functions, execute 'fml.sh load ...', 'fml.sh unload ...' and 'fml.sh exit'
# 9. Safety: define new module function in the fml/2.0beta.lua upon 'load', using set_shell_function
#    and embed the original module code inside, to be unloaded on 'unload'
#    Improve safety by redefining 'module' to the original lmod function during __fml_load execution?
#      -> this line:
#          eval $(__fml_load "${@:1}")
#      -> goes to:
#          eval "${__fml_orig_module_code}" ; eval $(__fml_load "${@:1}") ; eval "${__fml_module_code}"
#      -> Also, 
#    Successful completion of fml module restores fml module.
# 10. Implement tcsh/csh functionality ; 
#     for embedding originals in tcsh/csh aliases, the following should work:
#     set my_backup = "`alias module`"
#     Redefine it later using the variable
#     alias module "$my_backup"
#    The trick for #9, safety feature redefining 'module' within 'module' could possibly be
#     based on the following:
#     The bash equivalent for eval "${__fml_orig_module_code}" 
#     https://share.google/aimode/tdCNo8LcF5JhUzRq1
#     alias module 'echo "ORIG"; alias myfunc "echo FML"; eval myfunc'
# 11. Implement functionality to reconstruct already loaded slow environments
#    -> kludge for R: detect if any of the requested modules does not wind up
#       in the loaded list. If so, generate the corresponding complete fml name
#       and copy the contents of the incompletely named fml to it
# 12. using miniconda fast module, activating a module that does 'module load' in its
#    activate.d fails the first time around (env is not activated)
#    This is because after loading the second module, fml reverts to slow module loading-
#     therefore, it unloads the miniconda fast module in the midst of a conda activate command!!
#    At least, it succeeds with the second try because the slow environment was restored (!).
#    Example: /home/cvs2/.conda/envs/fil_new/etc/conda/activate.d/env_vars.sh
#    ml fml/2 ; export FML_THRESH=0 ; ml miniconda ; ml reset ; ml miniconda ; conda activate fil_new

######################

export FML_THRESH=10

# Comment out the below line if a friendly greeting is desired
export __fml_suppress_greeting=1

if [[ -z "$(declare -f module | grep 'fml')" ]] ; then
    # Change the name of lmod's 'module' function and save its code
    export __fml_orig_module_code=$(declare -f module)
    # Bash one-liner creates a renamed function using the saved code
    eval "__fml_orig_module${__fml_orig_module_code#module}"
else
    if [[ -z "${__fml_orig_module_code}" ]] ; then
        echo 'ERROR: the Fast Module Loader has bungled the lmod module environment!'
        echo 'Sorry, this should never happen.'
        echo 'To restore normal module functionality, please log out and log in again'
        return 1
    fi
fi

######################
# Function to unload the fml module
######################
function __fml_exit() {
    # Restore the original lmod 'module' function:
    if [[ -n "$(declare -f module | grep 'fml')" ]] ; then
        if [[ -n "${__fml_orig_module_code}" ]] ; then
            eval "${__fml_orig_module_code}"
        else
            echo 'ERROR: the Fast Module Loader lost track of the original module function!'
            echo 'Sorry, this should never happen'
            echo 'To restore normal module functionality, please log out and log in again'
            return 1
        fi
    fi

    old_fml_info=( $(__fml_get_loaded_fml) )
    old_fml_name="${old_fml_info[0]:-}"
    if [[ -n "${old_fml_name}" && "${old_fml_name}" != '0' ]] ; then
        __fml_orig_module unload "fml-${old_fml_name}"
    fi
    
    # TO FIX: the below line won't work, because the current fml_unpack also tries to restore fml
    #  (via the 'module restore' mechanism, because the saved module environments contain fml)
    #  which won't work during an unload of fml.

    # __fml_unpack    # Restore the 'slow' module environment if needed

    unset -f __fml_load
    unset -f __fml_build

    unset -f __fml_get_load_arguments
    unset -f __fml_get_load_info
    unset -f __fml_get_loaded_fml
    unset -f __fml_get_module_info
    unset -f __fml_unpack              

    unset -f __fml_orig_module
    unset __fml_orig_module_code
    unset __fml_suppress_greeting

    unset -f __fml_exit        
}    

######################
# Define the new module function, but only if the original lmod code was saved successfully
######################
if [[ -z "${__fml_orig_module_code}" ]] ; then
    echo 'ERROR: the Fast Module Loader cannot start!'
    echo 'Sorry, this should never happen'
    function __fml_exit() {
        unset -f __fml_load
        unset -f __fml_build

        unset -f __fml_get_load_arguments
        unset -f __fml_get_load_info
        unset -f __fml_get_loaded_fml
        unset -f __fml_get_module_info
        unset -f __fml_unpack              
        
        unset -f __fml_orig_module
        unset __fml_orig_module_code
        unset __fml_suppress_greeting

        unset -f __fml_exit        
    }
    module unload fml
    return 1
else
######################
# The module function, only more so
######################
    function module() {
        local runtime
        local __fml_build_request

        # echo debug $(__fml_load "${@:1}")
        eval $(__fml_load "${@:1}" )

        # Below we run the fml building function, IF there was no error in the
        #  requested lmod operations.
        # If perchance the above lmod operations unloaded fml however,
        #  the function will have been deleted, so we need to first test whether it still exists
        runtime=$( echo ${__fml_start:-} ${__fml_end:-} | awk '{print $2 - $1}' )
        if [[ "${runtime}" -ge $FML_THRESH ]] ; then
            echo 'Slow load time detected : '${runtime}' sec' 
            if [[ "${__fml_status:-}" -eq 0 \
                      && -n $(declare -f __fml_build) ]] ; then
                __fml_build
                return $?
            fi
        else
            if [[ -n "${__fml_build_request[@]}" ]] ; then
                echo 'Skipping fast module build; load time '"${runtime}"' did not exceed the threshold '"${FML_THRESH}"
            fi            
        fi
        
    }

    # function module() {
        # suppress the greeting with module reset/purge, when fml gets automatically unloaded/reloaded:
        # [[ " $@ " == *" reset "* || " $@ " == *" purge "* ]] && export __fml_suppress_greeting=1

        # local __fml_status
        # eval $(__fml_load "${@:1}")
        # __fml_status=$?
        # unset __fml_suppress_greeting
        # return $__fml_status
    # }
fi

######################
# Fast module loading: output of __fml_load() consists of printed 'module' commands
#  (but with 'module' substituted by __fml_orig_module')
######################
function __fml_load() {
    local get_fml_lua_script
    local fml_components
    local load_arguments
    local fml_info
    local requested_fml_name
    local requested_modfiles
    local old_fml_info
    local old_fml_name
    local old_fml_modfile
    local process_collection_lua_script
    local new_fml_name
    local build_lua_record
    
    ##################
    # lua script for extracting the list of module files, in the correct build order.
    # This obtains a list of lua modulefiles from an lmod-style module table (lua code)
    # Used to get 'ordered_module_list'
    ##################
    process_collection_lua_script='
    for key, subTable in pairs(_ModuleTable_.mT) do 
      if type(subTable) == "table" and subTable.fn then
        print(subTable.loadOrder, subTable.fn) 
      end 
    end '
        
    ##################
    # Bash command to save file info, including the full contents, size, and date,
    #  for the set of lua modulefiles that defines a shortcut; this is used 
    #  to test if any of them changed, meaning the shortcut should be rebuilt.
    # Bash code is saved in string form to be executed later.
    # When executed, it will require that the list of module files, $ordered_module_list, be set already.
    ##################
    build_lua_record="stat -c '%y'"' ${ordered_module_list[@]}; cat ${ordered_module_list[@]}'

    echo 'unset __fml_start ; '
    echo 'unset __fml_end ; '

    ######################
    # If "reset" is requested, reload fml after
    ######################
    if [[ " $@ " == *" reset "* ]] ; then
        get_fml_lua_script='for key, subTable in pairs(_ModuleTable_.mT) do
          if type(subTable) == "table" and subTable.fn then
            local prefix, suffix = subTable.fn:match("^(.-/)(fml/[^/]+)%.lua$")
            if prefix then
              print(prefix.." "..suffix)
            end
          end 
        end '

        fml_components=( $( (__fml_orig_module --mt ; echo "${get_fml_lua_script}" ) |&lua ) )
        
        # Perform the reset or purge command:
        echo "__fml_orig_module ${@:1} ; "
        # After fml is unloaded, we need to use the original 'module' commands to reload fml:
        echo "module use ${fml_components[0]} ;"
        echo "module load ${fml_components[1]} ;"
        return
    fi

    ######################
    # Set up fml load variables & check for errors
    ######################

    load_arguments=( $(__fml_get_load_arguments "${@:1}") )
    if [[ -z "${load_arguments[@]}" ]] ; then
        echo "__fml_orig_module ${@:1}"
        return
    fi

    old_fml_info=( $(__fml_get_loaded_fml) )
    old_fml_name="${old_fml_info[0]:-}"
    old_fml_modfile="${old_fml_info[2]:-}"

    # If old_fml_name returned an error code (integer less than 0) something went wrong (oooops)
    if [[ "${old_fml_info[0]:-}" =~ ^-?[0-9]+$ && "${old_fml_info[0]:-}" -lt 0 ]] ; then
        echo 'ERROR: Corrupted fml environment :' >&2
        __fml_orig_module list
        return
    fi
    
    # Loading slow modules on top of a fast module is not allowed, because it
    #  could lead to pathologies; detect and error out
    if [[ -n "${old_fml_name}" && "${old_fml_name}" != '0' && -n "${load_arguments[@]}" ]] ; then
        echo 'Additional module(s) : '"${load_arguments[@]}" >&2
        echo '  cannot be loaded on top of fast module '"fml-${old_fml_name}" >&2
        echo 'To load this environment as a fast module, do "module reset" and then' >&2
        echo '  load all your modules as a one-liner: "module load <mod1> <mod2> ..."' >&2
        return -1
    fi
        
    if [[ "${old_fml_info[0]:-}" == '0' ]] ; then # modules already present
        echo 'Loading additional modules with ordinary Lmod:'" ${load_arguments[@]}" >&2
        # echo '__fml_start=$(date +%s)' " ; __fml_orig_module ${@:1} ; " '__fml_status=$? ; __fml_end=$(date +%s) ; '
        echo "__fml_orig_module ${@:1} ; "
        echo 'To load this environment as a fast module, do "module reset" and then' >&2
        echo '  load all your modules as a one-liner: "module load <mod1> <mod2> ..."' >&2
        return
    fi
    
    fml_info=( $(__fml_get_load_info "${load_arguments[@]}" ) )

    if [[ -z "${fml_info[0]}" || "$?" -ne '0' ]] ; then
        echo 'FML did not recognize the requested modules; reverting to Lmod: module load '"${load_arguments[@]}" >&2
        echo "__fml_orig_module ${@:1}"
        return
    fi
    requested_fml_name="${fml_info[0]}"
    requested_modfiles="${fml_info[@]:1}"

    # If all modules have been requested unloaded, we are done
    if [[ -z "${requested_fml_name}" ]] ; then
        return
    fi

    ######################
    # Perform specialized load/unloading actions
    ######################

    fml_filename=~/.fml/${requested_fml_name}/fml-${requested_fml_name}.lua

    # Check if the module is out of date
    if [[ -f "${fml_filename}" ]] ; then
        if [[ -f ${fml_filename%.lua}.mt && -f ${fml_filename%.lua}.lua_record ]] ; then
            ordered_module_list=( $( (cat ${fml_filename%.lua}.mt ; \
                                      echo "${process_collection_lua_script}" ) \
                                     |& lua - | sort -n -k 1 \
                                     | awk '{n=split($2, a, "/") ; 
                                             if(a[n] != "StdEnv.lua" && a[n-1] != "fml") {
                                               print $2
                                             }}' ) )
            eval ${build_lua_record} | cmp ${fml_filename%.lua}.lua_record >& /dev/null
            update_needed="${status}"
        else
            update_needed=1
        fi
        
        if [[ "${update_needed}" -ne '0' ]] ; then
            echo 'Fast module seems to be out of date; rebuilding' >&2
        fi
    fi
        
    # Load the fast module if it exists.
    if [[ -f "${fml_filename}" && "${update_needed}" -eq '0' ]] ; then
        echo "Fast Module Loading : fml-${requested_fml_name}   (use 'module -fml' to disable)" >&2
        echo "__fml_orig_module use ~/.fml/${requested_fml_name} ; "
        echo "__fml_orig_module load fml-${requested_fml_name}"
    else
        if [[ "${update_needed}" -eq '0' ]] ; then
            echo 'Fast module check:'" ${load_arguments[@]}" >&2
        fi

        # Request a module load, also recording the time and exit status
        echo '__fml_start=$(date +%s) ; '
        echo "__fml_orig_module ${@:1} ; "
        echo '__fml_status=$? ; __fml_end=$(date +%s) ; '

        # Request a fast module build, if slow modules weren't previously present/loaded
        echo '__fml_build_request=( "'"${requested_fml_name}"'" "'"${fml_filename}"'" )'
    fi
}

######################
# Build the Fast Modules: this function is optionally called at the end of every
#  'module load' request, capturing the current module environment if
#  needed. No 'module' commands are invoked or requested by this function.
######################
function __fml_build() {
    local ordered_module_list
    local m
    local runtime
    local build_lua_record
    local process_collection_lua_script
    
    ##################
    # Bash command to save file info, including the full contents, size, and date,
    #  for the set of lua modulefiles that defines a shortcut; this is used 
    #  to test if any of them changed, meaning the shortcut should be rebuilt.
    # Bash code is saved in string form to be executed later.
    # When executed, it will require that the list of module files, $ordered_module_list, be set already.
    ##################
    build_lua_record="stat -c '%y'"' ${ordered_module_list[@]}; cat ${ordered_module_list[@]}'
    
    ##################
    # lua script for extracting the list of module files, in the correct build order.
    # This obtains a list of lua modulefiles from an lmod-style module table (lua code)
    # Used to get 'ordered_module_list'
    ##################
    process_collection_lua_script='
    for key, subTable in pairs(_ModuleTable_.mT) do 
      if type(subTable) == "table" and subTable.fn then
        print(subTable.loadOrder, subTable.fn) 
      end 
    end '
        
    runtime=$( echo ${__fml_start:-} ${__fml_end:-} | awk '{print $2 - $1}' )
    unset __fml_start
    unset __fml_end

    if [[ -z "${__fml_build_request[@]}" ]] ; then
        return
    fi
    
    fml_name="${__fml_build_request[0]}"
    fml_filename="${__fml_build_request[1]}"
    unset __fml_build_request
    
    ##################
    # Concatenate all the .lua files required by this collection,
    #  but strip out the 'depends_on' statements.
    #
    # This is predicated on 'module save' having generated a complete, self-consistent
    #  list of modules, with a defined build order that we will use when loading.
    #  (ordered_module_list is sorted on the build order).
    #
    # Each .lua code is wrapped by a 'do...done' statement to preserve
    #  independence of the local variables
    ##################
    
    mkdir -p $(dirname "${fml_filename}")
    # tmpfile1=$( mktemp -p $(dirname "${fml_filename}") )
    tmpfile1=$( mktemp ~/.config/lmod/fmltmpXXXXXXXXXX)
    tmpfile2=$( mktemp -p $(dirname "${fml_filename}") )
    tmpfile3=$( mktemp -p $(dirname "${fml_filename}") )
    
    __fml_orig_module --mt >& "${tmpfile1}"
    ordered_module_list=( $( (__fml_orig_module --mt ; echo "${process_collection_lua_script}" ) |&lua - | sort -n -k 1 | awk '{n=split($2, a, "/") ; if(a[n] != "StdEnv.lua" && a[n-1] != "fml") {print $2}}' ) )
    
    # Slow way for testing
    # echo module --redirect --width=1 save $(basename "${tmpfile1}")
    # module --redirect --width=1 save $(basename "${tmpfile1}") >& /dev/null
    # echo blarchity "${tmpfile1}"
    # ordered_module_list=(`( cat "${tmpfile1}" ; echo "${process_collection_lua_script}" ) | \
    #     lua - | sort -n -k 1 | awk '{print $2}' | grep -v 'StdEnv[.]lua$' | awk '$0 !~ "/fml/[^/]+[.]lua$"' | awk '$0 !~ "/fml[.]lua$"'`)
    # echo blarch blarch ${ordered_module_list[@]}
    
    eval "$build_lua_record" > "${tmpfile3}"

    printf '' > "${tmpfile2}"
    for m in ${ordered_module_list[@]}; do
        echo "do -- Scope for $m"
        # Skip all valid lua depends_on() statements, including with comments appended
        grep -E -v '^[[:space:]]*depends_on\([[:space:]]*"[^"]*"[[:space:]]*\)[[:space:]]*(--.*)?$' "$m"
        echo "end -- End scope for $m"
    done >> "${tmpfile2}"
    
    # In case there were previous versions present, possibly being written by someone else:
    #  make the updates atomic using the tmpfiles:
    /bin/mv "${tmpfile1}" "${fml_filename%.lua}.mt"
    /bin/mv "${tmpfile2}" "${fml_filename}"
    /bin/mv "${tmpfile3}" "${fml_filename%.lua}".lua_record
    echo 'Fast module updated : '"${fml_name}"

    # Now replace the slow-loading environment with the fast module
    module reset >& /dev/null
    module use $(dirname "${fml_filename}")
    # We shouldn't use the fml 'module function to load the fast module,
    #  because this could lead to pathologies. In particular, if the fast
    #  module loads too slow, it will get flagged for building into another
    #  fast module, which would presumably also get flagged, in an
    #  infinite recursion. This was confirmed (well, discovered) in testing.
    __fml_orig_module load $(basename "${fml_filename%.lua}")
}

function __fml_unpack() {
    local tmpfile
    local status
    local fml_file

    if [[ $# -gt 0 ]] ; then        
        fml_file="$1"
    else
        # with no arguments given, get the loaded fast module if present
        fml_info=( $(__fml_get_loaded_fml) )
        fml_name=${fml_info[0]}
        fml_file=${fml_info[2]}

        # If no fast module present, there is nothing to do
        if [[ -z "${fml_file}" ]] ; then
            return
        fi
        if [[ -n "${fml_name}" && "${fml_info[0]}" != '0' ]] ; then # fast modules present
            __fml_orig_module unload fml-${fml_name}
        fi
    fi
    mt_file="${fml_file%.lua}.mt"
    
    # Create a unique temporary file
    mkdir -p ~/.config/lmod
    tmpfile=$( mktemp -p ~/.config/lmod fmlXXXXXXXXXX )
    /bin/cp "${mt_file}" "${tmpfile}"
    __fml_orig_module restore $(basename "${tmpfile}")  >& /dev/null
    status=$?

    if [[ "${status}" -ne 0 ]] ; then
        echo 'fml internal failure: Failed to restore original module environment :'
        echo ' -> ' $2
    fi
    
    /bin/rm "${tmpfile}"
    [[ "${status}" -ne 0 ]] && return "${status}"
}

function __fml_get_load_arguments() {
    local load_arguments
    
    load_arguments=( $(echo "${@:1}" | awk '{
         for(i=1; i<=NF; ++i) {
            if(printargs)
               args = args " " load_prefix $i;
            if($i != "load" && $i != "unload" && $i !~ /^-/ && !load_cmd) {
              exit
            }
            if( ($i == "load" || $i == "unload") && !load_cmd) {
               load_cmd=1;
               printargs=1;
               if($i == "unload" && !load_cmd)
                 load_prefix="-" ;
            }
            if($i ~ "^-fml(|[/])")
               printargs=0;
          }
         }
         END {if(printargs) print(args)}') )
    echo "${load_arguments[@]}"
}

function __fml_get_loaded_fml() {
    local get_short_loaded_lua
    local old_fml_name
    
    # Get a list of all currently loaded modulefiles
    get_short_loaded_lua='
      for k,v in pairs(_ModuleTable_.mT) do 
        if type(v)=="table" and v.fn then 
          print(v.loadOrder, v.fn)
        end 
      end'

    # Below: check if a fast module fml-xxx is loaded.
    # Returns info on the fast module if present.
    # Returns '0' if 'slow modules' are present instead.
    # Returns '-1' if there was a problem
    #   Detected problems include:
    #    - multiple fast fml-xxx modules
    #    - or slow modules are coexisting with a fast fml-xxx module.
    old_fml_name=( $( (__fml_orig_module --mt ; echo "${get_short_loaded_lua}") \
                               |& lua - | sort -n -k 1 | awk '
                                  {
                                   n=split($2, a, "/");
                                   if($2 ~ "[/]fml-.+lua$") {
                                     if(fml) 
                                       {print(-2, $2, fml); finished=1 ; exit}
                                     else
                                       fml=substr(a[n],length("fml-")+1, length(a[n])-length("fml-")-length(".lua"));
                                       fmldir=a[n-1];
                                       fmlfile=$2;
                                   } else {
                                     if(a[n] != "StdEnv.lua" && a[n-1] != "fml") {
                                       if(fml)
                                         {print(-1, $2); finished=1 ; exit}
                                       else
                                         slowmod=1;
                                     }
                                   }
                                  }
                                  END {
                                    if(!finished) {
                                      if(slowmod) {
                                        if(fml)
                                           {print(-1, $2); exit}
                                        else
                                          print(0);
                                      } else
                                        print(fml, fmldir, fmlfile);
                                    }
                                  }') )    
    echo "${old_fml_name[@]}"
    return
}

function __fml_get_load_info() {

    local module_info
    local load_arguments
    local requested_modfiles
    local get_short_loaded_lua
    local new_fml_part
    local status

    # If no requested modules, return nothing
    if [[ $# -eq 0 ]] ; then
        return
    fi

    load_arguments=
    requested_modfiles=
    for arg in "${@:1}" ; do
        module_info=( $(__fml_get_module_info ${arg}) )
        status="$?"
        # if [[ -z "${module_info[@]}" || "${status}" -ne 0 ]] ; then
        #     return -1
        # fi

        load_arguments=( ${load_arguments[@]} ${module_info[0]} )
        requested_modfiles=( ${requested_modfiles[@]} ${module_info[1]} )
    done

    # If we can't find all the requested modules, flag an error
    if [[ ${#requested_modfiles[@]} -ne $# ]] ; then
        return -1
    fi

    # Concatenate the list of requested modules into an 'fml name'
    new_fml_part=$( (echo ${load_arguments[@]} ) \
                  | awk '{ for(ind=1; ind <= NF; ++ind) {
                             n=split($ind, a, "/");
                             if(nextarg) {
                                 printf("___");
                             }
                             module_name=a[n-1];
                             version=a[n];
                             sub(/\.lua$/, "", version);
                             if(a[1] == "-") {
                               printf("-");
                             }
                             printf(module_name "_" version);
                             nextarg=1;
                           }
                         }')
    
    echo ${new_fml_part} ${requested_modfiles[@]}
}

######################
# Get the full module name including the version; if version is missing, fill in
#  the default version if possible.
# Also returns the module filename. The source for all this is lmod's 'module --location show'
######################
function __fml_get_module_info() {
    if [[ $# -ne 1 ]] ; then
        return
    fi

    local mod
    local mod_prefix
    local modfile
    
    # Below: strip spaces out of our arguments, in case ahem OnDemand gives space-ful ones
    mod=$(echo $1)
    # Remove any trailing slash from the module name
    mod="${mod%/}"

    # Record whether this is a module removal request (leading "-")
    mod_prefix=$(echo $mod | awk '/^-/ {printf("-")}')
    mod="${mod#\-}"

    # Getting the modulefile location will fill out the default version if needed
    local modfile
    modfile=`(__fml_orig_module --redirect --location show "${mod}"|awk 'NF == 1') 2> /dev/null`
    
    # Below: get the full module name using combined info from the possibly abbreviated module name together
    #  with the module filename.
    if [[ -n ${modfile} ]] ; then
        # Tricky awk command the finds the abbreviated module name in the
        #  full filename string, which must be followed by 'xxx.lua' or 'xxx/vvv.lua'
        # It then returns the full module name, which is the rest of the file name
        #  after the match, but with the '.lua' stripped off.
        fullmod=$(echo "$modfile" | awk -v modname="${mod}" '
                   function escape_regex(s, i, c, out, specials) {
                     specials = "\\.^$*+?()[]{}|";
                     out = "";
                     for (i = 1; i <= length(s); i++) {
                       c = substr(s, i, 1);
                       if (index(specials, c)) {
                         out = out "\\" c;
                       } else {
                         out = out c;
                       }
                     }
                     return out;
                   }
                   BEGIN {
                     escaped_modname = escape_regex(modname);
                     pattern = escaped_modname "([^/]*|/[^/]+)\\.lua$";
                   }
                   {
                     if(match($0, pattern)) {
                       print substr($0, RSTART, RLENGTH-4);
                     }
                   }')
        if [[ -n "${fullmod}" ]] ; then
            echo "${mod_prefix}${fullmod}" "${modfile}"
        fi
    else
        return -1
    fi
}


# if [[ "$1" == "csh" || "$1" == "tcsh" ]] ; then
# if [[ "$1" == "load" ]] ; then
# __fml_load "${@:1}"

export -f __fml_load
export -f __fml_build

export -f __fml_get_load_arguments
export -f __fml_get_load_info
export -f __fml_get_loaded_fml
export -f __fml_get_module_info
export -f __fml_unpack              

export -f __fml_orig_module
export __fml_orig_module_code
export __fml_suppress_greeting

export -f __fml_exit        
