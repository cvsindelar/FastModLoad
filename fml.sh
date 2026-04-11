######################
# FastModLoad: Fast Module Loader for Lmod-Based HPC Software Stacks
# Chuck Sindelar, Yale Center for Research Computing (March 2026)
######################

export FML_THRESH=5

# Location of the script and its default shortcut library
fml_base_dir="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
fml_global_prebuilds_dir="${fml_base_dir}/fml_prebuilds"
fml_prebuilds_dir=~/".config/fml/fml_prebuilds"

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
# lua script for getting the ordered list of module names from 
#  the lmod-style module table (lua code)
##################
module_names_from_mt_lua_script='
for key, subTable in pairs(_ModuleTable_.mT) do 
  if type(subTable) == "table" and subTable.fullName then
    print(subTable.loadOrder, subTable.fullName, subTable.stackDepth) 
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
        local fml_debug

        fml_debug=0
        if [[ "$1" == '--fmldebug' ]] ; then
            fml_debug=1
            shift
        fi

        if [[ "${fml_debug}" -ne 1 ]] ; then
            eval $(__fml_load "${@:1}" )
        else
            echo $(__fml_load "${@:1}")
        fi
        
        runtime=$( echo ${__fml_start:-} ${__fml_end:-} | awk '{print $2 - $1}' )
        if [[ "${runtime}" -ge $FML_THRESH ]] ; then
            echo 'Slow load time detected : '${runtime}' sec' 
        fi        
    }

    ######################
    # fml function that builds and loads fast modules
    ######################

    # Enable autocompletion for fml the same as 'ml':
    t=(`complete -p ml`)
    if [ "$(type -t ${t[2]})" = 'function' ]; then
        complete -F "${t[2]}" fml
    fi
    
    function fml() {
        local runtime
        local __fml_build_request
        local fml_debug

        fml_debug=0
        if [[ "$1" == '--debug' ]] ; then
            fml_debug=1
            shift
        fi

        if [[ "${fml_debug}" -ne 1 ]] ; then
            eval $(__fml_load --fmlautobuild load "${@:1}" )
        else
            echo $(__fml_load --fmlautobuild load "${@:1}")
        fi        
    }
fi

