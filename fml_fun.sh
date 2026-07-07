#####################
# Bash function definitions for FastModLoad
#  These functions (and lua 'pseudofunctions' encoded by bash variables) are visible only to fml.sh
######################

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
# lua script for getting the ordered list of module *names* from 
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
# __fml_module() : the main fast module loading function
#  Output of consists of printed commands that will be executed
#   by the calling shell (bash) process.
######################
function __fml_module() {
    local fml_source_modfile_local
    local fmlglobal
    local fmldebug
    local load_arguments
    local old_fml_info
    local old_fml_name
    local old_fml_modfile
    local status
    local fml_skip
    local ordered_module_list
    local fml_info
    local fml_filename_info
    local fml_filename
    local requested_fml_name
    local update_needed
    local first_mod_spec
    local first_load_arg
    local fml_active
    local terselist
    local list_file
    local fml_name
    local tmp1
    local tmp2

    ######################
    # Read function inputs
    ######################
    fml_source_modfile_local="$1"
    shift

    ######################
    # Input flags that change the behavior
    ######################
    fmlglobal=''
    fmldebug=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fmldebug)
                shift
                ;;
            *)
                # Stop the loop at the first non-flag argument
                break
                ;;
        esac
    done

    ######################
    # Do a modified module listing if a fast module is loaded
    ######################
    if [[ " $@ " == *" list "* ]] ; then
        terselist=$(module --terse list 2>&1 )
        fml_name=$( echo "${terselist}" | awk '$0 ~ "^fml[-]" {print(substr($1, 5, length($1)-4))}' )
        if [[ -n ${fml_name} ]] ; then
            list_file=
            tmp1=${fml_global_prebuilds_dir}/${fml_name}/fml-${fml_name}.list
            tmp2=${fml_prebuilds_dir}/${fml_name}/fml-${fml_name}.list
            if [[ -f "${tmp1}" ]] ; then
                list_file="${tmp1}"
            elif [[ -f "${tmp2}" ]] ; then
                list_file="${tmp2}"
            fi

            if [[ -n "${list_file}" ]] ; then
                cat <<EOF
