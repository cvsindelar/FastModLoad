#####################
# FastModLoad: Fast Module Loader for Lmod-Based HPC Software Stacks
# Chuck Sindelar, Yale Center for Research Computing (March 2026)
######################

# Bash flags to be set only when executing 'bash fml.sh'
# We also allow this script to be sourced, for debugging purposes
if [[ "$0" == "${BASH_SOURCE}" ]]; then
    # Exit immediately when there is an unhandled error:
    set -e

    # Detect unset variables and exit immediately
    set -u
fi

function bailout() {
    echo "if [[ -n \$( declare -f module | grep fml ) ]] ; then "
    echo '    module --fmlrestore ; '
    echo 'else '
    echo '    echo "FastModLoad: Programming error, goodbye" ; '
    echo 'fi ; '
    
    echo 'if [[ ${#__fml_module_args[@]} -gt 0 ]] ; then '
    echo '    __fml_module_args_tmp=("${__fml_module_args[@]}") ; '
    echo "    unset __fml_module_args ; "
    echo '    echo "FastModLoad failure: falling back to Lmod..." ; '
    echo "    echo '   'module \${__fml_module_args_tmp[@]} ; "
    echo "    module \${__fml_module_args_tmp[@]} ; "
    echo "    unset __fml_module_args_tmp ; "
    echo 'fi ; '
    
    echo "if [[ -n \$( module --redirect --terse list | awk '\$0 ~ /^fml\//' ) ]] ; then "
    echo '    echo "FastModLoad: Bailing out, goodbye" ; '
    echo "    module unload fml ; "
    echo "fi ; " ; 
}

# Make the bailout function available to the user bash environment
echo 'function __fml_bailout() {'
bailout
echo ' }  ; '

# Trap for syntax errors in this script, but only when executing 'bash fml.sh' ;
# we also allow this script to be sourced, for debugging purposes
if [[ "$0" == "${BASH_SOURCE}" ]]; then
    trap 'status=$? ; if [ $status -ne 0 ]; then bailout; fi ; exit $status ; ' EXIT
fi

##########################
# Global script variables
##########################

# Load time threshold to print fml reminders:
FML_THRESH=5

# Location of the script and its shortcut libraries
fml_base_dir="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
fml_global_prebuilds_dir="${fml_base_dir}/fml_prebuilds"
fml_prebuilds_dir=~/".config/fml/fml_prebuilds"

######################
# Now execute the specified commands: fml.sh <fml_source_modfile> <cmd>
#   where <cmd> is one of fml, module, init, exit, build
######################