######################
# Fast module loading: output of __fml_load() consists of printed 'module' commands
#  (but with 'module' substituted by __fml_orig_module')
######################
function __fml_load() {
    local load_arguments
    local fml_info
    local fml_filename
    local old_fml_info
    local old_fml_name
    local old_fml_modfile
    local autobuild
    local status
    local fml_skip

    unset autobuild
    unset fmlglobal
    while [[ "$1" == '--fmlautobuild' || "$1" == '--fmlglobal' || "$1" == '--fmldebug' ]] ; do
        case "$1" in
            --fmlautobuild)
                autobuild=1
                shift
                break
                ;;
            --fmlglobal)
                fmlglobal=1
                shift
                break
                ;;
            --fmldebug)
                shift
                break
                ;;
        esac
    done
    
    echo 'unset __fml_start ; '
    echo 'unset __fml_end ; '

    ######################
    # If "reset" is requested, reload fml after
    ######################
    if [[ " $@ " == *" reset "* && -z "${autobuild}" ]] ; then
        local get_fml_lua_script
        get_fml_lua_script='for key, subTable in pairs(_ModuleTable_.mT) do
          if type(subTable) == "table" and subTable.fn then
            local prefix, suffix = subTable.fn:match("^(.-/)(fml/[^/]+)%.lua$")
            if prefix then
              print(prefix.." "..suffix)
            end
          end 
        end '

        local fml_components
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
    if [[ -z "${autobuild}" && -z "${load_arguments[@]}" ]] ; then
        echo "__fml_orig_module ${@:1}"
        return
    fi

    old_fml_info=( $(__fml_get_loaded_fml) )
    status=$?
    old_fml_name="${old_fml_info[0]:-}"
    old_fml_modfile="${old_fml_info[2]:-}"

    # If old_fml_name returned an error code (integer less than 0) something went wrong (oooops)
    if [[ "${status}" -ne 0 ]] ; then
        echo 'ERROR: Corrupted fml environment :' >&2
        __fml_orig_module list
        return
    fi
    
    # Check to be sure we are starting from a fresh environment (no other loaded modules or fast modules);
    #  otherwise there can be pathologies.

    fml_skip=0
    if [[ -n "${old_fml_name}" && "${old_fml_name}" != '0' ]] ; then
        if [[ -n "${load_arguments[@]}" ]] ; then
            # fast module is loaded and more modules are requested
            #  -> note the last 2 lines in the awk script below (END clause) are a hack to handle the faulty
            #     YCRC R module where R itself gets unloaded, so we print the top of the load stack
            #     (R-bundle-Bioconductor) just to print something
            ordered_module_list=( $( (cat ${old_fml_modfile%.lua}.mt ; \
                                  echo "${module_names_from_mt_lua_script}" ) \
                                 |& lua - | sort -n -k 1 \
                                 | awk '{if($2 != "StdEnv" && $2 !~ "^fml[/]" && $3 + 0 == 0) {
                                           print $2;
                                           lastln=NR;
                                         }}
                                         {arg2=$2}
                                         END {if(NR != lastln) print arg2}' ) )
            # echo 'Unpacking fast module '"fml-${old_fml_name} :" >&2
            # echo "   ${ordered_module_list[@]}" >&2
            # echo 'Additional module(s) : '"${load_arguments[@]}" >&2
            # echo '  will be loaded on top' >&2
            __fml_unpack "${old_fml_modfile}"
            fml_skip=1
        fi
    fi

    if [[ "${autobuild}" -eq '1' \
              && ( "${old_fml_name}" == '0' || -n "${ordered_module_list[@]}" ) ]] ; then
        # Trying to build fast module with modules already present
        #  -> note the hack in the awk script below (END clause) as above to handle
        #     the faulty YCRC R module
        if [[ -n "${load_arguments[@]}" ]] ; then
            if [[ "${old_fml_name}" == '0'  ]] ; then
                ordered_module_list=( $( ( __fml_orig_module --mt ; \
                                           echo "${module_names_from_mt_lua_script}" ) \
                                         |& lua - | sort -n -k 1 \
                                             | awk '{if($2 != "StdEnv" && $2 !~ "^fml[/]" && $3 + 0 == 0) {
                                                      print $2;
                                                    }}
                                                    {arg2=$2}
                                                    END {if(NR != lastln) print arg2}' ) )
            fi
            echo 'Slow-loading this environment because additional modules were already loaded;' >& 2
            echo 'To create a fast module for this environment, do "module reset" followed by:' >&2
            echo "    fml ${ordered_module_list[@]} ${load_arguments[@]}" >&2
            fml_skip=1
        else
            echo 'FML!' >&2
            return 1
        fi
    fi
        
    fml_info=( $(__fml_get_load_info "${load_arguments[@]}" ) )

    if [[ "${fml_skip}" -ne 0 || -z "${fml_info[0]}" || "$?" -ne '0' ]] ; then
        # Revert to lmod functions
        echo "__fml_orig_module ${@:1} ; "
        return
    fi

    fml_filename_info=( $( __get_fml_filename ${fml_info[@]} ) )
    fml_filename="${fml_filename_info[0]}"
    requested_fml_name="${fml_filename_info[1]}"
    update_needed="${fml_filename_info[2]}"

    ######################
    # Perform specialized load/unloading actions
    ######################

    # Load the fast module if it exists.
    if [[ -f "${fml_filename}" && "${update_needed}" -eq '0' ]] ; then
        echo "Fast Module Loading : fml-${requested_fml_name}   (use 'module -fml' to disable)" >&2
        echo "__fml_orig_module use $(dirname ${fml_filename}) ; "
        echo "__fml_orig_module load fml-${requested_fml_name} ; "
        echo "[[ -f ${fml_filename%.lua}.out ]] && cat ${fml_filename%.lua}.out ; "
    else
        if [[ "${update_needed}" -eq '0' ]] ; then
            :
            # echo 'Fast module check:'" ${load_arguments[@]}" >&2
        fi
        # Request a module load, also recording the output, load time and exit status
        echo "mkdir -p $(dirname ${fml_filename} ) ; "
        echo '__fml_start=$(date +%s) ; '
        echo "__fml_orig_module ${@:1} >& ${fml_filename%.lua}.out ; "
        echo '__fml_status=$? ; __fml_end=$(date +%s) ; '
        echo "cat ${fml_filename%.lua}.out ; "

        if [[ -n "${autobuild}" || "${update_needed}" -eq '1' ]] ; then
            echo '__fml_build "'"${requested_fml_name}"'" "'"${fml_filename}"'" ; '
        fi
    fi
}

