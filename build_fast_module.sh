# Run with: "source build_fast_module.sh"

mkdir -p fml_folder

ordered_module_list=( $( for m in `module --redirect -t list | grep -v StdEnv` ; do \
                            module --redirect --location show $m ; \
                         done) )

for m in ${ordered_module_list[@]}; do
    echo "do -- Scope for $m"
    grep -E -v '^[[:space:]]*depends_on\([[:space:]]*"[^"]*"[[:space:]]*\)[[:space:]]*(--.*)?$' "$m"
    echo "end -- End scope for $m"
done >> "fml_folder/fast_module.lua"

echo 'Now do "module use fml_folder ; ml fast_module"'