cat "${list_file%.list}.fancy_list"
echo "#####################################################"
echo "FastModLoad Emulated Environment:"
echo "    fml-${fml_name}"
echo "#####################################################"
echo ''
echo "Type 'fml' to disable this Fast Module and restore the original Lmod environment"
echo "Type 'fml --off' or 'ml --force -fml' to turn off Fast Module Loading altogether"
echo "Type 'module --lmod list' to peek at the current (true) Lmod environment"
echo ''
EOF
            else
                module list
            fi
            return
        fi
    fi
    
    ######################
    # If "reset" is requested, reload fml after
    ######################
    if [[ " $@ " == *" reset "* ]] ; then
        __fml_reset --quiet "${fml_source_modfile_local}" reset
        return
    fi

    ######################
    # If no load requested, or if fast module loading is turned off in the config file,
    #  pass the command through to Lmod
    ######################
    first_load_arg=$(echo "$@" | awk '$1=="load" || $1=="unload" {gsub("/", "_", $2); if($2!="") print $2; exit}')
    fml_active=$(__fml_is_active)

    if [[ -z ${first_load_arg} || "${fml_active}" == "off" ]] ; then
        __lmod_module_execute "$@"
        return
    fi

    ######################
    # Set up fml load variables & check for errors
    ######################

    echo '__fml_start=0 ; '
    echo '__fml_end=0 ; '

    load_arguments=( $(__fml_get_load_arguments "$@") )
    
    # Check if we should just pass through to the Lmod module function (if not building a fast module)
    if [[ -z "${load_arguments[@]}" ]] ; then
        # If no load requested, pass the command through to Lmod
        __lmod_module_execute "$@"
        return
    fi

    # Get first requested module minus any version spec
    first_mod_spec=$(echo ${load_arguments[0]} | awk '{sub("[/].*", "", $0) ; print($1)}')

    # Skip to the Lmod module function if both the below conditions are true::
    #   (1) There are no loaded fast modules
    #   (2) There is no stored fast module corresponding to the module request
    if [[ -z $( module --terse list |& grep '^fml[-]' ) \
          && -z $( ls ${fml_global_prebuilds_dir}/${first_mod_spec}_* \
                      ${fml_prebuilds_dir}/${first_mod_spec}_* 2> /dev/null ) ]] ; then
        __lmod_module_execute "$@"
        return
    fi

    status=0
    old_fml_info=( $(__fml_get_loaded_fml) ) || status=$?
    # If old_fml_name returned an error code (nonzero) something went wrong (oooops)
    if [[ "${status}" -ne 0 ]] ; then
        echo 'ERROR: Corrupted fml environment :' >&2
        module list
        return
    fi
    old_fml_name="${old_fml_info[0]:-}"
    old_fml_modfile="${old_fml_info[2]:-}"

    # Check to be sure we are starting from a fresh environment (no other loaded modules or fast modules);
    #  otherwise there can be pathologies.

    fml_skip=0
    # If a fast module is loaded, we need to unpack it as ordinary Lmod modules
    #  and then load the requested modules the ordinary way (fml_skip=1)
    if [[ -n "${old_fml_name}" && "${old_fml_name}" != '0' ]] ; then
        fml_skip=1

        # If the requested modules actually exist, unpack the existing fast module
        #  to get ready to load the new ones
        status=0
        fml_info=( $(__fml_get_load_info "${load_arguments[@]}" ) ) || status=$?
        if [[ "$status" -eq '0' && "${#fml_info[@]}" -gt 0 ]] ; then
            # For message printing, get the original list of user-requested modules
            ordered_module_list=( $(__fml_get_message_module_list "${old_fml_modfile%.lua}.mt") )

            status=0
            __fml_unpack "${fml_source_modfile_local}" || status=$?
            if [[ "${status}" -ne 0 ]] ; then
                echo 'echo "Warning: unable to restore the full lmod environment"'
                echo 'return 1'
            fi
	else
	    # fall back to the original Lmod module code
            __lmod_module_execute "$@"
	    return
        fi
    fi

    # If ordinary Lmod modules are loaded, turn on fml_skip to skip fast module loading
    if [[ ( "${old_fml_name}" == '0' || -n "${ordered_module_list[@]}" ) ]] ; then
        fml_skip=1

        # Get module list for printed output:
        #  -> note the hack in __fml_get_message_module_list's awk script handles
        #     the faulty YCRC R module edge case
        if [[ "${old_fml_name}" == '0'  ]] ; then
            ordered_module_list=( $(__fml_get_message_module_list) )
        fi
    fi

    status=0
    fml_info=( $(__fml_get_load_info "${load_arguments[@]}" ) ) || status=$?

    if [[ "$status" -ne 0 || "${fml_skip}" -ne 0 || "${#fml_info[@]}" -eq 0 ]] ; then
        # Revert to lmod functions
        __lmod_module_execute "$@"
        return
    fi

    fml_filename_info=( $(__fml_resolve_filename_info "${fmlglobal}" "${fml_info[@]}") )
    fml_filename="${fml_filename_info[0]}"
    requested_fml_name="${fml_filename_info[1]}"
    update_needed="${fml_filename_info[2]}"

    # if xxxx.d exists, the fast module is disabled and we skip loading it
    if [[ -d ${fml_prebuilds_dir}/${requested_fml_name}.d ]] ; then
        # Revert to lmod functions
        __lmod_module_execute "$@"
        return
    fi
        
    ######################
    # Perform specialized load/unloading actions
    ######################

    # Load the fast module if it exists.
    if [[ -f "${fml_filename}" && "${update_needed}" -eq '0' ]] ; then
        # cleanup_disabled_marker=0: __fml_module never reaches here while a
        #  '.d' disabled marker exists (checked above), so there's nothing to clean up.
        __fml_do_fast_load "${requested_fml_name}" "${fml_filename}" 0 "Falling back to Lmod:" "$@"
    else
        # Request a module load, also recording the output, load time and exit status
        echo "mkdir -p $(dirname ${fml_filename} ) ; "

        if [[ "${update_needed}" -eq '1' ]] ; then
            echo echo 'Fast Module Update: '"fml-${requested_fml_name}"
	fi
	
        echo '__fml_start=$(date +%s) ; '

        __lmod_module_execute "$@ >& ${fml_filename%.lua}.out_tmp"

	echo "awk '/Lmod Warning/ {printing=1} printing == 1' ${fml_filename%.lua}.out_tmp > ${fml_filename%.lua}.out"
	echo "/bin/rm ${fml_filename%.lua}.out_tmp"

        echo '__fml_end=$(date +%s) ; '
        
        echo "cat ${fml_filename%.lua}.out ; "

	# Rebuild the module, but only if it existed already and was stale
	#  (a brand new module is only built via an explicit 'fml' invocation)
        if [[ "${update_needed}" -eq '1' ]] ; then
	    echo '__fml_start=0 ; '
	    echo '__fml_end=0 ; '

	    # We need to do the equivalent of the user typing 'fml' in their own current
	    #  bash shell. It won't work to do it in this shell (fml.sh), where the user-requested
	    #  module is likely not yet loaded- loading will be done when the above-echoed
	    #  commands are processed by the calling shell.
            cat <<EOF