function __get_fml_filename() {
    fml_info=( "${@:1}" )
    requested_fml_name="${fml_info[0]}"
    requested_modfiles="${fml_info[@]:1}"
    
    fml1_global="${requested_fml_name}/fml-${requested_fml_name}.lua"
    fml2_user="${fml_prebuilds_dir}/${requested_fml_name}/fml-${requested_fml_name}.lua"

    fml_filename=''
    update_needed=''
    for fml_dir in ${fml_global_prebuilds_dir} ${fml_prebuilds_dir} ; do
        suffix=''
        # Initialize fml_filename for the while loop:
        fml_filename="${fml_dir}/${requested_fml_name}${suffix}/fml-${requested_fml_name}.lua"

        # Loop through all alternative fast module versions with suffixes ___1, ___2, ...
        while [[ -f "${fml_filename}" ]] ; do

            # Double check if the module is up to date
            if [[ -f ${fml_filename%.lua}.mt && -f ${fml_filename%.lua}.lua_record ]] ; then
                ordered_module_list=( $( (cat ${fml_filename%.lua}.mt ; \
                                          echo "${process_collection_lua_script}" ) \
                                         |& lua - | sort -n -k 1 \
                                         | awk '{n=split($2, a, "/") ; 
                                                 if(a[n] != "StdEnv.lua" && a[n-1] != "fml") {
                                                   print $2
                                                 }}' ) )
                # echo eval ${build_lua_record} '| cmp '${fml_filename%.lua}.lua_record >&2 # >& /dev/null
                stat "${ordered_module_list[@]}" &>/dev/null \
		    && eval ${build_lua_record} | cmp ${fml_filename%.lua}.lua_record >& /dev/null
                update_needed=$?
            else
                update_needed=1
            fi

            if [[ "${update_needed}" -eq '0' ]] ; then
                # If we found a good file, we're done
                break
            else
                if [[ -z ${suffix} ]] ; then
                    suffix='___1'
                else
                    suffix=$(echo ${suffix} | awk '{print("___" substr($1, 4, length($1)-3) + 1) }')
                fi
                echo 'Fast module seems to be out of date: ' "${fml_filename}" >&2
                echo ' -> next up: ' "${fml_basename}${suffix}" >&2
            fi
            # Update fml_filename for the while loop:
            fml_filename="${fml_dir}/${requested_fml_name}${suffix}/fml-${requested_fml_name}.lua"
        done

        # If we found a good file, break out of the outer loop
        if [[ -f "${fml_filename}" && "${update_needed}" -eq '0' ]] ; then
            break
        fi
        
        # Skip the second pass of this loop ($fml_basename == $fml2_user) if we are doing a global install.
        #  This means we are going to rebuild the global fastmodule 
        if [[ -n "${fmlglobal}" ]] ; then
            echo '(Re)building the global fast module: ' "${fml_filename}" >&2
            break
        fi
    done
    
    echo "${fml_filename}"
    echo "${requested_fml_name}"
    echo "${update_needed}"
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
    
    runtime=$( echo ${__fml_start:-} ${__fml_end:-} | awk '{print $2 - $1}' )
    unset __fml_start
    unset __fml_end

    __fml_build_request=("${@:1}")
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
    # cat "${fml_filename%.lua}.out"
}

function __fml_unpack() {
    local tmpfile
    local status
    local fml_file

    status=0
    if [[ $# -gt 0 ]] ; then        
        fml_file="$1"
    else
        # with no arguments given, get the loaded fast module if present
        fml_info=( $(__fml_get_loaded_fml) )
        status=$?
        fml_name=${fml_info[0]}
        fml_file=${fml_info[2]}

        # If no fast module present, there is nothing to do
        if [[ -z "${fml_file}" ]] ; then
            return
        fi
        
        # if [[ -n "${fml_name}" && "${fml_info[0]}" != '0' ]] ; then # fast modules present
        #     __fml_orig_module unload fml-${fml_name}
        # fi
    fi
    mt_file="${fml_file%.lua}.mt"
    
    # Create a unique temporary file
    mkdir -p ~/.config/lmod
    tmpfile=$( mktemp -p ~/.config/lmod fmlXXXXXXXXXX )
    /bin/cp "${mt_file}" "${tmpfile}"
    echo '__fml_orig_module restore '$(basename "${tmpfile}")' >& /dev/null; '
    echo '__fml_status=$? ; '
    echo "/bin/rm ${tmpfile} ; "

    # __fml_orig_module restore $(basename "${tmpfile}") >&2 # >& /dev/null
    # status=$?

    # if [[ "${status}" -ne 0 ]] ; then
    #     echo 'fml internal failure: Failed to restore original module environment :'
    #     echo ' -> ' $2
    # fi
    # /bin/rm "${tmpfile}"
    
    [[ "${status}" -ne 0 ]] && return "${status}"
}

function __fml_get_load_arguments() {
    local load_arguments

    while [[ "$1" == '--fmldebug' ]] ; do
        case "$1" in
            --fmldebug)
                shift
                break
                ;;
        esac
    done
    
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

    if [[ "${old_fml_name[0]:-}" =~ ^-?[0-9]+$ && "${old_fml_name[0]:-}" -lt 0 ]] ; then
        return 1
    else
        return 0
    fi
}

function __fml_get_load_info() {

    local module_info
    local load_arguments
    local requested_modfiles
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

export -f __fml_exit        