# fml.sh must be provided the location of its corresponding .lua modulefile
if [[ $# -ge 1 ]] ; then
    fml_source_modfile="$1"
    shift
fi

if [[ $# -ge 1 ]] ; then
    case "$1" in
        fml)
            shift
            if [[ $# -ge 1  && "$1" == "--help" ]] ; then
                shift
                echo 'Usage:' >&2
		echo '    fml [--global]         Make a Fast Module for the current module environment and load it' >&2
                echo '                           Alternatively, unpack the currently loaded Fast Module to restore' >&2
                echo '                           the original Lmod environment' >&2
                echo '' >&2
                echo '    fml [--global] <module 1> [<module 2> ...]' >&2
                echo '                           Make a Fast Module for the listed modules' >&2
                echo 'Options:' >&2
                echo '--help                     This help message' >&2
                echo "--global                   Make the new fast module available to all users" >&2
                echo '                            (requires write permission to the fml app folder:' >&2
                echo "                             ${fml_base_dir} )" >&2
                echo '' >&2
                exit
            fi
            
            fmlglobal=
            if [[ $# -ge 1 && "$1" == "--global" ]] ; then
                shift
                fmlglobal='--global'
                if [[ ! -w ${fml_base_dir} ]] ; then
                    echo 'Sorry, you do not have write permission in the global FastModLoad folder:' >&2
                    echo "      ${fml_base_dir}" >&2
                    exit
                fi
            fi
	    source "${fml_base_dir}"/fml_fun.sh
            __fml "${fml_source_modfile}" "${fmlglobal}" load "$@"
            ;;
        
        module)
            shift
	    source "${fml_base_dir}"/fml_fun.sh
            __fml_module "${fml_source_modfile}" "$@"
            ;;
        
        build)
            shift
	    source "${fml_base_dir}"/fml_fun.sh
            __fml_build "${fml_source_modfile}" "$@"
            ;;
        
        exit)
            echo '[[ -n $( declare -f module | grep fml ) ]] && module --fmlrestore ; '
            echo '[[ -n $( declare -f fml ) ]] && unset -f fml ; '
            # echo "echo 'Unpacking the module environment for fml-'${fml_source_modfile}"
	    
	    source "${fml_base_dir}"/fml_fun.sh
            __fml_unpack "${fml_source_modfile}" --nofml
            if [[ $? -ne 0 ]] ; then
                echo 'echo "Warning: unable to restore the full lmod environment"'
                echo 'return 1'
            fi
            ;;
        
        init)
            shift
            if [[ -z $( declare -f module | grep fml ) ]] ; then

cat <<EOF

# Fast module generating function
function fml () {
    local __fml_status
    unset __fml_status

    if [[ \$# -ge 1 && "\$1" == "--fmldebug" ]] ; then
        shift
        echo "\$(bash ${fml_base_dir}/fml.sh ${fml_source_modfile} fml \$@)"
    else
        eval "\$(bash ${fml_base_dir}/fml.sh ${fml_source_modfile} fml \$@)"
    fi
}

##########################################
# Hijacked Lmod module function
# The code below is tested, stable, and should only be changed with extreme care.
# Combined with the bash 'trap' commands at the top of this script, 
#  the below code insulates 'hijacking' from syntax errors
#  or other unexpected errors that occur in the fml functions defined above.
##########################################

function module () {
    # If requested, restore the original Lmod module function
    if [[ "\${1:-}"  == "--fmlrestore" ]] ; then
        # Embed the original module code right here, so it will be restored
        $(declare -f module)
        return
    fi

    local __fml_status
    local __fml_start
    local __fml_end
    local runtime

    unset __fml_status
    __fml_start=0
    __fml_end=0

    # If --lmod or purge are requested, fall back to the original Lmod module code,
    #   which is embedded below
    if [[ "\${1:-}"  == "--lmod" || " \$@ " == *" purge "* ]] ; then
        # Execute the original Lmod module function

        # Remove the fml-specific --lmod flag, if it was used to trigger the current call
        if [[ "\${1:-}"  == "--lmod" ]] ; then
            shift
        fi

        # Embed the original Lmod module code but without the function name
        $(declare -f module | awk 'NR > 1')
    else
        # New functionality obtained by running the bash function fml.sh

        # Optional debug flag '--fmldebug':
        local fmldebug
        fmldebug=0
        if [[ "\${1:-}" == "--fmldebug" ]] ; then
            shift
            fmldebug=1
        fi

        # Now we perform a more stringent test on whether to run fml.sh; otherwise we
        #  fall through to original Lmod module code. Only run fml.sh if:
        #  (1) A module reset is requested (fml.sh handles this specially to reload fml)
        #    or
        #  (2) A fast module is already loaded (fml.sh will unpack it before performing the requested
        #        'module' subcommand)
        #    or
        #  (3) User has requested to load (or unload) at least one module, and
        #       a fast module load of the requested modules is possible.
        #      Fast module loading is only requested if:
        #         - No other Lmod modules are already loaded (refuse to load fast modules on top of these),
        #         - A quick and dirty test indicates a suitable fast module may be available                           

        # Get the first requested module name, if any, and strip the trailing version info since the
        #  user may not have provided it
        local first_load_arg
        first_load_arg=\$(echo "\$@" | \
          awk '\$1=="load" || \$1=="unload" {gsub("/", "_", \$2); if(\$2!="") print \$2; exit}')

        terselist=\$(module --lmod --terse list 2>&1 )

        # Execute fml.sh using the above test
        if [[ " \$@ " == *" reset "* \
              || \$( echo "\${terselist}" | grep '^fml[-]' ) \
              || ( -n \${first_load_arg} \
                   && -z \$( echo "\${terselist}" | grep -v '^StdEnv\$' |& grep -v '^fml[/]' ) \
                   && -n \$( ls ${fml_global_prebuilds_dir}/\${first_load_arg}* \
                                ${fml_prebuilds_dir}/\${first_load_arg}* 2> /dev/null ) ) \
           ]] ; then

            if [[ \${fmldebug} -eq 1 ]] ; then
                echo "\$(bash ${fml_base_dir}/fml.sh ${fml_source_modfile} module \$@ )" >&2
            else
	        # Preserve input arguments in case fml.sh crashes
	  	#  -> in that case, fml.sh will trap the error and try
		#      the original lmod module command with __fml_module_args
		__fml_module_args=("\$@")
                eval "\$(bash ${fml_base_dir}/fml.sh ${fml_source_modfile} module \$@ )"
		if [[ \$? -ne 0 ]] ; then
		    __fml_status=1
		fi
		unset __fml_module_args

		if [[ "\${__fml_status}" -ne 0 ]] ; then
    		    echo "FastModLoad failure: falling back to Lmod.. "
            	    echo module --lmod "\$@"
            	    module --lmod "\$@"
		fi
            fi
        else
            # Otherwise, fml.sh wasn't executed and we fall through to the original Lmod module function

            __fml_start=\$(date +%s)
            module --lmod "\$@"
            __fml_end=\$(date +%s)

	    # Zero the runtime unless a module load was requested:
            # if [[ "\$(echo \$@ | awk '\$1=="load" {loading=1} END {if(loading) print 1 ; else print 0}')" -eq 0 ]] ; then
            if [[ " $* " == *" load "* ]] ; then
	        __fml_start=0
		__fml_end=0
	    fi
        fi

        # Check for excessively slow module loads
        runtime=\$( echo \${__fml_start:-} \${__fml_end:-} | awk '{print \$2 - \$1}' )
        if [[ "\${runtime}" -ge $FML_THRESH ]] ; then
            echo "Slow load time detected ( \${runtime} sec ) ; "
            echo "  - type 'fml' <enter> to speed up loading of this module" >&2
        fi
    fi
}

# Enable autocompletion for fml the same as 'ml':
t=( \$(complete -p ml) )
if [ "\$(type -t \${t[2]})" = 'function' ]; then
    complete -F "\${t[2]}" fml
fi

echo 'Fast Module Loading is active.'
echo "Note: to turn off Fast Module Loading, do 'module purge' or 'ml -fml'"

EOF
            fi
            ;;
        
    esac
fi