eval "\$(bash ${fml_base_dir}/fml.sh ${fml_source_modfile_local} fml)"
EOF
	fi
    fi
}

######################
# __fml() : generate fast modules
# As with __fml_module(), output of consists of printed commands that will be executed
#   by the calling shell (bash) process.
######################
function __fml() {
    local fml_source_modfile_local
    local fmlglobal
    local fmldebug
    local load_arguments
    local old_fml_info
    local old_fml_name
    local old_fml_modfile
    local status
    local fml_info
    local fml_filename_info
    local fml_filename
    local requested_fml_name
    local update_needed
    local autofml

    fml_source_modfile_local="$1"
    shift

    ######################
    # Input flags that change the behavior
    ######################
    fmlglobal=''
    fmldebug=''

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global)
                fmlglobal='--global'
                shift
                ;;
            --fmldebug)
                shift
                ;;
            *)
                # Stop the loop at the first non-flag argument
                break
                ;;
        esac
    done

    ######################
    # Set up fml load variables & check for errors
    ######################
        
    load_arguments=( $(__fml_get_load_arguments "$@") )
    
    status=0
    old_fml_info=( $(__fml_get_loaded_fml) ) || status=$?
    # If old_fml_name returned an error code (integer less than 0) something went wrong (oooops)
    if [[ "${status}" -ne 0 ]] ; then
        echo 'ERROR: Corrupted fml environment :' >&2
        module list
	echo "Please do 'module reset' to recover" >&2
        return
    fi
    old_fml_name="${old_fml_info[0]:-}"
    old_fml_modfile="${old_fml_info[2]:-}"
    
    # Check to be sure we are starting from a fresh environment (no other loaded modules or fast modules);
    #  otherwise there can be pathologies.

    autofml=0
    if [[ "${old_fml_name}" == '0' ]] ; then
        # Above is true if a Fast Module is not loaded AND ordinary modules are present/loaded
        if [[ "${#load_arguments[@]}" -eq 0 ]] ; then
            # If the user types fml with no arguments, trigger 'autofml'
            #  to build a Fast Module from the current environment
            autofml=1
        else
            # User requested another module load on top of existing loaded modules
            #  (not allowed for now)
	    echo echo "Modules are already loaded. Please use 'fml' by itself or do 'module reset' first."
            return
        fi
    else
        if [[ "${#load_arguments[@]}" -eq 0 && -z "${old_fml_name}" ]] ; then
            # No arguments to fml, and no Fast Module or other modules are loaded:
            echo 'fml --help ; '
            return
	fi
        if [[ -n "${old_fml_name}" ]] ; then
            if [[ "${#load_arguments[@]}" -eq 0 ]] ; then
                # If a Fast Module is loaded, unpack it and disable the fast module by
		# creating xxxx.d in the user's .config/fml/fml_prebuilds folder
		status=0
                __fml_unpack "${fml_source_modfile_local}" || status=$?
		if [[ $status -eq 0 ]] ; then
		    echo "mkdir -p ${fml_prebuilds_dir}/${old_fml_name}.d ; "
		    echo "echo Fast Module disabled: fml-${old_fml_name}"
		    echo "echo Type \'fml\' again to re-enable"
		fi
                return $status
            else
                echo "echo Modules are already loaded. Please use 'fml' by itself or do 'module reset' first."
            cat <<EOF
