function module_check() {

    if [[ "$1" == '-h' || "$1" == '--help' ]] ; then
        echo 'module_check: print module loading conflicts with strict consistency checking'
        echo 'Usage: module_check | module_check <mod1> [<mod2> ...]'
        echo ' No arguments: evaluate the current module environment'
        echo ' With arguments: evaluate listed module environment'
        return
    fi
   
    local return_status
    unset return_status
    
    local mlq_check_args
    unset mlq_check_args
    local ycrc_r_fudge
    unset ycrc_r_fudge
    # If no arguments given, check the current module environment
    if [[ "$#" -gt 0 ]] ; then
        if [[ "$1" == '--ycrc_r_fudge' ]] ; then
            # Ugh
            ycrc_r_fudge='--ycrc_r_fudge'
            shift
        fi
        mlq_check_args="${@:1}"
    else
        mlq_check_args=`module --redirect -t list`
        # Reset the module environment to speed up the checking
        # __mlq_reset
    fi

    unset __mlq_module_version
    unset __mlq_module_file
    unset __mlq_module_caller
    unset __mlq_module_callstack
    unset __mlq_expected_versions
    declare -Ag __mlq_module_file
    declare -Ag __mlq_module_version
    declare -Ag __mlq_module_caller
    declare -Ag __mlq_module_callstack
    declare -Ag __mlq_expected_versions

    local excursion_count
    excursion_count=0
    
    __mlq_parse_module_tree_iter $ycrc_r_fudge ${mlq_check_args}
    if [[ $? -ne 0 ]]; then
        return_status=1
    fi

    echo 'Excursion count:' $excursion_count
    unset __mlq_module_file
    unset __mlq_module_version
    unset __mlq_module_caller
    unset __mlq_module_callstack
    unset __mlq_expected_versions

    # Restore the previously loaded modules
    # if [[ "$#" -lt 1 ]] ; then
    #     module load ${mlq_check_args}
    # fi

    return $return_status
}

# Fancier logo (as if)
# Font source: https://patorjk.com/software/taag/#p=display&f=Diet%20Cola&t=mlq
# __mlq_diet_cola
#     IFS='' read -r -d '' mlq_diet_cola <<"EOF"
#             (~~)                         
#            <(@@)                  /      
#      /##--##-\#)    .  .-. .-.   / .-.   
#     / |##  # |       )/   )   ) / (   )  
#    *  ||ww--||      '/   /   (_/_.-`-(   
#       ^^    ^^                `-'     `-'
# EOF
    

function __mlq_parse_module_tree_iter() {
    # In the YCRC setup, R versions R/xxx and R/xxx-bare can coexist
    #  as module dependencies (lmod of course will only load one of them
    #  at a time). The below 'fudge' flag allows this to occur
    #  without reporting a conflict!
    local ycrc_r_fudge
    unset ycrc_r_fudge

    local caller
    local callstack
    local toplevel
    unset caller
    unset callstack
    unset toplevel

    toplevel=1
    while [[ -n $(echo "$1" | awk '$1 ~ /^--/') ]] ; do
	  if [[ "$1" == '--ycrc_r_fudge' ]] ; then
              # Ugh
              ycrc_r_fudge='--ycrc_r_fudge'
              shift
	  fi
    
	  if [[ "$1" == '--caller' ]] ; then
              shift
              caller="$1"
              shift
	      unset toplevel
	  fi
	  if [[ "$1" == '--callstack' ]] ; then
              shift
              callstack="$1"
              shift
	  fi
    done

    local return_status
    return_status=0
    
    # Loop through all the input arguments;
    #  By using "${@:1}" instead of $* we can correctly handle special characters in the arguments
    for fullmod in "${@:1}" ; do
        (( excursion_count = excursion_count + 1))
        # Avoid re-parsing the same module
        if [[ "${__mlq_expected_versions[$fullmod]}" ]]; then
            continue
        fi

        echo 'Parsing: '"'""${fullmod}""'"' ...'
        caller="${fullmod}"
	if [[ -n "$callstack" ]] ; then
	    callstack="${callstack}:${caller}"
	else
	    callstack="${caller}"
	fi
        
        # Extract module name and version
        local name="$(echo "$fullmod" | awk -F/ '{print $(NF-1)}')"
        local version="$(echo "$fullmod" | awk -F/ 'NF > 1 {print $NF}')"

        # module --location fails with an ugly error if the module is not found
        # the following would check for that, but makes the algorithm very slow
        # module -I is-avail ${fullmod}
        # if [[ ($? != 0) ]]; then
        #     echo 'ERROR: module not found: ' "${fullmod}"
        #     return 1
        # fi

        # Get the modulefile
        local modfile=$(module --redirect --location show "$fullmod")

        # Check if module --location failed (module not found)
        if [[ ! "${modfile}" ]] ; then
            echo 'ERROR: module not found: ' "${fullmod}"
            echo 'Call stack: '"${callstack}"
            # return immediately; cannot proceed without a modulefile
            return 1
        fi
        
        # Check if the version has already been encountered for this module

        # if [[ "${__mlq_module_version[$name]}" && "${__mlq_module_version[$name]}" != "$version" ]]; then
        if [[ "${__mlq_module_version[$name]}" && "${__mlq_module_file[$name]}" != "$modfile" ]] ; then

            # In the YCRC setup, R versions R/xxx and R/xxx-bare coexist although lmod
            #  will only load one of them at a time
            if [[ (  "${ycrc_r_fudge}" == '--ycrc_r_fudge' && "${name}" == 'R' ) \
                      && (    "${version}" == "${__mlq_module_version[$name]}"'-bare' \
                           || "${version}"'-bare' == "${__mlq_module_version[$name]}" ) ]] ; then
                # Ugh
                echo ''
                echo '[YCRC fudge] Skipping R version non-conflict:'
                echo "      R/${version}"
                echo "      R/${__mlq_module_version[$name]}"
            else
                echo ''
                echo 'Conflict: Multiple version dependencies were found for ' "'"${name}"'" ':'
                echo '     '"'"${version}"'"
                echo '     Call stack: '${callstack}
                echo '     File: '"${modfile}"
                echo '                vs.'
                echo '     '"'"${__mlq_module_version[$name]}"'"
                echo '     Call stack: '${__mlq_module_callstack[$name]}' )'
                echo '     File: '"${__mlq_module_file[$name]}"
                return_status=1
            fi
        fi

        __mlq_module_version[$name]="$version"        # Track version
        __mlq_module_file[$name]="$modfile"           # Track actual modfile name
        __mlq_module_caller[$name]="${caller}"          # Record whose dependency this is
        __mlq_module_callstack[$name]="${callstack}"    # Record call stack
        __mlq_expected_versions[$fullmod]="$version"  # Record version
	
        # Parse dependencies
        local modname_list=`awk '$1 ~ "^depends_on[(][\"]" {sub("^depends_on[(][\"]","",$1); sub("[\"][)]$","",$1); print $1}' $modfile`

        local m
        for m in $modname_list; do
            __mlq_parse_module_tree_iter $ycrc_r_fudge --caller "${caller}" --callstack "${callstack}" "$m"
            
            if [[ $? -ne 0 ]]; then
                # echo "while loading: ${fullmod}"
                return_status=1
            fi
        done

        if [[ "${toplevel}" ]] ; then
            echo ' done.'
        fi
    done

    return $return_status
}