eval "\$(bash ${fml_base_dir}/fml.sh ${fml_source_modfile_local} fml --help)"
EOF
		exit
                return
            fi
        fi
        # else: nothing is loaded at all (old_fml_name is empty) and the user
        #  gave module arguments -> fall through to build/load below
    fi

    status=0
    if [[ ${autofml} -eq 0 ]] ; then
        fml_info=( $(__fml_get_load_info "${load_arguments[@]}" ) ) || status=$?
    else
        # Get the original list of user-requested (currently loaded) modules
        load_arguments=( $(__fml_get_message_module_list) )
        fml_info=( $(__fml_get_load_info --slow "${load_arguments[@]}" ) )  || status=$?
    fi

    if [[ "${#fml_info[@]}" -eq 0 || "$status" -ne '0' ]] ; then
        echo 'fml --help'
        return
    fi

    fml_filename_info=( $(__fml_resolve_filename_info "${fmlglobal}" "${fml_info[@]}") )
    fml_filename="${fml_filename_info[0]}"
    requested_fml_name="${fml_filename_info[1]}"
    update_needed="${fml_filename_info[2]}"
    
    ######################
    # Perform specialized load/unloading actions
    ######################

    # Load the fast module if it exists.
    if [[ -f "${fml_filename}" && "${update_needed}" -eq '0' ]] ; then
        if [[ ${autofml} -eq 1 ]] ; then
            __fml_reset --quiet "${fml_source_modfile_local}" reset
            __fml_do_fast_load "${requested_fml_name}" "${fml_filename}" 1 \
                "Falling back to Lmod:" load "${load_arguments[@]}"
        else
            __fml_do_fast_load "${requested_fml_name}" "${fml_filename}" 1 \
                "Falling back to Lmod:" "$@"
        fi
    else
        # Request a module load, also recording the output, load time and exit status

	# Make the fast module directory, if it doesn't already exist, to capture the output
	#  of the below 'module load' command:
        mkdir -p $(dirname ${fml_filename} )

        if [[ ${autofml} -ne 1 ]] ; then
            echo '__fml_start=$(date +%s)'

            __lmod_module_execute "$@ >& ${fml_filename%.lua}.out_tmp"

	    echo "awk '/Lmod Warning/ {printing=1} printing == 1' ${fml_filename%.lua}.out_tmp > ${fml_filename%.lua}.out"
	    echo "/bin/rm ${fml_filename%.lua}.out_tmp"

            echo '__fml_end=$(date +%s)'
	    echo "cat ${fml_filename%.lua}.out ; "

	    # Since the above commands are executed in the user shell, they are deferred.
	    # We therefore need to do the equivalent of the user typing 'fml' in their own current
	    #  bash shell. It won't work to do it within the fml bash shell.
            cat <<EOF
eval "\$(bash ${fml_base_dir}/fml.sh ${fml_source_modfile_local} fml ${fmlglobal})"
EOF
	else
            if [[ -n "${fmlglobal}" ]] ; then
		echo 'printf "Global "'
	    fi
            echo echo 'Fast Module Build: '"fml-${requested_fml_name}"
    
	    # Module was loaded prior to running 'fml' so just build the module
	    __fml_build "${fml_source_modfile_local}" "${requested_fml_name}" "${fml_filename}"
            cat <<EOF
echo "Complete. To rapidly load this environment in the future, do:"
echo "    module reset ; module load ${load_arguments[@]}"
EOF
	fi
	
	# Ensure the fast module will be active going forwards, by
	#  removing any xxxx.d in the user's .config/fml/fml_prebuilds folder
	echo "if [[ -d ${fml_prebuilds_dir}/${requested_fml_name}.d ]] ; then "
	echo "   rmdir ${fml_prebuilds_dir}/${requested_fml_name}.d ; "
	echo 'fi'
    fi
}

######################
# Execute the original lmod 'module' function ; use --lmod if it has been
#  embedded in the 'hijacked' module function
######################
function __lmod_module_execute() {
    [[ -z "$@" ]] && return

    cat <<EOF
if [[ -z \$( declare -f module | grep fml ) ]] ; then
    module $@ ;
else
    module --lmod $@ ;
fi ;
EOF
}

######################
# Print 'on' or 'off' depending on whether Fast Module Loading is enabled
#  in ~/.config/fml/config
######################
function __fml_is_active() {
    awk '
$1 == "active" {active=$2}
END {
    if (active == "on")
        print("on")
    else
        print("off")
}' ~/.config/fml/config
}

######################
# Print the ordered list of user-visible module *names* (not filenames),
#  filtering out StdEnv and any loaded fml-xxx module. Used for
#  human-readable messages (e.g. "Fast Module Build: ...").
# If a module-table file is given, read the table from that saved snapshot;
#  otherwise read the live, currently-loaded module table.
######################
function __fml_get_message_module_list() {
    local mt_source

    if [[ $# -ge 1 && -n "$1" ]] ; then
        mt_source="cat $1"
    else
        mt_source="module --mt"
    fi

    ( eval "${mt_source}" ; echo "${module_names_from_mt_lua_script}" ) \
        |& lua - | sort -n -k 1 \
        | awk '{if($3 + 0 == 0) {
                  lastln=NR ;
                  if($2 != "StdEnv" && $2 !~ "^fml[/]" )
                     print $2 ;
                  }}
               {arg2=$2}
               END {if(NR != lastln && arg2 != "StdEnv" && arg2 !~ "^fml[/]")
                 print arg2}'
}

######################
# Given an fmlglobal flag ('--global' or '') and the fml_info returned by
#  __fml_get_load_info, resolve the on-disk Fast Module filename, its
#  combined name, and whether it needs to be (re)built.
# Prints 3 lines: fml_filename, requested_fml_name, update_needed
#  (all fields blank if resolution failed).
######################
function __fml_resolve_filename_info() {
    local fmlglobal
    local fml_info
    local status
    local fml_filename_info
    local fml_filename
    local requested_fml_name
    local update_needed

    fmlglobal="$1"
    shift
    fml_info=( "$@" )

    status=0
    fml_filename_info=( $( __get_fml_filename ${fmlglobal} "${fml_info[@]}" ) ) || status=$?

    # NOTE: the original inline version of this check at both call sites read
    #  `if [[ "$status" -ne 0 || ${#fml_filename_info[@]} -eq 3 ]]`, which is
    #  inverted - it assigned real values on FAILURE and blanked them out on
    #  success-with-3-fields. Fixed here to require success AND 3 fields.
    if [[ "${status}" -eq 0 && ${#fml_filename_info[@]} -eq 3 ]] ; then
        fml_filename="${fml_filename_info[0]}"
        requested_fml_name="${fml_filename_info[1]}"
        update_needed="${fml_filename_info[2]}"
    else
        fml_filename=''
        requested_fml_name=''
        update_needed=''
    fi

    echo "${fml_filename}"
    echo "${requested_fml_name}"
    echo "${update_needed}"
}

######################
# Attempt to load an existing, up-to-date Fast Module. Emits bash commands
#  for the calling shell. Caller must have already verified the module file
#  exists and is up to date.
# On success: optionally clears the disabled ('.d') marker, then prints the
#  module's cached load-time output.
# On failure: prints fallback_message, then falls back to an ordinary Lmod
#  load using fallback_cmd.
######################
function __fml_do_fast_load() {
    local requested_fml_name
    local fml_filename
    local cleanup_disabled_marker
    local fallback_message
    local fallback_cmd

    requested_fml_name="$1" ; shift
    fml_filename="$1" ; shift
    cleanup_disabled_marker="$1" ; shift
    fallback_message="$1" ; shift
    fallback_cmd=( "$@" )

    echo "Fast Module Load: fml-${requested_fml_name}" >&2

    __lmod_module_execute "use $(dirname "${fml_filename}")"
    __lmod_module_execute "load fml-${requested_fml_name} > /dev/null 2>&1"

    echo 'if [[ $? -eq 0 ]] ; then '
    if [[ "${cleanup_disabled_marker}" -eq 1 ]] ; then
        echo "    if [[ -d ${fml_prebuilds_dir}/${requested_fml_name}.d ]] ; then "
        echo "       rmdir ${fml_prebuilds_dir}/${requested_fml_name}.d ; "
        echo '    fi'
    fi
    echo "    if [[ -f ${fml_filename%.lua}.out ]] ; then cat ${fml_filename%.lua}.out ; fi ; "
    echo 'else '
    echo "    echo Fast Module failed to load: fml-${requested_fml_name}"
    echo "    echo ${fallback_message}"
    echo "    echo module ${fallback_cmd[@]}"
    __lmod_module_execute "${fallback_cmd[@]}"
    echo 'fi ; '
}

######################
# Perform a 'module purge' or 'module reset', then reload fml after
######################
function __fml_reset() {
    local fml_source_modfile_local
    local fml_path
    local fml_version
    local func
    local quiet

    quiet=0
    if [[ "$1" == "--quiet" ]] ; then
        quiet=1
        shift
    fi
    
    fml_source_modfile_local="$1"
    shift
    
    fml_source_modfile_local="${fml_source_modfile_local%.lua}"

    fml_path=$(dirname $(dirname "${fml_source_modfile_local}"))
    fml_name=$(basename $(dirname "${fml_source_modfile_local}"))
    fml_version=$(basename "${fml_source_modfile_local}")
    
    if [[ $# -lt 1 ]] ; then
        func=reset
    else
        func="$@"
    fi

    # echo module --lmod reset
    
    # Perform the reset or purge command:
    if [[ ${quiet} -eq 1 ]] ; then
	__lmod_module_execute "${func} > /dev/null 2>&1"
    else
	__lmod_module_execute "${func} 2> /dev/null"
    fi
    
    # After fml is unloaded, we need to use the original 'module' commands to reload fml:
    echo 'if [[ ":\$MODULEPATH:" != *":'${fml_path}'":* ]] ; then '
    __lmod_module_execute "use ${fml_path}"
    echo 'fi ; '
    
    if [[ ${quiet} -eq 1 ]] ; then
        __lmod_module_execute "load ${fml_name}/${fml_version} > /dev/null 2>&1"
    else
        __lmod_module_execute "load ${fml_name}/${fml_version}"
    fi
}

######################
# Get the filename associated with a 'fml module' ; it does not necessarily need to exist yet
#  '--global' option maps to within the fml_prebuilds directory where fml.sh is located ; otherwise
#  it maps to within ~/.config/fml/fml_prebuilds
######################
function __get_fml_filename() {
    local fml_info
    local requested_fml_name
    local requested_modfiles
    local fml1_global
    local fml2_user
    local update_needed
    local suffix
    local fml_filename
    local ordered_module_list
    local fmlglobal
    
    fmlglobal=
    if [[ "${1:-}" == "--global" ]] ; then
        fmlglobal=1
        shift
    fi
        
    fml_info=( "$@" )
    requested_fml_name="${fml_info[0]}"
    requested_modfiles="${fml_info[@]:1}"
    
    fml1_global="${requested_fml_name}/fml-${requested_fml_name}.lua"
    fml2_user="${fml_prebuilds_dir}/${requested_fml_name}/fml-${requested_fml_name}.lua"

    fml_filename=''
    update_needed='0'
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
                # echo 'Fast module seems to be out of date: ' "${fml_filename}" >&2
                # echo ' -> next up: ' "${requested_fml_name}${suffix}" >&2
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
    local fml_source_modfile_local
    local mod_name
    local mod_filename
    local tmpfile1
    local tmpfile2
    local tmpfile3
    local ordered_module_list

    fml_source_modfile_local="$1"
    shift
    
    if [[ $# -lt 2 ]] ; then
        return
    fi

    mod_name="$1"
    mod_filename="$2"

    mkdir -p $(dirname "${mod_filename}")

    # Save the module listing
    module --terse --redirect list > ${mod_filename%.lua}.list

    # Fanciful way to preserve colors (use 'less -R' to reproduce)
    LMOD_PAGER=none script -q -c "ml list" ${mod_filename%.lua}.list_tmp > /dev/null
    if [[ $? -eq 0 ]] ; then
        sed '1d; $d; s/\r//g' ${mod_filename%.lua}.list_tmp > ${mod_filename%.lua}.fancy_list
    else
        LMOD_PAGER=none ml list 2> ${mod_filename%.lua}.fancy_list
    fi
    /bin/rm ${mod_filename%.lua}.list_tmp >& /dev/null
    
    # tmpfile1=$( mktemp -p $(dirname "${mod_filename}") )
    mkdir -p ~/.config/lmod
    tmpfile1=$( mktemp ~/.config/lmod/fmltmpXXXXXXXXXX)
    tmpfile2=$( mktemp -p $(dirname "${mod_filename}") )
    tmpfile3=$( mktemp -p $(dirname "${mod_filename}") )
    
    module --mt >& "${tmpfile1}"
    ordered_module_list=( $( (module --mt ; echo "${process_collection_lua_script}" ) |&lua - | sort -n -k 1 | awk '{n=split($2, a, "/") ; if(a[n] != "StdEnv.lua" && a[n-1] != "fml") {print $2}}' ) )

    stat "${ordered_module_list[@]}" &>/dev/null \
        && eval "$build_lua_record" > "${tmpfile3}"
    
    ##################
    # Concatenate all the .lua files required by this collection,
    #  but strip out the 'depends_on' statements.
    #
    # This is predicated on 'module save' having generated a complete, self-consistent
    #  list of modules, with a defined build order that we will use when loading.
    #  (ordered_module_list is sorted on the build order).
    #
    # Each .lua code is wrapped by a 'do...end' statement to preserve
    #  independence of the local variables
    ##################
    
    printf '' > "${tmpfile2}"
    for m in ${ordered_module_list[@]}; do
        echo "do -- Scope for $m"
        # Skip all valid lua depends_on() statements, including with comments appended
        grep -E -v '^[[:space:]]*depends_on\([[:space:]]*"[^"]*"[[:space:]]*\)[[:space:]]*(--.*)?$' "$m"
        echo "end -- End scope for $m"
    done >> "${tmpfile2}"
    
    # In case there were previous versions present, possibly being written by someone else:
    #  make the updates atomic using the tmpfiles:
    /bin/mv "${tmpfile1}" "${mod_filename%.lua}.mt"
    /bin/mv "${tmpfile2}" "${mod_filename}"
    /bin/mv "${tmpfile3}" "${mod_filename%.lua}".lua_record

    # Loosen the highly restrictive permissions inherited from the original tmpfiles
    # Files and folder are group writeable so all group members can use the --global option
    #  for Fast Module building
    chmod -R a+r $(dirname "${mod_filename}")
    chmod -R ug+rw $(dirname "${mod_filename}")
    
    # Now replace the slow-loading environment with the fast module
    if [[ "${fml_source_modfile_local}" != '-' ]] ; then
        __fml_reset --quiet "${fml_source_modfile_local}" purge
    else
        __lmod_module_execute purge
    fi

    # Restore fml
    __lmod_module_execute "use $(dirname ${mod_filename})"
    __lmod_module_execute "load $(basename ${mod_filename%.lua})"
    
    echo 'if [[ $? -ne 0 ]] ; then '
    echo "    echo Fast Module failed to load: fml-${mod_name} ; "
    echo "    echo Falling back to Lmod ; "
    __lmod_module_execute "$@"
    
    echo 'else '
    echo '  : '
# cat<<"EOF"
# echo '' ;
# echo '            (~~) ' ;
# echo '           <(@@) ' ;
# echo '  *---##--##-\#) ' ;
# echo '      |##  # |_  ' ;
# echo '   ;_//ww---- \\ ' ;
# echo '               ^^' ;
# echo '' ;
# EOF

echo 'fi ; '

    # cat "${mod_filename%.lua}.out"
}

######################
# Replace a loaded fml module with the corresponding original lmod environment
######################
function __fml_unpack() {
    local fml_source_modfile_local
    local fml_path
    local fml_name
    local fml_version
    local nofml
    local status
    local fml_info
    local mt_file
    local tmpfile

    nofml=0
    if [[ $# -gt 0 && "$1" == "--nofml" ]] ; then
        nofml=1
        shift
    fi
    
    fml_source_modfile_local="$1"
    shift

    fml_source_modfile_local="${fml_source_modfile_local%.lua}"

    status=0
    if [[ $# -gt 0 ]] ; then
        fml_file="$1"
    else
        # with no arguments given, get the loaded fast module if present
        fml_info=( $(__fml_get_loaded_fml) ) || status=$?

        # If no fast module present, there is nothing to do
        if [[ $status -ne 0 || ${#fml_info[@]} -lt 3 ]] ; then
            return
        fi
                
        fml_modname=${fml_info[0]}
        fml_modfile=${fml_info[2]}

        # if [[ -n "${fml_name}" && "${fml_info[0]}" != '0' ]] ; then # fast modules present
        #     module unload fml-${fml_name}
        # fi
    fi

    # echo "echo 'Unpacking the module environment for fml-${fml_modname} (control-C to exit)' ; "
    
    mt_file="${fml_modfile%.lua}.mt"
    
    # Create a unique temporary file
    mkdir -p ~/.config/lmod
    tmpfile=$( mktemp -p ~/.config/lmod fmlXXXXXXXXXX )
    /bin/cp "${mt_file}" "${tmpfile}"

    __lmod_module_execute "restore '$(basename "${tmpfile}")' >& /dev/null"
    
    echo "/bin/rm ${tmpfile} ; "

    if [[ ${nofml} -eq 1 ]] ; then
	fml_name=$(basename $(dirname "${fml_source_modfile_local}"))
	fml_version=$(basename "${fml_source_modfile_local}")
	__lmod_module_execute "--force unload ${fml_name}/${fml_version}"
    fi
    
    if [[ "${status}" -ne 0 ]] ; then
        return "${status}"
    fi
}

######################
# Parses arguments for the 'load'/'unload' keywords and prints everything afterwards.
#  note, if 'unload' is used, results are prefixed with '-'
######################
function __fml_get_load_arguments() {
    local load_arguments
    
    load_arguments=( $(echo "$@" | awk '{
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

######################
# Return info on whether a fast module if present.
######################
function __fml_get_loaded_fml() {
    # Below: check if a fast module fml-xxx is loaded.
    # Returns info on the fast module if present.
    # Returns '0' if 'slow modules' are present instead.
    # Returns '-1' if there was a problem
    #   Detected problems include:
    #    - multiple fast fml-xxx modules
    local loaded_fml_name
    
    status=0
    loaded_fml_name=( $( (module --mt ; echo "${process_collection_lua_script}") \
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
                                  }') ) || status=$?
    if [[ "$status" -ne 0 || "${#loaded_fml_name[@]}" -lt 1 ]] ; then
        loaded_fml_name=( '' )
    fi
    if [[ "${#loaded_fml_name[@]}" -lt 2 ]] ; then
        loaded_fml_name=( "${loaded_fml_name[@]}" '' )
    fi
    if [[ "${#loaded_fml_name[@]}" -lt 3 ]] ; then
        loaded_fml_name=( "${loaded_fml_name[@]}" '' )
    fi
        
    echo "${loaded_fml_name[@]}"

    if [[ "${loaded_fml_name[0]:-}" =~ ^-?[0-9]+$ && "${loaded_fml_name[0]:-}" -lt 0 ]] ; then
        echo 'FastModLoad internal error: mismatched module environment detected: ' >&2
        module list
        return 1
    else
        return 0
    fi
}

######################
# Get a 'fml name' for requested module list
#  this requires filling in the full module names in the requested list;
#  the full names are also returned
######################
function __fml_get_load_info() {
    # If no requested modules, return nothing
    if [[ $# -eq 0 ]] ; then
        return
    fi
    local slow
    local load_arguments
    local requested_modfiles
    local arg
    local module_info
    local status
    local fml_name

    slow=0
    if [[ "${1:-}" == "--slow" ]] ; then
        shift
        slow=1
    fi

    if [[ "$#" -gt 3 ]] ; then
	echo 'Fast modules not allowed for 4 or more modules' >&2
	return 1
    fi

    load_arguments=
    requested_modfiles=()
    for arg in "$@" ; do
        module_info=()
        if [[ "${slow}" -eq 1 ]] ; then
            # Extra careful option always gets the default version if the version is not specified.
            #  The only known reason to do this is the YCRC R module, which wreaks havoc by
            #   unloading itself and replacing itself with "R/....-bare".
            #  Consequently, if R happens to be loaded when 
            #   using module --location show, lmod will report the loaded R version (R/...bare)
            #   rather than the YCRC R ordinary version that was requested.
            #  Thus, __fml_get_module_info will return the wrong R info in this case!
	    status=0
            module_info=( $(__fml_get_module_info ${arg}/default) ) || status=$?
        else
            module_info=()
        fi
        # If we used '/default' to look for the module (--slow was specified),
        #  it could well be the user actually specified the version already, which
        #  results in failure(there's no easy way to tell
        #  other than failure). So, we now redo __fml_get_module_info the normal way
	status=0
        if [[ "$status" -ne 0 || "${#module_info[@]}" -eq 0 ]] ; then
            module_info=( $(__fml_get_module_info ${arg}) ) || status=$?
        fi          
        if [[ ${#module_info[@]} -lt 2 || ${status} -ne 0 ]] ; then
            break
        fi

        load_arguments=( ${load_arguments[@]} ${module_info[0]} )
        requested_modfiles=( ${requested_modfiles[@]} ${module_info[1]} )
    done

    # If we can't find all the requested modules, flag an error
    if [[ "${#requested_modfiles[@]}" -ne $# ]] ; then
        return 1
    fi
    
    # Concatenate the list of requested modules into an 'fml name' by
    #  stringing them together with '___' separators.
    # To do: Limit the fml name size to three modules to avoid bash string length errors.
    fml_name=$( (echo ${load_arguments[@]} ) \
                  | awk '{ for(ind=1; ind <= NF; ++ind) {
                             if(nextarg) {
                                 printf("___");
                             }
                             module_name=$ind;
                             gsub("/", "_", module_name);
                             sub(/\.lua$/, "_", module_name);
                             printf(module_name);
                             nextarg=1;
                           }
                         }')
    echo ${fml_name} ${requested_modfiles[@]}
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
    
    # Below: strip spaces out of our arguments, in case ahem OnDemand gives space-ful ones
    mod=$(echo $1)
    # Remove any trailing slash from the module name
    mod="${mod%/}"

    # Record whether this is a module removal request (leading "-")
    mod_prefix=$(echo $mod | awk '/^-/ {printf("-")}')
    mod="${mod#\-}"

    # Getting the modulefile location will fill out the default version if needed
    modfile=`(module --redirect --location show "${mod}"|awk 'NF == 1') 2> /dev/null`
    
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
                     sub("[/]default$", "", modname); 
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
        return
    fi
}
